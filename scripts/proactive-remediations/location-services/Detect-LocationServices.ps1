<#
.SYNOPSIS
    Detects whether the system-wide Location Services toggle is disabled.

.DESCRIPTION
    Checks the CapabilityAccessManager ConsentStore for the location setting.
    When Autopilot skips the OOBE privacy page, Location Services defaults to
    "Deny" for all users, and standard users cannot re-enable it.

    Exit 0 = Compliant (Location Services enabled)
    Exit 1 = Non-compliant (Location Services disabled, remediation needed)

.NOTES
    Use as Detection Script in an Intune Remediation.
    Run as: System
    Reference: Sandy Zeng - https://msendpointmgr.com/2026/02/10/location-services-is-grayed-out/
#>

$registryPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"

try {
    $locationValue = Get-ItemPropertyValue -Path $registryPath -Name "Value" -ErrorAction Stop

    if ($locationValue -eq "Allow") {
        Write-Output "Location Services is enabled. No remediation needed."
        exit 0
    }
    else {
        Write-Output "Location Services is set to '$locationValue'. Remediation needed."
        exit 1
    }
}
catch {
    Write-Output "Unable to read Location Services registry value. Remediation needed. Error: $_"
    exit 1
}
