# Dump engine: ClrMD managed stack walk + bitness dispatch + dependency checks (the slow, tool-backed part).


# =============================== BITNESS DISPATCH ======================
# ClrMD loads the target's DAC as a NATIVE library into the host process, so the host must be the SAME
# bitness as the target - attaching to / walking a 32-bit target from 64-bit PowerShell throws
# "Dac architecture mismatch!" (and vice versa). These helpers detect the target bitness and re-run the
# ClrMD work in the matching-bitness Windows PowerShell host.

$script:HostBits = if ([Environment]::Is64BitProcess) { 64 } else { 32 }


# Live process bitness: 32 if it's a WOW64 (32-bit) process on a 64-bit OS, else matches the OS.
Add-Type -Namespace RT -Name Wow -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool IsWow64Process(System.IntPtr h, out bool wow);
'@ -ErrorAction SilentlyContinue

function Get-ProcessBitness([int]$ProcessId) {
    if (-not [Environment]::Is64BitOperatingSystem) { return 32 }
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        $wow = $false
        if ([RT.Wow]::IsWow64Process($p.Handle, [ref]$wow)) { return $(if ($wow) { 32 } else { 64 }) }
    } catch {}
    return 0
}


# Run a ClrMD-using command in the matching-bitness Windows PowerShell host and parse its JSON stdout. The
# child dot-sources this file and sets RT_BITNESS_REDIR=1 so it runs the work in-process (no further hop).
function Invoke-InMatchingHost([int]$Bits, [string]$Command) {
    $sub = if ($Bits -eq 32) { 'SysWOW64' } else { 'System32' }
    $exe = Join-Path $env:SystemRoot "$sub\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path $exe) -or -not $script:DumpIdPath) { return $null }
    $full = ". `"$script:DumpIdPath`"; `$env:RT_BITNESS_REDIR='1'; $Command"
    try {
        $out = & $exe -NoProfile -ExecutionPolicy Bypass -Command $full 2>$null
        if (-not $out) { return $null }
        return (($out -join "`n") | ConvertFrom-Json)
    } catch { return $null }
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

# Is this a .NET / WPF framework (or runtime) frame, i.e. NOT the analysed application's own code? A frame
# that is only framework does not by itself implicate the vendor; the APPLICATION frame driving it does.
# Classified by namespace root (framework/runtime only) - everything else (vendor code, native-interop
# wrappers, third-party libraries the vendor ships) counts as application. No per-vendor names hardcoded.
function Test-FrameworkFrame([string]$Norm) {
    if (-not $Norm) { return $true }
    return ($Norm -match '^(System\.|Microsoft\.|MS\.Internal|MS\.Win32|Windows\.|Presentation(Core|Framework)|WindowsBase|mscorlib|netstandard|Internal\.|<CrtImplementationDetails>|Accessibility\.)')
}

# Process bootstrap / message-pump roots - application frames that are ALWAYS present and do no real work, so
# they must NOT be reported as "the application code driving the hang". If the only non-framework frame on the
# stack is one of these, the UI thread is churning framework code with no active application work (weaker
# attribution - say so, don't name Main).
function Test-BootstrapFrame([string]$Norm) {
    if (-not $Norm) { return $true }
    return ($Norm -match '(\.Main$|EntryPoint|Application\.Run$|\.RunInternal$|\.RunDispatcher$)')
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
    # Match host bitness to the dump's architecture (ClrMD loads the DAC as native code). If the dump is a
    # different bitness than this host, redo the walk in the matching-bitness PowerShell and take its result.
    if ($env:RT_BITNESS_REDIR -ne '1') {
        $tb = Get-DumpBitness $Path
        if ($tb -and $tb -ne $script:HostBits) {
            $cmd = "Invoke-DumpWalk -Path '$Path' -ClrMdDll '$ClrMdDll' -TargetOSID $TargetOSID -Max $Max | ConvertTo-Json -Depth 8 -Compress"
            $j = Invoke-InMatchingHost -Bits $tb -Command $cmd
            if ($j) {
                $fr = if ($j.Frames) { @($j.Frames) } else { @() }
                return @{ Frames = $fr; ExceptionType = $j.ExceptionType; ThreadOSID = $j.ThreadOSID; UiConfirmed = [bool]$j.UiConfirmed
                          DispatcherFrame = $j.DispatcherFrame; AppFrame = $j.AppFrame; AppFrameDepth = [int]$j.AppFrameDepth
                          StormOperations = @($j.StormOperations); StormDominantFrame = $j.StormDominantFrame; StormDominantCount = [int]$j.StormDominantCount; StackDepth = [int]$j.StackDepth }
            }
            return $null
        }
    }
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

        # Scan the FULL stack (before truncation) for two things that survive the $Max cut:
        #  - the Dispatcher root -> proves the thread is the WPF UI thread
        #  - the application frame nearest the leaf -> the vendor's own code driving the work (what actually
        #    implicates the software; a framework-only stack does not).
        $uiConfirmed = $false; $dispFrame = $null; $appFrame = $null; $appDepth = 0
        $freq = @{}; $depth = 0                         # frame frequency + true managed depth (whole stack)
        foreach ($fr in @($target.StackTrace)) {
            if ($fr.Kind -ne [Microsoft.Diagnostics.Runtime.ClrStackFrameType]::ManagedMethod) { continue }
            $ds = "$($fr.DisplayString)"
            if (-not $uiConfirmed -and $ds -match 'System\.Windows\.Threading\.Dispatcher\.(Run|PushFrame|PushFrameImpl|InvokeImpl|ProcessQueue)') {
                $uiConfirmed = $true; $dispFrame = Normalize-DumpFrame $ds
            }
            $n = Normalize-DumpFrame $ds
            if ($n -and -not (Test-InfraFrame $n)) {
                $depth++
                $freq[$n] = [int]$freq[$n] + 1
                # appFrame = nearest-leaf application frame; appDepth = its 1-based position (1 = leaf). A large
                # depth means the app frame only TRIGGERED a framework storm, it is not what is executing now.
                if (-not $appFrame -and -not (Test-FrameworkFrame $n) -and -not (Test-BootstrapFrame $n)) { $appFrame = $n; $appDepth = $depth }
            }
        }
        # classify the dominant framework activity ("storm") and its recursion depth - the dump-backed WHY for a
        # framework-only hang (a deep repeating WPF pass = an oversized/over-nested UI or a mass re-bind).
        $stormOps = @()
        $allText = ($freq.Keys -join '|')
        if ($allText -match 'DescendentsWalker|TreeWalkHelper') { $stormOps += 'visual-tree-walk' }
        if ($allText -match 'BindingExpression|PropertyPathWorker|ClrBindingWorker|DataBindEngine') { $stormOps += 'data-binding' }
        if ($allText -match 'ResourceDictionary|FindResource|ResourceReferenceExpression') { $stormOps += 'resource-lookup' }
        if ($allText -match 'MeasureOverride|ArrangeOverride|MeasureCore|ArrangeCore|ContextLayoutManager|UpdateLayout') { $stormOps += 'layout' }
        $dom = $null; $domN = 0
        foreach ($k in $freq.Keys) { if ((Test-FrameworkFrame $k) -and [int]$freq[$k] -gt $domN) { $dom = $k; $domN = [int]$freq[$k] } }
        # Collect the WHOLE managed stack leaf-first (no omission) so every frame is visible - the deep WPF
        # recursion AND the vendor root. $Max is the soft intent; $hardCap is a safety bound for a pathological
        # stack. The compact view (what repeats, how deep) lives in the structured storm fields, not by hiding
        # frames here.
        $hardCap = [Math]::Max($Max, 400)
        $frames = @()
        foreach ($fr in @($target.StackTrace)) {
            if ($fr.Kind -ne [Microsoft.Diagnostics.Runtime.ClrStackFrameType]::ManagedMethod) { continue }
            $n = Normalize-DumpFrame $fr.DisplayString
            if (Test-InfraFrame $n) { continue }
            $frames += $n
            if ($frames.Count -ge $hardCap) { break }
        }
        @{ Frames = $frames; ExceptionType = $excType; ThreadOSID = $target.OSThreadId; UiConfirmed = $uiConfirmed
           DispatcherFrame = $dispFrame; AppFrame = $appFrame; AppFrameDepth = $appDepth
           StormOperations = $stormOps; StormDominantFrame = $dom; StormDominantCount = $domN; StackDepth = $depth }
    } catch {
        return $null
    } finally {
        # Dispose + force finalizers so ClrMD's memory-mapped view of the dump is released; otherwise the
        # file stays locked in this process and a later Move/Delete (suppression) fails with a sharing violation.
        if ($dt) { try { $dt.Dispose() } catch {} }
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    }
}


# Append a capability gap to KnownIssues\gaps.jsonl - things the tool could not do on this machine (a
# missing walk tool, an unsupported runtime, an attach failure). Surfaces what to improve.
function Add-DepGap([string]$Area, [string]$Detail, [string]$Dir) {
    if (-not $Dir) { $Dir = Get-KnownIssuesDir }
    try {
        if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
        $rec = @{ ts = (Get-Date).ToUniversalTime().ToString('o'); machine = (Get-MachineKey); computer = $env:COMPUTERNAME; area = $Area; detail = $Detail }
        Add-Content -LiteralPath (Join-Path $Dir 'gaps.jsonl') -Value ($rec | ConvertTo-Json -Compress) -Encoding UTF8
    } catch {}
}


# Passively attach to a LIVE process (read-only, no suspend, no dump) and try to create its CLR runtime -
# the no-dump proof that this machine can fault-identify that app. Returns @{ Managed; Flavor; Clr; Ok; Error }.
function Test-AppWalkable([int]$ProcessId, [string]$ClrMdDll) {
    if (-not ($ClrMdDll -and (Test-Path -LiteralPath $ClrMdDll))) { return @{ Managed = $null; Ok = $false; Error = 'ClrMD not downloaded' } }
    # A 32-bit app can only be attached from a 32-bit host (and vice versa) - the DAC loads as native code.
    if ($env:RT_BITNESS_REDIR -ne '1') {
        $tb = Get-ProcessBitness $ProcessId
        if ($tb -and $tb -ne $script:HostBits) {
            $cmd = "Test-AppWalkable -ProcessId $ProcessId -ClrMdDll '$ClrMdDll' | ConvertTo-Json -Compress"
            $j = Invoke-InMatchingHost -Bits $tb -Command $cmd
            if ($j) { return @{ Managed = $j.Managed; Flavor = $j.Flavor; Clr = $j.Clr; Ok = $j.Ok; Error = $j.Error } }
            return @{ Managed = $null; Ok = $false; Error = "could not probe in $tb-bit host" }
        }
    }
    if (-not $script:ClrMdLoaded) { try { Add-Type -Path $ClrMdDll -ErrorAction Stop; $script:ClrMdLoaded = $true } catch { return @{ Managed = $null; Ok = $false; Error = "ClrMD load failed: $($_.Exception.Message)" } } }
    $dt = $null
    try {
        $dt = [Microsoft.Diagnostics.Runtime.DataTarget]::AttachToProcess($ProcessId, 5000, [Microsoft.Diagnostics.Runtime.AttachFlag]::Passive)
        $clr = $dt.ClrVersions | Select-Object -First 1
        if (-not $clr) { return @{ Managed = $false; Flavor = 'native'; Ok = $true } }   # no CLR = unmanaged; crash ids via module+offset
        try { [void]$clr.CreateRuntime(); return @{ Managed = $true; Flavor = "$($clr.Flavor)"; Clr = "$($clr.Version)"; Ok = $true } }
        catch { return @{ Managed = $true; Flavor = "$($clr.Flavor)"; Clr = "$($clr.Version)"; Ok = $false; Error = $_.Exception.Message } }
    } catch {
        return @{ Managed = $null; Ok = $false; Error = $_.Exception.Message }
    } finally {
        if ($dt) { try { $dt.Dispose() } catch {} }
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    }
}


# Verify the fault-id capability for the MONITORED APPS on this machine - WITHOUT needing a dump. Checks the
# base deps (ClrMD, debug engine), then for each app detects its runtime from the live process and proves the
# walker can load it (passive attach). Logs any gap. Returns rows @{ Name; Status = OK|FAIL|WARN|SKIP; Detail }.
function Test-MonitorDependencies {
    param([string[]]$Apps, [string]$ClrMdDll, [string]$Dir)
    $rows = @()
    # base: walker + system debug engine
    if ($ClrMdDll -and (Test-Path -LiteralPath $ClrMdDll)) {
        $sig = (Get-AuthenticodeSignature $ClrMdDll).Status
        $rows += [pscustomobject]@{ Name = 'ClrMD walker'; Status = 'OK'; Detail = "downloaded ($sig signature)" }
    } else {
        $rows += [pscustomobject]@{ Name = 'ClrMD walker'; Status = 'FAIL'; Detail = 'not downloaded - download it on the Packages tab (needed for hang/managed ids)' }
        Add-DepGap 'clrmd-missing' 'ClrMD walker not downloaded' $Dir
    }
    $dbg = Join-Path $env:SystemRoot 'System32\dbgeng.dll'
    $rows += [pscustomobject]@{ Name = 'Debug engine'; Status = $(if (Test-Path $dbg) { 'OK' } else { 'WARN' }); Detail = $dbg }

    foreach ($app in @($Apps)) {
        if (-not "$app".Trim()) { continue }
        $procName = [IO.Path]::GetFileNameWithoutExtension("$app")
        $procs = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
        if (-not $procs.Count) {
            $rows += [pscustomobject]@{ Name = "App: $app"; Status = 'WARN'; Detail = 'not running now - start it and re-verify to detect its runtime' }
            continue
        }
        $r = Test-AppWalkable -ProcessId $procs[0].Id -ClrMdDll $ClrMdDll
        if ($r.Managed -eq $false) {
            $rows += [pscustomobject]@{ Name = "App: $app"; Status = 'OK'; Detail = "native/unmanaged (PID $($procs[0].Id)) - crash ids via module+offset; no managed walk needed" }
        } elseif ($r.Managed -and $r.Ok) {
            $rows += [pscustomobject]@{ Name = "App: $app"; Status = 'OK'; Detail = "$($r.Flavor) CLR $($r.Clr) (PID $($procs[0].Id)) - walkable, hang/managed ids available" }
        } elseif ($r.Managed -and -not $r.Ok) {
            $rows += [pscustomobject]@{ Name = "App: $app"; Status = 'FAIL'; Detail = "$($r.Flavor) CLR $($r.Clr) but the walker could not load it: $($r.Error)" }
            Add-DepGap 'walk-failed' ("$app ($($r.Flavor) $($r.Clr)): $($r.Error)") $Dir
        } else {
            $rows += [pscustomobject]@{ Name = "App: $app"; Status = 'FAIL'; Detail = "could not probe (PID $($procs[0].Id)): $($r.Error)" }
            Add-DepGap 'probe-failed' ("$app`: $($r.Error)") $Dir
        }
    }
    return $rows
}

