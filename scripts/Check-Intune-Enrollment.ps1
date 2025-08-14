<#
.SYNOPSIS
    Checks Intune enrollment for devices of members in a specified Entra ID group, with options to filter by device type.

.DESCRIPTION
    This script retrieves all members of a specified Entra ID group and checks their Intune
    enrollment status. It provides options to filter devices by type (iOS, Android, Windows)
    or show all devices. It uses the Microsoft Graph PowerShell SDK to interact with Microsoft 365 services.

.PARAMETER GroupId
    The ID of the Entra ID group to check. If not provided, the script will prompt for it.

.PARAMETER DeviceType
    The type of devices to display. Valid options are 'All', 'iOS', 'Android', 'Windows'. Default is 'All'.

.NOTES
    File Name      : Check-IntuneEnrollment.ps1
    Author         : Haakon Wibe
    Prerequisite   : Microsoft Graph PowerShell SDK
    Copyright      : (c) 2024 Haakon Wibe. All rights reserved.
    License        : GPL
    Version        : 1.2
    Creation Date  : 2024-09-12
    Last Modified  : 2024-09-12

.EXAMPLE
    .\Check-IntuneEnrollment.ps1 -GroupId "12345678-1234-1234-1234-123456789012" -DeviceType iOS

.EXAMPLE
    .\Check-IntuneEnrollment.ps1 -DeviceType Android

.EXAMPLE
    .\Check-IntuneEnrollment.ps1 -DeviceType All

#>

param (
    [Parameter(Mandatory=$false)]
    [string]$GroupId,

    [Parameter(Mandatory=$false)]
    [ValidateSet('All', 'iOS', 'Android', 'Windows')]
    [string]$DeviceType = 'All'
)

# Import IntuneToolkit and establish read-only connection
try {
    $toolkitPath = Join-Path $PSScriptRoot '../modules/IntuneToolkit/IntuneToolkit.psm1'
    if (-not (Test-Path $toolkitPath)) { $toolkitPath = Join-Path $PSScriptRoot '../../modules/IntuneToolkit/IntuneToolkit.psm1' }
    if (-not (Test-Path $toolkitPath)) { throw 'IntuneToolkit module not found.' }
    Import-Module $toolkitPath -Force -ErrorAction Stop
    Connect-IntuneGraph -PermissionLevel ReadOnly -Quiet
} catch { Write-Error "Failed to import/connect IntuneToolkit: $_"; exit 1 }

# Function to get Intune enrolled devices for a user
function Get-UserIntuneDevices {
    param (
        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName,
        [Parameter(Mandatory = $true)]
        [array]$AllDevices,
        [Parameter(Mandatory = $true)]
        [string]$DeviceType
    )
    
    $devices = $AllDevices | Where-Object { 
        $_.UserPrincipalName -eq $UserPrincipalName -and
        $_.ManagementAgent -in @("mdm", "configurationManagerClientMdm", "configurationManagerClientMdmEas")
    }

    switch ($DeviceType) {
        'iOS' { return $devices | Where-Object { $_.OperatingSystem -eq 'iOS' } }
        'Android' { return $devices | Where-Object { $_.OperatingSystem -eq 'Android' } }
        'Windows' { return $devices | Where-Object { $_.OperatingSystem -eq 'Windows' } }
        default { return $devices }
    }
}

# Main script
if (-not $GroupId) {
    $GroupId = Read-Host "Enter the Entra ID Group ID"
}

try {
    Write-Host "Fetching all managed devices... This may take a moment." -ForegroundColor Yellow
    $allDevices = Get-MgDeviceManagementManagedDevice -All
    Write-Host "Fetched $($allDevices.Count) devices." -ForegroundColor Green

    $groupMembers = Get-MgGroupMember -GroupId $GroupId -All
    
    foreach ($member in $groupMembers) {
        $user = Get-MgUser -UserId $member.Id
        $intuneDevices = Get-UserIntuneDevices -UserPrincipalName $user.UserPrincipalName -AllDevices $allDevices -DeviceType $DeviceType
        
        Write-Host "User: $($user.DisplayName) ($($user.UserPrincipalName))" -ForegroundColor Green
        
        if ($intuneDevices) {
            Write-Host "Intune Enrolled $DeviceType Devices: $($intuneDevices.Count)" -ForegroundColor Cyan
            foreach ($device in $intuneDevices) {
                Write-Host "  - Name: $($device.DeviceName)" -ForegroundColor Yellow
                Write-Host "    OS: $($device.OperatingSystem)"
                Write-Host "    OS Version: $($device.OsVersion)"
                Write-Host "    Device Type: $($device.DeviceType)"
                Write-Host "    Management Agent: $($device.ManagementAgent)"
                Write-Host "    Ownership: $($device.ManagedDeviceOwnerType)"
                Write-Host "    Compliance State: $($device.ComplianceState)"
                Write-Host "    Last Sync DateTime: $($device.LastSyncDateTime)"
                Write-Host ""
            }
        } else {
            Write-Host "No $DeviceType devices enrolled in Intune." -ForegroundColor Red
        }
        Write-Host "-----------------------------------------"
    }
} catch {
    Write-Error "An error occurred: $_"
} finally {
    Disconnect-MgGraph
}