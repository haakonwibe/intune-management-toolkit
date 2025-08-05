# Intune Tools and Utilities

:toolbox: A collection of scripts and function apps for Microsoft Intune automation and management.

## :file_folder: Folder Structureintune-tools/
│
├── scripts/
│   ├── Add-AutopilotCorporateIdentifiers.ps1
│   ├── Add-MgDevicesWithAppToGroup.ps1
│   ├── Check-Intune-Enrollment.ps1
│   └── Update-Group.ps1
│
└── function-apps/
    └── app-dependency-manager/
        ├── host.json
        ├── requirements.psd1
        └── run.ps1
## :rocket: Tools

### [Add-AutopilotCorporateIdentifiers.ps1](./scripts/Add-AutopilotCorporateIdentifiers.ps1)
**Windows Autopilot Device Preparation Migration Tool** - Migrates devices from traditional Windows Autopilot to Windows Autopilot device preparation. Features include device filtering, duplicate detection, optional source cleanup, and comprehensive migration tracking.

### [Add-MgDevicesWithAppToGroup.ps1](./scripts/Add-MgDevicesWithAppToGroup.ps1)
Adds devices associated with an Intune-managed app to an Azure AD group using Microsoft Graph.

### [Check-Intune-Enrollment.ps1](./scripts/Check-Intune-Enrollment.ps1)
Checks if users in a group have their devices enrolled in Intune.

### [Update-Group.ps1](./scripts/Update-Group.ps1)
Updates an Azure AD group's membership by adding or removing device IDs.

### [App Dependency Manager](./function-apps/app-dependency-manager/)
An Azure Function App that manages app dependencies for Intune deployments.

## :package: Usage

- Scripts are located under the `scripts` folder
- Function apps are located under the `function-apps` folder
- Scripts are designed for use with Windows PowerShell 5.1 or PowerShell 7+
- See individual files and folders for setup and usage instructions

## :lock: License

MIT — free to use, modify, and share.
