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
Check 'DumpType = Full'        ($d.DumpType -eq 'Full')
Check 'OnException on'         ($d.OnException)
Check 'ExceptionLevel blank'   ($d.ExceptionLevel -eq '')
Check 'OnHang on'              ($d.OnHang)
Check 'WaitForProcess on'      ($d.WaitForProcess)
Check 'DumpsPerSession = 1'    ($d.DumpsPerSession -eq 1)

Write-Host 'first-chance level (-e 1) is detected'
$f = ConvertFrom-ProcDumpArgs '-accepteula -ma -e 1 -h -n 3 -w'
Check 'ExceptionLevel = 1'     ($f.ExceptionLevel -eq '1')
Check 'OnException on'         ($f.OnException)
Check 'DumpsPerSession = 3'    ($f.DumpsPerSession -eq 3)

Write-Host 'build from toggles always starts with -accepteula'
$s = ConvertTo-ProcDumpArgs ([ordered]@{ DumpType='Full'; OnException=$true; ExceptionLevel=''; OnHang=$true; WaitForProcess=$true; DumpsPerSession=1 })
Check 'builds the shipped default' ($s -eq '-accepteula -ma -e -h -n 1 -w')
Check 'MiniPlus builds -mp'         ((ConvertTo-ProcDumpArgs ([ordered]@{ DumpType='MiniPlus'; DumpsPerSession=1 })) -match '(^|\s)-mp(\s|$)')
Check 'Mini builds neither -ma/-mp' (-not ((ConvertTo-ProcDumpArgs ([ordered]@{ DumpType='Mini'; DumpsPerSession=1 })) -match '(^|\s)-m[ap](\s|$)'))
Check 'parse -mp -> MiniPlus'       ((ConvertFrom-ProcDumpArgs '-accepteula -mp -e -n 1 -w').DumpType -eq 'MiniPlus')
Check 'parse neither -> Mini'       ((ConvertFrom-ProcDumpArgs '-accepteula -e -n 1 -w').DumpType -eq 'Mini')
Check 'accepteula always present'  ((ConvertTo-ProcDumpArgs ([ordered]@{})) -match '(^|\s)-accepteula(\s|$)')
Check 'on-exception + blank -> -e'  ((ConvertTo-ProcDumpArgs ([ordered]@{ OnException=$true; DumpsPerSession=1 })) -match '(^|\s)-e(\s|$)')
Check 'on-exception + 1 -> -e 1'    ((ConvertTo-ProcDumpArgs ([ordered]@{ OnException=$true; ExceptionLevel='1'; DumpsPerSession=1 })) -match '(^|\s)-e 1(\s|$)')
Check 'no on-exception -> no -e'    (-not ((ConvertTo-ProcDumpArgs ([ordered]@{ OnHang=$true; DumpsPerSession=1 })) -match '(^|\s)-e(\s|$)'))
Check 'level ignored without -e'    (-not ((ConvertTo-ProcDumpArgs ([ordered]@{ ExceptionLevel='1'; DumpsPerSession=1 })) -match '(^|\s)-e'))
Check 'n floored to 1'             ((ConvertTo-ProcDumpArgs ([ordered]@{ DumpsPerSession=0 })) -match '-n 1')

Write-Host 'round-trips'
foreach ($a in @('-accepteula -ma -e -h -n 1 -w', '-accepteula -ma -e 1 -h -n 5 -w', '-accepteula -ma -n 1')) {
    Check "round-trip: $a" ((ConvertTo-ProcDumpArgs (ConvertFrom-ProcDumpArgs $a)) -eq (ConvertTo-ProcDumpArgs (ConvertFrom-ProcDumpArgs (ConvertTo-ProcDumpArgs (ConvertFrom-ProcDumpArgs $a)))))
}

Write-Host ''
Write-Host ("{0}/{1} passed" -f ($script:count - $script:fail), $script:count) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 } else { exit 0 }
