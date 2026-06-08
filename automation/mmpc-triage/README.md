# MMP-C Triage Orchestrator (Azure Automation)

Part 2 of the [MMP-C triage pipeline](../../docs/mmpc-triage-design.md). A scheduled Azure Automation PowerShell runbook that reads the MMP-C health **Proactive Remediation** results and reconciles one Entra **triage group per failure reason** — so unhealthy devices land in a bucket a human can act on, and recovered devices leave automatically.

**Report-only by default.** It logs exactly what it would add/remove and writes nothing until you pass `-Apply`.

## Deployment checklist (in order)

Order matters: the managed identity must exist before it can be granted Graph access, and the PR GUID + group IDs are needed before the variables. Details for each step are in the sections below.

- [ ] **1. Automation account** — create it; enable **system-assigned managed identity**; note its **Object (principal) ID**.
- [ ] **2. Import the runbook** — `Invoke-MmpcTriageOrchestrator.ps1` as a **PowerShell** runbook, **runtime 7.2**, then **Publish**. *(No modules to import — the runbook uses no Az/Graph SDK.)*
- [ ] **3. Grant Graph app roles** to the MI — the three below, via the snippet in [Grant Graph permissions](#grant-graph-permissions-to-the-managed-identity). *(Needs an interactive admin login.)*
- [ ] **4. Triage group(s)** — one assigned Entra security group per reason (start with one); note each **Object ID**.
- [ ] **5. Proactive Remediation** — deploy the detection PR (`Invoke-MmpcDiagnostics.ps1 -AsRemediation`); note its **deviceHealthScript GUID**.
- [ ] **6. Automation Variables** — create the three under [Configure](#configure-automation-variables).
- [ ] **7. Run report-only** — Start the runbook (writes nothing); confirm the per-reason `+N -N` output.
      ⚠️ **This first run doubles as the endpoint check** — if it prints `Devices reporting: 0` while devices have run the PR, the `Get-PrDeviceState` Graph shape needs a tweak for the current API version. That's the one item flagged to verify.
- [ ] **8. Go live (P3)** — once report-only looks right, create a **Schedule** and run with `-Apply`.

## How it works

```
deviceHealthScripts/{id}/deviceRunStates   ──► parse "STATUS|REASON|detail" per device
        │
        ├─ UNHEALTHY → resolve azureADDeviceId → Entra device object id (batched)
        │              desired[reason] = { object ids }
        │
        └─ for each reason group:  add (desired − current),  remove (current − desired)
```

- **Auth:** the Automation account's **system-assigned managed identity**, token pulled from the local `IDENTITY_ENDPOINT` — no Az/Graph SDK import (fast cold start, no version drift).
- **Efficient:** resolves only *unhealthy* devices via Graph `$batch` (20/call); pages every list call; backs off on 429/5xx.
- **Safe:** manages only **device-type** members of the named triage groups; never touches other groups or user members; the groups are owned by this runbook (don't hand-edit them).

## Prerequisites

1. **Azure Automation account** with **system-assigned managed identity** enabled, using the **PowerShell 7.x** runtime.
2. **Triage groups** — one assigned (static) Entra security group per reason you want to route, e.g. `MMPC-Triage-TLSInspection`, `MMPC-Triage-NoLink`, …
3. The MMP-C health **Proactive Remediation** deployed (detection script = `Invoke-MmpcDiagnostics.ps1 -AsRemediation`). Note its **deviceHealthScript GUID**.

## Grant Graph permissions to the managed identity

The runbook needs three **application** permissions, consented to the Automation account's MI (portal can't do this; use Graph). Run once as an admin:

```powershell
Connect-MgGraph -Scopes 'AppRoleAssignment.ReadWrite.All','Application.Read.All'
$miObjectId = '<managed-identity-object-id>'          # Automation account → Identity → Object (principal) ID
$graph = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
'DeviceManagementManagedDevices.Read.All','Device.Read.All','GroupMember.ReadWrite.All' | ForEach-Object {
    $role = $graph.AppRoles | Where-Object Value -eq $_
    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $miObjectId `
        -PrincipalId $miObjectId -ResourceId $graph.Id -AppRoleId $role.Id
}
```

| Permission | Used for |
|------------|----------|
| `DeviceManagementManagedDevices.Read.All` | Read PR device run states + detection output |
| `Device.Read.All` | Resolve `managedDevice.azureADDeviceId` → Entra device object id |
| `GroupMember.ReadWrite.All` | Add/remove triage group members (only needed once you run `-Apply`) |

## Configure (Automation Variables)

Create these under the Automation account → **Shared Resources → Variables** (params override them if you start the runbook manually):

| Variable | Type | Example |
|----------|------|---------|
| `MmpcTriage-HealthScriptId` | String | `1234abcd-…` (the deviceHealthScript GUID) |
| `MmpcTriage-ReasonGroupMap` | String (JSON) | `{"MMPC_TLS_INSPECTION":"<groupId>","MMPC_NO_LINK":"<groupId>","MMPC_STUCK_TASK":"<groupId>"}` |
| `MmpcTriage-SettlingEscalationHours` | Integer | `24` |

Only the reasons present in the map are reconciled — start with one or two buckets and grow.

## Run it

```powershell
# P2 — report-only: review the job output, no writes
.\Invoke-MmpcTriageOrchestrator.ps1

# P3 — enforce: actually reconcile membership
.\Invoke-MmpcTriageOrchestrator.ps1 -Apply
```

Recommended rollout: import the runbook, run **report-only** a few times and confirm the +/- it proposes matches reality, then schedule it (every few hours) and add `-Apply`.

### Local testing (outside Automation)

Set a bearer token and call directly — config can come from parameters:

```powershell
$env:GRAPH_TOKEN = (Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com').Token
.\Invoke-MmpcTriageOrchestrator.ps1 -HealthScriptId '<guid>' -ReasonGroupMap @{ MMPC_TLS_INSPECTION = '<groupId>' }
```

## Verify before first prod run

- **PR run-state endpoint shape.** The read is isolated in `Get-PrDeviceState` (`/deviceManagement/deviceHealthScripts/{id}/deviceRunStates?$expand=managedDevice`, default API version `beta`). Confirm the property names (`preRemediationDetectionScriptOutput`, `lastStateUpdateDateTime`, `managedDevice.azureADDeviceId`) against the current Graph version and adjust there if needed.
- **Settling escalation** is currently informational (logs devices `SETTLING` longer than the threshold). The "is EPM actually assigned?" cross-check — which distinguishes *stuck* from *not-targeted* — is a later-phase addition, since only the orchestrator (not the device) can see assignment.

## Next phases

- **P3** — flip to `-Apply` on a schedule after report-only looks right.
- **P4** — per-bucket human triage playbooks (see the [design doc](../../docs/mmpc-triage-design.md)).
- **P5** — settling-escalation with assignment cross-check; optional per-run JSON/HTML state report.
