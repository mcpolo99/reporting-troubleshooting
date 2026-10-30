#Requires -Version 5.1
<#
.SYNOPSIS
  Fault-identify one dump (or every dump in a folder) and apply keep-first-count-rest de-duplication.

  The ProcDump monitor spawns this DETACHED, one per newly written dump, so the slow part (the ClrMD
  managed stack walk that opens the dump) never blocks the monitor loop. It also backs the "Identify /
  re-scan dumps" on-demand action: with -DumpDir (or no args, using the configured dump folder) it triages
  every .dmp present and prints a summary.

  Decision (see Common\DumpId.ps1 Invoke-DumpTriage): compute the stable fault id; the FIRST dump of an id
  is kept, later recurrences are counted and deleted (no local recurrence store).
  A provisional id (hang/managed-exception whose walk could not run) is never suppressed.

.USAGE
  powershell -NoProfile -ExecutionPolicy Bypass -File DumpTriage.ps1 -DumpPath C:\dumps\bSuite_...dmp
  powershell -NoProfile -ExecutionPolicy Bypass -File DumpTriage.ps1 -DumpDir C:\dumps
  powershell -NoProfile -ExecutionPolicy Bypass -File DumpTriage.ps1            # uses the monitor's DumpDir
#>
[CmdletBinding()]
param(
    [string]$DumpPath,       # a single dump (the monitor's per-dump worker)
    [string]$DumpDir,        # triage every .dmp here (on-demand); defaults to the monitor's configured DumpDir
    [switch]$Quiet
)

# The monitor runs this DETACHED + hidden + -Quiet, so a crash (e.g. an incomplete engine deploy) would be
# invisible - which looks exactly like "dumps appear but no JSON/registry". Log any terminating error to a
# file so it is never silent.
trap {
    try {
        $__ld = Join-Path $env:ProgramData 'ReportingTroubleshooting\Monitor\Logs'
        if (-not (Test-Path $__ld)) { New-Item -ItemType Directory -Path $__ld -Force | Out-Null }
        Add-Content -LiteralPath (Join-Path $__ld 'DumpTriage-error.log') -Encoding UTF8 `
            -Value ('{0}  FAILED: {1}`n{2}' -f (Get-Date -Format o), $_.Exception.Message, $_.ScriptStackTrace)
    } catch {}
    if (-not $Quiet) { Write-Host "DumpTriage failed: $($_.Exception.Message)" -ForegroundColor Red }
    exit 1
}

$ScriptDir = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }

# locate Common\ upward (same probe the other tools use)
$CommonDir = $null; $__probe = $ScriptDir
for ($__i = 0; $__i -lt 6 -and -not $CommonDir; $__i++) {
    foreach ($__c in @((Join-Path $__probe 'Common'), (Join-Path $__probe 'Scripts\Common'))) {
        if (Test-Path (Join-Path $__c 'Common.ps1')) { $CommonDir = $__c; break }
    }
    $__parent = Split-Path $__probe -Parent
    if (-not $__parent -or $__parent -eq $__probe) { break }
    $__probe = $__parent
}
if (-not $CommonDir) { throw "Shared components (Common\) not found from $ScriptDir upward." }
. (Join-Path $CommonDir 'Common.ps1')
. (Join-Path $CommonDir 'Packages.ps1')
. (Join-Path $CommonDir 'DumpId.ps1')
. (Join-Path $CommonDir 'Telemetry.ps1')   # Compress-DumpFile: triage gzips every kept dump at rest

# read the monitor config for the dedupe settings (this is a separate process from the monitor)
$MonConfig = Join-Path $env:ProgramData 'ReportingTroubleshooting\Monitor\config.json'
$cfg = $null; if (Test-Path $MonConfig) { try { $cfg = Get-Content $MonConfig -Raw | ConvertFrom-Json } catch {} }
function Cfg($name, $default) { if ($cfg -and $null -ne $cfg.$name -and "$($cfg.$name)" -ne '') { $cfg.$name } else { $default } }

if (-not $DumpDir) { $DumpDir = Cfg 'DumpDir' 'C:\dumps' }
$suppressKnown  = [bool](Cfg 'SuppressKnown' $true)
$clrmd    = Resolve-PackageTool 'clrmd'
# Known store resolution order: an explicit config BaselinePath, else the SYNCED copy under KnownIssues (what
# the backend sync writes), else the baseline SHIPPED with the build beside this script (so a fresh/offline box
# still ignores already-analysed ids from first run). First existing wins; none -> no baseline.
$synced = $null; try { $synced = (Get-TelemetryConfig).BaselinePath } catch {}
$shipped = Join-Path $ScriptDir 'known-issues.baseline.json'
$cfgBase = "$(Cfg 'BaselinePath' '')"
$baseline = @($cfgBase, $synced, $shipped) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace("$baseline")) { $baseline = $null }

# Write to the host, not the success pipeline - so a caller that captures Triage-One's return value gets
# only the result object, and a detached worker's stdout stays clean.
function Say($m) { if (-not $Quiet) { Write-Host $m } }

# A backend endpoint being configured means a grant could still come, so a known signature is KEPT (held) and
# offered rather than dropped. Pure local/offline mode (no http endpoint) means no grant can ever come, so a
# known signature's bytes are dropped. Get-TelemetryConfig is available (Telemetry.ps1 is dot-sourced above).
$script:IsOnline = $false
try { $script:IsOnline = [bool](Test-IsHttp (Get-TelemetryConfig).EventSink) } catch {}

function Triage-One([string]$Path) {
    $r = Invoke-DumpTriage -DumpPath $Path -ClrMdDll $clrmd -BaselinePath $baseline -SuppressKnown $suppressKnown -IsOnline $script:IsOnline
    $name = [IO.Path]::GetFileName($Path)
    Say ("{0,-40} {1,-9} id={2} x{3,-4} {4}{5}" -f $name, $r.Collect, $r.Id, $r.Count, $r.Leaf, $(if ($r.Disposition -and $r.Disposition -ne 'kept') { " ($($r.Disposition))" } else { '' }))
    return $r
}

if ($DumpPath) {
    [void](Triage-One $DumpPath)
} else {
    if (-not (Test-Path $DumpDir)) { Say "Dump folder not found: $DumpDir"; return }
    $dumps = @(Get-ChildItem -Path $DumpDir -Filter *.dmp -File -ErrorAction SilentlyContinue | Sort-Object CreationTime)
    Say ("Triaging {0} dump(s) in {1} (walk tool: {2})`n" -f $dumps.Count, $DumpDir, $(if ($clrmd) { 'ClrMD' } else { 'NONE - hangs stay provisional' }))
    $kept = 0; $dropped = 0; $defer = 0
    foreach ($d in $dumps) {
        $r = Triage-One $d.FullName
        switch ($r.Collect) { 'collect' { $kept++ } 'drop' { $dropped++ } 'defer' { $defer++ } }
    }
    Say ("`nDone: {0} collected, {1} dropped, {2} deferred (provisional)." -f $kept, $dropped, $defer)
}
