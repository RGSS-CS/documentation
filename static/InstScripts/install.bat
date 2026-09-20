@echo off
setlocal
rem Keep install.bat and install.ps1 in the same folder.
if not exist "%~dp0install.ps1" (
    echo ERROR: install.ps1 was not found beside install.bat.
    echo Download both files from the same documentation branch.
    exit /b 1
)
where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo ERROR: Windows PowerShell 5.1 or newer is required.
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
exit /b %errorlevel%
