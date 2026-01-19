<#
.SYNOPSIS
    Removes the BitLocker disable shortcut and associated components.

.DESCRIPTION
    Uninstall script for Intune Win32 app. Removes:
    - Scheduled task
    - Desktop shortcut
    - Scripts folder (optional - keeps logs by default)

.NOTES
    Author  : Haakon Wibe
    License : MIT
    Context : Run as SYSTEM via Intune.
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

# Remove shortcut from Public Desktop
$publicShortcut = "C:\Users\Public\Desktop\$ShortcutName"
if (Test-Path $publicShortcut) {
    Remove-Item $publicShortcut -Force
    Write-Host "Removed shortcut from Public Desktop"
}

# Remove shortcut from all user desktops (handles OneDrive Known Folder Move)
$userProfiles = Get-ChildItem "C:\Users" -Directory | Where-Object { $_.Name -notin @('Public', 'Default', 'Default User') }
foreach ($profile in $userProfiles) {
    $desktopPaths = @()

    # Try to get actual desktop path from user's registry
    try {
        $userAccount = New-Object System.Security.Principal.NTAccount("$env:COMPUTERNAME\$($profile.Name)")
        $userSID = $userAccount.Translate([System.Security.Principal.SecurityIdentifier]).Value
        $regPath = "Registry::HKU\$userSID\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
        $desktopValue = (Get-ItemProperty -Path $regPath -Name "Desktop" -ErrorAction Stop).Desktop
        $actualDesktop = [Environment]::ExpandEnvironmentVariables($desktopValue)
        $desktopPaths += $actualDesktop
    }
    catch {
        # Registry not accessible, continue with default path
    }

    # Also check default desktop path
    $desktopPaths += Join-Path $profile.FullName "Desktop"

    # Remove shortcut from all possible desktop locations
    foreach ($desktop in ($desktopPaths | Select-Object -Unique)) {
        $shortcutPath = Join-Path $desktop $ShortcutName
        if (Test-Path $shortcutPath) {
            Remove-Item $shortcutPath -Force
            Write-Host "Removed shortcut from $shortcutPath"
        }
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
