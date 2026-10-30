#Requires -Version 5.1
<#
.SYNOPSIS
  End-to-end test over a REAL minidump generated at test time (no committed corpus): spawn a throwaway
  process, MiniDumpWriteDump it, then run the whole edge pipeline on that dump - Get-DumpEvent, and the full
  triage (parse -> stable id -> ledger decision -> report -> gzip-at-rest). Deterministic enough: the dump is
  freshly generated, the id is asserted STABLE across two reads rather than to a fixed value.

  If a minidump cannot be generated on this host (no dbghelp / blocked), the e2e checks are SKIPPED (not
  failed) so the suite stays green on an odd environment.

  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\DumpE2E.Tests.ps1   (exit 0 = pass)
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\Common\DumpId.ps1')
. (Join-Path $PSScriptRoot '..\src\Common\Telemetry.ps1')   # Compress-DumpFile (gzip at rest)

$script:fail = 0; $script:count = 0
function Check([string]$name, [bool]$cond) { $script:count++; if ($cond) { Write-Host "  ok   $name" } else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ } }

# --- generate a real minidump of a throwaway process ---------------------------------------------------------
function New-TestMinidump([string]$Path) {
    Add-Type -Namespace RT -Name Mdump -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dbghelp.dll", SetLastError=true)]
public static extern bool MiniDumpWriteDump(System.IntPtr hProcess, uint pid,
    Microsoft.Win32.SafeHandles.SafeFileHandle hFile, int type,
    System.IntPtr ex, System.IntPtr user, System.IntPtr cb);
'@ -ErrorAction Stop
    $sleeper = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 60')
    try {
        Start-Sleep -Milliseconds 400                        # let it spin up so it is dumpable
        $h = $sleeper.Handle                                 # a child we own -> full-access handle
        $fs = [IO.File]::Create($Path)
        try { $ok = [RT.Mdump]::MiniDumpWriteDump($h, [uint32]$sleeper.Id, $fs.SafeFileHandle, 0x2, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero) }  # 0x2 = WithFullMemory (carries the env block)
        finally { $fs.Dispose() }
        return [bool]$ok -and (Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path).Length -gt 0)
    } finally { try { $sleeper.Kill() } catch {} }
}

$root = Join-Path $env:TEMP ('e2e_{0}' -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
$dumpDir = Join-Path $root 'dumps'; $ki = Join-Path $root 'KnownIssues'
New-Item -ItemType Directory -Force $dumpDir | Out-Null
New-Item -ItemType Directory -Force $ki | Out-Null
try {
    $placeholder = Join-Path $dumpDir ('ProcDump_{0}_powershell_pending_{1:yyyyMMdd_HHmmss}.dmp' -f $env:COMPUTERNAME, (Get-Date))
    $generated = $false
    try { $generated = New-TestMinidump $placeholder } catch { Write-Host "  (minidump generation unavailable: $($_.Exception.Message))" -ForegroundColor Yellow }

    if (-not $generated) {
        Write-Host '  SKIP e2e - could not generate a minidump on this host' -ForegroundColor Yellow
    } else {
        Write-Host 'real minidump generated'
        $magic = [IO.File]::ReadAllBytes($placeholder)[0..3] -join ','
        Check 'file is a minidump (MDMP magic)' ($magic -eq '77,68,77,80')   # 'MDMP'

        Write-Host 'Get-DumpEvent on a real dump'
        $ev = Get-DumpEvent -DumpPath $placeholder
        Check 'event has a signatureId'        ([bool]$ev.signatureId)
        Check 'event has a class'              ([bool]$ev.class)
        Check 'event has deviceId'             ([bool]$ev.deviceId)
        Check 'event has raw bytes + sha256'   (($ev.dump.bytes -gt 0) -and [bool]$ev.dump.sha256)
        $ev2 = Get-DumpEvent -DumpPath $placeholder
        Check 'signatureId is stable'          ($ev.signatureId -eq $ev2.signatureId)

        Write-Host 'full triage pipeline (parse -> id -> ledger -> report -> gzip)'
        $r = Invoke-DumpTriage -DumpPath $placeholder -Dir $ki -IsOnline $false
        Check 'kept (collect or defer)'        ($r.Collect -in 'collect','defer')
        Check 'placeholder consumed'           (-not (Test-Path -LiteralPath $placeholder))
        $gz = @(Get-ChildItem -LiteralPath $dumpDir -Filter *.dmp.gz -File -ErrorAction SilentlyContinue)
        Check 'resting .dmp.gz written'        ($gz.Count -eq 1)
        Check 'final name has a real tag'      ($gz.Count -eq 1 -and $gz[0].Name -notmatch '_pending_')
        $events = @(Get-ChildItem -LiteralPath (Join-Path $ki 'outbox') -Filter *.json -File -ErrorAction SilentlyContinue)
        Check 'one report in the outbox'       ($events.Count -eq 1)
        $led = Read-DeviceLedger $ki
        Check 'ledger holds the signature'     ($led.entries.ContainsKey($r.Id) -and $led.entries[$r.Id].state -eq 'held')
        $sample = "$($led.entries[$r.Id].sample)"
        # Compare resolved paths (the recorded path may be in 8.3 short form; the file is the same).
        $sampleReal = if ($sample -and (Test-Path -LiteralPath $sample)) { (Get-Item -LiteralPath $sample).FullName } else { $null }
        Check 'ledger sample is the .dmp.gz'   ($gz.Count -eq 1 -and $sampleReal -eq $gz[0].FullName)
    }
}
finally { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host ("{0}/{1} passed" -f ($script:count - $script:fail), $script:count) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 } else { exit 0 }
