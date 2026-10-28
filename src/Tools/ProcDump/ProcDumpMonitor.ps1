#Requires -Version 5.1
<#
.SYNOPSIS
  Self-installing ProcDump monitor: captures crash / hang / exception dumps for selected apps,
  keeps only the newest N dumps, and runs silently from a scheduled task.

.USAGE
  Interactive (menu: setup, install, status, start/stop, uninstall):
      powershell -ExecutionPolicy Bypass -File .\ProcDumpMonitor.ps1
  Unattended deployment (uses existing config, or defaults):
      powershell -ExecutionPolicy Bypass -File .\ProcDumpMonitor.ps1 -Install
      powershell -ExecutionPolicy Bypass -File .\ProcDumpMonitor.ps1 -Update   [-Force]
      powershell -ExecutionPolicy Bypass -File .\ProcDumpMonitor.ps1 -Uninstall
  -Update only installs if this script is NEWER than the installed copy. -Force also allows
  same-version reinstall, downgrade, and updating an old install whose stop handling isn't graceful.

.VERSION
  $ScriptVersion is stamped automatically from the repo VERSION by scripts\New-Release.ps1 at release time -
  NEVER edit it by hand. Release history lives in CHANGELOG.md and the GitHub releases.
  Monitor mode (what the scheduled task runs - not meant to be started by hand):
      ... -File "%ProgramData%\ReportingTroubleshooting\src\Tools\ProcDump\ProcDumpMonitor.ps1" -Monitor

.FILES
  Scripts run in place from the installed src; the scheduled task and the detached workers point at that src
  path, so an app update refreshes them with no copy to go stale. %ProgramData%\ReportingTroubleshooting\Monitor\
  holds DATA only:
      config.json                         settings
      Logs\ProcDumpMonitor_<datetime>.log         one per monitor launch
      Logs\ProcDumpMonitor-Setup_<datetime>.log   one per setup/menu session
      Logs\ProcDump_<app>_<datetime>.log          ProcDump's own output, one per ProcDump session
  ProcDump lives in the shared store %ProgramData%\ReportingTroubleshooting\Packages\sysinternals\
  Dump OUTPUT (not app data) goes to the configured DumpDir (default C:\dumps):
      <proc>_<computer>_<YYMMDD>_<HHMMSS>.dmp + <same>.info.txt   dump + reason, exception, PID, exe versions
#>
[CmdletBinding()]
param(
    [switch]$Monitor,
    [switch]$Install,
    [switch]$Update,
    [switch]$Force,
    [switch]$Uninstall,
    [switch]$Triage          # on-demand: fault-identify + dedupe every dump in the configured DumpDir (no admin)
)

# =============================== VERSION =================================
# Stamped automatically by scripts\New-Release.ps1 from the repo VERSION - do not edit by hand.
$ScriptVersion = '1.0.45'
$GracefulStopSince = [version]'2.0.0'   # installed copies older than this may kill apps when stopped

# =============================== CONSTANTS ===============================
$AppName         = 'ProcDumpMonitor'
$TaskName        = 'ProcDumpMonitor'
$BaseDir         = Join-Path $env:ProgramData 'ReportingTroubleshooting\Monitor'   # all app data under the one app root
$ConfigFile      = Join-Path $BaseDir 'config.json'
$LogDir          = Join-Path $BaseDir 'Logs'
# Scripts run IN PLACE from src (defined after $MonScriptDir below). $BaseDir holds DATA only - config, logs,
# KnownIssues, dumps - never script copies. The scheduled task points at the src script directly, so an app
# update refreshes the monitor automatically (no "installed copy" to go stale).
$MutexName       = "Global\$AppName"
$StopFile        = Join-Path $BaseDir 'stop.request'    # created to ask the running monitor to stop gracefully
# $ToolsDir / $ProcDumpExeName / $ProcDumpExe come from the shared package store, set after Packages.ps1 below.

$script:LogFile    = $null
$script:LogBase    = $null
$script:LogPart    = 1
$script:ExitCode   = 0
$script:LogCount   = 0
$script:LogPrefix  = $AppName
$script:EchoLog    = $false        # also print log lines to the console / Information stream (interactive use + GUI capture)
$script:Interactive = $false       # a console host that can actually Read-Host (menu mode only; NOT the GUI runspace)
$script:LogMaxMB   = 10

# =============================== SHARED COMPONENTS ======================
# Dot-sourced so they run in this script's scope and use the $script: logging state + $LogDir/$AppName
# above. Resolves Common\ in the repo layout (..\Common) or next to the installed copy (.\Common - the
# installer copies it there so the detached scheduled task can load it). Provides:
#   New-LogFile/Write-Log/Update-LogRoll/Remove-OldLogs, Test-Admin, Get-ConsoleUser,
#   Test-MicrosoftSignature, Read-Value/Read-Int/Read-Bool, Get-ScriptVersionFromFile, Format-Version.
$MonScriptDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
# The task runs THIS script and its siblings in place from src - no copying into $BaseDir.
$InstalledScript    = Join-Path $MonScriptDir "$AppName.ps1"
$InstalledTriage    = Join-Path $MonScriptDir 'DumpTriage.ps1'
$InstalledTelemetry = Join-Path (Split-Path $MonScriptDir -Parent) 'Telemetry\Send-Telemetry.ps1'
$CommonDir = $null; $__probe = $MonScriptDir
for ($__i = 0; $__i -lt 6 -and -not $CommonDir; $__i++) {
    foreach ($__c in @((Join-Path $__probe 'Common'), (Join-Path $__probe 'Scripts\Common'))) {
        if (Test-Path (Join-Path $__c 'Common.ps1')) { $CommonDir = $__c; break }
    }
    $__parent = Split-Path $__probe -Parent
    if (-not $__parent -or $__parent -eq $__probe) { break }
    $__probe = $__parent
}
if (-not $CommonDir) { throw "Shared components (Common\) not found from $MonScriptDir upward." }
. (Join-Path $CommonDir 'Logging.ps1')
. (Join-Path $CommonDir 'Common.ps1')
. (Join-Path $CommonDir 'Packages.ps1')
. (Join-Path $CommonDir 'DumpId.ps1')     # stable fault-signature + known-issues dedupe engine

# ProcDump lives in the shared package store - single source of truth: Common\Packages.ps1.
$ToolsDir        = Get-PackageDir 'sysinternals'
$ProcDumpExeName = Get-ProcDumpExeName
$ProcDumpExe     = Join-Path $ToolsDir $ProcDumpExeName

# =============================== CONFIG ==================================
function Get-DefaultConfig {
    [pscustomobject]@{
        Apps             = @('AppA.exe')
        DumpDir          = 'C:\dumps'
        KeepDumps        = 15
        CheckSeconds     = 5
        CleanupSeconds   = 300
        ProcDumpArgs     = '-accepteula -ma -e -h -n 1 -w'   # -n = dumps per ProcDump session (default 1 if omitted)
        CooldownSeconds  = 60           # after a dump: wait this long before re-arming ProcDump on the SAME process
        DuplicateAction  = 'Delete'     # Delete | Keep  - what to do with repeat captures of the same event
        DuplicateWindowSeconds = 300    # hang dumps of a process this soon after its exception dump = duplicate
        KnownIssuesEnabled = $true      # identify each dump's stable fault id and dedupe already-seen problems
        SuppressKnown    = $true        # keep the FIRST dump of each id, count + soft-suppress later recurrences
        SuppressAction   = 'Recycle'    # Recycle = move recurrences to KnownIssues\Suppressed | Delete
        BaselinePath     = ''           # optional: JSON of already-analysed ids to suppress even the first time (blank = installed baseline beside the script)
        TelemetryEnabled = $true        # periodically forward events / sync known-sigs / upload new-signature dumps
        TelemetrySeconds = 300          # how often the monitor flushes telemetry (when enabled)
        # The ingest/registry/silo endpoints and the send-only device key are NOT config: they ship with the
        # build as an encoded blob (see Common\Telemetry.ps1 Get-TelemetryEndpoints), so they are not clear
        # text in config.json or the UI and need no manual per-machine step.
        LogKeep          = 20
        LogMaxMB         = 10
        RunMode          = 'Logon'      # Logon = as user at logon (GUI apps, hang detection) | Startup = SYSTEM at boot
        TaskUser         = (Get-ConsoleUser)   # Logon mode: DOMAIN\user; defaults to the current console user (editable)
        HeadlessLauncher = $true        # Logon mode: start via 'conhost --headless' so no window flashes
    }
}

function Read-Config {
    $cfg = Get-DefaultConfig
    if (Test-Path $ConfigFile) {
        try {
            $file = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            foreach ($name in $cfg.PSObject.Properties.Name) {
                if ($null -ne $file.$name) { $cfg.$name = $file.$name }
            }
        } catch {
            Write-Log "Config file unreadable, using defaults: $($_.Exception.Message)" 'WARN'
        }
    }
    # Heal Apps. An older GUI build could save the whole list as the string "System.Object[]" (a stringified
    # array), which then armed ProcDump against a bogus process name that never exists - so it never attached.
    # Split any comma-joined value, trim, and drop empties and stringified-object artifacts.
    $rawApps = @($cfg.Apps)
    $cfg.Apps = @($rawApps |
        ForEach-Object { "$_" -split ',' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -notmatch '^System\.(Object|Collections)' })
    if ($rawApps | Where-Object { "$_" -match '^System\.' }) {
        Write-Log "Config 'Apps' held an invalid entry (e.g. 'System.Object[]') from an old build - removed it. Re-add the app(s) to monitor if the list is now empty." 'WARN'
    }
    # A saved empty TaskUser must not stick as empty: the Logon task needs a user, so fall back to the
    # current console user (same default as Get-DefaultConfig).
    if (-not "$($cfg.TaskUser)".Trim()) { $cfg.TaskUser = (Get-ConsoleUser) }
    return $cfg
}

function Save-Config($cfg) {
    if (-not (Test-Path $BaseDir)) { New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null }
    $cfg | ConvertTo-Json -Depth 4 | Set-Content -Path $ConfigFile -Encoding UTF8
    Write-Log "Config saved to $ConfigFile"
}

# =============================== HELPERS =================================
# Test-Admin, Get-ConsoleUser and Test-MicrosoftSignature come from the shared Common component.

# Launch the telemetry forwarder detached + below-normal (sync known-sigs, forward events, upload new-signature
# dumps) so network egress never blocks the monitor loop. Runs the forwarder in place from src. No-op if absent.
function Enqueue-Telemetry {
    $worker = $InstalledTelemetry
    if (-not (Test-Path $worker)) { Write-Log "Telemetry flush skipped: forwarder not found at $worker" 'WARN'; return }
    try {
        Write-Log 'Telemetry flush: launching forwarder (sync known-sigs, forward events, upload granted dumps)'
        $p = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$worker`"", '-Quiet')
        try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}
        Write-Log "Telemetry forwarder launched (PID $($p.Id)); outcome in Logs\Telemetry_*.log"
    } catch { Write-Log "Could not launch telemetry forwarder: $($_.Exception.Message)" 'WARN' }
}

# Verify the fault-id dependencies for the CONFIGURED apps on this machine (no dump needed) and emit a
# readable report. Backs the Monitor tab's "Verify deps" button (run in the monitor runspace). Gaps are
# logged to KnownIssues\gaps.jsonl by the engine.
function Get-MonitorDepReport {
    $cfg   = Read-Config
    $clrmd = Resolve-PackageTool 'clrmd'
    "Fault-id dependency check for the monitored apps on $env:COMPUTERNAME:"
    $apps = @($cfg.Apps | Where-Object { "$_".Trim() })
    if (-not $apps.Count) { "  (no apps configured yet - add apps in the config editor below, then re-verify)" }
    $rows = Test-MonitorDependencies -Apps $apps -ClrMdDll $clrmd
    foreach ($r in $rows) { "  [{0,-4}] {1} - {2}" -f $r.Status, $r.Name, $r.Detail }
    $fail = @($rows | Where-Object { $_.Status -eq 'FAIL' }).Count
    $warn = @($rows | Where-Object { $_.Status -eq 'WARN' }).Count
    if ($fail) { "RESULT: $fail dependency problem(s) - crash ids still work, but hang/managed-exception ids are unavailable where failed (logged to KnownIssues\gaps.jsonl)." }
    elseif ($warn) { "RESULT: no failures; $warn app(s) not running - start them and re-verify for a full check." }
    else { "RESULT: all monitored apps can be fault-identified on this machine." }
}

# Install ClrMD (managed stack-walker) when known-issues dedupe is on, so hang/managed-exception ids work.
function Install-KnownIssuesDeps($cfg) {
    if (-not $cfg.KnownIssuesEnabled) { return }
    if (Install-Package 'clrmd') { Write-Log 'ClrMD present (managed hang/exception identification available).' }
    else { Write-Log 'ClrMD not available - crash ids still work; hang/managed-exception ids need it (use Packages > Verify deps).' 'WARN' }
}

# Ensures the Sysinternals package (ProcDump + suite) is installed in the shared store. All download /
# extract / signature logic lives in the shared engine (Common\Packages.ps1) so it is defined once;
# ProcDump is the binary this monitor runs and is the one the engine gates on signature.
function Install-Sysinternals([switch]$Force) {
    return (Install-Package 'sysinternals' -Force:$Force)
}

# ---------- Safe ProcDump shutdown ----------
# ProcDump attaches to the app as a debugger. If ProcDump is KILLED while attached, Windows
# terminates the app too. So: always ask ProcDump to detach (Ctrl+C / -cancel), wait, and only
# force-end instances that are still just waiting (-w) with no target running.

function Get-OurProcDumps {
    @(Get-CimInstance Win32_Process -Filter "Name LIKE 'procdump%'" -ErrorAction SilentlyContinue |
      Where-Object { $_.ExecutablePath -and $_.ExecutablePath -like "$ToolsDir\*" })
}

# Which configured app a ProcDump instance is for (from its command line), or $null.
function Get-ProcDumpApp($pd, $cfg) {
    foreach ($app in $cfg.Apps) {
        if ($pd.CommandLine -match "(?i)\s$([regex]::Escape($app))(\s|`"|$)") { return $app }
    }
    $null
}

function Test-AppRunning([string]$App) {
    [bool](Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($App)) -ErrorAction SilentlyContinue)
}

# Sends Ctrl+C to a console process from a separate hidden helper (so our own console is untouched).
# For ProcDump, Ctrl+C = "end monitoring without terminating the process". Returns the helper process
# (PassThru, NOT -Wait) so the caller can fire one per instance concurrently and wait for them together -
# waiting on each in turn is far too slow when a dozen-plus instances are attached.
function Send-CtrlC([int]$ProcessId) {
    $code = @"
Add-Type -Namespace W -Name K -MemberDefinition '
[DllImport("kernel32.dll")] public static extern bool FreeConsole();
[DllImport("kernel32.dll")] public static extern bool AttachConsole(uint p);
[DllImport("kernel32.dll")] public static extern bool SetConsoleCtrlHandler(System.IntPtr h, bool add);
[DllImport("kernel32.dll")] public static extern bool GenerateConsoleCtrlEvent(uint e, uint g);'
[void][W.K]::FreeConsole()
if ([W.K]::AttachConsole($ProcessId)) {
    [void][W.K]::SetConsoleCtrlHandler([IntPtr]::Zero, `$true)
    [void][W.K]::GenerateConsoleCtrlEvent(0, 0)
    Start-Sleep -Milliseconds 500
}
"@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    try {
        Start-Process powershell.exe -ArgumentList "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $enc" `
                      -WindowStyle Hidden -PassThru -ErrorAction Stop
    } catch { Write-Log "Ctrl+C helper failed for PID ${ProcessId}: $($_.Exception.Message)" 'WARN'; $null }
}

function Stop-ProcDumpInstances($cfg, [int]$TimeoutSec = 30) {
    $pds = @(Get-OurProcDumps)
    if ($pds.Count -eq 0) { Write-Log 'No ProcDump instances running - nothing to detach.'; return }

    # Instances whose command line we can't read are orphans from another session/user: we can neither
    # Ctrl+C them (AttachConsole doesn't cross sessions) nor identify their target, so don't burn the detach
    # timeout waiting for them to exit - they never will from here.
    $orphanPids = @($pds | Where-Object { -not "$($_.CommandLine)".Trim() } | ForEach-Object { $_.ProcessId })
    if ($orphanPids.Count) {
        Write-Log "$($orphanPids.Count) orphaned ProcDump instance(s) (PID $($orphanPids -join ', ')) belong to another session and can't be managed from here - not waiting on them." 'WARN'
    }
    Write-Log "Stopping $($pds.Count) ProcDump instance(s) gracefully (detaching any attached, quitting any still waiting)..."

    # 1) Ctrl+C every instance CONCURRENTLY (detaches if attached, quits if waiting). Fire all helpers,
    # then wait for them together - serial -Wait on each is ~1s/instance and crawls with 17 attached.
    $helpers = @($pds | ForEach-Object { Send-CtrlC $_.ProcessId } | Where-Object { $_ })
    $hdeadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $hdeadline -and @($helpers | Where-Object { -not $_.HasExited }).Count -gt 0) {
        Start-Sleep -Milliseconds 150
    }
    foreach ($h in @($helpers | Where-Object { -not $_.HasExited })) { try { $h.Kill() } catch {} }

    # 2) Also use ProcDump's own -cancel for apps that are running (ProcDump 10+)
    Start-Sleep -Seconds 2
    if ((Get-OurProcDumps) -and (Test-Path $ProcDumpExe)) {
        foreach ($app in $cfg.Apps) {
            foreach ($proc in @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($app)) -ErrorAction SilentlyContinue)) {
                & $ProcDumpExe -accepteula -cancel $proc.Id 2>&1 | Out-Null
            }
        }
    }

    # 3) Wait for the manageable ones to exit on their own (ignore the orphans we can't signal)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $left = @(Get-OurProcDumps | Where-Object { $orphanPids -notcontains $_.ProcessId })
        if ($left.Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    }

    # 4) Leftovers: end only those whose app is NOT running (nothing attached -> safe)
    foreach ($pd in (Get-OurProcDumps)) {
        $app = Get-ProcDumpApp $pd $cfg
        if ($app -and -not (Test-AppRunning $app)) {
            Invoke-CimMethod -InputObject $pd -MethodName Terminate | Out-Null
            Write-Log "Ended waiting ProcDump PID $($pd.ProcessId) ($app not running, nothing attached)."
        } elseif ($app) {
            Write-Log "ProcDump PID $($pd.ProcessId) ($app) did not detach - LEFT RUNNING so $app is not terminated." 'WARN'
        } else {
            # No configured app matched its command line - it is an orphan from an earlier monitor session
            # (often one started by another user/session, whose command line we cannot read from here). We
            # can't send it Ctrl+C across sessions and can't tell what it may be attached to, so leave it be.
            $owner = $null
            try { $o = Invoke-CimMethod -InputObject $pd -MethodName GetOwner; if ($o.ReturnValue -eq 0) { $owner = ("{0}\{1}" -f $o.Domain, $o.User) } } catch {}
            Write-Log ("ProcDump PID $($pd.ProcessId) is an orphan from an earlier monitor session" +
                       $(if ($owner) { " (started by $owner)" } else { '' }) +
                       " - LEFT RUNNING so whatever it may be attached to is not terminated. End it manually or reboot if it is stale.") 'WARN'
        }
    }
    $n = @(Get-OurProcDumps).Count
    if ($n -eq 0) { Write-Log 'All ProcDump instances detached.' }
}

# ProcDump instances still attached after a stop attempt are taken over instead of
# starting duplicates; they are monitored until they exit (their output isn't captured).
function Get-AdoptedMonitors($cfg) {
    $map = @{}
    foreach ($pd in (Get-OurProcDumps)) {
        $app = Get-ProcDumpApp $pd $cfg
        if (-not $app -or $map.ContainsKey($app)) { continue }
        $proc = Get-Process -Id $pd.ProcessId -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        try { $null = $proc.Handle } catch { }
        $map[$app] = [pscustomobject]@{ Process = $proc; File = $null; Pos = 0L; Partial = ''; Enc = $null; App = $app; Started = Get-Date }
        Write-Log "Adopted running ProcDump PID $($pd.ProcessId) for $app."
    }
    $map
}

# =============================== VERSION INFO ============================
function Get-ExeInfoText([string]$Path) {
    try {
        $f  = Get-Item -LiteralPath $Path -ErrorAction Stop
        $vi = $f.VersionInfo
        '{0} | FileVersion {1} | ProductVersion {2} | Modified {3:yyyy-MM-dd HH:mm:ss} | {4:N0} KB' -f `
            $Path, $vi.FileVersion, $vi.ProductVersion, $f.LastWriteTime, ($f.Length / 1KB)
    } catch { "$Path | version unavailable: $($_.Exception.Message)" }
}

# Logs path + version whenever the set of running instances of an app changes.
function Update-AppVersions($cfg, $seen, $lastInfo) {
    foreach ($app in $cfg.Apps) {
        $name  = [IO.Path]::GetFileNameWithoutExtension($app)
        $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        $ids   = ($procs | ForEach-Object { $_.Id } | Sort-Object) -join ','
        if ($ids -eq $seen[$app]) { continue }

        $wasRunning = [bool]$seen[$app]
        $seen[$app] = $ids
        if (-not $procs) { if ($wasRunning) { Write-Log "$app no longer running." }; continue }

        $lines = foreach ($p in $procs) {
            $path = try { $p.Path } catch { $null }
            if ($path) { "PID $($p.Id): $(Get-ExeInfoText $path)" } else { "PID $($p.Id): path not accessible" }
        }
        $lastInfo[$app] = @($lines)
        foreach ($l in $lines) { Write-Log "$app running - $l" }
    }
}

# =============================== DUMP ANALYSIS ===========================
# keys are hex strings (PowerShell parses 0xC0000005 as a negative Int32, so literals won't match)
$ExceptionNames = @{
    'C0000005' = 'ACCESS_VIOLATION';        'C0000374' = 'HEAP_CORRUPTION'
    'C0000409' = 'STACK_BUFFER_OVERRUN / FAIL_FAST'; 'C00000FD' = 'STACK_OVERFLOW'
    'E0434352' = '.NET (CLR) EXCEPTION';    'E06D7363' = 'C++ EXCEPTION'
    '80000003' = 'BREAKPOINT';              '80000004' = 'SINGLE_STEP'
    'C0000094' = 'INTEGER_DIVIDE_BY_ZERO';  'C000001D' = 'ILLEGAL_INSTRUCTION'
    'C0000096' = 'PRIVILEGED_INSTRUCTION';  'C0000006' = 'IN_PAGE_ERROR'
    'C0000008' = 'INVALID_HANDLE';          'C0000420' = 'ASSERTION_FAILURE'
    'C0000602' = 'FAIL_FAST_EXCEPTION';     'C000041D' = 'FATAL_USER_CALLBACK_EXCEPTION'
}

# Reads header, exception record, process id and ProcDump's comment straight from the .dmp
# (only a few KB are read, even for multi-GB dumps).
function Get-DumpInfo([string]$Path) {
    $r = [pscustomobject]@{ ProcessId = $null; ThreadId = $null; Code = $null; Address = $null
                            Params = @(); Comment = ''; Trigger = ''; Exception = '' }
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $br = New-Object IO.BinaryReader($fs)
        if ($br.ReadUInt32() -ne 0x504D444D) { return $null }        # 'MDMP'
        [void]$br.ReadUInt32()
        $count = $br.ReadUInt32(); $dirRva = $br.ReadUInt32()
        $fs.Position = $dirRva
        $dir = @(for ($i = 0; $i -lt $count; $i++) { ,@($br.ReadUInt32(), $br.ReadUInt32(), $br.ReadUInt32()) })
        foreach ($s in $dir) {
            $type = $s[0]; $size = $s[1]; $rva = $s[2]
            if ($type -eq 6 -and $size -ge 40) {                      # ExceptionStream
                $fs.Position = $rva
                $r.ThreadId = $br.ReadUInt32(); [void]$br.ReadUInt32()
                $r.Code = $br.ReadUInt32(); [void]$br.ReadUInt32(); [void]$br.ReadUInt64()
                $r.Address = $br.ReadUInt64()
                $np = [Math]::Min($br.ReadUInt32(), 15); [void]$br.ReadUInt32()
                $r.Params = @(for ($j = 0; $j -lt $np; $j++) { $br.ReadUInt64() })
            }
            elseif ($type -eq 15 -and $size -ge 12) {                 # MiscInfoStream
                $fs.Position = $rva
                [void]$br.ReadUInt32(); $flags = $br.ReadUInt32(); $p = $br.ReadUInt32()
                if ($flags -band 1) { $r.ProcessId = $p }
            }
            elseif (($type -eq 10 -or $type -eq 11) -and $size -gt 0 -and $size -lt 65536 -and -not $r.Comment) {
                $fs.Position = $rva                                   # CommentStreamA / W
                $enc = if ($type -eq 11) { [Text.Encoding]::Unicode } else { [Text.Encoding]::ASCII }
                $r.Comment = $enc.GetString($br.ReadBytes([int]$size)).Trim([char]0, ' ', "`r", "`n")
            }
        }
    } finally { $fs.Dispose() }

    if ($null -ne $r.Code) {
        $hex  = '{0:X8}' -f $r.Code
        $name = $ExceptionNames[$hex]
        $r.Exception = '0x{0}{1} at 0x{2:X} on thread {3}' -f $hex, $(if ($name) { " $name" } else { '' }), $r.Address, $r.ThreadId
        if ($hex -eq 'C0000005' -and $r.Params.Count -ge 2) {
            $op = switch ($r.Params[0]) { 0 { 'read from' } 1 { 'write to' } 8 { 'execute (DEP) at' } default { 'access to' } }
            $r.Exception += ' ({0} 0x{1:X})' -f $op, $r.Params[1]
        }
    }
    # ProcDump's comment: "*** procdump <args>" + "*** <reason>" lines
    $reason = @($r.Comment -split "`r?`n" | ForEach-Object { ($_ -replace '^\*+\s*', '').Trim() } |
                Where-Object { $_ -and $_ -notmatch '^procdump(64|64a)?(\.exe)?\s' })
    $r.Trigger = if ($reason) { $reason -join '; ' }
                 elseif ($r.Exception) { 'Exception (no ProcDump comment in dump)' }
                 else { 'Unknown (no exception record and no ProcDump comment - likely hang/manual trigger)' }
    $r
}

function Get-DumpApp($cfg, [string]$FileName) {
    # New scheme: match the <process> token exactly. Fall back to a prefix match for any legacy-named dump.
    $proc = Get-DumpProcessFromName $FileName
    if ($proc) { return ($cfg.Apps | Where-Object { [IO.Path]::GetFileNameWithoutExtension($_) -ieq $proc } | Select-Object -First 1) }
    $cfg.Apps | Where-Object { $FileName -like "$([IO.Path]::GetFileNameWithoutExtension($_))*" } | Select-Object -First 1
}

# Launch the fault-identification + dedupe worker for one freshly written dump, DETACHED and at
# below-normal priority, so the slow managed stack walk never blocks the monitor loop. The worker
# (DumpTriage.ps1, run in place from src next to this script) computes the stable id, counts the
# occurrence, and soft-suppresses recurrences of an already-kept/known id.
function Enqueue-DumpTriage([string]$DumpPath) {
    $worker = $InstalledTriage
    if (-not (Test-Path $worker)) { Write-Log 'DumpTriage.ps1 not found - fault-id skipped for this dump.' 'WARN'; return }
    try {
        $p = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$worker`"", '-DumpPath', "`"$DumpPath`"", '-Quiet')
        try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}
        Write-Log "Fault-id worker queued for $([IO.Path]::GetFileName($DumpPath)) (PID $($p.Id))."
    } catch { Write-Log "Could not launch fault-id worker: $($_.Exception.Message)" 'WARN' }
}

# Handles new dumps once fully written: reads the reason, detects repeat captures of the same
# event, writes <dump>.info.txt, and logs a one-line summary.
#   $known   : set of dump paths already handled
#   $pending : path -> last seen size (dump still being written)
#   $recent  : app -> last primary dump info (for duplicate detection)
function Invoke-NewDumps($cfg, $known, $pending, $recent, $lastInfo) {
    $dumps = @(Get-ChildItem -Path $cfg.DumpDir -Filter *.dmp -File -ErrorAction SilentlyContinue | Sort-Object CreationTime)
    foreach ($d in $dumps) {
        if ($known.Contains($d.FullName)) { continue }

        # complete = size unchanged since last check, and no writer holds the file
        if (-not $pending.ContainsKey($d.FullName) -or $pending[$d.FullName] -ne $d.Length) {
            if (-not $pending.ContainsKey($d.FullName)) { Write-Log "Dump being written: $($d.Name)" }
            $pending[$d.FullName] = $d.Length; continue
        }
        try { ([IO.File]::Open($d.FullName, 'Open', 'Read', 'Read')).Dispose() } catch { continue }
        $pending.Remove($d.FullName); [void]$known.Add($d.FullName)

        $app  = Get-DumpApp $cfg $d.Name
        $info = try { Get-DumpInfo $d.FullName } catch { $null }

        # Rename the placeholder ProcDump wrote to the final convention now that the reason is known:
        # ProcDump_<pc>_<process>_<tag>_<yyyyMMdd>_<HHmmss>.dmp. The monitor is the single owner of the name, so
        # this happens before the .info.txt sidecar is written and before the deep triage worker is enqueued.
        $proc = if ($app) { [IO.Path]::GetFileNameWithoutExtension($app) } else { Get-DumpProcessFromName $d.Name }
        $tag  = Get-DumpTag -Code $(if ($info) { $info.Code } else { $null }) -Trigger $(if ($info) { $info.Trigger } else { '' })
        $finalName = New-DumpFileName -Computer $env:COMPUTERNAME -Process $proc -Tag $tag -When $d.CreationTime
        if ($finalName -ne $d.Name) {
            $finalPath = Join-Path $cfg.DumpDir $finalName
            if (Test-Path -LiteralPath $finalPath) {   # same pc/process/tag/second -> disambiguate
                $stem = $finalName -replace '\.dmp$', ''; $n = 2
                do { $finalName = '{0}_{1}.dmp' -f $stem, $n; $finalPath = Join-Path $cfg.DumpDir $finalName; $n++ } while (Test-Path -LiteralPath $finalPath)
            }
            try {
                Move-Item -LiteralPath $d.FullName -Destination $finalPath -Force -ErrorAction Stop
                [void]$known.Remove($d.FullName); [void]$known.Add($finalPath)
                Write-Log "Renamed dump $($d.Name) -> $finalName"
                $d = Get-Item -LiteralPath $finalPath
            } catch { Write-Log "Could not rename $($d.Name) to $finalName (in use?): $($_.Exception.Message)" 'WARN' }
        }

        $ver  = if ($app -and $lastInfo[$app]) { $lastInfo[$app] } else { @('(no version info recorded for this app)') }

        # ---- duplicate detection (same process frozen at the same event) ----
        $dupOf = $null; $why = ''
        $prev  = if ($app) { $recent[$app] } else { $null }
        if ($info -and $prev -and $info.ProcessId -and $info.ProcessId -eq $prev.Info.ProcessId) {
            if ($null -ne $info.Code -and $info.Code -eq $prev.Info.Code -and
                $info.Address -eq $prev.Info.Address -and $info.ThreadId -eq $prev.Info.ThreadId) {
                $dupOf = $prev.Name; $why = 'same process, thread, exception code and address'
            }
            elseif ($null -eq $info.Code -and $null -ne $prev.Info.Code -and
                    ($d.CreationTime - $prev.Time).TotalSeconds -lt $cfg.DuplicateWindowSeconds) {
                $dupOf = $prev.Name; $why = 'hang trigger while the process was still stopped at the exception'
            }
        }
        if (-not $dupOf -and $app -and $info) { $recent[$app] = @{ Name = $d.Name; Info = $info; Time = $d.CreationTime } }

        $summary = if ($info) { "$($info.Trigger)$(if ($info.Exception) { ' | ' + $info.Exception })$(if ($info.ProcessId) { ' | PID ' + $info.ProcessId })" }
                   else { 'could not read dump header' }

        # When known-issues dedupe is on, the triage worker owns all dedup/delete decisions (by stable fault
        # id, across sessions), so the monitor's own same-session duplicate delete stands down here.
        if ($dupOf -and $cfg.DuplicateAction -eq 'Delete' -and -not $cfg.KnownIssuesEnabled) {
            try {
                Remove-Item -LiteralPath $d.FullName -Force -ErrorAction Stop
                Write-Log "Duplicate capture deleted: $($d.Name) = repeat of $dupOf ($why)." 'WARN'
            } catch { Write-Log "Duplicate $($d.Name) could not be deleted: $($_.Exception.Message)" 'WARN' }
            continue
        }

        $text = @(
            "Dump        : $($d.Name)"
            "Created     : {0:yyyy-MM-dd HH:mm:ss}" -f $d.CreationTime
            "Size        : {0:N0} MB" -f ($d.Length / 1MB)
            "App         : $app"
            "Reason      : $(if ($info) { $info.Trigger } else { 'unknown' })"
            "Exception   : $(if ($info -and $info.Exception) { $info.Exception } else { '(none - not an exception dump)' })"
            "Process ID  : $(if ($info) { $info.ProcessId })"
            "Duplicate   : $(if ($dupOf) { "YES - repeat of $dupOf ($why)" } else { 'no (primary)' })"
            "Computer    : $env:COMPUTERNAME"
            "OS          : $([Environment]::OSVersion.VersionString)"
            "Executable(s) at time of dump:"
        ) + ($ver | ForEach-Object { "  $_" })
        if ($info -and $info.Comment) { $text += @('', 'ProcDump comment in dump:') + ($info.Comment -split "`r?`n" | ForEach-Object { "  $_" }) }

        try { Set-Content -LiteralPath ([IO.Path]::ChangeExtension($d.FullName, '.info.txt')) -Value $text -Encoding UTF8 -ErrorAction Stop }
        catch { Write-Log "Could not write info file for $($d.Name): $($_.Exception.Message)" 'WARN' }

        $lvl = if ($dupOf) { 'WARN' } else { 'INFO' }
        Write-Log ("Dump complete: {0} ({1:N0} MB) - {2}{3}" -f $d.Name, ($d.Length / 1MB), $summary,
                   $(if ($dupOf) { " - DUPLICATE of $dupOf (kept)" } else { '' })) $lvl

        # Fault-identify this dump and dedupe already-seen problems (runs detached - never blocks the loop).
        if ($cfg.KnownIssuesEnabled) { Enqueue-DumpTriage $d.FullName }
    }
    # forget dumps that no longer exist
    $existing = @($dumps | ForEach-Object { $_.FullName })
    @($known)        | Where-Object { $_ -notin $existing } | ForEach-Object { [void]$known.Remove($_) }
    @($pending.Keys) | Where-Object { $_ -notin $existing } | ForEach-Object { $pending.Remove($_) }
}

# Effective ProcDump arguments. -n comes from the config; if ProcDumpArgs has no -n, -n 1 is used.
# With -n 1 the monitor re-arms ProcDump after each dump (with a cooldown), so a process that stays
# frozen after an exception isn't captured over and over by the hang trigger.
function Get-EffectiveArgs($cfg) {
    $a = ($cfg.ProcDumpArgs -replace '\s{2,}', ' ').Trim()
    if ($a -notmatch '(^|\s)-accepteula(\s|$)') { $a = "-accepteula $a" }
    if ($a -notmatch '(^|\s)-n\s+\d+') { $a = "$a -n 1" }
    $a
}

# =============================== PROCDUMP OUTPUT CAPTURE =================
# ProcDump is started hidden through cmd.exe with its output redirected to its own log file
# (Logs\ProcDump_<app>_<datetime>.log, kept like the other logs). Each loop the monitor also
# copies new lines into the main log, so attach, triggers and dump writes all show up there.
# --- bitness-matched ProcDump selection ---
# A 64-bit procdump cannot produce a walkable managed dump of a 32-bit (WOW64) process, and vice versa, so
# each app must be captured by the procdump matching ITS bitness. Both ship in the Sysinternals Suite.
function Get-PeBitness([string]$Path) {
    if (-not ($Path -and (Test-Path -LiteralPath $Path))) { return 0 }
    try {
        $fs = [IO.File]::OpenRead($Path)
        try {
            $br = New-Object IO.BinaryReader($fs)
            $fs.Position = 0x3C; $peOff = $br.ReadInt32(); $fs.Position = $peOff
            if ($br.ReadUInt32() -ne 0x00004550) { return 0 }        # 'PE\0\0'
            switch ($br.ReadUInt16()) { 0x014c { 32 } 0x8664 { 64 } 0xAA64 { 64 } default { 0 } }
        } finally { $fs.Dispose() }
    } catch { 0 }
}

# App bitness: prefer the running process (IsWow64 via DumpId's Get-ProcessBitness), else the exe's PE header,
# else default to 64-bit. Self-corrects once the app has run at least once.
function Get-AppBitness([string]$App) {
    # An explicit exe path is authoritative - read its PE header before any name-based lookup (process names
    # are not unique across bitness, e.g. 32- and 64-bit powershell.exe).
    if ([IO.Path]::IsPathRooted($App)) { $pe = Get-PeBitness $App; if ($pe) { return $pe } }
    $name = [IO.Path]::GetFileNameWithoutExtension($App)
    $p = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    if ($p.Count) {
        $b = Get-ProcessBitness $p[0].Id; if ($b) { return $b }
        try { if ($p[0].Path) { $pe = Get-PeBitness $p[0].Path; if ($pe) { return $pe } } } catch {}
    }
    $cmd = Get-Command $App -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { $pe = Get-PeBitness $cmd.Source; if ($pe) { return $pe } }
    return 64
}

# The bitness-matched ProcDump exe path for an app (falls back to the default if the matched one is missing).
function Get-ProcDumpExeForApp([string]$App) {
    $bits = Get-AppBitness $App
    $exe  = if ($bits -eq 32) { 'procdump.exe' } else { $ProcDumpExeName }
    $path = Join-Path $ToolsDir $exe
    if (-not (Test-Path $path)) { $path = $ProcDumpExe; $exe = $ProcDumpExeName }
    [pscustomobject]@{ Path = $path; Bits = $bits; Name = $exe }
}

function Start-ProcDumpCaptured([string]$App, [string]$ArgLine, [string]$ExePath) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    $name    = [IO.Path]::GetFileNameWithoutExtension($App)
    $outFile = Join-Path $LogDir ('ProcDump_{0}_{1:yyyyMMdd_HHmmss}.log' -f $name, (Get-Date))
    if (Test-Path -LiteralPath $outFile) { $outFile = $outFile -replace '\.log$', ('_{0:fff}.log' -f (Get-Date)) }
    if (-not $ExePath) { $ExePath = $ProcDumpExe }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $psi.Arguments       = "/d /c `"`"$ExePath`" $ArgLine > `"$outFile`" 2>&1`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    $proc = [System.Diagnostics.Process]::Start($psi)

    [pscustomobject]@{ Process = $proc; File = $outFile; Pos = 0L; Partial = ''; Enc = $null; App = $App; Started = Get-Date }
}

function Read-ProcDumpOutput($state, [switch]$Final) {
    if (-not $state -or -not $state.File) { return }
    $n = 0
    if (Test-Path -LiteralPath $state.File) {
        try {
            $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            $fs = New-Object IO.FileStream($state.File, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
            try {
                if ($fs.Length -gt $state.Pos) {
                    [void]$fs.Seek($state.Pos, [IO.SeekOrigin]::Begin)
                    $buf = New-Object byte[] ([int]($fs.Length - $state.Pos))
                    $n = $fs.Read($buf, 0, $buf.Length)
                    $state.Pos += $n
                }
            } finally { $fs.Dispose() }
        } catch { return }
    }

    $text = $state.Partial
    if ($n -gt 0) {
        # ProcDump writes UTF-16 (usually with a FF FE BOM), or ANSI/OEM on some versions. Detect by BOM
        # first - the old "$buf[1] -eq 0" test failed on the BOM (2nd byte 0xFE), so UTF-16 was decoded as
        # single-byte and every character came out spaced ("W a i t i n g").
        $enc = $state.Enc
        if (-not $enc -and $n -ge 2) {
            $enc = if     ($buf[0] -eq 0xFF -and $buf[1] -eq 0xFE) { [Text.Encoding]::Unicode }
                   elseif ($buf[0] -eq 0xFE -and $buf[1] -eq 0xFF) { [Text.Encoding]::BigEndianUnicode }
                   elseif ($n -ge 3 -and $buf[0] -eq 0xEF -and $buf[1] -eq 0xBB -and $buf[2] -eq 0xBF) { [Text.Encoding]::UTF8 }
                   elseif ($buf[1] -eq 0) { [Text.Encoding]::Unicode }
                   else   { [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) }
            $state.Enc = $enc
        }
        if (-not $enc) { $enc = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) }
        $text += $enc.GetString($buf, 0, $n)
    }

    $lines = @($text -split "`r?`n")
    if ($Final) { $state.Partial = '' }
    else        { $state.Partial = $lines[-1]; $lines = if ($lines.Count -gt 1) { $lines[0..($lines.Count - 2)] } else { @() } }

    foreach ($l in $lines) {
        $l = $l.Trim([char]0, [char]0xFEFF, ' ', "`t")
        if (-not $l) { continue }
        # Forward only the ProcDump lines that matter: attach/wait state, dump lifecycle, errors, and the
        # "monitoring" confirmation. ProcDump's per-first-chance-exception lines ("[hh:mm:ss] Exception: ..")
        # and its 25-line settings block per arm are pure noise - busy .NET apps emit thousands of them.
        $keep = ($l -match '^(Process:|Waiting for process|Dump \d|Dump count)') -or
                ($l -match '(?i)monitoring without terminating') -or
                ($l -match '(?i)error|failed|unable|denied')
        if (-not $keep) { continue }
        $lvl = if ($l -match '(?i)error|failed|unable|denied') { 'WARN' } else { 'INFO' }
        Write-Log "[ProcDump $($state.App)] $l" $lvl
    }
}

# Final read; the ProcDump log file is kept (only removed if it ended up empty).
function Close-ProcDumpCapture($state) {
    if (-not $state -or -not $state.File) { return }
    Read-ProcDumpOutput $state -Final
    $f = Get-Item -LiteralPath $state.File -ErrorAction SilentlyContinue
    if ($f -and $f.Length -eq 0) { Remove-Item -LiteralPath $state.File -Force -ErrorAction SilentlyContinue }
}

function Remove-OldProcDumpLogs([int]$Keep, $active) {
    Get-ChildItem -Path $LogDir -Filter 'ProcDump_*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notin $active } |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip $Keep |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
}

# =============================== SCHEDULED TASK ==========================
function Register-MonitorTask($cfg) {
    $psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstalledScript`" -Monitor"

    if ($cfg.RunMode -eq 'Startup') {
        $action    = New-ScheduledTaskAction -Execute $psExe -Argument $psArgs -WorkingDirectory $BaseDir
        $trigger   = New-ScheduledTaskTrigger -AtStartup
        $trigger.Delay = 'PT1M'
        $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $who = 'SYSTEM at startup'
    } else {
        $user = if ($cfg.TaskUser) { $cfg.TaskUser } else { Get-ConsoleUser }
        if ($cfg.HeadlessLauncher) {
            $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
            $action  = New-ScheduledTaskAction -Execute $conhost -Argument "--headless `"$psExe`" $psArgs" -WorkingDirectory $BaseDir
        } else {
            $action  = New-ScheduledTaskAction -Execute $psExe -Argument $psArgs -WorkingDirectory $BaseDir
        }
        $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
        $trigger.Delay = 'PT30S'
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        $who = "$user at logon"
    }

    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -MultipleInstances IgnoreNew -Hidden

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Description 'ProcDump crash/hang dump monitor' -Force | Out-Null
    Write-Log "Scheduled task '$TaskName' registered (runs as $who)."
}

function Get-MonitorTask { Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue }

# The actual monitor-loop process(es) by command line - NOT the task state. The task may run the loop under
# conhost (HeadlessLauncher), and the task leaving 'Running' doesn't guarantee that PowerShell child died;
# while it lives it keeps re-arming ProcDump. Matches the loop launcher (and its conhost wrapper). Excludes
# this process so a Stop issued from the GUI/menu never ends itself.
function Get-MonitorProcesses {
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessId -ne $PID -and
        "$($_.CommandLine)" -match 'ProcDumpMonitor\.ps1' -and
        "$($_.CommandLine)" -match '(?i)(^|\s)-Monitor(\s|$)'
    })
}

# Force-end every monitor-loop process so it stops re-arming ProcDump. Returns how many were ended.
function Stop-MonitorProcesses {
    $mons = @(Get-MonitorProcesses)
    foreach ($m in $mons) {
        Write-Log "Ending monitor process PID $($m.ProcessId)."
        try { Stop-Process -Id $m.ProcessId -Force -ErrorAction Stop }
        catch { Write-Log "Could not end monitor PID $($m.ProcessId) (different user? run elevated): $($_.Exception.Message)" 'WARN' }
    }
    $mons.Count
}

# Graceful: ask the monitor to stop via a request file; it detaches ProcDump and exits by itself. Then
# GUARANTEE it: force-end any loop process the task left behind (e.g. a conhost-launched PowerShell), and
# only afterwards detach ProcDump - so nothing re-arms it between detach and loop-death.
function Stop-Monitor($cfg, [int]$TimeoutSec = 60) {
    $task = Get-MonitorTask
    $running = ($task -and $task.State -eq 'Running') -or (@(Get-MonitorProcesses).Count -gt 0)
    if (-not $running) {
        Write-Log $(if ($task) { "Monitor task is not running (state: $($task.State)) - already stopped." } else { 'Monitor task is not installed - nothing to stop.' })
        Remove-Item $StopFile -Force -ErrorAction SilentlyContinue
        Stop-MonitorProcesses | Out-Null                 # reap any stray loop just in case
        Stop-ProcDumpInstances $cfg                      # clean up orphaned ProcDump
        return
    }

    $active = @(Get-OurProcDumps).Count
    Set-Content -Path $StopFile -Value (Get-Date -Format o) -ErrorAction SilentlyContinue
    Write-Log "Stop requested (monitor running; $active ProcDump instance(s) active). Waiting up to ${TimeoutSec}s for it to detach and exit..."
    $deadline = (Get-Date).AddSeconds($TimeoutSec); $nextTick = 10
    while ((Get-Date) -lt $deadline) {
        $stillUp = ((Get-MonitorTask).State -eq 'Running') -or (@(Get-MonitorProcesses).Count -gt 0)
        if (-not $stillUp) { break }
        Start-Sleep -Seconds 1
        $elapsed = [int]($TimeoutSec - ($deadline - (Get-Date)).TotalSeconds)
        if ($elapsed -ge $nextTick) { Write-Log "...still waiting for the monitor to stop (${elapsed}s)."; $nextTick += 10 }
    }

    # Force whatever remains: stop the task instance, then kill any loop process it left running.
    if ((Get-MonitorTask).State -eq 'Running') {
        Write-Log 'Monitor did not acknowledge the stop in time - ending the task.' 'WARN'
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
    $killed = Stop-MonitorProcesses
    if ($killed) { Write-Log "Force-ended $killed lingering monitor process(es) that would have kept re-arming ProcDump." 'WARN' }
    else { Write-Log 'Monitor stopped.' }

    Remove-Item $StopFile -Force -ErrorAction SilentlyContinue
    Stop-ProcDumpInstances $cfg      # now the loop is dead, detach any ProcDump left behind
}

function Start-MonitorTask {
    $task = Get-MonitorTask
    if (-not $task) { Write-Log 'Monitor is not enabled - click Enable first (it registers the scheduled task).' 'WARN'; return }

    # The task action launches "powershell.exe -File <InstalledScript>" from src. If that script is missing
    # (e.g. the app was moved/uninstalled) the process exits instantly with no window - which looks like
    # "started but nothing is running". Catch it up front.
    if (-not (Test-Path -LiteralPath $InstalledScript)) {
        Write-Log "Monitor script not found at $InstalledScript - the app's src is missing. Reinstall the app, then click Enable." 'ERROR'
        return
    }
    $acts = @($task.Actions)
    $pointsHere = $acts | Where-Object { "$($_.Arguments)" -like "*$InstalledScript*" }
    if (-not $pointsHere) {
        Write-Log "The task points at a different/older script path than this src ($InstalledScript) - click Enable to re-register it against the current src." 'WARN'
    }

    Start-ScheduledTask -TaskName $TaskName

    # Verify it actually came up: a healthy monitor reaches Running and writes its startup banner within a few
    # seconds. If the launched process died immediately, report the task's real exit code instead of claiming success.
    $deadline = (Get-Date).AddSeconds(6); $running = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 400
        if ((Get-MonitorTask).State -eq 'Running') { $running = $true; break }
    }
    if ($running) {
        Write-Log 'Monitor task started and is running. Live attach/dump activity will appear in the monitor log.'
    } else {
        $info = Get-MonitorTask | Get-ScheduledTaskInfo
        Write-Log ("Monitor task was triggered but is not running (state: $((Get-MonitorTask).State), last result: 0x{0:X8}). " -f [int64]$info.LastTaskResult +
                   'The launched process exited immediately. Reinstall the monitor (Uninstall then Install); if it persists, check that the task user can run elevated at logon.') 'ERROR'
    }
}

# Non-persistent run (what "Start" does): launch the monitor loop as a detached, hidden process in THIS
# session - NO scheduled task involved. The run lives until Stop (or until the user logs off); it is not
# re-created at logon. The Global mutex in Invoke-Monitor guarantees a single monitor, so this never
# collides with an enabled task. For a monitor that survives logon/reboot, use Enable (registers the task).
function Start-MonitorRun {
    if (-not (Test-Path -LiteralPath $InstalledScript)) {
        Write-Log "Monitor script not found at $InstalledScript - the app's src is missing. Reinstall the app." 'ERROR'; return
    }
    $taskRunning = (Get-MonitorTask) -and (Get-MonitorTask).State -eq 'Running'
    if ($taskRunning -or @(Get-MonitorProcesses).Count -gt 0) {
        Write-Log 'Monitor is already running - nothing to start.'; return
    }
    Remove-Item $StopFile -Force -ErrorAction SilentlyContinue   # clear any stale stop request
    $p = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', "`"$InstalledScript`"", '-Monitor')

    # Confirm it actually came up: a healthy monitor spawns its loop process and acquires the mutex within a
    # few seconds. If the launched process died immediately, say so instead of claiming success.
    $deadline = (Get-Date).AddSeconds(6); $up = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 400
        if (-not $p.HasExited -and @(Get-MonitorProcesses).Count -gt 0) { $up = $true; break }
    }
    if ($up) {
        Write-Log "Monitor started (this session, PID $($p.Id)). Runs until you click Stop or log off. Click Enable for a monitor that survives logon/reboot."
    } else {
        Write-Log "Monitor exited immediately after start - see the newest monitor log in $LogDir for why." 'ERROR'
    }
}

# What the "Start Monitor" button/menu does. If the service is enabled AND its task points at THIS install's
# src, Start starts that task (persistent). Otherwise - no task, or a task left over from an old install/path
# that would just fail - it does a non-persistent run in this session, so Start always does something useful.
# Enable Service re-registers the task to restore persistence. Stop-Monitor ends whichever is running.
function Start-Monitor {
    $task = Get-MonitorTask
    if ($task) {
        $pointsHere = @($task.Actions | Where-Object { "$($_.Arguments)" -like "*$InstalledScript*" })
        if ($pointsHere.Count) { Start-MonitorTask; return }
        Write-Log "A scheduled task exists but points at an old path, not this install's src - starting a non-persistent run instead. Click 'Enable Service' to re-register the task for persistence across logon/reboot." 'WARN'
    }
    Start-MonitorRun
}

# =============================== VERSION / UPDATE ========================
# Get-ScriptVersionFromFile and Format-Version come from the shared Common component.
function Confirm-Step([string]$Question) {
    # Only a real console session can prompt. The GUI runspace sets EchoLog (to capture Write-Log on the
    # Information stream) but is NOT interactive, so prompting there throws "host does not support user
    # interaction". Unattended / GUI: proceed only when -Force was requested.
    if (-not $script:Interactive) { return [bool]$Force }
    (Read-Host "$Question (y/N)") -eq 'y'
}

# =============================== ENABLE / DISABLE SERVICE ===============
# Enable Service = register the scheduled task to run THIS script in place from src (persistent across
# logon/reboot), and start it. It copies NO scripts anywhere (src is the one correct location; an app update
# refreshes src directly). It only ensures config/dirs/tools exist, (re)registers the task, and starts it.
# (A non-persistent run that needs no task is Start-MonitorRun.)
function Enable-Service {
    $cfg = Read-Config
    if (-not (Test-Path $ConfigFile)) {
        if ($script:Interactive) { Write-Host 'No config yet - running setup first.'; $cfg = Edit-Config $cfg }
        else { Save-Config $cfg }   # GUI / unattended: write defaults; edit later via the Monitor tab
    }
    foreach ($d in @($BaseDir, $ToolsDir, $LogDir, $cfg.DumpDir)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    if (-not (Install-Sysinternals)) { Write-Log 'Install aborted: ProcDump not available.' 'ERROR'; return }
    Install-KnownIssuesDeps $cfg
    Save-Config $cfg                        # merge defaults (new keys appear in the editor); preserves edits

    Stop-Monitor $cfg                   # stop any running instance so the fresh start picks up current src
    Register-MonitorTask $cfg               # task runs "$InstalledScript -Monitor" in place - nothing copied
    Start-MonitorTask
    Write-Log "Service enabled: task registered to run $InstalledScript in place (version $ScriptVersion). No scripts copied."
}

# Scripts run in place from src, so an app update already refreshed them. "Update" just re-registers the task
# (its definition may have changed between versions) and restarts to pick up the current src.
function Invoke-Update { Enable-Service }

function Disable-Service {
    # Disable removes ONLY the scheduled task. Config, logs and the installed script are kept so a later
    # re-enable reuses the same configuration - disable must never clear config. Dumps live in C:\dumps
    # (outside BaseDir) and are untouched regardless.
    $cfg = Read-Config
    Stop-Monitor $cfg
    if (Get-MonitorTask) {
        # Disable the trigger first so no logon / StartWhenAvailable event can fire it mid-removal, then remove it.
        Disable-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Log 'Scheduled task removed.'
    } else { Write-Log 'No scheduled task to remove.' }
    $left = Stop-MonitorProcesses      # belt and suspenders: nothing left to re-arm ProcDump
    if ($left) { Write-Log "Ended $left monitor process(es) still running after task removal." 'WARN' }
    Stop-ProcDumpInstances $cfg
    Write-Log "Configuration preserved at $ConfigFile. Disable removes only the scheduled task; delete $BaseDir by hand if you want config/logs gone."
    Write-Host 'Service disabled - scheduled task removed; configuration preserved.'
}

# =============================== INTERACTIVE =============================
# Read-Value and Read-Int come from the shared Common component.
function Edit-Config($cfg) {
    Write-Host "`n--- Setup (Enter keeps the current value) ---" -ForegroundColor Cyan
    $apps = Read-Value 'Apps to monitor, comma separated' ($cfg.Apps -join ', ')
    $cfg.Apps = @($apps -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } |
                  ForEach-Object { if ($_ -notlike '*.exe') { "$_.exe" } else { $_ } })
    $cfg.DumpDir        = Read-Value 'Dump folder' $cfg.DumpDir
    $cfg.KeepDumps      = Read-Int   'Number of newest dumps to keep' $cfg.KeepDumps
    $cfg.ProcDumpArgs   = Read-Value 'ProcDump arguments (-e 1 = also first-chance exceptions; -n = dumps per session, 1 recommended)' $cfg.ProcDumpArgs
    $cfg.CooldownSeconds = Read-Int  'Cooldown before re-arming on the same process (seconds; 60 minimum, enforced)' $cfg.CooldownSeconds 60
    while ($true) {
        $a = Read-Value 'Duplicate captures of the same event: Delete / Keep' $cfg.DuplicateAction
        if ($a -in 'Delete','Keep') { $cfg.DuplicateAction = (Get-Culture).TextInfo.ToTitleCase($a.ToLower()); break }
        Write-Host 'Type Delete or Keep.' -ForegroundColor Yellow
    }
    $cfg.CheckSeconds   = Read-Int   'Process check interval (seconds)' $cfg.CheckSeconds
    $cfg.CleanupSeconds = Read-Int   'Dump cleanup interval (seconds)' $cfg.CleanupSeconds
    $cfg.LogKeep        = Read-Int   'Log files to keep' $cfg.LogKeep
    $cfg.LogMaxMB       = Read-Int   'Max size per log file (MB)' $cfg.LogMaxMB

    while ($true) {
        $m = Read-Value 'Run mode: Logon (user session, needed for hang detection) / Startup (SYSTEM at boot)' $cfg.RunMode
        if ($m -in 'Logon','Startup') { $cfg.RunMode = (Get-Culture).TextInfo.ToTitleCase($m.ToLower()); break }
        Write-Host 'Type Logon or Startup.' -ForegroundColor Yellow
    }
    if ($cfg.RunMode -eq 'Logon') {
        $def = if ($cfg.TaskUser) { $cfg.TaskUser } else { Get-ConsoleUser }
        $cfg.TaskUser = Read-Value 'Run as user (DOMAIN\user)' $def
        $cfg.HeadlessLauncher = (Read-Value 'Hide console completely with conhost --headless? (y/n)' ($(if ($cfg.HeadlessLauncher) {'y'} else {'n'}))) -eq 'y'
    }

    Save-Config $cfg
    if (Get-MonitorTask) {
        if ((Read-Host 'Re-register task and restart monitor with new settings? (Y/n)') -ne 'n') {
            Stop-Monitor $cfg
            Register-MonitorTask $cfg
            Start-MonitorTask
        }
    }
    return $cfg
}

function Show-Status {
    $cfg  = Read-Config
    $task = Get-MonitorTask
    Write-Host "`n--- Status ---" -ForegroundColor Cyan
    if ($task) {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName
        Write-Host ("Task       : {0}  (last run {1}, result 0x{2:X})" -f $task.State, $info.LastRunTime, $info.LastTaskResult)
        Write-Host ("Runs as    : {0}" -f $task.Principal.UserId)
    } else { Write-Host 'Task       : not installed' -ForegroundColor Yellow }

    Write-Host ("ProcDump   : {0}" -f $(if (Test-Path $ProcDumpExe) { "$ProcDumpExe ($((Get-Item $ProcDumpExe).VersionInfo.FileVersion))" } else { 'not downloaded' }))
    Write-Host ("Version    : installed {0} | this script {1}" -f (Format-Version (Get-ScriptVersionFromFile $InstalledScript)), $ScriptVersion)
    Write-Host ("Apps       : {0}" -f ($cfg.Apps -join ', '))

    $pd = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'procdump%'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -like "$ToolsDir\*" })
    Write-Host ("Monitors   : {0} running" -f $pd.Count)
    $pd | ForEach-Object { Write-Host ("             PID {0}: {1}" -f $_.ProcessId, ($_.CommandLine -replace '^.*?\.exe"?\s*', '')) }

    $dumps = @(Get-ChildItem $cfg.DumpDir -Filter *.dmp -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    $size  = ($dumps | Measure-Object Length -Sum).Sum / 1GB
    Write-Host ("Dumps      : {0} of max {1} in {2} ({3:N2} GB)" -f $dumps.Count, $cfg.KeepDumps, $cfg.DumpDir, $size)
    if ($dumps) { Write-Host ("Newest     : {0}  {1}" -f $dumps[0].LastWriteTime, $dumps[0].Name) }

    $log = Get-ChildItem $LogDir -Filter "${AppName}_*.log" -File -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($log) {
        Write-Host ("Latest log : {0}" -f $log.FullName)
        Get-Content $log.FullName -Tail 10 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }
    }
}

function Show-Menu {
    while ($true) {
        $installed = [bool](Get-MonitorTask)
        Write-Host "`n========== $AppName ==========" -ForegroundColor Cyan
        $iv = Get-ScriptVersionFromFile $InstalledScript
        Write-Host ("This script: v{0}   Installed: {1}   Config: {2}" -f $ScriptVersion, (Format-Version $iv),
                    $(if (Test-Path $ConfigFile) {$ConfigFile} else {'not created'}))
        if ($iv -and $iv -lt [version]$ScriptVersion -and $PSCommandPath -ne $InstalledScript) {
            Write-Host "   >> Update available: $(Format-Version $iv) -> $ScriptVersion  (choose U)" -ForegroundColor Green
        }
        Write-Host ' 1) Setup / edit configuration'
        Write-Host ' 2) Enable Service (download ProcDump, register the persistent scheduled task, start)'
        Write-Host ' 3) Status'
        Write-Host ' 4) Start monitor (starts the service if enabled, otherwise a non-persistent run)'
        Write-Host ' 5) Stop monitor'
        Write-Host ' 6) Run monitor in this window (testing, Ctrl+C to stop)'
        Write-Host ' 7) Update Sysinternals Suite to latest'
        Write-Host ' 8) Open dump folder'
        Write-Host ' 9) Disable Service (remove the scheduled task)'
        Write-Host ' U) Update installed copy from this script (version check, backup, keeps config)'
        Write-Host ' Q) Quit'
        switch ((Read-Host 'Select').Trim().ToUpper()) {
            '1' { $null = Edit-Config (Read-Config) }
            '2' { Enable-Service }
            '3' { Show-Status }
            '4' { Start-Monitor }
            '5' { Stop-Monitor (Read-Config) }
            '6' { Invoke-Monitor; $script:LogPrefix = "$AppName-Setup"; New-LogFile }
            '7' { $cfg = Read-Config; $was = $installed -and (Get-MonitorTask).State -eq 'Running'
                  if ($was) { Stop-Monitor $cfg }
                  $null = Install-Sysinternals -Force
                  if ($was) { Start-MonitorTask } }
            '8' { $d = (Read-Config).DumpDir; if (Test-Path $d) { Start-Process explorer.exe $d } else { Write-Host 'Folder does not exist yet.' } }
            '9' { if ((Read-Host 'Really disable the service? (y/N)') -eq 'y') { Disable-Service } }
            'U' { Invoke-Update }
            'Q' { return }
            default { Write-Host 'Unknown choice.' -ForegroundColor Yellow }
        }
    }
}

# =============================== MONITOR =================================
function Invoke-Monitor {
    $script:LogPrefix = $AppName
    New-LogFile

    $mutex = New-Object System.Threading.Mutex($false, $MutexName)
    $owned = $false
    try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { Write-Log 'Another monitor instance is already running - exiting.' 'WARN'; $mutex.Dispose(); return }

    $cfg = Read-Config
    $script:LogMaxMB = $cfg.LogMaxMB
    $monitors    = @{}
    $stopRequested = $false
    $lastCleanup = [datetime]::MinValue
    $lastTelemetry = Get-Date      # don't flush immediately on startup; wait one interval
    $cfgStamp    = if (Test-Path $ConfigFile) { (Get-Item $ConfigFile).LastWriteTimeUtc } else { $null }

    try {
        Write-Log ('=' * 70)
        Write-Log "Monitor v$ScriptVersion starting. User: $env:USERDOMAIN\$env:USERNAME  Session: $((Get-Process -Id $PID).SessionId)  PS: $($PSVersionTable.PSVersion)"
        Write-Log "Apps: $($cfg.Apps -join ', ') | Args: $(Get-EffectiveArgs $cfg) | Keep $($cfg.KeepDumps) dumps | Check $($cfg.CheckSeconds)s | Cleanup $($cfg.CleanupSeconds)s | Cooldown $($cfg.CooldownSeconds)s | Duplicates: $($cfg.DuplicateAction)"

        if (-not (Test-Path $ProcDumpExe) -and -not (Install-Sysinternals)) {
            Write-Log 'ProcDump missing and could not be installed - exiting.' 'ERROR'
            $script:ExitCode = 1; return
        }
        if (-not $cfg.Apps) { Write-Log 'No apps configured - exiting.' 'ERROR'; $script:ExitCode = 1; return }
        New-Item -ItemType Directory -Path $cfg.DumpDir -Force | Out-Null

        Remove-Item $StopFile -Force -ErrorAction SilentlyContinue   # stale request from earlier
        Stop-ProcDumpInstances $cfg      # detach orphans from a previous run (gracefully)
        $monitors = Get-AdoptedMonitors $cfg   # any that refused to detach: keep, don't duplicate

        $seenProcs = @{}                 # app -> comma list of running PIDs
        $lastInfo  = @{}                 # app -> version lines of latest running instance(s)
        $pending   = @{}                 # dump path -> size while it is being written
        $recent    = @{}                 # app -> last primary dump (duplicate detection)
        $cooldown  = @{}                 # app -> @{ Until; Pids } - don't re-arm on the same process yet
        $known     = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        Get-ChildItem -Path $cfg.DumpDir -Filter *.dmp -File -ErrorAction SilentlyContinue |
            ForEach-Object { [void]$known.Add($_.FullName) }   # existing dumps: not re-analysed

        while ($true) {
            if (Test-Path $StopFile) {
                Write-Log 'Stop requested.'
                $stopRequested = $true
                Remove-Item $StopFile -Force -ErrorAction SilentlyContinue
                break
            }

            # 0) Track exe versions of running apps; analyse finished dumps (reason, duplicates)
            Update-AppVersions $cfg $seenProcs $lastInfo
            Invoke-NewDumps $cfg $known $pending $recent $lastInfo

            $pdArgs = Get-EffectiveArgs $cfg

            # 1) Keep one ProcDump per app armed, and copy its output into the log
            foreach ($app in $cfg.Apps) {
                $st = $monitors[$app]
                if ($st -and -not $st.Process.HasExited) { Read-ProcDumpOutput $st; continue }

                $appName = [IO.Path]::GetFileNameWithoutExtension($app)
                $pidsNow = (@(Get-Process -Name $appName -ErrorAction SilentlyContinue) | ForEach-Object { $_.Id } | Sort-Object) -join ','

                if ($st) {
                    Close-ProcDumpCapture $st
                    $monitors.Remove($app)
                    $code = try { $st.Process.ExitCode } catch { '?' }
                    $made = @(Get-ChildItem -Path $cfg.DumpDir -Filter "ProcDump_*_${appName}_*.dmp" -File -ErrorAction SilentlyContinue |
                              Where-Object { $_.CreationTime -ge $st.Started.AddSeconds(-2) })
                    # Re-arm cooldown. Wait before re-arming whenever the SAME process is still alive - not only
                    # after a dump was written - and never faster than 60s, so a ProcDump that keeps exiting (caught
                    # nothing, or a saved config with a low/zero CooldownSeconds) cannot spin the monitor in a tight
                    # re-arm loop. A changed/absent PID set clears the cooldown immediately (see below), so a genuinely
                    # new process is still picked up promptly.
                    $coolSecs = [Math]::Max([int]$cfg.CooldownSeconds, 60)
                    if ($pidsNow) {
                        $cooldown[$app] = @{ Until = (Get-Date).AddSeconds($coolSecs); Pids = $pidsNow }
                        $wrote = if ($made) { 'after writing a dump' } else { 'without a new dump' }
                        Write-Log "ProcDump for $app exited $wrote (code $code). $app is still running (PID $pidsNow) - re-arming in ${coolSecs}s, or as soon as a new $app process starts."
                    } else {
                        Write-Log "ProcDump for $app exited (code $code); $app not running - re-arming (ProcDump waits for it to start)."
                    }
                }

                # cooldown: same process(es) still alive and time not up -> wait
                $cd = $cooldown[$app]
                if ($cd) {
                    if ((Get-Date) -lt $cd.Until -and $pidsNow -eq $cd.Pids) { continue }
                    $cooldown.Remove($app)
                    Write-Log "Cooldown for $app over$(if ($pidsNow -ne $cd.Pids) { ' (process changed)' }) - re-arming ProcDump."
                }

                # Dump filename template. ProcDump can only substitute PROCESSNAME/YYMMDD/HHMMSS and has no token
                # for which trigger (exception vs hang) fired, so we capture with a placeholder tag ('pending')
                # and Invoke-NewDumps renames to the final ProcDump_<pc>_<process>_<tag>_<yyyyMMdd>_<HHmmss>.dmp
                # once it has read the dump's reason. The computer name makes a dump's origin obvious.
                $dumpTemplate = Join-Path $cfg.DumpDir ('ProcDump_{0}_PROCESSNAME_pending_YYMMDD_HHMMSS.dmp' -f $env:COMPUTERNAME)
                $argLine = "$pdArgs $app `"$dumpTemplate`""
                try {
                    # Capture with the ProcDump matching the app's bitness so the dump stays walkable for a
                    # 32-bit (WOW64) app. Self-corrects once the app is running (bitness read from the process).
                    $pdSel = Get-ProcDumpExeForApp $app
                    $monitors[$app] = Start-ProcDumpCaptured $app $argLine $pdSel.Path
                    $attach = if ($pidsNow) { "attaching to running $app (PID $pidsNow)" } else { "watching for $app to start (none running yet)" }
                    Write-Log "ProcDump armed ($($pdSel.Bits)-bit $($pdSel.Name)) - $attach. Launcher PID $($monitors[$app].Process.Id)."
                } catch {
                    Write-Log "Failed to start ProcDump for ${app}: $($_.Exception.Message)" 'ERROR'
                }
            }

            # 2) Housekeeping on its own timer
            if (((Get-Date) - $lastCleanup).TotalSeconds -ge $cfg.CleanupSeconds) {
                $lastCleanup = Get-Date

                Get-ChildItem -Path $cfg.DumpDir -Filter *.dmp -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -Skip $cfg.KeepDumps |
                    ForEach-Object {
                        try {
                            Remove-Item $_.FullName -Force -ErrorAction Stop
                            Remove-Item ([IO.Path]::ChangeExtension($_.FullName, '.info.txt')) -Force -ErrorAction SilentlyContinue
                            Write-Log "Deleted old dump $($_.Name)"
                        }
                        catch { Write-Log "Could not delete $($_.Name) (in use?), will retry." 'WARN' }
                    }
                # info/version files whose dump is gone (.versions.txt = older script version)
                Get-ChildItem -Path $cfg.DumpDir -Filter *.txt -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '\.(info|versions)\.txt$' -and
                                   -not (Test-Path -LiteralPath ($_.FullName -replace '\.(info|versions)\.txt$', '.dmp')) } |
                    Remove-Item -Force -ErrorAction SilentlyContinue

                Update-LogRoll
                Remove-OldLogs $cfg.LogKeep
                Remove-OldProcDumpLogs $cfg.LogKeep @($monitors.Values | ForEach-Object { $_.File })
                Remove-Item (Join-Path $LogDir 'ProcDumpOutput') -Recurse -Force -ErrorAction SilentlyContinue   # folder from older version

                # Bound the forwarded-event archive (KnownIssues\outbox\sent) so it cannot grow without limit.
                $sentDir = Join-Path (Get-KnownIssuesDir) 'outbox\sent'
                if (Test-Path -LiteralPath $sentDir) {
                    Get-ChildItem -LiteralPath $sentDir -Filter *.json -File -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending | Select-Object -Skip 500 |
                        Remove-Item -Force -ErrorAction SilentlyContinue
                }

                # Pick up config changes without reinstalling
                $stamp = if (Test-Path $ConfigFile) { (Get-Item $ConfigFile).LastWriteTimeUtc } else { $null }
                if ($stamp -ne $cfgStamp) {
                    Write-Log 'Config file changed - reloading and restarting ProcDump instances.'
                    $cfgStamp = $stamp
                    Stop-ProcDumpInstances $cfg
                    $monitors.Values | ForEach-Object { Close-ProcDumpCapture $_ }
                    $cfg = Read-Config
                    $script:LogMaxMB = $cfg.LogMaxMB
                    $monitors = Get-AdoptedMonitors $cfg
                    $seenProcs = @{}
                    $cooldown  = @{}
                    New-Item -ItemType Directory -Path $cfg.DumpDir -Force | Out-Null
                    $lastCleanup = [datetime]::MinValue
                    continue
                }
            }

            # 3) Telemetry flush on its own timer (off unless enabled + endpoints configured). Detached, so
            #    network egress never blocks the loop; forwards events, syncs known-sigs, uploads new-sig dumps.
            if ($cfg.TelemetryEnabled -and ((Get-Date) - $lastTelemetry).TotalSeconds -ge $cfg.TelemetrySeconds) {
                $lastTelemetry = Get-Date
                Enqueue-Telemetry
            }

            Start-Sleep -Seconds $cfg.CheckSeconds
        }
    }
    catch {
        Write-Log "Fatal error, monitor stopped: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))" 'ERROR'
    }
    finally {
        Write-Log 'Monitor stopping.'
        # Requested stop or foreground test run: detach every ProcDump gracefully before exiting.
        # (On a crash of the monitor itself, ProcDump keeps running and is taken over at next start.)
        if ($stopRequested -or $script:EchoLog) {
            Stop-ProcDumpInstances $cfg
            $monitors.Values | ForEach-Object { Close-ProcDumpCapture $_ }
        } else {
            $monitors.Values | ForEach-Object { Read-ProcDumpOutput $_ -Final }
        }
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }
}

# =============================== ENTRY POINT =============================
# Loaded as a library (RT_LIBRARY=1, e.g. the GUI runspace dot-sources this for its functions): expose
# functions only, no auto-run. BUT an explicit action switch must still run: a monitor/worker the GUI
# launches as its own process (Start-MonitorRun, Enqueue-DumpTriage) inherits RT_LIBRARY=1 from the GUI's
# process environment, and must not be silenced by it - that would "start" a process that does nothing.
if ($env:RT_LIBRARY -eq '1' -and -not ($Monitor -or $Install -or $Update -or $Uninstall -or $Triage)) { return }

if ($Monitor) {
    Invoke-Monitor
    exit $script:ExitCode
}

# On-demand fault-id + dedupe over the configured dump folder (no admin needed).
if ($Triage) {
    $cfg = Read-Config
    if (-not (Test-Path $InstalledTriage)) { Write-Host 'DumpTriage.ps1 not found.' -ForegroundColor Red; exit 1 }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $InstalledTriage -DumpDir $cfg.DumpDir
    exit $LASTEXITCODE
}

if (-not (Test-Admin)) {
    $sw = if ($Install) { ' -Install' } elseif ($Update) { ' -Update' } elseif ($Uninstall) { ' -Uninstall' } else { '' }
    if ($Force) { $sw += ' -Force' }
    Write-Host 'Administrator rights required - relaunching elevated...'
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"$sw"
    exit
}

$script:LogPrefix = "$AppName-Setup"
New-LogFile
$script:EchoLog = -not ($Install -or $Update -or $Uninstall)   # menu mode prints to console; switches are silent
$script:Interactive = $script:EchoLog                          # only the console menu can Read-Host
Write-Log "Setup session (v$ScriptVersion) started by $env:USERDOMAIN\$env:USERNAME from $PSCommandPath"

if     ($Install)   { Enable-Service }
elseif ($Update)    { Invoke-Update }
elseif ($Uninstall) { Disable-Service }
else                { Show-Menu }
