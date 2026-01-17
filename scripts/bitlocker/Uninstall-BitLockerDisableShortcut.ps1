<#
.SYNOPSIS
    Removes the BitLocker disable shortcut and associated components.

.DESCRIPTION
    Uninstall script for Intune Win32 app. Removes:
    - Scheduled task
    - Desktop shortcut
    - Scripts folder (optional - keeps logs by default)

.NOTES
    Run as SYSTEM context via Intune.
#>

$ErrorActionPreference = "SilentlyContinue"

# Configuration
$ToolsFolder = "C:\ProgramData\IntuneTools"
$TaskName = "Disable-BitLocker"
$ShortcutName = "Disable BitLocker.lnk"

Write-Host "Starting uninstallation..."

# Remove scheduled task
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed scheduled task: $TaskName"
}

# Remove shortcut from all user desktops (in case user profile changed)
$userProfiles = Get-ChildItem "C:\Users" -Directory | Where-Object { $_.Name -notin @('Public', 'Default', 'Default User') }
foreach ($profile in $userProfiles) {
    $shortcutPath = Join-Path $profile.FullName "Desktop\$ShortcutName"
    if (Test-Path $shortcutPath) {
        Remove-Item $shortcutPath -Force
        Write-Host "Removed shortcut from $($profile.Name)'s desktop"
    }
}

# Remove script file but keep logs folder for troubleshooting
$scriptPath = Join-Path $ToolsFolder "Disable-BitLocker.ps1"
if (Test-Path $scriptPath) {
    Remove-Item $scriptPath -Force
    Write-Host "Removed script file"
}

Write-Host "Uninstallation completed"
exit 0
