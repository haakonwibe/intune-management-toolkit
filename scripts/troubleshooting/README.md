# Intune Troubleshooting Scripts

Device-side diagnostics for Intune-managed Windows endpoints. Scripts here run **locally on the device** and inspect on-box state (registry, certificates, services, scheduled tasks, event logs, connectivity) rather than querying Microsoft Graph.

| Script | Purpose |
|--------|---------|
| [`Invoke-MmpcDiagnostics.ps1`](./Invoke-MmpcDiagnostics.ps1) | Diagnoses the MMP-C / linked (dual) enrollment channel that delivers EPM & Device Inventory |
| [`Get-IntuneDeviceDiagnostics.ps1`](./Get-IntuneDeviceDiagnostics.ps1) | Graph-based per-device diagnostics with progressive detail levels (Standard / Advanced / Detailed) |

> The two are complementary: `Get-IntuneDeviceDiagnostics.ps1` answers *"what does Intune think of this device?"* from the service side; `Invoke-MmpcDiagnostics.ps1` answers *"is the device's MMP-C plumbing actually healthy?"* from the device side.

---

## Invoke-MmpcDiagnostics.ps1

### Why this exists

Classic Intune configuration rides **OMA-DM**. Endpoint Privilege Management (EPM) and Device Inventory do **not** — they come down the **MMP-C** channel (Microsoft Management Platform – Cloud) via a *second*, "linked" (dual) enrollment, processed locally by the Windows Declared Configuration (WinDC) service.

The practical consequence: **a healthy OMA-DM enrollment tells you nothing about MMP-C health.** A single EPM setting like *"Send elevation data for reporting"* can error while every classic profile applies cleanly. This script inspects the MMP-C side specifically.

**Self-contained by design** — no dependency on the IntuneToolkit module or Microsoft Graph, so it runs standalone on any endpoint and can ship as a Proactive Remediation. **Run elevated** (most enrollment reads require admin).

### What it checks (one pass)

1. **Enrollments** under `HKLM\SOFTWARE\Microsoft\Enrollments` — identifies which is Intune (OMA-DM) vs MMP-C (linked), by `DiscoveryServiceFullURL` / `ProviderID`.
2. **`LinkedEnrollment` subkey** — `EnrollStatus`, `LastError`, `MMPCLocked`, `MmpcEnrollmentFlag`, `LinkedEnrollmentID`, `DiscoveryEndpoint`. Health is judged on the link **resolving** (a present MMP-C enrollment that `LinkedEnrollmentID` points at, with `MMPCLocked=1` and `LastError=0`), not on any single magic value.
3. **Dual-enrollment scheduled task** (`deviceenroller.exe /EnrollMmpc`) — a lingering task usually means the enrollment is stuck; it self-deletes on success.
4. **MMP-C device certificate** referenced by `SSLClientCertSearchCriteria`.
5. **EPM agent** (service `DisplayName` + binary `PathName`, install folder + binary present) and the **`DeviceHealthMonitoring`** policy keys.
6. **DM diagnostics event log** (`Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin`) — recent errors/warnings.
7. **Endpoint reachability + TLS-inspection detection** — the single most common MMP-C break is a proxy / SSL-inspection appliance re-signing the server certificate, which fails the cert-chain check during enrollment.

### Endpoint discovery (not hardcoded)

Only `discovery.dm.microsoft.com` is a fixed, documented host. The enrollment / policy / auth URLs are returned **dynamically** by the discovery service per device and tenant — so the script *uncovers* them from the device rather than guessing:

- the per-device `DiscoveryEndpoint` registry value,
- any `*.dm.microsoft.com` host seen in the DM diagnostics log,
- and, with `-DiscoverEndpoints`, a **live query** of the discovery endpoint that surfaces the real `EnrollmentServiceUrl` / `EnrollmentPolicyServiceUrl` / `AuthenticationServiceUrl`.

Every uncovered host is then TLS-probed for interception.

### Parameters

| Parameter | Description |
|-----------|-------------|
| `-AsRemediation` | Intune Proactive Remediation mode: emit one machine-readable `STATUS\|REASON\|detail` line and an exit code (see below). Suppresses the human report. |
| `-DiscoverEndpoints` | Actively POST the discovery service to surface the real enrollment/policy/auth URLs, then TLS-probe everything uncovered. |
| `-Json` | Write a timestamped JSON report (metadata + findings + endpoints). |
| `-JsonPath <dir-or-file>` | Where to write the JSON (default `%TEMP%`). A directory gets a timestamped filename; a `.json` path is used verbatim. |
| `-PassThru` | Return the structured result object for further processing. Without it, console output ends cleanly at the summary. |
| `-CollectCab` | Also drop an `MdmDiagnosticsTool` cab for deeper offline analysis. |
| `-TriggerReEnrollment` | Re-fire MMP-C enrollment (`deviceenroller.exe /c /EnrollMmpc`). **Unsupported**, requires SYSTEM context, prompts before acting. |
| `-EventLookbackHours <n>` | Event-log window (default 24). |
| `-CabOutputPath <path>` | Cab destination (default `%TEMP%\MdmLogs.cab`). |

### Examples

```powershell
# Full read-only diagnostic with a PASS/WARN/FAIL summary
.\Invoke-MmpcDiagnostics.ps1

# Also actively discover the real downstream endpoints and TLS-probe them
.\Invoke-MmpcDiagnostics.ps1 -DiscoverEndpoints

# Capture a JSON report for a ticket / support handoff
.\Invoke-MmpcDiagnostics.ps1 -DiscoverEndpoints -Json -JsonPath C:\Reports

# Capture the structured object for scripting
$r = .\Invoke-MmpcDiagnostics.ps1 -PassThru
$r.Summary    # @{ Fail = 0; Warn = 1; Pass = 5 }
```

### Reading the output

Each check prints a colour-coded `[PASS]` / `[WARN]` / `[FAIL]` / `[INFO]` line, followed by a summary tally and an itemized list of any issues. The returned object (`-PassThru`) exposes `Findings`, `Enrollments`, `Linked`, `Endpoints`, and `Summary`.

| Finding | Likely meaning |
|---------|----------------|
| **FAIL** No MMP-C enrollment / dangling `LinkedEnrollmentId` | The link to MMP-C was never established or is broken — EPM cannot apply. Usual root cause. |
| **FAIL** Endpoint cert "looks like SSL inspection" | A proxy/inspection appliance is re-signing `*.dm.microsoft.com`. Exclude those hosts from TLS interception. |
| **WARN** Enrollment task still present | The `/EnrollMmpc` task is stuck/retrying — chase its `LastResult`. |
| **WARN** `DeviceHealthMonitoring` policy keys absent | Common, often benign; only matters when Device Inventory / health monitoring is actually assigned. Correlates with a `404` in the DM diag log. |
| **INFO** `MmpcEnrollmentFlag` not present | Inconclusive on its own (build-dependent); health is taken from the link state. |

### Deploying as a Proactive Remediation

Because it's self-contained, the script works as a **detection** script in an Intune Proactive Remediation:

| Setting | Value |
|---------|-------|
| Run this script using the logged-on credentials | No (SYSTEM) |
| Enforce script signature check | No |
| Run script in 64-bit PowerShell | Yes |

Use **`-AsRemediation`** as the detection script. It emits a single line and an exit code instead of the human report:

```
.\Invoke-MmpcDiagnostics.ps1 -AsRemediation
# UNHEALTHY|MMPC_TLS_INSPECTION|discovery.dm.microsoft.com cert issued by 'CN=Corp Proxy CA' - looks like SSL inspection.
```

| Exit | Status | Meaning |
|------|--------|---------|
| `0` | `HEALTHY` / `SETTLING` | Healthy, or still completing enrollment — **do not triage** |
| `1` | `UNHEALTHY` | A reason code fired — triage |
| `0` | `ERROR` | Not elevated or an internal error — **fails safe** (never triages on a script problem) |

**Reason codes:** `MMPC_NO_LINK`, `MMPC_TLS_INSPECTION`, `MMPC_ENDPOINT_UNREACHABLE`, `MMPC_LAST_ERROR`, `MMPC_STUCK_TASK`, `MMPC_CERT_MISSING`, `MMPC_AGENT_DOWN`, `MMPC_HEALTHY`, `MMPC_SETTLING`.

The reason code is what a server-side orchestrator routes on (one triage group per reason). See [`docs/mmpc-triage-design.md`](../../docs/mmpc-triage-design.md) for the full pipeline (Azure Automation orchestrator + human triage).

> **Settling window:** a device still completing its linked enrollment (`MMPCLocked` not yet set, no `LastError`) returns `SETTLING`/exit 0 — it is deliberately *not* triaged. A device with EPM assigned that never links can't be distinguished from "EPM not assigned" on the device alone; the orchestrator escalates that case using Graph-side assignment + device age.

---

## Future enhancements

Short list of where this could go next, roughly in priority order:

- ~~**Automation-friendly exit codes / output.**~~ ✅ Done — `-AsRemediation` emits a single `STATUS|REASON|detail` line + exit code. Next: the Azure Automation orchestrator that reconciles triage groups from PR results (see [design doc](../../docs/mmpc-triage-design.md)).
- **Decode the enum fields.** Map `EnrollmentType` (1, 6, 11, 13, 26, …), `EnrollmentState`, and `LinkedEnrollment\EnrollStatus` to human-readable meanings once values are confirmed against documentation (e.g. `EnrollStatus 4 = succeeded`). Today these are shown raw.
- **Event-log correlation.** Recognise and explain the specific IDs that recur on the MMP-C channel — `404` (provider/policy not found), `4108` (Declared Configuration resource cleanup task failed), `2750` (DeviceStatus CSP WSC health) — and separate benign-OMADM noise from genuine WinDC failures.
- **Better certificate resolution.** Resolve the MMP-C device cert from the MMP-C enrollment's own keys, not only the OMA-DM `SSLClientCertSearchCriteria`, and validate the chain / expiry explicitly.
- **HTML report.** A self-contained HTML output (alongside JSON) for ticket attachment, mirroring `Get-IntuneComplianceReport.ps1`.
- **Authenticated discovery walk.** Use the device token to follow the discovery → enrollment → policy chain further, surfacing where a real enrollment attempt would fail rather than stopping at an unauthenticated `200`/`401`.
- **Light remediation actions.** Opt-in, guarded helpers: restart the EPM agent service, kick a sync, or clear a stuck task — separate from the existing unsupported re-enrollment trigger.
- **Multi-device aggregation.** A companion that runs this across a fleet (or ingests the JSON reports) and summarises MMP-C health tenant-wide.

## Things that may prove useful going forward

**On-box locations**

- Enrollments: `HKLM\SOFTWARE\Microsoft\Enrollments\{GUID}` and `…\{GUID}\LinkedEnrollment`
- OMA-DM accounts / cert criteria: `HKLM\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts`
- DHM policy: `HKLM\SOFTWARE\Microsoft\PolicyManager\default\DeviceHealthMonitoring`
- EPM agent: `C:\Program Files\Microsoft EPM Agent` (service `MEMEPMSvc` / "Microsoft EPM Agent Service")
- DM diag log: `Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin`

**Built-in tools worth knowing**

- `MdmDiagnosticsTool.exe -area DeviceEnrollment;DeviceProvisioning;Autopilot;TPM -cab <path>` (the `-CollectCab` switch wraps this)
- `dsregcmd /status` — tenant ID, Entra join state (the discovery probe uses this)
- `deviceenroller.exe /c /EnrollMmpc` — re-fires the linked enrollment (SYSTEM only; unsupported)
- `PsExec -s` — to obtain a SYSTEM context for the above

**Key fact to keep in mind:** the most common real-world MMP-C failure is **TLS inspection of `*.dm.microsoft.com`**, not anything in Intune itself. When in doubt, check section 7 first.

## References

- Microsoft Learn — [Windows declared configuration](https://learn.microsoft.com/en-us/windows/client-management/declared-configuration), [discovery](https://learn.microsoft.com/en-us/windows/client-management/declared-configuration-discovery)
- Microsoft Learn — [Endpoint Privilege Management overview](https://learn.microsoft.com/en-us/intune/intune-service/protect/epm-overview)
- Rudy Ooms (call4cloud.nl) — MMP-C / WinDC / LinkedEnrollment series
