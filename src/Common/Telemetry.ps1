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

# One-line reason from a web error record - the HTTP status when there is a response (e.g. 401 Unauthorized = the
# device has no/invalid fleet key), else the exception message (DNS/TLS/proxy). Lets a swallowed sync failure say
# WHY instead of a bare "sync failed".
function Resolve-HttpError($err, $Config) {
    try {
        $r = $err.Exception.Response
        if ($r -and $r.StatusCode) { return ('HTTP {0} {1}' -f [int]$r.StatusCode, "$($r.StatusCode)") }
    } catch {}
    $noKey = if ($Config -and -not $Config.DeviceKey) { ' (no fleet key configured on this device)' } else { '' }
    return "$($err.Exception.Message)$noKey"
}

# How many flushes we re-attempt a wanted dump before giving up and parking it in failed-uploads (#42). The
# event itself (if accepted) is never re-sent beyond this; only the dump upload is capped.
$script:MaxDumpUploadAttempts = 3

# Telemetry.ps1 is dot-sourced both by Send-Telemetry.ps1 (which loads Logging.ps1) and by callers that do not
# (tests, GUI). Route transport logging through Write-Log when it exists, else no-op, so it never throws and a
# silent flush still leaves a trail in Logs\Telemetry_*.log when run from the forwarder (#42: no diagnostics).
function Write-TelemetryLog {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log $Message $Level }
}

# Per-event dump-upload attempt counter, kept in a sidecar next to the event (<event>.try) so the event BODY
# stays byte-identical across retries (the body is the wire contract; we never mutate it to track state).
# *.try is not *.json, so the outbox drain never mistakes it for an event.
function Get-UploadAttempts { param([string]$EventPath)
    $p = "$EventPath.try"; $n = 0
    if (Test-Path -LiteralPath $p) { [void][int]::TryParse(("$(Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue)").Trim(), [ref]$n) }
    return $n
}
function Set-UploadAttempts { param([string]$EventPath, [int]$Count) try { Set-Content -LiteralPath "$EventPath.try" -Value $Count -Encoding ascii } catch {} }
function Clear-UploadAttempts { param([string]$EventPath) $p = "$EventPath.try"; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } }

# Resolve where the dump for an event actually is. Prefers an absolute path the producer stamped (dump.path),
# then a rooted dump.file, then DumpDir + the bare filename. The event records the RAW .dmp name/path, but the
# triage worker gzips every kept dump at rest (<dump>.dmp -> <dump>.dmp.gz), so for each candidate we also try
# the ".gz" form - raw-first so a not-yet-gzipped dump still resolves. Returns @{ Path; Tried; IsGz }.
# (#42 defect 3: a bare filename + a DumpDir that differs from where the capture landed skipped upload silently.)
function Resolve-DumpPath { param($Evt, $Config)
    $d = if ($Evt) { $Evt.dump } else { $null }
    $bases = @()
    if ($d) {
        if ($d.path) { $bases += "$($d.path)" }
        $file = "$($d.file)"
        if ($file) {
            if ([IO.Path]::IsPathRooted($file)) { $bases += $file }
            if ($Config.DumpDir) { $bases += (Join-Path $Config.DumpDir ([IO.Path]::GetFileName($file))) }
        }
    }
    # Each base expands to [raw, raw.gz]; a base already ending in .gz is tried as-is.
    $tried = @()
    foreach ($b in $bases) { if ($b) { if ($b -match '\.gz$') { $tried += $b } else { $tried += $b; $tried += ($b + '.gz') } } }
    $hit = $null
    foreach ($c in $tried) { if ($c -and (Test-Path -LiteralPath $c)) { $hit = $c; break } }
    return @{ Path = $hit; Tried = @($tried); IsGz = [bool]($hit -and $hit -match '\.gz$') }
}

# Archive an event that is fully handled (sent, and its dump obligation met or n/a): move it to outbox\sent and
# drop the attempt sidecar.
function Move-SentEvent { param([string]$EventPath, [string]$SentDir)
    Move-Item -LiteralPath $EventPath -Destination (Join-Path $SentDir ([IO.Path]::GetFileName($EventPath))) -Force
    Clear-UploadAttempts -EventPath $EventPath
}

# Delete a dump the flush is done with (uploaded OK, or the backend did not want it) + its sidecars. DumpDir is
# staging: the only dumps we retain are the ones that FAILED to upload (in failed-uploads). No-op if $DumpPath is
# blank/missing (e.g. the dump was already deleted, or a recurrence deleted at triage).
function Remove-HandledDump { param([string]$DumpPath)
    if (-not $DumpPath) { return }
    foreach ($f in @($DumpPath) + @('.info.txt', '.versions.txt' | ForEach-Object { $DumpPath -replace '\.dmp$', $_ })) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
}

# Delete a dump and its sidecars, handling BOTH the raw (.dmp) and the kept-at-rest (.dmp.gz) form - the stem
# for sidecars is the path with a trailing .dmp or .dmp.gz stripped. Used after a successful upload (the only
# delete-on-send; the backend now holds the dump). No-op on a blank/missing path.
function Remove-DumpArtifacts { param([string]$DumpPath)
    if (-not $DumpPath) { return }
    $stem = $DumpPath -replace '\.dmp(\.gz)?$', ''
    foreach ($f in @($DumpPath) + @('.info.txt', '.versions.txt' | ForEach-Object { $stem + $_ })) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
}

# Terminal state for a wanted dump we could not upload (retries exhausted, or it can never fit the grant). We
# NEVER delete it (#42): the dump is MOVED to DumpDir\failed-uploads (preserved for a manual retry) and the event
# to outbox\failed with a .error note. Both subdirs are non-recursive-safe (the drain only scans the top level).
function Move-FailedUpload { param([string]$EventPath, [string]$DumpPath, $Config, [string]$Reason)
    try {
        if ($DumpPath -and (Test-Path -LiteralPath $DumpPath)) {
            $fuDump = Join-Path $Config.DumpDir 'failed-uploads'
            if (-not (Test-Path -LiteralPath $fuDump)) { New-Item -ItemType Directory -Path $fuDump -Force | Out-Null }
            Move-Item -LiteralPath $DumpPath -Destination (Join-Path $fuDump ([IO.Path]::GetFileName($DumpPath))) -Force -ErrorAction SilentlyContinue
        }
        $fuEvt = Join-Path (Split-Path -Parent $EventPath) 'failed'
        if (-not (Test-Path -LiteralPath $fuEvt)) { New-Item -ItemType Directory -Path $fuEvt -Force | Out-Null }
        $dest = Join-Path $fuEvt ([IO.Path]::GetFileName($EventPath))
        try { Set-Content -LiteralPath "$dest.error" -Value $Reason -Encoding UTF8 } catch {}
        Move-Item -LiteralPath $EventPath -Destination $dest -Force
    } catch {}
    Clear-UploadAttempts -EventPath $EventPath
}

# Drain the outbox to the event sink. Durable at-least-once for the EVENT (stays until the backend accepts it),
# and - the #42 fix - the event is only archived once its granted dump has actually uploaded (or no dump was
# wanted). A wanted dump that fails to upload keeps the event pending and retried up to MaxDumpUploadAttempts;
# after that the dump is parked in failed-uploads (never dropped). Returns @{ Sent; Failed; Dumps; FailedUploads }.
function Send-OutboxEvents {
    param([string]$Dir, $Config)
    if (-not $Config) { $Config = Get-TelemetryConfig }
    if (-not $Dir) { $Dir = Get-KnownIssuesDir }
    $outbox = Join-Path $Dir 'outbox'
    if (-not (Test-Path -LiteralPath $outbox)) { return @{ Sent = 0; Failed = 0; Dumps = 0; FailedUploads = 0; Skipped = 0 } }
    $sentDir = Join-Path $outbox 'sent'
    if (-not (Test-Path -LiteralPath $sentDir)) { New-Item -ItemType Directory -Path $sentDir -Force | Out-Null }
    $http = Test-IsHttp $Config.EventSink
    if (-not $http -and -not (Test-Path -LiteralPath $Config.EventSink)) { New-Item -ItemType Directory -Path $Config.EventSink -Force | Out-Null }

    $profile = Get-DeviceProfile   # per-device collection profile (CONTRACT 4a), offline-aware cache
    $sent = 0; $failed = 0; $dumps = 0; $failedUploads = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $outbox -Filter *.json -File -ErrorAction SilentlyContinue)) {
        try {
            if ($http) {
                # 1) Post the event. The backend decides on its 202 whether this capture's dump is wanted and,
                #    if so, returns a one-time uploadGrant { token, maxBytes, expiresAt } in the response body.
                #    The event's own eventId is the Idempotency-Key (contract 3) so a retry of the same file is
                #    deduped server-side rather than double-stored.
                $body = Get-Content -LiteralPath $f.FullName -Raw
                $evt = $null; try { $evt = $body | ConvertFrom-Json } catch {}
                $idem = if ($evt -and $evt.ids -and $evt.ids.eventId) { "$($evt.ids.eventId)" } else { [IO.Path]::GetFileNameWithoutExtension($f.Name) }
                # Profile shortcut (CONTRACT 4a): if THIS device already uploaded a dump for this signature, the
                # backend already has a sample - we will NOT be granted another, so don't bother holding a grant
                # round-trip's worth of work on it. We do NOT delete the local dump (kept dumps are never deleted
                # on the send path; size-based retention evicts handled dumps later). The grant still decides any
                # actual upload; this only skips churn for a signature the backend already has.
                $sigId = if ($evt) { if ($evt.signatureId) { "$($evt.signatureId)" } elseif ($evt.ids) { "$($evt.ids.signatureId)" } else { '' } } else { '' }
                if ($sigId -and $profile[$sigId] -eq 'uploaded') {
                    Write-TelemetryLog ("device already uploaded a dump for {0} - any held dump kept locally, not re-collected" -f $sigId)
                }
                try {
                    $resp = Invoke-RestMethod -Method Post -Uri ($Config.EventSink.TrimEnd('/') + '/v1/events') -Body $body -ContentType 'application/json' -Headers (Get-AuthHeaders $Config @{ 'Idempotency-Key' = $idem }) -TimeoutSec 30
                } catch {
                    # Event not accepted -> leave it in the outbox and retry next run (durable, unbounded).
                    Write-TelemetryLog ("event POST failed for {0}: {1}" -f $f.Name, $_.Exception.Message) 'WARN'
                    $failed++; continue
                }
                # 2) No grant token -> the backend did not want this capture's dump -> the EVENT is done. We KEEP
                #    the local (gzipped) dump: dumps are never deleted on the send path (user rule). The dump stays
                #    in the dump dir, available for manual collection, and size-based retention evicts it (oldest
                #    handled first) only when the disk budget is exceeded.
                $grantTok = if ($resp -and $resp.uploadGrant) { "$($resp.uploadGrant.token)" } else { '' }
                if ([string]::IsNullOrWhiteSpace($grantTok)) {
                    Write-TelemetryLog ("dump not requested for {0} - event archived, local dump kept" -f $f.Name)
                    Move-SentEvent -EventPath $f.FullName -SentDir $sentDir; $sent++
                    continue
                }
                # 3) A grant WAS issued -> a dump is wanted. Locate it on disk.
                $loc = Resolve-DumpPath -Evt $evt -Config $Config
                if (-not $loc.Path) {
                    $n = (Get-UploadAttempts -EventPath $f.FullName) + 1
                    Write-TelemetryLog ("granted dump not found for {0} (looked: {1}); attempt {2}/{3}" -f $f.Name, ($loc.Tried -join ', '), $n, $script:MaxDumpUploadAttempts) 'ERROR'
                    if ($n -ge $script:MaxDumpUploadAttempts) { Move-FailedUpload -EventPath $f.FullName -DumpPath $null -Config $Config -Reason 'dump-not-found'; $failedUploads++ }
                    else { Set-UploadAttempts -EventPath $f.FullName -Count $n; $failed++ }
                    continue
                }
                # 4) A grant was issued and the dump is on disk, so it WILL be uploaded. The triage worker already
                #    gzipped every kept dump at rest (process memory compresses ~5x), so normally the resolved file
                #    IS the .gz and we upload it as-is - a large transfer win that also makes the body far more
                #    likely to fit the grant cap. Only a dump that somehow stayed raw is compressed here to a
                #    TEMPORARY .gz (deleted after). The backend stores the body opaquely (CONTRACT 5b); the event
                #    already carries the RAW bytes/sha256, which still describe the original dump. We NEVER delete
                #    the kept .gz after upload - size-based retention owns disk; the send path only archives the event.
                $diskName = Split-Path $loc.Path -Leaf                 # e.g. ProcDump_..._.dmp.gz (already compressed)
                $rawName  = $diskName -replace '\.gz$', ''             # the original .dmp name the silo reconstructs
                $tempGz = $null
                if ($loc.IsGz) {
                    $uploadPath = $loc.Path; $uploadName = $rawName + '.gz'
                } else {
                    $comp = Compress-DumpFile -SourcePath $loc.Path -DestPath ($loc.Path + '.upload.gz') -Label $rawName
                    if ($comp.Ok) { $tempGz = $comp.Path; $uploadPath = $tempGz; $uploadName = $rawName + '.gz' }
                    else { Write-TelemetryLog ("compress failed for {0}: {1} - uploading raw" -f $rawName, $comp.Error) 'WARN'; $uploadPath = $loc.Path; $uploadName = $rawName }
                }
                try {
                    $bytes = (Get-Item -LiteralPath $uploadPath).Length
                    $grant = Resolve-UploadGrant -Response $resp -DumpBytes $bytes
                    if ($grant.Reason -eq 'too-large') {
                        # Over the grant cap: park the EVENT (so it is not retried forever), but KEEP the dump in
                        # place (never deleted). Record the reason beside the parked event.
                        Write-TelemetryLog ("granted dump {0} is {1} bytes compressed, over the grant cap - parking event, dump kept" -f $rawName, $bytes) 'ERROR'
                        Move-FailedUpload -EventPath $f.FullName -DumpPath $null -Config $Config -Reason 'too-large'; $failedUploads++
                        continue
                    }
                    $up = Send-EscalatedDump -DumpPath $uploadPath -UploadName $uploadName -Config $Config -Grant $grant.Token
                    if ($up.Ok) {
                        # Uploaded OK -> the backend now holds this dump, so the local copy is redundant and MAY be
                        # deleted (frees disk). This is the ONLY delete-on-send: a dump that was NOT uploaded
                        # (no grant, failed, over cap) is always kept. Removes the on-disk dump (.dmp.gz or raw) + sidecars.
                        Write-TelemetryLog ("uploaded dump {0} as {1} ({2} bytes compressed) -> {3}; local copy removed (backend holds it)" -f $rawName, $uploadName, $bytes, $up.Key) 'INFO'
                        Remove-DumpArtifacts -DumpPath $loc.Path
                        Move-SentEvent -EventPath $f.FullName -SentDir $sentDir; $sent++; $dumps++
                    } else {
                        $n = (Get-UploadAttempts -EventPath $f.FullName) + 1
                        Write-TelemetryLog ("dump upload failed for {0}: {1}; attempt {2}/{3}" -f $rawName, $up.Detail, $n, $script:MaxDumpUploadAttempts) 'ERROR'
                        if ($n -ge $script:MaxDumpUploadAttempts) { Move-FailedUpload -EventPath $f.FullName -DumpPath $null -Config $Config -Reason ("upload-failed: " + $up.Detail); $failedUploads++ }
                        else { Set-UploadAttempts -EventPath $f.FullName -Count $n; $failed++ }
                        continue
                    }
                } finally {
                    if ($tempGz -and (Test-Path -LiteralPath $tempGz)) { Remove-Item -LiteralPath $tempGz -Force -ErrorAction SilentlyContinue }
                }
            } else {
                # Local/offline stand-in: no server to grant, so a NEW signature (escalateDump) drops its dump
                # into the local silo dir and stamps the key into the event before the file-drop.
                $evt = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
                if ($evt.escalateDump -and -not $evt.ids.dumpObjectKey -and $evt.dump.file) {
                    $loc = Resolve-DumpPath -Evt $evt -Config $Config
                    if ($loc.Path) {
                        $up = Send-EscalatedDump -DumpPath $loc.Path -Config $Config
                        if ($up.Ok) { $evt.ids.dumpObjectKey = $up.Key; $dumps++ }
                        else { Write-TelemetryLog ("local dump copy failed for {0}: {1}" -f $f.Name, $up.Detail) 'WARN' }
                    }
                    $evt | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $f.FullName -Encoding UTF8
                }
                Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $Config.EventSink $f.Name) -Force   # file-drop stand-in
                Move-SentEvent -EventPath $f.FullName -SentDir $sentDir; $sent++
            }
        } catch {
            Write-TelemetryLog ("outbox item {0} failed: {1}" -f $f.Name, $_.Exception.Message) 'WARN'
            $failed++
        }     # left in the outbox; retried next run
    }
    @{ Sent = $sent; Failed = $failed; Dumps = $dumps; FailedUploads = $failedUploads; Skipped = 0 }
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
        # Ensure the baseline's folder exists - KnownIssues\ may not exist yet on a fresh machine or before the
        # monitor has created it - and force file ops to be TERMINATING (-ErrorAction Stop) so a write/read failure
        # fails CLOSED to -1 (keep existing baseline) instead of a non-terminating error slipping past the catch and
        # silently returning 0, which would discard the synced list and make first-run triage over-capture.
        $baseDir = Split-Path -Parent $Config.BaselinePath
        if ($baseDir -and -not (Test-Path -LiteralPath $baseDir)) { New-Item -ItemType Directory -Path $baseDir -Force -ErrorAction Stop | Out-Null }
        if (Test-IsHttp $Config.KnownSource) {
            $headers = Get-AuthHeaders $Config
            $data = Invoke-RestMethod -Method Get -Uri ($Config.KnownSource.TrimEnd('/') + '/v1/known-signatures') -Headers $headers -TimeoutSec 30
            # The registry returns { signatures: [ { signature, status, ... } ], nextCursor }. The triage
            # baseline only needs the id set, so store the ids as a flat array (the shape Test-BaselineKnown reads).
            $ids = @($data.signatures | ForEach-Object { $_.signature } | Where-Object { $_ })
            (ConvertTo-Json -InputObject $ids) | Set-Content -LiteralPath $Config.BaselinePath -Encoding UTF8 -ErrorAction Stop
        } elseif (Test-Path -LiteralPath $Config.KnownSource) {
            if ($Config.KnownSource -ne $Config.BaselinePath) { Copy-Item -LiteralPath $Config.KnownSource -Destination $Config.BaselinePath -Force -ErrorAction Stop }
        } else { return 0 }
        $b = Get-Content -LiteralPath $Config.BaselinePath -Raw -ErrorAction Stop | ConvertFrom-Json
        $ids = if ($null -eq $b) { @() } elseif ($b.issues) { $b.issues.PSObject.Properties.Name } elseif ($b -is [array]) { $b } else { @($b) }
        return @($ids).Count
    } catch { Write-TelemetryLog ("known-signatures: sync error - {0}" -f (Resolve-HttpError $_ $Config)) 'WARN'; return -1 }   # -1 = keep the existing baseline
}

# Pull THIS device's collection profile (CONTRACT 4a: GET /v1/profile?deviceId) and cache it locally, so the
# flush knows - even offline - which signatures this device has already uploaded (discard the held dump) vs still
# owes (keep + retry). Advisory only: the grant (5a) remains the sole upload authority. Returns the entry count,
# or -1 on failure (keep the cached profile). No-op (0) in local/offline mode.
function Sync-DeviceProfile {
    param($Config, [string]$DeviceId)
    if (-not $Config) { $Config = Get-TelemetryConfig }
    if (-not $DeviceId) { $DeviceId = $env:COMPUTERNAME }
    if (-not (Test-IsHttp $Config.KnownSource)) { return 0 }
    try {
        $uri = $Config.KnownSource.TrimEnd('/') + '/v1/profile?deviceId=' + [uri]::EscapeDataString($DeviceId)
        $data = Invoke-RestMethod -Method Get -Uri $uri -Headers (Get-AuthHeaders $Config) -TimeoutSec 30
        $map = @{}
        foreach ($e in @($data.entries)) { if ($e.signatureId) { $map["$($e.signatureId)"] = "$($e.state)" } }
        $path = Get-DeviceProfilePath
        $dir = Split-Path -Parent $path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        ($map | ConvertTo-Json) | Set-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop
        return $map.Count
    } catch { Write-TelemetryLog ("device-profile: sync error - {0}" -f (Resolve-HttpError $_ $Config)) 'WARN'; return -1 }
}

# Offline / server-unreachable fallback for the device profile. When there is no backend to ask (local mode)
# or the http sync failed, we still must avoid re-keeping a dump for a signature this box already holds a sample
# for - otherwise a long offline period keeps one dump per RECURRENCE instead of one per signature. We derive
# the profile LOCALLY from the per-machine registry (ids this machine has a kept sample for) merged with the
# known baseline (ids already analysed), marking them 'uploaded' so triage/flush treat them as already-collected.
# This only ever ADDS local knowledge; it never invents a 'granted' obligation. Returns the entry count.
function Build-LocalDeviceProfile {
    param($Config, [string]$DeviceId)
    if (-not $Config) { $Config = Get-TelemetryConfig }
    $map = @{}
    try {
        # ids with a kept sample on THIS machine (registry is per-machine already)
        $reg = Read-LocalRegistry (Get-KnownIssuesDir)
        $machineKey = Get-MachineKey
        foreach ($id in @($reg.issues.Keys)) {
            $iss = $reg.issues[$id]
            $m = if ($iss.machines) { $iss.machines[$machineKey] } else { $null }
            if ($m -and $m.sample) { $map["$id"] = 'uploaded' }
        }
        # ids already analysed centrally (shipped/synced baseline) - also "already collected" for our purposes
        if ($Config.BaselinePath -and (Test-Path -LiteralPath $Config.BaselinePath)) {
            try {
                $b = Get-Content -LiteralPath $Config.BaselinePath -Raw | ConvertFrom-Json
                $ids = if ($null -eq $b) { @() } elseif ($b.issues) { $b.issues.PSObject.Properties.Name } elseif ($b -is [array]) { $b } else { @($b) }
                foreach ($id in @($ids)) { if ($id) { $map["$id"] = 'uploaded' } }
            } catch {}
        }
        $path = Get-DeviceProfilePath
        $dir = Split-Path -Parent $path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        ($map | ConvertTo-Json) | Set-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop
        return $map.Count
    } catch { Write-TelemetryLog ("device-profile: local build error - {0}" -f $_.Exception.Message) 'WARN'; return -1 }
}

# "Collect for manual handling" (UI button): for a box that cannot reach the backend, gather everything a human
# needs to carry to an online PC into ONE folder, <DumpDir>\manual-outbox. That is the pending event JSONs (the
# reports) and the gzipped dumps - two separate kinds of file, NOT packaged together. The events are MOVED out of
# the outbox (so the forwarder stops trying to send them - manual takeover) and the dumps are MOVED out of the
# dump dir. Replaying them later is an online-PC / operator step. Returns @{ Events; Dumps; Dest }.
function Move-ToManualOutbox {
    param($Config, [string]$Dir)
    if (-not $Config) { $Config = Get-TelemetryConfig }
    if (-not $Dir) { $Dir = Get-KnownIssuesDir }
    $dest = Join-Path $Config.DumpDir 'manual-outbox'
    if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
    $events = 0; $dumps = 0
    # 1) pending events (+ their .try sidecars) from the outbox top level (never the already-archived 'sent')
    $outbox = Join-Path $Dir 'outbox'
    if (Test-Path -LiteralPath $outbox) {
        foreach ($e in @(Get-ChildItem -LiteralPath $outbox -Filter *.json -File -ErrorAction SilentlyContinue)) {
            try {
                Move-Item -LiteralPath $e.FullName -Destination (Join-Path $dest $e.Name) -Force
                $try = "$($e.FullName).try"; if (Test-Path -LiteralPath $try) { Move-Item -LiteralPath $try -Destination (Join-Path $dest ($e.Name + '.try')) -Force }
                $events++
            } catch { Write-TelemetryLog ("manual-collect: could not move event {0}: {1}" -f $e.Name, $_.Exception.Message) 'WARN' }
        }
    }
    # 2) gzipped dumps (+ their .info/.versions sidecars) from the dump dir top level and failed-uploads
    foreach ($root in @($Config.DumpDir, (Join-Path $Config.DumpDir 'failed-uploads'))) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($g in @(Get-ChildItem -LiteralPath $root -Filter *.dmp.gz -File -ErrorAction SilentlyContinue)) {
            try {
                Move-Item -LiteralPath $g.FullName -Destination (Join-Path $dest $g.Name) -Force
                foreach ($sx in '.info.txt', '.versions.txt') {
                    $sc = ($g.FullName -replace '\.dmp\.gz$', $sx)
                    if (Test-Path -LiteralPath $sc) { Move-Item -LiteralPath $sc -Destination (Join-Path $dest ([IO.Path]::GetFileName($sc))) -Force }
                }
                $dumps++
            } catch { Write-TelemetryLog ("manual-collect: could not move dump {0}: {1}" -f $g.Name, $_.Exception.Message) 'WARN' }
        }
    }
    Write-TelemetryLog ("manual-collect: moved {0} event(s) and {1} dump(s) to {2}" -f $events, $dumps, $dest)
    @{ Events = $events; Dumps = $dumps; Dest = $dest }
}

# Reachability + auth probe for the configured telemetry service, for the "Test telemetry" button. Checks each
# distinct https endpoint (EventSink / KnownSource / DumpTarget) with the SAME authenticated call the device
# makes (GET /v1/known-signatures), so a green result means this machine can actually talk to the backend with
# its fleet key. Returns a human-readable multi-line summary; never throws.
function Test-Telemetry {
    param($Config)
    if (-not $Config) { $Config = Get-TelemetryConfig }
    $lines = @('fleet key: ' + $(if ($Config.DeviceKey) { 'configured' } else { 'NOT configured on this device' }))
    $bases = @($Config.EventSink, $Config.KnownSource, $Config.DumpTarget) | Where-Object { Test-IsHttp $_ } | Select-Object -Unique
    if (@($bases).Count -eq 0) { return 'Telemetry is in local/offline mode (no https endpoint configured) - nothing to reach.' }
    foreach ($base in $bases) {
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $null = Invoke-RestMethod -Method Get -Uri ($base.TrimEnd('/') + '/v1/known-signatures') -Headers (Get-AuthHeaders $Config) -TimeoutSec 15
            $lines += ('OK    {0}  - reached + authenticated ({1} ms)' -f $base, $sw.ElapsedMilliseconds)
        } catch {
            $lines += ('FAIL  {0}  - {1}' -f $base, (Resolve-HttpError $_ $Config))
        }
    }
    return ($lines -join "`n")
}

# Get-DeviceProfile / Get-DeviceProfilePath live in Common\Dump\Core.ps1 (dump engine) so the detached triage
# worker can read the cached profile too; this transport module only writes it (Sync-DeviceProfile above).

# Stream a file to an http endpoint with HttpClient. Windows PowerShell 5.1's Invoke-RestMethod -InFile buffers
# the WHOLE file into memory before sending, so a ~1.6 GB dump spikes/fails on a constrained machine (#42 defect
# 4); StreamContent over a FileStream sends it in chunks. Returns @{ Ok; Status; Body; Error }.
function Invoke-DumpUpload {
    param([string]$Uri, [string]$FilePath, [hashtable]$Headers, [int]$TimeoutSec = 600)
    try { Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue } catch {}
    $client = $null; $fs = $null; $req = $null; $content = $null
    try {
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
        $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Post, $Uri)
        $fs = [System.IO.File]::OpenRead($FilePath)
        $content = New-Object System.Net.Http.StreamContent $fs
        $content.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue 'application/octet-stream'
        if ($Headers) { foreach ($k in $Headers.Keys) { [void]$req.Headers.TryAddWithoutValidation($k, "$($Headers[$k])") } }
        $req.Content = $content
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $rbody = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $code = [int]$resp.StatusCode
        if ($resp.IsSuccessStatusCode) { return @{ Ok = $true; Status = $code; Body = $rbody; Error = $null } }
        return @{ Ok = $false; Status = $code; Body = $rbody; Error = ("HTTP {0} {1}" -f $code, $resp.ReasonPhrase) }
    } catch {
        return @{ Ok = $false; Status = 0; Body = $null; Error = $_.Exception.Message }
    } finally {
        if ($content) { $content.Dispose() }; if ($fs) { $fs.Dispose() }; if ($req) { $req.Dispose() }; if ($client) { $client.Dispose() }
    }
}

# gzip a file (streamed, chunked - never buffers the whole dump into memory), to $DestPath or <source>.gz.
# Process-memory dumps compress heavily; this is the last step before upload (#43). Progress is logged every ~10%
# and a final "compressed X -> Y (Z%)" line (#65), so a watcher on the telemetry log (and, later, the UI) sees a
# large dump being worked. Returns @{ Ok; Path; RawBytes; GzBytes; Error }.
function Compress-DumpFile {
    param([Parameter(Mandatory)][string]$SourcePath, [string]$DestPath, [string]$Label)
    try { Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue } catch {}
    if (-not $DestPath) { $DestPath = "$SourcePath.gz" }
    if (-not $Label)    { $Label = [IO.Path]::GetFileName($SourcePath) }
    $in = $null; $out = $null; $gz = $null
    try {
        $in  = [IO.File]::OpenRead($SourcePath)
        $total = $in.Length
        $out = [IO.File]::Create($DestPath)
        $gz  = New-Object System.IO.Compression.GZipStream($out, [System.IO.Compression.CompressionLevel]::Optimal)
        $buf = New-Object byte[] (1MB); $done = 0L; $lastPct = -1
        Write-TelemetryLog ("compressing {0} ({1:N0} bytes) before upload..." -f $Label, $total)
        while (($read = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $gz.Write($buf, 0, $read); $done += $read
            if ($total -gt 0) {
                $pct = [int](($done * 100) / $total)
                if ($pct -ge $lastPct + 10 -and $pct -lt 100) { Write-TelemetryLog ("compressing {0}: {1}%" -f $Label, $pct); $lastPct = $pct }
            }
        }
        $gz.Dispose(); $gz = $null; $out.Dispose(); $out = $null; $in.Dispose(); $in = $null
        $gzBytes = (Get-Item -LiteralPath $DestPath).Length
        $ratio = if ($total -gt 0) { [int](($gzBytes * 100) / $total) } else { 0 }
        Write-TelemetryLog ("compressed {0}: {1:N0} -> {2:N0} bytes ({3}% of raw)" -f $Label, $total, $gzBytes, $ratio)
        return @{ Ok = $true; Path = $DestPath; RawBytes = $total; GzBytes = $gzBytes; Error = $null }
    } catch {
        if ($gz) { $gz.Dispose() }; if ($out) { $out.Dispose() }; if ($in) { $in.Dispose() }
        if (Test-Path -LiteralPath $DestPath) { Remove-Item -LiteralPath $DestPath -Force -ErrorAction SilentlyContinue }
        return @{ Ok = $false; Path = $null; RawBytes = 0; GzBytes = 0; Error = $_.Exception.Message }
    }
}

# Send a granted dump to the dump target (silo stand-in locally). Over http the one-time grant from the
# /v1/events 202 goes in X-Upload-Grant (fleet key only, no admin key), streamed (not -InFile; #42 defect 4).
# Returns @{ Ok; Key; Detail } - on failure Detail carries the HTTP status/reason so the flusher can log it
# (#42 defect 2: the upload error was swallowed with no diagnostic). It is artifact-agnostic: whatever file is at
# $DumpPath is uploaded as-is (the flusher passes a gzipped .gz, #43), named by $UploadName on the wire.
function Send-EscalatedDump {
    param([Parameter(Mandatory)][string]$DumpPath, $Config, [string]$Grant, [string]$UploadName)
    if (-not $Config) { $Config = Get-TelemetryConfig }
    if (-not (Test-Path -LiteralPath $DumpPath)) { return @{ Ok = $false; Key = $null; Detail = 'dump-not-found' } }
    $name = if ($UploadName) { $UploadName } else { [IO.Path]::GetFileName($DumpPath) }
    if (Test-IsHttp $Config.DumpTarget) {
        $extra = @{ 'X-Dump-Name' = $name }
        if ($Grant) { $extra['X-Upload-Grant'] = $Grant }
        $headers = Get-AuthHeaders $Config $extra
        $r = Invoke-DumpUpload -Uri ($Config.DumpTarget.TrimEnd('/') + '/v1/dumps') -FilePath $DumpPath -Headers $headers -TimeoutSec 600
        if (-not $r.Ok) { return @{ Ok = $false; Key = $null; Detail = $r.Error } }
        $key = $name
        if ($r.Body) { try { $o = $r.Body | ConvertFrom-Json; if ($o.dumpObjectKey) { $key = "$($o.dumpObjectKey)" } } catch {} }   # contract 5b: 201 { dumpObjectKey }
        return @{ Ok = $true; Key = $key; Detail = "HTTP $($r.Status)" }
    } else {
        try {
            if (-not (Test-Path -LiteralPath $Config.DumpTarget)) { New-Item -ItemType Directory -Path $Config.DumpTarget -Force | Out-Null }
            Copy-Item -LiteralPath $DumpPath -Destination (Join-Path $Config.DumpTarget $name) -Force
            return @{ Ok = $true; Key = (Join-Path $Config.DumpTarget $name); Detail = 'local-copy' }
        } catch { return @{ Ok = $false; Key = $null; Detail = $_.Exception.Message } }
    }
}
