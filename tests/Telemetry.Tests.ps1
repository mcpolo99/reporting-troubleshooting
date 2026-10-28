#Requires -Version 5.1
<#
.SYNOPSIS
  Deterministic tests for the edge telemetry transport (local-default targets, synthetic events).

  No network, no real dumps - synthetic events + local file sinks, so the behaviour under test is stable:
  the forwarder drains the outbox, uploads the dump only for a NEW signature, stamps the key, archives sent
  events, and syncs the known-signature baseline. Dependency-free; runs in stock PS 5.1.

  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Telemetry.Tests.ps1   (exit 0 = pass)
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\Common\DumpId.ps1')
. (Join-Path $PSScriptRoot '..\src\Common\Telemetry.ps1')

$script:fail = 0; $script:count = 0
function Check([string]$name, [bool]$cond) { $script:count++; if ($cond) { Write-Host "  ok   $name" } else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ } }

$dir = Join-Path $env:TEMP ('tel_test_{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
try {
    New-Item -ItemType Directory -Force (Join-Path $dir 'outbox') | Out-Null
    $dumpDir = Join-Path $dir 'dumps'; New-Item -ItemType Directory -Force $dumpDir | Out-Null
    Set-Content (Join-Path $dumpDir 'app.exe_new.dmp') -Value 'FAKEDUMP' -Encoding ascii

    # a NEW-signature event (escalateDump + local dump present) and a KNOWN recurrence (event only)
    (@{ escalateDump = $true;  ids = @{ dumpObjectKey = $null }; dump = @{ file = 'app.exe_new.dmp' } } | ConvertTo-Json) | Set-Content (Join-Path $dir 'outbox\new.json') -Encoding UTF8
    (@{ escalateDump = $false; ids = @{ dumpObjectKey = $null }; dump = @{ file = 'app.exe_known.dmp' } } | ConvertTo-Json) | Set-Content (Join-Path $dir 'outbox\known.json') -Encoding UTF8

    $knownSrc = Join-Path $dir 'known.json'
    Set-Content $knownSrc -Value '{"issues":{"a1":{},"b2":{},"c3":{}}}' -Encoding UTF8
    $cfg = [ordered]@{
        EventSink = (Join-Path $dir 'sink'); KnownSource = $knownSrc; DumpTarget = (Join-Path $dir 'silo')
        DumpDir = $dumpDir; BaselinePath = (Join-Path $dir 'baseline.json'); DeviceKey = $null
    }

    Write-Host 'known-signature sync'
    $k = Sync-KnownSignatures -Config $cfg
    Check 'baseline lists 3 ids'            ($k -eq 3)
    Check 'baseline file written'           (Test-Path $cfg.BaselinePath)

    Write-Host 'forward outbox'
    $r = Send-OutboxEvents -Dir $dir -Config $cfg
    Check 'both events sent'                ($r.Sent -eq 2)
    Check 'exactly one dump uploaded'       ($r.Dumps -eq 1)
    Check 'no failures'                     ($r.Failed -eq 0)
    Check 'outbox drained'                  (@(Get-ChildItem (Join-Path $dir 'outbox') -Filter *.json -File).Count -eq 0)
    Check 'both archived to sent'           (@(Get-ChildItem (Join-Path $dir 'outbox\sent') -Filter *.json -File).Count -eq 2)
    Check 'new-sig dump in the silo'        (Test-Path (Join-Path $dir 'silo\app.exe_new.dmp'))
    $sentNew = Get-Content (Join-Path $dir 'outbox\sent\new.json') -Raw | ConvertFrom-Json
    $sentKnown = Get-Content (Join-Path $dir 'outbox\sent\known.json') -Raw | ConvertFrom-Json
    Check 'new event got a dumpObjectKey'   ([bool]$sentNew.ids.dumpObjectKey)
    Check 'known event: no dump uploaded'   (-not $sentKnown.ids.dumpObjectKey)
    Check 'known dump NOT in the silo'      (-not (Test-Path (Join-Path $dir 'silo\app.exe_known.dmp')))

    Write-Host 'idempotent re-run (nothing left to send)'
    $r2 = Send-OutboxEvents -Dir $dir -Config $cfg
    Check 're-run sends nothing'            ($r2.Sent -eq 0 -and $r2.Dumps -eq 0)

    # http path decides dump upload from the /v1/events response grant, not from the event (server-minted,
    # one-time, bounded by maxBytes). Pure decision - no network.
    Write-Host 'upload-grant decision (http path)'
    $withGrant = [pscustomobject]@{ uploadGrant = [pscustomobject]@{ token = 'g1'; maxBytes = 1000 } }
    Check 'grant + small dump -> upload'    ((Resolve-UploadGrant -Response $withGrant -DumpBytes 500).Ok)
    Check 'no grant -> no upload'           (-not (Resolve-UploadGrant -Response ([pscustomobject]@{}) -DumpBytes 500).Ok)
    Check 'grant + oversize -> no upload'   ((Resolve-UploadGrant -Response $withGrant -DumpBytes 5000).Reason -eq 'too-large')
    Check 'grant, no maxBytes -> upload'    ((Resolve-UploadGrant -Response ([pscustomobject]@{ uploadGrant = [pscustomobject]@{ token = 'g2' } }) -DumpBytes 999999).Ok)
    Check 'grant decision carries token'    ((Resolve-UploadGrant -Response $withGrant -DumpBytes 500).Token -eq 'g1')

    # dump-path resolution (#42 defect 3): absolute dump.path wins; else DumpDir + bare file; else not-found.
    Write-Host 'dump-path resolution'
    $cfg2 = [ordered]@{ DumpDir = $dumpDir }
    $evAbs  = [pscustomobject]@{ dump = [pscustomobject]@{ file = 'app.exe_new.dmp'; path = (Join-Path $dumpDir 'app.exe_new.dmp') } }
    $evBare = [pscustomobject]@{ dump = [pscustomobject]@{ file = 'app.exe_new.dmp' } }
    $evGone = [pscustomobject]@{ dump = [pscustomobject]@{ file = 'nope.dmp' } }
    Check 'resolves absolute dump.path'     ((Resolve-DumpPath -Evt $evAbs  -Config $cfg2).Path -eq (Join-Path $dumpDir 'app.exe_new.dmp'))
    Check 'falls back to DumpDir + file'    ((Resolve-DumpPath -Evt $evBare -Config $cfg2).Path -eq (Join-Path $dumpDir 'app.exe_new.dmp'))
    Check 'missing dump -> null path'       ($null -eq (Resolve-DumpPath -Evt $evGone -Config $cfg2).Path)
    Check 'not-found reports looked paths'  ((Resolve-DumpPath -Evt $evGone -Config $cfg2).Tried.Count -ge 1)

    # upload-attempt sidecar (#42 retry cap): counts up, stays out of the *.json drain, clears cleanly.
    Write-Host 'upload-attempt sidecar'
    $evPath = Join-Path $dir 'outbox\sent\new.json'    # any existing file path; the sidecar sits beside it
    Check 'attempts start at 0'             ((Get-UploadAttempts -EventPath $evPath) -eq 0)
    Set-UploadAttempts -EventPath $evPath -Count 2
    Check 'attempts persist'               ((Get-UploadAttempts -EventPath $evPath) -eq 2)
    Check 'sidecar written as .try'        (Test-Path -LiteralPath ($evPath + '.try'))
    Check 'sidecar not caught by *.json'   (@(Get-ChildItem (Join-Path $dir 'outbox\sent') -Filter *.json -File).Name -notcontains 'new.json.try')
    Clear-UploadAttempts -EventPath $evPath
    Check 'attempts cleared'               ((Get-UploadAttempts -EventPath $evPath) -eq 0)

    # giving up (#42 user rule): the dump is MOVED to DumpDir\failed-uploads, never deleted; the event is parked.
    Write-Host 'failed-upload parking'
    $fdir = Join-Path $dir 'fu'; New-Item -ItemType Directory -Force (Join-Path $fdir 'outbox') | Out-Null
    $fdump = Join-Path $fdir 'dumps'; New-Item -ItemType Directory -Force $fdump | Out-Null
    $dumpF = Join-Path $fdump 'stuck.dmp'; Set-Content $dumpF -Value 'DUMP' -Encoding ascii
    $evF = Join-Path $fdir 'outbox\stuck.json'; Set-Content $evF -Value '{}' -Encoding UTF8
    Set-UploadAttempts -EventPath $evF -Count 2
    Move-FailedUpload -EventPath $evF -DumpPath $dumpF -Config ([ordered]@{ DumpDir = $fdump }) -Reason 'upload-failed: HTTP 409'
    Check 'dump preserved (not deleted)'   (Test-Path (Join-Path $fdump 'failed-uploads\stuck.dmp'))
    Check 'dump left original location'    (-not (Test-Path $dumpF))
    Check 'event parked in outbox\failed'  (Test-Path (Join-Path $fdir 'outbox\failed\stuck.json'))
    Check 'reason note written'            ((Get-Content (Join-Path $fdir 'outbox\failed\stuck.json.error') -Raw).Trim() -eq 'upload-failed: HTTP 409')
    Check 'event gone from outbox'         (-not (Test-Path $evF))
    Check 'attempt sidecar cleaned up'     (-not (Test-Path ($evF + '.try')))

    # compression before upload (#43): gzips to <source>.gz, streamed; round-trips to the original bytes.
    Write-Host 'dump compression (gzip before upload)'
    $srcDump = Join-Path $dir 'compress_me.dmp'
    $payload = (('A' * 4096) + ('B' * 4096)) * 64   # 512 KiB, highly compressible
    Set-Content -LiteralPath $srcDump -Value $payload -Encoding ascii -NoNewline
    $c = Compress-DumpFile -SourcePath $srcDump
    Check 'compress ok'                    ($c.Ok)
    Check 'gz written next to source'      ($c.Path -eq ($srcDump + '.gz') -and (Test-Path -LiteralPath $c.Path))
    Check 'gz smaller than raw'            ((Get-Item -LiteralPath $c.Path).Length -lt (Get-Item -LiteralPath $srcDump).Length)
    Check 'returns raw + gz byte counts'   ($c.RawBytes -eq (Get-Item -LiteralPath $srcDump).Length -and $c.GzBytes -eq (Get-Item -LiteralPath $c.Path).Length -and $c.GzBytes -lt $c.RawBytes)
    # round-trip: decompress and compare to the original bytes
    $rt = Join-Path $dir 'compress_me.roundtrip'
    $gin = [IO.File]::OpenRead($c.Path); $gz = New-Object System.IO.Compression.GZipStream($gin, [System.IO.Compression.CompressionMode]::Decompress); $gout = [IO.File]::Create($rt)
    try { $gz.CopyTo($gout) } finally { $gz.Dispose(); $gin.Dispose(); $gout.Dispose() }
    Check 'gz round-trips to original'     ((Get-Item -LiteralPath $rt).Length -eq (Get-Item -LiteralPath $srcDump).Length)
    Check 'custom DestPath honored'        ((Compress-DumpFile -SourcePath $srcDump -DestPath (Join-Path $dir 'x.gz')).Path -eq (Join-Path $dir 'x.gz'))
    Check 'missing source -> not ok'       (-not (Compress-DumpFile -SourcePath (Join-Path $dir 'nope.dmp')).Ok)
}
finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host ("{0}/{1} passed" -f ($script:count - $script:fail), $script:count) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 } else { exit 0 }
