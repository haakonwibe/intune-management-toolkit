# Regional Settings Deployment for Autopilot

Sets Windows Region, Regional format, and Timezone during Autopilot enrollment using Windows 11 cmdlets.

## Win32 App Deployment

### 1. Package the files

```powershell
IntuneWinAppUtil.exe -c ".\scripts\regional-settings" -s "Install-RegionalSettings.ps1" -o ".\output"
```

### 2. Create Win32 app in Intune

| Setting | Value |
|---------|-------|
| Name | `Regional Settings - Norway` |
| Install command | `powershell.exe -ExecutionPolicy Bypass -File Install-RegionalSettings.ps1 -GeoId 177 -Culture "nb-NO" -TimeZone "W. Europe Standard Time"` |
| Uninstall command | `cmd /c exit 0` |
| Install behavior | **System** |
| Detection rule | Script: `Detect-RegionalSettings.ps1` |

### 3. Assignment

- Assign to **Users** as **Required** for ESP Account Setup phase
- Assign as **Available** for Company Portal self-service

## Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `-GeoId` | Geographic location ID | `177` |
| `-Culture` | Culture/locale code | `nb-NO` |
| `-TimeZone` | Windows timezone ID | `W. Europe Standard Time` |

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

Uses Windows 11 PowerShell cmdlets:
```powershell
Set-TimeZone -Id $TimeZone                    # Timezone
Set-WinUILanguageOverride -Language $Culture  # UI language override
Set-WinUserLanguageList -LanguageList ...     # Preferred language list
Set-Culture -CultureInfo $Culture             # Regional format (date/time/number)
Set-WinSystemLocale -SystemLocale $Culture    # System locale
Set-WinHomeLocation -GeoId $GeoId             # Geographic location
Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true
```

## Detection

The install script creates a marker file at:
```
C:\ProgramData\IntuneTools\RegionalSettings.installed
```

The detection script simply checks if this file exists.

## Logs

```
C:\ProgramData\IntuneTools\RegionalSettings.log
```
