<#
.SYNOPSIS
    Removes the detection marker and log files for the regional settings Win32 app.

.DESCRIPTION
    Deletes the marker file and log file created by Install-RegionalSettings.ps1
    so that the Intune detection script no longer reports the app as installed.

    Note: This does not revert any regional/language settings that were applied.

.NOTES
    Author  : Haakon Wibe
    License : MIT
    Context : Use as the uninstall command for the Intune Win32 app.
              Uninstall command: powershell.exe -ExecutionPolicy Bypass -File Uninstall-RegionalSettings.ps1
#>

$LogFolder = "C:\ProgramData\IntuneTools"
$MarkerFile = Join-Path $LogFolder "RegionalSettings.installed"
$LogFile = Join-Path $LogFolder "RegionalSettings.log"

Remove-Item -Path $MarkerFile -Force -ErrorAction SilentlyContinue
Remove-Item -Path $LogFile -Force -ErrorAction SilentlyContinue

exit 0
