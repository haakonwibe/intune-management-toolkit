# Design: MMP-C Health Triage Pipeline

**Status:** Approved — P0 + P2 (report-only) implemented
**Owner:** @haakonwibe
**Decisions:** Orchestrator = **Azure Automation** runbook ([`automation/mmpc-triage`](../automation/mmpc-triage)). Proactive Remediation licensing confirmed in place.
**Related:** [`scripts/troubleshooting/Invoke-MmpcDiagnostics.ps1`](../scripts/troubleshooting/Invoke-MmpcDiagnostics.ps1), [`function-apps/app-dependency-manager`](../function-apps/app-dependency-manager)

## Problem

Endpoint Privilege Management (EPM) and Device Inventory ride the **MMP-C / linked (dual) enrollment** channel, not classic OMA-DM. A device can be fully Intune-enrolled and compliant while its MMP-C plumbing is broken — so EPM silently fails to apply. Today we can only find this by running `Invoke-MmpcDiagnostics.ps1` on a device by hand.

## Goal

Detect MMP-C health automatically across newly enrolled (and existing) devices, route unhealthy devices into **triage groups by failure reason**, and give a human-in-the-loop workflow to choose and pilot the right fix. Close the loop: devices that recover leave triage automatically.

## Non-goals

- **No auto-remediation of the root cause.** Different MMP-C failures need different fixes (network change vs re-enrollment vs policy assignment); a human decides. The pipeline triages and reports — it does not push fixes.
- Not a replacement for the manual script; the script remains the on-device deep-dive tool.

## Architecture overview

```
  ┌─────────────────────────────────────────────────────────────────────┐
  │ PART 1 — Detect on device, triage server-side                        │
  │                                                                       │
  │  [Intune Proactive Remediation: detection-only]                      │
  │     Invoke-MmpcDiagnostics.ps1 -AsRemediation                        │
  │        exit 0 = healthy / still-settling                             │
  │        exit 1 = unhealthy  + one-line REASON CODE                    │
  │                         │                                            │
  │                         ▼  (Intune records pass/fail + output)       │
  │  [Orchestrator: scheduled job — Azure Automation runbook]           │
  │        • read PR device run states via Graph                        │
  │        • map Intune managedDevice → Entra device object             │
  │        • reconcile triage group membership (add failing, remove       │
  │          recovered) — one group per reason code                     │
  └─────────────────────────────────────────────────────────────────────┘
                            │
                            ▼
  ┌─────────────────────────────────────────────────────────────────────┐
  │ PART 2 — Human triage → targeted fix → pilot                         │
  │   • review triage group(s) (already bucketed by reason)             │
  │   • pick the fix for that bucket (see playbook table)               │
  │   • deploy to a pilot ring, validate, widen                         │
  │   • device passes next detection cycle → auto-removed from triage   │
  └─────────────────────────────────────────────────────────────────────┘
```

> **Why server-side group management?** A Proactive Remediation script runs as SYSTEM on the device with **no Graph permissions** — it cannot add its own device to an Entra group. Group membership must be reconciled by a scheduled job with app permissions. This repo already has that pattern in `app-dependency-manager`.

## Part 1 — Detection contract

The script gains an **`-AsRemediation`** mode (additive; default behaviour unchanged):

- Emits a **single line** (Intune captures the last line of stdout) of the form `STATUS|REASON|detail`.
- **Exit code:** `0` = healthy **or** still-settling (do not triage); `1` = unhealthy (triage).
- Suppresses the colourful human report; machine-readable only.

### Reason codes

| Reason code | Trigger (from existing checks) | Typical fix (Part 2) |
|-------------|-------------------------------|----------------------|
| `MMPC_NO_LINK` | No MMP-C enrollment, or `LinkedEnrollmentId` dangling | Check EPM policy assignment / enrollment restrictions |
| `MMPC_TLS_INSPECTION` | Discovery endpoint cert issued by a non-Microsoft CA (checked when the link is broken) | Exclude `*.dm.microsoft.com` from SSL inspection |
| `MMPC_ENDPOINT_UNREACHABLE` | Discovery host not reachable (TCP) when the link is broken | Firewall/proxy egress allowlist |
| `MMPC_STUCK_TASK` | `/EnrollMmpc` task lingering / non-zero `LastResult` | Assign re-enrollment remediation |
| `MMPC_LAST_ERROR` | `LinkedEnrollment\LastError` ≠ 0 | Decode the error code; route accordingly |
| `MMPC_CERT_MISSING` | `SSLClientCertSearchCriteria` cert absent/expired | Renew/repair device cert |
| `MMPC_AGENT_DOWN` | EPM agent installed but service not Running | Restart service / reinstall agent |
| `MMPC_HEALTHY` | All checks pass | — (exit 0) |

### Settling window (important)

MMP-C linking completes some time **after** enrollment. The detection must not triage a device that is simply still completing:

- Treat "link in progress" (`MMPCLocked` not yet set **and** `LastError = 0`) as **exit 0 / still-settling**, not a failure.
- Optionally honour a minimum device-age / enrollment-age threshold before reporting `MMPC_NO_LINK`.

## Part 2 — Orchestrator (scheduled job)

### Platform — **DECIDED: Azure Automation PowerShell runbook**

Chosen over an Azure Function: best fit for a scheduled Graph/Entra reconciliation job — native PowerShell, built-in scheduling, built-in per-job history (valuable for a human-reviewed workflow), no cold-start/timeout quirks. (The Function alternative was considered for consistency with `app-dependency-manager`; operational fit won.)

The rest of this section is host-agnostic.

### Identity & Graph permissions (least privilege, application)

| Permission | Why |
|------------|-----|
| `DeviceManagementManagedDevices.Read.All` | Read Proactive Remediation (device health script) run states & output |
| `Device.Read.All` | Resolve Intune `managedDevice` → Entra device object (group members are Entra device objects, not Intune IDs) |
| `GroupMember.ReadWrite.All` | Add/remove devices in the triage groups |

> Exact scope names for PR run-state reads should be confirmed against current Graph docs before grant. Use a **system-assigned managed identity** on the Automation account / Function; grant app roles via admin consent.

### Reconciliation logic (idempotent, closed-loop)

```
for each reason code R:
    desiredMembers = devices whose latest PR run = fail with reason R   (Entra device objIds)
    currentMembers = members of triage-group[R]
    add    desiredMembers - currentMembers
    remove currentMembers - desiredMembers      # recovered or re-bucketed
```

- **Idempotent:** running twice changes nothing if state is unchanged.
- **Closed loop:** recovered devices are removed automatically; a device that changes reason moves buckets.
- Handle Graph **paging + throttling (429)** with retry/backoff.
- Log an **action summary** each run (added/removed per group) for the audit trail.

### Group model

- One Entra **triage group per reason code** (`MMPC-Triage-NoLink`, `MMPC-Triage-TLSInspection`, …) → clean routing, obvious owner per bucket.
- Optionally one **parent "all MMP-C triage"** dynamic/rollup group for reporting.
- Groups are **assigned-membership, managed only by the orchestrator** — do not hand-edit.

### Cadence

- Detection PR: Intune's schedule (e.g. daily).
- Orchestrator: timer every few hours — frequent enough to reflect recoveries, infrequent enough to stay well within free tiers.

## Triage playbook (Part 2, human)

| Bucket | First checks | Fix / pilot |
|--------|-------------|-------------|
| TLS inspection | Confirm with the script's section 7 on a sample device | Network team excludes `*.dm.microsoft.com`; re-run detection |
| Stuck task | `LastResult` of the `/EnrollMmpc` task | Re-enrollment remediation to the bucket as a pilot |
| No link | EPM policy assignment, enrollment restrictions | Fix assignment; watch bucket drain |
| Cert missing | Cert store / criteria | Repair channel; reissue |

## Security & operations

- App-only managed identity, three read/one write scope, no secrets in code (consistent with repo guidance).
- Orchestrator only ever touches the named triage groups — never other groups.
- Every run emits an action summary; consider alerting if adds/removes spike (mass-failure signal, e.g. a tenant-wide inspection change).

## Rollout phases

1. **P0 — ✅ done.** `-AsRemediation` + reason codes implemented in the script; decision tree validated across healthy + all failure modes. (Still worth a live run on a genuinely broken device when one is available.)
2. **P1** — Deploy PR detection-only to a pilot ring; just observe Intune's pass/fail reporting (no automation).
3. **P2 — ✅ done.** Orchestrator runbook in **report-only** mode ([`automation/mmpc-triage`](../automation/mmpc-triage)) — managed-identity auth, batched device resolution, set-diff reconciliation logged but not written. Parsing + diff logic unit-tested.
4. **P3** — Enable group writes (`-Apply`) on a schedule once report-only output looks right.
5. **P4** — Stand up the human triage playbooks per bucket.
6. **P5** — Confirm closed-loop removal; widen targeting beyond pilot.

## Open questions

- Confirm the exact Graph scope(s) for reading PR run states + per-device output.
- Targeting: dynamic group of recently-enrolled Windows devices, or all Windows with detection filtering?
- **Settling escalation:** a device with EPM assigned but no link reports `MMPC_SETTLING` forever from the device's point of view (it can't see assignment). The orchestrator — which *can* see assignment + device age via Graph — should escalate "settling beyond N hours with EPM assigned" into the triage flow.
- One triage group per reason vs a single group with the reason carried elsewhere (extension attribute / report)?
- Do we want the orchestrator to also write a small **state report** (JSON/HTML) per run for dashboards?

## References

- MS Learn — [Windows declared configuration](https://learn.microsoft.com/en-us/windows/client-management/declared-configuration)
- MS Learn — [Remediations (Proactive Remediations)](https://learn.microsoft.com/en-us/mem/intune/fundamentals/remediations)
- MS Learn — [Endpoint Privilege Management overview](https://learn.microsoft.com/en-us/intune/intune-service/protect/epm-overview)
- Existing pattern: [`function-apps/app-dependency-manager`](../function-apps/app-dependency-manager)
