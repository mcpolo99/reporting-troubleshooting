#Requires -Version 5.1
<#
.SYNOPSIS
  Deterministic tests for the heap enrichment MERGE gating (no real dump, no heap walk).

  Uses -FromHeapJson with a synthetic result so the walk (ClrMD) is not invoked - what is under test is the
  policy: merge the heap counts into the event ONLY for a storm-class diagnosis, else skip, unless -Force.
  The heap WALK itself is exercised functionally on a real dump (not a unit-test surface - a live dump is
  changing data). Dependency-free; runs in stock PS 5.1.

  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Heap.Tests.ps1   (exit 0 = pass)
#>
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot '..\scripts\Measure-DumpHeap.ps1'
$script:fail = 0; $script:count = 0
function Check([string]$name, [bool]$cond) { $script:count++; if ($cond) { Write-Host "  ok   $name" } else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ } }

$dir = Join-Path $env:TEMP ('heap_test_{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
try {
    New-Item -ItemType Directory -Force $dir | Out-Null
    $heap = Join-Path $dir 'h.json'
    (@{ schema = 'procdump-heap/v1'; totalObjects = 7000000; visualObjects = 91913; frameworkElements = 90827; bindingExpressions = 113320; distinctTypes = 25793; topTypes = @(); measuredAtUtc = '2026-10-27T00:00:00Z'; elapsedSec = 1400 } | ConvertTo-Json -Depth 5) | Set-Content $heap -Encoding UTF8
    function New-Event([string]$cat, [string]$path) { (@{ diagnosis = @{ category = $cat }; ids = @{} } | ConvertTo-Json -Depth 5) | Set-Content $path -Encoding UTF8 }
    function HeapOf([string]$path) { (Get-Content $path -Raw | ConvertFrom-Json).heap }

    $storm = Join-Path $dir 'storm.facts.json'; New-Event 'hang-wpf-storm' $storm
    $trig = Join-Path $dir 'trig.facts.json';  New-Event 'ui-thread-storm-triggered' $trig
    $busy = Join-Path $dir 'busy.facts.json';  New-Event 'ui-thread-busy' $busy

    & $script -FromHeapJson $heap -FactsPath $storm | Out-Null
    & $script -FromHeapJson $heap -FactsPath $trig  | Out-Null
    & $script -FromHeapJson $heap -FactsPath $busy  | Out-Null

    Check 'storm event: heap merged'            ([bool](HeapOf $storm))
    Check 'storm event: binding count correct'  ((HeapOf $storm).bindingExpressions -eq 113320)
    Check 'storm event: summary present'        ([bool](HeapOf $storm).summary)
    Check 'storm-triggered event: heap merged'  ([bool](HeapOf $trig))
    Check 'non-storm event: skipped'            (-not (HeapOf $busy))

    & $script -FromHeapJson $heap -FactsPath $busy -Force | Out-Null
    Check 'non-storm with -Force: heap merged'  ([bool](HeapOf $busy))
}
finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host ("{0}/{1} passed" -f ($script:count - $script:fail), $script:count) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 } else { exit 0 }
