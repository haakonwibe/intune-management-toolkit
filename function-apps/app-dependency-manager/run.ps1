<#
.SYNOPSIS
    Azure Function that adds users to an Entra ID group based on app installation.

.DESCRIPTION
    Timer-triggered Azure Function that monitors for devices with a specific app installed
    and automatically adds the associated users to a target Entra ID security group.
    Uses managed identity authentication to connect to Microsoft Graph.

.NOTES
    Author  : Haakon Wibe
    License : MIT
    Context : Azure Function App (timer trigger)
    Config  : Set TargetAppName and TargetGroupName in application settings.
#>

# Input bindings are passed in via param block.
param($Timer)

# Get the current universal time in the default string format.
$currentUTCtime = (Get-Date).ToUniversalTime()

# Log the function start
Write-Host "PowerShell timer trigger function started! TIME: $currentUTCtime"

try {
    # Connect to Microsoft Graph using managed identity
    Connect-MgGraph -Identity

    # Get configuration from environment variables
    $appName = $env:TargetAppName
    $groupName = $env:TargetGroupName

    if ([string]::IsNullOrEmpty($appName) -or [string]::IsNullOrEmpty($groupName)) {
        throw "Configuration missing. Please set TargetAppName and TargetGroupName in application settings."
    }

    Write-Host "Starting process for app: $appName"

    # Retrieve all detected apps
    $detectedApps = Get-MgDeviceManagementDetectedApp -All
    Write-Host "Retrieved all detected apps"

    # Find all apps that match your app name
    $matchingApps = $detectedApps | Where-Object { $_.DisplayName -eq $appName }

    if ($null -eq $matchingApps -or $matchingApps.Count -eq 0) {
        Write-Host "App '$appName' not found."
        exit
    }

    Write-Host "Found $($matchingApps.Count) apps matching '$appName'."

    # Initialize a collection to hold all associated managed devices
    $allAssociatedManagedDevices = @()

    foreach ($app in $matchingApps) {
        $appId = $app.Id
        Write-Host "Processing App ID: $appId, Version: $($app.Version), Publisher: $($app.Publisher)"

        # Retrieve managed devices that have the app installed
        $associatedManagedDevices = Get-MgDeviceManagementDetectedAppManagedDevice -DetectedAppId $appId -All

        if ($associatedManagedDevices) {
            $allAssociatedManagedDevices += $associatedManagedDevices
        }
    }

    # Remove duplicate devices
    $allAssociatedManagedDevices = $allAssociatedManagedDevices | Select-Object -Property * -Unique
    Write-Host "Total managed devices found: $($allAssociatedManagedDevices.Count)"

    # Proceed to extract user IDs associated with the devices
    $userIds = @()

    foreach ($device in $allAssociatedManagedDevices) {
        # Get the managed device details
        $managedDevice = Get-MgDeviceManagementManagedDevice -ManagedDeviceId $device.Id

        # Check if UserId is available
        if ($managedDevice.UserId -ne $null -and $managedDevice.UserId -ne "") {
            $userIds += $managedDevice.UserId
        }
    }

    # Remove duplicate user IDs
    $userIds = $userIds | Select-Object -Unique
    Write-Host "Total unique users to add: $($userIds.Count)"

    # Get the group ID from the group name
    $group = Get-MgGroup -Filter "displayName eq '$groupName'"
    if ($null -eq $group) {
        throw "Group '$groupName' not found."
    }
    $groupId = $group.Id

    Write-Host "Found group with ID: $groupId"

    # Add Users to the Entra ID Group
    foreach ($userId in $userIds) {
        try {
            # Check if the user is already a member of the group
            $isMember = Get-MgGroupMember -GroupId $groupId -Filter "id eq '$userId'" -ErrorAction SilentlyContinue

            if ($null -eq $isMember) {
                # Add the user to the group
                New-MgGroupMember -GroupId $groupId -DirectoryObjectId $userId
                Write-Host "Added user with ID $userId to group $groupId"
            } else {
                Write-Host "User with ID $userId is already a member of the group."
            }
        } catch {
            Write-Host "Failed to add user with ID $userId to group $groupId. Error: $_"
        }
    }

    Write-Host "Function completed successfully"
}
catch {
    Write-Host "Error in function execution: $_"
    throw
}