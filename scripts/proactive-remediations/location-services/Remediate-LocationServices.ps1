<#
.SYNOPSIS
    Enables system-wide Location Services on Windows devices.

.DESCRIPTION
    Uses SystemSettingsAdminFlows.exe to enable the system-wide Location Services
    toggle. This is required on Autopilot-provisioned devices where the OOBE privacy
    page was skipped, causing Location Services to default to disabled.

    No Intune policy, GPO, or registry setting can enable this toggle directly.
    The SystemSettingsAdminFlows.exe utility is the only supported method.

.NOTES
    Use as Remediation Script in an Intune Remediation.
    Run as: System (64-bit)
    Reference: Sandy Zeng - https://msendpointmgr.com/2026/02/10/location-services-is-grayed-out/
#>

$registryPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"

try {
    # Enable Location Services using SystemSettingsAdminFlows
    $process = Start-Process -FilePath "$env:SystemRoot\System32\SystemSettingsAdminFlows.exe" `
        -ArgumentList "SetCamSystemGlobal location 1" `
        -Wait -PassThru -NoNewWindow

    if ($process.ExitCode -ne 0) {
        Write-Output "SystemSettingsAdminFlows.exe returned exit code $($process.ExitCode)."
        exit 1
    }

    # Verify the change took effect
    Start-Sleep -Seconds 2
    $locationValue = Get-ItemPropertyValue -Path $registryPath -Name "Value" -ErrorAction Stop

    if ($locationValue -eq "Allow") {
        Write-Output "Location Services successfully enabled."
        exit 0
    }
    else {
        Write-Output "Location Services is still set to '$locationValue' after remediation."
        exit 1
    }
}
catch {
    Write-Output "Remediation failed. Error: $_"
    exit 1
}
