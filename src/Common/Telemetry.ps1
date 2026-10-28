# Edge telemetry transport (client side). Moves what the analyzer produced toward the centre.
#
#   events : outbox\*.json  -> EventSink            (local dir  | https .../v1/events)
#   known  : KnownSource    -> baseline file        (local file | https .../v1/known-signatures)
#   dumps  : escalated .dmp -> DumpTarget           (local dir  | https .../v1/dumps)
#
# The ingest/registry/silo endpoints and the send-only device key are NOT in config.json or the UI: they are
# baked into the build as one encoded blob (Get-TelemetryEndpoints), so the URL/key are not clear text and do
# not grep out of the files or repo. It is still only a public send-only ingest key - encoding just stops
# trivial extraction. Only operational toggles stay in config: TelemetryEnabled / TelemetrySeconds, plus the
# machine's own DumpDir and local BaselinePath. Until a real blob is baked, the endpoints are blank and the
# transport runs in local-file mode (under KnownIssues), so the whole flow is testable before any backend.

# The endpoint set is an encoded blob (gzip+Base64 of {"e":<events>,"k":<known>,"d":<dumps>,"key":<deviceKey>}).
# It is NEVER committed: the real blob lives only in a local, untracked file placed on each machine out-of-band
# (the monitor data dir, see below). This source constant stays EMPTY so the public repo carries no key; empty
# and no local file = local-file mode. Generate the local blob with scripts\New-TelemetryBlob.ps1 -Save.
$script:TelemetryBlob = ''
$script:TelemetryBlobFile = Join-Path $env:ProgramData 'ReportingTroubleshooting\Monitor\telemetry.blob'

# Decode the blob into @{EventSink;KnownSource;DumpTarget;DeviceKey}. Prefers the local untracked file; falls
# back to the (normally empty) source constant. Any value absent/blank -> $null, which Get-TelemetryConfig
# turns into the local-file fallback. Never throws: a missing/bad/empty blob = local mode.
function Get-TelemetryEndpoints {
    $empty = @{ EventSink = $null; KnownSource = $null; DumpTarget = $null; DeviceKey = $null }
    $blob = $script:TelemetryBlob
    if ([string]::IsNullOrWhiteSpace($blob) -and (Test-Path -LiteralPath $script:TelemetryBlobFile)) {
        try { $blob = (Get-Content -LiteralPath $script:TelemetryBlobFile -Raw).Trim() } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($blob)) { return $empty }
    try {
        $bytes = [Convert]::FromBase64String($blob)
        $in  = New-Object System.IO.MemoryStream (,$bytes)
        $gz  = New-Object System.IO.Compression.GZipStream($in, [System.IO.Compression.CompressionMode]::Decompress)
        $sr  = New-Object System.IO.StreamReader($gz)
        $json = $sr.ReadToEnd(); $sr.Close()
        $o = $json | ConvertFrom-Json
        function V($x) { if ("$x".Trim()) { "$x".Trim() } else { $null } }
        return @{ EventSink = V $o.e; KnownSource = V $o.k; DumpTarget = V $o.d; DeviceKey = V $o.key }
    } catch { return $empty }
}

function Get-TelemetryConfig {
    $cfgPath = Join-Path $env:ProgramData 'ReportingTroubleshooting\Monitor\config.json'
    $cfg = $null; if (Test-Path -LiteralPath $cfgPath) { try { $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json } catch {} }
    $ki = Get-KnownIssuesDir
    $ep = Get-TelemetryEndpoints
    function Val($name, $default) { if ($cfg -and $null -ne $cfg.$name -and "$($cfg.$name)" -ne '') { $cfg.$name } else { $default } }
    [ordered]@{
        EventSink      = if ($ep.EventSink)   { $ep.EventSink }   else { Join-Path $ki 'sent' }                   # baked URL | local archive (ingest API stand-in)
        KnownSource    = if ($ep.KnownSource) { $ep.KnownSource } else { Join-Path $ki 'known-signatures.json' }  # baked URL | local file (registry stand-in)
        DumpTarget     = if ($ep.DumpTarget)  { $ep.DumpTarget }  else { Join-Path $ki 'upload' }                 # baked URL | local dir (silo stand-in)
        DumpDir        = Val 'DumpDir'        'C:\dumps'                                                           # machine's own dump folder (config)
        BaselinePath   = Val 'BaselinePath'   (Join-Path $ki 'known-issues.baseline.json')                        # local baseline (config)
        DeviceKey      = $ep.DeviceKey                                                                            # baked send-only key, sent as Authorization: Bearer when http
    }
}
function Test-IsHttp([string]$t) { return ($t -and $t -match '^https?://') }

# The fleet key authenticates as a bearer token: Authorization: Bearer <key>. Returns the auth headers merged
# with any extras, or just the extras in local-file mode (no key).
function Get-AuthHeaders($Config, [hashtable]$Extra) {
    $h = @{}; if ($Extra) { foreach ($k in $Extra.Keys) { $h[$k] = $Extra[$k] } }
    if ($Config.DeviceKey) { $h['Authorization'] = "Bearer $($Config.DeviceKey)" }
    return $h
}

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
                $headers = Get-AuthHeaders $Config
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
            $headers = Get-AuthHeaders $Config
            $data = Invoke-RestMethod -Method Get -Uri ($Config.KnownSource.TrimEnd('/') + '/v1/known-signatures') -Headers $headers -TimeoutSec 30
            # The registry returns { signatures: [ { signature, status, ... } ], nextCursor }. The triage
            # baseline only needs the id set, so store the ids as a flat array (the shape Test-BaselineKnown reads).
            $ids = @($data.signatures | ForEach-Object { $_.signature } | Where-Object { $_ })
            (ConvertTo-Json -InputObject $ids) | Set-Content -LiteralPath $Config.BaselinePath -Encoding UTF8
        } elseif (Test-Path -LiteralPath $Config.KnownSource) {
            if ($Config.KnownSource -ne $Config.BaselinePath) { Copy-Item -LiteralPath $Config.KnownSource -Destination $Config.BaselinePath -Force }
        } else { return 0 }
        $b = Get-Content -LiteralPath $Config.BaselinePath -Raw | ConvertFrom-Json
        $ids = if ($null -eq $b) { @() } elseif ($b.issues) { $b.issues.PSObject.Properties.Name } elseif ($b -is [array]) { $b } else { @($b) }
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
            $headers = Get-AuthHeaders $Config @{ 'X-Dump-Name' = $name }
            Invoke-RestMethod -Method Post -Uri ($Config.DumpTarget.TrimEnd('/') + '/v1/dumps') -InFile $DumpPath -Headers $headers -TimeoutSec 600 | Out-Null
            return $name
        } else {
            if (-not (Test-Path -LiteralPath $Config.DumpTarget)) { New-Item -ItemType Directory -Path $Config.DumpTarget -Force | Out-Null }
            Copy-Item -LiteralPath $DumpPath -Destination (Join-Path $Config.DumpTarget $name) -Force
            return (Join-Path $Config.DumpTarget $name)
        }
    } catch { return $null }
}
