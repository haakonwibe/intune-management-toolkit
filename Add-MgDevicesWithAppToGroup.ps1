# Set the name of the app you're targeting
$appName = "BusinessApp"

# Retrieve all detected apps
$detectedApps = Get-MgDeviceManagementDetectedApp -All

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
    if ($null -ne $managedDevice.UserId -and $managedDevice.UserId -ne "") {
        $userIds += $managedDevice.UserId
    }
}

# Remove duplicate user IDs
$userIds = $userIds | Select-Object -Unique

Write-Host "Total unique users to add: $($userIds.Count)"

# Add Users to the Entra ID Group
$groupId = "MDM-APP-TUNNEL-COMPANION"

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