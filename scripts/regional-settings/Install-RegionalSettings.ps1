<#
.SYNOPSIS
    Sets Windows Region, Regional format, and Timezone during Autopilot enrollment.

.DESCRIPTION
    Configures regional settings (GeoID, culture/locale, timezone) using Windows 11 cmdlets.
    Designed to run as SYSTEM during ESP to set defaults before user sees the desktop.

    By default only regional formats are changed (dates, numbers, timezone, geo location)
    while keeping the existing OS display language. Use -InstallLanguagePack to also download
    and install the full language pack and switch the UI language.

.PARAMETER GeoId
    The geographic location ID. Examples: 177 (Norway), 244 (United States), 94 (Germany).
    See: https://learn.microsoft.com/en-us/windows/win32/intl/table-of-geographical-locations

.PARAMETER Culture
    The culture/locale code. Examples: nb-NO (Norwegian Bokmål), en-US, de-DE.

.PARAMETER TimeZone
    The Windows timezone ID. Examples: "W. Europe Standard Time" (Norway), "Pacific Standard Time" (US West).
    Run Get-TimeZone -ListAvailable to see all options.

.PARAMETER InstallLanguagePack
    When specified, downloads and installs the full language pack for the Culture via
    Install-Language, sets the UI language override, and makes the culture the primary
    language in the preferred list. Requires a reboot (exits with code 3010).

.EXAMPLE
    .\Install-RegionalSettings.ps1 -GeoId 177 -Culture "nb-NO" -TimeZone "W. Europe Standard Time"
    Sets regional formats to Norwegian on an English OS without changing the display language.

.EXAMPLE
    .\Install-RegionalSettings.ps1 -GeoId 177 -Culture "nb-NO" -TimeZone "W. Europe Standard Time" -InstallLanguagePack
    Installs the nb-NO language pack, switches the UI language, and sets all regional formats. Exits 3010 to trigger reboot.

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
    [string]$TimeZone,

    [Parameter()]
    [switch]$InstallLanguagePack
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

function Write-ESPDiagnostics {
    # Log all available signals for ESP/OOBE detection diagnostics.
    # Run during testing to determine which signals reliably indicate ESP.
    Write-Log "--- ESP Diagnostics Start ---"

    # 1. OOBE registry
    $OOBEInProgress = [Microsoft.Win32.Registry]::GetValue(
        "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE", "OOBEInProgress", $null)
    Write-Log "  OOBE\OOBEInProgress: $OOBEInProgress"

    # 2. Autopilot settings
    $AutopilotRegPath = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Provisioning\AutopilotSettings"
    $DeviceConfigComplete = [Microsoft.Win32.Registry]::GetValue($AutopilotRegPath, "DeviceConfigurationComplete", $null)
    Write-Log "  AutopilotSettings\DeviceConfigurationComplete: $DeviceConfigComplete"

    # 3. Processes
    $CloudExpHost = [bool](Get-Process -Name "CloudExperienceHost" -ErrorAction SilentlyContinue)
    $CloudExpBroker = [bool](Get-Process -Name "CloudExperienceHostBroker" -ErrorAction SilentlyContinue)
    $WWAHost = [bool](Get-Process -Name "WWAHost" -ErrorAction SilentlyContinue)
    $ExplorerRunning = [bool](Get-Process -Name "explorer" -ErrorAction SilentlyContinue)
    Write-Log "  Process CloudExperienceHost: $CloudExpHost"
    Write-Log "  Process CloudExperienceHostBroker: $CloudExpBroker"
    Write-Log "  Process WWAHost: $WWAHost"
    Write-Log "  Process explorer: $ExplorerRunning"

    # 4. Logged-on user
    $LoggedOnUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    Write-Log "  Logged-on user: $LoggedOnUser"

    # 5. FirstSync / IsSyncDone (device and user level)
    $basePath = "HKLM:\SOFTWARE\Microsoft\Enrollments"
    $enrollments = Get-ChildItem -Path $basePath -ErrorAction SilentlyContinue
    foreach ($enrollment in $enrollments) {
        $providerID = (Get-ItemProperty -Path $enrollment.PSPath -Name "ProviderID" -ErrorAction SilentlyContinue).ProviderID
        if ($providerID -eq "MS DM Server") {
            Write-Log "  Enrollment GUID: $($enrollment.PSChildName)"
            $firstSyncPath = Join-Path -Path $enrollment.PSPath -ChildPath "FirstSync"
            if (Test-Path -Path $firstSyncPath) {
                $isSyncDone = (Get-ItemProperty -Path $firstSyncPath -Name "IsSyncDone" -ErrorAction SilentlyContinue).IsSyncDone
                Write-Log "  FirstSync\IsSyncDone (device): $isSyncDone"
                $sids = Get-ChildItem -Path $firstSyncPath -ErrorAction SilentlyContinue
                foreach ($sid in $sids) {
                    $userSyncDone = (Get-ItemProperty -Path $sid.PSPath -Name "IsSyncDone" -ErrorAction SilentlyContinue).IsSyncDone
                    Write-Log "  FirstSync\$($sid.PSChildName)\IsSyncDone (user): $userSyncDone"
                }
            }
            else {
                Write-Log "  FirstSync key: Not found"
            }
        }
    }

    # 6. Sidecar PolicyProvider InstallationState (WMI)
    try {
        $providers = Get-CimInstance -Namespace "root\cimv2\mdm\dmmap" -ClassName "MDM_EnrollmentStatusTracking_PolicyProviders02_01" -ErrorAction Stop
        foreach ($p in $providers) {
            Write-Log "  PolicyProvider $($p.InstanceID) InstallationState: $($p.InstallationState)"
        }
    }
    catch {
        Write-Log "  PolicyProvider WMI query: Failed ($($_.Exception.Message))"
    }

    # 7. HasProvisioningCompleted (WMI)
    try {
        $setup = Get-CimInstance -Namespace "root\cimv2\mdm\dmmap" -ClassName "MDM_EnrollmentStatusTracking_Setup01" -ErrorAction Stop
        foreach ($s in $setup) {
            Write-Log "  HasProvisioningCompleted: $($s.HasProvisioningCompleted)"
        }
    }
    catch {
        Write-Log "  HasProvisioningCompleted WMI query: Failed ($($_.Exception.Message))"
    }

    # 8. Device app tracking state (WMI)
    try {
        $trackedApps = Get-CimInstance -Namespace "root\cimv2\mdm\dmmap" -ClassName "MDM_EnrollmentStatusTracking_Tracking03_02" -ErrorAction SilentlyContinue
        if ($trackedApps) {
            foreach ($app in $trackedApps) {
                Write-Log "  TrackedApp $($app.InstanceID) InstallationState: $($app.InstallationState)"
            }
        }
        else {
            Write-Log "  TrackedApps: None found"
        }
    }
    catch {
        Write-Log "  TrackedApps WMI query: Failed ($($_.Exception.Message))"
    }

    Write-Log "--- ESP Diagnostics End ---"
}

function Test-IsESP {
    # Placeholder — will be updated once we identify reliable signals from diagnostics
    return $false
}

# Main execution
Write-Log "=========================================="
Write-Log "Regional Settings Installation Started"
Write-Log "GeoId: $GeoId, Culture: $Culture, TimeZone: $TimeZone, InstallLanguagePack: $InstallLanguagePack"
Write-ESPDiagnostics
Write-Log "=========================================="

try {
    # Snapshot current settings for rollback
    $UIOverride = Get-WinUILanguageOverride -ErrorAction SilentlyContinue
    $PreviousSettings = @{
        GeoId            = (Get-WinHomeLocation).GeoId
        Culture          = (Get-Culture).Name
        TimeZone         = (Get-TimeZone).Id
        SystemLocale     = (Get-WinSystemLocale).Name
        LanguageList     = @((Get-WinUserLanguageList).LanguageTag)
        UILanguageOverride = if ($UIOverride) { $UIOverride.LanguageTag } else { $null }
    }
    Write-Log "Saved previous settings for rollback: GeoId=$($PreviousSettings.GeoId), Culture=$($PreviousSettings.Culture), TimeZone=$($PreviousSettings.TimeZone)"

    # Set timezone
    Set-TimeZone -Id $TimeZone
    Write-Log "Set timezone to $TimeZone"

    if ($InstallLanguagePack) {
        # Install full language pack from Microsoft CDN
        Write-Log "Installing language pack for $Culture (this may take 10-20 minutes)..."
        Install-Language -Language $Culture -CopyToSettings
        Write-Log "Language pack for $Culture installed successfully"

        # Set UI language override to the new language
        Set-WinUILanguageOverride -Language $Culture
        Write-Log "Set UI language override to $Culture"

        # Set preferred language list with new language as primary
        $OldList = Get-WinUserLanguageList
        $UserLanguageList = New-WinUserLanguageList -Language $Culture
        $UserLanguageList += $OldList | Where-Object { $_.LanguageTag -ne $Culture }
        Set-WinUserLanguageList -LanguageList $UserLanguageList -Force
        Write-Log "Set user language list with $Culture as primary"
    }
    else {
        # Regional formats only — append culture to language list without changing display language
        $UserLanguageList = Get-WinUserLanguageList
        if (-not ($UserLanguageList | Where-Object { $_.LanguageTag -eq $Culture })) {
            $UserLanguageList += New-WinUserLanguageList -Language $Culture
            Set-WinUserLanguageList -LanguageList $UserLanguageList -Force
            Write-Log "Added $Culture to end of user language list (existing display language unchanged)"
        }
        else {
            Write-Log "User language list already contains $Culture, no change needed"
        }
    }

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

    # Create marker file for detection (includes previous settings for rollback)
    @{
        GeoId                = $GeoId
        Culture              = $Culture
        TimeZone             = $TimeZone
        LanguagePackInstalled = [bool]$InstallLanguagePack
        InstalledAt          = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        PreviousSettings     = $PreviousSettings
    } | ConvertTo-Json -Depth 3 | Set-Content -Path $MarkerFile -Force
    Write-Log "Created marker file: $MarkerFile"

    Write-Log "=========================================="
    Write-Log "Regional settings installation completed"
    Write-Log "=========================================="

    if ($InstallLanguagePack) {
        Write-Log "Exiting with code 3010 (reboot required for language pack)"
        exit 3010
    }
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Log $_.ScriptStackTrace
    exit 1
}
