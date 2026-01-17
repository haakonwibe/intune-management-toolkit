<#
.SYNOPSIS
    Detection script for Intune Proactive Remediation.

.DESCRIPTION
    Checks if the currently logged-on user is a member of the local Administrators group.
    Exit 0 = compliant (user is already admin), Exit 1 = non-compliant (user needs to be added)

.NOTES
    Author  : Haakon Wibe
    License : MIT
    Context : Run as SYSTEM in Intune Proactive Remediation.
    Detection runs first to determine if remediation is needed.
#>

$ErrorActionPreference = "Stop"

# Configuration
$ToolsFolder = "C:\ProgramData\IntuneTools"
$LogPath = Join-Path $ToolsFolder "LocalAdmin.log"

# Ensure log folder exists
if (-not (Test-Path $ToolsFolder)) {
    New-Item -Path $ToolsFolder -ItemType Directory -Force | Out-Null
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [Detection] $Message"
    Add-Content -Path $LogPath -Value $entry -Force
    Write-Host $entry
}

try {
    # Get currently logged-on user via CIM (works when running as SYSTEM)
    $loggedInUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName

    if (-not $loggedInUser) {
        Write-Log "No user currently logged in - skipping detection"
        Write-Host "No user logged in"
        exit 0  # Compliant - nothing to do if no user
    }

    Write-Log "Detected logged-in user: $loggedInUser"

    # Extract username without domain
    $username = $loggedInUser.Split('\')[-1]

    # Get members of local Administrators group
    $adminGroup = [ADSI]"WinNT://./Administrators,group"
    $adminMembers = @($adminGroup.Invoke("Members")) | ForEach-Object {
        $_.GetType().InvokeMember("Name", 'GetProperty', $null, $_, $null)
    }

    Write-Log "Local Administrators group members: $($adminMembers -join ', ')"

    # Check if user is already in Administrators group
    if ($adminMembers -contains $username) {
        Write-Log "User '$username' is already a member of local Administrators - compliant"
        Write-Host "User is already a local administrator"
        exit 0  # Compliant
    }
    else {
        Write-Log "User '$username' is NOT a member of local Administrators - remediation required"
        Write-Host "User is not a local administrator"
        exit 1  # Non-compliant - remediation needed
    }
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Host "Detection error: $($_.Exception.Message)"
    exit 1  # Treat errors as non-compliant to trigger remediation attempt
}
