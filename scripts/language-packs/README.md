# Language Pack Deployment for Autopilot

Per-language Win32 apps that install Windows language packs and set them as the system UI language during Autopilot enrollment. Each language is packaged as a separate Intune Win32 app so they can be assigned independently.

## Supported Languages

| Language | Folder | Display Name |
|----------|--------|-------------|
| nb-NO | `nb-NO/` | Norwegian (Bokmål) |
| sv-SE | `sv-SE/` | Swedish |
| da-DK | `da-DK/` | Danish |
| fi-FI | `fi-FI/` | Finnish |
| de-DE | `de-DE/` | German |
| nl-NL | `nl-NL/` | Dutch |
| fr-FR | `fr-FR/` | French |
| it-IT | `it-IT/` | Italian |
| es-ES | `es-ES/` | Spanish |
| pt-PT | `pt-PT/` | Portuguese |
| tr-TR | `tr-TR/` | Turkish |
| sq-AL | `sq-AL/` | Albanian |
| hr-HR | `hr-HR/` | Croatian |

## Win32 App Deployment

### 1. Package a language

```powershell
IntuneWinAppUtil.exe -c ".\scripts\language-packs\nb-NO" -s "Install-LanguagePack.ps1" -o ".\output"
```

### 2. Create Win32 app in Intune

| Setting | Value (example: Norwegian) |
|---------|-------|
| Name | `Language Pack - Norwegian (nb-NO)` |
| Install command | `powershell.exe -ExecutionPolicy Bypass -File Install-LanguagePack.ps1` |
| Uninstall command | `cmd /c exit 0` |
| Install behavior | **System** |
| Detection rule | Script: `Detect-LanguagePack.ps1` |
| Return codes | Add `3010` = Soft reboot (success + reboot required) |

### 3. Assignment

- Assign to **Devices** as **Required** for ESP Device Setup phase
- Can be combined with the Regional Settings app (which handles timezone, formats, and geo location separately)

## What the Script Does

Each `Install-LanguagePack.ps1` script:

1. Downloads and installs the language pack via `Install-Language -CopyToSettings`
2. Sets the system preferred UI language via `Set-SystemPreferredUILanguage`
3. Sets the UI language override via `Set-WinUILanguageOverride`
4. Makes the language primary in the user language list
5. Copies settings to the welcome screen and new user accounts
6. Exits with code 3010 to trigger a reboot

## Detection

Each `Detect-LanguagePack.ps1` checks if the language pack is fully installed using `Get-InstalledLanguage`, verifying that the language has actual language packs (not just features).

## Logs

```
C:\ProgramData\IntuneTools\LanguagePack-<language>.log          # e.g. LanguagePack-nb-NO.log
C:\ProgramData\IntuneTools\LanguagePack-<language>.installed    # Marker file for detection
```

## Relationship to Regional Settings

These language pack apps **change the OS display language**. If you only need to change date/time/number formats and timezone without changing the UI language, use the [Regional Settings](../regional-settings/) app instead.

For a full localization setup, deploy both:
1. **Language Pack app** — installs the language and switches the UI
2. **Regional Settings app** — sets timezone, date/number formats, and geo location
