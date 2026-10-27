# Dump engine: local known-issues registry, per-machine dedupe, occurrences log, baseline.


# =============================== LOCAL REGISTRY =========================
# The per-machine known-issues registry on the prod box. Keyed by stable id; each id carries per-machine
# counters so the analyst's offline merge can combine machines under one id. Counts are ABSOLUTE (not
# deltas) so re-merging the same export is idempotent. All read-modify-write goes through a machine-wide
# mutex so the monitor loop and the background triage worker never corrupt the file.

function Get-RegistryPath([string]$Dir) {
    if (-not $Dir) { $Dir = Get-KnownIssuesDir }
    Join-Path $Dir ('registry_{0}.json' -f (Get-MachineKey))
}

function Get-OccurrencesPath([string]$Dir) {
    if (-not $Dir) { $Dir = Get-KnownIssuesDir }
    Join-Path $Dir 'occurrences.jsonl'
}


# PSCustomObject (from ConvertFrom-Json) -> nested [hashtable] so arbitrary id/machine keys are mutable.
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


function Read-LocalRegistry([string]$Dir) {
    $path = Get-RegistryPath $Dir
    if (Test-Path -LiteralPath $path) {
        try {
            $reg = ConvertTo-HashtableDeep ((Get-Content -LiteralPath $path -Raw) | ConvertFrom-Json)
            if (-not $reg.issues) { $reg.issues = @{} }
            if (-not $reg.schemaVersion) { $reg.schemaVersion = 1 }
            return $reg
        } catch { }
    }
    @{ schemaVersion = 1; issues = @{} }
}


function Save-LocalRegistry($Registry, [string]$Dir) {
    if (-not $Dir) { $Dir = Get-KnownIssuesDir }
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $json = $Registry | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath (Get-RegistryPath $Dir) -Value $json -Encoding UTF8
}


# Append one occurrence to the audit log (every event, even suppressed/kept). One JSON object per line.
function Add-Occurrence([hashtable]$Record, [string]$Dir) {
    if (-not $Dir) { $Dir = Get-KnownIssuesDir }
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $line = ($Record | ConvertTo-Json -Depth 5 -Compress)
    Add-Content -LiteralPath (Get-OccurrencesPath $Dir) -Value $line -Encoding UTF8
}


# Is this id already known/analysed from the shipped baseline (ids the analyst has already handled)?
function Test-BaselineKnown([string]$Id, [string]$BaselinePath) {
    if (-not $Id -or -not $BaselinePath -or -not (Test-Path -LiteralPath $BaselinePath)) { return $false }
    try {
        $b = (Get-Content -LiteralPath $BaselinePath -Raw) | ConvertFrom-Json
        $ids = if ($b.issues) { $b.issues.PSObject.Properties.Name } elseif ($b -is [array]) { $b } else { @($b) }
        return [bool]($ids -contains $Id)
    } catch { return $false }
}


# Record one dump against the registry and decide keep vs suppress (keep-first-count-rest).
#   $IdObj : from Get-DumpStableId    $Sig : from Get-DumpSignature
# Returns @{ Action='keep'|'suppress'|'defer'; Reason; Id; Count }.
#  - 'defer'    : id is provisional (walk pending) - never suppress on a provisional id; keep the dump.
#  - 'keep'     : first sample of this id on this machine (or baseline-unknown) - keep the dump.
#  - 'suppress' : a recurrence of an already-kept / already-analysed id - count it, drop the sample.
function Register-DumpOccurrence {
    param(
        [Parameter(Mandatory)]$IdObj,
        [Parameter(Mandatory)]$Sig,
        [Parameter(Mandatory)][string]$DumpPath,
        [string]$Dir,
        [string]$BaselinePath,
        [bool]$SuppressKnown = $true
    )
    if (-not $Dir) { $Dir = Get-KnownIssuesDir }
    $machineKey = Get-MachineKey
    $now = (Get-Date).ToUniversalTime().ToString('o')

    return (Invoke-WithRegistryLock {
        $reg = Read-LocalRegistry $Dir
        $id  = $IdObj.Id
        $provisional = [bool]$IdObj.WalkPending

        if (-not $reg.issues.ContainsKey($id)) {
            $reg.issues[$id] = @{
                kind = $IdObj.Kind; idTier = $(if ($IdObj.Kind -eq 'crash') { 1 } else { 2 }); scheme = $IdObj.Scheme
                signature = @{ code = $Sig.Code; module = $Sig.Module; moduleVersion = $Sig.ModuleVer
                               moduleTimestamp = $Sig.ModuleTs; offset = $(if ($null -ne $Sig.Offset) { '0x{0:x}' -f $Sig.Offset } else { $null })
                               frames = @($Sig.Frames) }
                status = 'open'; firstSeen = $now; lastSeen = $now; totalCount = 0; provisional = $provisional
                machines = @{}
            }
        }
        $issue = $reg.issues[$id]
        $issue.lastSeen = $now
        if ($provisional) { $issue.provisional = $true }

        if (-not $issue.machines.ContainsKey($machineKey)) {
            $issue.machines[$machineKey] = @{ name = $env:COMPUTERNAME; count = 0; firstSeen = $now; lastSeen = $now; sample = $null }
        }
        $m = $issue.machines[$machineKey]
        $m.count = [int]$m.count + 1
        $m.lastSeen = $now

        # recompute absolute total across machines (idempotent on the analyst merge)
        $total = 0; foreach ($mk in $issue.machines.Keys) { $total += [int]$issue.machines[$mk].count }
        $issue.totalCount = $total

        # decision: one dump KEPT per (signature, machine). A different PC = different conditions = independent
        # evidence for the vendor, so the FIRST sample on each machine is kept even when the signature was
        # already analysed elsewhere (baseline) or seen on other machines; baseline-known only annotates the
        # reason (for muting analyst alerts), it no longer suppresses a machine's first sample. Recurrences on
        # the same machine are counted and suppressed.
        $hasSample = [bool]$m.sample -and (Test-Path -LiteralPath "$($m.sample)")
        $baselineKnown = Test-BaselineKnown $id $BaselinePath
        if ($baselineKnown) { $issue.baselineKnown = $true }
        if ($provisional) {
            $action = 'defer'; $reason = 'id provisional (stack walk pending) - keeping dump'
        } elseif (-not $SuppressKnown) {
            $action = 'keep'; $reason = 'suppression disabled'
            if (-not $hasSample) { $m.sample = $DumpPath }
        } elseif ($hasSample) {
            $action = 'suppress'; $reason = 'recurrence (dump already kept on this machine)'
        } else {
            $action = 'keep'; $m.sample = $DumpPath
            $reason = if ($baselineKnown) { 'first sample on this machine (signature already analysed elsewhere)' } else { 'first sample on this machine' }
        }

        Save-LocalRegistry $reg $Dir
        Add-Occurrence @{ ts = $now; id = $id; kind = $IdObj.Kind; machine = $machineKey
                          computer = $env:COMPUTERNAME; pid = $Sig.ProcessId; dump = [IO.Path]::GetFileName($DumpPath)
                          action = $action; reason = $reason; count = $m.count; provisional = $provisional } $Dir
        @{ Action = $action; Reason = $reason; Id = $id; Count = $m.count }
    })
}


# Serialise registry read-modify-write across the monitor + triage worker processes.
function Invoke-WithRegistryLock([scriptblock]$Body) {
    $mtx = New-Object System.Threading.Mutex($false, 'Global\RTKnownIssues')
    $held = $false
    try { $held = $mtx.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $held = $true }
    try { & $Body } finally { if ($held) { try { $mtx.ReleaseMutex() } catch {} }; $mtx.Dispose() }
}

