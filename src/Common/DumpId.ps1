# Shared stable-fault-signature engine. Dot-source it (after Common.ps1). Defines functions only.
#
# Purpose: give every crash/hang/exception dump a STABLE id that is identical iff the fault is the
# same - even across machines and dump files - so already-analysed problems can be deduplicated. The
# id never uses an absolute (ASLR) address; it uses faulting module + offset (native crash) or the
# normalised managed call stack (hang / .NET exception). Tier-1 (module+offset) is computed here by
# a pure byte-parse of the minidump streams - no symbols, no tools, milliseconds even on multi-GB
# dumps. Tier-2 (managed frames) needs a stack-walk tool and is resolved by Invoke-DumpWalk.
#
# The Tier-1 parse mirrors scripts/classify.ps1 in the analysis toolkit byte-for-byte (same module+
# offset), so the prod box and the analyst agree on the id.

# 0xE0434352 = 'CCR' = a managed (.NET CLR) exception. The faulting module/offset then points at the
# CLR, not the app, so a managed exception is identified by its managed stack (Tier-2), not module+offset.
$script:CLR_EXCEPTION_CODE = 0xE0434352

function Get-KnownIssuesDir {
    Join-Path $env:ProgramData 'ReportingTroubleshooting\Monitor\KnownIssues'
}

# Stable, unique per physical machine (survives rename; unlike COMPUTERNAME which can collide/change).
function Get-MachineKey {
    try {
        $g = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
        if ($g) { return "$g".Trim() }
    } catch {}
    return $env:COMPUTERNAME     # last-resort fallback
}

# First 16 hex chars (64 bits) of SHA-256 of the lowercased canonical string. 64 bits is collision-safe
# for this volume and short enough for an issue title.
function Get-ShortHash([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text.ToLowerInvariant())
        $h = $sha.ComputeHash($bytes)
        -join (0..7 | ForEach-Object { '{0:x2}' -f $h[$_] })
    } finally { $sha.Dispose() }
}

# Reads only the small minidump streams (exception, miscinfo/pid, module list) - never the memory body.
# Returns kind + the faulting module/offset + enough signature detail for the registry entry, or $null
# if the file is not a minidump. Mirrors scripts/classify.ps1 Read-Dump.
function Get-DumpSignature([string]$Path) {
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $br = New-Object IO.BinaryReader($fs)
        if ($br.ReadUInt32() -ne 0x504D444D) { return $null }      # 'MDMP'
        [void]$br.ReadUInt32()                                     # version
        $nStreams = $br.ReadUInt32(); $dirRva = $br.ReadUInt32()

        $fs.Position = $dirRva
        $dirs = @(for ($i = 0; $i -lt $nStreams; $i++) { ,@($br.ReadUInt32(), $br.ReadUInt32(), $br.ReadUInt32()) })

        $code = $null; $threadId = $null; $address = $null; $procId = $null
        $modules = @()
        foreach ($d in $dirs) {
            $type = $d[0]; $size = $d[1]; $rva = $d[2]
            if ($type -eq 6 -and $size -ge 40) {                   # ExceptionStream
                $fs.Position = $rva
                $threadId = $br.ReadUInt32(); [void]$br.ReadUInt32()
                $code = $br.ReadUInt32(); [void]$br.ReadUInt32(); [void]$br.ReadUInt64()
                $address = $br.ReadUInt64()
            }
            elseif ($type -eq 15 -and $size -ge 12) {              # MiscInfoStream (flags bit0 => pid valid)
                $fs.Position = $rva
                [void]$br.ReadUInt32(); $flags = $br.ReadUInt32(); $pval = $br.ReadUInt32()
                if ($flags -band 1) { $procId = $pval }
            }
            elseif ($type -eq 4) {                                 # ModuleListStream
                $fs.Position = $rva
                $nMod = $br.ReadUInt32()
                for ($j = 0; $j -lt $nMod; $j++) {
                    $base = $br.ReadUInt64(); $sizeImg = $br.ReadUInt32()
                    [void]$br.ReadUInt32()                         # CheckSum
                    $ts = $br.ReadUInt32()                         # TimeDateStamp
                    $nameRva = $br.ReadUInt32()
                    # VS_FIXEDFILEINFO: dwSignature,dwStrucVersion,dwFileVersionMS,dwFileVersionLS,...
                    [void]$br.ReadUInt32(); [void]$br.ReadUInt32()
                    $verMS = $br.ReadUInt32(); $verLS = $br.ReadUInt32()
                    $fs.Position += (52 - 16) + 8 + 8 + 8 + 8       # rest of VS_FIXEDFILEINFO + Cv + Misc + Reserved0/1
                    $modules += [pscustomobject]@{ Base = $base; Size = $sizeImg; NameRva = $nameRva
                        TimeStamp = $ts; VerMS = $verMS; VerLS = $verLS; Name = $null }
                }
                foreach ($mod in $modules) {
                    $fs.Position = $mod.NameRva
                    $len = $br.ReadUInt32()
                    $full = [Text.Encoding]::Unicode.GetString($br.ReadBytes([int]$len))
                    $mod.Name = [IO.Path]::GetFileNameWithoutExtension($full)
                }
            }
        }

        # resolve the faulting module + offset (never the absolute address)
        $module = $null; $offset = $null; $modVer = $null; $modTs = $null
        if ($address) {
            foreach ($mod in $modules) {
                if ($address -ge $mod.Base -and $address -lt ($mod.Base + $mod.Size)) {
                    $module = $mod.Name; $offset = $address - $mod.Base
                    $modVer = '{0}.{1}.{2}.{3}' -f ($mod.VerMS -shr 16), ($mod.VerMS -band 0xffff), ($mod.VerLS -shr 16), ($mod.VerLS -band 0xffff)
                    $modTs  = '0x{0:x8}' -f $mod.TimeStamp
                    break
                }
            }
        }

        $kind = if ($null -eq $code) { 'hang' }
                elseif ($code -eq $script:CLR_EXCEPTION_CODE) { 'managed-exception' }
                else { 'crash' }

        [pscustomobject]@{
            Kind       = $kind
            Code       = if ($null -ne $code) { '{0:X8}' -f $code } else { $null }
            Module     = $module
            Offset     = $offset
            ModuleVer  = $modVer
            ModuleTs   = $modTs
            Address    = $address
            ProcessId  = $procId
            ThreadId   = $threadId
            Frames     = @()          # filled by Invoke-DumpWalk for Tier-2 kinds
            ExceptionType = $null     # filled by Invoke-DumpWalk for managed-exception dumps
        }
    } finally { $fs.Dispose() }
}

# Builds the canonical id string + short id from a signature. For Tier-2 kinds (hang / managed
# exception) the id needs the managed frames; if $sig.Frames is empty the id is PROVISIONAL (Tier-1
# fallback) and WalkPending is $true - the caller should run Invoke-DumpWalk and recompute.
function Get-DumpStableId($Sig, [int]$TopN = 8) {
    if (-not $Sig) { return $null }
    $walkPending = $false
    switch ($Sig.Kind) {
        'crash' {
            $loc = if ($Sig.Module) { '{0}+0x{1:x}' -f $Sig.Module, $Sig.Offset } else { '0x{0:x}' -f $Sig.Address }
            $canonical = 't1|{0}|{1}' -f $Sig.Code, $loc
        }
        default {
            # hang or managed-exception: identity = the top N normalised managed frames (leaf-first); a
            # managed exception also pins its exception type. These come from Invoke-DumpWalk.
            if ($Sig.Frames -and $Sig.Frames.Count) {
                $top = @($Sig.Frames | Select-Object -First $TopN) -join '|'
                $canonical = if ($Sig.Kind -eq 'hang') { 't2h|{0}' -f $top }
                             else { 't2m|{0}|{1}' -f "$($Sig.ExceptionType)", $top }
            } else {
                # provisional until a stack walk fills Frames - this id MUST NOT be used to suppress
                $walkPending = $true
                $loc = if ($Sig.Module) { '{0}+0x{1:x}' -f $Sig.Module, $Sig.Offset } else { '0x{0:x}' -f $Sig.Address }
                $canonical = 't1prov|{0}|{1}|{2}' -f $Sig.Kind, $Sig.Code, $loc
            }
        }
    }
    [pscustomobject]@{
        Id          = Get-ShortHash $canonical
        Kind        = $Sig.Kind
        Canonical   = $canonical
        WalkPending = $walkPending
    }
}

# =============================== TIER-2 STACK WALK =====================
# Managed stack walk via ClrMD (Microsoft.Diagnostics.Runtime, a single signed net45 DLL). Works on
# .NET Framework dumps using the DAC already installed on the box (bSuite's own CLR). Returns the
# normalised managed frames of the faulting / UI thread so a hang or managed exception gets a stable id.
# This is the SLOW part (opens the dump, loads the DAC) - run it from the background triage worker only,
# never the monitor loop.

$script:ClrMdLoaded = $false

# One managed frame's display string -> 'Namespace.Type.Method' with argument lists and generic
# instantiations stripped (those vary; the method identity does not). Used both for the id hash and the
# human-readable signature frames.
function Normalize-DumpFrame([string]$Display) {
    if (-not $Display) { return $null }
    $s = $Display
    $p = $s.IndexOf('(')                               # drop the argument list
    if ($p -ge 0) { $s = $s.Substring(0, $p) }
    $s = [regex]::Replace($s, '\[\[.*?\]\]', '')       # drop generic instantiations [[System.__Canon, ...]]
    $s = [regex]::Replace($s, '`\d+', '')              # drop arity markers `1
    $s.Trim()
}

# Frames that carry no fault identity (runtime transitions, P/Invoke stubs, async plumbing) - skipped.
function Test-InfraFrame([string]$Norm) {
    if (-not $Norm) { return $true }
    return ($Norm -match '^DomainBoundILStubClass\.IL_STUB' -or
            $Norm -match 'AsyncVoidMethodBuilder\.Start$' -or
            $Norm -match 'AsyncTaskMethodBuilder.*\.Start$' -or
            $Norm -match '^System\.Threading\.ExecutionContext\.Run')
}

# Walk a dump's faulting/UI thread managed stack. Returns @{ Frames=@(normalised, leaf-first);
# ExceptionType; ThreadOSID } or $null if no managed stack could be read (caller then leaves the id
# provisional and keeps the dump).
function Invoke-DumpWalk {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ClrMdDll,
        [int]$TargetOSID = 0,          # OS thread id from the exception stream (managed exception); 0 = auto
        [int]$Max = 40
    )
    if (-not (Test-Path -LiteralPath $ClrMdDll)) { return $null }
    if (-not $script:ClrMdLoaded) {
        try { Add-Type -Path $ClrMdDll -ErrorAction Stop; $script:ClrMdLoaded = $true } catch { return $null }
    }
    $dt = $null
    try {
        $dt = [Microsoft.Diagnostics.Runtime.DataTarget]::LoadCrashDump($Path)
        $clr = $dt.ClrVersions | Select-Object -First 1
        if (-not $clr) { return $null }
        $rt = $clr.CreateRuntime()

        $target = $null; $excType = $null
        if ($TargetOSID) {
            $target = $rt.Threads | Where-Object { $_.OSThreadId -eq [uint32]$TargetOSID } | Select-Object -First 1
        }
        if (-not $target) {   # thread carrying a live managed exception (managed-exception dumps)
            $target = $rt.Threads | Where-Object { $_.CurrentException } | Select-Object -First 1
        }
        if (-not $target) {   # the WPF UI thread = the one pumping the Dispatcher
            $target = $rt.Threads | Where-Object {
                @($_.StackTrace | Where-Object { "$($_.DisplayString)" -match 'System\.Windows\.Threading\.Dispatcher' }).Count
            } | Select-Object -First 1
        }
        if (-not $target) {   # fallback: the thread with the most managed frames
            $target = $rt.Threads | Sort-Object { @($_.StackTrace | Where-Object { $_.Kind -eq [Microsoft.Diagnostics.Runtime.ClrStackFrameType]::ManagedMethod }).Count } -Descending | Select-Object -First 1
        }
        if (-not $target) { return $null }
        if ($target.CurrentException) { $excType = $target.CurrentException.Type.Name }

        $frames = @()
        foreach ($fr in @($target.StackTrace)) {
            if ($fr.Kind -ne [Microsoft.Diagnostics.Runtime.ClrStackFrameType]::ManagedMethod) { continue }
            $n = Normalize-DumpFrame $fr.DisplayString
            if (Test-InfraFrame $n) { continue }
            $frames += $n
            if ($frames.Count -ge $Max) { break }
        }
        @{ Frames = $frames; ExceptionType = $excType; ThreadOSID = $target.OSThreadId }
    } catch {
        return $null
    } finally {
        # Dispose + force finalizers so ClrMD's memory-mapped view of the dump is released; otherwise the
        # file stays locked in this process and a later Move/Delete (suppression) fails with a sharing violation.
        if ($dt) { try { $dt.Dispose() } catch {} }
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    }
}

# =============================== PREREQUISITE VERIFY ===================
# Verify the ENVIRONMENT the Tier-2 walk depends on but does NOT install - the pieces that are assumed to
# already be on a prod box (its own .NET Framework CLR + matching DAC, the system debug engine). A dev box
# has these for other reasons, so the only trustworthy check is to actually walk a real dump ON THAT box.
# Returns an array of @{ Name; Status = OK|FAIL|WARN|SKIP; Detail }.
function Test-DumpWalkPrereqs {
    param([string]$ClrMdDll, [string]$DumpDir, [string]$SampleDump)
    $checks = @()
    $add = { param($n, $s, $d) $script:__c += ,([pscustomobject]@{ Name = $n; Status = $s; Detail = $d }) }
    $script:__c = @()

    # 1) .NET Framework 4.x runtime (needed to run ClrMD and present wherever bSuite runs)
    try {
        $ndp = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop
        if ($ndp.Release) { & $add '.NET Framework 4.x' 'OK' ("Release $($ndp.Release), version $($ndp.Version)") }
        else { & $add '.NET Framework 4.x' 'WARN' 'v4\Full present but no Release value' }
    } catch { & $add '.NET Framework 4.x' 'FAIL' 'not found in registry (NDP\v4\Full)' }

    # 2) system debug engine (built into Windows; ClrMD/cdb use it)
    foreach ($m in 'dbgeng.dll', 'dbghelp.dll') {
        $p = Join-Path $env:SystemRoot "System32\$m"
        if (Test-Path $p) { & $add $m 'OK' $p } else { & $add $m 'WARN' "missing: $p" }
    }

    # 3) a Framework DAC/SOS on disk (ClrMD can also take the DAC from the dump's own path, so this is WARN)
    $dac = @(Get-ChildItem (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64') -Filter 'mscordacwks.dll' -Recurse -ErrorAction SilentlyContinue)
    if ($dac.Count) { & $add 'Framework DAC (mscordacwks)' 'OK' ("$($dac.Count) found, e.g. $($dac[0].FullName)") }
    else { & $add 'Framework DAC (mscordacwks)' 'WARN' 'none on disk - ClrMD will try the DAC referenced by each dump' }

    # 4) ClrMD DLL present and loadable
    if ($ClrMdDll -and (Test-Path -LiteralPath $ClrMdDll)) {
        $sig = (Get-AuthenticodeSignature $ClrMdDll).Status
        try { Add-Type -Path $ClrMdDll -ErrorAction Stop; $script:ClrMdLoaded = $true; & $add 'ClrMD library' 'OK' "loaded ($sig signature)" }
        catch { & $add 'ClrMD library' 'FAIL' "present but failed to load: $($_.Exception.Message)" }
    } else { & $add 'ClrMD library' 'FAIL' 'not installed - install the clrmd package' }

    # 5) THE REAL PROOF: walk an actual dump on this machine
    $sample = $SampleDump
    if (-not $sample -and $DumpDir -and (Test-Path $DumpDir)) {
        $sample = (Get-ChildItem $DumpDir -Filter *.dmp -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
    }
    if (-not $sample) {
        & $add 'Functional walk' 'SKIP' 'no .dmp available to test - capture one dump, then re-verify'
    } elseif (-not ($ClrMdDll -and (Test-Path -LiteralPath $ClrMdDll))) {
        & $add 'Functional walk' 'SKIP' 'ClrMD not installed'
    } else {
        # Auto thread selection (Dispatcher / most-managed) so the test demonstrates a managed walk even
        # when the sample is a crash whose faulting thread is native. The point is: can ClrMD load this
        # machine's CLR and walk managed code at all?
        $name = [IO.Path]::GetFileName($sample)
        $walk = Invoke-DumpWalk -Path $sample -ClrMdDll $ClrMdDll -TargetOSID 0
        if ($walk -and $walk.Frames.Count) {
            & $add 'Functional walk' 'OK' ("{0}: CLR loaded, {1} managed frame(s), leaf '{2}'" -f $name, $walk.Frames.Count, $walk.Frames[0])
        } elseif ($walk) {
            & $add 'Functional walk' 'OK' ("{0}: CLR loaded OK (sample had no managed frames to walk)" -f $name)
        } else {
            & $add 'Functional walk' 'FAIL' ("{0}: ClrMD could not load the CLR (DAC mismatch?) - Tier-2 ids unavailable on this box" -f $name)
        }
    }

    $out = $script:__c; Remove-Variable __c -Scope script -ErrorAction SilentlyContinue
    return $out
}

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
                kind = $IdObj.Kind; idTier = $(if ($IdObj.Kind -eq 'crash') { 1 } else { 2 })
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

        # decision
        $hasSample = [bool]$m.sample -and (Test-Path -LiteralPath "$($m.sample)")
        $baselineKnown = Test-BaselineKnown $id $BaselinePath
        if ($provisional) {
            $action = 'defer'; $reason = 'id provisional (stack walk pending) - keeping dump'
        } elseif (-not $SuppressKnown) {
            $action = 'keep'; $reason = 'suppression disabled'
            if (-not $hasSample) { $m.sample = $DumpPath }
        } elseif ($baselineKnown) {
            $action = 'suppress'; $reason = 'already analysed (baseline)'
        } elseif ($hasSample) {
            $action = 'suppress'; $reason = 'recurrence (first sample already kept on this machine)'
        } else {
            $action = 'keep'; $reason = 'first sample on this machine'; $m.sample = $DumpPath
        }

        Save-LocalRegistry $reg $Dir
        Add-Occurrence @{ ts = $now; id = $id; kind = $IdObj.Kind; machine = $machineKey
                          computer = $env:COMPUTERNAME; pid = $Sig.ProcessId; dump = [IO.Path]::GetFileName($DumpPath)
                          action = $action; reason = $reason; count = $m.count; provisional = $provisional } $Dir
        @{ Action = $action; Reason = $reason; Id = $id; Count = $m.count }
    })
}

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
        if ($walk) { $sig.Frames = $walk.Frames; $sig.ExceptionType = $walk.ExceptionType }
    }

    $idObj = Get-DumpStableId $sig
    $res = Register-DumpOccurrence -IdObj $idObj -Sig $sig -DumpPath $DumpPath -Dir $Dir -BaselinePath $BaselinePath -SuppressKnown $SuppressKnown
    $res.Kind = $sig.Kind
    $res.Leaf = if ($sig.Frames -and $sig.Frames.Count) { $sig.Frames[0] } elseif ($sig.Module) { '{0}+0x{1:x}' -f $sig.Module, $sig.Offset } else { '' }

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

# Serialise registry read-modify-write across the monitor + triage worker processes.
function Invoke-WithRegistryLock([scriptblock]$Body) {
    $mtx = New-Object System.Threading.Mutex($false, 'Global\RTKnownIssues')
    $held = $false
    try { $held = $mtx.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $held = $true }
    try { & $Body } finally { if ($held) { try { $mtx.ReleaseMutex() } catch {} }; $mtx.Dispose() }
}
