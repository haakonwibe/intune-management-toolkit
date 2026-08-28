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
│   │   ├── intunewin-packager/
│   │   │   ├── New-IntuneWinPackage.ps1              # IntuneWinAppUtil.exe wrapper
│   │   │   └── Package-App.cmd                       # Explorer double-click launcher
│   │   ├── intunewin-builder/
│   │   │   └── New-IntuneAppPackageFromInstaller.ps1 # Win32 app packaging helper (.intunewin)
│   │   └── app-id-lookup/
│   │       ├── Get-AdminPortalIDs.ps1                # Look up App IDs for Microsoft admin portals
│   │       ├── Get-AppIDs.ps1                        # Bulk-resolve app names to Application IDs
│   │       └── Get-AppNamesFromIDs.ps1               # Reverse-resolve Application IDs to names
│   ├── bitlocker/
│   │   ├── Install-BitLockerDisableShortcut.ps1      # Intune app: desktop shortcut to disable BitLocker
│   │   ├── Uninstall-BitLockerDisableShortcut.ps1    # Uninstall script for Intune
│   │   └── Detect-BitLockerDisableShortcut.ps1       # Detection rule for Intune
│   ├── compliance/
│   │   └── Get-IntuneComplianceReport.ps1            # Compliance summary (HTML/JSON)
│   ├── devices/
│   │   └── Invoke-StaleDeviceCleanup.ps1             # Stale / orphaned device cleanup
│   ├── troubleshooting/
│   │   ├── Get-IntuneDeviceDiagnostics.ps1           # Multi‑level device diagnostics
│   │   ├── Invoke-MmpcDiagnostics.ps1                # MMP-C / linked (dual) enrollment diagnostics
│   │   └── README.md                                 # Troubleshooting scripts guide
│   ├── regional-settings/
│   │   ├── Install-RegionalSettings.ps1              # Set region, locale & timezone (ESP + desktop)
│   │   ├── Uninstall-RegionalSettings.ps1            # Rollback to previous regional settings
│   │   ├── Detect-RegionalSettings.ps1               # Detection rule for Intune
│   │   └── README.md                                 # Deployment guide & parameters
│   ├── language-packs/
│   │   ├── nb-NO/                                    # Per-language Win32 apps (13 languages)
│   │   │   ├── Install-LanguagePack.ps1              # Install language pack
│   │   │   └── Detect-LanguagePack.ps1               # Detection rule
│   │   ├── sv-SE/
│   │   ├── da-DK/
│   │   ├── fi-FI/
│   │   ├── de-DE/
│   │   ├── nl-NL/
│   │   ├── fr-FR/
│   │   ├── it-IT/
│   │   ├── es-ES/
│   │   ├── pt-PT/
│   │   ├── tr-TR/
│   │   ├── sq-AL/
│   │   └── hr-HR/
│   ├── proactive-remediations/
│   │   ├── local-admin/
│   │   │   ├── Detect-UserLocalAdmin.ps1             # Detection: check if user is local admin
│   │   │   └── Remediate-UserLocalAdmin.ps1          # Remediation: add user to Administrators
│   │   └── location-services/
│   │       ├── Detect-LocationServices.ps1           # Detection: check if Location Services is disabled
│   │       └── Remediate-LocationServices.ps1        # Remediation: enable Location Services
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
├── automation/
│   └── mmpc-triage/                                  # Azure Automation runbook: MMP-C triage orchestrator
│       ├── Invoke-MmpcTriageOrchestrator.ps1         # Reconciles triage groups from PR results (report-only → -Apply)
│       └── README.md                                 # Deploy & config guide
│
├── docs/
│   ├── mmpc-triage-design.md                         # MMP-C health triage pipeline design
│   └── remote-help-win32-packaging.html              # Remote Help + AVD unattended packaging reference
│
└── function-apps/
    └── app-dependency-manager/                       # Azure Function for app dependency automation
        ├── host.json
        ├── requirements.psd1
        ├── run.ps1
        └── README.md
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

### [IntuneWin Packager](./scripts/apps/intunewin-packager/)
Wrapper around `IntuneWinAppUtil.exe` for quick `.intunewin` packaging. Includes a `.cmd` launcher for double-click use from Explorer.

**Files:**
- `New-IntuneWinPackage.ps1` – PowerShell wrapper script
- `Package-App.cmd` – Explorer launcher

### [New-IntuneAppPackageFromInstaller.ps1](./scripts/apps/intunewin-builder/New-IntuneAppPackageFromInstaller.ps1)
Automates creation of Win32 Intune (.intunewin) packages from common installer types with metadata extraction and detection scaffolding.

**Key Features:** MSI metadata extraction, EXE heuristic detection (InnoSetup/NSIS/InstallShield), silent switch suggestions, Metadata.json + DetectionScript.ps1 generation, auto-downloads IntuneWinAppUtil.exe.

**Flags:** `-Init` (environment setup & tool download), `-Browse` (interactive installer selection from a folder).

**Worked example:** [Remote Help + AVD unattended packaging reference](./docs/remote-help-win32-packaging.html) — the three packages, their portal field values, detection rules and dependency chain.

### [App ID Lookup](./scripts/apps/app-id-lookup/)
Scripts to resolve Microsoft application names and IDs via the Graph API service principal catalog.

- **Get-AdminPortalIDs.ps1** – Look up Application IDs for Microsoft admin portals (Azure, Exchange, Intune, Entra, Purview, Teams, etc.)
- **Get-AppIDs.ps1** – Bulk-resolve display names to Application IDs
- **Get-AppNamesFromIDs.ps1** – Reverse-resolve Application IDs (GUIDs) to display names

**Key Features:** Graph-based lookup, deduplication, CSV export, handles missing apps gracefully.

> **Output is tenant data.** The resolved `ObjectId` values are service principal object IDs unique to the tenant the scripts run against (unlike `ApplicationId`, which is a global Microsoft constant). The exported `.csv`/`.xlsx` files are gitignored — regenerate them per tenant rather than committing them.

### [Regional Settings Deployment](./scripts/regional-settings/)
Intune Win32 app that configures Windows region, locale, and timezone during Autopilot enrollment. Runs as SYSTEM during ESP to set defaults before the user reaches the desktop. Two modes:

- **Default** – Sets regional formats (dates, numbers, timezone, geo location) while keeping the existing OS display language (e.g. English).
- **With `-InstallLanguagePack`** – Also downloads and installs the full language pack, switches the UI language, and exits with code 3010 to trigger a reboot.

**Files:**
- `Install-RegionalSettings.ps1` – Install script (regional formats + optional language pack)
- `Uninstall-RegionalSettings.ps1` – Rollback to previous settings
- `Detect-RegionalSettings.ps1` – Detection rule for Intune

**Parameters:** `-GeoId` (geographic location), `-Culture` (locale code, e.g. `nb-NO`), `-TimeZone` (Windows timezone ID), `-InstallLanguagePack` (switch to install full language pack and change UI language).

**Intune Deployment (regional formats only):**
| Setting | Value |
|---------|-------|
| Install command | `powershell.exe -ExecutionPolicy Bypass -File Install-RegionalSettings.ps1 -GeoId 177 -Culture "nb-NO" -TimeZone "W. Europe Standard Time"` |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -File Uninstall-RegionalSettings.ps1` |
| Install behavior | System |
| Detection | Custom script → `Detect-RegionalSettings.ps1` |

**Intune Deployment (full language pack):**
| Setting | Value |
|---------|-------|
| Install command | `powershell.exe -ExecutionPolicy Bypass -File Install-RegionalSettings.ps1 -GeoId 177 -Culture "nb-NO" -TimeZone "W. Europe Standard Time" -InstallLanguagePack` |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -File Uninstall-RegionalSettings.ps1` |
| Install behavior | System |
| Detection | Custom script → `Detect-RegionalSettings.ps1` |
| Return codes | Add `3010` = Soft reboot (success + reboot required) |

**Logging:** `C:\ProgramData\IntuneTools\RegionalSettings.log`

### [Language Packs](./scripts/language-packs/)
Per-language Win32 apps for installing language packs during Autopilot. Each language folder contains an install and detection script. Supported languages: nb-NO, sv-SE, da-DK, fi-FI, de-DE, nl-NL, fr-FR, it-IT, es-ES, pt-PT, tr-TR, sq-AL, hr-HR.

**Files per language:**
- `Install-LanguagePack.ps1` – Downloads and installs the language pack via `Install-Language`
- `Detect-LanguagePack.ps1` – Detection rule for Intune

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

### [Location Services Proactive Remediation](./scripts/proactive-remediations/location-services/)
Intune Proactive Remediation package that detects and re-enables system-wide Location Services. On Autopilot-provisioned devices where the OOBE privacy page is skipped, Location Services defaults to disabled and standard users cannot turn it back on.

**Files:**
- `Detect-LocationServices.ps1` – Detection script (checks the CapabilityAccessManager consent store)
- `Remediate-LocationServices.ps1` – Remediation script (enables Location Services via `SystemSettingsAdminFlows.exe`)

**Intune Deployment:**
| Setting | Value |
|---------|-------|
| Run this script using the logged-on credentials | No |
| Enforce script signature check | No |
| Run script in 64-bit PowerShell | Yes |

### [Get-IntuneDeviceDiagnostics.ps1](./scripts/troubleshooting/Get-IntuneDeviceDiagnostics.ps1)
Actionable per‑device diagnostics with progressive depth levels.

| Level | Purpose | Data Highlights |
|-------|---------|-----------------|
| Standard | Quick health | Core facts, sync age, compliance, encryption, storage |
| Advanced | Troubleshooting | + Config & compliance states, top apps, groups, autopilot, Defender/BitLocker, issues, recs |
| Detailed | Deep analysis | + Setting failures, conflicts, full app inventory, hardware, AAD device, recent actions, audit events, enhanced recommendations & summary |

**Exports:** JSON bundle (`-OutputPath`) including policies, settings (Detailed), apps, groups, autopilot, protection, audit events (if `-IncludeAuditLogs`), device actions, issues & recommendations.

### [Invoke-MmpcDiagnostics.ps1](./scripts/troubleshooting/Invoke-MmpcDiagnostics.ps1)
Diagnoses the **MMP-C / linked (dual) enrollment** channel that delivers Endpoint Privilege Management (EPM) and Device Inventory policies via Windows Declared Configuration (WinDC). A healthy OMA-DM enrollment says nothing about MMP-C health, so EPM policies can fail while every classic profile applies clean. Runs locally on the device — **self-contained, no IntuneToolkit/Graph dependency** — so it can also ship as a Proactive Remediation. Run elevated.

**Checks in one pass:**
- Both enrollments under `HKLM\SOFTWARE\Microsoft\Enrollments` and which is MMP-C
- The `LinkedEnrollment` subkey (`EnrollStatus`, `LastError`, `MMPCLocked`, `MmpcEnrollmentFlag`, `DiscoveryEndpoint`)
- The `deviceenroller.exe /EnrollMmpc` dual-enrollment scheduled task (a lingering task = stuck/incomplete)
- The MMP-C device certificate referenced by `SSLClientCertSearchCriteria`
- EPM agent service/folder and `DeviceHealthMonitoring` policy keys
- Recent failures in the DeviceManagement-Enterprise-Diagnostics-Provider/Admin log
- Endpoint reachability **and TLS-inspection detection** (re-signed server cert is the most common MMP-C break)

**Endpoint discovery:** only `discovery.dm.microsoft.com` is a fixed host — the enrollment/policy/auth URLs are returned dynamically by the discovery service, so the script **uncovers them from the device** (the `DiscoveryEndpoint` reg value + the DM diag log, and with `-DiscoverEndpoints` a live query of the discovery service) rather than hardcoding guesses.

**Output:** color-coded `[PASS]`/`[WARN]`/`[FAIL]`/`[INFO]` lines, a summary tally with the list of issues to fix, and (with `-PassThru`) a structured object you can capture (`$r = .\Invoke-MmpcDiagnostics.ps1 -PassThru`).

**Flags:** `-DiscoverEndpoints` (live discovery probe), `-Json` / `-JsonPath` (timestamped JSON report), `-PassThru` (return the result object), `-CollectCab` (MdmDiagnosticsTool cab), `-TriggerReEnrollment` (re-fires `deviceenroller /c /EnrollMmpc`; needs SYSTEM, prompts first), `-EventLookbackHours`.

See the [troubleshooting README](./scripts/troubleshooting/README.md) for the full check list, output interpretation, deployment-as-remediation notes, and future enhancements.

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
./scripts/apps/intunewin-builder/New-IntuneAppPackageFromInstaller.ps1 -InstallerPath .\setup.exe -OutputPath .\out

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
