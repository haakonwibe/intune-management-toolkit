<#
.SYNOPSIS
    Sets Windows Region, Regional format, and Timezone during Autopilot enrollment.

.DESCRIPTION
    Configures regional settings (GeoID, culture/locale, timezone) using Windows 11 cmdlets.
    Designed to run as SYSTEM during ESP to set defaults before user sees the desktop.

.PARAMETER GeoId
    The geographic location ID. Examples: 177 (Norway), 244 (United States), 94 (Germany).
    See: https://learn.microsoft.com/en-us/windows/win32/intl/table-of-geographical-locations

.PARAMETER Culture
    The culture/locale code. Examples: nb-NO (Norwegian Bokmål), en-US, de-DE.

.PARAMETER TimeZone
    The Windows timezone ID. Examples: "W. Europe Standard Time" (Norway), "Pacific Standard Time" (US West).
    Run Get-TimeZone -ListAvailable to see all options.

.EXAMPLE
    .\Install-RegionalSettings.ps1 -GeoId 177 -Culture "nb-NO" -TimeZone "W. Europe Standard Time"
    Sets regional settings to Norway/Norwegian Bokmål with Central European timezone.

.NOTES
    Author  : Haakon Wibe
    License : MIT
    Context : Deploy via Intune Win32 app in SYSTEM context.

    Common GeoIDs:
        Norway      = 177
        Sweden      = 221
        Denmark     = 61
        Finland     = 77
        USA         = 244
        UK          = 242
        Germany     = 94
        France      = 84
        Netherlands = 176

    Common Timezones:
        Norway/Sweden/Denmark   = "W. Europe Standard Time"
        Finland                 = "FLE Standard Time"
        UK                      = "GMT Standard Time"
        US Eastern              = "Eastern Standard Time"
        US Pacific              = "Pacific Standard Time"
        Germany/France          = "W. Europe Standard Time"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [int]$GeoId,

    [Parameter(Mandatory = $true)]
    [string]$Culture,

    [Parameter(Mandatory = $true)]
    [string]$TimeZone
)

$ErrorActionPreference = "Stop"

# Configuration
$LogFolder = "C:\ProgramData\IntuneTools"
$LogPath = Join-Path $LogFolder "RegionalSettings.log"
$MarkerFile = Join-Path $LogFolder "RegionalSettings.installed"

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
Write-Log "Regional Settings Installation Started"
Write-Log "GeoId: $GeoId, Culture: $Culture, TimeZone: $TimeZone"
Write-Log "=========================================="

try {
    # Set timezone
    Set-TimeZone -Id $TimeZone
    Write-Log "Set timezone to $TimeZone"

    # Set UI language override
    Set-WinUILanguageOverride -Language $Culture
    Write-Log "Set UI language override to $Culture"

    # Set preferred language list (adds to existing, making new language first)
    $OldList = Get-WinUserLanguageList
    $UserLanguageList = New-WinUserLanguageList -Language $Culture
    $UserLanguageList += $OldList | Where-Object { $_.LanguageTag -ne $Culture }
    Set-WinUserLanguageList -LanguageList $UserLanguageList -Force
    Write-Log "Set user language list with $Culture as primary"

    # Set regional format (date, time, number formats)
    Set-Culture -CultureInfo $Culture
    Write-Log "Set culture/regional format to $Culture"

    # Set system locale (language for non-Unicode programs)
    Set-WinSystemLocale -SystemLocale $Culture
    Write-Log "Set system locale to $Culture"

    # Set geographic location
    Set-WinHomeLocation -GeoId $GeoId
    Write-Log "Set home location to GeoId $GeoId"

    # Copy settings to welcome screen and new user accounts
    Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true
    Write-Log "Copied settings to welcome screen and new user accounts"

    # Create marker file for detection
    @{
        GeoId    = $GeoId
        Culture  = $Culture
        TimeZone = $TimeZone
        InstalledAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    } | ConvertTo-Json | Set-Content -Path $MarkerFile -Force
    Write-Log "Created marker file: $MarkerFile"

    Write-Log "=========================================="
    Write-Log "Regional settings installation completed"
    Write-Log "=========================================="
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Log $_.ScriptStackTrace
    exit 1
}
