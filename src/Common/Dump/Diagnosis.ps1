# Dump engine: kind-aware diagnosis. Turns the measured facts into ONE plain-language problem statement
# plus a machine category, so an event is self-sufficient - you read `diagnosis.problem` and know what the
# dump shows, without reading 40 stack frames. FACTS ONLY: every statement is derived from what was read
# from the dump (exception code, faulting module+offset, managed leaf frame, UI/Dispatcher confirmation,
# ProcDump's capture note). No speculation about root cause.

# Resolve ANY exception/NTSTATUS code to its OS-provided description - NO hardcoded table, so every code
# Windows knows is handled (and app-defined codes degrade to just the hex value). Asks the OS the same way
# WinDbg does: FormatMessage against ntdll.dll's message table, then the system table as a fallback. Cached.
Add-Type -Namespace RT -Name Msg -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr GetModuleHandleW(string name);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern System.IntPtr LoadLibraryExW(string name, System.IntPtr h, uint flags);
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)]
public static extern int FormatMessageW(uint flags, System.IntPtr src, uint msgId, uint langId, System.Text.StringBuilder buf, int size, System.IntPtr args);
'@ -ErrorAction SilentlyContinue
$script:ExcCache = @{}
$script:NtdllHandle = [IntPtr]::Zero

function Get-ExceptionName([string]$Code) {
    if (-not $Code) { return $null }
    $u = try { [Convert]::ToUInt32($Code, 16) } catch { return $null }
    if ($script:ExcCache.ContainsKey($u)) { return $script:ExcCache[$u] }
    $FROM_HMODULE = 0x800; $IGNORE_INSERTS = 0x200
    $msg = $null
    try {
        if ($script:NtdllHandle -eq [IntPtr]::Zero) {
            $script:NtdllHandle = [RT.Msg]::GetModuleHandleW('ntdll.dll')               # ntdll is always loaded
            if ($script:NtdllHandle -eq [IntPtr]::Zero) { $script:NtdllHandle = [RT.Msg]::LoadLibraryExW('ntdll.dll', [IntPtr]::Zero, 0) }
        }
        $sb = New-Object System.Text.StringBuilder 2048
        $n = [RT.Msg]::FormatMessageW(($FROM_HMODULE -bor $IGNORE_INSERTS), $script:NtdllHandle, $u, 0, $sb, $sb.Capacity, [IntPtr]::Zero)
        if ($n -gt 0) {
            # tidy the message-table text into one line: drop the "{EXCEPTION}"/"{...}" header, collapse newlines
            $msg = $sb.ToString()
            $msg = [regex]::Replace($msg, '^\s*\{[^}]*\}\s*', '')
            $msg = ([regex]::Replace($msg, '\s+', ' ')).Trim()
        }
    } catch { $msg = $null }
    $script:ExcCache[$u] = $msg
    return $msg
}

# Is an exception code fatal, from its NTSTATUS severity bits (top two bits = 0b11 = error) - dynamic, no
# per-code list. Managed exceptions (0xE0434352) are errors too and fall out of this naturally.
function Test-FatalExceptionCode([string]$Code) {
    if (-not $Code) { return $false }
    $u = try { [Convert]::ToUInt32($Code, 16) } catch { return $false }
    return ((($u -shr 30) -band 0x3) -eq 0x3)
}

# Why ProcDump wrote this dump (independent of the stack): a hung-window note proves the window was actually
# unresponsive, not merely busy.
function Get-DumpCaptureReason($Sig) {
    if ($Sig.ProcDumpComment -and $Sig.ProcDumpComment -match '(?i)hung window') { return 'hung-window' }
    switch ($Sig.Kind) {
        'crash' { return 'exception' }
        'managed-exception' { return 'managed-exception' }
        'hang' { return 'hang' }
        default { return 'unknown' }
    }
}

# The one derived verdict. Returns an [ordered] with a category, a one-line `problem`, a classification
# `confidence`, and kind-specific fields. Kinds: crash (native), managed-exception, hang, unknown.
function Get-DumpDiagnosis($Sig) {
    $leaf = if ($Sig.Frames -and $Sig.Frames.Count) { $Sig.Frames[0] }
            elseif ($Sig.Module) { '{0}+0x{1:x}' -f $Sig.Module, $Sig.Offset }
            else { $null }
    $unresponsive = [bool]($Sig.ProcDumpComment -match '(?i)hung window')
    $uiConfirmed = [bool]$Sig.UiConfirmed
    $d = [ordered]@{ category = $null; problem = $null; confidence = 'high' }

    switch ($Sig.Kind) {
        'crash' {
            # Category stays the KIND (crash); the OS-resolved name + raw code carry the specifics, so no
            # per-code table is needed and every NTSTATUS is covered.
            $d.category = 'crash'
            $exc = Get-ExceptionName $Sig.Code
            $where = if ($Sig.Module) { '{0}+0x{1:x}' -f $Sig.Module, $Sig.Offset }
                     elseif ($null -ne $Sig.Address) { '0x{0:x}' -f $Sig.Address } else { 'an unknown location' }
            $what = if ($exc) { '0x{0} ("{1}")' -f $Sig.Code, $exc } else { 'exception 0x{0}' -f $Sig.Code }
            $onThread = if ($Sig.ThreadId) { ' on thread {0}' -f $Sig.ThreadId } else { '' }
            $d.problem = 'Process crashed with {0} at {1}{2}.' -f $what, $where, $onThread
        }
        'managed-exception' {
            $d.category = 'managed-exception'
            $t = if ($Sig.ExceptionType) { $Sig.ExceptionType } else { '(type not resolved)' }
            $at = if ($leaf) { ' at {0}' -f $leaf } else { '' }
            $d.problem = 'Unhandled managed exception {0}{1}.' -f $t, $at
            if (-not $Sig.ExceptionType) { $d.confidence = 'low' }
        }
        'hang' {
            $who = if ($uiConfirmed) { 'The WPF UI/Dispatcher thread' } else { 'A thread' }
            $app = $Sig.AppFrame                                   # the vendor's own frame driving the work
            $appFrames = @(); if ($Sig.Frames) { $appFrames = @($Sig.Frames | Where-Object { $_ -notmatch '^\.\.\.' -and -not (Test-FrameworkFrame $_) -and -not (Test-BootstrapFrame $_) }) }
            # Where is the application frame? At/near the leaf = vendor code is EXECUTING now. Only deep at the
            # root = the vendor handler TRIGGERED a framework pass that is what's actually running.
            $appNearLeaf = $app -and ([int]$Sig.AppFrameDepth -ge 1) -and ([int]$Sig.AppFrameDepth -le 3)
            $isStorm = (@($Sig.StormOperations).Count -gt 0) -and ([int]$Sig.StormDominantCount -ge 3)
            $ops = if (@($Sig.StormOperations).Count) { $Sig.StormOperations -join ' + ' } else { $null }
            $dom = if ($Sig.StormDominantFrame) { ', dominated by {0} (x{1})' -f $Sig.StormDominantFrame, $Sig.StormDominantCount } else { '' }
            if (-not $leaf) {
                $d.category = 'hang'; $d.confidence = 'low'
                $d.problem = 'The process hung with no managed stack available (walk could not run).'
            }
            elseif ($appNearLeaf) {
                # vendor code is at/near the leaf -> actively executing on the UI thread
                $d.category = if ($uiConfirmed) { 'ui-thread-busy' } else { 'thread-busy' }
                if ($app -eq $leaf) { $d.problem = '{0} was running application code {1}; the window was unresponsive.' -f $who, $app }
                else { $d.problem = '{0} was running application code {1} (inside framework call {2}); the window was unresponsive.' -f $who, $app, $leaf }
                if (-not $uiConfirmed) { $d.confidence = 'medium' }
            }
            elseif ($isStorm) {
                # the thread is deep in a framework pass; name the vendor TRIGGER if the only app frame is the
                # deep root, else report the storm with no captured application frame.
                $d.confidence = 'medium'
                if ($app) {
                    $d.category = 'ui-thread-storm-triggered'
                    $d.problem = '{0} was in a WPF {1} pass ({2} frames deep{3}) triggered by application code {4} (at the root of the stack); the window was unresponsive.' -f $who, $ops, $Sig.StackDepth, $dom, $app
                } else {
                    $d.category = 'hang-wpf-storm'
                    $d.problem = '{0} was in a WPF {1} pass ({2} frames deep{3}); no application frame on the captured stack; the window was unresponsive.' -f $who, $ops, $Sig.StackDepth, $dom
                }
            }
            else {
                # not near-leaf app code and not a deep repeating pass -> shallow framework (likely blocked/waiting)
                $d.category = 'hang-framework-only'; $d.confidence = 'low'
                $trig = if ($app) { ' (deep root application frame: {0})' -f $app } else { '' }
                $d.problem = '{0} was in framework code {1} ({2} managed frames deep){3}; no application frame near the leaf; the window was unresponsive.' -f $who, $leaf, $Sig.StackDepth, $trig
            }
            $d.storm = [ordered]@{
                operations    = @($Sig.StormOperations)
                dominantFrame = $Sig.StormDominantFrame
                dominantCount = [int]$Sig.StormDominantCount
                stackDepth    = [int]$Sig.StackDepth
            }
            $d.applicationFrame = $app
            $d.applicationFrameDepth = [int]$Sig.AppFrameDepth
            $d.applicationFrames = $appFrames
            $d.uiThreadConfirmed = $uiConfirmed
            $d.dispatcherFrame = $Sig.DispatcherFrame
            $d.windowUnresponsive = $unresponsive
        }
        default {
            $d.category = 'unknown'; $d.problem = 'Unclassified dump (no exception, no managed stack).'; $d.confidence = 'low'
        }
    }
    $d.busyAt = $leaf
    $d.captureReason = Get-DumpCaptureReason $Sig
    return $d
}
