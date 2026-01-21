<#
.SYNOPSIS
    Detection script for regional settings Win32 app deployment.

.DESCRIPTION
    Checks if the marker file exists from a successful installation.

.NOTES
    Author  : Haakon Wibe
    License : MIT
    Context : Used as Intune Win32 app detection rule (script).
#>

$MarkerFile = "C:\ProgramData\IntuneTools\RegionalSettings.installed"

if (Test-Path $MarkerFile) {
    Write-Host "Regional settings installed: $MarkerFile exists"
    exit 0  # Detected
}
else {
    Write-Host "Regional settings not installed: $MarkerFile not found"
    exit 1  # Not detected
}
