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

    # Record against the ledger and get the bytes decision (collect | drop | defer). Dedup state lives ONLY here.
    $res = Update-DeviceLedger -IdObj $idObj -DumpPath $DumpPath -Dir $Dir -BaselinePath $BaselinePath -SuppressKnown $SuppressKnown -IsOnline $IsOnline
    $res.Kind = $sig.Kind
    $res.Leaf = if ($sig.Frames -and $sig.Frames.Count) { $sig.Frames[0] } elseif ($sig.Module) { '{0}+0x{1:x}' -f $sig.Module, $sig.Offset } else { '' }

    # ALWAYS emit one procdump-facts/v1 report for this capture, while the dump still exists at $DumpPath.
    # Guarded so a missing/failing emitter never breaks triage.
    if (Get-Command Get-DumpFacts -ErrorAction SilentlyContinue) {
        try {
            $facts = Get-DumpFacts -Sig $sig -IdObj $idObj -DumpPath $DumpPath -Decision $res
            $res.EventPath = Write-DumpFactsEvent -Facts $facts -Dir $Dir
        } catch { Add-DepGap 'facts-emit' ("report emission failed for $([IO.Path]::GetFileName($DumpPath)): $($_.Exception.Message)") $Dir }
    }

    if ($res.Collect -eq 'drop') {
        # Discard the bytes (already reported): a recurrence, an already-uploaded id, or a known id offline. The
        # report is enough. This is the only place the engine deletes a dump; a kept dump is never deleted here -
        # disk is bounded by the monitor's size-based retention, which only evicts already-uploaded dumps.
        $sidecars = @($DumpPath) + @('.info.txt', '.versions.txt' | ForEach-Object { $DumpPath -replace '\.dmp$', $_ })
        foreach ($f in $sidecars) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
        $res.Disposition = 'dropped'
    } else {
        # KEEP (collect/defer). gzip the dump at rest NOW, regardless of any server grant: a kept dump always
        # lives compressed in the dump dir (~5x smaller), so an offline box stores far more within its budget and
        # the file is already in the shape the flush uploads. The raw .dmp is replaced by <dump>.dmp.gz; the event
        # carries the RAW sha256/bytes (they describe the original). Guarded: if the compressor is unavailable the
        # raw dump is kept.
        $res.Disposition = 'kept'
        if ((Get-Command Compress-DumpFile -ErrorAction SilentlyContinue) -and ($DumpPath -notmatch '\.gz$') -and (Test-Path -LiteralPath $DumpPath)) {
            $gz = Compress-DumpFile -SourcePath $DumpPath -DestPath ($DumpPath + '.gz') -Label ([IO.Path]::GetFileName($DumpPath))
            if ($gz.Ok) {
                Remove-Item -LiteralPath $DumpPath -Force -ErrorAction SilentlyContinue
                $res.Disposition = 'kept-gz'; $res.KeptPath = $gz.Path
                # the ledger sample now points at the resting .gz, not the raw .dmp
                try { [void](Set-LedgerSample -Sig $res.Id -Sample $gz.Path -Dir $Dir) } catch {}
            } else {
                Add-DepGap 'gzip-at-rest' ("gzip of kept dump $([IO.Path]::GetFileName($DumpPath)) failed: $($gz.Error) - keeping raw") $Dir
                $res.KeptPath = $DumpPath
            }
        } else {
            $res.KeptPath = $DumpPath
        }
    }
    return $res
}
