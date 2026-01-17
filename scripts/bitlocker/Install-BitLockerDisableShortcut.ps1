<#
.SYNOPSIS
    Installs a desktop shortcut that allows users to disable BitLocker on the OS drive.

.DESCRIPTION
    Deploys via Intune Company Portal. Creates:
    - PowerShell script to disable BitLocker
    - Scheduled task (runs as SYSTEM) to execute the script
    - Desktop shortcut for the current user to trigger decryption

.NOTES
    Run as SYSTEM context via Intune Win32 app deployment.
    Use case: Prepare devices for Intune/Autopilot reset by removing BitLocker PIN requirement.
#>

$ErrorActionPreference = "Stop"

# Configuration
$ToolsFolder = "C:\ProgramData\IntuneTools"
$ScriptPath = Join-Path $ToolsFolder "Disable-BitLocker.ps1"
$LogPath = Join-Path $ToolsFolder "BitLocker.log"
$TaskName = "Disable-BitLocker"
$ShortcutName = "Disable BitLocker.lnk"

# Simple logging function
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] $Message"
    Add-Content -Path $LogPath -Value $entry -Force
    Write-Host $entry
}

# Create tools folder
if (-not (Test-Path $ToolsFolder)) {
    New-Item -Path $ToolsFolder -ItemType Directory -Force | Out-Null
}

Write-Log "Starting installation of BitLocker disable shortcut"

# Create the BitLocker disable script
$disableScript = @'
$LogPath = "C:\ProgramData\IntuneTools\BitLocker.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogPath -Value "[$timestamp] $Message" -Force
}

try {
    Write-Log "BitLocker disable initiated by user"

    # Check current BitLocker status
    $volume = Get-BitLockerVolume -MountPoint "C:" -ErrorAction Stop

    if ($volume.ProtectionStatus -eq "Off") {
        Write-Log "BitLocker protection is already off on C: drive"
        $msg = "BitLocker is already disabled on the C: drive."
    }
    elseif ($volume.VolumeStatus -eq "FullyDecrypted") {
        Write-Log "C: drive is already fully decrypted"
        $msg = "The C: drive is already decrypted."
    }
    else {
        Write-Log "Disabling BitLocker on C: drive (Status: $($volume.VolumeStatus), Protection: $($volume.ProtectionStatus))"
        Disable-BitLocker -MountPoint "C:" -ErrorAction Stop
        Write-Log "BitLocker decryption started successfully"
        $msg = "BitLocker decryption has started on the C: drive.`n`nThis may take a while. You can continue working normally."
    }

    # Show notification to user
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show($msg, "BitLocker", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show("Failed to disable BitLocker: $($_.Exception.Message)", "BitLocker Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    exit 1
}
'@

Set-Content -Path $ScriptPath -Value $disableScript -Force
Write-Log "Created BitLocker disable script at $ScriptPath"

# Create scheduled task (runs as SYSTEM to have admin rights)
$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Log "Removed existing scheduled task"
}

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $settings -Description "Disables BitLocker on C: drive for Intune/Autopilot reset preparation" | Out-Null
Write-Log "Created scheduled task: $TaskName"

# Get current logged-in user's desktop
$loggedInUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
if ($loggedInUser) {
    $username = $loggedInUser.Split('\')[-1]
    $userDesktop = "C:\Users\$username\Desktop"

    if (Test-Path $userDesktop) {
        $shortcutPath = Join-Path $userDesktop $ShortcutName

        # Create shortcut using WScript.Shell
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = "schtasks.exe"
        $shortcut.Arguments = "/run /tn `"$TaskName`""
        $shortcut.Description = "Disable BitLocker on C: drive"
        $shortcut.IconLocation = "imageres.dll,54"
        $shortcut.Save()

        Write-Log "Created desktop shortcut for user $username at $shortcutPath"
    }
    else {
        Write-Log "WARNING: Could not find desktop for user $username"
    }
}
else {
    Write-Log "WARNING: No user currently logged in - shortcut not created"
}

Write-Log "Installation completed successfully"
exit 0
