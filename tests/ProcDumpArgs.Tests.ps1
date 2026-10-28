#Requires -Version 5.1
<#
.SYNOPSIS
  Deterministic tests for the ProcDump argument toggle model (settings UI <-> ProcDumpArgs string, #53).
  Pure string logic - no GUI, no network. Run: powershell -NoProfile -ExecutionPolicy Bypass -File this.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\Common\Common.ps1')

$script:fail = 0; $script:count = 0
function Check([string]$name, [bool]$cond) { $script:count++; if ($cond) { Write-Host "  ok   $name" } else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ } }

Write-Host 'parse the shipped default'
$d = ConvertFrom-ProcDumpArgs '-accepteula -ma -e -h -n 1 -w'
Check 'FullDump on'            ($d.FullDump)
Check 'OnException on'         ($d.OnException)
Check 'FirstChance off'        (-not $d.FirstChance)
Check 'OnHang on'              ($d.OnHang)
Check 'WaitForProcess on'      ($d.WaitForProcess)
Check 'DumpsPerSession = 1'    ($d.DumpsPerSession -eq 1)

Write-Host 'first-chance (-e 1) is detected'
$f = ConvertFrom-ProcDumpArgs '-accepteula -ma -e 1 -h -n 3 -w'
Check 'FirstChance on'         ($f.FirstChance)
Check 'OnException implied'    ($f.OnException)
Check 'DumpsPerSession = 3'    ($f.DumpsPerSession -eq 3)

Write-Host 'build from toggles always starts with -accepteula'
$s = ConvertTo-ProcDumpArgs ([ordered]@{ FullDump=$true; OnException=$true; FirstChance=$false; OnHang=$true; WaitForProcess=$true; DumpsPerSession=1 })
Check 'builds the shipped default' ($s -eq '-accepteula -ma -e -h -n 1 -w')
Check 'accepteula always present'  ((ConvertTo-ProcDumpArgs ([ordered]@{})) -match '(^|\s)-accepteula(\s|$)')
Check 'first-chance builds -e 1'   ((ConvertTo-ProcDumpArgs ([ordered]@{ FirstChance=$true; DumpsPerSession=1 })) -match '(^|\s)-e 1(\s|$)')
Check 'n floored to 1'             ((ConvertTo-ProcDumpArgs ([ordered]@{ DumpsPerSession=0 })) -match '-n 1')

Write-Host 'round-trips'
foreach ($a in @('-accepteula -ma -e -h -n 1 -w', '-accepteula -ma -e 1 -h -n 5 -w', '-accepteula -ma -n 1')) {
    Check "round-trip: $a" ((ConvertTo-ProcDumpArgs (ConvertFrom-ProcDumpArgs $a)) -eq (ConvertTo-ProcDumpArgs (ConvertFrom-ProcDumpArgs (ConvertTo-ProcDumpArgs (ConvertFrom-ProcDumpArgs $a)))))
}

Write-Host ''
Write-Host ("{0}/{1} passed" -f ($script:count - $script:fail), $script:count) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 } else { exit 0 }
