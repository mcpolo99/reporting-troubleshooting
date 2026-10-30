# Dump engine: the DEVICE LEDGER - the single local source of truth for dedup, plus the known store reader.
#
# device-ledger.json: { schemaVersion, entries: { <signatureId>: { state, localCount, sample, firstSeenUtc, lastSeenUtc } } }
#   state = 'held'     - bytes kept locally; the backend does NOT have them. Keep + escalate on grant.
#         = 'granted'  - the backend issued an upload grant (obligation outstanding). Keep + upload.
#         = 'uploaded' - the backend CONFIRMED it holds a dump for this (sig, device). Drop further bytes.
# There is NO registry_<guid>.json any more and NO device-profile.json - this one ledger replaces both
# (migrated on first read). It is the ONLY place dedup state lives; the backend profile is MERGED into it,
# never a competing copy. All read-modify-write goes through a machine-wide mutex.


# PSCustomObject (from ConvertFrom-Json) -> nested [hashtable] so arbitrary id keys are mutable.
function ConvertTo-HashtableDeep($obj) {
    if ($null -eq $obj) { return $null }
    if ($obj -is [System.Collections.IDictionary]) {
        $h = @{}; foreach ($k in $obj.Keys) { $h[$k] = ConvertTo-HashtableDeep $obj[$k] }; return $h
    }
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}; foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-HashtableDeep $p.Value }; return $h
    }
    if ($obj -is [object[]]) { return @($obj | ForEach-Object { ConvertTo-HashtableDeep $_ }) }
    return $obj
}

# Serialise ledger read-modify-write across the monitor, triage worker, and flush processes.
function Invoke-WithLedgerLock([scriptblock]$Body) {
    $mtx = New-Object System.Threading.Mutex($false, 'Global\RTDeviceLedger')
    $held = $false
    try { $held = $mtx.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $held = $true }
    try { & $Body } finally { if ($held) { try { $mtx.ReleaseMutex() } catch {} }; $mtx.Dispose() }
}

# One-time migration of pre-ledger stores into the ledger entries map. Imports an old device-profile.json
# ({ sig -> state }) and any registry_*.json (per-machine sample/count) as 'held'/their state, then deletes
# the legacy files. Idempotent and best-effort - never throws.
function Import-LegacyLedger([hashtable]$Entries, [string]$Dir) {
    $now = (Get-Date).ToUniversalTime().ToString('o')
    # old device-profile.json: flat { sig -> 'uploaded'|'granted' }
    $prof = Join-Path $Dir 'device-profile.json'
    if (Test-Path -LiteralPath $prof) {
        try {
            $o = Get-Content -LiteralPath $prof -Raw | ConvertFrom-Json
            if ($o) { foreach ($p in $o.PSObject.Properties) {
                if (-not $Entries.ContainsKey($p.Name)) { $Entries[$p.Name] = @{ state = "$($p.Value)"; localCount = 0; sample = $null; firstSeenUtc = $now; lastSeenUtc = $now } }
            } }
        } catch {}
        Remove-Item -LiteralPath $prof -Force -ErrorAction SilentlyContinue
    }
    # old registry_<guid>.json: { issues: { sig: { machines: { <key>: { count, sample } } } } }
    foreach ($reg in @(Get-ChildItem -LiteralPath $Dir -Filter 'registry_*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $r = ConvertTo-HashtableDeep ((Get-Content -LiteralPath $reg.FullName -Raw) | ConvertFrom-Json)
            $mk = Get-MachineKey
            if ($r.issues) { foreach ($sig in $r.issues.Keys) {
                $m = $r.issues[$sig].machines; $me = if ($m) { $m[$mk] } else { $null }
                $sample = if ($me) { $me.sample } else { $null }
                $count  = if ($me) { [int]$me.count } else { 0 }
                if (-not $Entries.ContainsKey($sig)) {
                    $state = if ($sample) { 'held' } else { 'held' }   # kept sample -> held; the backend profile merge corrects to uploaded
                    $Entries[$sig] = @{ state = $state; localCount = $count; sample = $sample; firstSeenUtc = $now; lastSeenUtc = $now }
                }
            } }
        } catch {}
        Remove-Item -LiteralPath $reg.FullName -Force -ErrorAction SilentlyContinue
    }
}

# Load the ledger as @{ schemaVersion; entries = @{ sig -> @{ state; localCount; sample; firstSeenUtc; lastSeenUtc } } }.
# Migrates legacy stores on first load. Never throws.
function Read-DeviceLedger([string]$Dir) {
    if (-not $Dir) { $Dir = Get-KnownIssuesDir }
    $path = Get-DeviceLedgerPath $Dir
    if (Test-Path -LiteralPath $path) {
        try {
            $l = ConvertTo-HashtableDeep ((Get-Content -LiteralPath $path -Raw) | ConvertFrom-Json)
            if (-not $l.entries) { $l.entries = @{} }
            if (-not $l.schemaVersion) { $l.schemaVersion = 1 }
            return $l
        } catch { }
    }
    $entries = @{}
    try { if (Test-Path -LiteralPath $Dir) { Import-LegacyLedger $entries $Dir } } catch {}
    @{ schemaVersion = 1; entries = $entries }
}

function Save-DeviceLedger($Ledger, [string]$Dir) {
    if (-not $Dir) { $Dir = Get-KnownIssuesDir }
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    ($Ledger | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Get-DeviceLedgerPath $Dir) -Encoding UTF8
}

# The state the ledger holds for a signature, or $null if unseen.
function Get-LedgerState($Ledger, [string]$Sig) {
    if ($Ledger -and $Ledger.entries -and $Ledger.entries.ContainsKey($Sig)) { return "$($Ledger.entries[$Sig].state)" }
    return $null
}


# ---- known store (refs) -------------------------------------------------------------------------------------
# The fleet-wide analysed-signature set, read-only here. One id-extraction (handles the flat-array shape the
# sync writes, and a legacy { issues: {...} } shape). Single source of truth for "is this id known".
function Get-KnownIds([string]$BaselinePath) {
    if (-not $BaselinePath -or -not (Test-Path -LiteralPath $BaselinePath)) { return @() }
    try {
        $b = (Get-Content -LiteralPath $BaselinePath -Raw) | ConvertFrom-Json
        if ($null -eq $b) { @() } elseif ($b.issues) { @($b.issues.PSObject.Properties.Name) } elseif ($b -is [array]) { @($b) } else { @($b) }
    } catch { @() }
}

function Test-BaselineKnown([string]$Id, [string]$BaselinePath) {
    if (-not $Id) { return $false }
    return [bool]((Get-KnownIds $BaselinePath) -contains $Id)
}


# ---- the collect decision (first match wins) ----------------------------------------------------------------
# Record one capture against the ledger and decide what to do with the dump BYTES. Reporting is unconditional
# and handled by the caller; this only bumps the count and returns the bytes decision.
#   Collect = 'collect' (keep the gzipped bytes, escalate on grant) | 'drop' (discard the bytes; still reported)
#           | 'defer'   (id not reliable yet - keep to be safe)
# Decision order (docs/architecture/monitor/07):
#   1 provisional                         -> defer  (keep)
#   2 ledger state = uploaded             -> drop   (backend has ours)
#   3 held/granted and sample on disk     -> drop   (local dedup)
#   4 held/granted and sample gone        -> collect(re-held)
#   5 known/analysed AND offline          -> drop   (no grant can ever come)
#   6 known/analysed AND online           -> collect(held; the grant decides upload)
#   7 otherwise (new here)                -> collect(held; first sample)
function Update-DeviceLedger {
    param(
        [Parameter(Mandatory)]$IdObj,
        [Parameter(Mandatory)][string]$DumpPath,
        [string]$Dir,
        [string]$BaselinePath,
        [bool]$SuppressKnown = $true,
        [bool]$IsOnline = $false
    )
    if (-not $Dir) { $Dir = Get-KnownIssuesDir }
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $id  = $IdObj.Id
    $provisional = [bool]$IdObj.WalkPending

    return (Invoke-WithLedgerLock {
        $ledger = Read-DeviceLedger $Dir
        if (-not $ledger.entries.ContainsKey($id)) {
            $ledger.entries[$id] = @{ state = $null; localCount = 0; sample = $null; firstSeenUtc = $now; lastSeenUtc = $now }
        }
        $e = $ledger.entries[$id]
        $e.localCount = [int]$e.localCount + 1
        $e.lastSeenUtc = $now

        $state      = "$($e.state)"
        $hasSample  = [bool]$e.sample -and (Test-Path -LiteralPath "$($e.sample)")
        $known      = Test-BaselineKnown $id $BaselinePath

        if ($provisional) {
            $collect = 'defer'; $reason = 'id provisional (walk pending) - keeping dump'
        } elseif ($state -eq 'uploaded') {
            $collect = 'drop'; $reason = 'backend already holds a dump for this signature (uploaded)'
        } elseif (($state -eq 'held' -or $state -eq 'granted') -and $hasSample) {
            $collect = 'drop'; $reason = 'recurrence - a sample is already held on this machine'
        } elseif (($state -eq 'held' -or $state -eq 'granted') -and -not $hasSample) {
            $collect = 'collect'; $reason = 'held sample missing - re-acquiring'
        } elseif ($SuppressKnown -and $known -and -not $IsOnline) {
            $collect = 'drop'; $reason = 'known/analysed and offline - no grant can come'
        } elseif ($SuppressKnown -and $known -and $IsOnline) {
            $collect = 'collect'; $reason = 'known/analysed but online - hold one; the grant decides upload'
        } else {
            $collect = 'collect'; $reason = 'first sample on this machine'
        }

        # On keep (collect/defer): state becomes held unless the backend already granted; record the sample.
        if ($collect -ne 'drop') {
            if ($state -ne 'granted') { $e.state = 'held' }
            $e.sample = $DumpPath
        }

        Save-DeviceLedger $ledger $Dir
        @{ Collect = $collect; State = "$($e.state)"; Reason = $reason; Id = $id; Count = $e.localCount }
    })
}

# Merge the backend profile into the ledger (Sync, read-only reconcile). Backend state overlays local state
# WITHOUT clobbering local 'held': backend 'uploaded' wins (local copy becomes freeable), backend 'granted'
# sets granted if we still hold the dump; a signature the backend does not mention keeps its local state.
# $BackendEntries is @{ sig -> 'uploaded'|'granted' }. Returns @{ Count; FreeSamples=@(paths to delete) }.
function Merge-BackendProfile {
    param([hashtable]$BackendEntries, [string]$Dir)
    if (-not $Dir) { $Dir = Get-KnownIssuesDir }
    $now = (Get-Date).ToUniversalTime().ToString('o')
    return (Invoke-WithLedgerLock {
        $ledger = Read-DeviceLedger $Dir
        $free = @()
        foreach ($sig in @($BackendEntries.Keys)) {
            $bs = "$($BackendEntries[$sig])"
            if (-not $ledger.entries.ContainsKey($sig)) {
                $ledger.entries[$sig] = @{ state = $bs; localCount = 0; sample = $null; firstSeenUtc = $now; lastSeenUtc = $now }
                continue
            }
            $e = $ledger.entries[$sig]
            if ($bs -eq 'uploaded') {
                if ($e.sample) { $free += "$($e.sample)"; $e.sample = $null }
                $e.state = 'uploaded'
            } elseif ($bs -eq 'granted' -and $e.state -ne 'uploaded') {
                $e.state = 'granted'
            }
        }
        Save-DeviceLedger $ledger $Dir
        @{ Count = @($ledger.entries.Keys).Count; FreeSamples = @($free) }
    })
}

# Point a signature's kept sample at its final resting path (e.g. after gzip renamed the dump to .dmp.gz).
function Set-LedgerSample {
    param([string]$Sig, [string]$Sample, [string]$Dir)
    if (-not $Sig) { return }
    if (-not $Dir) { $Dir = Get-KnownIssuesDir }
    Invoke-WithLedgerLock {
        $ledger = Read-DeviceLedger $Dir
        if ($ledger.entries.ContainsKey($Sig)) { $ledger.entries[$Sig].sample = $Sample; Save-DeviceLedger $ledger $Dir }
    }
}

# Mark a signature uploaded after a confirmed upload (Flush). Frees the local sample path (returned to delete).
function Set-LedgerUploaded {
    param([string]$Sig, [string]$Dir)
    if (-not $Sig) { return $null }
    if (-not $Dir) { $Dir = Get-KnownIssuesDir }
    return (Invoke-WithLedgerLock {
        $ledger = Read-DeviceLedger $Dir
        $freed = $null
        if ($ledger.entries.ContainsKey($Sig)) {
            $e = $ledger.entries[$Sig]
            if ($e.sample) { $freed = "$($e.sample)" }
            $e.sample = $null; $e.state = 'uploaded'
        } else {
            $ledger.entries[$Sig] = @{ state = 'uploaded'; localCount = 0; sample = $null; firstSeenUtc = (Get-Date).ToUniversalTime().ToString('o'); lastSeenUtc = (Get-Date).ToUniversalTime().ToString('o') }
        }
        Save-DeviceLedger $ledger $Dir
        $freed
    })
}
