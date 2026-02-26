<#
.SYNOPSIS
    Uninstalls the regional settings Win32 app and restores previous settings.

.DESCRIPTION
    Reads the marker file created by Install-RegionalSettings.ps1, restores the
    regional settings that were in place before installation, and removes the
    detection marker and log files.

    If the marker file is missing or does not contain previous settings, the script
    still removes the detection files and exits successfully.

    Note: Installed language packs cannot be removed automatically and will remain.

.NOTES
    Author  : Haakon Wibe
    License : MIT
    Context : Use as the uninstall command for the Intune Win32 app.
              Uninstall command: powershell.exe -ExecutionPolicy Bypass -File Uninstall-RegionalSettings.ps1
#>

$ErrorActionPreference = "Stop"

$LogFolder = "C:\ProgramData\IntuneTools"
$InstallLog = Join-Path $LogFolder "RegionalSettings.log"
$UninstallLog = Join-Path $LogFolder "RegionalSettings-Uninstall.log"
$MarkerFile = Join-Path $LogFolder "RegionalSettings.installed"

# Ensure log folder exists
if (-not (Test-Path $LogFolder)) {
    New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] $Message"
    Add-Content -Path $UninstallLog -Value $entry -Force
    Write-Host $entry
}

Write-Log "=========================================="
Write-Log "Regional Settings Uninstall Started"
Write-Log "=========================================="

# Restore previous settings if the marker file contains them
if (Test-Path $MarkerFile) {
    try {
        $Marker = Get-Content -Path $MarkerFile -Raw | ConvertFrom-Json
        $Prev = $Marker.PreviousSettings

        if ($Prev) {
            Write-Log "Restoring previous settings..."

            Set-TimeZone -Id $Prev.TimeZone
            Write-Log "Restored timezone to $($Prev.TimeZone)"

            Set-Culture -CultureInfo $Prev.Culture
            Write-Log "Restored culture to $($Prev.Culture)"

            Set-WinSystemLocale -SystemLocale $Prev.SystemLocale
            Write-Log "Restored system locale to $($Prev.SystemLocale)"

            Set-WinHomeLocation -GeoId $Prev.GeoId
            Write-Log "Restored home location to GeoId $($Prev.GeoId)"

            $LanguageList = $Prev.LanguageList | ForEach-Object { New-WinUserLanguageList -Language $_ }
            Set-WinUserLanguageList -LanguageList $LanguageList -Force
            Write-Log "Restored user language list to: $($Prev.LanguageList -join ', ')"

            if ($Prev.UILanguageOverride) {
                Set-WinUILanguageOverride -Language $Prev.UILanguageOverride
                Write-Log "Restored UI language override to $($Prev.UILanguageOverride)"
            }
            else {
                Clear-WinUILanguageOverride -ErrorAction SilentlyContinue
                Write-Log "Cleared UI language override (none was set previously)"
            }

            Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true
            Write-Log "Copied restored settings to welcome screen and new user accounts"
        }
        else {
            Write-Log "No previous settings found in marker file, skipping restore"
        }
    }
    catch {
        Write-Log "WARNING: Failed to restore settings: $($_.Exception.Message)"
        Write-Log "Continuing with cleanup..."
    }
}
else {
    Write-Log "No marker file found, skipping restore"
}

# Remove detection and install log files
Remove-Item -Path $MarkerFile -Force -ErrorAction SilentlyContinue
Write-Log "Removed marker file"

Remove-Item -Path $InstallLog -Force -ErrorAction SilentlyContinue
Write-Log "Removed install log"

Write-Log "=========================================="
Write-Log "Regional Settings Uninstall Completed"
Write-Log "=========================================="

exit 0
