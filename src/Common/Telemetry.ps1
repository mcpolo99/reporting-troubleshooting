# Edge telemetry transport (client side). Moves what the analyzer produced toward the centre.
#
#   events : outbox\*.json  -> EventSink            (local dir  | https .../v1/events)
#   known  : KnownSource    -> baseline file        (local file | https .../v1/known-signatures)
#   dumps  : granted .dmp   -> DumpTarget           (local dir  | https .../v1/dumps, with the grant)
#
# Over http the dump upload is grant-gated: POST /v1/events returns a one-time uploadGrant on its 202 when
# the backend wants this capture's dump (new/first-seen signature or an operator collect flag); the device
# then POSTs the dump with X-Upload-Grant. The device never mints the grant and never holds the admin key.
# In local/offline mode there is no server to grant, so the dump is dropped into the local silo dir for a
# new signature (escalateDump), as before.
#
# The ingest/registry/silo endpoints and the send-only device key are NOT in config.json or the UI: they are
# baked into the build as one encoded blob (Get-TelemetryEndpoints), so the URL/key are not clear text and do
# not grep out of the files or repo. It is still only a public send-only ingest key - encoding just stops
# trivial extraction. Only operational toggles stay in config: TelemetryEnabled / TelemetrySeconds, plus the
# machine's own DumpDir and local BaselinePath. If the blob is ever emptied, the endpoints fall back to local
# files under KnownIssues, so the flow still runs offline.

# The endpoint set is an encoded blob (gzip+Base64 of {"e":<events>,"k":<known>,"d":<dumps>,"key":<deviceKey>})
# that SHIPS WITH THE BUILD: it is committed here and deploys with every update, so machines never need a
# manual key step. The key is only a public send-only ingest key; encoding keeps the URL/key out of clear text
# and out of grep - obfuscation, not secrecy. Regenerate with scripts\New-TelemetryBlob.ps1 (prints the blob).
$script:TelemetryBlob = 'H4sIAAAAAAAEAI2NUQqDMBAF77LfRaPZZKOXKZvkhYJKpOZHSu9ee4L2c2CYeVGmmR6t7cfc9w0rNrTn2e11rYfGLtWNboQ/nAXnZZW23INYEQVr4TyZyfvkRh9THHVAuMCWaJldZqcmIQhgMZTCkoWNyfqN/Ry+P6EHNdK6AAAA'
# Optional per-machine OVERRIDE: a local untracked telemetry.blob (same format) takes precedence over the
# shipped blob - e.g. to point a test machine at a different backend. Absent -> the shipped blob is used.
$script:TelemetryBlobFile = Join-Path $env:ProgramData 'ReportingTroubleshooting\Monitor\telemetry.blob'

# Decode the blob into @{EventSink;KnownSource;DumpTarget;DeviceKey}. A local override file wins; otherwise the
# shipped blob. Any value absent/blank -> $null, which Get-TelemetryConfig turns into the local-file fallback.
# Never throws: a missing/bad/empty blob = local mode.
function Get-TelemetryEndpoints {
    $empty = @{ EventSink = $null; KnownSource = $null; DumpTarget = $null; DeviceKey = $null }
    $blob = $null
    if (Test-Path -LiteralPath $script:TelemetryBlobFile) {
        try { $blob = (Get-Content -LiteralPath $script:TelemetryBlobFile -Raw).Trim() } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($blob)) { $blob = $script:TelemetryBlob }
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
            if ($http) {
                # 1) Post the event. The backend decides on its 202 whether this capture's dump is wanted and,
                #    if so, returns a one-time uploadGrant { token, maxBytes, expiresAt } in the response body.
                #    The event's own eventId is the Idempotency-Key (contract 3) so a retry of the same file
                #    is deduped server-side rather than double-stored.
                $body = Get-Content -LiteralPath $f.FullName -Raw
                $evt = $null; try { $evt = $body | ConvertFrom-Json } catch {}
                $idem = if ($evt -and $evt.ids -and $evt.ids.eventId) { "$($evt.ids.eventId)" } else { [IO.Path]::GetFileNameWithoutExtension($f.Name) }
                $resp = Invoke-RestMethod -Method Post -Uri ($Config.EventSink.TrimEnd('/') + '/v1/events') -Body $body -ContentType 'application/json' -Headers (Get-AuthHeaders $Config @{ 'Idempotency-Key' = $idem }) -TimeoutSec 30
                # 2) Grant issued + dump still on disk + within maxBytes -> upload it under the grant.
                $dumpFile = if ($evt -and $evt.dump) { $evt.dump.file } else { $null }
                if ($dumpFile) {
                    $dumpPath = Join-Path $Config.DumpDir $dumpFile
                    if (Test-Path -LiteralPath $dumpPath) {
                        $grant = Resolve-UploadGrant -Response $resp -DumpBytes (Get-Item -LiteralPath $dumpPath).Length
                        if ($grant.Ok -and (Send-EscalatedDump -DumpPath $dumpPath -Config $Config -Grant $grant.Token)) { $dumps++ }
                    }
                }
            } else {
                # Local/offline stand-in: no server to grant, so a NEW signature (escalateDump) drops its dump
                # into the local silo dir and stamps the key into the event before the file-drop.
                $evt = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
                if ($evt.escalateDump -and -not $evt.ids.dumpObjectKey -and $evt.dump.file) {
                    $dumpPath = Join-Path $Config.DumpDir $evt.dump.file
                    if (Test-Path -LiteralPath $dumpPath) {
                        $key = Send-EscalatedDump -DumpPath $dumpPath -Config $Config
                        if ($key) { $evt.ids.dumpObjectKey = $key; $dumps++ }
                    }
                    $evt | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $f.FullName -Encoding UTF8
                }
                Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $Config.EventSink $f.Name) -Force   # file-drop stand-in
            }
            Move-Item -LiteralPath $f.FullName -Destination (Join-Path $sentDir $f.Name) -Force
            $sent++
        } catch { $failed++ }     # left in the outbox; retried next run
    }
    @{ Sent = $sent; Failed = $failed; Dumps = $dumps; Skipped = 0 }
}

# Decide, from the /v1/events response, whether to upload this capture's dump. Ok only when the server issued
# a grant token and the dump fits any maxBytes the grant sets. Returns @{ Ok; Token; Reason }.
function Resolve-UploadGrant {
    param($Response, [long]$DumpBytes = 0)
    $g = if ($Response) { $Response.uploadGrant } else { $null }
    if (-not $g -or [string]::IsNullOrWhiteSpace("$($g.token)")) { return @{ Ok = $false; Token = $null; Reason = 'no-grant' } }
    $max = 0L; if ($g.maxBytes) { [void][long]::TryParse("$($g.maxBytes)", [ref]$max) }
    if ($max -gt 0 -and $DumpBytes -gt $max) { return @{ Ok = $false; Token = "$($g.token)"; Reason = 'too-large' } }
    return @{ Ok = $true; Token = "$($g.token)"; Reason = 'ok' }
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

# Send a granted dump to the dump target (silo stand-in locally). Over http the one-time grant from the
# /v1/events 202 goes in X-Upload-Grant (fleet key only, no admin key). Returns the object key/path, or $null.
function Send-EscalatedDump {
    param([Parameter(Mandatory)][string]$DumpPath, $Config, [string]$Grant)
    if (-not $Config) { $Config = Get-TelemetryConfig }
    if (-not (Test-Path -LiteralPath $DumpPath)) { return $null }
    $name = [IO.Path]::GetFileName($DumpPath)
    try {
        if (Test-IsHttp $Config.DumpTarget) {
            $extra = @{ 'X-Dump-Name' = $name }
            if ($Grant) { $extra['X-Upload-Grant'] = $Grant }
            $headers = Get-AuthHeaders $Config $extra
            $resp = Invoke-RestMethod -Method Post -Uri ($Config.DumpTarget.TrimEnd('/') + '/v1/dumps') -InFile $DumpPath -ContentType 'application/octet-stream' -Headers $headers -TimeoutSec 600
            if ($resp -and $resp.dumpObjectKey) { return "$($resp.dumpObjectKey)" } else { return $name }   # contract 5b: 201 { dumpObjectKey }
        } else {
            if (-not (Test-Path -LiteralPath $Config.DumpTarget)) { New-Item -ItemType Directory -Path $Config.DumpTarget -Force | Out-Null }
            Copy-Item -LiteralPath $DumpPath -Destination (Join-Path $Config.DumpTarget $name) -Force
            return (Join-Path $Config.DumpTarget $name)
        }
    } catch { return $null }
}
