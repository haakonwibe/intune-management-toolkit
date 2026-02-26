@echo off
REM Quick launcher - runs the PowerShell wrapper in the same directory
where pwsh >nul 2>&1 && (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0New-IntuneWinPackage.ps1" %*
) || (
    PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0New-IntuneWinPackage.ps1" %*
)
pause
