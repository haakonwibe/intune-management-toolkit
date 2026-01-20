<#
.SYNOPSIS
    Sets Windows Region and Regional format during Autopilot enrollment.

.DESCRIPTION
    Configures regional settings (GeoID, culture/locale) for the current user and sets
    defaults for new users. Designed to run during ESP Account Setup phase (step 3) or
    at first logon via scheduled task for settings that require it.

.PARAMETER GeoId
    The geographic location ID. Examples: 177 (Norway), 244 (United States), 94 (Germany).
    See: https://learn.microsoft.com/en-us/windows/win32/intl/table-of-geographical-locations

.PARAMETER Culture
    The culture/locale code. Examples: nb-NO (Norwegian Bokmål), en-US, de-DE.

.PARAMETER CopyToSystem
    If specified, copies regional settings to system accounts (Welcome screen, system accounts).
    Requires running as SYSTEM.

.PARAMETER CopyToDefaultUser
    If specified, copies regional settings to the default user profile for new users.
    Requires running as SYSTEM.

.PARAMETER CreateLogonTask
    Creates a scheduled task that applies user settings at first logon. This ensures
    settings that require a fresh logon session are applied correctly.

.EXAMPLE
    .\Install-RegionalSettings.ps1 -GeoId 177 -Culture "nb-NO"
    Sets regional settings to Norway/Norwegian Bokmål.

.EXAMPLE
    .\Install-RegionalSettings.ps1 -GeoId 177 -Culture "nb-NO" -CopyToSystem -CopyToDefaultUser
    Full deployment: Sets user, system, and default user profile settings (run as SYSTEM).

.NOTES
    Author  : Haakon Wibe
    License : MIT
    Context : Deploy via Intune Win32 app (SYSTEM context with -CopyToSystem -CopyToDefaultUser)
              or Platform Script (User context for user-only settings).

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
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [int]$GeoId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-zA-Z]{2,3}(-[a-zA-Z]{2,4})?$')]
    [string]$Culture,

    [switch]$CopyToSystem,
    [switch]$CopyToDefaultUser,
    [switch]$CreateLogonTask
)

$ErrorActionPreference = "Stop"

# Configuration
$ToolsFolder = "C:\ProgramData\IntuneTools"
$LogPath = Join-Path $ToolsFolder "RegionalSettings.log"
$TaskName = "Set-RegionalSettings-FirstLogon"

# Ensure tools folder exists
if (-not (Test-Path $ToolsFolder)) {
    New-Item -Path $ToolsFolder -ItemType Directory -Force | Out-Null
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] $Message"
    Add-Content -Path $LogPath -Value $entry -Force
    Write-Host $entry
}

function Test-RunningAsSystem {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return $currentIdentity.User.Value -eq "S-1-5-18"
}

function Get-CurrentUsername {
    # Get the currently logged-in interactive user
    try {
        $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | Select-Object -First 1
        if ($explorer) {
            $ownerInfo = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner -ErrorAction Stop
            if ($ownerInfo.ReturnValue -eq 0) {
                return @{
                    Domain   = $ownerInfo.Domain
                    Username = $ownerInfo.User
                    FullName = "$($ownerInfo.Domain)\$($ownerInfo.User)"
                }
            }
        }
    }
    catch {
        Write-Log "Could not detect user from explorer.exe: $($_.Exception.Message)"
    }

    # Fallback
    $loggedInUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
    if ($loggedInUser) {
        $parts = $loggedInUser.Split('\')
        return @{
            Domain   = $parts[0]
            Username = $parts[-1]
            FullName = $loggedInUser
        }
    }

    return $null
}

function Set-UserRegionalSettings {
    param(
        [string]$SID,
        [int]$GeoId,
        [string]$Culture
    )

    $regBase = "Registry::HKU\$SID\Control Panel\International"
    $geoRegPath = "Registry::HKU\$SID\Control Panel\International\Geo"

    Write-Log "Setting regional settings for SID: $SID"

    # Validate culture exists
    try {
        $cultureInfo = [System.Globalization.CultureInfo]::GetCultureInfo($Culture)
        Write-Log "Culture validated: $($cultureInfo.DisplayName) ($Culture)"
    }
    catch {
        throw "Invalid culture code: $Culture"
    }

    # Get regional info for the culture
    $regionInfo = [System.Globalization.RegionInfo]::new($Culture)

    # Set GeoID
    if (-not (Test-Path $geoRegPath)) {
        New-Item -Path $geoRegPath -Force | Out-Null
    }
    Set-ItemProperty -Path $geoRegPath -Name "Nation" -Value $GeoId.ToString() -Type String
    Set-ItemProperty -Path $geoRegPath -Name "Name" -Value $regionInfo.TwoLetterISORegionName -Type String
    Write-Log "Set GeoID to $GeoId ($($regionInfo.TwoLetterISORegionName))"

    # Set locale/culture settings
    Set-ItemProperty -Path $regBase -Name "LocaleName" -Value $Culture -Type String
    Set-ItemProperty -Path $regBase -Name "sLanguage" -Value $cultureInfo.ThreeLetterWindowsLanguageName -Type String
    Set-ItemProperty -Path $regBase -Name "sCountry" -Value $regionInfo.EnglishName -Type String

    # Date formats
    $dateTimeFormat = $cultureInfo.DateTimeFormat
    Set-ItemProperty -Path $regBase -Name "sShortDate" -Value $dateTimeFormat.ShortDatePattern -Type String
    Set-ItemProperty -Path $regBase -Name "sLongDate" -Value $dateTimeFormat.LongDatePattern -Type String
    Set-ItemProperty -Path $regBase -Name "sShortTime" -Value $dateTimeFormat.ShortTimePattern -Type String
    Set-ItemProperty -Path $regBase -Name "sTimeFormat" -Value $dateTimeFormat.LongTimePattern -Type String
    Set-ItemProperty -Path $regBase -Name "iFirstDayOfWeek" -Value ([int]$dateTimeFormat.FirstDayOfWeek).ToString() -Type String
    Set-ItemProperty -Path $regBase -Name "sDate" -Value $dateTimeFormat.DateSeparator -Type String
    Set-ItemProperty -Path $regBase -Name "sTime" -Value $dateTimeFormat.TimeSeparator -Type String
    Set-ItemProperty -Path $regBase -Name "iTime" -Value $(if ($dateTimeFormat.ShortTimePattern -like "*H*") { "1" } else { "0" }) -Type String
    Write-Log "Set date/time formats for $Culture"

    # Number formats
    $numberFormat = $cultureInfo.NumberFormat
    Set-ItemProperty -Path $regBase -Name "sDecimal" -Value $numberFormat.NumberDecimalSeparator -Type String
    Set-ItemProperty -Path $regBase -Name "sThousand" -Value $numberFormat.NumberGroupSeparator -Type String
    Set-ItemProperty -Path $regBase -Name "sCurrency" -Value $numberFormat.CurrencySymbol -Type String
    Set-ItemProperty -Path $regBase -Name "sMonDecimalSep" -Value $numberFormat.CurrencyDecimalSeparator -Type String
    Set-ItemProperty -Path $regBase -Name "sMonThousandSep" -Value $numberFormat.CurrencyGroupSeparator -Type String
    Set-ItemProperty -Path $regBase -Name "iNegCurr" -Value $numberFormat.CurrencyNegativePattern.ToString() -Type String
    Set-ItemProperty -Path $regBase -Name "iCurrency" -Value $numberFormat.CurrencyPositivePattern.ToString() -Type String
    Write-Log "Set number/currency formats for $Culture"
}

function Set-DefaultUserRegionalSettings {
    param(
        [int]$GeoId,
        [string]$Culture
    )

    Write-Log "Loading DEFAULT user registry hive..."

    $defaultHivePath = "C:\Users\Default\NTUSER.DAT"
    $tempKey = "HKU\DEFAULT_USER_TEMP"

    # Load the default user hive
    $result = reg load $tempKey $defaultHivePath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to load default user hive: $result"
    }

    try {
        Set-UserRegionalSettings -SID "DEFAULT_USER_TEMP" -GeoId $GeoId -Culture $Culture
        Write-Log "Default user regional settings configured"
    }
    finally {
        # Unload the hive
        [gc]::Collect()
        Start-Sleep -Milliseconds 500
        reg unload $tempKey 2>&1 | Out-Null
    }
}

function Set-SystemRegionalSettings {
    param(
        [int]$GeoId,
        [string]$Culture
    )

    Write-Log "Configuring system regional settings..."

    # Set system locale (welcome screen, system accounts)
    # This uses the international settings Copy function via registry
    $xmlContent = @"
<gs:GlobalizationServices xmlns:gs="urn:longhornGlobalizationUnattend">
    <gs:UserList>
        <gs:User UserID="Current" CopySettingsToDefaultUserAcct="true" CopySettingsToSystemAcct="true"/>
    </gs:UserList>
    <gs:LocationPreferences>
        <gs:GeoID Value="$GeoId"/>
    </gs:LocationPreferences>
    <gs:UserLocale>
        <gs:Locale Name="$Culture" SetAsCurrent="true"/>
    </gs:UserLocale>
</gs:GlobalizationServices>
"@

    $xmlPath = Join-Path $ToolsFolder "RegionalSettings.xml"
    Set-Content -Path $xmlPath -Value $xmlContent -Encoding UTF8 -Force

    # Apply settings using control panel international settings
    $result = & control.exe intl.cpl,, /f:"$xmlPath" 2>&1
    Write-Log "Applied system regional settings via intl.cpl"

    # Clean up
    Remove-Item -Path $xmlPath -Force -ErrorAction SilentlyContinue
}

function New-FirstLogonTask {
    param(
        [int]$GeoId,
        [string]$Culture
    )

    Write-Log "Creating first-logon scheduled task..."

    # Create a simple script that applies settings and removes itself
    $logonScriptPath = Join-Path $ToolsFolder "Set-RegionalSettingsLogon.ps1"
    $logonScript = @"
# First-logon regional settings script - runs once and removes itself
`$LogPath = "C:\ProgramData\IntuneTools\RegionalSettings.log"
`$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Add-Content -Path `$LogPath -Value "[`$timestamp] First-logon task executing for user `$env:USERNAME" -Force

try {
    # Set culture for current user session
    Set-Culture -CultureInfo "$Culture"
    Set-WinHomeLocation -GeoId $GeoId
    Set-WinUserLanguageList -LanguageList "$Culture" -Force

    Add-Content -Path `$LogPath -Value "[`$timestamp] Regional settings applied: Culture=$Culture, GeoId=$GeoId" -Force
}
catch {
    Add-Content -Path `$LogPath -Value "[`$timestamp] ERROR: `$(`$_.Exception.Message)" -Force
}

# Remove the scheduled task and this script
Unregister-ScheduledTask -TaskName "$TaskName" -Confirm:`$false -ErrorAction SilentlyContinue
Remove-Item -Path "`$PSCommandPath" -Force -ErrorAction SilentlyContinue
"@

    Set-Content -Path $logonScriptPath -Value $logonScript -Force

    # Remove existing task if present
    Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false

    # Create task that runs at user logon
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$logonScriptPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -GroupId "S-1-5-32-545" -RunLevel Limited  # Users group
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "Applies regional settings at first user logon" | Out-Null

    Write-Log "Created first-logon scheduled task: $TaskName"
}

# Main execution
Write-Log "=========================================="
Write-Log "Regional Settings Installation Started"
Write-Log "GeoId: $GeoId, Culture: $Culture"
Write-Log "Running as SYSTEM: $(Test-RunningAsSystem)"
Write-Log "=========================================="

try {
    $isSystem = Test-RunningAsSystem

    if ($isSystem) {
        # Running as SYSTEM - can configure default user and system settings
        $currentUser = Get-CurrentUsername

        if ($currentUser) {
            Write-Log "Detected logged-in user: $($currentUser.FullName)"

            # Get user SID
            $userAccount = New-Object System.Security.Principal.NTAccount($currentUser.FullName)
            $userSID = $userAccount.Translate([System.Security.Principal.SecurityIdentifier]).Value

            # Apply settings to current user's registry
            Set-UserRegionalSettings -SID $userSID -GeoId $GeoId -Culture $Culture
        }
        else {
            Write-Log "No interactive user detected - skipping current user settings"
        }

        if ($CopyToDefaultUser) {
            Set-DefaultUserRegionalSettings -GeoId $GeoId -Culture $Culture
        }

        if ($CopyToSystem) {
            Set-SystemRegionalSettings -GeoId $GeoId -Culture $Culture
        }

        if ($CreateLogonTask) {
            New-FirstLogonTask -GeoId $GeoId -Culture $Culture
        }
    }
    else {
        # Running as user - apply settings directly
        Write-Log "Running in user context, applying settings directly..."

        Set-Culture -CultureInfo $Culture
        Set-WinHomeLocation -GeoId $GeoId
        Set-WinUserLanguageList -LanguageList $Culture -Force

        Write-Log "Applied regional settings via PowerShell cmdlets"

        if ($CopyToSystem -or $CopyToDefaultUser) {
            Write-Log "WARNING: -CopyToSystem and -CopyToDefaultUser require SYSTEM context"
        }
    }

    Write-Log "Regional settings installation completed successfully"
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Log $_.ScriptStackTrace
    exit 1
}
