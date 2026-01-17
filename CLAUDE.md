# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Commands

### Prerequisites
```powershell
# Install required PowerShell modules
Install-Module Microsoft.Graph -Scope CurrentUser
```

### Running Scripts
The repository contains standalone PowerShell scripts that can be run directly:

```powershell
# Core device diagnostics
.\scripts\troubleshooting\Get-IntuneDeviceDiagnostics.ps1 -DeviceName LAPTOP-123

# Compliance reporting
.\scripts\compliance\Get-IntuneComplianceReport.ps1 -OutputPath .\reports

# App packaging
.\scripts\apps\New-IntuneAppPackageFromInstaller.ps1 -InstallerPath .\setup.exe -OutputPath .\out

# Device cleanup (preview mode)
.\scripts\devices\Invoke-StaleDeviceCleanup.ps1 -DaysInactive 60 -WhatIf

# Autopilot migration (dry run)
.\scripts\Add-AutopilotCorporateIdentifiers.ps1 -FilterByManufacturer "Dell" -DryRun
```

### Testing Scripts
Always test scripts with `-DryRun` or `-WhatIf` parameters before making changes:
```powershell
# Safe testing patterns
.\scripts\devices\Invoke-StaleDeviceCleanup.ps1 -WhatIf
.\scripts\Add-AutopilotCorporateIdentifiers.ps1 -DryRun
```

## Code Architecture

### Module Structure
The `modules/IntuneToolkit/` directory contains the shared PowerShell module used across all scripts:

- **Connection Management**: `Connect-IntuneGraph` with permission level presets (ReadOnly, Standard, Full)
- **Logging**: `Write-IntuneLog` for consistent structured logging
- **Device Operations**: `Get-IntuneDeviceCompliance`, `Get-BatchedIntuneDevices` for device management
- **Export Functions**: `Export-IntuneReport` supports CSV, JSON, HTML formats
- **Utilities**: `ConvertTo-FriendlySize`, `Test-AdminPrivileges`

### Permission Levels
Scripts use the IntuneToolkit module's permission presets:
- **ReadOnly**: Device/app/config read permissions only
- **Standard**: Read + device write permissions (most scripts)  
- **Full**: All permissions including privileged operations and group management

### Script Categories
- **apps/**: Win32 app packaging and deployment helpers
- **bitlocker/**: Intune Win32 app for user-initiated BitLocker disable (Autopilot reset prep)
- **compliance/**: Compliance reporting and analysis
- **devices/**: Device lifecycle management (cleanup, diagnostics)
- **proactive-remediations/**: Intune Proactive Remediation packages (detection + remediation scripts)
- **troubleshooting/**: Deep device diagnostics with progressive detail levels

### Azure Functions
The `function-apps/app-dependency-manager/` contains a timer-triggered Azure Function that:
- Monitors for specific apps on managed devices
- Automatically adds associated users to Entra ID groups
- Uses managed identity authentication

## Development Guidelines

### Error Handling
All scripts use the IntuneToolkit module's logging functions. Error handling should:
- Use `Write-IntuneLog` for structured logging
- Include try-catch blocks for Graph API calls
- Support `-WhatIf` for destructive operations
- Provide clear error messages with context

### Graph API Usage
- Always use `Connect-IntuneGraph` with appropriate permission levels
- Leverage `Get-BatchedIntuneDevices` for large device queries
- Use `Test-GraphConnection` to verify connectivity before operations
- Include retry logic for transient failures

### Export Patterns
Use `Export-IntuneReport` for consistent output formats:
- JSON exports include metadata and timestamps
- Support multiple formats (CSV, JSON, HTML)
- Include timestamped filenames for version tracking

### Security Considerations
- Use least-privilege permission levels where possible
- Sanitize device identifiers in exported reports when sharing
- Test with `-DryRun` before destructive operations
- Store sensitive configuration in Azure Function app settings (not code)