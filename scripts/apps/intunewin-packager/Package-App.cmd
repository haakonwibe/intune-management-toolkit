@echo off
REM Quick launcher - runs the PowerShell wrapper in the same directory
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0New-IntuneWinPackage.ps1" %*
pause
