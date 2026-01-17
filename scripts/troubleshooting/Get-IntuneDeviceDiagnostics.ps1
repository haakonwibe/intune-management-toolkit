<#
.SYNOPSIS
    Intune device diagnostics (Standard | Advanced | Detailed) with actionable, real Graph data.

.DESCRIPTION
    Standard  (Quick ~5s): Core device facts + health indicators (sync age, compliance, encryption, storage).
    Advanced  (~30s): Adds issue analysis, compliance policy breakdown (incl. failing settings), configuration
                      profile states, top detected apps, group memberships, category, autopilot profile,
                      protection state summary, targeted recommendations.
    Detailed  (Deeper):   Adds full app inventory, per-setting config states (conflict/error), full non‑compliant
                      setting values, Azure AD device properties, recent audit events, log collection requests,
                      richer hardware / security info & extended recommendations.

    Only displays sections that have data (no explicit '(none)' noise). All data comes from Microsoft Graph
    using SDK cmdlets (with beta fallbacks only where necessary) – no placeholders.

.PARAMETER DeviceId
    The Intune device ID to diagnose.

.PARAMETER DeviceName
    The device name to search for in Intune.

.PARAMETER UserPrincipalName
    Find devices by user. Returns newest by LastSync unless -AllUserDevices is specified.

.PARAMETER DiagnosticLevel
    Standard | Advanced | Detailed (legacy Basic -> Standard, LegacyStandard -> Advanced).

.PARAMETER IncludeAuditLogs
    Adds audit log / directory events (needs AuditLog.Read.All + Directory.Read.All) – automatically added for Detailed.

.PARAMETER OutputPath
    When supplied, exports a JSON bundle with all collected data for the device.

.PARAMETER ShowRemediation
    Print remediation recommendations.

.NOTES
    File Name      : Get-IntuneDeviceDiagnostics.ps1
    Author         : Haakon Wibe
    Prerequisite   : Microsoft Graph PowerShell SDK
    License        : MIT
    Version        : 1.0

.EXAMPLE
    .\Get-IntuneDeviceDiagnostics.ps1 -DeviceName "LAPTOP-123"

.EXAMPLE
    .\Get-IntuneDeviceDiagnostics.ps1 -DeviceName "LAPTOP-123" -DiagnosticLevel Advanced

.EXAMPLE
    .\Get-IntuneDeviceDiagnostics.ps1 -UserPrincipalName "user@contoso.com" -DiagnosticLevel Detailed -OutputPath "C:\Reports"
#>
[CmdletBinding()]param(
    [string]$DeviceId,
    [string]$DeviceName,
    [string]$UserPrincipalName,
    [ValidateSet('Standard','Advanced','Detailed','Basic','LegacyStandard')][string]$DiagnosticLevel = 'Standard',
    [switch]$IncludeAuditLogs,
    [int]$DaysBack = 7,
    [string]$OutputPath,
    [switch]$ShowRemediation,
    [int]$SyncStaleDays = 7,
    [int]$EnrollmentPendingHours = 24,
    [switch]$AllUserDevices,
    [int]$TopApps = 20,
    [switch]$Disconnect
)

# Map legacy
switch ($DiagnosticLevel) { 'Basic' { $DiagnosticLevel='Standard' } 'LegacyStandard' { $DiagnosticLevel='Advanced' } }

if (-not $DeviceId -and -not $DeviceName -and -not $UserPrincipalName) { Write-Host 'Usage: specify -DeviceId | -DeviceName | -UserPrincipalName' -ForegroundColor Yellow; return }

#region Bootstrap
$ErrorActionPreference = 'Stop'
$toolkitPath = Join-Path $PSScriptRoot '../../modules/IntuneToolkit/IntuneToolkit.psm1'
if (Test-Path $toolkitPath) { try { Import-Module $toolkitPath -Force -ErrorAction Stop } catch {} }
if (-not (Get-Command Write-IntuneLog -ErrorAction SilentlyContinue)) { function Write-IntuneLog { param([string]$Message,[ValidateSet('Info','Warning','Error','Success','Debug')]$Level='Info') $ts=(Get-Date -Format 'u'); $c=switch($Level){Info{'White'}Warning{'Yellow'}Error{'Red'}Success{'Green'}Debug{'Cyan'}}; Write-Host "[$ts] $Message" -ForegroundColor $c } }
$scopeLevel = if ($DiagnosticLevel -eq 'Standard') { 'ReadOnly' } else { 'Standard' }
if ($DiagnosticLevel -eq 'Detailed') { $IncludeAuditLogs = $true }
$extraScopes=@(); if ($IncludeAuditLogs){ $extraScopes += 'AuditLog.Read.All','Directory.Read.All' }
try { Connect-IntuneGraph -PermissionLevel $scopeLevel -AdditionalScopes $extraScopes -Quiet | Out-Null } catch { Write-IntuneLog "Graph connect failed: $_" -Level Error; throw }
$script:startTime = Get-Date
#endregion

#region Functions
function Get-TargetDevices {
    if ($DeviceId) { try { return @(Get-MgDeviceManagementManagedDevice -ManagedDeviceId $DeviceId -ErrorAction Stop) } catch { throw "Device not found: $DeviceId" } }
    if ($DeviceName) { $d = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$DeviceName'" -All; if(-not $d){ throw "No device named $DeviceName"}; return @($d|Sort-Object LastSyncDateTime -Descending|Select-Object -First 1) }
    if ($UserPrincipalName) { $d = Get-MgDeviceManagementManagedDevice -Filter "userPrincipalName eq '$UserPrincipalName'" -All; if(-not $d){ throw "No devices for $UserPrincipalName"}; if(-not $AllUserDevices){ $d=$d|Sort-Object LastSyncDateTime -Descending|Select-Object -First 1 }; return @($d) }
}
function Get-ComplianceStates { param($DeviceId) try { Get-MgDeviceManagementManagedDeviceCompliancePolicyState -ManagedDeviceId $DeviceId -All } catch { @() } }
function Get-ComplianceSettingStates { param($DeviceId,$PolicyStateId) try { Get-MgDeviceManagementManagedDeviceCompliancePolicySettingState -ManagedDeviceId $DeviceId -CompliancePolicyStateId $PolicyStateId -All } catch { @() } }
function Get-ConfigStates { param($DeviceId) try { Get-MgDeviceManagementManagedDeviceDeviceConfigurationState -ManagedDeviceId $DeviceId -All } catch { @() } }
function Get-ConfigSettingStates { param($DeviceId,$ConfigStateId) try { Get-MgDeviceManagementManagedDeviceDeviceConfigurationSettingState -ManagedDeviceId $DeviceId -DeviceConfigurationStateId $ConfigStateId -All } catch { @() } }
function Get-DetectedApps { param($DeviceId,[switch]$All,[int]$Top=20) try { if($All){ Get-MgDeviceManagementManagedDeviceDetectedApp -ManagedDeviceId $DeviceId -All } else { Get-MgDeviceManagementManagedDeviceDetectedApp -ManagedDeviceId $DeviceId -Top $Top } } catch { @() } }
function Get-Groups { param($AzureAdDeviceId) if(-not $AzureAdDeviceId){return @()} try { (Get-MgDeviceMemberOf -DeviceId $AzureAdDeviceId -All -ErrorAction SilentlyContinue) | ForEach-Object { $_.AdditionalProperties.displayName } | Where-Object { $_ } } catch { @() } }
function Get-Autopilot { param($DeviceId,$AzureAdDeviceId) try { $cmd=Get-Command Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -ErrorAction SilentlyContinue; if($cmd){ $ap = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -Filter "managedDeviceId eq '$DeviceId'" -All -ErrorAction SilentlyContinue|Select-Object -First 1; if(-not $ap -and $AzureAdDeviceId){ $ap = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -Filter "azureAdDeviceId eq '$AzureAdDeviceId'" -All -ErrorAction SilentlyContinue|Select-Object -First 1 }; if($ap){ return $ap } } } catch { } }
function Get-Protection { param($DeviceId) try { Get-MgDeviceManagementManagedDeviceWindowsProtectionState -ManagedDeviceId $DeviceId -ErrorAction SilentlyContinue } catch { $null } }
function Get-AadDevice { param($AzureAdDeviceId) if(-not $AzureAdDeviceId){ return $null } try { Get-MgDevice -DeviceId $AzureAdDeviceId -ErrorAction SilentlyContinue } catch { $null } }
function Get-Audit { param($AzureAdDeviceId,$Since,[int]$Top=50) if(-not $AzureAdDeviceId){return @()} try { $filter = "targetResources/any(t: t/id eq '$AzureAdDeviceId') and activityDateTime ge $($Since.ToString('o'))"; Get-MgAuditLogDirectoryAudit -Filter $filter -Top $Top -ErrorAction SilentlyContinue } catch { @() } }
function Get-LogCollections { param($DeviceId) try { Get-MgDeviceManagementManagedDeviceLogCollectionRequest -ManagedDeviceId $DeviceId -All -ErrorAction SilentlyContinue } catch { @() } }

function Analyze-Issues { param($device,$syncHours,$complianceStates,$configStates)
    $issues=@()
    if ($syncHours -gt 168) { $issues += "❌ Device hasn't synced in over a week ($syncHours h)" } elseif ($syncHours -gt 24) { $issues += "⚠️ Device sync stale ($syncHours h)" }
    if ($device.ComplianceState -ne 'compliant' -and $device.ComplianceState) { $issues += "❌ Overall compliance: $($device.ComplianceState)" }
    foreach($c in $configStates | Where-Object { $_.State -in 'error','conflict' }) { $issues += "❌ Config profile: $($c.DisplayName) state=$($c.State)" }
    foreach($p in $complianceStates | Where-Object { $_.State -eq 'nonCompliant' }) { $issues += "❌ Policy non-compliant: $($p.DisplayName)" }
    # Duplicate policy detection (improved wording)
    $dup = $complianceStates | Group-Object DisplayName | Where-Object Count -gt 1
    foreach($dgrp in $dup){ $issues += "⚠️ Duplicate policy assignments: '$($dgrp.Name)' appears $($dgrp.Count) times" }
    if (-not $device.IsEncrypted) { $issues += '⚠️ Disk encryption not reported as enabled' }
    if ($device.TotalStorageSpaceInBytes -and $device.FreeStorageSpaceInBytes){ $pct = [math]::Round(($device.FreeStorageSpaceInBytes / $device.TotalStorageSpaceInBytes)*100,1); if($pct -lt 10){ $issues += "⚠️ Low free storage (${pct}%)" } }
    # Non‑Windows policy assignment (heuristic name match)
    if ($device.OperatingSystem -match 'Windows') {
        $nonWin = $complianceStates | Where-Object { $_.DisplayName -match '(?i)iOS|Android|macOS' -and $_.State -ne 'notApplicable' }
        if ($nonWin){ $issues += '⚠️ Non-Windows compliance policies assigned to Windows device' }
    }
    $issues
}
function Build-Recommendations { param($device,$issues,$syncHours,$complianceStates,$complianceSettingDetails,$protection)
    $recs=@()
    if ($syncHours -gt 24) { $recs += 'Force device sync from Intune portal / Company Portal.' }
    if ($issues -match 'encryption' -and -not $device.IsEncrypted){ $recs += 'Enable BitLocker (verify policy assignment / recovery escrow).' }
    if ($issues -match 'Low free storage'){ $recs += 'Free disk space (cleanup temp, remove unused software).' }
    if ($complianceStates | Where-Object State -eq 'nonCompliant'){ $recs += 'Open non-compliant policy -> review failing settings & remediate.' }
    if ($protection -and -not $protection.RealTimeProtectionEnabled){ $recs += 'Turn on Defender real-time protection.' }
    if (-not $recs){ $recs = 'No immediate remediation required.' }
    $recs | Select-Object -Unique
}
#endregion

Write-IntuneLog 'Collecting device(s)...' -Level Info
$devices = Get-TargetDevices
Write-IntuneLog "Devices in scope: $($devices.Count)" -Level Info

foreach($device in $devices){
    Write-IntuneLog "Processing: $($device.DeviceName)" -Level Info
    $syncHours = if($device.LastSyncDateTime){ [math]::Round(((Get-Date)-$device.LastSyncDateTime).TotalHours,1) } else { 'N/A' }

    if ($DiagnosticLevel -eq 'Standard') {
        Write-Host '=== QUICK DEVICE STATUS ===' -ForegroundColor Cyan
        Write-Host "Device: $($device.DeviceName)"
        Write-Host "User: $($device.UserPrincipalName)"
        Write-Host "Model: $($device.Manufacturer) $($device.Model)"
        Write-Host "OS: $($device.OperatingSystem) $($device.OsVersion)"
        Write-Host "Serial: $($device.SerialNumber)"
        Write-Host ''
        Write-Host 'Status Indicators:' -ForegroundColor Yellow
        if ($syncHours -ne 'N/A'){ Write-Host "  Last Sync: $syncHours hours ago $(if($syncHours -gt 24){'⚠️'}else{'✅'})" }
        Write-Host "  Compliance: $($device.ComplianceState) $(if($device.ComplianceState -eq 'compliant'){'✅'}else{'❌'})"
        if ($device.PSObject.Properties.Name -contains 'IsEncrypted'){ Write-Host "  Encrypted: $(if($device.IsEncrypted){'Yes ✅'}else{'No ❌'})" }
        if ($device.PSObject.Properties.Name -contains 'ManagementState'){ Write-Host "  Management: $($device.ManagementState)" }
        Write-Host ''
        Write-Host 'Quick Stats:' -ForegroundColor Yellow
        if ($device.TotalStorageSpaceInBytes){ Write-Host ("  Storage: {0}GB free of {1}GB" -f ([math]::Round($device.FreeStorageSpaceInBytes/1GB,1)),([math]::Round($device.TotalStorageSpaceInBytes/1GB,1))) }
        Write-Host "  Enrolled: $($device.EnrolledDateTime)"
        Write-Host "  Ownership: $($device.OwnerType)"
        continue
    }

    # Advanced & Detailed
    $compliancePolicies = Get-ComplianceStates -DeviceId $device.Id
    $configStates       = Get-ConfigStates -DeviceId $device.Id
    $detectedApps       = Get-DetectedApps -DeviceId $device.Id -All:($DiagnosticLevel -eq 'Detailed') -Top $TopApps
    $groups             = Get-Groups -AzureAdDeviceId $device.AzureAdDeviceId
    # Replaced invalid cmdlet (Get-MgDeviceManagementManagedDeviceDeviceCategory). Use existing property instead.
    $category           = $device.DeviceCategoryDisplayName
    $autopilot          = Get-Autopilot -DeviceId $device.Id -AzureAdDeviceId $device.AzureAdDeviceId
    $protection         = Get-Protection -DeviceId $device.Id
    $aadDevice          = if ($DiagnosticLevel -eq 'Detailed'){ Get-AadDevice -AzureAdDeviceId $device.AzureAdDeviceId } else { $null }
    $audit              = if ($IncludeAuditLogs){ Get-Audit -AzureAdDeviceId $device.AzureAdDeviceId -Since (Get-Date).AddDays(-[math]::Min($DaysBack,30)) } else { @() }
    $logCollections     = if ($DiagnosticLevel -eq 'Detailed'){ Get-LogCollections -DeviceId $device.Id } else { @() }

    # Setting-level details (Detailed)
    $configSettingMap=@{}; if ($DiagnosticLevel -eq 'Detailed'){ foreach($c in $configStates){ if($c.State -in 'error','conflict'){ $cfg = Get-ConfigSettingStates -DeviceId $device.Id -ConfigStateId $c.Id; if($cfg){ $configSettingMap[$c.Id]=$cfg } } } }
    $complianceSettingMap=@{}; if ($DiagnosticLevel -eq 'Detailed'){ foreach($p in ($compliancePolicies|Where-Object State -eq 'nonCompliant')){ $sets=Get-ComplianceSettingStates -DeviceId $device.Id -PolicyStateId $p.Id; if($sets){ $complianceSettingMap[$p.Id]=$sets } } }

    $issues = Analyze-Issues -device $device -syncHours $syncHours -complianceStates $compliancePolicies -configStates $configStates
    $recommendations = if ($ShowRemediation){ Build-Recommendations -device $device -issues $issues -syncHours $syncHours -complianceStates $compliancePolicies -complianceSettingDetails $complianceSettingMap -protection $protection } else { @() }

    # For Detailed level gather device action results (recent actions)
    $deviceActions = @()
    if ($DiagnosticLevel -eq 'Detailed') {
        try {
            $actionUri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices('$($device.Id)')/deviceActionResults"
            $deviceActions = Invoke-MgGraphRequest -Method GET -Uri $actionUri -ErrorAction SilentlyContinue
            if ($deviceActions -and $deviceActions.value){ $deviceActions = $deviceActions.value } else { $deviceActions=@() }
        } catch { $deviceActions=@() }
    }

    # ----- Output -----
    Write-Host ('='*70)
    Write-Host ("=== DEVICE DIAGNOSTICS: {0} ({1}) ===" -f $device.DeviceName,$DiagnosticLevel) -ForegroundColor Cyan
    Write-Host ("User: {0}" -f $device.UserPrincipalName)
    Write-Host ("Model: {0} {1} | OS: {2} {3}" -f $device.Manufacturer,$device.Model,$device.OperatingSystem,$device.OsVersion) -ForegroundColor Gray
    if ($syncHours -ne 'N/A'){ Write-Host ("Last Sync: {0}h ago" -f $syncHours) -ForegroundColor Gray }
    $complianceColor = if ($device.ComplianceState -eq 'compliant') { 'Green' } else { 'Red' }
    Write-Host ("Compliance: {0}" -f $device.ComplianceState) -ForegroundColor $complianceColor
    if ($protection){ Write-Host ("BitLocker: {0} | AV RT: {1}" -f ($protection.BitLockerStatus,$protection.RealTimeProtectionEnabled) ) -ForegroundColor Gray }
    if ($category) { Write-Host ("Category: {0}" -f $category) -ForegroundColor Gray }

    # Issues
    Write-Host "`n=== POTENTIAL ISSUES ===" -ForegroundColor Red
    if ($issues.Count -eq 0){ Write-Host '  ✅ No issues detected' -ForegroundColor Green } else { foreach($i in $issues){ Write-Host "  $i" } }

    # Advanced sections (kept as-is) only when Advanced
    if ($DiagnosticLevel -eq 'Advanced') {
        if ($compliancePolicies){
            Write-Host "`n=== COMPLIANCE POLICIES ===" -ForegroundColor Yellow
            foreach($pol in $compliancePolicies){
                $icon = switch($pol.State){ 'compliant'{'✅'} 'nonCompliant'{'❌'} 'unknown'{'❓'} 'notApplicable'{'⊘'} default{'❓'} }
                Write-Host ("  $icon {0} [{1}]" -f $pol.DisplayName,$pol.State)
            }
        }
        if ($configStates){
            Write-Host "`n=== CONFIGURATION PROFILES ===" -ForegroundColor Yellow
            foreach($cfg in $configStates){ $icon = switch($cfg.State){ 'compliant'{'✅'} 'conflict'{'⚠️'} 'error'{'❌'} 'notApplicable'{'⊘'} default{'❓'} }; Write-Host ("  $icon {0} [{1}]" -f $cfg.DisplayName,$cfg.State) }
        }
        if ($detectedApps){
            Write-Host "`n=== INSTALLED SOFTWARE ($((($detectedApps|Measure-Object).Count))) ===" -ForegroundColor Yellow
            $appList = $detectedApps | Sort-Object DisplayName | Select-Object -First $TopApps
            foreach($app in $appList){ Write-Host ("  - {0} v{1}" -f $app.DisplayName,$app.Version) -ForegroundColor DarkGray }
            if ($detectedApps.Count -gt $TopApps){ Write-Host ("    ... +{0} more" -f ($detectedApps.Count - $TopApps)) -ForegroundColor DarkGray }
        }
        if ($groups){ Write-Host "`n=== GROUP MEMBERSHIPS ({0}) ===" -f $groups.Count -ForegroundColor Yellow; foreach($g in ($groups|Sort-Object|Select-Object -First 25)){ Write-Host "  - $g" -ForegroundColor DarkGray }; if($groups.Count -gt 25){ Write-Host "    ... +$($groups.Count-25) more" -ForegroundColor DarkGray } }
        if ($autopilot){ Write-Host "`n=== AUTOPILOT ===" -ForegroundColor Yellow; Write-Host ("  Serial: {0} | Profile: {1} | GroupTag: {2}" -f $autopilot.SerialNumber,$autopilot.DeploymentProfileDisplayName,$autopilot.GroupTag) }
    }

    # Detailed enhanced sections ONLY for Detailed level
    if ($DiagnosticLevel -eq 'Detailed') {
        # Compliance (with failing settings inline)
        if ($compliancePolicies){
            Write-Host "`n=== COMPLIANCE POLICIES (Detailed) ===" -ForegroundColor Yellow
            foreach($pol in $compliancePolicies){
                $icon = switch($pol.State){ 'compliant'{'✅'} 'nonCompliant'{'❌'} 'unknown'{'❓'} 'notApplicable'{'⊘'} default{'❓'} }
                Write-Host ("  $icon {0} [{1}]" -f $pol.DisplayName,$pol.State)
                if ($pol.State -eq 'nonCompliant' -and $complianceSettingMap.ContainsKey($pol.Id)){
                    foreach($s in ($complianceSettingMap[$pol.Id] | Where-Object {$_.State -ne 'compliant'})){
                        Write-Host ("     - {0}: Current='{1}' State={2}" -f $s.Setting,$s.CurrentValue,$s.State) -ForegroundColor Red
                    }
                }
            }
        }
        # Configuration profiles (with error details)
        if ($configStates){
            Write-Host "`n=== CONFIGURATION PROFILES ===" -ForegroundColor Yellow
            foreach($cfg in $configStates){
                $icon = switch($cfg.State){ 'compliant'{'✅'} 'conflict'{'⚠️'} 'error'{'❌'} 'notApplicable'{'⊘'} default{'❓'} }
                Write-Host ("  $icon {0} [{1}]" -f $cfg.DisplayName,$cfg.State)
                if ($cfg.State -eq 'error' -and $cfg.StateDetails){ Write-Host ("     Error: {0}" -f $cfg.StateDetails) -ForegroundColor Red }
                if ($configSettingMap.ContainsKey($cfg.Id)){
                    foreach($st in ($configSettingMap[$cfg.Id] | Where-Object {$_.State -in 'error','conflict'})){
                        Write-Host ("     - {0}: Current='{1}' State={2}" -f $st.Setting,$st.CurrentValue,$st.State) -ForegroundColor (if($st.State -eq 'error'){'Red'}else{'Yellow'})
                    }
                }
            }
        }
        # Detected applications (Top 25 with size info)
        Write-Host "`n=== DETECTED APPLICATIONS ===" -ForegroundColor Yellow
        try {
            $detTop = $detectedApps | Sort-Object DisplayName | Select-Object -First 25
            if ($detTop){
                foreach($app in $detTop){
                    $sizeInfo = if ($app.SizeInByte -gt 0) { " ($('{0:N1}' -f ($app.SizeInByte/1MB)) MB)" } else { '' }
                    $ver = if($app.Version){ " v$($app.Version)" } else { '' }
                    Write-Host ("  • {0}{1}{2}" -f $app.DisplayName,$ver,$sizeInfo)
                }
                if ($detectedApps.Count -gt 25){ Write-Host '  ... and more (showing top 25)' -ForegroundColor Gray }
            } else { Write-Host '  No applications detected' -ForegroundColor Gray }
        } catch { Write-Host '  Could not retrieve application list' -ForegroundColor Gray }

        # Hardware details
        Write-Host "`n=== HARDWARE INFORMATION ===" -ForegroundColor Cyan
        Write-Host ("  Serial Number: {0}" -f $device.SerialNumber)
        if ($device.TotalStorageSpaceInBytes){
            $totGB = '{0:N1}' -f ($device.TotalStorageSpaceInBytes/1GB)
            $freeGB = '{0:N1}' -f ($device.FreeStorageSpaceInBytes/1GB)
            $pctFree = if($device.TotalStorageSpaceInBytes){ '{0:P0}' -f ($device.FreeStorageSpaceInBytes/$device.TotalStorageSpaceInBytes) } else { 'N/A' }
            Write-Host "  Total Storage: $totGB GB"
            Write-Host "  Free Storage: $freeGB GB ($pctFree free)"
        }
        # Precompute values to avoid inline 'if' inside format (compat with Windows PowerShell)
        $physMemDisplay = if ($device.PhysicalMemoryInBytes) { '{0:N1} GB' -f ($device.PhysicalMemoryInBytes/1GB) } else { 'N/A' }
        $wifiMacDisplay = if ($device.WiFiMacAddress) { $device.WiFiMacAddress } else { 'N/A' }
        Write-Host ("  Physical Memory: {0}" -f $physMemDisplay)
        Write-Host ("  WiFi MAC: {0}" -f $wifiMacDisplay)
        Write-Host ("  Enrolled: {0}" -f $device.EnrolledDateTime)
        Write-Host ("  Managed By: {0}" -f $device.ManagementAgent)
        Write-Host ("  Ownership: {0}" -f $device.ManagedDeviceOwnerType)

        # AAD Device Info (detailed)
        if ($device.AzureAdDeviceId) {
            Write-Host "`n=== AZURE AD INFORMATION ===" -ForegroundColor Blue
            try {
                $aadDeviceDtl = Get-MgDevice -Filter "deviceId eq '$($device.AzureAdDeviceId)'" -ErrorAction SilentlyContinue
                if ($aadDeviceDtl) {
                    Write-Host ("  Display Name: {0}" -f $aadDeviceDtl.DisplayName)
                    Write-Host ("  Trust Type: {0}" -f $aadDeviceDtl.TrustType)
                    if ($aadDeviceDtl.PSObject.Properties.Name -contains 'AccountEnabled') { Write-Host ("  Enabled: {0}" -f (if($aadDeviceDtl.AccountEnabled){'Yes ✅'}else{'No ❌'})) }
                    $reg = $aadDeviceDtl.AdditionalProperties.registrationDateTime
                    if ($reg){ Write-Host ("  Registered: {0}" -f $reg) }
                    try {
                        $aadGroups = Get-MgDeviceMemberOf -DeviceId $aadDeviceDtl.Id -ErrorAction SilentlyContinue
                        if ($aadGroups){ Write-Host '  Groups:' -ForegroundColor Yellow; foreach($g in $aadGroups){ $dn=$g.AdditionalProperties.displayName; if($dn){ Write-Host "    - $dn" } } }
                    } catch {}
                }
            } catch { Write-Verbose 'Could not retrieve Azure AD information' }
        }

        # Recent device actions
        Write-Host "`n=== RECENT ACTIONS (Last 30 days) ===" -ForegroundColor Magenta
        if ($deviceActions){
            $deviceActions | Sort-Object lastUpdatedDateTime -Descending | Select-Object -First 10 | ForEach-Object { Write-Host ("  {0}: {1} - {2}" -f $_.lastUpdatedDateTime,$_.actionName,$_.actionState) }
        } else { Write-Host '  No recent device actions' -ForegroundColor Gray }

        # Detailed recommendations (augmentation)
        Write-Host "`n=== RECOMMENDED ACTIONS ===" -ForegroundColor Green
        $detailedRecs=@()
        # duplicate policies
        $dupPol = $compliancePolicies | Group-Object DisplayName | Where-Object Count -gt 1
        if ($dupPol){ $detailedRecs += '📋 Review and clean up duplicate compliance policies.' }
        if ($syncHours -is [double]){ if ($syncHours -gt 24){ $detailedRecs += "🔄 Device hasn't synced in $syncHours hours – trigger manual sync." } elseif ($syncHours -gt 8){ $detailedRecs += "🔄 Consider asking user to sync (last sync $syncHours h)." } }
        if ($device.FreeStorageSpaceInBytes -and $device.TotalStorageSpaceInBytes){ $freePct = $device.FreeStorageSpaceInBytes / $device.TotalStorageSpaceInBytes; if ($freePct -lt 0.10){ $detailedRecs += '💾 Critical: <10% disk free – cleanup immediately.' } elseif ($freePct -lt 0.20){ $detailedRecs += '💾 Warning: <20% disk free – plan cleanup.' } }
        $unknownPolicies = $compliancePolicies | Where-Object { $_.State -in 'unknown','notApplicable' }
        $wrongPlatform = $unknownPolicies | Where-Object { $_.DisplayName -match 'iOS|Android|Cloud PC|macOS' }
        if ($wrongPlatform){ $detailedRecs += '🎯 Remove device from groups targeting non-Windows policies.' }
        if (-not $device.IsEncrypted){ $detailedRecs += '🔒 Enable and enforce BitLocker encryption.' }
        if (-not $detailedRecs){ Write-Host '  ✅ No immediate actions required' -ForegroundColor Green } else { foreach($r in $detailedRecs){ Write-Host "  $r" } }

        # Summary
        Write-Host "`n=== DIAGNOSTIC SUMMARY ===" -ForegroundColor White
        Write-Host ("  Total Issues Found: {0}" -f $issues.Count)
        Write-Host ("  Compliance State: {0}" -f $device.ComplianceState)
        $health = if ($issues.Count -eq 0){'✅ Healthy'} elseif ($issues.Count -le 2){'⚠️ Minor Issues'} else {'❌ Needs Attention'}
        Write-Host ("  Device Health: {0}" -f $health)
    }

    # Recommendations (legacy flag) for Advanced only (Detailed has its own enhanced block above if ShowRemediation)
    if ($ShowRemediation -and $DiagnosticLevel -eq 'Advanced'){ Write-Host "`n=== RECOMMENDATIONS ===" -ForegroundColor Green; foreach($r in $recommendations){ Write-Host "  $r" } }

    # JSON Export (include deviceActions when Detailed)
    if ($OutputPath){
        if (-not (Test-Path $OutputPath)){ New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
        $safe = $device.DeviceName -replace '[^A-Za-z0-9._-]','_'
        $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
        $bundle = [ordered]@{
            Device = $device
            CompliancePolicies = $compliancePolicies
            ComplianceSettings = if($DiagnosticLevel -eq 'Detailed'){ $complianceSettingMap.GetEnumerator() | ForEach-Object { [pscustomobject]@{ PolicyStateId=$_.Key; Settings=$_.Value } } } else { @() }
            ConfigProfiles = $configStates
            ConfigSettings = if($DiagnosticLevel -eq 'Detailed'){ $configSettingMap.GetEnumerator() | ForEach-Object { [pscustomobject]@{ ConfigStateId=$_.Key; Settings=$_.Value } } } else { @() }
            DetectedApps = $detectedApps
            Groups = $groups
            Category = $category
            Autopilot = $autopilot
            Protection = $protection
            AadDevice = $aadDevice
            Audit = $audit
            LogCollections = $logCollections
            DeviceActions = $deviceActions
            Issues = $issues
            Recommendations = if($DiagnosticLevel -eq 'Detailed'){ $detailedRecs } else { $recommendations }
            Generated = (Get-Date).ToString('o')
            Level = $DiagnosticLevel
        }
        $bundle | ConvertTo-Json -Depth 14 | Out-File -FilePath (Join-Path $OutputPath "DeviceDiag_${safe}_$ts.json") -Encoding UTF8
        Write-IntuneLog "Exported JSON -> $OutputPath" -Level Success
    }
}

$elapsed = (Get-Date) - $script:startTime
Write-IntuneLog ("Completed in {0}s" -f [int]$elapsed.TotalSeconds) -Level Success
if ($Disconnect){ Disconnect-MgGraph | Out-Null }
