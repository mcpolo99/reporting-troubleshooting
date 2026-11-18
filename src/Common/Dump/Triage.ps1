# Dump engine: triage one dump end-to-end (signature -> walk -> id -> ledger decision -> report -> collect/drop),
# plus THE single dump-delete path. Owned by the INGEST concern (triage worker), never the armer.


# THE ONE place a dump is deleted. Time + grace based, with a disk-budget emergency ceiling. Nothing on the
# triage or send path deletes a dump; those paths only MARK a dump processed (a '<dump>.handled' marker, written
# by Set-DumpHandled) when its bytes reach a terminal outcome - dropped (recurrence / already-uploaded / known),
# uploaded OK, not-wanted, or permanently parked. This function is the single source of truth for removal:
#   - a PROCESSED dump (has a .handled marker) is deleted once it is older than GraceSeconds;
#   - a NEEDED dump (no marker - awaiting a grant/upload) or an un-triaged dump is NEVER auto-deleted;
#   - if the dump dir is still over LimitGB after the grace sweep, processed dumps are evicted oldest-handled
#     first EVEN within grace (the hard disk ceiling), but a needed/unmarked dump is still never touched - over
#     budget with only needed dumps -> warn, never silent data loss.
# Deletion is identical online or offline (it never consults the endpoint or the ledger). Also sweeps orphaned
# .info/.versions/.handled sidecars whose dump is gone. GraceSeconds default 2h.
function Invoke-DumpRetention {
    param([Parameter(Mandatory)][string]$DumpDir, [double]$LimitGB = 30, [string]$Dir, [int]$GraceSeconds = 7200)
    if (-not $Dir) { $Dir = Get-KnownIssuesDir }
    $limitBytes = [Math]::Max($LimitGB, 0.1) * 1GB
    $roots = @($DumpDir, (Join-Path $DumpDir 'failed-uploads'))
    $nowUtc = (Get-Date).ToUniversalTime()

    # Orphaned sidecars (a .info/.versions/.handled whose dump is gone) - sweep regardless of budget/grace.
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        Get-ChildItem -LiteralPath $r -Filter *.txt -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '\.(info|versions)\.txt$' -and
                           -not (Test-Path -LiteralPath ($_.FullName -replace '\.(info|versions)\.txt$', '.dmp')) -and
                           -not (Test-Path -LiteralPath ($_.FullName -replace '\.(info|versions)\.txt$', '.dmp.gz')) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $r -Filter *.handled -File -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-Path -LiteralPath ($_.FullName -replace '\.handled$', '')) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # Every dump on disk (raw .dmp or kept-at-rest .dmp.gz) under the roots, tagged with its processed time.
    function Get-AllDumps {
        $acc = @()
        foreach ($r in $roots) {
            if (-not (Test-Path -LiteralPath $r)) { continue }
            foreach ($d in @(Get-ChildItem -LiteralPath $r -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.dmp(\.gz)?$' })) {
                $acc += [pscustomobject]@{ File = $d; HandledUtc = (Get-DumpHandledUtc $d.FullName) }
            }
        }
        $acc
    }

    # 1) Grace sweep: delete every PROCESSED dump older than the grace period. Needed/unmarked dumps are skipped.
    foreach ($p in @(Get-AllDumps | Where-Object { $_.HandledUtc })) {
        $age = ($nowUtc - $p.HandledUtc).TotalSeconds
        if ($age -lt $GraceSeconds) { continue }
        try {
            $sz = $p.File.Length
            Remove-DumpArtifacts -DumpPath $p.File.FullName
            Write-TelemetryLog ("retention: deleted processed dump {0} ({1:N1} MB), handled {2:N0}s ago (grace {3}s)" -f $p.File.Name, ($sz/1MB), $age, $GraceSeconds)
        } catch { Write-TelemetryLog "retention: could not delete $($p.File.Name) (in use?), will retry." 'WARN' }
    }

    # 2) Disk-budget ceiling: if still over budget, evict the oldest-handled PROCESSED dumps first, even within
    #    grace. A needed/unmarked dump is never evicted.
    $left = @(Get-AllDumps)
    $total = ($left | ForEach-Object { $_.File.Length } | Measure-Object -Sum).Sum
    if (-not $total -or $total -le $limitBytes) { return }
    foreach ($e in @($left | Where-Object { $_.HandledUtc } | Sort-Object HandledUtc)) {
        if ($total -le $limitBytes) { break }
        try {
            $sz = $e.File.Length
            Remove-DumpArtifacts -DumpPath $e.File.FullName
            $total -= $sz
            Write-TelemetryLog ("retention: over budget - evicted processed dump {0} ({1:N1} MB) early; budget {2} GB" -f $e.File.Name, ($sz/1MB), $LimitGB) 'WARN'
        } catch { Write-TelemetryLog "retention: could not evict $($e.File.Name) (in use?), will retry." 'WARN' }
    }
    if ($total -gt $limitBytes) {
        Write-TelemetryLog ("retention: still {0:N1} GB over the {1} GB budget, but all remaining dumps are needed/un-triaged - kept (no data loss)." -f (($total-$limitBytes)/1GB), $LimitGB) 'WARN'
    }
}


# =============================== TRIAGE (one dump) =====================
# Full handling for one completed dump: read its signature, run the Tier-2 walk if the kind needs one, compute
# the stable id, record it against the device ledger and get the COLLECT decision, ALWAYS emit one report, then
# act on the decision. EVERY dump is gzipped at rest regardless of the decision; 'collect'/'defer' leave the
# .dmp.gz unmarked (needed, awaits upload) while 'drop' marks it '<dump>.handled' (held for the delete timer).
# This is the slow step (the walk opens the dump) - the monitor runs it in a DETACHED worker, never in its loop.
# Returns @{ Collect; State; Reason; Id; Count; Kind; Leaf; Disposition; KeptPath; EventPath }.
function Invoke-DumpTriage {
    param(
        [Parameter(Mandatory)][string]$DumpPath,
        [string]$ClrMdDll,
        [string]$Dir,
        [string]$BaselinePath,
        [bool]$SuppressKnown = $true,
        [bool]$IsOnline = $false,       # a backend endpoint is configured (a grant could come) - drives the known-but-offline drop
        [string]$CancelFile             # Force-flush cancel marker: aborts a long gzip mid-stream (passed to Compress-DumpFile)
    )
    if (-not (Test-Path -LiteralPath $DumpPath)) { return @{ Collect = 'skip'; Reason = 'dump not found' } }
    if (-not $Dir) { $Dir = Get-KnownIssuesDir }

    # Parse + id ONCE (shared with Get-DumpEvent): signature, Tier-2 walk, stable id.
    $ident = Resolve-DumpIdentity -DumpPath $DumpPath -ClrMdDll $ClrMdDll -Dir $Dir
    if (-not $ident) { return @{ Collect = 'skip'; Reason = 'not a minidump' } }
    $sig = $ident.Sig; $idObj = $ident.IdObj

    # Triage OWNS naming now (the monitor writes a placeholder and never renames). Derive the real tag from the
    # single parse above and compute the FINAL resting name, so the rename is folded into the gzip - there is
    # never an intermediate final '.dmp' for the monitor's *.dmp scan to re-pick-up (it only ever sees the
    # placeholder vanish and a '.dmp.gz' appear, which it ignores).
    $tag = Get-DumpTag -Code $sig.Code -Trigger "$($sig.ProcDumpComment)"
    $dumpDir = Split-Path -Parent $DumpPath
    $restingName = Get-RestingDumpName (Split-Path $DumpPath -Leaf) $tag
    if (-not $restingName) {
        $proc = Get-DumpProcessFromName (Split-Path $DumpPath -Leaf); if (-not $proc) { $proc = [IO.Path]::GetFileNameWithoutExtension("$($sig.ImageName)") }
        $comp = Get-DumpComputerFromName (Split-Path $DumpPath -Leaf); if (-not $comp) { $comp = $env:COMPUTERNAME }
        $when = try { (Get-Item -LiteralPath $DumpPath).CreationTime } catch { Get-Date }
        $restingName = New-DumpFileName -Computer $comp -Process $proc -Tag $tag -When $when
    }
    $restingGz = (Join-Path $dumpDir $restingName) + '.gz'

    # Record against the ledger and get the bytes decision (collect | drop | defer). Dedup state lives ONLY here.
    # The recorded sample is the final resting .gz (what will exist after the fold).
    $res = Update-DeviceLedger -IdObj $idObj -DumpPath $restingGz -Dir $Dir -BaselinePath $BaselinePath -SuppressKnown $SuppressKnown -IsOnline $IsOnline
    $res.Kind = $sig.Kind
    $res.Leaf = if ($sig.Frames -and $sig.Frames.Count) { $sig.Frames[0] } elseif ($sig.Module) { '{0}+0x{1:x}' -f $sig.Module, $sig.Offset } else { '' }

    # Capture the RAW facts from the placeholder while it is still on disk (size + mtime always; sha only when we
    # keep the bytes for upload - a dropped dump is held compressed for the delete timer, not hashed).
    $rawBytes = -1; $rawMtime = $null; $rawSha = $null
    try { $pi = Get-Item -LiteralPath $DumpPath -ErrorAction Stop; $rawBytes = [long]$pi.Length; $rawMtime = $pi.LastWriteTimeUtc.ToString('o') } catch {}
    if ($res.Collect -ne 'drop') { $rawSha = Get-FileSha256 $DumpPath }

    # EVERY dump lives compressed at rest - ALWAYS gzip, whether it will be uploaded (needed) or only held for the
    # delete timer (processed). Write the FINAL-named <...>.dmp.gz straight from the placeholder (rename + gzip
    # folded into one), then delete the placeholder - the monitor's *.dmp scan only ever sees the placeholder
    # vanish and a '.dmp.gz' appear (which it ignores). If the compressor is unavailable or fails, keep the RAW
    # placeholder in place (no rename -> no monitor re-triage).
    $res.KeptPath = $DumpPath; $emitPath = $DumpPath; $gzOk = $false
    if ((Get-Command Compress-DumpFile -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $DumpPath)) {
        $gz = Compress-DumpFile -SourcePath $DumpPath -DestPath $restingGz -Label $restingName -CancelFile $CancelFile
        if ($gz.Ok) {
            Remove-Item -LiteralPath $DumpPath -Force -ErrorAction SilentlyContinue
            $gzOk = $true; $res.KeptPath = $restingGz; $emitPath = $restingGz
        } else {
            Add-DepGap 'gzip-at-rest' ("gzip of $([IO.Path]::GetFileName($DumpPath)) failed: $($gz.Error) - keeping raw placeholder") $Dir
            if ($res.Collect -ne 'drop') { try { [void](Set-LedgerSample -Sig $res.Id -Sample $DumpPath -Dir $Dir) } catch {} }   # kept sample stays the raw placeholder
        }
    } elseif ($res.Collect -ne 'drop') {
        try { [void](Set-LedgerSample -Sig $res.Id -Sample $DumpPath -Dir $Dir) } catch {}
    }

    if ($res.Collect -eq 'drop') {
        # Reported, but the bytes are not needed (a recurrence, an already-uploaded id, or a known id). The dump is
        # compressed like any other, then MARKED processed where it lies (a '<dump>.handled' marker). The single
        # delete path (Invoke-DumpRetention) removes it once it is older than the grace period (or sooner only if
        # over the disk budget). The ingest pass never re-triages a .dmp.gz. Identical online/offline.
        Set-DumpHandled -DumpPath $res.KeptPath -Reason ("drop:" + "$($res.Reason)")
        $res.Disposition = if ($gzOk) { 'dropped-held-gz' } else { 'dropped-held' }
    } else {
        # KEEP (collect/defer): left UNMARKED - a needed dump awaiting a grant/upload; the delete path never
        # touches an unmarked dump.
        $res.Disposition = if ($gzOk) { 'kept-gz' } else { 'kept' }
    }

    # ALWAYS emit one procdump-facts/v1 report, AFTER the dump reached its resting form, referencing that file.
    # Raw size/sha/mtime were captured above (the report describes the ORIGINAL dump). Guarded so a failing
    # emitter never breaks triage.
    if (Get-Command Get-DumpFacts -ErrorAction SilentlyContinue) {
        try {
            $facts = Get-DumpFacts -Sig $sig -IdObj $idObj -DumpPath $emitPath -Decision $res -Sha256 $rawSha -RawBytes $rawBytes -RawCapturedUtc $rawMtime
            $res.EventPath = Write-DumpFactsEvent -Facts $facts -Dir $Dir
        } catch { Add-DepGap 'facts-emit' ("report emission failed for $restingName : $($_.Exception.Message)") $Dir }
    }
    return $res
}
