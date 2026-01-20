# Regional Settings Deployment for Autopilot

Sets Windows Region and Regional format during Autopilot enrollment (ESP Account Setup phase).

## Quick Start

### Option 1: Win32 App (Recommended for ESP)

This method runs during ESP Account Setup phase, ensuring settings are applied before the user sees the desktop.

1. **Package the files:**
   ```powershell
   # Download IntuneWinAppUtil if needed
   # https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool

   IntuneWinAppUtil.exe -c ".\scripts\regional-settings" -s "Install-RegionalSettings.ps1" -o ".\output"
   ```

2. **Create Win32 app in Intune:**
   - Name: `Regional Settings - Norway` (or your region)
   - Install command:
     ```
     powershell.exe -ExecutionPolicy Bypass -File Install-RegionalSettings.ps1 -GeoId 177 -Culture "nb-NO" -CopyToSystem -CopyToDefaultUser -CreateLogonTask
     ```
   - Uninstall command: `cmd /c exit 0`
   - Install behavior: **System**
   - Detection rule: Use `Detect-RegionalSettings.ps1` (edit expected values first)

3. **Assignment:**
   - Assign to **Users** (not devices) for Account Setup phase
   - Set as **Required**

4. **ESP Configuration:**
   - In your Enrollment Status Page profile, ensure "Block device use until required apps are installed" includes this app

### Option 2: Platform Script (Simpler)

For scenarios where ESP timing isn't critical:

1. Go to **Intune > Devices > Scripts**
2. Add PowerShell script: `Install-RegionalSettings.ps1`
3. Configure:
   - Run as: **User** (for user context) or **System** (with full parameters)
   - Parameters (in script settings): Edit the script or use a wrapper

## Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `-GeoId` | Geographic location ID | `177` (Norway) |
| `-Culture` | Culture/locale code | `nb-NO` |
| `-CopyToSystem` | Apply to welcome screen (requires SYSTEM) | Switch |
| `-CopyToDefaultUser` | Apply to new user profiles (requires SYSTEM) | Switch |
| `-CreateLogonTask` | Create first-logon task for complete application | Switch |

## Common GeoIDs and Cultures

| Country | GeoId | Culture |
|---------|-------|---------|
| Norway | 177 | nb-NO (Bokmål), nn-NO (Nynorsk) |
| Sweden | 221 | sv-SE |
| Denmark | 61 | da-DK |
| Finland | 77 | fi-FI |
| Germany | 94 | de-DE |
| France | 84 | fr-FR |
| UK | 242 | en-GB |
| USA | 244 | en-US |
| Netherlands | 176 | nl-NL |

Full list: [Microsoft GeoID Table](https://learn.microsoft.com/en-us/windows/win32/intl/table-of-geographical-locations)

## Why Use `-CreateLogonTask`?

Some regional settings are loaded at the start of a user session. When running during ESP:
- Registry-based settings apply immediately
- Some session-dependent settings need a fresh logon

The `-CreateLogonTask` parameter creates a one-time scheduled task that:
1. Runs at user logon
2. Applies settings using PowerShell cmdlets (`Set-Culture`, `Set-WinHomeLocation`)
3. Deletes itself after running

This ensures 100% of settings are correct from the user's perspective.

## Logs

Installation logs are written to:
```
C:\ProgramData\IntuneTools\RegionalSettings.log
```

## Troubleshooting

**Settings not applied:**
- Check logs at `C:\ProgramData\IntuneTools\RegionalSettings.log`
- Verify the app ran during ESP (check Intune app install status)
- User may need to sign out/in for session-dependent settings

**Detection fails:**
- Edit `Detect-RegionalSettings.ps1` with correct `$ExpectedGeoId` and `$ExpectedCulture`
- Verify values match the install command parameters

**ESP timeout:**
- The script typically runs in under 5 seconds
- If ESP times out, check for other apps/policies causing delays
