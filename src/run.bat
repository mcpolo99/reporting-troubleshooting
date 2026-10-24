@echo off
setlocal

:: Launches the local Get.ps1 (next to this file) elevated - via Windows Terminal if present, else
:: PowerShell. Get.ps1 then version-checks against GitHub, installs/updates, and opens the toolkit.
:: (For a machine with no local copy, use the one-liner in README.md instead.)

set "wtDefaultPath=%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe"
set "wtScoopPath=%USERPROFILE%\scoop\apps\windows-terminal\current\wt.exe"
set "logDir=%LOCALAPPDATA%\ReportingTroubleshooting\Logs"
set "logFile=%logDir%\ReportingTroubleshooting-Run.log"

:: Ensure Logs folder exists
if not exist "%logDir%" mkdir "%logDir%"

:: Determine which terminal exists
if exist "%wtDefaultPath%" (
    set "wtPath=%wtDefaultPath%"
) else if exist "%wtScoopPath%" (
    set "wtPath=%wtScoopPath%"
) else (
    set "wtPath="
)

:: Interpolated into a PS single-quoted string below;
:: apostrophes escaped via %:'=''% and the -File arg uses [char]34 to avoid quote-parity bugs.
set "SCRIPT_PATH=%~dp0Get.ps1"

if defined wtPath (
    call :Log Launching Get.ps1 with Windows Terminal...
    PowerShell -NoProfile -ExecutionPolicy Bypass -Command "$p='%SCRIPT_PATH:'=''%'; $w='%wtPath:'=''%'; $q=[char]34; Start-Process -FilePath $w -ArgumentList ('PowerShell -NoProfile -ExecutionPolicy Bypass -File ' + $q + $p + $q) -Verb RunAs" >> "%logFile%" || call :Error "PowerShell command failed"
) else (
    echo Windows Terminal not found, using default PowerShell...
    call :Log Windows Terminal not found. Using default PowerShell to launch Get.ps1...
    PowerShell -NoProfile -ExecutionPolicy Bypass -Command "$p='%SCRIPT_PATH:'=''%'; $q=[char]34; Start-Process PowerShell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File ' + $q + $p + $q) -Verb RunAs" >> "%logFile%" || call :Error "PowerShell command failed"
)

echo.
echo If you need further assistance, see:
echo https://github.com/mcpolo99/reporting-troubleshooting
goto :EOF

:: Logging Function
:Log
echo(%* >> "%logFile%"
goto :EOF

:: Error Handler
:Error
echo(ERROR: %*
call :Log ERROR: %*
echo Logged in %logFile%
pause
goto :EOF
