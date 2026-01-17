<#
.SYNOPSIS
    Intune & Azure AD stale device lifecycle management and cleanup tool.

.DESCRIPTION
    Identifies and (optionally) retires or deletes stale / orphaned / duplicate / failed enrollment
    devices from Microsoft Intune (managedDevices) and Azure AD (device directory objects).

    Safety focused: honours WhatIf / Confirm, supports exclusion lists, device caps per run,
    pre-action backup export, detailed reports (candidates, actions, skipped) and optional rollback helper.

    Rollback limitations: Intune retire / delete operations and Azure AD device deletions are not fully
    reversible. The backup produced can help with investigations or (if still in soft-delete) manual restore.

.NOTES
    File Name      : Invoke-StaleDeviceCleanup.ps1
    Author         : Haakon Wibe
    Prerequisite   : Microsoft Graph PowerShell SDK
    License        : MIT
    Version        : 0.2

.PARAMETER StaleDays
    Number of days since last Intune sync to qualify as stale (default 90).

.PARAMETER Action
    Cleanup action to perform: Export (no change), Retire (managed devices), Delete (Intune + optionally AAD).

.PARAMETER MaxDevices
    Maximum number of devices to act on in a single run (safety cap, default 50).

.PARAMETER ExclusionListPath
    Optional CSV containing columns: DeviceId, AzureAdDeviceId, SerialNumber, DeviceName. Any match excludes.

.PARAMETER IncludeAzureAD
    Include Azure AD device objects (directory devices) in stale evaluation & deletion (Delete action only).

.PARAMETER OutputPath
    Folder to write reports & logs. Created if absent.

.PARAMETER BackupPath
    Folder for backup JSON prior to destructive actions (Delete / Retire). Created if absent.

.PARAMETER DuplicateThreshold
    Number of devices per user beyond which older duplicates are flagged (default 5).

.PARAMETER Rollback
    Attempts rollback using a prior backup file (see -BackupFile). Only metadata restore helper; does NOT
    undelete devices automatically.

.PARAMETER BackupFile
    Path to a previously generated backup JSON file used for rollback assistance.

.PARAMETER Disconnect
    Disconnect Microsoft Graph at end.

.EXAMPLE
    # Preview candidates only (recommended first run)
    ./Invoke-StaleDeviceCleanup.ps1 -WhatIf

.EXAMPLE
    # Retire stale devices (last sync > 120 days) with exclusion list
    ./Invoke-StaleDeviceCleanup.ps1 -StaleDays 120 -Action Retire -ExclusionListPath ./sample-exclusion-list.csv -Verbose

.EXAMPLE
    # Delete (hard) stale + orphaned devices including Azure AD directory objects (max 20 devices)
    ./Invoke-StaleDeviceCleanup.ps1 -Action Delete -MaxDevices 20 -IncludeAzureAD -Confirm

.EXAMPLE
    # Generate reports only (export mode)
    ./Invoke-StaleDeviceCleanup.ps1 -Action Export -OutputPath ./reports

#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter()] [int]$StaleDays = 90,
    [Parameter()] [ValidateSet('Export','Retire','Delete')] [string]$Action = 'Export',
    [Parameter()] [int]$MaxDevices = 50,
    [Parameter()] [string]$ExclusionListPath,
    [Parameter()] [switch]$IncludeAzureAD,
    [Parameter()] [string]$OutputPath = '.',
    [Parameter()] [string]$BackupPath = './backups',
    [Parameter()] [int]$DuplicateThreshold = 5,
    [Parameter()] [switch]$Rollback,
    [Parameter()] [string]$BackupFile,
    [Parameter()] [switch]$Disconnect
)

#region Helper Functions
function Write-LogMessage {
    param(
        [string]$Message = '',
        [ValidateSet('Info','Warning','Error','Success','Debug')] [string]$Level = 'Info'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = switch($Level){ 'Info'{'White'} 'Warning'{'Yellow'} 'Error'{'Red'} 'Success'{'Green'} 'Debug'{'Cyan'} default{'White'} }
    if ([string]::IsNullOrWhiteSpace($Message)) { Write-Host ''; Write-Verbose '[NEWLINE]'; return }
    Write-Host "[$ts] $Message" -ForegroundColor $color
    Write-Verbose "[$Level] $Message"
}

function Import-ExclusionList {
    param([string]$Path)
    if (-not $Path) { return @() }
    if (-not (Test-Path $Path)) { Write-LogMessage "Exclusion list not found: $Path" -Level Warning; return @() }
    try {
        $csv = Import-Csv -Path $Path
        Write-LogMessage "Loaded exclusion list entries: $($csv.Count)" -Level Info
        return $csv
    } catch {
        Write-LogMessage "Failed to load exclusion list: $_" -Level Error
        return @()
    }
}

function Test-IsExcluded {
    param(
        [object]$Device,
        [array]$Exclusions
    )
    if (-not $Exclusions -or $Exclusions.Count -eq 0) { return $false }
    foreach($ex in $Exclusions){
        if (($ex.DeviceId -and $ex.DeviceId -eq $Device.Id) -or
            ($ex.AzureAdDeviceId -and $ex.AzureAdDeviceId -eq $Device.AzureAdDeviceId) -or
            ($ex.SerialNumber -and $ex.SerialNumber -eq $Device.SerialNumber) -or
            ($ex.DeviceName -and $ex.DeviceName -eq $Device.DeviceName)) { return $true }
    }
    return $false
}

function Backup-Devices {
    param(
        [array]$Devices,
        [string]$Path,
        [string]$Action
    )
    if (-not $Devices -or $Devices.Count -eq 0) { return $null }
    if (-not (Test-Path $Path)) { New-Item -Path $Path -ItemType Directory -Force | Out-Null }
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $file = Join-Path $Path "StaleDeviceBackup-$Action-$timestamp.json"
    try {
        $Devices | ConvertTo-Json -Depth 10 | Out-File -FilePath $file -Encoding UTF8
        Write-LogMessage "Backup saved: $file" -Level Success
        return $file
    } catch {
        Write-LogMessage "Failed to write backup: $_" -Level Error
        return $null
    }
}

function Load-BackupFile {
    param([string]$File)
    if (-not $File) { throw 'Backup file path not provided.' }
    if (-not (Test-Path $File)) { throw "Backup file not found: $File" }
    try { return Get-Content -Raw -Path $File | ConvertFrom-Json } catch { throw "Failed to parse backup file: $_" }
}

function Get-ManagedDevices {
    Write-LogMessage 'Retrieving Intune managed devices...' -Level Info
    try { return Get-MgDeviceManagementManagedDevice -All -ErrorAction Stop } catch { throw "Failed to retrieve managed devices: $_" }
}

function Get-AzureAdDevices {
    Write-LogMessage 'Retrieving Azure AD devices...' -Level Info
    try { return Get-MgDevice -All -ErrorAction Stop } catch { throw "Failed to retrieve Azure AD devices: $_" }
}

function Classify-StaleDevices {
    param(
        [array]$ManagedDevices,
        [array]$DirectoryDevices,
        [int]$StaleDays,
        [int]$DuplicateThreshold
    )
    $now = Get-Date
    $staleThreshold = $now.AddDays(-$StaleDays)

    $results = @()

    # 1. Last sync stale
    foreach($d in $ManagedDevices){
        $lastSync = $d.LastSyncDateTime
        $isNever = -not $lastSync
        $isStale = $isNever -or ($lastSync -lt $staleThreshold)
        if ($isStale){
            $results += [PSCustomObject]@{
                Source = 'Intune'
                Id = $d.Id
                AzureAdDeviceId = $d.AzureAdDeviceId
                DeviceName = $d.DeviceName
                UserPrincipalName = $d.UserPrincipalName
                SerialNumber = $d.SerialNumber
                LastSync = if($lastSync){ $lastSync.ToString('u') } else { 'Never' }
                ReasonCodes = @('LastSyncStale')
                Reasons = "Last sync older than $StaleDays days" + ($(if($isNever){' (Never)'} else {''}))
                RecommendedAction = 'Retire/Delete'
                EnrollmentState = $d.EnrollmentState
                OperatingSystem = $d.OperatingSystem
                ManagementAgent = $d.ManagementAgent
                DuplicateGroupKey = ($d.UserPrincipalName + '|' + $d.OperatingSystem + '|' + ($d.DeviceName -replace '\d+$',''))
                Raw = $d
            }
        }
    }

    # 2. Failed / pending enrollment
    foreach($d in $ManagedDevices){
        if ($d.EnrollmentState -in @('failed','notContacted') -or ($d.ManagementAgent -eq 'unknown')){
            if (-not ($results | Where-Object Id -eq $d.Id)){
                $results += [PSCustomObject]@{
                    Source = 'Intune'
                    Id = $d.Id
                    AzureAdDeviceId = $d.AzureAdDeviceId
                    DeviceName = $d.DeviceName
                    UserPrincipalName = $d.UserPrincipalName
                    SerialNumber = $d.SerialNumber
                    LastSync = if($d.LastSyncDateTime){ $d.LastSyncDateTime.ToString('u') } else { 'Never' }
                    ReasonCodes = @('FailedEnrollment')
                    Reasons = 'Failed or unreachable enrollment state'
                    RecommendedAction = 'Delete'
                    EnrollmentState = $d.EnrollmentState
                    OperatingSystem = $d.OperatingSystem
                    ManagementAgent = $d.ManagementAgent
                    DuplicateGroupKey = ($d.UserPrincipalName + '|' + $d.OperatingSystem + '|' + ($d.DeviceName -replace '\d+$',''))
                    Raw = $d
                }
            } else {
                # Append reason
                ($results | Where-Object Id -eq $d.Id).ReasonCodes += 'FailedEnrollment'
            }
        }
    }

    # 3. Orphaned (no user)
    foreach($d in $ManagedDevices){
        if (-not $d.UserPrincipalName){
            if (-not ($results | Where-Object Id -eq $d.Id)){
                $results += [PSCustomObject]@{
                    Source = 'Intune'
                    Id = $d.Id
                    AzureAdDeviceId = $d.AzureAdDeviceId
                    DeviceName = $d.DeviceName
                    UserPrincipalName = ''
                    SerialNumber = $d.SerialNumber
                    LastSync = if($d.LastSyncDateTime){ $d.LastSyncDateTime.ToString('u') } else { 'Never' }
                    ReasonCodes = @('NoUser')
                    Reasons = 'No associated user'
                    RecommendedAction = 'Delete'
                    EnrollmentState = $d.EnrollmentState
                    OperatingSystem = $d.OperatingSystem
                    ManagementAgent = $d.ManagementAgent
                    DuplicateGroupKey = ($d.UserPrincipalName + '|' + $d.OperatingSystem + '|' + ($d.DeviceName -replace '\d+$',''))
                    Raw = $d
                }
            } else {
                ($results | Where-Object Id -eq $d.Id).ReasonCodes += 'NoUser'
            }
        }
    }

    # 4. Duplicate registrations (by user + OS + normalized name root) beyond threshold
    $groups = $ManagedDevices | Where-Object UserPrincipalName | ForEach-Object {
        $_ | Add-Member -NotePropertyName DuplicateGroupKey -NotePropertyValue ($_.UserPrincipalName + '|' + $_.OperatingSystem + '|' + ($_.DeviceName -replace '\d+$','')) -PassThru
    } | Group-Object DuplicateGroupKey

    foreach($g in $groups){
        if ($g.Count -gt $DuplicateThreshold){
            # Order by LastSync descending keep newest N
            $ordered = $g.Group | Sort-Object -Property LastSyncDateTime -Descending
            $extras = $ordered[$DuplicateThreshold..($ordered.Count-1)]
            foreach($d in $extras){
                if (-not ($results | Where-Object Id -eq $d.Id)){
                    $results += [PSCustomObject]@{
                        Source = 'Intune'
                        Id = $d.Id
                        AzureAdDeviceId = $d.AzureAdDeviceId
                        DeviceName = $d.DeviceName
                        UserPrincipalName = $d.UserPrincipalName
                        SerialNumber = $d.SerialNumber
                        LastSync = if($d.LastSyncDateTime){ $d.LastSyncDateTime.ToString('u') } else { 'Never' }
                        ReasonCodes = @('DuplicateRegistration')
                        Reasons = "Duplicate registration beyond threshold ($DuplicateThreshold)"
                        RecommendedAction = 'Delete'
                        EnrollmentState = $d.EnrollmentState
                        OperatingSystem = $d.OperatingSystem
                        ManagementAgent = $d.ManagementAgent
                        DuplicateGroupKey = $d.DuplicateGroupKey
                        Raw = $d
                    }
                } else {
                    ($results | Where-Object Id -eq $d.Id).ReasonCodes += 'DuplicateRegistration'
                }
            }
        }
    }

    # For Azure AD devices (if provided) only add those with no Intune match and very old last activity (approx using ApproximateLastSignInDateTime or device trust time)
    foreach($aad in $DirectoryDevices){
        if (-not ($ManagedDevices | Where-Object { $_.AzureAdDeviceId -eq $aad.Id })){
            # Some device objects expose ApproximateLastSignInDateTime (Graph Beta sometimes). We'll use extension if available; else CreatedDateTime.
            $candidateLast = $aad.ApproximateLastSignInDateTime
            if (-not $candidateLast){ $candidateLast = $aad.DeviceRegistrationDateTime }
            if (-not $candidateLast){ $candidateLast = $aad.CreatedDateTime }
            if (-not $candidateLast -or $candidateLast -lt $staleThreshold){
                $results += [PSCustomObject]@{
                    Source = 'AzureAD'
                    Id = $aad.Id
                    AzureAdDeviceId = $aad.Id
                    DeviceName = $aad.DisplayName
                    UserPrincipalName = ''
                    SerialNumber = $aad.SerialNumber
                    LastSync = if($candidateLast){ $candidateLast.ToString('u') } else { 'Unknown' }
                    ReasonCodes = @('DirectoryStale')
                    Reasons = "Directory object stale (no managed device, last activity older than $StaleDays days)"
                    RecommendedAction = 'Delete'
                    EnrollmentState = ''
                    OperatingSystem = $aad.OperatingSystem
                    ManagementAgent = ''
                    DuplicateGroupKey = ''
                    Raw = $aad
                }
            }
        }
    }

    # Consolidate reasons (deduplicate ReasonCodes)
    foreach($r in $results){ $r.ReasonCodes = ($r.ReasonCodes | Select-Object -Unique); if (-not $r.Reasons -and $r.ReasonCodes){ $r.Reasons = ($r.ReasonCodes -join ', ') } }
    return $results
}

function Generate-Reports {
    param(
        [array]$Candidates,
        [array]$Planned,
        [array]$Skipped,
        [string]$OutputPath
    )
    if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $pre = Join-Path $OutputPath "StaleDevices-Candidates-$ts.csv"
    $act = Join-Path $OutputPath "StaleDevices-Actions-$ts.csv"
    $skp = Join-Path $OutputPath "StaleDevices-Skipped-$ts.csv"
    try {
        $Candidates | Export-Csv -NoTypeInformation -Path $pre -Encoding UTF8
        $Planned | Export-Csv -NoTypeInformation -Path $act -Encoding UTF8
        $Skipped | Export-Csv -NoTypeInformation -Path $skp -Encoding UTF8
        Write-LogMessage "Reports exported: `n  Candidates: $pre`n  Actions:    $act`n  Skipped:    $skp" -Level Success
    } catch {
        Write-LogMessage "Failed to export reports: $_" -Level Error
    }
}

function Perform-Action {
    param(
        [object]$Device,
        [string]$Action
    )
    $source = $Device.Source
    switch($Action){
        'Retire' {
            if ($source -eq 'Intune'){
                if ($PSCmdlet.ShouldProcess($Device.DeviceName, 'Retire Intune managed device')){
                    try {
                        Invoke-MgDeviceManagementManagedDeviceRetire -ManagedDeviceId $Device.Id -ErrorAction Stop
                        return 'Retired'
                    } catch { Write-LogMessage "Retire failed for $($Device.DeviceName): $_" -Level Error; return 'RetireFailed' }
                } else { return 'RetireSkipped' }
            } else { return 'NotApplicable' }
        }
        'Delete' {
            if ($source -eq 'Intune'){
                if ($PSCmdlet.ShouldProcess($Device.DeviceName, 'Delete Intune managed device')){
                    try {
                        Remove-MgDeviceManagementManagedDevice -ManagedDeviceId $Device.Id -ErrorAction Stop
                        return 'IntuneDeleted'
                    } catch { Write-LogMessage "Intune delete failed for $($Device.DeviceName): $_" -Level Error; return 'IntuneDeleteFailed' }
                } else { return 'DeleteSkipped' }
            } elseif ($source -eq 'AzureAD') {
                if ($PSCmdlet.ShouldProcess($Device.DeviceName, 'Delete Azure AD device object')){
                    try {
                        Remove-MgDevice -DeviceId $Device.Id -ErrorAction Stop
                        return 'AzureADDeleted'
                    } catch { Write-LogMessage "AAD delete failed for $($Device.DeviceName): $_" -Level Error; return 'AADDeleteFailed' }
                } else { return 'DeleteSkipped' }
            }
        }
        default { return 'ExportOnly' }
    }
}
#endregion

#region Rollback Mode
if ($Rollback){
    Write-LogMessage '=== Rollback Mode ===' -Level Warning
    try {
        $backup = Load-BackupFile -File $BackupFile
        Write-LogMessage "Loaded backup with $($backup.Count) devices." -Level Info
        Write-LogMessage 'NOTE: Automated rollback of deleted / retired devices is not supported. Use backup metadata for manual recreation or auditing.' -Level Warning
        $out = Join-Path $OutputPath ("Rollback-Metadata-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
        $backup | Select-Object Source,Id,AzureAdDeviceId,DeviceName,UserPrincipalName,SerialNumber,LastSync,ReasonCodes,Reasons,RecommendedAction | Export-Csv -NoTypeInformation -Path $out -Encoding UTF8
        Write-LogMessage "Rollback metadata exported: $out" -Level Success
    } catch {
        Write-LogMessage "Rollback failed: $_" -Level Error
        throw
    }
    if ($Disconnect){ Write-LogMessage 'Disconnecting Microsoft Graph...' -Level Info; Disconnect-MgGraph; Write-LogMessage 'Disconnected.' -Level Success }
    return
}
#endregion

#region Preparation & Connection
Write-LogMessage '=== Intune Stale Device Cleanup ===' -Level Success
Write-LogMessage "Action: $Action | StaleDays: $StaleDays | MaxDevices: $MaxDevices | IncludeAzureAD: $IncludeAzureAD" -Level Info

if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $BackupPath)) { New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null }

$exclusions = Import-ExclusionList -Path $ExclusionListPath

# Import toolkit & connect using Standard permission set (write operations required)
try {
    $toolkitPath = Join-Path $PSScriptRoot '../../modules/IntuneToolkit/IntuneToolkit.psm1'
    if (-not (Test-Path $toolkitPath)) { throw "IntuneToolkit module not found at $toolkitPath" }
    Import-Module $toolkitPath -Force -ErrorAction Stop
    Connect-IntuneGraph -PermissionLevel Standard -Quiet:$false | Out-Null
    Write-LogMessage 'Connected via IntuneToolkit (Standard permission set).' -Level Success
} catch { Write-LogMessage "Failed to import/connect IntuneToolkit: $_" -Level Error; throw }
#endregion

#region Data Retrieval
$managedDevices = Get-ManagedDevices
$aadDevices = @()
if ($IncludeAzureAD -or $Action -eq 'Delete'){ $aadDevices = Get-AzureAdDevices }

Write-LogMessage "Managed devices: $($managedDevices.Count) | AAD devices: $($aadDevices.Count)" -Level Info
#endregion

#region Classification
Write-LogMessage 'Classifying stale devices...' -Level Info
$candidates = Classify-StaleDevices -ManagedDevices $managedDevices -DirectoryDevices ($IncludeAzureAD ? $aadDevices : @()) -StaleDays $StaleDays -DuplicateThreshold $DuplicateThreshold

if (-not $candidates -or $candidates.Count -eq 0){ Write-LogMessage 'No stale device candidates identified.' -Level Success; if ($Disconnect){ Disconnect-MgGraph }; return }

# Attach consolidated reason text
foreach($c in $candidates){ $c | Add-Member -NotePropertyName ReasonSummary -NotePropertyValue ($c.ReasonCodes -join '; ') -Force }

Write-LogMessage "Total candidates identified: $($candidates.Count)" -Level Success
#endregion

#region Exclusions & Planning
$planned = @()
$skipped = @()

$idx = 0
foreach($c in $candidates){
    $idx++
    if ($idx % 50 -eq 0 -or $idx -eq $candidates.Count){ Write-Progress -Activity 'Evaluating candidates' -Status "$idx / $($candidates.Count)" -PercentComplete (($idx / $candidates.Count)*100) }

    if (Test-IsExcluded -Device $c -Exclusions $exclusions){
        $skipped += ($c | Select-Object *, @{n='SkipReason';e={'Excluded'}})
        continue
    }
    if ($planned.Count -ge $MaxDevices){
        $skipped += ($c | Select-Object *, @{n='SkipReason';e={'MaxDevicesReached'}})
        continue
    }
    if ($Action -eq 'Retire' -and $c.Source -ne 'Intune'){
        $skipped += ($c | Select-Object *, @{n='SkipReason';e={'RetireNotApplicable'}})
        continue
    }
    $planned += ($c | Select-Object *)
}
Write-Progress -Activity 'Evaluating candidates' -Completed

Write-LogMessage "Planned actions: $($planned.Count) | Skipped: $($skipped.Count)" -Level Info
if ($planned.Count -eq 0){ Write-LogMessage 'Nothing to do after exclusions & limits.' -Level Warning; Generate-Reports -Candidates $candidates -Planned $planned -Skipped $skipped -OutputPath $OutputPath; if ($Disconnect){ Disconnect-MgGraph }; return }
#endregion

#region Backup
$backupFile = $null
if ($Action -in @('Retire','Delete')){
    $backupFile = Backup-Devices -Devices $planned -Path $BackupPath -Action $Action
    if (-not $backupFile){ Write-LogMessage 'Backup failed or not created; aborting for safety.' -Level Error; return }
}
#endregion

#region Execution
if ($Action -eq 'Export'){
    Write-LogMessage 'Export mode selected - no changes will be made.' -Level Warning
} else {
    Write-LogMessage "Executing $Action operations..." -Level Info
    $counter = 0
    foreach($p in $planned){
        $counter++
        Write-Progress -Activity "$Action devices" -Status "$counter / $($planned.Count)" -PercentComplete (($counter / $planned.Count) * 100)
        $result = Perform-Action -Device $p -Action $Action
        $p | Add-Member -NotePropertyName ActionResult -NotePropertyValue $result -Force
    }
    Write-Progress -Activity "$Action devices" -Completed
    $success = ($planned | Where-Object { $_.ActionResult -match 'Retired|Deleted' }).Count
    Write-LogMessage "$Action operations complete. Success count (rough): $success" -Level Success
}
#endregion

#region Reporting
Generate-Reports -Candidates $candidates -Planned $planned -Skipped $skipped -OutputPath $OutputPath

# Summary
Write-LogMessage ''
Write-LogMessage '=== Cleanup Summary ===' -Level Success
Write-LogMessage "Candidates total: $($candidates.Count)" -Level Info
Write-LogMessage "Planned actions:  $($planned.Count)" -Level Info
Write-LogMessage "Skipped:          $($skipped.Count)" -Level Info
if ($backupFile){ Write-LogMessage "Backup file:     $backupFile" -Level Info }
Write-LogMessage "Reports folder:  $OutputPath" -Level Info
Write-LogMessage "Action mode:     $Action" -Level Info

if ($WhatIf){ Write-LogMessage 'NOTE: -WhatIf was used; destructive actions would have been simulated only.' -Level Warning }
#endregion

#region Disconnect
if ($Disconnect){ Write-LogMessage 'Disconnecting Microsoft Graph...' -Level Info; Disconnect-MgGraph; Write-LogMessage 'Disconnected from Microsoft Graph.' -Level Success }
#endregion
