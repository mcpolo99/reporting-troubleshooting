# Dump engine: triage one dump end-to-end (signature -> walk -> id -> register -> emit event -> suppress).


# =============================== TRIAGE (one dump) =====================
# Full decision for one completed dump: read its signature, run the Tier-2 walk if the kind needs one,
# compute the stable id, record it (keep-first-count-rest, per-machine), and act on the decision -
# recurrences are soft-suppressed (moved to Suppressed\, or deleted). The FIRST sample of an id is always
# kept. Returns the decision plus the id. This is the slow step (the walk opens the dump) - the monitor
# runs it in a DETACHED worker, never in its loop.
function Invoke-DumpTriage {
    param(
        [Parameter(Mandatory)][string]$DumpPath,
        [string]$ClrMdDll,
        [string]$Dir,
        [string]$BaselinePath,
        [bool]$SuppressKnown = $true,
        [ValidateSet('Recycle', 'Delete')][string]$SuppressAction = 'Recycle',
        [string]$SuppressDir
    )
    if (-not (Test-Path -LiteralPath $DumpPath)) { return @{ Action = 'skip'; Reason = 'dump not found' } }
    if (-not $Dir) { $Dir = Get-KnownIssuesDir }
    if (-not $SuppressDir) { $SuppressDir = Join-Path $Dir 'Suppressed' }

    $sig = try { Get-DumpSignature $DumpPath } catch { $null }
    if (-not $sig) { return @{ Action = 'skip'; Reason = 'not a minidump' } }

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
    # A Tier-2 kind (hang / managed exception) with no frames means the managed walk could not run (ClrMD
    # missing or the walk failed) - the id stays provisional and the dump is kept. Record the gap.
    if ($idObj.WalkPending -and $sig.Kind -ne 'crash') {
        Add-DepGap 'tier2-unavailable' ("$($sig.Kind) dump $([IO.Path]::GetFileName($DumpPath)): managed walk unavailable (ClrMD missing or failed) - id provisional, dump kept") $Dir
    }
    $res = Register-DumpOccurrence -IdObj $idObj -Sig $sig -DumpPath $DumpPath -Dir $Dir -BaselinePath $BaselinePath -SuppressKnown $SuppressKnown
    $res.Kind = $sig.Kind
    $res.Leaf = if ($sig.Frames -and $sig.Frames.Count) { $sig.Frames[0] } elseif ($sig.Module) { '{0}+0x{1:x}' -f $sig.Module, $sig.Offset } else { '' }

    # Emit ONE procdump-facts/v1 event for this capture (every event, no exceptions) to the local outbox,
    # while the dump still exists at $DumpPath. Guarded so a missing/failing emitter never breaks triage.
    if (Get-Command Get-DumpFacts -ErrorAction SilentlyContinue) {
        try {
            $facts = Get-DumpFacts -Sig $sig -IdObj $idObj -DumpPath $DumpPath -Decision $res
            $res.EventPath = Write-DumpFactsEvent -Facts $facts -Dir $Dir
        } catch { Add-DepGap 'facts-emit' ("event emission failed for $([IO.Path]::GetFileName($DumpPath)): $($_.Exception.Message)") $Dir }
    }

    if ($res.Action -eq 'suppress') {
        $sidecars = @($DumpPath) + @('.info.txt', '.versions.txt' | ForEach-Object { $DumpPath -replace '\.dmp$', $_ })
        if ($SuppressAction -eq 'Delete') {
            foreach ($f in $sidecars) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
            $res.Disposition = 'deleted'
        } else {
            if (-not (Test-Path -LiteralPath $SuppressDir)) { New-Item -ItemType Directory -Path $SuppressDir -Force | Out-Null }
            $moved = $true
            foreach ($f in $sidecars) {
                if (Test-Path -LiteralPath $f) {
                    try { Move-Item -LiteralPath $f -Destination (Join-Path $SuppressDir ([IO.Path]::GetFileName($f))) -Force -ErrorAction Stop }
                    catch { $moved = $false; $res.MoveError = $_.Exception.Message }
                }
            }
            $res.Disposition = if ($moved) { "moved to $SuppressDir" } else { "SUPPRESS but move failed: $($res.MoveError)" }
        }
    } else {
        $res.Disposition = 'kept'
    }
    return $res
}

