#Requires -Version 5.1
<#
.SYNOPSIS
  CENTRAL (not edge) Level-2 heap enrichment for an escalated hang dump.

  The edge emitter says a hang is a WPF storm and how deep; it cannot say HOW MANY elements/bindings (that
  needs a full managed-heap walk, far too heavy for a plant PC). This runs on the uploaded dump at the centre
  and produces the NUMERIC proof: how many WPF Visual / FrameworkElement objects, how many live bindings, and
  the dominant types. FACTS ONLY - the "oversized UI" conclusion stays the analyst's; this just counts.

  Output: a heap-enrichment JSON (keyed by the dump file; the caller joins it to the event by signatureId).

.USAGE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Measure-DumpHeap.ps1 -DumpPath <x.dmp> [-Top 20] [-OutFile <x.heap.json>]
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DumpPath,
    [int]$Top = 20,
    [string]$OutFile
)
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $PSCommandPath
. (Join-Path $ScriptDir '..\src\Common\Common.ps1')
. (Join-Path $ScriptDir '..\src\Common\Packages.ps1')
. (Join-Path $ScriptDir '..\src\Common\DumpId.ps1')

$clrmd = Resolve-PackageTool 'clrmd'
if (-not ($clrmd -and (Test-Path -LiteralPath $clrmd))) { throw 'ClrMD not available (download it on the Packages tab).' }
if (-not (Test-Path -LiteralPath $DumpPath)) { throw "dump not found: $DumpPath" }

# match host bitness to the dump (ClrMD loads the DAC as native code)
$tb = Get-DumpBitness $DumpPath
if ($tb -and $tb -ne $script:HostBits -and $env:RT_BITNESS_REDIR -ne '1') {
    $cmd = "& '$PSCommandPath' -DumpPath '$DumpPath' -Top $Top" + $(if ($OutFile) { " -OutFile '$OutFile'" } else { '' })
    $sub = if ($tb -eq 32) { 'SysWOW64' } else { 'System32' }
    $exe = Join-Path $env:SystemRoot "$sub\WindowsPowerShell\v1.0\powershell.exe"
    & $exe -NoProfile -ExecutionPolicy Bypass -Command "`$env:RT_BITNESS_REDIR='1'; $cmd"
    return
}

Add-Type -Path $clrmd -ErrorAction Stop
$sw = [Diagnostics.Stopwatch]::StartNew()
$dt = $null
try {
    $dt = [Microsoft.Diagnostics.Runtime.DataTarget]::LoadCrashDump($DumpPath)
    $clr = $dt.ClrVersions | Select-Object -First 1
    if (-not $clr) { throw 'no CLR in dump' }
    $heap = $clr.CreateRuntime().Heap

    $byType = @{}                                   # typeName -> count
    $total = 0
    foreach ($o in $heap.EnumerateObjects()) {
        $t = $o.Type; if (-not $t) { continue }
        $n = $t.Name; if (-not $n) { continue }
        $byType[$n] = [int]$byType[$n] + 1
        $total++
    }

    # which distinct types derive from a given base (walk the BaseType chain once per type, cached)
    $derivesCache = @{}
    function Test-Derives([string]$typeName, [string]$baseName) {
        $key = "$typeName|$baseName"
        if ($derivesCache.ContainsKey($key)) { return $derivesCache[$key] }
        $res = $false
        try {
            $t = $heap.GetTypeByName($typeName)
            while ($t) { if ($t.Name -eq $baseName) { $res = $true; break }; $t = $t.BaseType }
        } catch { $res = $false }
        $derivesCache[$key] = $res; $res
    }
    $sumDerived = {
        param($base)
        $c = 0; foreach ($k in $byType.Keys) { if (Test-Derives $k $base) { $c += [int]$byType[$k] } }; $c
    }

    $visual = & $sumDerived 'System.Windows.Media.Visual'
    $fe = & $sumDerived 'System.Windows.FrameworkElement'
    $bindings = [int]$byType['System.Windows.Data.BindingExpression'] + [int]$byType['System.Windows.Data.MultiBindingExpression']
    $topTypes = $byType.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $Top |
        ForEach-Object { [ordered]@{ type = $_.Name; count = [int]$_.Value } }

    $out = [ordered]@{
        schema          = 'procdump-heap/v1'
        dump            = [IO.Path]::GetFileName($DumpPath)
        measuredAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
        elapsedSec      = [int]$sw.Elapsed.TotalSeconds
        totalObjects    = $total
        visualObjects   = $visual                   # System.Windows.Media.Visual-derived (the UI tree)
        frameworkElements = $fe                      # System.Windows.FrameworkElement-derived
        bindingExpressions = $bindings
        distinctTypes   = @($byType.Keys).Count
        topTypes        = @($topTypes)
    }
    $json = $out | ConvertTo-Json -Depth 6
    if ($OutFile) { Set-Content -LiteralPath $OutFile -Value $json -Encoding UTF8; Write-Host "wrote $OutFile" }
    else { $json }
} finally {
    if ($dt) { try { $dt.Dispose() } catch {} }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
}
