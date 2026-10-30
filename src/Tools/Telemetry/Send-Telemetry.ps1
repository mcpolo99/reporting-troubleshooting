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
. (Join-Path $CommonDir 'Logging.ps1')
. (Join-Path $CommonDir 'DumpId.ps1')       # Get-KnownIssuesDir
. (Join-Path $CommonDir 'Telemetry.ps1')

# Every flush is recorded in the monitor's Logs dir (Logs\Telemetry_<datetime>.log), so a detached, silent
# run still leaves a trail of what was attempted and whether it sent / failed. -Quiet only suppresses the
# console echo; the file log is always written.
$LogDir = Join-Path $env:ProgramData 'ReportingTroubleshooting\Monitor\Logs'
$AppName = 'Telemetry'
$script:LogPrefix = 'Telemetry'
$script:EchoLog = -not $Quiet
$script:LogMaxMB = 5
$script:LogCount = 0
New-LogFile
try { Remove-OldLogs 10 } catch {}

# Single instance. The monitor launches this forwarder on a timer; a slow flush (a big upload, or a long
# offline retry sweep) must never let the next tick start a SECOND forwarder racing on the same outbox/dumps.
# A machine-wide mutex makes the flush exclusive: if another forwarder already holds it, this one exits at once.
$FlushMutex = New-Object System.Threading.Mutex($false, 'Global\RTTelemetryFlush')
$FlushOwned = $false
try { $FlushOwned = $FlushMutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $FlushOwned = $true }
if (-not $FlushOwned) { Write-Log 'Another telemetry flush is already running - exiting (single instance).' 'WARN'; $FlushMutex.Dispose(); exit 0 }

if (-not $Dir) { $Dir = Get-KnownIssuesDir }
$cfg = Get-TelemetryConfig
$mode = if (Test-IsHttp $cfg.EventSink) { 'http' } else { 'local' }
Write-Log "flush start (mode=$mode, events -> $($cfg.EventSink))"

try {
    $k = Sync-KnownSignatures -Config $cfg
    if ($k -ge 0) { Write-Log "known-signatures: baseline now lists $k signature(s)" }
    else { Write-Log 'known-signatures: sync failed - keeping existing baseline' 'WARN' }

    # Device profile: pull it from the backend when reachable; otherwise (local mode, or a failed http sync)
    # BUILD it locally from the registry + baseline so offline dedup still holds - one dump per signature, not
    # one per recurrence - instead of leaving the flush with no profile at all.
    $p = Sync-DeviceProfile -Config $cfg
    if ($p -gt 0) { Write-Log "device-profile: $p signature(s) already collected for this device (from backend)" }
    elseif ($p -eq 0) { $lp = Build-LocalDeviceProfile -Config $cfg; Write-Log "device-profile: local/offline - built $lp entry(ies) from registry + baseline" }
    else { $lp = Build-LocalDeviceProfile -Config $cfg; Write-Log "device-profile: backend sync failed - rebuilt $lp entry(ies) locally" 'WARN' }

    $r = Send-OutboxEvents -Dir $Dir -Config $cfg
    $level = if ($r.FailedUploads -gt 0) { 'ERROR' } elseif ($r.Failed -gt 0) { 'WARN' } else { 'INFO' }
    Write-Log ('events: sent {0}, uploaded {1} dump(s) on grant, {2} pending retry (left in outbox), {3} moved to failed-uploads' -f $r.Sent, $r.Dumps, $r.Failed, $r.FailedUploads) $level
    Write-Log 'flush done'
    if ($r.Failed -gt 0 -or $r.FailedUploads -gt 0) { exit 1 }
    exit 0
}
catch {
    Write-Log "flush error: $($_.Exception.Message)" 'ERROR'
    exit 1
}
