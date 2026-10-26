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
. (Join-Path $CommonDir 'DumpId.ps1')

# Verify the ENVIRONMENT the dump fault-identifier depends on but does NOT install (the already-delivered
# pieces: the box's own .NET Framework CLR + DAC, the system debug engine) and prove it by walking a real
# dump on this machine. Emits text lines (streamed to the GUI). The "Verify deps" button calls this.
function Test-Dependencies {
    $clrmd = Resolve-PackageTool 'clrmd'
    $dumpDir = 'C:\dumps'
    $monCfg = Join-Path $env:ProgramData 'ReportingTroubleshooting\Monitor\config.json'
    if (Test-Path $monCfg) { try { $d = (Get-Content $monCfg -Raw | ConvertFrom-Json).DumpDir; if ($d) { $dumpDir = $d } } catch {} }
    "Verifying dependencies (environment the hang/exception identifier needs - not installed by us):"
    $rows = Test-DumpWalkPrereqs -ClrMdDll $clrmd -DumpDir $dumpDir
    foreach ($r in $rows) { "  [{0,-4}] {1} - {2}" -f $r.Status, $r.Name, $r.Detail }
    $fail = @($rows | Where-Object { $_.Status -eq 'FAIL' }).Count
    if ($fail) { "RESULT: $fail check(s) FAILED - crash ids still work, but hang/managed-exception (Tier-2) ids are unavailable until fixed." }
    else { "RESULT: all required dependencies present - full crash + hang/managed-exception identification available." }
}
