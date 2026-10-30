# Dump engine: triage one dump end-to-end (signature -> walk -> id -> ledger decision -> report -> collect/drop).


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

    $sig = try { Get-DumpSignature $DumpPath } catch { $null }
    if (-not $sig) { return @{ Collect = 'skip'; Reason = 'not a minidump' } }

    # Tier-2 kinds (hang, managed exception) need the managed stack to get a stable id.
    if ($sig.Kind -ne 'crash' -and $ClrMdDll -and (Test-Path -LiteralPath $ClrMdDll)) {
        $tos = if ($sig.ThreadId) { [int]$sig.ThreadId } else { 0 }
        $walk = Invoke-DumpWalk -Path $DumpPath -ClrMdDll $ClrMdDll -TargetOSID $tos
        if ($walk) {
            $sig.Frames = $walk.Frames; $sig.ExceptionType = $walk.ExceptionType
            if (-not $sig.ThreadId -and $walk.ThreadOSID) { $sig.ThreadId = $walk.ThreadOSID }   # hang: the walked UI/dispatcher thread
            $sig.UiConfirmed = [bool]$walk.UiConfirmed; $sig.DispatcherFrame = $walk.DispatcherFrame
            $sig.AppFrame = $walk.AppFrame; $sig.AppFrameDepth = [int]$walk.AppFrameDepth
            $sig.StormOperations = @($walk.StormOperations); $sig.StormDominantFrame = $walk.StormDominantFrame
            $sig.StormDominantCount = [int]$walk.StormDominantCount; $sig.StackDepth = [int]$walk.StackDepth
        }
    }

    $idObj = Get-DumpStableId $sig
    # A Tier-2 kind with no frames means the managed walk could not run (ClrMD missing or failed) - the id stays
    # provisional and the dump is kept (defer). Record the gap.
    if ($idObj.WalkPending -and $sig.Kind -ne 'crash') {
        Add-DepGap 'tier2-unavailable' ("$($sig.Kind) dump $([IO.Path]::GetFileName($DumpPath)): managed walk unavailable (ClrMD missing or failed) - id provisional, dump kept") $Dir
    }

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
