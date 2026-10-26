# Library host for the shared package engine (Common\Packages.ps1), so the GUI/CLI can run installs in an
# isolated runspace with the shared logging scaffolding. The install LOGIC and catalogue live in
# Common\Packages.ps1 (single source of truth); this file only wires logging + Common so it is hostable.
# Loaded as a library (RT_LIBRARY=1) by New-ToolRunspace -Load.

$PkgScriptDir = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }

$CommonDir = $null; $__probe = $PkgScriptDir
for ($__i = 0; $__i -lt 6 -and -not $CommonDir; $__i++) {
    foreach ($__c in @((Join-Path $__probe 'Common'), (Join-Path $__probe 'Scripts\Common'))) {
        if (Test-Path (Join-Path $__c 'Common.ps1')) { $CommonDir = $__c; break }
    }
    $__parent = Split-Path $__probe -Parent
    if (-not $__parent -or $__parent -eq $__probe) { break }
    $__probe = $__parent
}
if (-not $CommonDir) { throw "Shared components (Common\) not found from $PkgScriptDir upward." }

$AppName = 'ReportingTroubleshooting'
$BaseDir = Join-Path $env:ProgramData $AppName
$LogDir  = Join-Path $BaseDir 'Logs'
$script:LogPrefix = 'Packages'
$script:EchoLog   = $false
$script:LogMaxMB  = 10

. (Join-Path $CommonDir 'Logging.ps1')
. (Join-Path $CommonDir 'Common.ps1')
. (Join-Path $CommonDir 'Packages.ps1')
# (Fault-id dependency verification lives on the ProcDump Monitor tab - it is app-aware and runs in the
# monitor runspace via Get-MonitorDepReport; the Packages tool only installs/resolves packages.)
