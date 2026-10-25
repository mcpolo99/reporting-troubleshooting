#Requires -Version 5.1
# Entry point. Self-elevates, dot-sources the components, then opens the WPF window (default) or the
# text menu (-CLI, or when WPF is unavailable).
param([switch]$CLI)

# The interactive UI drives ETW collection, scheduled-task install and dump capture in-process, so the
# whole app needs admin. Self-elevate (unless already admin).
function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
if (-not (Test-Admin)) {
    $sw = if ($CLI) { ' -CLI' } else { '' }
    try {
        Start-Process powershell.exe -Verb RunAs -ErrorAction Stop `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"$sw"
    } catch { Write-Host 'Administrator rights are required.' -ForegroundColor Yellow }
    return
}

# Version is the single source of truth in the repo-root VERSION file (one level above src\).
$__verFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'VERSION'
$ScriptVersion = if (Test-Path $__verFile) { (Get-Content $__verFile -Raw).Trim() } else { '0.0.0' }

# -------- paths --------
$script:ToolkitRoot = $PSScriptRoot
$schemasPath = Join-Path $PSScriptRoot 'Schemas'
$script:MainWindowSchema   = Join-Path $schemasPath 'MainWindow.xaml'
$script:SharedStylesSchema = Join-Path $schemasPath 'SharedStyles.xaml'

# tool entry scripts - relative (CLI launcher) and absolute (GUI runspaces)
$script:ToolPerfView = 'Tools\PerfView\PerfViewCapture.ps1'
$script:ToolMonitor  = 'Tools\ProcDump\ProcDumpMonitor.ps1'
$script:ToolCase     = 'Tools\ProcDump\ProcDumpCase.ps1'
$script:ToolPackages = 'Tools\Packages\PackagesTool.ps1'
$script:ToolPerfViewPath = Join-Path $PSScriptRoot $script:ToolPerfView
$script:ToolMonitorPath  = Join-Path $PSScriptRoot $script:ToolMonitor
$script:ToolCasePath     = Join-Path $PSScriptRoot $script:ToolCase
$script:ToolPackagesPath = Join-Path $PSScriptRoot $script:ToolPackages

# -------- components (dot-sourced) --------
. (Join-Path $PSScriptRoot 'Helpers\Start-Tool.ps1')
. (Join-Path $PSScriptRoot 'Helpers\Install-Shortcut.ps1')
# Shared package engine (single source of truth for installs). Used by the CLI 'P' option; the GUI runs
# installs off the UI thread in its own runspace (via Tools\Packages\PackagesTool.ps1).
. (Join-Path $PSScriptRoot 'Common\Common.ps1')
. (Join-Path $PSScriptRoot 'Common\Packages.ps1')
. (Join-Path $PSScriptRoot 'CLI\Show-CliMenu.ps1')
. (Join-Path $PSScriptRoot 'GUI\Get-SystemUsesDarkMode.ps1')
. (Join-Path $PSScriptRoot 'GUI\Set-WindowThemeResources.ps1')
. (Join-Path $PSScriptRoot 'GUI\ToolRunspace.ps1')
. (Join-Path $PSScriptRoot 'GUI\Show-MainWindow.ps1')

# -------- route --------
if ($CLI) { Show-CliMenu; return }
try {
    Show-MainWindow
} catch {
    Write-Host "GUI unavailable ($($_.Exception.Message)) - falling back to the text menu." -ForegroundColor Yellow
    Show-CliMenu
}
