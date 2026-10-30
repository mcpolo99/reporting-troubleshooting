#Requires -Version 5.1
<#
.SYNOPSIS
  Run every *.Tests.ps1 in this folder and aggregate the result. Exit 0 iff all suites pass.
  Suites use synthetic inputs and no network; the e2e suite GENERATES a real minidump at test time
  (MiniDumpWriteDump on a throwaway process) and asserts the signature is STABLE rather than a fixed value,
  so it stays deterministic. CI entry point.

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
