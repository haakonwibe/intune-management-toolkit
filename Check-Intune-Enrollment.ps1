# Requires the Microsoft Graph PowerShell SDK
# Install-Module Microsoft.Graph -Scope CurrentUser

# Connect to Microsoft Graph
Connect-MgGraph -Scopes "User.Read.All", "Group.Read.All", "DeviceManagementManagedDevices.Read.All"

# Function to get Intune enrolled devices for a user
function Get-IntuneEnrolledDevices {
    param (
        [Parameter(Mandatory = $true)]
        [string]$UserId
    )
    
    $devices = Get-MgUserManagedDevice -UserId $UserId
    return $devices | Where-Object { $_.ManagementAgent -eq "MDM" -or $_.ManagementAgent -eq "ConfigurationManagerClientMDM" }
}

# Main script
$groupId = Read-Host "Enter the Entra ID Group ID"

try {
    $groupMembers = Get-MgGroupMember -GroupId $groupId -All
    
    foreach ($member in $groupMembers) {
        $user = Get-MgUser -UserId $member.Id
        $intuneDevices = Get-IntuneEnrolledDevices -UserId $member.Id
        
        if ($intuneDevices) {
            Write-Host "$($user.DisplayName) ($($user.UserPrincipalName)) has $($intuneDevices.Count) device(s) enrolled in Intune:"
            foreach ($device in $intuneDevices) {
                Write-Host "  - $($device.DeviceName) ($($device.OperatingSystem))"
            }
        } else {
            Write-Host "$($user.DisplayName) ($($user.UserPrincipalName)) has no devices enrolled in Intune."
        }
        Write-Host ""
    }
} catch {
    Write-Error "An error occurred: $_"
} finally {
    Disconnect-MgGraph
}