#Requires -Version 5.1
<#
.SYNOPSIS
  PerfView capture console: installs PerfView, then starts / stops machine-wide performance traces
  (ETW/ETL) using selectable collection profiles that keep the trace size under control. Also reaches
  the temporary one-shot process-dump capture (ProcDumpCase.ps1) from the same menu.

  PerfView is "installed" (resolved, Microsoft-signature-verified, parked in a known Tools folder).
  ProcDump capture stays TEMPORARY - it is delegated to ProcDumpCase.ps1 and nothing is installed.

.USAGE
  Interactive (menu: setup, install, status, start/stop capture, abort, procdump):
      powershell -ExecutionPolicy Bypass -File .\PerfViewCapture.ps1
  Unattended:
      ...\PerfViewCapture.ps1 -Install
      ...\PerfViewCapture.ps1 -Start [-Profile Balanced] [-Label 6.0.0.222] [-Seconds 0]
      ...\PerfViewCapture.ps1 -Stop                    # stop the running capture (fires the stop event)
      ...\PerfViewCapture.ps1 -Abort
      ...\PerfViewCapture.ps1 -Status
      ...\PerfViewCapture.ps1 -SendStopEvent           # same as -Stop: fires the stop event
      ...\PerfViewCapture.ps1 -Uninstall

  ONE capture model for every trace: -Start runs a single PerfView 'collect' that ALWAYS arms the stop
  event, so it can be stopped at any time with -Stop (or from the GUI, or by any process writing the
  event). -Seconds adds a hard time cap ONLY when > 0; -Seconds 0 (default) means no limit - it runs
  until stopped. On stop it merges + zips and reports the output file. -CollectTimed is a kept alias for
  -Start (the stop event is always on now). -Abort force-cancels a stuck session WITHOUT saving data.

.VERSION
  $ScriptVersion is stamped automatically from the repo VERSION by scripts\New-Release.ps1 at release time -
  NEVER edit it by hand. Release history lives in CHANGELOG.md and the GitHub releases.

.FILES
  App data under the one app root %ProgramData%\ReportingTroubleshooting\PerfView\ :
      config.json                              settings + collection profiles
      active.json                              state of the current background trace
      Symbols\                                 PerfView's own symbol cache (_NT_SYMBOL_PATH downstream store)
      Logs\PerfViewCapture_<datetime>.log      one per menu/op session
      Logs\PerfView_<datetime>.log             PerfView's own output, one per start/stop/collect
  PerfView.exe lives in the shared store %ProgramData%\ReportingTroubleshooting\Packages\perfview\
  Trace OUTPUT (not app data) goes to the configured OutputDir (default C:\dumps\PerfView):
      PerfViewData_<computer>_<profile>_<label>_<datetime>.etl(.zip)
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Start,
    [switch]$Stop,
    [switch]$CollectTimed,
    [ValidateRange(0, 86400)][int]$Seconds = 0,   # 0 = no time cap (stop with -Stop / the event)
    [switch]$StopOnEvent,
    [switch]$Abort,
    [switch]$Status,
    [switch]$SendStopEvent,
    [switch]$Uninstall,
    [string]$Profile,
    [string]$Label,
    [string]$PerfViewPath,            # explicit source PerfView.exe for Install
    [string]$ParamFile               # internal: used when relaunching elevated
)

# =============================== VERSION =================================
# Stamped automatically by scripts\New-Release.ps1 from the repo VERSION - do not edit by hand.
$ScriptVersion = '1.0.40'

# =============================== CONSTANTS ===============================
$AppName     = 'PerfViewCapture'
$BaseDir     = Join-Path $env:ProgramData 'ReportingTroubleshooting\PerfView'   # all app data lives under the one app root
$ConfigFile  = Join-Path $BaseDir 'config.json'
$ActiveFile  = Join-Path $BaseDir 'active.json'
$LogDir      = Join-Path $BaseDir 'Logs'
$SymbolDir   = Join-Path $BaseDir 'Symbols'                        # PerfView's own symbol cache (subfolder of the app root)
$SessionName = 'PerfViewCapture'                     # fixed ETW session name for start/stop/abort pairing
$StopEventSource = 'PerfViewStop'
$StopEventText   = 'PERFVIEW_STOP_NOW'
# $ToolsDir / $PerfViewExe are set from the shared package store after Packages.ps1 is dot-sourced below.
$ScriptDir   = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }

$script:LogFile   = $null
$script:LogBase   = $null
$script:LogPart   = 1
$script:LogCount  = 0
$script:LogPrefix = $AppName
$script:EchoLog   = $false        # also print log lines to the console (interactive use)
$script:LogMaxMB  = 10
$script:ExitCode  = 0

# =============================== SHARED COMPONENTS ======================
# Dot-sourced so they run in this script's scope and use the $script: logging state + $LogDir/$AppName
# above. Provides: New-LogFile/Write-Log/Update-LogRoll/Remove-OldLogs, Test-Admin, Get-ConsoleUser,
# Test-MicrosoftSignature, Read-Value/Read-Int/Read-Bool, Get-ScriptVersionFromFile, Format-Version.
$CommonDir = $null; $__probe = $ScriptDir
for ($__i = 0; $__i -lt 6 -and -not $CommonDir; $__i++) {
    foreach ($__c in @((Join-Path $__probe 'Common'), (Join-Path $__probe 'Scripts\Common'))) {
        if (Test-Path (Join-Path $__c 'Common.ps1')) { $CommonDir = $__c; break }
    }
    $__parent = Split-Path $__probe -Parent
    if (-not $__parent -or $__parent -eq $__probe) { break }
    $__probe = $__parent
}
if (-not $CommonDir) { throw "Shared components (Common\) not found from $ScriptDir upward." }
. (Join-Path $CommonDir 'Logging.ps1')
. (Join-Path $CommonDir 'Common.ps1')
. (Join-Path $CommonDir 'Packages.ps1')

# PerfView binary lives in the shared package store - single source of truth: Common\Packages.ps1.
$ToolsDir    = Get-PackageDir 'perfview'
$PerfViewExe = Join-Path $ToolsDir 'PerfView.exe'

# =============================== CONFIG ==================================
# Shipped collection profiles, smallest-first. CircularMB caps the trace size (the "it gets HUGE" fix):
# the circular buffer drops the oldest events once the cap is hit, so the file never grows past it.
function Get-DefaultProfiles {
    @(
        [pscustomobject]@{
            Name = 'Lean'
            Description  = 'CPU stacks + .NET (GC/JIT). Smallest. Start here for pure CPU/managed hangs.'
            KernelEvents = 'Default,ThreadTime'
            ClrEvents    = 'Default'
            Providers    = ''
            CircularMB   = 2048
            BufferSizeMB = 1024
            ExtraArgs    = ''
        },
        [pscustomobject]@{
            Name = 'Balanced'
            Description  = 'Lean + file/disk I/O + memory hard faults. Good default for slow/stall cases.'
            KernelEvents = 'Default,ThreadTime,FileIOInit,FileIO,DiskIO,MemoryHardFaults'
            ClrEvents    = 'Default'
            Providers    = 'Microsoft-Windows-Kernel-Memory'
            CircularMB   = 2048
            BufferSizeMB = 1024
            ExtraArgs    = ''
        },
        [pscustomobject]@{
            Name = 'Full'
            Description  = 'Everything from the notes incl. VirtualAlloc + TCPIP. Largest; use when cause is unknown.'
            KernelEvents = 'Default,ThreadTime,FileIOInit,FileIO,DiskIO,MemoryHardFaults,VirtualAlloc,NetworkTCPIP'
            ClrEvents    = 'Default'
            Providers    = 'Microsoft-Windows-Kernel-Memory,Microsoft-Windows-TCPIP'
            CircularMB   = 4096
            BufferSizeMB = 1024
            ExtraArgs    = ''
        },
        [pscustomobject]@{
            Name = 'Max'
            Description  = 'Full event set with a 20 GB circular buffer - deepest/longest capture. Pair with a long collect (Merge/Zip on; e.g. a 900 s timed collect, or Start then Stop when the problem is reproduced).'
            KernelEvents = 'Default,ThreadTime,FileIOInit,FileIO,DiskIO,MemoryHardFaults,VirtualAlloc,NetworkTCPIP'
            ClrEvents    = 'Default'
            Providers    = 'Microsoft-Windows-Kernel-Memory,Microsoft-Windows-TCPIP'
            CircularMB   = 20000
            BufferSizeMB = 1024
            ExtraArgs    = ''
        }
    )
}

function Get-DefaultConfig {
    [pscustomobject]@{
        OutputDir      = 'C:\dumps\PerfView'
        DefaultProfile = 'Balanced'
        Merge          = $true
        Zip            = $true
        SymbolPath     = ''        # exported as _NT_SYMBOL_PATH before a merge/collect; blank = default (Get-SymbolPath: cache in PerfView's own Symbols subfolder + the MS public server)
        LastLabel      = ''
        LogKeep        = 20
        LogMaxMB       = 10
        Profiles       = Get-DefaultProfiles
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
    if (-not $cfg.Profiles) { $cfg.Profiles = Get-DefaultProfiles }
    else {
        # Append any built-in profile the saved config doesn't have yet (by name), so new built-ins (e.g.
        # 'Max') reach existing installs without discarding the user's own/edited profiles.
        $have = @($cfg.Profiles | ForEach-Object { $_.Name })
        foreach ($d in Get-DefaultProfiles) { if ($have -notcontains $d.Name) { $cfg.Profiles = @($cfg.Profiles) + $d } }
    }
    return $cfg
}

function Save-Config($cfg) {
    if (-not (Test-Path $BaseDir)) { New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null }
    $cfg | ConvertTo-Json -Depth 6 | Set-Content -Path $ConfigFile -Encoding UTF8
    Write-Log "Config saved to $ConfigFile"
}

function Get-Profile($cfg, [string]$Name) {
    if (-not $Name) { $Name = $cfg.DefaultProfile }
    $p = $cfg.Profiles | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if (-not $p) {
        $p = $cfg.Profiles | Where-Object { $_.Name -ieq $cfg.DefaultProfile } | Select-Object -First 1
    }
    if (-not $p) { $p = $cfg.Profiles | Select-Object -First 1 }
    return $p
}

# Resolve the _NT_SYMBOL_PATH to export for a merge/collect. A custom cfg.SymbolPath wins; otherwise
# PerfView caches into its OWN Symbols subfolder (not the shared C:\Symbols) backed by the MS public server.
# Always creates the cache dir so PerfView can write to it.
function Get-SymbolPath($cfg) {
    $sp = "$($cfg.SymbolPath)".Trim()
    if (-not $sp) { $sp = "SRV*$SymbolDir*https://msdl.microsoft.com/download/symbols" }
    # Make sure any local down-stream cache dir(s) referenced exist (SRV*<dir>*... or plain path).
    foreach ($m in [regex]::Matches($sp, '(?i)(?:SRV\*)?([A-Za-z]:\\[^*;]+)')) {
        $dir = $m.Groups[1].Value.Trim()
        if ($dir -and $dir -notmatch '^https?:') { New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null }
    }
    return $sp
}

# =============================== ACTIVE STATE ============================
function Save-ActiveState($state) {
    if (-not (Test-Path $BaseDir)) { New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null }
    $state | ConvertTo-Json -Depth 4 | Set-Content -Path $ActiveFile -Encoding UTF8
}
function Read-ActiveState {
    if (-not (Test-Path $ActiveFile)) { return $null }
    try { Get-Content $ActiveFile -Raw | ConvertFrom-Json } catch { $null }
}
function Clear-ActiveState { Remove-Item $ActiveFile -Force -ErrorAction SilentlyContinue }

# =============================== INSTALL PERFVIEW =======================
# Delegates to the shared package engine (Common\Packages.ps1). Local PerfView.exe candidates (an explicit
# -PerfViewPath, one next to this script, or one on PATH) are preferred over downloading - offered to the
# engine as local sources; it verifies the Microsoft signature either way.
function Install-PerfView([switch]$Force) {
    $candidates = @()
    if ($PerfViewPath) { $candidates += $PerfViewPath }
    $candidates += (Join-Path $ScriptDir 'PerfView.exe')
    return (Install-Package 'perfview' -Force:$Force -LocalSource $candidates)
}

# =============================== PERFVIEW RUN ============================
# Builds the shared provider/buffer arguments from a profile (no verb, no data file).
function Get-ProfileArgs($p) {
    $a = @("/BufferSizeMB:$($p.BufferSizeMB)", "/CircularMB:$($p.CircularMB)")
    if ($p.KernelEvents) { $a += "/KernelEvents:$($p.KernelEvents)" }
    if ($p.ClrEvents)    { $a += "/ClrEvents:$($p.ClrEvents)" }
    if ($p.Providers)    { $a += "/Providers:$($p.Providers)" }
    if ($p.ExtraArgs)    { $a += ($p.ExtraArgs -split '\s+' | Where-Object { $_ }) }
    return $a
}

# Tails PerfView's own /LogFile while it runs and surfaces progress: notable phase lines (merging,
# zipping, symbol resolution, ...) as they are written, plus an elapsed-time heartbeat so long, quiet
# steps (merge/zip on Stop, the whole duration of a collect) don't look frozen. Reads the log
# share-friendly so it never blocks PerfView's own writes.
#
# PerfView writes one terminal line per command - "[DONE <time> SUCCESS: ...]" or "[DONE ... FAIL: ...]"
# - and can then stay resident (e.g. blocked on a "press enter to close" wait on an inherited console),
# so we must NOT wait on process exit alone or the heartbeat runs forever after the work is finished.
# That DONE line is the authoritative completion signal; on seeing it we stop and report its result.
# Returns @{ Done=<bool seen>; Success=<bool> }.
function Watch-PerfViewProgress([System.Diagnostics.Process]$Proc, [string]$LogPath, [string]$What) {
    $started  = Get-Date
    $lastEmit = Get-Date
    $pos      = 0L
    $prev     = ''
    $done     = $false
    $success  = $false
    $phaseRx  = '(?i)\b(start|stopp|stopped|merg|zip|resolv|convert|collect|symbol|writing|complet|done|elapsed|error|warn)'
    while (-not $Proc.HasExited -and -not $done) {
        Start-Sleep -Milliseconds 500
        if (Test-Path $LogPath) {
            try {
                $fs = New-Object System.IO.FileStream($LogPath, [System.IO.FileMode]::Open,
                        [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try {
                    if ($fs.Length -gt $pos) {
                        $fs.Position = $pos
                        $sr = New-Object System.IO.StreamReader($fs)
                        $chunk = $sr.ReadToEnd(); $pos = $fs.Position; $sr.Dispose()
                        foreach ($ln in ($chunk -split "`r?`n")) {
                            $t = $ln.Trim()
                            if ($t -and $t -match $phaseRx -and $t -ne $prev) {
                                if ($t.Length -gt 140) { $t = $t.Substring(0, 137) + '...' }
                                Write-Log "  $t"; $prev = $t; $lastEmit = Get-Date
                            }
                            if ($t -match '\[DONE\b') { $done = $true; $success = ($t -match '(?i)\bSUCCESS\b') }
                        }
                    }
                } finally { $fs.Dispose() }
            } catch { }
        }
        if (-not $done -and ((Get-Date) - $lastEmit).TotalSeconds -ge 30) {   # 30s heartbeat: liveness without flooding a long capture
            Write-Log ("{0}: working... {1}s elapsed" -f $What, [int]((Get-Date) - $started).TotalSeconds)
            $lastEmit = Get-Date
        }
    }
    return @{ Done = $done; Success = $success }
}

# Runs PerfView with its own per-op log file and surfaces live progress (see Watch-PerfViewProgress).
function Invoke-PerfView([string[]]$PerfViewArgs, [string]$What) {
    if (-not (Test-Path $PerfViewExe)) {
        if (-not (Install-PerfView)) { Write-Log 'PerfView is not installed and could not be acquired.' 'ERROR'; return 1 }
    }
    $pvLog = Join-Path $LogDir ('PerfView_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))
    $full  = @('/AcceptEULA', "/LogFile:$pvLog", "/SessionName:$SessionName") + $PerfViewArgs
    Write-Log "$What : PerfView $($full -join ' ')"
    try {
        # -PassThru without -Wait so we can tail the log and report progress while it runs.
        $proc = Start-Process -FilePath $PerfViewExe -ArgumentList $full -NoNewWindow -PassThru -ErrorAction Stop
        $r = Watch-PerfViewProgress $proc $pvLog $What
        if ($proc.HasExited) {
            $code = $proc.ExitCode
        } elseif ($r.Done) {
            # Work finished (DONE in the log) but PerfView is still resident - give it a moment, then release
            # it so the job can complete. Trust the log's SUCCESS/FAIL for the result code.
            if (-not $proc.WaitForExit(5000)) {
                Write-Log "$What finished (per the PerfView log) but the process stayed resident - closing it." 'INFO'
                try { $proc.Kill() } catch { }
            }
            $code = if ($r.Success) { 0 } else { 1 }
        } else {
            $proc.WaitForExit(); $code = $proc.ExitCode
        }
        Write-Log "$What finished with exit code $code (PerfView log: $pvLog)" ($(if ($code -eq 0) {'INFO'} else {'WARN'}))
        return $code
    } catch {
        Write-Log "$What failed to launch PerfView: $($_.Exception.Message)" 'ERROR'
        return 1
    }
}

function Get-OutFile($cfg, $p, [string]$Label) {
    $safeProfile = ($p.Name -replace '[^\w\-]', '_')
    $safeLabel   = if ($Label) { '_' + ($Label -replace '[^\w\-\.]', '_') } else { '' }
    # Prefix with the computer name so a trace's origin is obvious once collected from several machines.
    $name = 'PerfViewData_{0}_{1}{2}_{3:yyyyMMdd_HHmmss}.etl' -f $env:COMPUTERNAME, $safeProfile, $safeLabel, (Get-Date)
    Join-Path $cfg.OutputDir $name
}

# ONE capture model for every trace: a single `collect` that always arms the stop event
# (/StopOnEventLogMessage) so ANY trace can be stopped on demand with Stop-Trace, and adds a hard time
# cap (/MaxCollectSec) ONLY when MaxSeconds > 0 (0 = run until Stop / the event, no time limit). This
# call blocks (streaming progress) for the whole trace, then merges+zips and reports the file. Stop it
# from anywhere - even another process or the GUI while this is running - by firing the event (Stop-Trace).
function Start-Trace([string]$ProfileName, [string]$Label, [int]$MaxSeconds = 0) {
    $cfg = Read-Config
    $active = Read-ActiveState
    if ($active) {
        Write-Log "A trace is already active (profile '$($active.Profile)', file $($active.OutFile)). Stop or Abort it first." 'WARN'
        return
    }
    $p = Get-Profile $cfg $ProfileName
    New-Item -ItemType Directory -Path $cfg.OutputDir -Force | Out-Null
    $out = Get-OutFile $cfg $p $Label
    $env:_NT_SYMBOL_PATH = Get-SymbolPath $cfg; Write-Log "_NT_SYMBOL_PATH = $($env:_NT_SYMBOL_PATH)"

    $args = @('collect', $out) + (Get-ProfileArgs $p) +
            @("/StopOnEventLogMessage:$StopEventText", "/Merge:$([bool]$cfg.Merge)", "/Zip:$([bool]$cfg.Zip)")
    if ($MaxSeconds -gt 0) { $args += "/MaxCollectSec:$MaxSeconds" }

    Save-ActiveState ([pscustomobject]@{
        SessionName = $SessionName
        OutFile     = $out
        Profile     = $p.Name
        Label       = $Label
        MaxSeconds  = $MaxSeconds
        StartedUtc  = (Get-Date).ToUniversalTime().ToString('o')
    })
    if ($Label) { $cfg.LastLabel = $Label; Save-Config $cfg }

    $howStop = if ($MaxSeconds -gt 0) { "Stop any time (Stop button / '$StopEventText' event), or it ends automatically after ${MaxSeconds}s." }
               else { "No time limit - runs until you Stop it (fires the '$StopEventText' event)." }
    Write-Log "Capture started (profile '$($p.Name)'). $howStop  Output on stop: $out (+ .zip). Reproduce the problem, then Stop."

    $code = Invoke-PerfView $args 'Collect'
    Clear-ActiveState
    if ($code -eq 0) {
        $zip = "$out.zip"
        $f = if (Test-Path $zip) { $zip } elseif (Test-Path $out) { $out } else { $null }
        if ($f) { Write-Log ("Trace written: {0} ({1} MB)" -f $f, [math]::Round((Get-Item $f).Length / 1MB, 1)) }
        else    { Write-Log "Capture finished but $out / .zip not found - check the PerfView log." 'WARN' }
    } else {
        Write-Log 'Capture failed - check the PerfView log.' 'ERROR'
        $script:ExitCode = 1
    }
}

# Stop ANY running capture by firing the stop event the collect watches for. Returns immediately; the
# running Start-Trace (here or in another process) then stops, merges, zips and reports the file. Needs
# no admin, so it works from a separate runspace while a capture is blocking its own.
function Stop-Trace {
    $active = Read-ActiveState
    if (-not $active) { Write-Log 'No active trace recorded. If a session is orphaned, use Abort.' 'WARN'; return }
    Write-Log "Stopping capture: signalling '$StopEventText'. PerfView will stop, merge and zip, then report the output file."
    Send-StopEvent
}

# Back-compat shim: a timed collect is just a Start-Trace with a time cap. The stop event is always armed
# now, so -StopOnEventLog is accepted but redundant.
function Invoke-CollectTimed([string]$ProfileName, [string]$Label, [int]$MaxSeconds, [switch]$StopOnEventLog) {
    Start-Trace $ProfileName $Label $MaxSeconds
}

# Force-cancel: aborts the ETW session WITHOUT merging (data discarded). Use only to clear a stuck/orphaned
# session; the normal stop is Stop-Trace (which keeps the data).
function Stop-Abort {
    $code = Invoke-PerfView @('abort') 'Abort trace'
    Clear-ActiveState
    Write-Log ($(if ($code -eq 0) { 'Abort complete - any orphaned session cleared (no data saved).' } else { 'Abort returned non-zero (there may have been nothing to abort).' }))
}

function Send-StopEvent {
    # Fires the Application event a '/StopOnEventLogMessage' collect watches for. No admin needed.
    Write-Log "Writing stop event (source $StopEventSource, '$StopEventText') to the Application log."
    & eventcreate.exe /T INFORMATION /ID 999 /L APPLICATION /SO $StopEventSource /D $StopEventText | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Log "eventcreate returned $LASTEXITCODE." 'WARN' }
}

# =============================== STATUS =================================
function Get-LiveSession {
    try {
        $out = & logman.exe query -ets 2>$null
        return [bool]($out | Select-String -SimpleMatch $SessionName)
    } catch { return $false }
}

function Show-Status {
    $cfg = Read-Config
    Write-Host "`n--- Status ---" -ForegroundColor Cyan
    Write-Host ("PerfView   : {0}" -f $(if (Test-Path $PerfViewExe) { "$PerfViewExe ($((Get-Item $PerfViewExe).VersionInfo.FileVersion))" } else { 'not installed' }))
    Write-Host ("Script     : v{0}" -f $ScriptVersion)
    Write-Host ("Output dir : {0}" -f $cfg.OutputDir)
    Write-Host ("Symbols    : {0}" -f (Get-SymbolPath $cfg))
    Write-Host ("Default    : profile '{0}'   Merge={1} Zip={2}" -f $cfg.DefaultProfile, [bool]$cfg.Merge, [bool]$cfg.Zip)
    Write-Host ("Profiles   : {0}" -f (($cfg.Profiles | ForEach-Object { $_.Name }) -join ', '))

    $active = Read-ActiveState
    $live   = Get-LiveSession
    if ($active) {
        Write-Host ("Active     : profile '{0}' label '{1}' started {2}Z" -f $active.Profile, $active.Label, $active.StartedUtc) -ForegroundColor Green
        Write-Host ("             file (on stop): {0}" -f $active.OutFile)
    } else { Write-Host 'Active     : no trace recorded' -ForegroundColor Yellow }
    Write-Host ("ETW session: {0}" -f $(if ($live) { "'$SessionName' is running" } else { "'$SessionName' not present" }))
    if ($active -and -not $live) { Write-Host '             (recorded trace but no live session - consider Abort)' -ForegroundColor Yellow }
    if (-not $active -and $live) { Write-Host '             (live session but nothing recorded - Abort to clear it)' -ForegroundColor Yellow }

    $traces = @(Get-ChildItem $cfg.OutputDir -Filter 'PerfViewData_*' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    Write-Host ("Traces     : {0} in {1}" -f $traces.Count, $cfg.OutputDir)
    if ($traces) { Write-Host ("Newest     : {0}  {1}" -f $traces[0].LastWriteTime, $traces[0].Name) }

    $log = Get-ChildItem $LogDir -Filter "${AppName}_*.log" -File -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($log) {
        Write-Host ("Latest log : {0}" -f $log.FullName)
        Get-Content $log.FullName -Tail 8 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }
    }
}

# =============================== INTERACTIVE ============================
function Select-Profile($cfg, [string]$Purpose) {
    $names = @($cfg.Profiles | ForEach-Object { $_.Name })
    Write-Host "`nProfiles:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $names.Count; $i++) {
        $pp = $cfg.Profiles[$i]
        $mark = if ($pp.Name -ieq $cfg.DefaultProfile) { ' (default)' } else { '' }
        Write-Host ("  {0}) {1}{2} - {3}" -f ($i + 1), $pp.Name, $mark, $pp.Description)
    }
    $sel = Read-Value "$Purpose - number or name" $cfg.DefaultProfile
    $n = 0
    if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $names.Count) { return $names[$n - 1] }
    return $sel
}

function Edit-Profiles($cfg) {
    while ($true) {
        Write-Host "`n--- Profiles ---" -ForegroundColor Cyan
        for ($i = 0; $i -lt $cfg.Profiles.Count; $i++) {
            $p = $cfg.Profiles[$i]
            Write-Host ("  {0}) {1}  CircularMB={2} BufferMB={3}" -f ($i + 1), $p.Name, $p.CircularMB, $p.BufferSizeMB)
            Write-Host ("       Kernel={0}" -f $p.KernelEvents) -ForegroundColor DarkGray
            Write-Host ("       Clr={0}  Providers={1}" -f $p.ClrEvents, $p.Providers) -ForegroundColor DarkGray
        }
        Write-Host '  E) edit one   A) add   D) delete   S) set default   Q) back'
        $c = (Read-Host 'Select').Trim().ToUpper()
        switch ($c) {
            'E' {
                $n = (Read-Int 'Which profile number' 1 1) - 1
                if ($n -ge 0 -and $n -lt $cfg.Profiles.Count) { Edit-OneProfile $cfg.Profiles[$n] }
            }
            'A' {
                $np = [pscustomobject]@{ Name=''; Description=''; KernelEvents='Default,ThreadTime'; ClrEvents='Default'; Providers=''; CircularMB=2048; BufferSizeMB=1024; ExtraArgs='' }
                Edit-OneProfile $np
                if ($np.Name) { $cfg.Profiles = @($cfg.Profiles) + $np }
            }
            'D' {
                $n = (Read-Int 'Which profile number to delete' 1 1) - 1
                if ($n -ge 0 -and $n -lt $cfg.Profiles.Count) {
                    $rm = $cfg.Profiles[$n].Name
                    $cfg.Profiles = @($cfg.Profiles | Where-Object { $_.Name -ne $rm })
                    if ($cfg.DefaultProfile -eq $rm -and $cfg.Profiles) { $cfg.DefaultProfile = $cfg.Profiles[0].Name }
                }
            }
            'S' { $cfg.DefaultProfile = Select-Profile $cfg 'Set default' }
            'Q' { return $cfg }
            default { Write-Host 'Unknown choice.' -ForegroundColor Yellow }
        }
        Save-Config $cfg
    }
}

function Edit-OneProfile($p) {
    Write-Host "`n--- Edit profile (Enter keeps the current value) ---" -ForegroundColor Cyan
    $p.Name         = Read-Value 'Name' $p.Name
    $p.Description  = Read-Value 'Description' $p.Description
    $p.KernelEvents = Read-Value 'KernelEvents (comma list, blank = none)' $p.KernelEvents
    $p.ClrEvents    = Read-Value 'ClrEvents (blank = none)' $p.ClrEvents
    $p.Providers    = Read-Value 'Providers (comma list, blank = none)' $p.Providers
    $p.CircularMB   = Read-Int   'CircularMB (max trace size; caps the file)' ([int]$p.CircularMB) 0
    $p.BufferSizeMB = Read-Int   'BufferSizeMB' ([int]$p.BufferSizeMB) 1
    $p.ExtraArgs    = Read-Value 'Extra PerfView args (blank = none)' $p.ExtraArgs
}

function Edit-Config($cfg) {
    Write-Host "`n--- Setup (Enter keeps the current value) ---" -ForegroundColor Cyan
    $cfg.OutputDir  = Read-Value 'Output folder for traces' $cfg.OutputDir
    $cfg.Merge      = Read-Bool  'Merge the trace on stop' ([bool]$cfg.Merge)
    $cfg.Zip        = Read-Bool  'Zip the trace on stop' ([bool]$cfg.Zip)
    $cfg.SymbolPath = Read-Value "Symbol path for merge (_NT_SYMBOL_PATH, blank = cache in $SymbolDir + MS public server)" $cfg.SymbolPath
    $cfg.LogKeep    = Read-Int   'Log files to keep' ([int]$cfg.LogKeep)
    $cfg.LogMaxMB   = Read-Int   'Max size per log file (MB)' ([int]$cfg.LogMaxMB)
    $cfg.DefaultProfile = Select-Profile $cfg 'Default profile'
    Save-Config $cfg
    if ((Read-Value 'Edit collection profiles now? (y/n)' 'n') -match '^(y|yes)$') { $cfg = Edit-Profiles $cfg }
    return $cfg
}

function Show-Menu {
    while ($true) {
        $cfg    = Read-Config
        $active = Read-ActiveState
        Write-Host "`n========== $AppName ==========" -ForegroundColor Cyan
        Write-Host ("PerfView: {0}   Script: v{1}" -f $(if (Test-Path $PerfViewExe) { (Get-Item $PerfViewExe).VersionInfo.FileVersion } else { 'not installed' }), $ScriptVersion)
        if ($active) { Write-Host ("Active trace: profile '{0}' label '{1}'" -f $active.Profile, $active.Label) -ForegroundColor Green }
        Write-Host ' 1) Setup / edit configuration (profiles, output dir, symbols, zip/merge)'
        Write-Host ' 2) Install / verify PerfView'
        Write-Host ' 3) Status'
        Write-Host ' 4) Start capture      (pick profile, optional label, optional max seconds; 0 = until Stop)'
        Write-Host ' 5) Stop capture       (signal the stop event; it merges + zips and shows the output path)'
        Write-Host ' 7) Abort capture      (force-cancel a stuck/orphaned session, no data saved)'
        Write-Host ' 8) Open output folder'
        Write-Host ' U) Update PerfView to latest'
        Write-Host ' Q) Quit'
        switch ((Read-Host 'Select').Trim().ToUpper()) {
            '1' { $null = Edit-Config $cfg }
            '2' { $null = Install-PerfView }
            '3' { Show-Status }
            '4' {
                $prof  = Select-Profile $cfg 'Start capture'
                $label = Read-Value 'Version/patch label (optional)' $cfg.LastLabel
                $secs  = Read-Int 'Max seconds (0 = no limit, stop with option 5 or the event)' 0 0
                Start-Trace $prof $label $secs
            }
            '5' { Stop-Trace }
            '7' { Stop-Abort }
            '8' { if (Test-Path $cfg.OutputDir) { Start-Process explorer.exe $cfg.OutputDir } else { Write-Host 'Output folder does not exist yet.' } }
            'U' { $null = Install-PerfView -Force }
            'Q' { return }
            default { Write-Host 'Unknown choice.' -ForegroundColor Yellow }
        }
    }
}

# =============================== UNINSTALL =============================
function Invoke-Uninstall {
    $active = Read-ActiveState
    if ($active) { Write-Log 'Aborting active trace before uninstall.'; Stop-Abort }
    $delAll = $true
    if ($script:EchoLog) { $delAll = (Read-Host "Delete $BaseDir (PerfView, config, logs)? (Y/n)") -ne 'n' }
    if ($delAll) {
        Write-Log "Removing $BaseDir"
        $script:LogFile = $null
        Remove-Item $BaseDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'Uninstall complete.'
}

# =============================== ENTRY POINT ============================
# When loaded as a library (RT_LIBRARY=1, e.g. the GUI's background runspace) expose the functions only:
# no elevation, no logging session, no dispatch. The caller drives the functions directly.
if ($env:RT_LIBRARY -eq '1') { return }

# Starting / stopping / aborting a kernel ETW session, and installing, need admin. Status and the
# stop-event helper do not, so don't force elevation just to read state.
$needsAdmin = -not ($Status -or $SendStopEvent)

if ($ParamFile -and (Test-Path -LiteralPath $ParamFile)) {
    try {
        $saved = Import-Clixml -LiteralPath $ParamFile
        Remove-Item -LiteralPath $ParamFile -Force -ErrorAction SilentlyContinue
        foreach ($k in $saved.Keys) { Set-Variable -Name $k -Value $saved[$k] }
    } catch { }
}

if ($needsAdmin -and -not (Test-Admin) -and -not $ParamFile) {
    $h = @{}
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Key -eq 'ParamFile') { continue }
        $v = $kv.Value
        if ($v -is [System.Management.Automation.SwitchParameter]) { $v = $v.IsPresent }
        $h[$kv.Key] = $v
    }
    $pf = Join-Path $env:TEMP "PerfViewCapture_$PID.xml"
    $h | Export-Clixml -LiteralPath $pf
    try {
        Write-Host 'Administrator rights are needed for ETW collection - relaunching elevated...'
        Start-Process powershell.exe -Verb RunAs -ErrorAction Stop `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ParamFile `"$pf`""
        exit
    } catch {
        Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue
        Write-Host 'Elevation declined - some actions will fail without admin rights.' -ForegroundColor Yellow
    }
}

$unattended = $Install -or $Start -or $Stop -or $CollectTimed -or $Abort -or $Status -or $SendStopEvent -or $Uninstall
$script:EchoLog = -not $unattended
New-LogFile
Write-Log "Session (v$ScriptVersion) started by $env:USERDOMAIN\$env:USERNAME from $PSCommandPath"
$cfgBoot = Read-Config
$script:LogMaxMB = [int]$cfgBoot.LogMaxMB
Remove-OldLogs ([int]$cfgBoot.LogKeep)

if     ($Install)       { $null = Install-PerfView }
elseif ($Start)         { Start-Trace $Profile $Label $Seconds }   # -Seconds 0 (default) = until -Stop / event
elseif ($Stop)          { Stop-Trace }
elseif ($CollectTimed)  { Start-Trace $Profile $Label $Seconds }   # same path; the stop event is always armed
elseif ($Abort)         { Stop-Abort }
elseif ($Status)        { Show-Status }
elseif ($SendStopEvent) { Send-StopEvent }
elseif ($Uninstall)     { Invoke-Uninstall }
else                    { Show-Menu }

exit $script:ExitCode
