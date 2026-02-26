<#
.SYNOPSIS
    Creates an Intune Win32 (.intunewin) package from an MSI or EXE installer with metadata & detection scaffolding.

.DESCRIPTION
    Automates:
      * Locates Microsoft Win32 Content Prep Tool (script folder, env var, legacy path) or downloads latest release.
      * Extracts MSI metadata (Name, Version, ProductCode, Manufacturer) for naming & detection.
      * EXE heuristic detection (InstallShield / Inno Setup / NSIS / Wise / Squirrel / MSI wrapper) to propose silent switches.
      * Generates install / uninstall command defaults (override via parameters).
      * Builds .intunewin using IntuneWinAppUtil.exe.
      * Produces side-car Metadata.json (+ optional DetectionScript.ps1) to aid portal import.

    Supports PowerShell 7+ and Windows PowerShell 5.1 (no PS7-only syntax used).

.PARAMETER InstallerPath
    Path to the installer file (.msi or .exe), or a directory when used with -Browse.
    Not required when using -Init.

.PARAMETER Browse
    When specified, treats InstallerPath as a directory and presents an interactive menu
    of discovered installers (.msi, .exe) to choose from.

.PARAMETER Init
    Creates the expected environment (output folder, downloads IntuneWinAppUtil.exe if missing)
    and shows a status report. Use this when setting up a new packaging workstation.

.NOTES
    File Name      : New-IntuneAppPackageFromInstaller.ps1
    Author         : Haakon Wibe
    License        : MIT
    Version        : 1.1.0

.EXAMPLE
    ./New-IntuneAppPackageFromInstaller.ps1 -Init
    # Set up the environment and download IntuneWinAppUtil.exe if needed

.EXAMPLE
    ./New-IntuneAppPackageFromInstaller.ps1 -InstallerPath C:\Installers\7zip.msi

.EXAMPLE
    ./New-IntuneAppPackageFromInstaller.ps1 -InstallerPath C:\Installers\notepadpp.exe -InstallCommand 'notepadpp.exe /S'

.EXAMPLE
    ./New-IntuneAppPackageFromInstaller.ps1 -Browse -InstallerPath C:\Installers
    # Interactive menu to pick from all installers in the folder
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Position=0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [string]$InstallerPath,

    [Parameter()] [string]$OutputPath,
    [Parameter()] [string]$AppName,
    [Parameter()] [string]$Publisher,
    [Parameter()] [string]$InstallCommand,
    [Parameter()] [string]$UninstallCommand,
    [Parameter()] [ValidateSet('Auto','MSI','File','Registry','Script')] [string]$DetectionMethod = 'Auto',
    [Parameter()] [string]$FileDetectionPath,
    [Parameter()] [string]$FileDetectionVersion,
    [Parameter()] [string]$RegistryDetectionKey,
    [Parameter()] [string]$RegistryDetectionValueName,
    [Parameter()] [string]$RegistryDetectionValueData,
    [Parameter()] [string]$CustomDetectionScriptPath,
    [switch]$Browse,
    [switch]$Init,
    [switch]$Quiet
)

#region Helper Imports / Environment
$script:ScriptName = Split-Path -Leaf $PSCommandPath
$ErrorActionPreference = 'Stop'

# Installer file extensions (in priority order)
$script:InstallerExtensions = @('.msi', '.exe')

# Import IntuneToolkit for logging (fallback to Write-Host if missing)
$modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../modules/IntuneToolkit/IntuneToolkit.psm1'
if (Test-Path $modulePath) {
    try { Import-Module $modulePath -Force -ErrorAction Stop } catch { Write-Host "[WARN] Failed to import IntuneToolkit module: $_" -ForegroundColor Yellow }
}
if (-not (Get-Command Write-IntuneLog -ErrorAction SilentlyContinue)) {
    function Write-IntuneLog { param([string]$Message,[ValidateSet('Info','Warning','Error','Success','Debug')]$Level='Info') $ts=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); Write-Host "[$ts] $Message" }
}
#endregion

#region Tool Path Resolution
function Find-IntuneWinAppUtil {
    <#
    .SYNOPSIS
        Searches for IntuneWinAppUtil.exe in well-known locations.
        Returns the path if found, $null otherwise.
    #>
    [CmdletBinding()] param()

    # 1. Same folder as this script
    $candidate = Join-Path $PSScriptRoot 'IntuneWinAppUtil.exe'
    if (Test-Path $candidate) { return $candidate }

    # 2. Environment variable override
    if ($env:INTUNEWIN_TOOL_PATH -and (Test-Path $env:INTUNEWIN_TOOL_PATH)) {
        $p = $env:INTUNEWIN_TOOL_PATH
        if ((Get-Item $p).PSIsContainer) { $p = Join-Path $p 'IntuneWinAppUtil.exe' }
        if (Test-Path $p) { return $p }
    }

    # 3. Legacy hardcoded path
    $legacy = 'C:\Tools\IntuneWinAppUtil\IntuneWinAppUtil.exe'
    if (Test-Path $legacy) { return $legacy }

    # 4. Persistent local app data cache
    $localCache = Join-Path $env:LOCALAPPDATA 'IntuneWinAppUtil\IntuneWinAppUtil.exe'
    if (Test-Path $localCache) { return $localCache }

    return $null
}

function Get-LatestWin32ContentPrepTool {
    <#
    .SYNOPSIS
        Finds IntuneWinAppUtil.exe locally, or downloads the latest release from GitHub.
    #>
    [CmdletBinding()] param()

    $existing = Find-IntuneWinAppUtil
    if ($existing) {
        Write-IntuneLog -Message "Found IntuneWinAppUtil.exe: $existing" -Level Debug
        return $existing
    }

    # Download to persistent local cache
    $toolRoot = Join-Path $env:LOCALAPPDATA 'IntuneWinAppUtil'
    if (-not (Test-Path $toolRoot)) { New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null }
    $exePath = Join-Path $toolRoot 'IntuneWinAppUtil.exe'

    Write-IntuneLog -Message 'IntuneWinAppUtil.exe not found locally. Downloading latest release...' -Level Info
    $releaseApi = 'https://api.github.com/repos/microsoft/Microsoft-Win32-Content-Prep-Tool/releases/latest'
    try {
        $headers = @{ 'User-Agent' = 'intune-management-toolkit'; 'Accept'='application/vnd.github+json' }
        $release = Invoke-RestMethod -Uri $releaseApi -Headers $headers -UseBasicParsing

        # Prefer an attached asset zip. If none (assets empty) fallback to zipball_url
        $asset = $null
        if ($release.assets -and $release.assets.Count -gt 0) {
            $asset = $release.assets | Where-Object { $_.name -match '\.zip$' } | Select-Object -First 1
        }

        $tempZip = Join-Path $toolRoot 'Win32ContentPrepTool.zip'
        if ($asset) {
            Write-IntuneLog -Message "Downloading asset: $($asset.name)" -Level Info
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tempZip -UseBasicParsing -Headers $headers
        } else {
            if (-not $release.zipball_url) { throw 'No asset zip and no zipball_url found in release JSON.' }
            Write-IntuneLog -Message 'No release assets found. Falling back to zipball_url archive.' -Level Warning
            Invoke-WebRequest -Uri $release.zipball_url -OutFile $tempZip -UseBasicParsing -Headers $headers
        }

        Write-IntuneLog -Message 'Expanding archive...' -Level Info
        $expandPath = Join-Path $toolRoot 'extract_tmp'
        if (Test-Path $expandPath) { Remove-Item $expandPath -Recurse -Force }
        Expand-Archive -Path $tempZip -DestinationPath $expandPath -Force
        Remove-Item $tempZip -Force -ErrorAction SilentlyContinue

        # Search recursively for IntuneWinAppUtil.exe (GitHub zipball has a root folder with commit hash)
        $found = Get-ChildItem -Path $expandPath -Filter 'IntuneWinAppUtil.exe' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $found) { throw 'IntuneWinAppUtil.exe not located inside extracted archive.' }
        Copy-Item -Path $found.FullName -Destination $exePath -Force
        Remove-Item $expandPath -Recurse -Force -ErrorAction SilentlyContinue

        if (-not (Test-Path $exePath)) { throw 'Extraction completed but executable still missing.' }
        Write-IntuneLog -Message "Downloaded Win32 Content Prep Tool version tag: $($release.tag_name)" -Level Success
        return $exePath
    } catch {
        throw "Failed to acquire Microsoft Win32 Content Prep Tool: $_"
    }
}
#endregion

#region Functions
function Get-MSIMetadata {
    [CmdletBinding()] param([string]$Path)
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $db = $installer.GetType().InvokeMember('OpenDatabase','InvokeMethod',$null,$installer,@($Path,0))
    function Get-MSIProperty([string]$Name){
        $q = "SELECT Value FROM Property WHERE Property='$Name'"
        $view = $db.GetType().InvokeMember('OpenView','InvokeMethod',$null,$db,($q))
        $view.GetType().InvokeMember('Execute','InvokeMethod',$null,$view,$null)|Out-Null
        $record = $view.GetType().InvokeMember('Fetch','InvokeMethod',$null,$view,$null)
        if ($record) { return $record.GetType().InvokeMember('StringData','GetProperty',$null,$record,1) } else { return $null }
    }
    return [ordered]@{
        Type           = 'MSI'
        ProductName    = (Get-MSIProperty 'ProductName')
        ProductVersion = (Get-MSIProperty 'ProductVersion')
        ProductCode    = (Get-MSIProperty 'ProductCode')
        Manufacturer   = (Get-MSIProperty 'Manufacturer')
    }
}

function Get-EXEHeuristics {
    [CmdletBinding()] param([string]$Path)
    $fi = Get-Item $Path
    $vi = $fi.VersionInfo

    $contentSample = try { [System.IO.File]::ReadAllText($Path) } catch { '' }
    $heuristics = @()
    if ($contentSample -match 'Inno Setup') { $heuristics += 'InnoSetup' }
    if ($contentSample -match 'Nullsoft') { $heuristics += 'NSIS' }
    if ($contentSample -match 'InstallShield') { $heuristics += 'InstallShield' }
    if ($contentSample -match 'Wise Installation') { $heuristics += 'Wise' }
    if ($contentSample -match 'Squirrel') { $heuristics += 'Squirrel' }
    if ($contentSample -match 'MSI') { $heuristics += 'MSIWrapper' }
    $heuristics = $heuristics | Select-Object -Unique

    $silentSuggestions = @()
    switch -Regex ($heuristics) {
        'InnoSetup'     { $silentSuggestions += '/VERYSILENT','/SILENT','/SP-' }
        'NSIS'          { $silentSuggestions += '/S' }
        'InstallShield' { $silentSuggestions += '/s','/s /v"/qn"' }
        'Wise'          { $silentSuggestions += '/s' }
        'Squirrel'      { $silentSuggestions += '--silent' }
        'MSIWrapper'    { $silentSuggestions += '/qn' }
    }
    if (-not $silentSuggestions) { $silentSuggestions = '/S','/Silent','/Quiet','/Q','/QN','/VERYSILENT' }

    return [ordered]@{
        Type               = 'EXE'
        FileName           = $fi.Name
        ProductName        = $vi.ProductName
        ProductVersion     = $vi.ProductVersion
        FileVersion        = $vi.FileVersion
        CompanyName        = $vi.CompanyName
        Heuristics         = $heuristics
        SilentSwitchHints  = ($silentSuggestions | Select-Object -Unique)
    }
}

function New-DetectionMetadata {
    [CmdletBinding()] param(
        [hashtable]$InstallerMetadata,
        [string]$ChosenMethod,
        [string]$FilePath,
        [string]$FileVersion,
        [string]$RegKey,
        [string]$RegValueName,
        [string]$RegValueData,
        [string]$MSIProductCode,
        [string]$CustomScript
    )

    $rules = @()
    switch ($ChosenMethod) {
        'MSI'      { $rules += @{ Type='MSI'; ProductCode=$MSIProductCode } }
        'File'     { $rules += @{ Type='File'; Path=$FilePath; Version=$FileVersion } }
        'Registry' { $rules += @{ Type='Registry'; Key=$RegKey; ValueName=$RegValueName; ValueData=$RegValueData } }
        'Script'   { $rules += @{ Type='Script'; ScriptFile='DetectionScript.ps1' } }
    }
    return @{ Method=$ChosenMethod; Rules=$rules; Source=$InstallerMetadata }
}
#endregion

#region Init Mode
if ($Init) {
    Write-Host ""
    Write-Host "=== Intune App Builder - Environment Setup ===" -ForegroundColor Cyan
    Write-Host ""

    # Check IntuneWinAppUtil.exe
    $toolFound = Find-IntuneWinAppUtil
    if ($toolFound) {
        Write-Host "  [OK]      IntuneWinAppUtil.exe" -ForegroundColor Green
        Write-Host "            $toolFound" -ForegroundColor DarkGray
    } else {
        Write-Host "  [Missing] IntuneWinAppUtil.exe" -ForegroundColor Yellow
        Write-Host "            Attempting download..." -ForegroundColor DarkGray
        try {
            $downloaded = Get-LatestWin32ContentPrepTool
            Write-Host "  [OK]      Downloaded to: $downloaded" -ForegroundColor Green
        } catch {
            Write-Host "  [Failed]  $_" -ForegroundColor Red
            Write-Host "            Download manually: https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool" -ForegroundColor DarkGray
        }
    }

    # Check IntuneToolkit module
    Write-Host ""
    if (Get-Command Write-IntuneLog -ErrorAction SilentlyContinue) {
        Write-Host "  [OK]      IntuneToolkit module loaded" -ForegroundColor Green
    } else {
        Write-Host "  [Info]    IntuneToolkit module not found (using built-in logging)" -ForegroundColor DarkGray
    }

    # Show search order
    Write-Host ""
    Write-Host "  Tool search order:" -ForegroundColor DarkGray
    Write-Host "    1. $PSScriptRoot\IntuneWinAppUtil.exe" -ForegroundColor DarkGray
    Write-Host "    2. %INTUNEWIN_TOOL_PATH% (environment variable)" -ForegroundColor DarkGray
    Write-Host "    3. C:\Tools\IntuneWinAppUtil\IntuneWinAppUtil.exe" -ForegroundColor DarkGray
    Write-Host "    4. %LOCALAPPDATA%\IntuneWinAppUtil\IntuneWinAppUtil.exe (auto-download)" -ForegroundColor DarkGray

    Write-Host ""
    Write-Host "  Usage examples:" -ForegroundColor DarkGray
    Write-Host "    .\New-IntuneAppPackageFromInstaller.ps1 -InstallerPath C:\Installers\app.msi" -ForegroundColor DarkGray
    Write-Host "    .\New-IntuneAppPackageFromInstaller.ps1 -Browse -InstallerPath C:\Installers" -ForegroundColor DarkGray
    Write-Host ""
    return
}
#endregion

#region Browse Mode / Input Validation
if (-not $InstallerPath) {
    Write-Error "InstallerPath is required. Use -Init to set up the environment, or -Browse -InstallerPath <folder> for interactive mode."
    return
}

if ($Browse -or (Test-Path $InstallerPath -PathType Container)) {
    $searchPath = if (Test-Path $InstallerPath -PathType Container) { $InstallerPath } else { Split-Path $InstallerPath -Parent }
    if (-not (Test-Path $searchPath)) {
        Write-Error "Directory not found: $searchPath"
        return
    }

    $installers = Get-ChildItem -Path $searchPath -File |
                  Where-Object { $script:InstallerExtensions -contains $_.Extension.ToLowerInvariant() } |
                  Sort-Object {
                      $idx = $script:InstallerExtensions.IndexOf($_.Extension.ToLowerInvariant())
                      if ($idx -ge 0) { $idx } else { 999 }
                  }

    if ($installers.Count -eq 0) {
        Write-Host ""
        Write-Host "=== No Installers Found ===" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  No .msi or .exe files in: $searchPath" -ForegroundColor DarkGray
        Write-Host ""
        return
    }
    elseif ($installers.Count -eq 1) {
        $InstallerPath = $installers[0].FullName
        Write-Host "Auto-selected: $($installers[0].Name)" -ForegroundColor Green
    }
    else {
        Write-Host ""
        Write-Host "=== Select Installer ===" -ForegroundColor Cyan
        Write-Host "  Directory: $searchPath" -ForegroundColor DarkGray
        Write-Host ""
        for ($i = 0; $i -lt $installers.Count; $i++) {
            $inst = $installers[$i]
            $size = [math]::Round($inst.Length / 1MB, 2)
            Write-Host "  [$($i + 1)] $($inst.Name)" -ForegroundColor Yellow -NoNewline
            Write-Host "  ($size MB, $($inst.LastWriteTime.ToString('yyyy-MM-dd')))" -ForegroundColor DarkGray
        }

        Write-Host ""
        $selection = Read-Host "Select installer (1-$($installers.Count))"

        if ($selection -match '^\d+$' -and [int]$selection -ge 1 -and [int]$selection -le $installers.Count) {
            $InstallerPath = $installers[[int]$selection - 1].FullName
        }
        else {
            Write-Error "Invalid selection."
            return
        }
    }
}

if (-not (Test-Path $InstallerPath)) {
    Write-Error "Installer not found: $InstallerPath"
    return
}
#endregion

#region Start
Write-IntuneLog -Message "Starting $script:ScriptName" -Level Info
Write-IntuneLog -Message "PowerShell version: $($PSVersionTable.PSVersion)" -Level Debug

$resolvedInstaller = (Resolve-Path $InstallerPath).Path
$extension = ([IO.Path]::GetExtension($resolvedInstaller)).ToLowerInvariant()
if ($extension -notin '.msi','.exe') { throw 'Only MSI and EXE installers are supported.' }

if (-not $OutputPath) { $OutputPath = Join-Path -Path (Split-Path $resolvedInstaller -Parent) -ChildPath 'IntunePackages' }
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

$toolPath = Get-LatestWin32ContentPrepTool

$installerMeta = @{}
try {
    if ($extension -eq '.msi') {
        Write-IntuneLog -Message 'Extracting MSI metadata...' -Level Info
        $msiMeta = Get-MSIMetadata -Path $resolvedInstaller
        $installerMeta = $msiMeta
        if (-not $AppName) { $AppName = $msiMeta.ProductName }
        if (-not $Publisher) { $Publisher = $msiMeta.Manufacturer }
        if (-not $InstallCommand) { $InstallCommand = 'msiexec /i "{0}" /qn /norestart' -f (Split-Path -Leaf $resolvedInstaller) }
        if (-not $UninstallCommand -and $msiMeta.ProductCode) { $UninstallCommand = 'msiexec /x {0} /qn /norestart' -f $msiMeta.ProductCode }
        $DetectionMethod = 'MSI'
    } else {
        Write-IntuneLog -Message 'Collecting EXE metadata and heuristics...' -Level Info
        $exeMeta = Get-EXEHeuristics -Path $resolvedInstaller
        $installerMeta = $exeMeta
        if (-not $AppName) { $AppName = if ($exeMeta.ProductName) { $exeMeta.ProductName } else { [IO.Path]::GetFileNameWithoutExtension($resolvedInstaller) } }
        if (-not $Publisher) { $Publisher = $exeMeta.CompanyName }
        if (-not $InstallCommand) { $InstallCommand = '"{0}" {1}' -f (Split-Path -Leaf $resolvedInstaller), ($exeMeta.SilentSwitchHints[0]) }
        if (-not $UninstallCommand) { $UninstallCommand = '# TODO: Provide uninstall command (EXE installer)' }
    }
} catch { throw "Failed to extract installer metadata: $_" }

if (-not $AppName) { $AppName = [IO.Path]::GetFileNameWithoutExtension($resolvedInstaller) }
if (-not $Publisher) { $Publisher = 'Unknown' }

$chosenDetection = $DetectionMethod
if ($chosenDetection -eq 'Auto') {
    $chosenDetection = if ($extension -eq '.msi') { 'MSI' } elseif ($FileDetectionPath) { 'File' } elseif ($RegistryDetectionKey) { 'Registry' } elseif ($CustomDetectionScriptPath) { 'Script' } else { if ($extension -eq '.exe') { 'File' } else { 'MSI' } }
}

if ($chosenDetection -eq 'File' -and -not $FileDetectionPath) { $FileDetectionPath = 'C:\Program Files\<AppFolder>\' + (Split-Path -Leaf $resolvedInstaller) }
if ($chosenDetection -eq 'File' -and -not $FileDetectionVersion) { $FileDetectionVersion = $installerMeta.ProductVersion }
if ($chosenDetection -eq 'Registry' -and -not $RegistryDetectionKey) { $RegistryDetectionKey = 'HKLM:SOFTWARE\<Vendor>\<AppName>' }

$detectionMetadata = New-DetectionMetadata -InstallerMetadata $installerMeta -ChosenMethod $chosenDetection -FilePath $FileDetectionPath -FileVersion $FileDetectionVersion -RegKey $RegistryDetectionKey -RegValueName $RegistryDetectionValueName -RegValueData $RegistryDetectionValueData -MSIProductCode $installerMeta.ProductCode -CustomScript $CustomDetectionScriptPath

$packageId = [Guid]::NewGuid().ToString()
$workingRoot = Join-Path ([IO.Path]::GetTempPath()) ("IntuneAppPkg_{0}" -f $packageId)
$sourceDir = Join-Path $workingRoot 'Source'
New-Item -ItemType Directory -Path $sourceDir -Force | Out-Null
Copy-Item -Path $resolvedInstaller -Destination $sourceDir -Force

$setupFile = Split-Path -Leaf $resolvedInstaller
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$sanitizedApp = ($AppName -replace '[^A-Za-z0-9._-]','_')
$intuneWinOutputDir = $OutputPath
$expectedWinFile = Join-Path $intuneWinOutputDir ("{0}_{1}.intunewin" -f $sanitizedApp,$timestamp)

Write-IntuneLog -Message 'Preparing to invoke IntuneWinAppUtil...' -Level Info
Write-IntuneLog -Message "InstallCommand = $InstallCommand" -Level Debug
Write-IntuneLog -Message "UninstallCommand = $UninstallCommand" -Level Debug
Write-IntuneLog -Message "Detection = $($detectionMetadata.Method)" -Level Debug

if ($PSCmdlet.ShouldProcess($expectedWinFile,'Create .intunewin package')) {
    try {
        Write-IntuneLog -Message "Invoking IntuneWinAppUtil.exe" -Level Info
        $invokeStart = Get-Date
        $toolOutput = & $toolPath -c $sourceDir -s $setupFile -o $intuneWinOutputDir -q 2>&1
        $exitCode = $LASTEXITCODE
        Write-IntuneLog -Message "IntuneWinAppUtil exit code: $exitCode" -Level Debug
        if ($toolOutput) { Write-Verbose ($toolOutput -join [Environment]::NewLine) }

        # Primary expected naming pattern
        $produced = Get-ChildItem -Path $intuneWinOutputDir -Filter ($setupFile + '.intunewin') -ErrorAction SilentlyContinue | Select-Object -First 1
        # Fallback: any .intunewin generated in output path after invocation start
        if (-not $produced) {
            $candidates = Get-ChildItem -Path $intuneWinOutputDir -Filter '*.intunewin' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $invokeStart.AddSeconds(-5) }
            if ($candidates.Count -eq 1) { $produced = $candidates | Select-Object -First 1 }
        }
        # Second fallback: search recursively
        if (-not $produced) {
            $candidates = Get-ChildItem -Path $intuneWinOutputDir -Recurse -Filter '*.intunewin' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $invokeStart.AddSeconds(-5) }
            if ($candidates.Count -eq 1) { $produced = $candidates | Select-Object -First 1 }
        }
        # Retry without -q if nothing produced and exit code non-zero or no file discovered
        if (-not $produced) {
            Write-IntuneLog -Message 'Expected file not found after quiet run. Retrying without -q for diagnostics...' -Level Warning
            $toolOutput2 = & $toolPath -c $sourceDir -s $setupFile -o $intuneWinOutputDir 2>&1
            $exitCode2 = $LASTEXITCODE
            Write-IntuneLog -Message "Retry exit code: $exitCode2" -Level Debug
            if ($toolOutput2) { Write-Warning ("IntuneWinAppUtil (retry) output:`n" + ($toolOutput2 -join [Environment]::NewLine)) }
            $produced = Get-ChildItem -Path $intuneWinOutputDir -Filter ($setupFile + '.intunewin') -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $produced) {
                $produced = Get-ChildItem -Path $intuneWinOutputDir -Filter '*.intunewin' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            }
        }

        if ($produced) {
            if ($produced.FullName -ne $expectedWinFile) {
                Move-Item -Path $produced.FullName -Destination $expectedWinFile -Force
            }
        }

        if (-not (Test-Path $expectedWinFile)) {
            Write-Warning 'Could not locate produced .intunewin file. Directory listing:'
            Get-ChildItem -Path $intuneWinOutputDir | ForEach-Object { Write-Host ("  - " + $_.FullName) }
            throw 'Expected .intunewin file not created.'
        }
        Write-IntuneLog -Message "Package created: $expectedWinFile" -Level Success
    } catch {
        throw "Failed to create .intunewin package: $_"
    }
}

$generatedDetectionScript = $null
if ($chosenDetection -eq 'Script') {
    $generatedDetectionScript = Join-Path $OutputPath 'DetectionScript.ps1'
    if (-not $CustomDetectionScriptPath) {
@'
# DetectionScript.ps1
# Return 0 exit code if application is detected; non-zero otherwise.
$target = "C:\\Program Files\\<AppFolder>\\<AppExe>"
if (Test-Path $target) { exit 0 } else { exit 1 }
'@ | Out-File -FilePath $generatedDetectionScript -Encoding UTF8 -Force
    } else {
        Copy-Item -Path $CustomDetectionScriptPath -Destination $generatedDetectionScript -Force
    }
    Write-IntuneLog -Message "Detection script generated: $generatedDetectionScript" -Level Success
}

$metadata = [ordered]@{
    AppName                 = $AppName
    Publisher               = $Publisher
    Version                 = $installerMeta.ProductVersion
    SourceInstaller         = $resolvedInstaller
    InstallerType           = if ($extension -eq '.msi') { 'MSI' } else { 'EXE' }
    PackageFile             = $expectedWinFile
    CreatedOn               = (Get-Date).ToString('o')
    InstallCommand          = $InstallCommand
    UninstallCommand        = $UninstallCommand
    Detection               = $detectionMetadata
    HeuristicSilentSwitches = if ($installerMeta.SilentSwitchHints) { $installerMeta.SilentSwitchHints } else { @() }
    WorkingId               = $packageId
    GeneratedBy             = $script:ScriptName
    Notes                   = 'Import Metadata.json reference values manually into Intune portal.'
}
$metadataPath = Join-Path $OutputPath ("{0}_{1}_Metadata.json" -f $sanitizedApp,$timestamp)
if ($PSCmdlet.ShouldProcess($metadataPath,'Write metadata JSON')) {
    $metadata | ConvertTo-Json -Depth 8 | Out-File -FilePath $metadataPath -Encoding UTF8 -Force
    Write-IntuneLog -Message "Metadata exported: $metadataPath" -Level Success
}

#region Summary
Write-IntuneLog -Message 'Summary:' -Level Info
Write-Host (' App Name      : {0}' -f $AppName)
Write-Host (' Publisher     : {0}' -f $Publisher)
Write-Host (' Version       : {0}' -f $installerMeta.ProductVersion)
Write-Host (' InstallerType : {0}' -f $metadata.InstallerType)
Write-Host (' Package File  : {0}' -f $expectedWinFile)

# Show package file size
if (Test-Path $expectedWinFile) {
    $pkgSize = [math]::Round((Get-Item $expectedWinFile).Length / 1MB, 2)
    Write-Host (' Package Size  : {0} MB' -f $pkgSize)
}

Write-Host (' Metadata File : {0}' -f $metadataPath)
Write-Host (' Detection     : {0}' -f $detectionMetadata.Method)
if ($installerMeta.SilentSwitchHints) { Write-Host (' Silent Hints  : {0}' -f ($installerMeta.SilentSwitchHints -join ', ')) }

# Logo matching - check for a Logo folder near the output
$logoSearchPaths = @(
    (Join-Path (Split-Path $OutputPath -Parent) 'Logo')
    (Join-Path $PSScriptRoot 'Logo')
)
$logoFolder = $logoSearchPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($logoFolder) {
    $logoExtensions = @('.png', '.jpg', '.jpeg', '.svg', '.ico')
    $appNameNormalized = ($AppName -replace '[^a-zA-Z0-9]', '').ToLower()
    $matchedLogo = Get-ChildItem -Path $logoFolder -File |
                   Where-Object { $logoExtensions -contains $_.Extension.ToLowerInvariant() } |
                   Where-Object {
                       $fileNormalized = ($_.BaseName -replace '[^a-zA-Z0-9]', '').ToLower()
                       $fileNormalized -like "*$appNameNormalized*" -or $appNameNormalized -like "*$fileNormalized*"
                   } |
                   Select-Object -First 1

    if ($matchedLogo) {
        Write-Host (' Logo          : {0}' -f $matchedLogo.FullName) -ForegroundColor Magenta
    } else {
        $availableLogos = Get-ChildItem -Path $logoFolder -File |
                          Where-Object { $logoExtensions -contains $_.Extension.ToLowerInvariant() }
        if ($availableLogos.Count -gt 0) {
            Write-Host ""
            Write-Host " No matching logo for '$AppName'. Available:" -ForegroundColor DarkYellow
            foreach ($logo in $availableLogos) {
                Write-Host ("   $($logo.Name)") -ForegroundColor DarkGray
            }
        }
    }
}
#endregion

Write-IntuneLog -Message 'Completed.' -Level Success
#endregion
