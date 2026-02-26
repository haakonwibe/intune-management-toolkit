# Regional Settings Deployment for Autopilot

Sets Windows Region, Regional format, and Timezone during Autopilot enrollment using Windows 11 cmdlets. Optionally installs a full language pack to switch the OS display language.

## Win32 App Deployment

### 1. Package the files

```powershell
IntuneWinAppUtil.exe -c ".\scripts\regional-settings" -s "Install-RegionalSettings.ps1" -o ".\output"
```

### 2. Create Win32 app in Intune

**Regional formats only** (keeps English UI):

| Setting | Value |
|---------|-------|
| Name | `Regional Settings - Norway` |
| Install command | `powershell.exe -ExecutionPolicy Bypass -File Install-RegionalSettings.ps1 -GeoId 177 -Culture "nb-NO" -TimeZone "W. Europe Standard Time"` |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -File Uninstall-RegionalSettings.ps1` |
| Install behavior | **System** |
| Detection rule | Script: `Detect-RegionalSettings.ps1` |

**Full language pack** (switches UI to Norwegian):

| Setting | Value |
|---------|-------|
| Name | `Language Pack - Norway` |
| Install command | `powershell.exe -ExecutionPolicy Bypass -File Install-RegionalSettings.ps1 -GeoId 177 -Culture "nb-NO" -TimeZone "W. Europe Standard Time" -InstallLanguagePack` |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -File Uninstall-RegionalSettings.ps1` |
| Install behavior | **System** |
| Detection rule | Script: `Detect-RegionalSettings.ps1` |
| Return codes | Add `3010` as success (hard reboot) |

### 3. Assignment

- Assign to **Users** as **Required** for ESP Account Setup phase
- Assign as **Available** for Company Portal self-service

## Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `-GeoId` | Geographic location ID | `177` |
| `-Culture` | Culture/locale code | `nb-NO` |
| `-TimeZone` | Windows timezone ID | `W. Europe Standard Time` |
| `-InstallLanguagePack` | Switch to install full language pack and change UI language | N/A |

## Common Configurations

| Country | GeoId | Culture | TimeZone |
|---------|-------|---------|----------|
| Norway | 177 | nb-NO | W. Europe Standard Time |
| Sweden | 221 | sv-SE | W. Europe Standard Time |
| Denmark | 61 | da-DK | W. Europe Standard Time |
| Finland | 77 | fi-FI | FLE Standard Time |
| Germany | 94 | de-DE | W. Europe Standard Time |
| France | 84 | fr-FR | W. Europe Standard Time |
| UK | 242 | en-GB | GMT Standard Time |
| USA (Eastern) | 244 | en-US | Eastern Standard Time |
| USA (Pacific) | 244 | en-US | Pacific Standard Time |
| Netherlands | 176 | nl-NL | W. Europe Standard Time |

## What the Script Does

### Default (regional formats only)

Sets date/time/number formats and timezone without changing the OS display language:

```powershell
Set-TimeZone -Id $TimeZone                    # Timezone
Set-WinUserLanguageList -LanguageList ...     # Append culture to language list (keeps existing display language)
Set-Culture -CultureInfo $Culture             # Regional format (date/time/number)
Set-WinSystemLocale -SystemLocale $Culture    # System locale
Set-WinHomeLocation -GeoId $GeoId             # Geographic location
Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true
```

### With -InstallLanguagePack

Downloads and installs the full language pack, then switches the UI language:

```powershell
Set-TimeZone -Id $TimeZone
Install-Language -Language $Culture -CopyToSettings   # Download & install language pack (10-20 min)
Set-WinUILanguageOverride -Language $Culture           # Switch UI display language
Set-WinUserLanguageList -LanguageList ...              # Culture as primary language
Set-Culture -CultureInfo $Culture
Set-WinSystemLocale -SystemLocale $Culture
Set-WinHomeLocation -GeoId $GeoId
Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true
```

Exit code 3010 signals Intune to schedule a reboot (required for the UI language change to take effect).

## Uninstall

The `Uninstall-RegionalSettings.ps1` script restores the regional settings that were in place before installation and removes the detection marker and log files. The install script snapshots the current settings into the marker file, and the uninstall script reads them back to roll back all changes.

**Restored:** timezone, culture, system locale, GeoID, user language list, UI language override.
**Not restored:** installed language packs (no `Uninstall-Language` cmdlet exists).

## Detection

The install script creates a marker file at:
```
C:\ProgramData\IntuneTools\RegionalSettings.installed
```

The detection script simply checks if this file exists.

## Logs

```
C:\ProgramData\IntuneTools\RegionalSettings.log              # Install log (removed on uninstall)
C:\ProgramData\IntuneTools\RegionalSettings-Uninstall.log    # Uninstall log (persists)
```
