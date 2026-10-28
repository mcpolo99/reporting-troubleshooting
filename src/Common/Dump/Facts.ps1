# Dump engine: per-event fact emitter. Turns one triaged dump into ONE self-contained `procdump-facts/v1`
# JSON event and writes it to the local outbox (KnownIssues\outbox\<eventId>.json), one blob per capture -
# no exceptions. The event leads with a `diagnosis` (the plain-language verdict from Diagnosis.ps1) and
# carries every MEASURED fact the edge can read (ids, class, exception, faulting location, managed chain,
# module versions, environment, integrity) plus the triage decision. It is the Layer-1 "facts" half of a
# vendor report; Layer-2 judgement (requests, architectural standard, severity wording) is authored once
# per signature and merged by the renderer. Fields that need public Microsoft tools at the centre (full
# native stack, heap-failure record, per-thread table) are left null and noted - central cdb enrichment
# fills them later, keyed by the same ids.
#
# SCHEMA IS FROZEN. Changing `procdump-facts/v1` or the signature recipe (Signature.ps1 Get-DumpStableId)
# breaks historical grouping - bump the version instead.

$script:FACTS_SCHEMA = 'procdump-facts/v1'

# Outbox: one JSON per event, drained later by the transport (Vector -> POST /v1/events). Until then it
# is the local record of every event.
function Get-OutboxDir([string]$Dir) {
    if (-not $Dir) { $Dir = Get-KnownIssuesDir }
    Join-Path $Dir 'outbox'
}

# Sortable, unique per event: UTC timestamp (ms) + 8 random hex. Not a dedup key (that is signatureId).
function New-DumpEventId {
    '{0}-{1}' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmssfff'),
                 (-join (1..4 | ForEach-Object { '{0:x2}' -f (Get-Random -Minimum 0 -Maximum 256) }))
}

# Identifies the specific capture (not the fault): distinguishes ProcDump's repeated writes of the same
# stop from genuinely separate events. Per-thread CPU times would strengthen it but are not in the header.
function Get-DumpCaptureId($Sig) {
    if (-not $Sig) { return $null }
    $addr = if ($null -ne $Sig.Address) { '{0:x}' -f $Sig.Address } else { '' }
    Get-ShortHash ('{0}|{1}|{2}|{3}' -f $Sig.ProcessId, $Sig.ThreadId, $addr, $Sig.Code)
}

# Severity from measured facts only, no per-code list. A crash is high when its exception code has NTSTATUS
# error severity (top two bits set) - dynamic, covers every code. Managed exceptions and hangs (ProcDump's
# -h fires only once a window is unresponsive past its threshold, i.e. already user-visible) are high too.
function Get-DumpSeverity($Sig) {
    if ($Sig.Kind -eq 'crash') { if (Test-FatalExceptionCode $Sig.Code) { return 'high' } else { return 'medium' } }
    if ($Sig.Kind -eq 'managed-exception' -or $Sig.Kind -eq 'hang') { return 'high' }
    return 'medium'
}

# This machine's environment (the edge runs on the box that captured, so machine OS = dump OS).
function Get-MachineEnvironment {
    $os = $null
    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $ver = "$([Environment]::OSVersion.Version)"
        $disp = if ($cv.DisplayVersion) { $cv.DisplayVersion } elseif ($cv.ReleaseId) { $cv.ReleaseId } else { $null }
        $os = ('{0}{1} ({2})' -f $cv.ProductName, $(if ($disp) { " $disp" } else { '' }), $ver)
    } catch { $os = "$([Environment]::OSVersion.VersionString)" }
    [ordered]@{ os = $os; cpus = [Environment]::ProcessorCount; arch = $env:PROCESSOR_ARCHITECTURE }
}

# Build the `procdump-facts/v1` event from an already-triaged dump. Reuses $Sig (Get-DumpSignature, with
# any Invoke-DumpWalk frames merged in) and $IdObj (Get-DumpStableId); does not re-open the dump except to
# hash it, and only hashes when the dump will be escalated (first sample / provisional) - never for a
# suppressed recurrence whose dump is about to be dropped.
function Get-DumpFacts {
    param(
        [Parameter(Mandatory)]$Sig,
        [Parameter(Mandatory)]$IdObj,
        [Parameter(Mandatory)][string]$DumpPath,
        $Decision,                 # from Register-DumpOccurrence: @{ Action; Count; ... }
        [string]$DumpTool,
        [string]$DumpType,
        [string]$Sha256            # precomputed hash to reuse (re-analysis) - avoids re-hashing a multi-GB dump
    )
    $action = if ($Decision) { "$($Decision.Action)" } else { 'keep' }
    $escalate = ($action -ne 'suppress')                 # upload the dump only on first sample / provisional
    $occ = if ($Decision) { [int]$Decision.Count } else { 1 }   # this machine's occurrence count for the signature
    $confidence = if ($IdObj.WalkPending) { 'low' } else { 'high' }
    $diag = Get-DumpDiagnosis $Sig

    $fi = $null; try { $fi = Get-Item -LiteralPath $DumpPath -ErrorAction Stop } catch {}

    # Computer: prefer what the DUMP records (ProcDump comment on newer dumps, else the ".info.txt" sidecar
    # beside it) over this host - so an off-box re-scan reports the machine that captured, not the analyst box.
    # The stable deviceId (MachineGuid) only exists for THIS host; if the dump is from another machine we do
    # not know its guid, so leave it null rather than stamp the wrong one.
    $hostComputer = $env:COMPUTERNAME
    $dumpComputer = $null
    if ($Sig.ProcDumpComment -and $Sig.ProcDumpComment -match '(?im)^\s*computer\s*[:=]\s*(\S+)') { $dumpComputer = $matches[1] }
    if (-not $dumpComputer) {
        $info = $DumpPath -replace '\.dmp$', '.info.txt'
        if (Test-Path -LiteralPath $info) {
            try {
                $m = Select-String -LiteralPath $info -Pattern '^\s*Computer\s*[:=]\s*(\S+)' -ErrorAction Stop | Select-Object -First 1
                if ($m) { $dumpComputer = $m.Matches[0].Groups[1].Value }
            } catch {}
        }
    }
    $computer = if ($dumpComputer) { $dumpComputer } else { $hostComputer }
    $computerSource = if ($dumpComputer) { 'dump' } else { 'host' }
    $offBox = $dumpComputer -and ($dumpComputer -ne $hostComputer)
    # deviceId is the fleet key and MUST be derivable from the dump - use the machine name the dump records
    # (for this fleet that is the unique machine number). The stable MachineGuid is only knowable live on the
    # capturing PC, so it rides along as extra identity when on-box, never as the primary key.
    $deviceId = $computer
    $machineGuid = if (-not $offBox) { Get-MachineKey } else { $null }
    $sha = $null
    if ($escalate -and $fi) {
        if ($Sha256) { $sha = $Sha256.ToLowerInvariant() }
        else { try { $sha = (Get-FileHash -LiteralPath $DumpPath -Algorithm SHA256).Hash.ToLowerInvariant() } catch {} }
    }

    # Build arrays with STATEMENT-FORM assignments. Windows PowerShell 5.1 unwraps a single-element array
    # returned from an `if`-expression (or a $() subexpression) to a scalar, which would emit `"x"` instead
    # of `["x"]`; a direct `$x = @(...)` keeps it an array. A native crash has only the faulting location at
    # the edge (full native stack is central cdb enrichment).
    $frames = @()
    if ($Sig.Frames) { $frames = @($Sig.Frames) }
    $faultLoc = if ($Sig.Module) { '{0}+0x{1:x}' -f $Sig.Module, $Sig.Offset } elseif ($null -ne $Sig.Address) { '0x{0:x}' -f $Sig.Address } else { $null }
    $faultStack = $frames
    if ($Sig.Kind -eq 'crash' -and $faultLoc) { $faultStack = @($faultLoc) }

    $modules = @()
    if ($Sig.Module)    { $modules += [ordered]@{ name = $Sig.Module;    version = $Sig.ModuleVer; timestamp = $Sig.ModuleTs; role = 'faulting' } }
    if ($Sig.ImageName) { $modules += [ordered]@{ name = $Sig.ImageName;  version = $Sig.ImageVer;  timestamp = $null;        role = 'image' } }
    if ($Sig.ClrName)   { $modules += [ordered]@{ name = $Sig.ClrName;    version = $Sig.ClrVer;    timestamp = $null;        role = 'clr' } }

    $notes = @()
    if ($Sig.Kind -eq 'crash') { $notes += 'native stack, nearest-export names and any heap-failure record require central cdb enrichment (not read at the edge)' }
    if ($IdObj.WalkPending)    { $notes += 'managed stack walk unavailable (ClrMD missing or failed) - signature is provisional, dump kept for central analysis' }

    # Environment: prefer values read from the DUMP (correct wherever analysis runs); fall back to this machine
    # (valid only when analysis runs on the box that captured). Keep both friendly OS and the dump build.
    $hostEnv = Get-MachineEnvironment
    $environment = [ordered]@{
        os    = if ($Sig.Os) { $Sig.Os } else { $hostEnv.os }
        cpus  = if ($null -ne $Sig.Cpus) { [int]$Sig.Cpus } else { $hostEnv.cpus }
        arch  = if ($Sig.Arch) { $Sig.Arch } else { $hostEnv.arch }
        osSource = if ($Sig.Os) { 'dump' } else { 'host' }
    }

    [ordered]@{
        schema       = $script:FACTS_SCHEMA
        emittedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        # Top-level index-projection keys the wire contract reads (polos-ab-infra CONTRACT.md 7). signatureId
        # is LOAD-BEARING: first-seen detection and the dump-upload grant (5a) key off this exact top-level
        # field, so it is mirrored here as well as in ids. class/severity are already top-level below.
        # Passthrough/additive - does NOT change the signature recipe or grouping (schema stays v1).
        signatureId    = $IdObj.Id
        deviceId       = $deviceId
        productVersion = $Sig.ImageVer
        capturedAtUtc  = $(if ($fi) { $fi.LastWriteTimeUtc.ToString('o') } else { $null })
        ids          = [ordered]@{
            eventId            = (New-DumpEventId)
            deviceId           = $deviceId
            deviceSource       = $computerSource
            computer           = $computer
            machineGuid        = $machineGuid
            signatureId        = $IdObj.Id
            signatureScheme    = $IdObj.Scheme
            signatureCanonical = $IdObj.Canonical
            signatureTier      = $(if ($Sig.Kind -eq 'crash') { 1 } else { 2 })
            captureId          = (Get-DumpCaptureId $Sig)
            dumpObjectKey      = $null                 # set when the dump is uploaded to the silo (Phase 1)
        }
        diagnosis    = $diag                           # the plain-language verdict - read this first
        class          = $Sig.Kind
        captureReason  = $diag.captureReason
        captureComment = $Sig.ProcDumpComment
        confidence     = $confidence
        severity       = (Get-DumpSeverity $Sig)
        isNewSignature = ($action -ne 'suppress')
        escalateDump   = $escalate
        occurrenceCount = $(if ($Decision) { $occ } else { $null })
        product      = [ordered]@{ image = $Sig.ImageName; imageVersion = $Sig.ImageVer }
        environment  = $environment
        dump         = [ordered]@{
            file         = [IO.Path]::GetFileName($DumpPath)
            path         = $(if ($fi) { $fi.FullName } else { $DumpPath })   # absolute source path, so the flusher finds the dump even when its DumpDir differs from where the capture landed (#42)
            bytes        = $(if ($fi) { $fi.Length } else { $null })
            sha256       = $sha
            writtenLocal = $(if ($fi) { $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') } else { $null })
        }
        process      = [ordered]@{ pid = $Sig.ProcessId; faultThreadId = $Sig.ThreadId }
        exception    = [ordered]@{
            code    = $(if ($Sig.Code) { '0x{0}' -f $Sig.Code } else { $null })
            name    = (Get-ExceptionName $Sig.Code)
            address = $(if ($null -ne $Sig.Address) { '0x{0:x}' -f $Sig.Address } else { $null })
        }
        exceptionType     = $Sig.ExceptionType
        faultingLocation  = $faultLoc
        faultStack        = $faultStack
        managedChain      = $frames
        managedChainOrder = 'leaf-first'
        nativeStackComplete = $false
        modules      = $modules
        notes        = $notes
    }
}

# Atomically write one event to the outbox (temp file + move, so a drainer never reads a partial file).
# Returns the event path, or $null on failure (emission must never break triage).
function Write-DumpFactsEvent {
    param([Parameter(Mandatory)]$Facts, [string]$Dir)
    try {
        $outbox = Get-OutboxDir $Dir
        if (-not (Test-Path -LiteralPath $outbox)) { New-Item -ItemType Directory -Path $outbox -Force | Out-Null }
        $name = '{0}.json' -f $Facts.ids.eventId
        $final = Join-Path $outbox $name
        $tmp = '{0}.tmp' -f $final
        $json = $Facts | ConvertTo-Json -Depth 8
        Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $final -Force
        return $final
    } catch { return $null }
}
