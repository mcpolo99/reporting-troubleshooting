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

# Resolve where the granted dump actually is. Prefers an absolute path the producer stamped (dump.path), then a
# rooted dump.file, then DumpDir + the bare filename. Returns @{ Path = <first existing | $null>; Tried = @() }.
# (#42 defect 3: a bare filename + a DumpDir that differs from where the capture landed skipped upload silently.)
function Resolve-DumpPath { param($Evt, $Config)
    $d = if ($Evt) { $Evt.dump } else { $null }
    $tried = @()
    if ($d) {
        if ($d.path) { $tried += "$($d.path)" }
        $file = "$($d.file)"
        if ($file) {
            if ([IO.Path]::IsPathRooted($file)) { $tried += $file }
            if ($Config.DumpDir) { $tried += (Join-Path $Config.DumpDir ([IO.Path]::GetFileName($file))) }
        }
    }
    $hit = $null
    foreach ($c in $tried) { if ($c -and (Test-Path -LiteralPath $c)) { $hit = $c; break } }
    return @{ Path = $hit; Tried = @($tried) }
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
                try {
                    $resp = Invoke-RestMethod -Method Post -Uri ($Config.EventSink.TrimEnd('/') + '/v1/events') -Body $body -ContentType 'application/json' -Headers (Get-AuthHeaders $Config @{ 'Idempotency-Key' = $idem }) -TimeoutSec 30
                } catch {
                    # Event not accepted -> leave it in the outbox and retry next run (durable, unbounded).
                    Write-TelemetryLog ("event POST failed for {0}: {1}" -f $f.Name, $_.Exception.Message) 'WARN'
                    $failed++; continue
                }
                # 2) No grant token -> the backend did not want this capture's dump -> the event is done and the
                #    local dump (if any) is not needed - delete it (DumpDir is staging, not a keep-store).
                $grantTok = if ($resp -and $resp.uploadGrant) { "$($resp.uploadGrant.token)" } else { '' }
                if ([string]::IsNullOrWhiteSpace($grantTok)) {
                    $locNG = Resolve-DumpPath -Evt $evt -Config $Config
                    if ($locNG.Path) { Remove-HandledDump -DumpPath $locNG.Path; Write-TelemetryLog ("dump not requested for {0} - deleted {1}" -f $f.Name, (Split-Path $locNG.Path -Leaf)) }
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
                # 4) A grant was issued and the dump is on disk, so it WILL be uploaded - only now do we compress it
                #    (#64: a dump that is not being uploaded is never compressed; the no-grant case already returned
                #    at step 2). Process-memory dumps compress ~5x, so gzipping just before the POST is a large
                #    transfer win and makes the body far more likely to fit the grant cap. The backend stores the
                #    body opaquely (CONTRACT 5b), so we upload the .gz as-is and signal it with a .gz name; the silo
                #    consumer decompresses. The event already carries the RAW bytes/sha256 (emitted at capture), so
                #    those still describe the original dump. Size-gate the COMPRESSED bytes, stream up, clean the .gz.
                $rawName = Split-Path $loc.Path -Leaf
                $gzPath = $null
                $comp = Compress-DumpFile -SourcePath $loc.Path -DestPath ($loc.Path + '.gz') -Label $rawName
                if ($comp.Ok) { $gzPath = $comp.Path; $uploadPath = $gzPath; $uploadName = $rawName + '.gz' }
                else { Write-TelemetryLog ("compress failed for {0}: {1} - uploading raw" -f $rawName, $comp.Error) 'WARN'; $uploadPath = $loc.Path; $uploadName = $rawName }
                try {
                    $bytes = (Get-Item -LiteralPath $uploadPath).Length
                    $grant = Resolve-UploadGrant -Response $resp -DumpBytes $bytes
                    if ($grant.Reason -eq 'too-large') {
                        Write-TelemetryLog ("granted dump {0} is {1} bytes compressed, over the grant cap - moving to failed-uploads" -f $rawName, $bytes) 'ERROR'
                        Move-FailedUpload -EventPath $f.FullName -DumpPath $loc.Path -Config $Config -Reason 'too-large'; $failedUploads++
                        continue
                    }
                    $up = Send-EscalatedDump -DumpPath $uploadPath -UploadName $uploadName -Config $Config -Grant $grant.Token
                    if ($up.Ok) {
                        Write-TelemetryLog ("uploaded dump {0} as {1} ({2} bytes compressed) -> {3}" -f $rawName, $uploadName, $bytes, $up.Key) 'INFO'
                        Remove-HandledDump -DumpPath $loc.Path   # uploaded OK -> the local raw dump is no longer needed
                        Move-SentEvent -EventPath $f.FullName -SentDir $sentDir; $sent++; $dumps++
                    } else {
                        $n = (Get-UploadAttempts -EventPath $f.FullName) + 1
                        Write-TelemetryLog ("dump upload failed for {0}: {1}; attempt {2}/{3}" -f $rawName, $up.Detail, $n, $script:MaxDumpUploadAttempts) 'ERROR'
                        if ($n -ge $script:MaxDumpUploadAttempts) { Move-FailedUpload -EventPath $f.FullName -DumpPath $loc.Path -Config $Config -Reason ("upload-failed: " + $up.Detail); $failedUploads++ }
                        else { Set-UploadAttempts -EventPath $f.FullName -Count $n; $failed++ }
                        continue
                    }
                } finally {
                    if ($gzPath -and (Test-Path -LiteralPath $gzPath)) { Remove-Item -LiteralPath $gzPath -Force -ErrorAction SilentlyContinue }
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
    } catch { return -1 }       # -1 = sync failed (keep the existing baseline)
}

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
