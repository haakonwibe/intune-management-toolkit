# Add-AutopilotCorporateIdentifiers.ps1

?? **Windows Autopilot Device Preparation Migration Tool**

## ?? Overview

This PowerShell script migrates devices from traditional Windows Autopilot to Windows Autopilot device preparation. It retrieves devices from your Autopilot inventory and adds them as imported device identifiers to enable the new device preparation workflow. The script provides comprehensive migration capabilities with safety features and optional source cleanup.

## ?? Purpose

- **Direct Migration**: Seamlessly migrate devices from Autopilot to device preparation
- **Safety Features**: Dry run mode and duplicate detection
- **Flexible Filtering**: Target specific manufacturers or models
- **Source Cleanup**: Optional deletion from source Autopilot inventory
- **Connection Management**: Persistent Graph connections with optional disconnect

## ?? Features

- ? Retrieves all Windows Autopilot devices from your inventory
- ? Adds devices as imported identifiers for device preparation
- ? Filters devices by manufacturer and/or model
- ? Detects and handles existing device identifiers
- ? Optional deletion from source Autopilot inventory
- ? Comprehensive error handling and progress tracking
- ? Dry run mode for safe testing
- ? Connection management with optional disconnect

## ?? Prerequisites

- **Microsoft Graph PowerShell SDK**: `Install-Module Microsoft.Graph -Scope CurrentUser`
- **Required permissions**: 
  - `DeviceManagementServiceConfig.ReadWrite.All`
  - `DeviceManagementConfiguration.ReadWrite.All`
- **Administrative access**: Global Administrator or Intune Administrator role

## ?? Usage Examples

### Basic Migration.\Add-AutopilotCorporateIdentifiers.ps1
### Safe Testing with Dry Run.\Add-AutopilotCorporateIdentifiers.ps1 -DryRun
### Filter by Manufacturer.\Add-AutopilotCorporateIdentifiers.ps1 -FilterByManufacturer "Dell", "HP"
### Filter by Model.\Add-AutopilotCorporateIdentifiers.ps1 -FilterByModel "Latitude", "EliteBook"
### Complete Migration with Source Cleanup.\Add-AutopilotCorporateIdentifiers.ps1 -FilterByManufacturer "SAMSUNG" -DeleteFromSource
### Test Migration with Source Cleanup.\Add-AutopilotCorporateIdentifiers.ps1 -FilterByManufacturer "Microsoft Corporation" -DeleteFromSource -DryRun
### Disconnect After Completion.\Add-AutopilotCorporateIdentifiers.ps1 -Disconnect
## ?? Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `DryRun` | Switch | No | Shows what would be done without making changes |
| `FilterByModel` | String Array | No | Filter devices by specific model names |
| `FilterByManufacturer` | String Array | No | Filter devices by manufacturer names |
| `DeleteFromSource` | Switch | No | Delete devices from source Autopilot after migration |
| `Disconnect` | Switch | No | Disconnect from Microsoft Graph when complete |

## ?? Migration Process

1. **Connect**: Authenticates to Microsoft Graph with required permissions
2. **Retrieve**: Gets all Windows Autopilot devices from inventory
3. **Filter**: Applies manufacturer/model filters if specified
4. **Analyze**: Checks for existing device identifiers in device preparation
5. **Migrate**: Adds new device identifiers to device preparation system
6. **Cleanup**: Optionally deletes devices from source Autopilot inventory
7. **Report**: Provides comprehensive migration and deletion statistics

## ?? Output Information

The script provides detailed information including:
- Total devices found in Autopilot inventory
- Applied filters and resulting device counts
- Migration progress for each device
- Success/failure statistics for migration
- Success/failure statistics for deletion (if enabled)
- Next steps for completing the migration

## ?? Safety Features

- **Dry Run Mode**: Test operations without making changes
- **Duplicate Detection**: Skips devices already in device preparation
- **Error Handling**: Comprehensive error reporting and recovery
- **Warning Messages**: Clear warnings when deletion is enabled
- **Field Validation**: Handles problematic characters in device names
- **Connection Management**: Maintains persistent Graph connections

## ?? Migration Workflow

### Phase 1: Preparation
1. Run with `-DryRun` to preview changes
2. Use filters to target specific device groups
3. Review migration plan and device counts

### Phase 2: Migration
1. Execute migration without `-DryRun`
2. Monitor progress and success rates
3. Review migration results

### Phase 3: Cleanup (Optional)
1. Test deletion with `-DeleteFromSource -DryRun`
2. Execute deletion with `-DeleteFromSource`
3. Verify devices removed from source

### Phase 4: Validation
1. Navigate to Microsoft Intune admin center
2. Go to **Devices > Windows > Windows enrollment > Device preparation (preview)**
3. Verify imported device identifiers
4. Begin using Windows Autopilot device preparation

## ? Advanced Usage

### Staged Migration by Manufacturer# Test each manufacturer separately
.\Add-AutopilotCorporateIdentifiers.ps1 -FilterByManufacturer "Microsoft Corporation" -DryRun
.\Add-AutopilotCorporateIdentifiers.ps1 -FilterByManufacturer "SAMSUNG" -DryRun
.\Add-AutopilotCorporateIdentifiers.ps1 -FilterByManufacturer "LENOVO" -DryRun

# Execute migration for each
.\Add-AutopilotCorporateIdentifiers.ps1 -FilterByManufacturer "Microsoft Corporation" -DeleteFromSource
.\Add-AutopilotCorporateIdentifiers.ps1 -FilterByManufacturer "SAMSUNG" -DeleteFromSource
.\Add-AutopilotCorporateIdentifiers.ps1 -FilterByManufacturer "LENOVO" -DeleteFromSource -Disconnect
### Combined Filtering.\Add-AutopilotCorporateIdentifiers.ps1 -FilterByManufacturer "Dell" -FilterByModel "Latitude" -DeleteFromSource
## ??? Troubleshooting

- **Connection Issues**: Ensure you have proper Microsoft Graph permissions
- **Migration Failures**: Check device data and retry failed devices
- **Deletion Failures**: Verify devices exist in source Autopilot inventory
- **Filter Issues**: Check manufacturer and model name spelling
- **Duplicate Devices**: Script automatically handles existing device identifiers

## ?? License

MIT — Free to use, modify, and share.