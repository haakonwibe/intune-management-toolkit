#Requires -Version 7.0
<#
.SYNOPSIS
    Azure Automation runbook: reconcile MMP-C triage Entra groups from Intune
    Proactive Remediation results. P2 of the MMP-C triage pipeline.

.DESCRIPTION
    Reads the per-device detection results of the MMP-C health Proactive Remediation
    (Invoke-MmpcDiagnostics.ps1 -AsRemediation), parses the "STATUS|REASON|detail" line
    each device emitted, and reconciles one Entra triage group per reason code:

        desired = devices currently UNHEALTHY with reason R   (as Entra device object ids)
        current = device members of triage-group[R]
        add    = desired - current
        remove = current - desired      (recovered or re-bucketed)

    REPORT-ONLY by default: it logs exactly what it would add/remove and writes nothing.
    Pass -Apply to perform the group writes (pipeline phase P3).

    Auth is the Automation account's system-assigned managed identity, via the local
    IDENTITY_ENDPOINT - no Az/Graph SDK import (those are slow/heavy in the sandbox).

.NOTES
    Required Graph application permissions (admin-consented to the MI):
      DeviceManagementManagedDevices.Read.All  (read PR device run states + output)
      Device.Read.All                          (resolve managedDevice -> Entra device object)
      GroupMember.ReadWrite.All                (manage triage group membership; needed for -Apply)

    Configuration is read from Automation Variables when present, else from parameters:
      MmpcTriage-HealthScriptId      : GUID of the deviceHealthScript (Proactive Remediation)
      MmpcTriage-ReasonGroupMap      : JSON object { "MMPC_TLS_INSPECTION": "<groupId>", ... }
      MmpcTriage-SettlingEscalationHours : int (default 24)

    Graph endpoint shapes (deviceHealthScripts/deviceRunStates) should be confirmed against
    the current Graph version before first prod run - they are isolated in Get-PrDeviceState.

.PARAMETER Apply
    Perform group writes. Omit (default) for report-only.

.EXAMPLE
    # Report-only (P2): log what would change, write nothing
    .\Invoke-MmpcTriageOrchestrator.ps1

.EXAMPLE
    # Enforce (P3): actually reconcile the triage groups
    .\Invoke-MmpcTriageOrchestrator.ps1 -Apply
#>
[CmdletBinding()]
param(
    [string]   $HealthScriptId,
    [hashtable]$ReasonGroupMap,
    [int]      $SettlingEscalationHours,
    [string]   $GraphApiVersion = 'beta',   # PR run-state shape is richest in beta
    [switch]   $Apply
)

$ErrorActionPreference = 'Stop'
$GraphBase = 'https://graph.microsoft.com'

# ---------------------------------------------------------------------------
# configuration: Automation Variables override params (so a schedule needs no args)
# ---------------------------------------------------------------------------
function Get-Config {
    param([string]$Name, $Fallback)
    if (Get-Command Get-AutomationVariable -ErrorAction SilentlyContinue) {
        try { $v = Get-AutomationVariable -Name $Name -ErrorAction Stop; if ($null -ne $v -and "$v" -ne '') { return $v } }
        catch { Write-Verbose "Automation variable '$Name' not set; using fallback." }
    }
    $Fallback
}

# ---------------------------------------------------------------------------
# auth: managed identity token from the Automation sandbox (no modules).
# Local testing fallback: set $env:GRAPH_TOKEN to a bearer token.
# ---------------------------------------------------------------------------
function Get-GraphToken {
    if ($env:GRAPH_TOKEN) { return $env:GRAPH_TOKEN }
    if (-not $env:IDENTITY_ENDPOINT) {
        throw "No IDENTITY_ENDPOINT (not in an Automation MI sandbox) and no `$env:GRAPH_TOKEN for local testing."
    }
    $uri = "$($env:IDENTITY_ENDPOINT)?resource=$GraphBase&api-version=2019-08-01"
    $resp = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER }
    $resp.access_token
}

# ---------------------------------------------------------------------------
# thin Graph client: bearer auth, transparent paging, 429/5xx backoff.
# Returns the flattened .value collection for GETs, or the response for writes.
# ---------------------------------------------------------------------------
function Invoke-Graph {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Url,          # absolute or '/path' (assumed v1.0 if no version segment)
        $Body,
        [int]$MaxRetries = 5
    )
    if ($Url -notmatch '^https?://') {
        $ver = if ($Url -match '^/(v1\.0|beta)/') { '' } else { 'v1.0/' }
        $Url = "$GraphBase/$ver$($Url.TrimStart('/'))"
    }

    $headers = @{ Authorization = "Bearer $script:GraphToken"; 'Content-Type' = 'application/json' }
    $collected = [System.Collections.Generic.List[object]]::new()

    while ($Url) {
        $attempt = 0
        while ($true) {
            try {
                $params = @{ Method = $Method; Uri = $Url; Headers = $headers }
                if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress) }
                $resp = Invoke-RestMethod @params
                break
            }
            catch {
                $status = $_.Exception.Response.StatusCode.value__
                if (($status -eq 429 -or $status -ge 500) -and $attempt -lt $MaxRetries) {
                    $retryAfter = 0
                    try { $retryAfter = [int]$_.Exception.Response.Headers['Retry-After'] } catch { Write-Verbose 'no Retry-After header' }
                    if (-not $retryAfter) { $retryAfter = [Math]::Min(60, [Math]::Pow(2, $attempt)) }
                    Write-Verbose "Graph $status on $Url - retry $($attempt+1)/$MaxRetries after ${retryAfter}s"
                    Start-Sleep -Seconds $retryAfter
                    $attempt++
                    continue
                }
                throw
            }
        }

        if ($Method -ne 'GET') { return $resp }
        if ($null -ne $resp.value) { $collected.AddRange(@($resp.value)) } elseif ($resp) { $collected.Add($resp) }
        $Url = $resp.'@odata.nextLink'
    }
    $collected
}

# ---------------------------------------------------------------------------
# Graph $batch: run up to 20 requests per call. Returns id -> response map.
# ---------------------------------------------------------------------------
function Invoke-GraphBatch {
    param([Parameter(Mandatory)][object[]]$Requests)   # each: @{ id; method; url }
    $results = @{}
    for ($i = 0; $i -lt $Requests.Count; $i += 20) {
        $chunk = $Requests[$i..([Math]::Min($i + 19, $Requests.Count - 1))]
        $resp = Invoke-Graph -Method POST -Url "$GraphBase/v1.0/`$batch" -Body @{ requests = $chunk }
        foreach ($r in $resp.responses) { $results[$r.id] = $r }
    }
    $results
}

# ---------------------------------------------------------------------------
# read PR per-device detection results. ISOLATED so the (verify-me) endpoint
# shape lives in one place. Returns: @{ AzureAdDeviceId; DeviceName; Status;
# Reason; Detail; UpdatedUtc }.
# ---------------------------------------------------------------------------
function Get-PrDeviceState {
    param([Parameter(Mandatory)][string]$HealthScriptId)

    $url = "/$GraphApiVersion/deviceManagement/deviceHealthScripts/$HealthScriptId/deviceRunStates?`$expand=managedDevice"
    foreach ($s in (Invoke-Graph -Method GET -Url $url)) {
        $out  = "$($s.preRemediationDetectionScriptOutput)".Trim()
        $line = ($out -split "`r?`n" | Where-Object { $_ -match '^\s*(HEALTHY|SETTLING|UNHEALTHY|ERROR)\s*\|' } | Select-Object -Last 1)
        if (-not $line) { continue }                       # device hasn't reported our contract (yet)
        $parts = $line -split '\|', 3
        [pscustomobject]@{
            AzureAdDeviceId = $s.managedDevice.azureADDeviceId
            DeviceName      = $s.managedDevice.deviceName
            Status          = $parts[0].Trim()
            Reason          = ($parts[1]).Trim()
            Detail          = if ($parts.Count -ge 3) { $parts[2].Trim() } else { '' }
            UpdatedUtc      = $s.lastStateUpdateDateTime
        }
    }
}

# ---------------------------------------------------------------------------
# resolve Entra device deviceId (GUID) -> directory object id, in batches.
# Group membership uses the object id, not the deviceId.
# ---------------------------------------------------------------------------
function Resolve-EntraDeviceObjectId {
    param([Parameter(Mandatory)][string[]]$DeviceIds)
    $map = @{}
    $reqs = @($DeviceIds | Where-Object { $_ } | Select-Object -Unique | ForEach-Object {
            @{ id = $_; method = 'GET'; url = "/devices?`$filter=deviceId eq '$_'&`$select=id,deviceId" }
        })
    if (-not $reqs) { return $map }
    foreach ($kv in (Invoke-GraphBatch -Requests $reqs).GetEnumerator()) {
        $obj = $kv.Value.body.value | Select-Object -First 1
        if ($obj) { $map[$kv.Key] = $obj.id }
    }
    $map
}

# ---------------------------------------------------------------------------
# device-type members of a group (object ids). Only devices - never touch
# user members even if a group was misconfigured.
# ---------------------------------------------------------------------------
function Get-GroupDeviceMemberId {
    param([Parameter(Mandatory)][string]$GroupId)
    (Invoke-Graph -Method GET -Url "/groups/$GroupId/members/microsoft.graph.device?`$select=id").id
}

# Writes are gated by -Apply at the orchestration level, so per-helper ShouldProcess is redundant.
function Add-GroupMember {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([string]$GroupId, [string]$ObjectId)
    Invoke-Graph -Method POST -Url "/groups/$GroupId/members/`$ref" `
        -Body @{ '@odata.id' = "$GraphBase/v1.0/directoryObjects/$ObjectId" } | Out-Null
}
function Remove-GroupMember {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([string]$GroupId, [string]$ObjectId)
    Invoke-Graph -Method DELETE -Url "/groups/$GroupId/members/$ObjectId/`$ref" | Out-Null
}

# ===========================================================================
# main
# ===========================================================================
$healthScriptId = if ($HealthScriptId) { $HealthScriptId } else { Get-Config 'MmpcTriage-HealthScriptId' }
$settlingHours  = if ($PSBoundParameters.ContainsKey('SettlingEscalationHours')) { $SettlingEscalationHours }
                  else { [int](Get-Config 'MmpcTriage-SettlingEscalationHours' 24) }
$reasonGroupMap = if ($ReasonGroupMap) { $ReasonGroupMap }
                  else { $j = Get-Config 'MmpcTriage-ReasonGroupMap'; if ($j) { ($j | ConvertFrom-Json -AsHashtable) } else { @{} } }

if (-not $healthScriptId) { throw "No HealthScriptId (param or Automation variable 'MmpcTriage-HealthScriptId')." }
if (-not $reasonGroupMap.Count) { throw "No ReasonGroupMap (param or Automation variable 'MmpcTriage-ReasonGroupMap')." }

$mode = if ($Apply) { 'APPLY' } else { 'REPORT-ONLY' }
Write-Output "MMP-C triage orchestrator | mode=$mode | healthScript=$healthScriptId | reasons=$($reasonGroupMap.Keys -join ',')"

$script:GraphToken = Get-GraphToken

# 1. pull all device verdicts
$states = @(Get-PrDeviceState -HealthScriptId $healthScriptId)
$unhealthy = $states | Where-Object Status -eq 'UNHEALTHY'
Write-Output ("Devices reporting: {0} | unhealthy: {1} | settling: {2} | healthy: {3}" -f `
    $states.Count, $unhealthy.Count,
    ($states | Where-Object Status -eq 'SETTLING').Count,
    ($states | Where-Object Status -eq 'HEALTHY').Count)

# 2. resolve unhealthy devices -> Entra object ids (batched, unhealthy only)
$objIdMap = Resolve-EntraDeviceObjectId -DeviceIds @($unhealthy.AzureAdDeviceId)

# 3. reconcile each reason's group
$summary = [System.Collections.Generic.List[object]]::new()
foreach ($reason in $reasonGroupMap.Keys) {
    $groupId = $reasonGroupMap[$reason]

    $desired = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($d in ($unhealthy | Where-Object Reason -eq $reason)) {
        $oid = $objIdMap[$d.AzureAdDeviceId]
        if ($oid) { [void]$desired.Add($oid) }
        else { Write-Warning "No Entra device object for $($d.DeviceName) ($($d.AzureAdDeviceId)) - skipped." }
    }

    $current = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($m in @(Get-GroupDeviceMemberId -GroupId $groupId)) { [void]$current.Add($m) }

    $toAdd    = $desired    | Where-Object { -not $current.Contains($_) }
    $toRemove = @($current) | Where-Object { -not $desired.Contains($_) }

    Write-Output ("[{0}] group={1} | desired={2} current={3} | +{4} -{5}{6}" -f `
        $reason, $groupId, $desired.Count, $current.Count, @($toAdd).Count, @($toRemove).Count,
        ($(if (-not $Apply) { ' (report-only)' } else { '' })))

    if ($Apply) {
        foreach ($o in $toAdd)    { Add-GroupMember    -GroupId $groupId -ObjectId $o }
        foreach ($o in $toRemove) { Remove-GroupMember -GroupId $groupId -ObjectId $o }
    }
    else {
        foreach ($o in $toAdd)    { Write-Output "    would ADD    $o" }
        foreach ($o in $toRemove) { Write-Output "    would REMOVE $o" }
    }

    $summary.Add([pscustomobject]@{ Reason = $reason; GroupId = $groupId
            Desired = $desired.Count; Current = $current.Count
            Added = @($toAdd).Count; Removed = @($toRemove).Count })
}

# 4. settling-too-long candidates (informational; assignment cross-check is a TODO for
#    a later phase - the device can't see whether EPM is assigned, the orchestrator can).
$cutoff = (Get-Date).ToUniversalTime().AddHours(-$settlingHours)
$stuck = $states | Where-Object { $_.Status -eq 'SETTLING' -and $_.UpdatedUtc -and ([datetime]$_.UpdatedUtc).ToUniversalTime() -lt $cutoff }
if ($stuck) {
    Write-Warning "$($stuck.Count) device(s) SETTLING > ${settlingHours}h - escalation candidates (verify EPM is assigned): $((@($stuck.DeviceName) | Select-Object -First 20) -join ', ')"
}

Write-Output "Done ($mode)."
$summary | Format-Table -AutoSize | Out-String | Write-Output
