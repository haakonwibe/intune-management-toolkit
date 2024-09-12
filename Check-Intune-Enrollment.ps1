# Requires the Microsoft Graph PowerShell SDK
# Install-Module Microsoft.Graph -Scope CurrentUser

# Connect to Microsoft Graph with the necessary scopes
Connect-MgGraph -Scopes "User.Read.All", "Group.Read.All", "DeviceManagementManagedDevices.Read.All"

# Function to get Intune enrolled iOS and Android devices for a user
function Get-UserIntuneDevices {
    param (
        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName,
        [Parameter(Mandatory = $true)]
        [array]$AllDevices
    )
    
    return $AllDevices | Where-Object { 
        $_.UserPrincipalName -eq $UserPrincipalName -and
        $_.OperatingSystem -in @("iOS", "Android") -and
        $_.ManagementAgent -in @("mdm", "configurationManagerClientMdm", "configurationManagerClientMdmEas")
    }
}

# Main script
$groupId = Read-Host "Enter the Entra ID Group ID"

try {
    Write-Host "Fetching all managed devices... This may take a moment." -ForegroundColor Yellow
    $allDevices = Get-MgDeviceManagementManagedDevice -All
    Write-Host "Fetched $($allDevices.Count) devices." -ForegroundColor Green

    $groupMembers = Get-MgGroupMember -GroupId $groupId -All
    
    foreach ($member in $groupMembers) {
        $user = Get-MgUser -UserId $member.Id
        $intuneDevices = Get-UserIntuneDevices -UserPrincipalName $user.UserPrincipalName -AllDevices $allDevices
        
        Write-Host "User: $($user.DisplayName) ($($user.UserPrincipalName))" -ForegroundColor Green
        
        if ($intuneDevices) {
            Write-Host "Intune Enrolled iOS/Android Devices: $($intuneDevices.Count)" -ForegroundColor Cyan
            foreach ($device in $intuneDevices) {
                Write-Host "  - Name: $($device.DeviceName)" -ForegroundColor Yellow
                Write-Host "    OS: $($device.OperatingSystem)"
                Write-Host "    OS Version: $($device.OsVersion)"
                Write-Host "    Management Agent: $($device.ManagementAgent)"
                Write-Host "    Compliance State: $($device.ComplianceState)"
                Write-Host "    Last Sync DateTime: $($device.LastSyncDateTime)"
                Write-Host ""
            }
        } else {
            Write-Host "No iOS/Android devices enrolled in Intune." -ForegroundColor Red
        }
        Write-Host "-----------------------------------------"
    }
} catch {
    Write-Error "An error occurred: $_"
} finally {
    #Disconnect-MgGraph
}