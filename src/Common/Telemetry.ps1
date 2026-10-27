# Edge telemetry transport (client side). Moves what the analyzer produced toward the centre, with every
# target CONFIGURABLE and defaulting to a LOCAL path - so the whole flow runs and is testable now, before any
# backend exists. Backend integration later is only a config change (local dir -> https URL); no code change.
#
#   events : outbox\*.json  -> EventSink            (local dir  | https .../v1/events)
#   known  : KnownSignaturesSource -> baseline file (local file | https .../v1/known-signatures)
#   dumps  : escalated .dmp -> DumpUploadTarget     (local dir  | https .../v1/dumps)
#
# Config lives in the monitor config.json (telemetry* keys); unset keys fall back to local paths under
# KnownIssues. A per-device send-only key (TelemetryDeviceKey) is sent as X-Device-Key when a target is http.

function Get-TelemetryConfig {
    $cfgPath = Join-Path $env:ProgramData 'ReportingTroubleshooting\Monitor\config.json'
    $cfg = $null; if (Test-Path -LiteralPath $cfgPath) { try { $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json } catch {} }
    $ki = Get-KnownIssuesDir
    function Val($name, $default) { if ($cfg -and $null -ne $cfg.$name -and "$($cfg.$name)" -ne '') { $cfg.$name } else { $default } }
    [ordered]@{
        EventSink      = Val 'TelemetryEventSink'       (Join-Path $ki 'sent')                 # local archive stands in for the ingest API
        KnownSource    = Val 'KnownSignaturesSource'    (Join-Path $ki 'known-signatures.json') # local file stands in for the registry service
        DumpTarget     = Val 'TelemetryDumpTarget'      (Join-Path $ki 'upload')               # local dir stands in for the silo
        DumpDir        = Val 'DumpDir'                  'C:\dumps'                             # where captured dumps live, to upload an escalated one
        BaselinePath   = Val 'BaselinePath'             (Join-Path $ki 'known-issues.baseline.json')
        DeviceKey      = Val 'TelemetryDeviceKey'       $null
    }
}
function Test-IsHttp([string]$t) { return ($t -and $t -match '^https?://') }

# Drain the outbox to the event sink. Durable at-least-once: an event stays in the outbox until it is accepted,
# then moves to outbox\sent\ (archived, not deleted). Returns @{ Sent; Failed; Skipped }.
function Send-OutboxEvents {
    param([string]$Dir, $Config)
    if (-not $Config) { $Config = Get-TelemetryConfig }
    if (-not $Dir) { $Dir = Get-KnownIssuesDir }
    $outbox = Join-Path $Dir 'outbox'
    if (-not (Test-Path -LiteralPath $outbox)) { return @{ Sent = 0; Failed = 0; Skipped = 0 } }
    $sentDir = Join-Path $outbox 'sent'
    if (-not (Test-Path -LiteralPath $sentDir)) { New-Item -ItemType Directory -Path $sentDir -Force | Out-Null }
    $http = Test-IsHttp $Config.EventSink
    if (-not $http -and -not (Test-Path -LiteralPath $Config.EventSink)) { New-Item -ItemType Directory -Path $Config.EventSink -Force | Out-Null }

    $sent = 0; $failed = 0; $dumps = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $outbox -Filter *.json -File -ErrorAction SilentlyContinue)) {
        try {
            $evt = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
            # A NEW signature needs the full dump too: upload it (if still present locally) and stamp the key
            # into the event before forwarding. Known recurrences (escalateDump=false) send the event only.
            if ($evt.escalateDump -and -not $evt.ids.dumpObjectKey -and $evt.dump.file) {
                $dumpPath = Join-Path $Config.DumpDir $evt.dump.file
                if (Test-Path -LiteralPath $dumpPath) {
                    $key = Send-EscalatedDump -DumpPath $dumpPath -Config $Config
                    if ($key) { $evt.ids.dumpObjectKey = $key; $dumps++ }
                }
                $evt | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $f.FullName -Encoding UTF8
            }
            $body = Get-Content -LiteralPath $f.FullName -Raw
            if ($http) {
                $headers = @{}; if ($Config.DeviceKey) { $headers['X-Device-Key'] = $Config.DeviceKey }
                Invoke-RestMethod -Method Post -Uri ($Config.EventSink.TrimEnd('/') + '/v1/events') -Body $body -ContentType 'application/json' -Headers $headers -TimeoutSec 30 | Out-Null
            } else {
                Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $Config.EventSink $f.Name) -Force   # file-drop stand-in
            }
            Move-Item -LiteralPath $f.FullName -Destination (Join-Path $sentDir $f.Name) -Force
            $sent++
        } catch { $failed++ }     # left in the outbox; retried next run
    }
    @{ Sent = $sent; Failed = $failed; Dumps = $dumps; Skipped = 0 }
}

# Pull the central known-signature list into the local baseline the triage consults (so a signature already
# analysed elsewhere is recognised here). Local-file source = already local, copied into place. Returns count.
function Sync-KnownSignatures {
    param($Config)
    if (-not $Config) { $Config = Get-TelemetryConfig }
    try {
        if (Test-IsHttp $Config.KnownSource) {
            $headers = @{}; if ($Config.DeviceKey) { $headers['X-Device-Key'] = $Config.DeviceKey }
            $data = Invoke-RestMethod -Method Get -Uri ($Config.KnownSource.TrimEnd('/') + '/v1/known-signatures') -Headers $headers -TimeoutSec 30
            ($data | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Config.BaselinePath -Encoding UTF8
        } elseif (Test-Path -LiteralPath $Config.KnownSource) {
            if ($Config.KnownSource -ne $Config.BaselinePath) { Copy-Item -LiteralPath $Config.KnownSource -Destination $Config.BaselinePath -Force }
        } else { return 0 }
        $b = Get-Content -LiteralPath $Config.BaselinePath -Raw | ConvertFrom-Json
        $ids = if ($b.issues) { $b.issues.PSObject.Properties.Name } elseif ($b -is [array]) { $b } else { @() }
        return @($ids).Count
    } catch { return -1 }       # -1 = sync failed (keep the existing baseline)
}

# Send an escalated dump to the dump target (silo stand-in locally). Returns the object key/path, or $null.
function Send-EscalatedDump {
    param([Parameter(Mandatory)][string]$DumpPath, $Config)
    if (-not $Config) { $Config = Get-TelemetryConfig }
    if (-not (Test-Path -LiteralPath $DumpPath)) { return $null }
    $name = [IO.Path]::GetFileName($DumpPath)
    try {
        if (Test-IsHttp $Config.DumpTarget) {
            $headers = @{ 'X-Dump-Name' = $name }; if ($Config.DeviceKey) { $headers['X-Device-Key'] = $Config.DeviceKey }
            Invoke-RestMethod -Method Post -Uri ($Config.DumpTarget.TrimEnd('/') + '/v1/dumps') -InFile $DumpPath -Headers $headers -TimeoutSec 600 | Out-Null
            return $name
        } else {
            if (-not (Test-Path -LiteralPath $Config.DumpTarget)) { New-Item -ItemType Directory -Path $Config.DumpTarget -Force | Out-Null }
            Copy-Item -LiteralPath $DumpPath -Destination (Join-Path $Config.DumpTarget $name) -Force
            return (Join-Path $Config.DumpTarget $name)
        }
    } catch { return $null }
}
