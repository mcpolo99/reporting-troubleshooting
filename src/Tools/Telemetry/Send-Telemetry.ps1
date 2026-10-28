#Requires -Version 5.1
<#
.SYNOPSIS
  Push pending telemetry to the centre: sync the known-signature baseline, then drain the event outbox.

  Runs on the edge (invoke from the monitor or a light scheduled task). Every target is configurable and
  defaults to a LOCAL path, so this works end-to-end before any backend exists - see Common\Telemetry.ps1.
  Durable: an event stays in the outbox until accepted, so nothing is lost across reboots/offline periods.

.USAGE
  powershell -NoProfile -ExecutionPolicy Bypass -File Send-Telemetry.ps1 [-Dir <KnownIssues dir>] [-Quiet]
#>
[CmdletBinding()]
param([string]$Dir, [switch]$Quiet)

$ScriptDir = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$CommonDir = $null; $p = $ScriptDir
for ($i = 0; $i -lt 6 -and -not $CommonDir; $i++) {
    foreach ($c in @((Join-Path $p 'Common'), (Join-Path $p 'Scripts\Common'))) {
        if (Test-Path (Join-Path $c 'Common.ps1')) { $CommonDir = $c; break }
    }
    $parent = Split-Path $p -Parent; if (-not $parent -or $parent -eq $p) { break }; $p = $parent
}
if (-not $CommonDir) { throw "Common\ not found from $ScriptDir upward." }
. (Join-Path $CommonDir 'Common.ps1')
. (Join-Path $CommonDir 'DumpId.ps1')       # Get-KnownIssuesDir
. (Join-Path $CommonDir 'Telemetry.ps1')

function Say($m) { if (-not $Quiet) { Write-Host $m } }
if (-not $Dir) { $Dir = Get-KnownIssuesDir }
$cfg = Get-TelemetryConfig

Say ("known-signatures <- {0}" -f $cfg.KnownSource)
$k = Sync-KnownSignatures -Config $cfg
Say $(if ($k -ge 0) { "  baseline now lists $k signature(s)" } else { '  sync failed - keeping existing baseline' })

Say ("events -> {0}" -f $cfg.EventSink)
$r = Send-OutboxEvents -Dir $Dir -Config $cfg
Say ("  sent {0}, uploaded {1} dump(s) on server grant, failed {2} (failed stay in the outbox for the next run)" -f $r.Sent, $r.Dumps, $r.Failed)

if ($r.Failed -gt 0) { exit 1 }
