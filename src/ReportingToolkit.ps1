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

# A fatal startup failure (e.g. a Group-Policy-enforced execution policy that blocks loading the component
# .ps1 even with -ExecutionPolicy Bypass) must not vanish with a blank console. Log it and keep the window
# open so the cause is visible. Covers dot-sourcing (before any UI) and the route.
try {
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
} catch {
    $msg = $_.Exception.Message
    Write-Host ''
    Write-Host "Reporting & Troubleshooting failed to start: $msg" -ForegroundColor Red
    if ($_.Exception -is [System.Management.Automation.PSSecurityException] -or $msg -match 'running scripts is disabled') {
        Write-Host 'This machine blocks script execution via policy. Check: Get-ExecutionPolicy -List' -ForegroundColor Yellow
        Write-Host 'If MachinePolicy/UserPolicy is set, it overrides -ExecutionPolicy Bypass (Group Policy).' -ForegroundColor Yellow
    }
    try {
        $logDir = Join-Path $env:LOCALAPPDATA 'ReportingTroubleshooting\Logs'
        New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
        $log = Join-Path $logDir ('startup_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))
        $_ | Out-String | Set-Content -LiteralPath $log -Encoding UTF8
        Write-Host "Details written to: $log" -ForegroundColor Yellow
    } catch {}
    if ([Environment]::UserInteractive) { try { Read-Host 'Press Enter to close' | Out-Null } catch {} }
}
