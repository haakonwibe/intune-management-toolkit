<#
.SYNOPSIS
    Installs the Finnish language pack and sets it as the Windows UI language.

.DESCRIPTION
    Downloads and installs the fi-FI language pack via Install-Language, sets it as the
    system preferred UI language, and applies the change to the welcome screen and new
    user accounts. Designed to run as SYSTEM during Autopilot ESP via Intune Win32 app.

    Exits with code 3010 to signal a reboot is required for the language change to take effect.

.NOTES
    Author  : Haakon Wibe
    License : MIT
    Context : Deploy via Intune Win32 app in SYSTEM context.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# Configuration
$Language   = "fi-FI"
$LogFolder  = "C:\ProgramData\IntuneTools"
$LogPath    = Join-Path $LogFolder "LanguagePack-$Language.log"
$MarkerFile = Join-Path $LogFolder "LanguagePack-$Language.installed"

# Ensure log folder exists
if (-not (Test-Path $LogFolder)) {
    New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] $Message"
    Add-Content -Path $LogPath -Value $entry -Force
    Write-Host $entry
}

# Main execution
Write-Log "=========================================="
Write-Log "Language Pack Installation Started"
Write-Log "Language: $Language"
Write-Log "=========================================="

try {
    # Snapshot current settings for rollback
    $UIOverride = Get-WinUILanguageOverride -ErrorAction SilentlyContinue
    $PreviousSettings = @{
        SystemPreferredUILanguage = (Get-SystemPreferredUILanguage -ErrorAction SilentlyContinue)
        UILanguageOverride        = if ($UIOverride) { $UIOverride.LanguageTag } else { $null }
        LanguageList              = @((Get-WinUserLanguageList).LanguageTag)
    }
    Write-Log "Saved previous settings for rollback: UIOverride=$($PreviousSettings.UILanguageOverride), LanguageList=$($PreviousSettings.LanguageList -join ', ')"

    # Install language pack from Microsoft CDN
    # -CopyToSettings sets the System and Default Device Settings (display language,
    # regional and locale formats) but only for new users and the system default.
    # A reboot is required, and the user would still need to manually select the
    # language in Settings. The explicit cmdlets below ensure the language is fully
    # applied without manual intervention.
    Write-Log "Installing language pack for $Language (this may take 10-20 minutes)..."
    Install-Language -Language $Language -CopyToSettings
    Write-Log "Language pack for $Language installed successfully"

    # Set system preferred UI language (system-wide default for all users)
    Set-SystemPreferredUILanguage -Language $Language
    Write-Log "Set system preferred UI language to $Language"

    # Set UI language override (forces the display language for the current user
    # profile without requiring manual selection in Settings after reboot)
    Set-WinUILanguageOverride -Language $Language
    Write-Log "Set UI language override to $Language"

    # Set preferred language list with new language as primary, preserving existing
    # languages so keyboard layouts and regional preferences are not lost
    $OldList = Get-WinUserLanguageList
    $UserLanguageList = New-WinUserLanguageList -Language $Language
    $UserLanguageList += $OldList | Where-Object { $_.LanguageTag -ne $Language }
    Set-WinUserLanguageList -LanguageList $UserLanguageList -Force
    Write-Log "Set user language list with $Language as primary"

    # Copy settings to welcome screen and new user accounts
    Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true
    Write-Log "Copied settings to welcome screen and new user accounts"

    # Create marker file for detection (includes previous settings for rollback)
    @{
        Language         = $Language
        InstalledAt      = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        PreviousSettings = $PreviousSettings
    } | ConvertTo-Json -Depth 3 | Set-Content -Path $MarkerFile -Force
    Write-Log "Created marker file: $MarkerFile"

    Write-Log "=========================================="
    Write-Log "Language pack installation completed"
    Write-Log "=========================================="

    Write-Log "Exiting with code 3010 (reboot required for language pack)"
    exit 3010
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Log $_.ScriptStackTrace
    exit 1
}
