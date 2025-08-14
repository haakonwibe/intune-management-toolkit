# Intune Management Toolkit 🛠️

A collection of PowerShell scripts and Azure Function Apps for Microsoft Intune management and automation.

## Overview

Scripts and tools for common Intune administration tasks, including Windows Autopilot migrations, device group management, app dependency automation, compliance reporting, and device lifecycle (stale device) cleanup.

**Features:**
- PowerShell 7 compatible with backward compatibility to 5.1
- Microsoft Graph API integration
- Error handling and logging
- Azure Function Apps for cloud automation
- Device lifecycle management (stale / duplicate / orphaned device cleanup)
- Comprehensive compliance and inventory reporting
- Central IntuneToolkit module with standardized Graph connection & utilities
- Win32 app packaging helper (automatic Intune .intunewin packaging)

## 📁 **Repository Structure**

```
intune-management-toolkit/
│
├── scripts/                              # PowerShell automation scripts
│   ├── compliance/
│   │   └── Get-IntuneComplianceReport.ps1      # Compliance reporting
│   ├── devices/
│   │   └── Invoke-StaleDeviceCleanup.ps1       # Stale / orphaned device cleanup
│   ├── apps/
│   │   └── New-IntuneAppPackageFromInstaller.ps1  # Win32 packaging (.intunewin)
│   ├── Add-AutopilotCorporateIdentifiers.ps1   # Autopilot migration tool
│   ├── Add-MgDevicesWithAppToGroup.ps1         # App-based device grouping
│   ├── Check-Intune-Enrollment.ps1             # Enrollment verification
│   └── Update-Group.ps1                        # Azure AD group management
│
├── modules/
│   └── IntuneToolkit/                         # Reusable helper module
│       ├── IntuneToolkit.psm1
│       └── IntuneToolkit.psd1
│
└── function-apps/                        # Azure Function Apps
    └── app-dependency-manager/           # Intune app dependency automation
        ├── host.json
        ├── requirements.psd1
        └── run.ps1
```

## IntuneToolkit Module (Core Utilities)
All scripts now leverage a shared module: `modules/IntuneToolkit/IntuneToolkit.psm1` providing:
- Unified Microsoft Graph connection via `Connect-IntuneGraph`
- Permission level presets (principle of least privilege)
- Logging helper (`Write-IntuneLog`)
- Device batching & compliance helpers
- Report export helpers

### Permission Levels
| Level | Scopes (summary) | Purpose |
|-------|------------------|---------|
| ReadOnly | Read device/config/apps + user/group read | Reporting & inventory only |
| Standard | Read/Write managed devices + read config/apps | Operational tasks (cleanup, grouping) |
| Full | Adds privileged operations + write config/apps/service | Administrative / migration scripts |
| Custom | Provide your own scope list | Advanced scenarios |

### Connection Pattern
```powershell
Import-Module "$PSScriptRoot/../../modules/IntuneToolkit/IntuneToolkit.psm1" -Force
Connect-IntuneGraph -PermissionLevel ReadOnly -Quiet   # or Standard / Full
```
The function reuses an existing session if sufficient scopes are already granted.

## Tools & Scripts

### **[New-IntuneAppPackageFromInstaller.ps1](./scripts/apps/New-IntuneAppPackageFromInstaller.ps1)**
**Automated Win32 App Packaging (.intunewin) for Intune**

Creates Intune-ready Win32 packages from MSI or EXE installers with automatic metadata extraction & detection rule scaffolding.

Key capabilities:
- Auto-download latest Microsoft Win32 Content Prep Tool (GitHub release API, zipball fallback)
- Supports MSI & EXE installers
- MSI metadata extraction (ProductName, Version, ProductCode, Manufacturer)
- EXE heuristic engine (InstallShield, Inno Setup, NSIS, Wise, Squirrel, MSI wrapper hints) with silent switch suggestions
- Default install/uninstall command generation (customizable)
- Detection method options: Auto / MSI / File / Registry / Script
- Produces: .intunewin, Metadata.json, optional DetectionScript.ps1
- Robust logging + retry & diagnostic logic if packaging output not found

Example basic usage:
```powershell
# MSI
./scripts/apps/New-IntuneAppPackageFromInstaller.ps1 -InstallerPath 'C:\Intune\Apps\7-ZipMSI\7z2501-x64.msi'

# EXE with explicit silent argument
./scripts/apps/New-IntuneAppPackageFromInstaller.ps1 -InstallerPath 'C:\Installers\NotepadPlusPlus.exe' -InstallCommand 'NotepadPlusPlus.exe /S'

# EXE with custom file detection
./scripts/apps/New-IntuneAppPackageFromInstaller.ps1 -InstallerPath 'C:\Installers\Tool.exe' -DetectionMethod File -FileDetectionPath 'C:\Program Files\Tool\Tool.exe'

# Custom script detection
./scripts/apps/New-IntuneAppPackageFromInstaller.ps1 -InstallerPath .\setup.exe -DetectionMethod Script -CustomDetectionScriptPath .\MyDetect.ps1
```

Sample run (MSI packaging):
```
> .\New-IntuneAppPackageFromInstaller.ps1 -InstallerPath "C:\Intune\Apps\7-ZipMSI\7z2501-x64.msi"
[2025-08-14 13:01:18] Starting New-IntuneAppPackageFromInstaller.ps1
[2025-08-14 13:01:18] PowerShell version: 7.5.2
[2025-08-14 13:01:18] IntuneWinAppUtil.exe not found. Downloading latest release...
[2025-08-14 13:01:18] No release assets found. Falling back to zipball_url archive.
[2025-08-14 13:01:19] Expanding archive...
[2025-08-14 13:01:19] Downloaded Win32 Content Prep Tool version tag: v1.8.7
[2025-08-14 13:01:19] Extracting MSI metadata...
[2025-08-14 13:01:19] Preparing to invoke IntuneWinAppUtil...
[2025-08-14 13:01:19] InstallCommand = msiexec /i "7z2501-x64.msi" /qn /norestart
[2025-08-14 13:01:19] UninstallCommand = msiexec /x {23170F69-40C1-2702-2501-000001000000} /qn /norestart
[2025-08-14 13:01:19] Detection = MSI
[2025-08-14 13:01:19] Invoking IntuneWinAppUtil.exe
[2025-08-14 13:01:19] IntuneWinAppUtil exit code: 0
[2025-08-14 13:01:19] Package created: C:\Intune\Apps\7-ZipMSI\IntunePackages\7-Zip_25.01__x64_edition__20250814-130119.intunewin
[2025-08-14 13:01:19] Metadata exported: C:\Intune\Apps\7-ZipMSI\IntunePackages\7-Zip_25.01__x64_edition__20250814-130119_Metadata.json
[2025-08-14 13:01:19] Summary:
 App Name      : 7-Zip 25.01 (x64 edition)
 Publisher     : Igor Pavlov
 Version       : 25.01.00.0
 InstallerType : MSI
 Package File  : C:\Intune\Apps\7-ZipMSI\IntunePackages\7-Zip_25.01__x64_edition__20250814-130119.intunewin
 Metadata File : C:\Intune\Apps\7-ZipMSI\IntunePackages\7-Zip_25.01__x64_edition__20250814-130119_Metadata.json
 Detection     : MSI
[2025-08-14 13:01:19] Completed.
```

Artifacts produced:
- .intunewin package (ready for Intune upload)
- Metadata.json (contains install/uninstall commands, detection rule data, silent switch hints)
- DetectionScript.ps1 (only when -DetectionMethod Script / custom script used)

### **[Invoke-StaleDeviceCleanup.ps1](./scripts/devices/Invoke-StaleDeviceCleanup.ps1)**
**Intune & Azure AD Device Lifecycle Cleanup**

Identifies and (optionally) retires or deletes stale, duplicate, failed-enrollment, and orphaned devices. Generates comprehensive candidate/action/skip CSV reports with safety features:
- Criteria: last sync (default 90 days), failed enrollments, no user, duplicate registrations
- Actions: Export (report only), Retire, Delete (Intune + optional Azure AD)
- Safety: WhatIf, Confirm, exclusion list, max device cap (default 50), JSON backup, rollback metadata export
- Reporting: candidates, planned actions, skipped (with reasons)

Example usage:
```powershell
Import-Module ./modules/IntuneToolkit/IntuneToolkit.psm1 -Force
Connect-IntuneGraph -PermissionLevel Standard
./scripts/devices/Invoke-StaleDeviceCleanup.ps1 -Action Export -WhatIf

./scripts/devices/Invoke-StaleDeviceCleanup.ps1 -Action Retire -StaleDays 120 -ExclusionListPath ./exclusions.csv -Verbose -Confirm

./scripts/devices/Invoke-StaleDeviceCleanup.ps1 -Action Delete -IncludeAzureAD -MaxDevices 20 -Confirm
```

### **[Get-IntuneComplianceReport.ps1](./scripts/compliance/Get-IntuneComplianceReport.ps1)**
Generates rich compliance reports (CSV / HTML / JSON) with policy insights and grouping.

```powershell
Import-Module ./modules/IntuneToolkit/IntuneToolkit.psm1 -Force
Connect-IntuneGraph -PermissionLevel ReadOnly -Quiet
./scripts/compliance/Get-IntuneComplianceReport.ps1 -OutputFormat HTML -IncludeDeviceDetails
```

### **[Add-AutopilotCorporateIdentifiers.ps1](./scripts/Add-AutopilotCorporateIdentifiers.ps1)**
**Windows Autopilot Device Preparation Migration Tool**

Migrates devices from traditional Windows Autopilot to Windows Autopilot device preparation using Full permission level.

### **[Add-MgDevicesWithAppToGroup.ps1](./scripts/Add-MgDevicesWithAppToGroup.ps1)**
Adds devices with specific Intune-managed applications to Azure AD groups using Microsoft Graph API (Standard permission level).

### **[Check-Intune-Enrollment.ps1](./scripts/Check-Intune-Enrollment.ps1)**
Checks Intune enrollment status for users in specified Azure AD groups (ReadOnly level).

### **[Update-Group.ps1](./scripts/Update-Group.ps1)**
Manages Azure AD group membership by adding or removing device IDs (On-prem AD sample, not using Graph).

### **[App Dependency Manager](./function-apps/app-dependency-manager/)**
Azure Function App for managing application dependency chains in Intune deployments.

## AI-Assisted Development
This project leverages modern development tools including AI-powered code assistance (e.g. GitHub Copilot) to accelerate scripting and enforce consistent patterns. All AI-generated or assisted contributions are reviewed and curated for accuracy, security, and adherence to best practices before inclusion. Manual validation remains required for production use.

## Requirements

- PowerShell 5.1 or PowerShell 7+
- Microsoft Graph PowerShell SDK
- Appropriate Microsoft Graph API permissions (granted via interactive consent when connecting)

## Setup

1. Install required PowerShell modules (Microsoft Graph):
   ```powershell
   Install-Module Microsoft.Graph -Scope CurrentUser
   ```
2. Clone the repository.
3. Run scripts using the IntuneToolkit connection pattern shown above.
4. Always test in Export / WhatIf mode before destructive operations.

## Quick Start Examples
```powershell
# Compliance (read-only)
Import-Module ./modules/IntuneToolkit/IntuneToolkit.psm1 -Force
Connect-IntuneGraph -PermissionLevel ReadOnly -Quiet
./scripts/compliance/Get-IntuneComplianceReport.ps1 -OutputFormat CSV

# Device cleanup (write)
Import-Module ./modules/IntuneToolkit/IntuneToolkit.psm1 -Force
Connect-IntuneGraph -PermissionLevel Standard
./scripts/devices/Invoke-StaleDeviceCleanup.ps1 -Action Retire -StaleDays 120 -WhatIf

# Autopilot migration (full)
Import-Module ./modules/IntuneToolkit/IntuneToolkit.psm1 -Force
Connect-IntuneGraph -PermissionLevel Full
./scripts/Add-AutopilotCorporateIdentifiers.ps1 -DryRun

# Win32 packaging (local only)
./scripts/apps/New-IntuneAppPackageFromInstaller.ps1 -InstallerPath C:\Installers\App.msi
```

## Usage Examples (Legacy Direct Calls Still Supported)
Direct script execution still works because each script imports/connects internally, but using the shared module first allows chaining multiple operations in one authenticated session.

## License

MIT License - Free to use, modify, and distribute.

---

*Part of the Digital Workplace automation toolkit by [@haakonwibe](https://github.com/haakonwibe/intune-management-toolkit)*
