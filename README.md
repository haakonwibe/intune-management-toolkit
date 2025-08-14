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
- Comprehensive compliance, inventory & device diagnostics reporting
- Central IntuneToolkit module with standardized Graph connection & utilities
- Win32 app packaging helper (automatic Intune .intunewin packaging)

## 📁 **Repository Structure**

```
intune-management-toolkit/
│
├── scripts/                              # PowerShell automation scripts
│   ├── compliance/
│   │   └── Get-IntuneComplianceReport.ps1        # Compliance reporting (HTML / JSON)
│   ├── devices/
│   │   └── Invoke-StaleDeviceCleanup.ps1         # Stale / orphaned device cleanup
│   ├── apps/
│   │   └── New-IntuneAppPackageFromInstaller.ps1 # Win32 packaging (.intunewin)
│   ├── troubleshooting/
│   │   └── Get-IntuneDeviceDiagnostics.ps1       # Multi-level device diagnostics (Standard/Advanced/Detailed)
│   ├── Add-AutopilotCorporateIdentifiers.ps1     # Autopilot migration tool
│   ├── Add-MgDevicesWithAppToGroup.ps1           # App-based device grouping
│   ├── Check-Intune-Enrollment.ps1               # Enrollment verification
│   └── Update-Group.ps1                          # Azure AD group management (placeholder)
│
├── modules/
│   └── IntuneToolkit/                           # Reusable helper module
│       ├── IntuneToolkit.psm1
│       └── IntuneToolkit.psd1
│
└── function-apps/                        # Azure Function Apps
    └── app-dependency-manager/           # Intune app dependency automation
        ├── host.json
        ├── requirements.psd1
        └── run.ps1
```

## 🔍 Highlight: Get-IntuneDeviceDiagnostics.ps1
Actionable diagnostics for a single Intune managed device (or a user's most recent device) with progressively deeper Graph data.

| Level | Purpose | Typical Runtime | Data Surface (summary) |
|-------|---------|-----------------|------------------------|
| Standard | Quick health snapshot (help desk) | < 5s | Core device facts, sync age, compliance, encryption, storage stats |
| Advanced | Troubleshooting context | ~5–15s | Adds config profile states, compliance policy set, app inventory (top N), groups, autopilot, Defender / BitLocker indicators, issue analysis, recommendations |
| Detailed | Deep forensic view | 15s+ (org size dependent) | Adds setting-level failing details, conflict/error config settings, expanded app list (with size), hardware metrics, AAD device info, recent actions, audit events, enhanced recommendations, summary health classification |

### Usage Examples
```
# Quick health (default Standard)
./scripts/troubleshooting/Get-IntuneDeviceDiagnostics.ps1 -DeviceName LAPTOP-123

# Advanced troubleshooting with remediation suggestions
./scripts/troubleshooting/Get-IntuneDeviceDiagnostics.ps1 -UserPrincipalName user@contoso.com -DiagnosticLevel Advanced -ShowRemediation

# Detailed forensic export with audit logs & JSON bundle
./scripts/troubleshooting/Get-IntuneDeviceDiagnostics.ps1 -DeviceId <guid> -DiagnosticLevel Detailed -IncludeAuditLogs -ShowRemediation -OutputPath ./diag
```

### Key Switches
- `-DiagnosticLevel Standard|Advanced|Detailed`
- `-UserPrincipalName` / `-DeviceName` / `-DeviceId`
- `-ShowRemediation` (recommendation engine)
- `-IncludeAuditLogs` (auto-enabled for Detailed)
- `-OutputPath` (writes JSON bundle for ticket attachment / automation)
- `-AllUserDevices` (enumerate every device for the supplied UPN)

### Issue Detection Heuristics (non-exhaustive)
- Stale or missing sync (24h / 7d thresholds)
- Duplicate compliance policy state entries
- Non-Windows policies targeting Windows devices (name heuristic)
- Non-compliant policies & failing settings (Detailed)
- Configuration profile conflicts / errors
- Low disk space (<10% / <20%)
- Missing disk encryption signal

### Exported JSON (when -OutputPath used)
Includes: Device object, policies, (Detailed: per-setting failures), configuration states, detected apps, groups, autopilot record, protection state, AAD device, audit events (if requested), log collection requests, device action results (Detailed), issues & recommendations.

## IntuneToolkit Module (Core Utilities)
All scripts leverage `modules/IntuneToolkit/IntuneToolkit.psm1` providing:
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

> The diagnostics script requests additional scopes (AuditLog.Read.All / Directory.Read.All) only when you specify `-IncludeAuditLogs` or are in Detailed mode.

## Prerequisites
- Microsoft Graph PowerShell SDK modules installed (core + beta if using advanced install status endpoints in future)
- Appropriate Graph delegated permissions for chosen operations
- PowerShell 7 recommended (Windows PowerShell 5.1 supported)

## Contributing
PRs welcome: add new diagnostics, extend reporting, or integrate additional Intune data surfaces (e.g. update rings, compliance trend history).

## License
MIT — see LICENSE file.

---

*Part of the Digital Workplace automation toolkit by [@haakonwibe](https://github.com/haakonwibe/intune-management-toolkit)*
