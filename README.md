# Intune Management Toolkit 🛠️

A collection of PowerShell scripts and Azure Function Apps for Microsoft Intune management and automation.

## Overview

Scripts and tools for common Intune administration tasks, including Windows Autopilot migrations, device group management, and app dependency automation.

**Features:**
- PowerShell 7 compatible with backward compatibility to 5.1
- Microsoft Graph API integration
- Error handling and logging
- Azure Function Apps for cloud automation

## 📁 **Repository Structure**

```
intune-management-toolkit/
│
├── scripts/                              # PowerShell automation scripts
│   ├── Add-AutopilotCorporateIdentifiers.ps1   # Autopilot migration tool
│   ├── Add-MgDevicesWithAppToGroup.ps1         # App-based device grouping
│   ├── Check-Intune-Enrollment.ps1             # Enrollment verification
│   └── Update-Group.ps1                        # Azure AD group management
│
└── function-apps/                        # Azure Function Apps
    └── app-dependency-manager/           # Intune app dependency automation
        ├── host.json
        ├── requirements.psd1
        └── run.ps1
```

## Tools & Scripts

### **[Add-AutopilotCorporateIdentifiers.ps1](./scripts/Add-AutopilotCorporateIdentifiers.ps1)**
**Windows Autopilot Device Preparation Migration Tool**

Migrates devices from traditional Windows Autopilot to Windows Autopilot device preparation.

**Features:**
- Device filtering and duplicate detection
- Optional source cleanup
- Migration tracking and logging
- Batch processing support

### **[Add-MgDevicesWithAppToGroup.ps1](./scripts/Add-MgDevicesWithAppToGroup.ps1)**
Adds devices with specific Intune-managed applications to Azure AD groups using Microsoft Graph API.

### **[Check-Intune-Enrollment.ps1](./scripts/Check-Intune-Enrollment.ps1)**
Checks Intune enrollment status for users in specified Azure AD groups.

### **[Update-Group.ps1](./scripts/Update-Group.ps1)**
Manages Azure AD group membership by adding or removing device IDs.

### **[App Dependency Manager](./function-apps/app-dependency-manager/)**
Azure Function App for managing application dependency chains in Intune deployments.

## Requirements

- PowerShell 5.1 or PowerShell 7+
- Microsoft Graph PowerShell SDK
- Appropriate Microsoft Graph API permissions for device and group management

## Setup

1. Install required PowerShell modules:
   ```powershell
   Install-Module Microsoft.Graph -Scope CurrentUser
   ```
2. Configure authentication (see individual script documentation)
3. Test scripts with a limited scope before production use

## Usage Examples

```powershell
# Check Autopilot migration (test mode)
.\Add-AutopilotCorporateIdentifiers.ps1 -TenantId "your-tenant-id" -WhatIf

# Add devices with specific app to a group
.\Add-MgDevicesWithAppToGroup.ps1 -AppName "Microsoft Teams" -GroupName "Teams-Devices"
```

## License

MIT License - Free to use, modify, and distribute.

---

*Part of the Digital Workplace automation toolkit by [@haakonwibe](https://github.com/haakonwibe)*
