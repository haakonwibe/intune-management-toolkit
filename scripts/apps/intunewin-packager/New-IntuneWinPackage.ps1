<#
.SYNOPSIS
    Wrapper for IntuneWinAppUtil.exe that simplifies .intunewin package creation.

.DESCRIPTION
    Auto-discovers apps in the .\Apps folder, detects installer files, and invokes
    IntuneWinAppUtil.exe with the correct parameters. Designed to work alongside
    the standard Intune packaging folder structure:

        C:\Intune\
        +-- IntuneWinAppUtil.exe
        +-- New-IntuneWinPackage.ps1   (this script)
        +-- Apps\
        |   +-- 7-Zip EXE\
        |   |   +-- 7z2409-x64.exe
        |   +-- CMTrace\
        |       +-- CMTrace.exe
        +-- Output\
        +-- Logo\

.PARAMETER AppName
    Name of the app folder under .\Apps\. If omitted, an interactive menu is shown.

.PARAMETER SetupFile
    Name of the installer file. If omitted, auto-detected (or menu if multiple found).

.PARAMETER OutputFolder
    Override the output path. Defaults to .\Output.

.PARAMETER CatalogFolder
    Override the catalog/source folder. Defaults to empty (no catalog).

.PARAMETER SubfolderOutput
    If specified, creates a subfolder under Output named after the app.

.PARAMETER Init
    Creates the expected folder structure (Apps, Output, Logo) if it doesn't exist.
    Use this when setting up a new packaging environment.

.PARAMETER WhatIf
    Shows what would be executed without actually running IntuneWinAppUtil.exe.

.EXAMPLE
    .\New-IntuneWinPackage.ps1 -Init
    # Creates the Apps, Output, and Logo folders if they don't exist

.EXAMPLE
    .\New-IntuneWinPackage.ps1
    # Interactive mode - pick from discovered apps

.EXAMPLE
    .\New-IntuneWinPackage.ps1 -AppName "7-Zip EXE"
    # Auto-detects the setup file in that folder

.EXAMPLE
    .\New-IntuneWinPackage.ps1 -AppName "7-ZipMSI" -SetupFile "7z2501-x64.msi" -SubfolderOutput
    # Explicit setup file, output goes to .\Output\7-ZipMSI\

.NOTES
    Author : Haakon Wibe / alttabtowork.com
    Version: 1.1.0
    Date   : 2025-02-26
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [string]$AppName,

    [Parameter(Position = 1)]
    [string]$SetupFile,

    [string]$OutputFolder,

    [string]$CatalogFolder,

    [switch]$SubfolderOutput,

    [switch]$Init
)

#region --- Configuration ---
$IntuneRoot    = $PSScriptRoot
$AppsFolder    = Join-Path $IntuneRoot "Apps"
$DefaultOutput = Join-Path $IntuneRoot "Output"
$ToolExe       = Join-Path $IntuneRoot "IntuneWinAppUtil.exe"

# Installer file extensions to look for (in priority order)
$InstallerExtensions = @('.exe', '.msi', '.msix', '.ps1', '.cmd', '.bat')
#endregion

#region --- Init Mode ---
if ($Init) {
    Write-Host ""
    Write-Host "=== Initializing Intune Packaging Environment ===" -ForegroundColor Cyan
    Write-Host "  Root: $IntuneRoot" -ForegroundColor DarkGray
    Write-Host ""

    $foldersToCreate = @("Apps", "Output", "Logo")
    foreach ($folder in $foldersToCreate) {
        $path = Join-Path $IntuneRoot $folder
        if (Test-Path $path) {
            Write-Host "  [OK] $folder\" -ForegroundColor Green
        }
        else {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
            Write-Host "  [Created] $folder\" -ForegroundColor Yellow
        }
    }

    # Check for IntuneWinAppUtil.exe
    Write-Host ""
    if (Test-Path $ToolExe) {
        Write-Host "  [OK] IntuneWinAppUtil.exe" -ForegroundColor Green
    }
    else {
        Write-Host "  [Missing] IntuneWinAppUtil.exe" -ForegroundColor Red
        Write-Host "           Download from: https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "Ready! Add app installer folders under .\Apps\ and run the script again." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Example folder structure:" -ForegroundColor DarkGray
    Write-Host "    Apps\7-Zip\7z2409-x64.exe" -ForegroundColor DarkGray
    Write-Host "    Apps\CMTrace\CMTrace.exe" -ForegroundColor DarkGray
    Write-Host "    Logo\7zip.png" -ForegroundColor DarkGray
    Write-Host ""
    return
}
#endregion

#region --- Validation ---
$problems = @()

$hasToolExe   = Test-Path $ToolExe
$hasAppsFolder = Test-Path $AppsFolder

if (-not $hasToolExe) {
    $problems += "IntuneWinAppUtil.exe"
}
if (-not $hasAppsFolder) {
    $problems += "Apps folder"
}

if ($problems.Count -gt 0) {
    Write-Host ""
    Write-Host "=== Environment Check ===" -ForegroundColor Cyan
    Write-Host "  Location: $IntuneRoot" -ForegroundColor DarkGray
    Write-Host ""

    # Show status of everything
    $items = @(
        @{ Name = "IntuneWinAppUtil.exe"; Exists = $hasToolExe;    Hint = "Download from: https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool" }
        @{ Name = "Apps\";               Exists = $hasAppsFolder;  Hint = "Create this folder and add app subfolders with installers" }
        @{ Name = "Output\";             Exists = (Test-Path $DefaultOutput); Hint = "Will be created automatically when packaging" }
        @{ Name = "Logo\";               Exists = (Test-Path (Join-Path $IntuneRoot "Logo")); Hint = "Optional - store app logos here for easy reference" }
    )

    foreach ($item in $items) {
        if ($item.Exists) {
            Write-Host "  [OK]      $($item.Name)" -ForegroundColor Green
        }
        else {
            Write-Host "  [Missing] $($item.Name)" -ForegroundColor Red
            Write-Host "            $($item.Hint)" -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host "Tip: Run with -Init to create the folder structure automatically:" -ForegroundColor Yellow
    Write-Host "  .\New-IntuneWinPackage.ps1 -Init" -ForegroundColor Yellow
    Write-Host ""
    return
}
#endregion

#region --- App Selection ---
if (-not $AppName) {
    $appFolders = Get-ChildItem -Path $AppsFolder -Directory | Sort-Object Name

    if ($appFolders.Count -eq 0) {
        Write-Host ""
        Write-Host "=== No Apps Found ===" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  The Apps folder is empty: $AppsFolder" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Create a subfolder for each app with its installer inside:" -ForegroundColor DarkGray
        Write-Host "    Apps\7-Zip\7z2409-x64.exe" -ForegroundColor DarkGray
        Write-Host "    Apps\CMTrace\CMTrace.exe" -ForegroundColor DarkGray
        Write-Host "    Apps\MyApp\Install-MyApp.ps1" -ForegroundColor DarkGray
        Write-Host ""
        return
    }

    Write-Host ""
    Write-Host "=== Available Apps ===" -ForegroundColor Cyan
    Write-Host ""
    for ($i = 0; $i -lt $appFolders.Count; $i++) {
        $folder = $appFolders[$i]
        $files  = Get-ChildItem -Path $folder.FullName -File |
                  Where-Object { $InstallerExtensions -contains $_.Extension }
        $fileList = ($files | ForEach-Object { $_.Name }) -join ", "
        Write-Host "  [$($i + 1)] $($folder.Name)" -ForegroundColor Yellow -NoNewline
        Write-Host "  ($fileList)" -ForegroundColor DarkGray
    }

    Write-Host ""
    $selection = Read-Host "Select app (1-$($appFolders.Count))"

    if ($selection -match '^\d+$' -and [int]$selection -ge 1 -and [int]$selection -le $appFolders.Count) {
        $AppName = $appFolders[[int]$selection - 1].Name
    }
    else {
        Write-Error "Invalid selection."
        return
    }
}

$appPath = Join-Path $AppsFolder $AppName
if (-not (Test-Path $appPath)) {
    Write-Error "App folder not found: $appPath"
    return
}
#endregion

#region --- Setup File Detection ---
if (-not $SetupFile) {
    $installers = Get-ChildItem -Path $appPath -File |
                  Where-Object { $InstallerExtensions -contains $_.Extension } |
                  Sort-Object {
                      # Sort by extension priority so .exe/.msi come first
                      $idx = $InstallerExtensions.IndexOf($_.Extension)
                      if ($idx -ge 0) { $idx } else { 999 }
                  }

    if ($installers.Count -eq 0) {
        Write-Error "No installer files found in: $appPath"
        Write-Error "Looking for extensions: $($InstallerExtensions -join ', ')"
        return
    }
    elseif ($installers.Count -eq 1) {
        $SetupFile = $installers[0].Name
        Write-Host "Auto-detected setup file: $SetupFile" -ForegroundColor Green
    }
    else {
        Write-Host ""
        Write-Host "=== Multiple installers found ===" -ForegroundColor Cyan
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
            $SetupFile = $installers[[int]$selection - 1].Name
        }
        else {
            Write-Error "Invalid selection."
            return
        }
    }
}

# Verify the setup file exists
$setupFilePath = Join-Path $appPath $SetupFile
if (-not (Test-Path $setupFilePath)) {
    Write-Error "Setup file not found: $setupFilePath"
    return
}
#endregion

#region --- Output Path ---
if (-not $OutputFolder) {
    $OutputFolder = $DefaultOutput
}

if ($SubfolderOutput) {
    $OutputFolder = Join-Path $OutputFolder $AppName
}

if (-not (Test-Path $OutputFolder)) {
    Write-Host "Creating output folder: $OutputFolder" -ForegroundColor DarkGray
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}
#endregion

#region --- Build & Execute ---
$arguments = @(
    "-c", "`"$appPath`""
    "-s", "`"$SetupFile`""
    "-o", "`"$OutputFolder`""
)

if ($CatalogFolder) {
    $arguments += "-a", "`"$CatalogFolder`""
}

# Quiet mode (suppress confirmation prompts in the tool)
$arguments += "-q"

Write-Host ""
Write-Host "=== Packaging ===" -ForegroundColor Cyan
Write-Host "  App:    $AppName" -ForegroundColor White
Write-Host "  Setup:  $SetupFile" -ForegroundColor White
Write-Host "  Source: $appPath" -ForegroundColor DarkGray
Write-Host "  Output: $OutputFolder" -ForegroundColor DarkGray
Write-Host ""

if ($PSCmdlet.ShouldProcess("$AppName ($SetupFile)", "Package with IntuneWinAppUtil")) {
    $command = "$ToolExe $($arguments -join ' ')"
    Write-Host "Executing: $command" -ForegroundColor DarkYellow
    Write-Host ""

    & $ToolExe @arguments

    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "Packaging complete!" -ForegroundColor Green

        # Show the output file
        $outputFiles = Get-ChildItem -Path $OutputFolder -Filter "*.intunewin" |
                       Sort-Object LastWriteTime -Descending |
                       Select-Object -First 1
        if ($outputFiles) {
            $size = [math]::Round($outputFiles.Length / 1MB, 2)
            Write-Host "Output: $($outputFiles.FullName) ($size MB)" -ForegroundColor Green
        }

        # Check for matching logo in the Logo folder
        $logoFolder = Join-Path $IntuneRoot "Logo"
        if (Test-Path $logoFolder) {
            $logoExtensions = @('.png', '.jpg', '.jpeg', '.svg', '.ico')

            # Try to find a logo matching the app name (fuzzy: strip spaces, dashes, etc.)
            $appNameNormalized = ($AppName -replace '[^a-zA-Z0-9]', '').ToLower()
            $matchedLogo = Get-ChildItem -Path $logoFolder -File |
                           Where-Object { $logoExtensions -contains $_.Extension } |
                           Where-Object {
                               $fileNormalized = ($_.BaseName -replace '[^a-zA-Z0-9]', '').ToLower()
                               $fileNormalized -like "*$appNameNormalized*" -or $appNameNormalized -like "*$fileNormalized*"
                           } |
                           Select-Object -First 1

            Write-Host ""
            if ($matchedLogo) {
                Write-Host "Logo:   $($matchedLogo.FullName)" -ForegroundColor Magenta
            }
            else {
                # No match - list what's available
                $availableLogos = Get-ChildItem -Path $logoFolder -File |
                                  Where-Object { $logoExtensions -contains $_.Extension }
                if ($availableLogos.Count -gt 0) {
                    Write-Host "No matching logo found for '$AppName'. Available logos:" -ForegroundColor DarkYellow
                    foreach ($logo in $availableLogos) {
                        Write-Host "    $($logo.FullName)" -ForegroundColor DarkGray
                    }
                }
                else {
                    Write-Host "No logos found in: $logoFolder" -ForegroundColor DarkGray
                }
            }
        }
    }
    else {
        Write-Host ""
        Write-Host "IntuneWinAppUtil exited with code: $LASTEXITCODE" -ForegroundColor Red
    }
}
#endregion