<#
.SYNOPSIS
    Migrates devices from Autopilot inventory to Windows Autopilot device preparation.

.DESCRIPTION
    This script retrieves all Windows Autopilot devices from your inventory and adds them as imported device identifiers
    to enable migration to Windows Autopilot device preparation. The script uses the Microsoft Graph PowerShell SDK 
    to interact with Intune services using the importedDeviceIdentities endpoint.

.PARAMETER DryRun
    When specified, shows what would be done without making actual changes.

.PARAMETER FilterByModel
    Optional parameter to filter devices by specific model(s).

.PARAMETER FilterByManufacturer
    Optional parameter to filter devices by specific manufacturer(s).

.PARAMETER DeleteFromSource
    When specified, deletes devices from the source Autopilot inventory after successful migration.

.PARAMETER Disconnect
    When specified, disconnects from Microsoft Graph at the end of the script.

.NOTES
    File Name      : Add-AutopilotCorporateIdentifiers.ps1
    Author         : Generated for Intune Tools
    Prerequisite   : Microsoft Graph PowerShell SDK
    Copyright      : (c) 2024. All rights reserved.
    License        : MIT
    Version        : 4.1
    Creation Date  : 2024-12-19
    Last Modified  : 2024-12-19

.EXAMPLE
    .\Add-AutopilotCorporateIdentifiers.ps1

.EXAMPLE
    .\Add-AutopilotCorporateIdentifiers.ps1 -DryRun

.EXAMPLE
    .\Add-AutopilotCorporateIdentifiers.ps1 -FilterByManufacturer "Dell" -FilterByModel "Latitude"

.EXAMPLE
    .\Add-AutopilotCorporateIdentifiers.ps1 -FilterByManufacturer "SAMSUNG" -DeleteFromSource

.EXAMPLE
    .\Add-AutopilotCorporateIdentifiers.ps1 -Disconnect

#>

param (
    [Parameter(Mandatory=$false)]
    [switch]$DryRun,

    [Parameter(Mandatory=$false)]
    [string[]]$FilterByModel,

    [Parameter(Mandatory=$false)]
    [string[]]$FilterByManufacturer,

    [Parameter(Mandatory=$false)]
    [switch]$DeleteFromSource,

    [Parameter(Mandatory=$false)]
    [switch]$Disconnect
)

# Requires the Microsoft Graph PowerShell SDK
# Install-Module Microsoft.Graph -Scope CurrentUser

Write-Host "=== Windows Autopilot Device Preparation Migration Tool ===" -ForegroundColor Cyan
Write-Host "This script migrates Autopilot devices to Windows Autopilot device preparation." -ForegroundColor Yellow

if ($DeleteFromSource) {
    Write-Host "??  WARNING: Devices will be DELETED from source Autopilot inventory after successful migration!" -ForegroundColor Red
}

Write-Host ""

# Connect to Microsoft Graph with the necessary scopes
try {
    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Yellow
    Connect-MgGraph -Scopes "DeviceManagementServiceConfig.ReadWrite.All", "DeviceManagementConfiguration.ReadWrite.All" -NoWelcome
    Write-Host "Connected successfully to Microsoft Graph." -ForegroundColor Green
} catch {
    Write-Error "Failed to connect to Microsoft Graph: $_"
    exit 1
}

# Function to check if device identifier already exists in Autopilot device preparation
function Test-DeviceIdentifierExists {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Manufacturer,
        [Parameter(Mandatory = $true)]
        [string]$Model,
        [Parameter(Mandatory = $true)]
        [string]$SerialNumber
    )
    
    try {
        $uri = "https://graph.microsoft.com/beta/deviceManagement/importedDeviceIdentities/searchExistingIdentities"
        $deviceIdentifier = "$Manufacturer,$Model,$SerialNumber"
        
        $requestBody = @{
            importedDeviceIdentities = @(
                @{
                    importedDeviceIdentifier = $deviceIdentifier
                    importedDeviceIdentityType = "manufacturerModelSerial"
                }
            )
        } | ConvertTo-Json -Depth 3
        
        $response = Invoke-MgGraphRequest -Uri $uri -Method POST -Body $requestBody -ContentType "application/json"
        
        # If response contains values, device already exists
        return ($null -ne $response.value -and $response.value.Count -gt 0)
    } catch {
        Write-Warning "Could not check if device $SerialNumber exists: $_"
        return $false
    }
}

# Function to add device identifier for Autopilot device preparation
function Add-DeviceIdentifier {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Manufacturer,
        [Parameter(Mandatory = $true)]
        [string]$Model,
        [Parameter(Mandatory = $true)]
        [string]$SerialNumber,
        [Parameter(Mandatory = $false)]
        [switch]$DryRun
    )
    
    try {
        if ($DryRun) {
            Write-Host "  [DRY RUN] Would add device identifier for: $SerialNumber ($Manufacturer, $Model)" -ForegroundColor Magenta
            return $true
        }
        
        $uri = "https://graph.microsoft.com/beta/deviceManagement/importedDeviceIdentities/importDeviceIdentityList"
        $deviceIdentifier = "$Manufacturer,$Model,$SerialNumber"
        
        # Import the device identifier
        $requestBody = @{
            importedDeviceIdentities = @(
                @{
                    importedDeviceIdentifier = $deviceIdentifier
                    importedDeviceIdentityType = "manufacturerModelSerial"
                }
            )
            overwriteImportedDeviceIdentities = $false
        } | ConvertTo-Json -Depth 3
        
        $response = Invoke-MgGraphRequest -Uri $uri -Method POST -Body $requestBody -ContentType "application/json"
        
        Write-Host "  ? Successfully added device identifier for: $SerialNumber" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  ? Failed to add device identifier for $SerialNumber : $_" -ForegroundColor Red
        return $false
    }
}

# Function to remove device from Autopilot inventory
function Remove-AutopilotDevice {
    param (
        [Parameter(Mandatory = $true)]
        [string]$DeviceId,
        [Parameter(Mandatory = $true)]
        [string]$SerialNumber,
        [Parameter(Mandatory = $false)]
        [switch]$DryRun
    )
    
    try {
        if ($DryRun) {
            Write-Host "  [DRY RUN] Would delete device from Autopilot: $SerialNumber" -ForegroundColor Magenta
            return $true
        }
        
        $uri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities/$DeviceId"
        
        Invoke-MgGraphRequest -Uri $uri -Method DELETE
        
        Write-Host "  ??? Successfully deleted device from Autopilot: $SerialNumber" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  ? Failed to delete device from Autopilot $SerialNumber : $_" -ForegroundColor Red
        return $false
    }
}

try {
    Write-Host "Retrieving Windows Autopilot devices..." -ForegroundColor Yellow
    $autopilotDevices = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -All
    
    if (-not $autopilotDevices -or $autopilotDevices.Count -eq 0) {
        Write-Host "No Windows Autopilot devices found in your inventory." -ForegroundColor Yellow
        exit 0
    }
    
    Write-Host "Found $($autopilotDevices.Count) Autopilot devices in inventory." -ForegroundColor Green
    
    # Apply filters if specified
    $filteredDevices = $autopilotDevices
    
    if ($FilterByManufacturer) {
        $filteredDevices = $filteredDevices | Where-Object { 
            $deviceManufacturer = $_.Manufacturer
            $FilterByManufacturer | ForEach-Object { $deviceManufacturer -like "*$_*" }
        }
        Write-Host "Filtered to $($filteredDevices.Count) devices by manufacturer: $($FilterByManufacturer -join ', ')" -ForegroundColor Cyan
    }
    
    if ($FilterByModel) {
        $filteredDevices = $filteredDevices | Where-Object { 
            $deviceModel = $_.SystemFamily
            $FilterByModel | ForEach-Object { $deviceModel -like "*$_*" }
        }
        Write-Host "Filtered to $($filteredDevices.Count) devices by model: $($FilterByModel -join ', ')" -ForegroundColor Cyan
    }
    
    if ($filteredDevices.Count -eq 0) {
        Write-Host "No devices match the specified filters." -ForegroundColor Yellow
        exit 0
    }
    
    Write-Host ""
    Write-Host "=== Device Analysis ===" -ForegroundColor Cyan
    Write-Host "Total devices to process: $($filteredDevices.Count)"
    
    if ($DryRun) {
        Write-Host ""
        Write-Host "DRY RUN MODE - No actual changes will be made" -ForegroundColor Magenta
    }
    
    Write-Host ""
    Write-Host "=== Processing Devices ===" -ForegroundColor Cyan
    Write-Host "Adding device identifiers for Autopilot device preparation..." -ForegroundColor Yellow
    
    # Process devices
    $successCount = 0
    $failureCount = 0
    $alreadyExistsCount = 0
    $deletedCount = 0
    $deleteFailedCount = 0
    
    foreach ($device in $filteredDevices) {
        Write-Host ""
        Write-Host "Processing device: $($device.SerialNumber) (Model: $($device.Model), Manufacturer: $($device.SystemFamily))" -ForegroundColor White
        
        # Use the correct manufacturer and model fields and clean them
        $manufacturer = if (-not [string]::IsNullOrEmpty($device.Manufacturer)) { 
            # Remove commas and other problematic characters from manufacturer name
            $device.Manufacturer -replace ',', '' -replace ';', '' -replace '\s+', ' '
        } else { 
            "Unknown" 
        }
        
        # Use SystemFamily as model since it contains the actual model names
        $model = if (-not [string]::IsNullOrEmpty($device.SystemFamily)) { 
            # Remove commas and other problematic characters from model name
            $device.SystemFamily -replace ',', '' -replace ';', '' -replace '\s+', ' '
        } else { 
            "Unknown" 
        }
        
        $serialNumber = $device.SerialNumber
        
        if ([string]::IsNullOrEmpty($serialNumber)) {
            Write-Host "  ?? Skipping device with empty serial number" -ForegroundColor Yellow
            continue
        }
        
        Write-Host "  ? Using: Manufacturer='$manufacturer', Model='$model', Serial='$serialNumber'" -ForegroundColor Cyan
        
        # Check if device identifier already exists (skip in dry run mode)
        $deviceExists = $false
        if (-not $DryRun) {
            $deviceExists = Test-DeviceIdentifierExists -Manufacturer $manufacturer -Model $model -SerialNumber $serialNumber
            if ($deviceExists) {
                Write-Host "  ?? Device identifier already exists in Autopilot device preparation: $serialNumber" -ForegroundColor Cyan
                $alreadyExistsCount++
            }
        }
        
        # Add device identifier (only if it doesn't already exist)
        $migrationSuccessful = $false
        if (-not $deviceExists) {
            if (Add-DeviceIdentifier -Manufacturer $manufacturer -Model $model -SerialNumber $serialNumber -DryRun:$DryRun) {
                $successCount++
                $migrationSuccessful = $true
            } else {
                $failureCount++
            }
        } else {
            $migrationSuccessful = $true  # Consider existing devices as successful for deletion purposes
        }
        
        # Delete from source Autopilot if requested and migration was successful
        if ($DeleteFromSource -and $migrationSuccessful) {
            Write-Host "  ? Deleting from source Autopilot inventory..." -ForegroundColor Yellow
            if (Remove-AutopilotDevice -DeviceId $device.Id -SerialNumber $serialNumber -DryRun:$DryRun) {
                $deletedCount++
            } else {
                $deleteFailedCount++
            }
        }
    }
    
    # Summary
    Write-Host ""
    Write-Host "=== Migration Summary ===" -ForegroundColor Cyan
    Write-Host "Total devices processed: $($filteredDevices.Count)"
    Write-Host "Successfully added: $successCount" -ForegroundColor Green
    Write-Host "Already existed: $alreadyExistsCount" -ForegroundColor Cyan
    Write-Host "Failed: $failureCount" -ForegroundColor Red
    
    if ($DeleteFromSource) {
        Write-Host ""
        Write-Host "=== Deletion Summary ===" -ForegroundColor Cyan
        Write-Host "Successfully deleted from source: $deletedCount" -ForegroundColor Green
        Write-Host "Failed to delete from source: $deleteFailedCount" -ForegroundColor Red
    }
    
    if (-not $DryRun -and $successCount -gt 0) {
        Write-Host ""
        Write-Host "Device identifiers have been added successfully!" -ForegroundColor Green
        Write-Host "These devices are now ready for Windows Autopilot device preparation." -ForegroundColor Yellow
        
        if ($DeleteFromSource -and $deletedCount -gt 0) {
            Write-Host "Devices have been removed from the source Autopilot inventory." -ForegroundColor Yellow
        }
        
        Write-Host ""
        Write-Host "Next steps:" -ForegroundColor Cyan
        Write-Host "1. Navigate to Microsoft Intune admin center" -ForegroundColor White
        Write-Host "2. Go to Devices > Windows > Windows enrollment > Device preparation (preview)" -ForegroundColor White
        Write-Host "3. Review imported device identifiers" -ForegroundColor White
        Write-Host "4. Begin using Windows Autopilot device preparation for new deployments" -ForegroundColor White
    }
    
    if ($DryRun) {
        Write-Host ""
        if ($DeleteFromSource) {
            Write-Host "This was a dry run. Re-run the script without -DryRun to migrate devices and delete from source." -ForegroundColor Magenta
        } else {
            Write-Host "This was a dry run. Re-run the script without -DryRun to apply changes." -ForegroundColor Magenta
        }
    }
    
} catch {
    Write-Error "An error occurred during processing: $_"
    exit 1
} finally {
    # Only disconnect if the -Disconnect parameter is specified
    if ($Disconnect) {
        Write-Host ""
        Write-Host "Disconnecting from Microsoft Graph..." -ForegroundColor Yellow
        Disconnect-MgGraph
        Write-Host "Disconnected from Microsoft Graph." -ForegroundColor Green
    }
}