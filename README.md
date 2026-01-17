# Intune Management Toolkit 🛠️

A collection of PowerShell scripts and Azure Function Apps for Microsoft Intune management and automation.

## Overview

Scripts and tools for common Intune administration tasks: Windows Autopilot migrations, device group management, application packaging & dependency automation, compliance reporting, stale device cleanup, and deep device diagnostics.

**Features:**
- PowerShell 7 (compatible with 5.1 where possible)
- Microsoft Graph API integration (least-privilege permission tiers)
- Consistent logging & error handling (IntuneToolkit module)
- JSON / HTML export options for reporting & ticket attachment
- Azure Function Apps for unattended automation

## 📁 Repository Structure
```
intune-management-toolkit/
│
├── scripts/
│   ├── apps/
│   │   └── New-IntuneAppPackageFromInstaller.ps1     # Win32 app packaging helper (.intunewin)
│   ├── bitlocker/
│   │   ├── Install-BitLockerDisableShortcut.ps1      # Intune app: desktop shortcut to disable BitLocker
│   │   ├── Uninstall-BitLockerDisableShortcut.ps1    # Uninstall script for Intune
│   │   └── Detect-BitLockerDisableShortcut.ps1       # Detection rule for Intune
│   ├── compliance/
│   │   └── Get-IntuneComplianceReport.ps1            # Compliance summary (HTML/JSON)
│   ├── devices/
│   │   └── Invoke-StaleDeviceCleanup.ps1             # Stale / orphaned device cleanup
│   ├── troubleshooting/
│   │   └── Get-IntuneDeviceDiagnostics.ps1           # Multi‑level device diagnostics
│   ├── proactive-remediations/
│   │   └── local-admin/
│   │       ├── Detect-UserLocalAdmin.ps1             # Detection: check if user is local admin
│   │       └── Remediate-UserLocalAdmin.ps1          # Remediation: add user to Administrators
│   ├── Add-AutopilotCorporateIdentifiers.ps1         # Autopilot migration tool
│   ├── Add-MgDevicesWithAppToGroup.ps1               # App‑based dynamic device grouping
│   ├── Check-Intune-Enrollment.ps1                   # Enrollment verification
│   └── Update-Group.ps1                              # Entra ID group membership management
│
├── modules/
│   └── IntuneToolkit/                                # Shared helper module (Graph + logging)
│       ├── IntuneToolkit.psm1
│       └── IntuneToolkit.psd1
│
└── function-apps/
    └── app-dependency-manager/                       # Azure Function for app dependency automation
        ├── host.json
        ├── requirements.psd1
        └── run.ps1
```

## Tools & Scripts

### [Add-AutopilotCorporateIdentifiers.ps1](./scripts/Add-AutopilotCorporateIdentifiers.ps1)
Migration helper to transition devices to Windows Autopilot Device Preparation with optional duplicate detection & cleanup.

**Key Features:** device filtering, batch processing, migration logging, WhatIf support.

### [Add-MgDevicesWithAppToGroup.ps1](./scripts/Add-MgDevicesWithAppToGroup.ps1)
Adds devices to an Entra ID / Intune group when a specified managed app is detected on the device.

**Key Features:** Graph filtering, idempotent adds, optional dry run.

### [Check-Intune-Enrollment.ps1](./scripts/Check-Intune-Enrollment.ps1)
Audits Intune enrollment status for users or groups and flags missing / stale enrollments.

### [Update-Group.ps1](./scripts/Update-Group.ps1)
Simple utility for adding/removing device IDs from an Entra ID security group (seed / maintenance scenarios).

### [New-IntuneAppPackageFromInstaller.ps1](./scripts/apps/New-IntuneAppPackageFromInstaller.ps1)
Automates creation of Win32 Intune (.intunewin) packages from common installer types.

**Key Features:** Silent switch heuristics, detection rule scaffolding, output folder hygiene.

### [Get-IntuneComplianceReport.ps1](./scripts/compliance/Get-IntuneComplianceReport.ps1)
Generates an HTML (and optional JSON) compliance dashboard with device counts, state breakdown, and issue flags.

**Key Features:** Export timestamping, color‑coded status, lightweight Graph footprint.

### [Invoke-StaleDeviceCleanup.ps1](./scripts/devices/Invoke-StaleDeviceCleanup.ps1)
Identifies and (optionally) retires / deletes stale, duplicate or orphaned device objects.

**Key Features:** Age thresholds, preview (WhatIf), exclusion patterns, action logging.

### [BitLocker Disable Shortcut](./scripts/bitlocker/)
Intune Win32 app that installs a desktop shortcut allowing users to disable BitLocker on the OS drive. Useful for preparing devices for Intune/Autopilot reset without BitLocker PIN blocking the process.

**Files:**
- `Install-BitLockerDisableShortcut.ps1` – Install script (creates scheduled task + desktop shortcut)
- `Uninstall-BitLockerDisableShortcut.ps1` – Uninstall script
- `Detect-BitLockerDisableShortcut.ps1` – Detection rule for Intune

**Intune Deployment:**
| Setting | Value |
|---------|-------|
| Install command | `powershell.exe -ExecutionPolicy Bypass -File Install-BitLockerDisableShortcut.ps1` |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -File Uninstall-BitLockerDisableShortcut.ps1` |
| Install behavior | System |
| Detection | Custom script → `Detect-BitLockerDisableShortcut.ps1` |

### [Local Admin Proactive Remediation](./scripts/proactive-remediations/local-admin/)
Intune Proactive Remediation package that adds the currently logged-on user to the local Administrators group.

**Files:**
- `Detect-UserLocalAdmin.ps1` – Detection script (checks if user is already admin)
- `Remediate-UserLocalAdmin.ps1` – Remediation script (adds user to Administrators)

**Intune Deployment:**
| Setting | Value |
|---------|-------|
| Run this script using the logged-on credentials | No |
| Enforce script signature check | No |
| Run script in 64-bit PowerShell | Yes |

**Logging:** `C:\ProgramData\IntuneTools\LocalAdmin.log`

### [Get-IntuneDeviceDiagnostics.ps1](./scripts/troubleshooting/Get-IntuneDeviceDiagnostics.ps1)
Actionable per‑device diagnostics with progressive depth levels.

| Level | Purpose | Data Highlights |
|-------|---------|-----------------|
| Standard | Quick health | Core facts, sync age, compliance, encryption, storage |
| Advanced | Troubleshooting | + Config & compliance states, top apps, groups, autopilot, Defender/BitLocker, issues, recs |
| Detailed | Deep analysis | + Setting failures, conflicts, full app inventory, hardware, AAD device, recent actions, audit events, enhanced recommendations & summary |

**Exports:** JSON bundle (`-OutputPath`) including policies, settings (Detailed), apps, groups, autopilot, protection, audit events (if `-IncludeAuditLogs`), device actions, issues & recommendations.

## IntuneToolkit Module
Shared helpers under `modules/IntuneToolkit` provide:
- `Connect-IntuneGraph` with permission level presets (ReadOnly / Standard / Full)
- `Write-IntuneLog` structured console logging
- Utility functions leveraged across scripts (connection reuse, batching)

## Requirements
- PowerShell 7 (recommended) or Windows PowerShell 5.1
- Microsoft Graph PowerShell SDK (`Install-Module Microsoft.Graph`)
- Appropriate delegated permissions (additional AuditLog/Directory scopes only when requested)

## Quick Start
```powershell
# Install Graph SDK
Install-Module Microsoft.Graph -Scope CurrentUser

# Run a quick device health check
./scripts/troubleshooting/Get-IntuneDeviceDiagnostics.ps1 -DeviceName LAPTOP-123

# Generate compliance report
./scripts/compliance/Get-IntuneComplianceReport.ps1 -OutputPath ./reports

# Package an installer
./scripts/apps/New-IntuneAppPackageFromInstaller.ps1 -InstallerPath .\setup.exe -OutputPath .\out

# Identify stale devices (preview)
./scripts/devices/Invoke-StaleDeviceCleanup.ps1 -DaysInactive 60 -WhatIf
```

## Security & Best Practices
- Principle of least privilege: run with lowest permission tier required
- Use `-WhatIf` / preview flags before destructive actions (cleanup, migration)
- Review exported JSON before sharing (sanitise identifiers if needed)

## License
MIT License – free to use, modify & distribute.

---
*Digital Workplace automation toolkit by [@haakonwibe](https://github.com/haakonwibe)*
