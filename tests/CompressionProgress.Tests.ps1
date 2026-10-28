#Requires -Version 5.1
<#
.SYNOPSIS
  Deterministic tests for Get-CompressionProgressLine - the parser behind the Monitor tab's live compression
  indicator (#65). Pure string logic. Run: powershell -NoProfile -ExecutionPolicy Bypass -File this.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\Common\Common.ps1')

$script:fail = 0; $script:count = 0
function Check([string]$name, [bool]$cond) { $script:count++; if ($cond) { Write-Host "  ok   $name" } else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ } }

$pre = '2026-10-28 14:30:05.123 [INFO ] [PID 4242] '

Write-Host 'non-compression line -> null'
Check 'plain log line ignored'   ($null -eq (Get-CompressionProgressLine ($pre + 'flush start (mode=http)')))
Check 'empty -> null'            ($null -eq (Get-CompressionProgressLine ''))

Write-Host 'start line -> 0% and prefix stripped'
$s = Get-CompressionProgressLine ($pre + 'compressing dump.dmp (2,800,000,000 bytes) before upload...')
Check 'start percent 0'          ($s.Percent -eq 0)
Check 'prefix stripped'          ($s.Text -eq 'compressing dump.dmp (2,800,000,000 bytes) before upload...')

Write-Host 'progress line -> parsed percent'
$p = Get-CompressionProgressLine ($pre + 'compressing dump.dmp: 40%')
Check 'percent 40'               ($p.Percent -eq 40)
Check 'text carries percent'     ($p.Text -eq 'compressing dump.dmp: 40%')

Write-Host 'done line -> 100%'
$d = Get-CompressionProgressLine ($pre + 'compressed dump.dmp: 2,800,000,000 -> 570,000,000 bytes (20% of raw)')
Check 'done percent 100'         ($d.Percent -eq 100)
Check 'done text kept'           ($d.Text -match '20% of raw')

Write-Host ''
Write-Host ("{0}/{1} passed" -f ($script:count - $script:fail), $script:count) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 } else { exit 0 }
