@echo off
REM ============================================================
REM  Run-ProcDumpCase.bat
REM  Launches ProcDumpCase.ps1 in interactive mode.
REM  Keep this .bat in the SAME folder as ProcDumpCase.ps1.
REM  Double-click it, or right-click > Run as administrator.
REM ============================================================

setlocal
cd /d "%~dp0"

set "PS1=%~dp0ProcDumpCase.ps1"

if not exist "%PS1%" (
    echo.
    echo  ERROR: ProcDumpCase.ps1 was not found next to this .bat file.
    echo  Put both files in the same folder and try again.
    echo  Looked for: "%PS1%"
    echo.
    pause
    exit /b 1
)

echo Starting ProcDumpCase (interactive)...
echo (The script will ask for administrator rights - approve the prompt.)
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%"

echo.
echo ProcDumpCase has finished. If a separate elevated window opened,
echo the results and prompts were shown there.
pause
endlocal
