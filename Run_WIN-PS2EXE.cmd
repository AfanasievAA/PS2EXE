@echo off
:: Check if PowerShell 7+ (pwsh) is installed and available in PATH
where pwsh >nul 2>nul
if %ERRORLEVEL% equ 0 (
    set "PS_CMD=pwsh"
    goto :run
)

:: Check if Windows PowerShell 5.1 (powershell.exe) is installed and available in PATH
where powershell >nul 2>nul
if %ERRORLEVEL% equ 0 (
    echo PowerShell 7 was not found, using Windows PowerShell 5.1.
    set "PS_CMD=powershell"
    goto :run
)

:: Nothing found
echo PowerShell was not found on your system.
echo Please download and install the latest version from: https://aka.ms/powershell
pause
exit /b 1

:run
:: Full path to the PowerShell script (the folder where this .cmd resides) with the same name as the CMD file
set "PS_SCRIPT=%~dp0%~n0.ps1"
:: If a command-line argument was supplied, use it as the XML file path.
:: Otherwise pass an empty string (the PowerShell script will receive $null)
set "XML_ARG=%~1"
:: Run PowerShell
::   -NoProfile          - run without loading any profiles
::   -ExecutionPolicy Bypass - allow execution even when a restrictive policy is set
::   -File               - specify the script file to run
::   "%XML_ARG%"         - first positional parameter of the script (full path to the XML file)
"%PS_CMD%" -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" "%XML_ARG%"