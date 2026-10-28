#Requires -Version 5.1
<#
.SYNOPSIS
  Run every *.Tests.ps1 in this folder and aggregate the result. Exit 0 iff all suites pass.
  Each suite is deterministic (synthetic inputs, no real dumps / no network). CI entry point.

  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
#>
$ErrorActionPreference = 'Stop'
$suites = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.Tests.ps1 -File | Sort-Object Name)
$failed = @()
foreach ($s in $suites) {
    Write-Host "`n===== $($s.Name) =====" -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $s.FullName
    if ($LASTEXITCODE -ne 0) { $failed += $s.Name }
}
Write-Host ''
if ($failed.Count) { Write-Host ("FAILED: {0}" -f ($failed -join ', ')) -ForegroundColor Red; exit 1 }
Write-Host ("ALL {0} SUITE(S) PASSED" -f $suites.Count) -ForegroundColor Green; exit 0
