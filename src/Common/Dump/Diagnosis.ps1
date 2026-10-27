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
            $d.category = if ($uiConfirmed) { 'ui-thread-busy' } else { 'thread-busy' }
            if ($leaf) {
                $who = if ($uiConfirmed) { 'The WPF UI/Dispatcher thread' } else { 'A thread' }
                $d.problem = '{0} was executing {1} when the window became unresponsive. Long-running work on the UI thread blocks the message loop, so the window cannot respond.' -f $who, $leaf
            } else {
                $d.problem = 'The process hung with no managed stack available (walk could not run).'
                $d.confidence = 'low'
            }
            if (-not $uiConfirmed) { $d.confidence = 'low' }   # could not prove the stuck thread is the UI thread
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
