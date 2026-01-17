<#
.SYNOPSIS
    Detection script for Intune Win32 app.

.DESCRIPTION
    Checks if the BitLocker disable scheduled task exists.
    Exit 0 = installed, Exit 1 = not installed

.NOTES
    Use as detection rule in Intune Win32 app configuration.
#>

$TaskName = "Disable-BitLocker"

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

if ($task) {
    Write-Host "Found: $TaskName"
    exit 0
}
else {
    exit 1
}
