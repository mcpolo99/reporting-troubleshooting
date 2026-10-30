# Dump engine: triage one dump end-to-end (signature -> walk -> id -> ledger decision -> report -> collect/drop),
# plus size-based retention over the dump dir. Owned by the INGEST concern (triage worker), never the armer.


# Size-based dump retention, keyed off the LEDGER (never by count). A dump is PROTECTED and never evicted when
# it is a current ledger sample (held/granted) or is referenced by any unsent report (outbox or outbox\failed).
# Everything else is a stale/orphaned artifact and is evictable oldest-first when over the disk budget (uploaded
# dumps are already deleted at upload, so in practice this only reaps orphans). Over budget with only protected
# dumps -> warn, never silent data loss. Also sweeps orphaned .info/.versions sidecars.
function Invoke-DumpRetention {
    param([Parameter(Mandatory)][string]$DumpDir, [double]$LimitGB = 30, [string]$Dir)
    if (-not $Dir) { $Dir = Get-KnownIssuesDir }
    $limitBytes = [Math]::Max($LimitGB, 0.1) * 1GB
    $roots = @($DumpDir, (Join-Path $DumpDir 'failed-uploads'))

    $protected = @{}
    $add = { param($p) if ($p) { $n = [IO.Path]::GetFileName("$p"); $protected[$n] = $true; $protected[($n -replace '\.gz$','')] = $true; $protected["$n.gz"] = $true } }
    try { $led = Read-DeviceLedger $Dir; foreach ($sig in @($led.entries.Keys)) { & $add $led.entries[$sig].sample } } catch {}
    foreach ($sub in @('outbox', 'outbox\failed')) {
        $d = Join-Path $Dir $sub
        if (-not (Test-Path -LiteralPath $d)) { continue }
        foreach ($ev in @(Get-ChildItem -LiteralPath $d -Filter *.json -File -ErrorAction SilentlyContinue)) {
            try { $j = Get-Content -LiteralPath $ev.FullName -Raw | ConvertFrom-Json; & $add $j.dump.path; & $add $j.dump.file } catch {}
        }
    }

    # Orphaned sidecars (a .info/.versions whose dump is gone) - sweep regardless of budget.
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        Get-ChildItem -LiteralPath $r -Filter *.txt -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '\.(info|versions)\.txt$' -and
                           -not (Test-Path -LiteralPath ($_.FullName -replace '\.(info|versions)\.txt$', '.dmp')) -and
                           -not (Test-Path -LiteralPath ($_.FullName -replace '\.(info|versions)\.txt$', '.dmp.gz')) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    $all = @()
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $all += @(Get-ChildItem -LiteralPath $r -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.dmp(\.gz)?$' })
    }
    if (-not $all.Count) { return }
    $total = ($all | Measure-Object Length -Sum).Sum
    if ($total -le $limitBytes) { return }

    $evictable = @($all | Where-Object { -not $protected[$_.Name] } | Sort-Object LastWriteTime)
    foreach ($d in $evictable) {
        if ($total -le $limitBytes) { break }
        try {
            $sz = $d.Length
            Remove-Item -LiteralPath $d.FullName -Force -ErrorAction Stop
            foreach ($sx in '.info.txt', '.versions.txt') { Remove-Item -LiteralPath ($d.FullName -replace '\.dmp(\.gz)?$', $sx) -Force -ErrorAction SilentlyContinue }
            $total -= $sz
            Write-TelemetryLog ("retention: evicted orphan dump {0} ({1:N1} MB); budget {2} GB" -f $d.Name, ($sz/1MB), $LimitGB)
        } catch { Write-TelemetryLog "retention: could not evict $($d.Name) (in use?), will retry." 'WARN' }
    }
    if ($total -gt $limitBytes) {
        Write-TelemetryLog ("retention: still {0:N1} GB over the {1} GB budget, but all remaining dumps are held/unsent - kept (use Collect for manual handling)." -f (($total-$limitBytes)/1GB), $LimitGB) 'WARN'
    }
}


# =============================== TRIAGE (one dump) =====================
# Full handling for one completed dump: read its signature, run the Tier-2 walk if the kind needs one, compute
# the stable id, record it against the device ledger and get the COLLECT decision, ALWAYS emit one report, then
# act on the decision - 'collect'/'defer' keep the gzipped bytes, 'drop' discards them (still reported). This is
# the slow step (the walk opens the dump) - the monitor runs it in a DETACHED worker, never in its loop.
# Returns @{ Collect; State; Reason; Id; Count; Kind; Leaf; Disposition; KeptPath; EventPath }.
function Invoke-DumpTriage {
    param(
        [Parameter(Mandatory)][string]$DumpPath,
        [string]$ClrMdDll,
        [string]$Dir,
        [string]$BaselinePath,
        [bool]$SuppressKnown = $true,
        [bool]$IsOnline = $false        # a backend endpoint is configured (a grant could come) - drives the known-but-offline drop
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
    # keep the bytes - never hash a multi-GB dump we are about to drop).
    $rawBytes = -1; $rawMtime = $null; $rawSha = $null
    try { $pi = Get-Item -LiteralPath $DumpPath -ErrorAction Stop; $rawBytes = [long]$pi.Length; $rawMtime = $pi.LastWriteTimeUtc.ToString('o') } catch {}
    if ($res.Collect -ne 'drop') { try { $rawSha = (Get-FileHash -LiteralPath $DumpPath -Algorithm SHA256).Hash.ToLowerInvariant() } catch {} }

    $emitPath = (Join-Path $dumpDir $restingName)   # logical final raw name; the flush resolves the .dmp.gz
    if ($res.Collect -eq 'drop') {
        # Discard the bytes (already reported): a recurrence, an already-uploaded id, or a known id offline. Only
        # place the engine deletes a dump; a kept dump is never deleted here - disk is bounded by retention,
        # which only ever evicts dumps the backend already holds.
        foreach ($f in @($DumpPath) + @('.info.txt', '.versions.txt' | ForEach-Object { $DumpPath -replace '\.dmp$', $_ })) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
        $res.Disposition = 'dropped'
    } else {
        # KEEP (collect/defer). Write the FINAL-named <...>.dmp.gz straight from the placeholder (rename + gzip in
        # one), then delete the placeholder. A kept dump always lives compressed (~5x smaller). If the compressor
        # is somehow unavailable or fails, keep the RAW placeholder in place (no rename -> no monitor re-triage).
        $res.Disposition = 'kept'; $res.KeptPath = $DumpPath
        if ((Get-Command Compress-DumpFile -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $DumpPath)) {
            $gz = Compress-DumpFile -SourcePath $DumpPath -DestPath $restingGz -Label $restingName
            if ($gz.Ok) {
                Remove-Item -LiteralPath $DumpPath -Force -ErrorAction SilentlyContinue
                $res.Disposition = 'kept-gz'; $res.KeptPath = $restingGz; $emitPath = $restingGz
            } else {
                Add-DepGap 'gzip-at-rest' ("gzip of $([IO.Path]::GetFileName($DumpPath)) failed: $($gz.Error) - keeping raw placeholder") $Dir
                $emitPath = $DumpPath
                try { [void](Set-LedgerSample -Sig $res.Id -Sample $DumpPath -Dir $Dir) } catch {}   # sample stays the raw placeholder
            }
        } else {
            $emitPath = $DumpPath
            try { [void](Set-LedgerSample -Sig $res.Id -Sample $DumpPath -Dir $Dir) } catch {}
        }
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
