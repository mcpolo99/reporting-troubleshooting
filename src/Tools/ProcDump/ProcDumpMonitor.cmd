@echo off
rem Launcher for ProcDumpMonitor.ps1 - double-click this file.
rem Keep it in the same folder as ProcDumpMonitor.ps1.
rem Extra arguments are passed through, e.g.:  ProcDumpMonitor.cmd -Install
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ProcDumpMonitor.ps1" %*
