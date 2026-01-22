<#
.SYNOPSIS
    Remediation script for Intune Proactive Remediation.

.DESCRIPTION
    Adds the currently logged-on user to the local Administrators group.
    Exit 0 = success, Exit 1 = failure

.NOTES
    Author  : Haakon Wibe
    License : MIT
    Credits : Michael Niehaus (OOBE detection), Sandy Zeng, Peter Klapwijk
    Context : Run as SYSTEM in Intune Proactive Remediation.
    This script runs only when the detection script returns exit code 1 (non-compliant).
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
    $entry = "[$timestamp] [Remediation] $Message"
    Add-Content -Path $LogPath -Value $entry -Force
    Write-Host $entry
}

# Check if OOBE is complete using Windows API (credit: Michael Niehaus)
$OOBETypeDef = @"
using System;
using System.Runtime.InteropServices;
namespace Api {
    public class Kernel32 {
        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        public static extern int OOBEComplete(ref int bIsOOBEComplete);
    }
}
"@

try {
    Add-Type -TypeDefinition $OOBETypeDef -Language CSharp -ErrorAction SilentlyContinue
}
catch {
    # Type may already be loaded from a previous run
}

$IsOOBEComplete = $false
$null = [Api.Kernel32]::OOBEComplete([ref]$IsOOBEComplete)

if (-not $IsOOBEComplete) {
    Write-Log "OOBE is not complete - cannot remediate until enrollment finishes"
    Write-Host "OOBE in progress - retry later"
    exit 1  # Failed to signal Intune to retry after OOBE completes
}

try {
    # Get currently logged-on user via CIM (works when running as SYSTEM)
    $loggedInUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName

    if (-not $loggedInUser) {
        Write-Log "No user currently logged in - cannot add to Administrators"
        Write-Host "No user logged in"
        exit 1
    }

    # Extract username without domain for display
    $username = $loggedInUser.Split('\')[-1]

    # Secondary check: Skip known system/temporary users as a fallback
    $skipUsers = @('defaultuser0', 'defaultuser1', 'SYSTEM', 'LOCAL SERVICE', 'NETWORK SERVICE')
    if ($username -in $skipUsers -or $username -like 'defaultuser*') {
        Write-Log "Skipping system/temporary user '$username' - retry later"
        Write-Host "System user detected - retry later"
        exit 1  # Failed to signal Intune to retry
    }

    Write-Log "Remediation started for user: $loggedInUser"

    # Add user to local Administrators group using the full domain\username
    # This handles both local users and domain/Azure AD users correctly
    $adminGroup = [ADSI]"WinNT://./Administrators,group"

    # Try to add using WinNT provider with full path
    # For domain users: WinNT://DOMAIN/username
    # For local users: WinNT://COMPUTERNAME/username
    $domain = $loggedInUser.Split('\')[0]

    try {
        # First attempt: Add using domain\user format via net localgroup (most reliable)
        $result = net localgroup Administrators $loggedInUser /add 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-Log "Successfully added '$loggedInUser' to local Administrators group"
        }
        elseif ($result -like "*1378*" -or $result -like "*already a member*") {
            # Error 1378 = already a member
            Write-Log "User '$loggedInUser' is already a member of Administrators"
        }
        else {
            throw "net localgroup failed: $result"
        }
    }
    catch {
        # Fallback: Try using Add-LocalGroupMember (requires PowerShell 5.1+)
        Write-Log "Attempting fallback method using Add-LocalGroupMember"
        Add-LocalGroupMember -Group "Administrators" -Member $loggedInUser -ErrorAction Stop
        Write-Log "Successfully added '$loggedInUser' to local Administrators group (fallback method)"
    }

    # Verify the user was added
    $adminMembers = @($adminGroup.Invoke("Members")) | ForEach-Object {
        $_.GetType().InvokeMember("Name", 'GetProperty', $null, $_, $null)
    }

    if ($adminMembers -contains $username) {
        Write-Log "Verified: '$username' is now a member of local Administrators"
        Write-Host "User successfully added to Administrators"
        exit 0
    }
    else {
        Write-Log "WARNING: Could not verify membership after adding user"
        Write-Host "Could not verify membership"
        exit 0  # Still exit 0 as the add command succeeded
    }
}
catch {
    Write-Log "ERROR: Failed to add user to Administrators - $($_.Exception.Message)"
    Write-Host "Remediation error: $($_.Exception.Message)"
    exit 1
}
