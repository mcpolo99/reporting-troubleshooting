#Requires -Version 5.1
<#
.SYNOPSIS
  EDGE heap enrichment for a storm-class hang: count the WPF objects and merge the numbers into the event.

  Runs on the capturing PC (the machine already does the light triage, so it enriches locally and sends small
  numbers rather than a multi-GB dump). GATED to storm-class hangs (-FactsPath checks diagnosis.category) and
  meant to run DETACHED + low priority, post-capture - never on the monitor's hot path. FACTS ONLY: it counts
  Visual / FrameworkElement / BindingExpression objects; the "oversized UI" conclusion stays the analyst's.
  Heavier central analysis (native stacks, heap-failure records) is a separate engine - dumps-analysis-toolkit#41.

.USAGE
  # measure a dump and merge the counts into its event (only if the event is a storm, else -Force):
  powershell -File Measure-DumpHeap.ps1 -DumpPath x.dmp -FactsPath x.facts.json
  # re-merge an already-computed result without walking again:
  powershell -File Measure-DumpHeap.ps1 -FromHeapJson x.heap.json -FactsPath x.facts.json
  # just print/save the measurement:
  powershell -File Measure-DumpHeap.ps1 -DumpPath x.dmp [-OutFile x.heap.json] [-Top 20]
#>
[CmdletBinding()]
param(
    [string]$DumpPath,
    [string]$FromHeapJson,            # reuse a prior procdump-heap/v1 result instead of walking again
    [string]$FactsPath,               # merge the counts into this event as a `heap` fact (gated on storm category)
    [switch]$Force,                   # merge even if the event is not a storm
    [int]$Top = 20,
    [string]$OutFile
)
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $PSCommandPath
. (Join-Path $ScriptDir '..\src\Common\Common.ps1')
. (Join-Path $ScriptDir '..\src\Common\Packages.ps1')
. (Join-Path $ScriptDir '..\src\Common\DumpId.ps1')

$STORM_CATEGORIES = @('hang-wpf-storm', 'ui-thread-storm-triggered')

function Measure-Heap([string]$dump) {
    $clrmd = Resolve-PackageTool 'clrmd'
    if (-not ($clrmd -and (Test-Path -LiteralPath $clrmd))) { throw 'ClrMD not available (download it on the Packages tab).' }
    if (-not (Test-Path -LiteralPath $dump)) { throw "dump not found: $dump" }
    $tb = Get-DumpBitness $dump
    if ($tb -and $tb -ne $script:HostBits -and $env:RT_BITNESS_REDIR -ne '1') {
        $sub = if ($tb -eq 32) { 'SysWOW64' } else { 'System32' }
        $exe = Join-Path $env:SystemRoot "$sub\WindowsPowerShell\v1.0\powershell.exe"
        $cmd = "`$env:RT_BITNESS_REDIR='1'; & '$PSCommandPath' -DumpPath '$dump' -Top $Top -OutFile '$env:TEMP\rt_heap_redir.json' *> `$null; Get-Content -Raw '$env:TEMP\rt_heap_redir.json'"
        return (& $exe -NoProfile -ExecutionPolicy Bypass -Command $cmd | ConvertFrom-Json)
    }
    Add-Type -Path $clrmd -ErrorAction Stop
    $sw = [Diagnostics.Stopwatch]::StartNew(); $dt = $null
    try {
        $dt = [Microsoft.Diagnostics.Runtime.DataTarget]::LoadCrashDump($dump)
        $clr = $dt.ClrVersions | Select-Object -First 1; if (-not $clr) { throw 'no CLR in dump' }
        $heap = $clr.CreateRuntime().Heap
        $byType = @{}; $total = 0
        foreach ($o in $heap.EnumerateObjects()) { $t = $o.Type; if (-not $t) { continue }; $n = $t.Name; if (-not $n) { continue }; $byType[$n] = [int]$byType[$n] + 1; $total++ }
        $cache = @{}
        function Derives([string]$type, [string]$base) {
            $k = "$type|$base"; if ($cache.ContainsKey($k)) { return $cache[$k] }
            $r = $false; try { $x = $heap.GetTypeByName($type); while ($x) { if ($x.Name -eq $base) { $r = $true; break }; $x = $x.BaseType } } catch {}
            $cache[$k] = $r; $r
        }
        $sum = { param($b) $c = 0; foreach ($k in $byType.Keys) { if (Derives $k $b) { $c += [int]$byType[$k] } }; $c }
        $topTypes = $byType.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $Top | ForEach-Object { [ordered]@{ type = $_.Name; count = [int]$_.Value } }
        [ordered]@{
            schema = 'procdump-heap/v1'; dump = [IO.Path]::GetFileName($dump); measuredAtUtc = (Get-Date).ToUniversalTime().ToString('o'); elapsedSec = [int]$sw.Elapsed.TotalSeconds
            totalObjects = $total; visualObjects = (& $sum 'System.Windows.Media.Visual'); frameworkElements = (& $sum 'System.Windows.FrameworkElement')
            bindingExpressions = [int]$byType['System.Windows.Data.BindingExpression'] + [int]$byType['System.Windows.Data.MultiBindingExpression']
            distinctTypes = @($byType.Keys).Count; topTypes = @($topTypes)
        }
    } finally { if ($dt) { try { $dt.Dispose() } catch {} }; [GC]::Collect(); [GC]::WaitForPendingFinalizers() }
}

# --- get the measurement (walk, or reuse a prior result) ---
if ($FromHeapJson) { $h = Get-Content -LiteralPath $FromHeapJson -Raw | ConvertFrom-Json }
elseif ($DumpPath) { $h = Measure-Heap $DumpPath }
else { throw 'pass -DumpPath (to walk) or -FromHeapJson (to reuse a result).' }

# fact-only one-line summary (numbers only; no "oversized" claim)
$summary = ('{0:N0} FrameworkElement-derived objects, {1:N0} live BindingExpressions, {2:N0} Visual-derived objects.' -f [int]$h.frameworkElements, [int]$h.bindingExpressions, [int]$h.visualObjects)
$heapBlock = [ordered]@{
    schema = 'procdump-heap/v1'; measuredAtUtc = $h.measuredAtUtc; elapsedSec = [int]$h.elapsedSec
    totalObjects = [int]$h.totalObjects; visualObjects = [int]$h.visualObjects; frameworkElements = [int]$h.frameworkElements
    bindingExpressions = [int]$h.bindingExpressions; distinctTypes = [int]$h.distinctTypes; topTypes = @($h.topTypes); summary = $summary
}

# --- merge into the event (gated on storm category) ---
if ($FactsPath) {
    if (-not (Test-Path -LiteralPath $FactsPath)) { throw "facts event not found: $FactsPath" }
    $facts = Get-Content -LiteralPath $FactsPath -Raw | ConvertFrom-Json
    $cat = "$($facts.diagnosis.category)"
    if (($STORM_CATEGORIES -contains $cat) -or $Force) {
        $facts | Add-Member -NotePropertyName heap -NotePropertyValue $heapBlock -Force
        ($facts | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $FactsPath -Encoding UTF8
        Write-Host ("merged heap facts into {0}: {1}" -f [IO.Path]::GetFileName($FactsPath), $summary)
    } else {
        Write-Host ("skipped {0}: category '{1}' is not a storm (use -Force to merge anyway)" -f [IO.Path]::GetFileName($FactsPath), $cat)
    }
}
if ($OutFile) { ($heapBlock | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $OutFile -Encoding UTF8; Write-Host "wrote $OutFile" }
elseif (-not $FactsPath) { $heapBlock | ConvertTo-Json -Depth 6 }
