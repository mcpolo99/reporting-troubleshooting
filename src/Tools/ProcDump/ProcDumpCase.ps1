#Requires -Version 5.1
<#
.SYNOPSIS
  ProcDumpCase - one-shot "capture a case" tool. Launches an exe under ProcDump, collects the dumps
  plus the evidence needed for a reliable vendor/support report, and packs everything into one zip.
  Nothing is installed: no scheduled task, no service. Only ProcDump itself is downloaded if it
  can't be found on the machine.

.USAGE
  Interactive (prompts for exe, capture mode, assembly binding log):
      powershell -ExecutionPolicy Bypass -File .\ProcDumpCase.ps1

  The default is AGNOSTIC: when you pass no trigger (or -Auto), it catches a crash,
  a silent exit OR a hang in one run - use it when you don't yet know what's wrong.

  Examples:
      # Cause unknown - the usual starting point. Just point it at the exe:
      .\ProcDumpCase.ps1 -ExePath 'C:\BIESSE\bSuite\bSuite.exe'

      # Same, for a .NET app, with the assembly binding log on (helps "won't start"):
      .\ProcDumpCase.ps1 -ExePath 'C:\BIESSE\bSuite\bSuite.exe' -FusionLog

      # Once you DO know the cause, narrow it down:
      .\ProcDumpCase.ps1 -ExePath '...\bSuite.exe' -ExceptionFilter FileLoadException  # one named exception
      .\ProcDumpCase.ps1 -ExePath '...\App.exe' -Hang -TimeoutSeconds 600              # hang only
      .\ProcDumpCase.ps1 -ExePath '...\App.exe' -Auto -NoHang                          # agnostic, minus hang

  While capturing: press Q to stop (a snapshot dump is taken, ProcDump detaches, the app keeps running).

.WHAT IS COLLECTED  (<OutputRoot>\<computer>_<exe>_<datetime>\ and <same>.zip)
  Dumps\        ProcDump dumps (+ snapshot dump on timeout / Q)
  Logs\         procdump_output.txt, collect.log
  Events\       .evtx exports (Application, System, CodeIntegrity, AppLocker, Defender) for the last
                -EventHours hours, plus session_events.txt (only events during the capture, readable)
  Files\        signatures.csv (signature + Mark-of-the-Web of every exe/dll in the app folder),
                citool_policies.txt, WER reports for the app, FusionLog\ (if -FusionLog),
                app .config files (only with -IncludeAppConfig - they can contain passwords)
  system_info.txt, SUMMARY.txt   (findings, e.g. Code Integrity / Smart App Control blocks)

.NOTES
  Dump/evidence output (not app data) goes to C:\dumps\Cases\<computer>_<exe>_<datetime>\ by default.
  ProcDump lookup order: -ProcDumpPath, PATH (incl. WinGet links), script folder (+ \Tools), the shared
  package store %ProgramData%\ReportingTroubleshooting\Packages\sysinternals, common Sysinternals folders,
  WinGet packages. Every candidate must be validly Microsoft-signed. Only then the shared package engine
  installs it (to the shared store), signature-verified as well.
  Full dumps contain the process memory (paths, user names, possibly licence data). Share them
  only through the vendor's official support channel.
#>
[CmdletBinding()]
param(
    [string]$ExePath,
    [string]$Arguments = '',
    [string]$WorkingDirectory,
    [string]$OutputRoot = 'C:\dumps\Cases',   # dump/evidence output (not app data)
    [switch]$Auto,                        # agnostic default: catch a crash, a silent exit OR a hang in one run
    [string[]]$ExceptionFilter = @(),     # e.g. FileLoadException, E0434352, C0000005 -> first-chance dumps
    [switch]$FirstChance,                 # dump on ALL first-chance exceptions (noisy, limited by -MaxDumps)
    [switch]$DumpOnExit,                  # dump when the process terminates (silent exits)
    [switch]$Unhandled,                   # dump on an unhandled (2nd-chance) exception - a real crash
    [switch]$Hang,                        # dump when a window stops responding
    [switch]$NoHang,                      # in Auto mode, leave out the hang trigger (avoids false positives)
    [ValidateRange(1, 50)][int]$MaxDumps = 3,
    [ValidateRange(0, 86400)][int]$TimeoutSeconds = 300,   # 0 = wait until the app exits
    [switch]$FusionLog,                   # temporary .NET assembly binding log (restored afterwards)
    [switch]$IncludeAppConfig,
    [ValidateRange(1, 720)][int]$EventHours = 24,
    [string]$ProcDumpPath,
    [switch]$AllowDownload,               # download ProcDump without asking if none is found
    [switch]$NoZip,
    [switch]$NoElevate,
    [switch]$SkipSignatureScan,
    [string]$ParamFile                    # internal: used when relaunching elevated
)

# Stamped automatically by scripts\New-Release.ps1 from the repo VERSION - do not edit by hand.
$ScriptVersion = '1.0.36'
$ErrorActionPreference = 'Continue'
# $ToolsDir points at the shared package store; set after Packages.ps1 is dot-sourced below.

# ============================ RELAUNCH / ELEVATION ============================
$script:Relaunched = $false
if ($ParamFile) {
    if (Test-Path -LiteralPath $ParamFile) {
        $saved = Import-Clixml -LiteralPath $ParamFile
        Remove-Item -LiteralPath $ParamFile -Force -ErrorAction SilentlyContinue
        foreach ($k in $saved.Keys) { Set-Variable -Name $k -Value $saved[$k] -Scope Script }
    }
    $script:Relaunched = $true
}

# ---- shared components (Test-Admin, Test-MicrosoftSignature, Read-Value/Int/Bool, version helpers) ----
$CaseScriptDir = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$CommonDir = $null; $__probe = $CaseScriptDir
for ($__i = 0; $__i -lt 6 -and -not $CommonDir; $__i++) {
    foreach ($__c in @((Join-Path $__probe 'Common'), (Join-Path $__probe 'Scripts\Common'))) {
        if (Test-Path (Join-Path $__c 'Common.ps1')) { $CommonDir = $__c; break }
    }
    $__parent = Split-Path $__probe -Parent
    if (-not $__parent -or $__parent -eq $__probe) { break }
    $__probe = $__parent
}
if (-not $CommonDir) { throw "Shared components (Common\) not found from $CaseScriptDir upward." }
. (Join-Path $CommonDir 'Common.ps1')
. (Join-Path $CommonDir 'Packages.ps1')

# ProcDump lives in the shared package store - single source of truth: Common\Packages.ps1.
$ToolsDir = Get-PackageDir 'sysinternals'

if (-not (Test-Admin) -and -not $NoElevate -and -not $script:Relaunched) {
    $h = @{}
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Key -eq 'ParamFile') { continue }
        $v = $kv.Value
        if ($v -is [System.Management.Automation.SwitchParameter]) { $v = $v.IsPresent }
        $h[$kv.Key] = $v
    }
    $pf = Join-Path $env:TEMP "ProcDumpCase_$PID.xml"
    $h | Export-Clixml -LiteralPath $pf
    try {
        Write-Host 'Administrator rights are needed for event logs, CiTool and the binding log - relaunching elevated...'
        Start-Process powershell.exe -Verb RunAs -ErrorAction Stop `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ParamFile `"$pf`""
        exit
    } catch {
        Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue
        Write-Host 'Elevation declined - continuing without admin rights (some evidence will be missing).' -ForegroundColor Yellow
    }
}
$IsAdmin     = Test-Admin
$CanPrompt   = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected

# ================================== LOGGING ===================================
$script:CaseLog  = $null
$script:Buffered = New-Object System.Collections.Generic.List[string]
$script:Findings = New-Object System.Collections.Generic.List[string]

function Write-Step([string]$Msg, [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO') {
    $line  = '{0:yyyy-MM-dd HH:mm:ss} [{1,-5}] {2}' -f (Get-Date), $Level, $Msg
    $color = switch ($Level) { 'WARN' {'Yellow'} 'ERROR' {'Red'} 'OK' {'Green'} default {'Gray'} }
    Write-Host $Msg -ForegroundColor $color
    if ($script:CaseLog) { Add-Content -LiteralPath $script:CaseLog -Value $line -Encoding UTF8 }
    else { $script:Buffered.Add($line) }
}

function Invoke-Collect([string]$Name, [scriptblock]$Block) {
    Write-Step "Collecting: $Name"
    try { & $Block } catch { Write-Step "  $Name failed: $($_.Exception.Message)" 'WARN' }
}

function Exit-Script([int]$Code) {
    # an elevated relaunch opens its own window - keep it open so the message can be read
    if ($script:Relaunched -and $CanPrompt) { Read-Host 'Press Enter to close' | Out-Null }
    exit $Code
}

function Read-Choice([string]$Prompt, [string]$Default) {
    $v = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($v)) { $Default } else { $v.Trim() }
}

# ================================== PROCDUMP ==================================
function Test-MsSigned([string]$Path) { Test-MicrosoftSignature $Path }   # shared (Common.ps1)

function Get-ProcDumpNames {
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch ($arch) {
        'ARM64' { @('procdump64a.exe', 'procdump64.exe', 'procdump.exe') }
        'AMD64' { @('procdump64.exe', 'procdump.exe') }
        default { @('procdump.exe') }
    }
}

function Find-ProcDump {
    $names = Get-ProcDumpNames
    $cands = New-Object System.Collections.Generic.List[string]

    if ($ProcDumpPath) {
        if (Test-Path -LiteralPath $ProcDumpPath -PathType Container) { foreach ($n in $names) { $cands.Add((Join-Path $ProcDumpPath $n)) } }
        else { $cands.Add($ProcDumpPath) }
    }
    foreach ($n in $names) {
        foreach ($c in @(Get-Command $n -CommandType Application -All -ErrorAction SilentlyContinue)) { $cands.Add($c.Source) }
    }
    $dirs = @($PSScriptRoot, $(if ($PSScriptRoot) { Join-Path $PSScriptRoot 'Tools' }), $ToolsDir,
              'C:\Sysinternals', 'C:\SysinternalsSuite', 'C:\Tools\Sysinternals', 'C:\Tools',
              (Join-Path $env:ProgramFiles 'Sysinternals'), (Join-Path $env:ProgramFiles 'SysinternalsSuite'),
              (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'))
    $wg = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path -LiteralPath $wg) {
        $dirs += @(Get-ChildItem -LiteralPath $wg -Directory -Filter '*Sysinternals*' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }
    foreach ($d in $dirs) { if ($d) { foreach ($n in $names) { $cands.Add((Join-Path $d $n)) } } }

    $seen = @{}
    foreach ($c in $cands) {
        if (-not $c -or $seen.ContainsKey($c)) { continue }
        $seen[$c] = $true
        if (-not (Test-Path -LiteralPath $c -PathType Leaf)) { continue }
        $real = $c
        try {   # WinGet "Links" are symlinks - check the real file
            $it = Get-Item -LiteralPath $c -Force -ErrorAction Stop
            if ($it.LinkType -and $it.Target) {
                $t = @($it.Target)[0]
                $real = if ([IO.Path]::IsPathRooted($t)) { $t } else { Join-Path $it.DirectoryName $t }
            }
        } catch { }
        if (Test-MsSigned $real) { return $real }
        Write-Step "Ignoring $c - not a valid Microsoft-signed ProcDump." 'WARN'
    }
    return $null
}

# Ensures the Sysinternals package is installed in the shared store and returns the ProcDump path (or
# $null). Download/extract/signature logic lives once in the shared engine (Common\Packages.ps1).
function Install-ProcDump {
    if (Install-Package 'sysinternals') { return (Resolve-PackageTool 'sysinternals' (Get-ProcDumpExeName)) }
    Write-Step 'ProcDump install failed (see the package log).' 'ERROR'
    return $null
}

function Get-FileVer([string]$Path) {
    try { [version]((Get-Item -LiteralPath $Path).VersionInfo.FileVersion -replace '[^\d\.].*$', '') } catch { [version]'0.0' }
}

function ConvertTo-Arg([string]$s) {
    if ($s -match '[\s"]') { '"' + ($s -replace '"', '\"') + '"' } else { $s }
}

# ProcDump writes to a redirected file; show new lines live (encoding: UTF-16 or OEM, depends on version)
$script:PdPos = 0L; $script:PdPartial = ''; $script:PdEnc = $null
function Show-ProcDumpOutput([string]$File, [switch]$Final) {
    if (-not (Test-Path -LiteralPath $File)) { return }
    $n = 0; $buf = $null
    try {
        $fs = New-Object IO.FileStream($File, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                                       ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            if ($fs.Length -gt $script:PdPos) {
                [void]$fs.Seek($script:PdPos, [IO.SeekOrigin]::Begin)
                $buf = New-Object byte[] ([int]($fs.Length - $script:PdPos))
                $n = $fs.Read($buf, 0, $buf.Length)
                $script:PdPos += $n
            }
        } finally { $fs.Dispose() }
    } catch { return }

    $text = $script:PdPartial
    if ($n -gt 0) {
        if (-not $script:PdEnc) {
            $script:PdEnc = if ($n -ge 2 -and $buf[1] -eq 0) { [Text.Encoding]::Unicode }
                            else { [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) }
        }
        $text += $script:PdEnc.GetString($buf, 0, $n)
    }
    $lines = @($text -split "`r?`n")
    if ($Final) { $script:PdPartial = '' }
    else { $script:PdPartial = $lines[-1]; $lines = if ($lines.Count -gt 1) { $lines[0..($lines.Count - 2)] } else { @() } }
    foreach ($l in $lines) {
        $l = $l.Trim([char]0, [char]0xFEFF, ' ', "`t")
        if ($l -and $l -notmatch '^(ProcDump v|Copyright \(C\)|Sysinternals - )') { Write-Host "  [ProcDump] $l" -ForegroundColor DarkCyan }
    }
}

# ================================ EVIDENCE HELPERS ============================
function Get-SacState {
    try {
        $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name VerifiedAndReputablePolicyState -ErrorAction Stop).VerifiedAndReputablePolicyState
        switch ($v) { 0 { 'Off (0)' } 1 { 'On - enforced (1)' } 2 { 'Evaluation (2)' } default { "Unknown ($v)" } }
    } catch { 'Not present (Smart App Control not available on this system)' }
}

function Get-NetFxVersion {
    try { $r = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop).Release }
    catch { return 'not installed / not found' }
    $v = if ($r -ge 533320) { '4.8.1' } elseif ($r -ge 528040) { '4.8' } elseif ($r -ge 461808) { '4.7.2' }
         elseif ($r -ge 461308) { '4.7.1' } elseif ($r -ge 460798) { '4.7' } else { 'older than 4.7' }
    "$v (release $r)"
}

function Get-ZoneId([string]$Path) {
    try {
        $z = Get-Content -LiteralPath $Path -Stream Zone.Identifier -ErrorAction Stop
        $m = $z | Select-String 'ZoneId=(\d+)' | Select-Object -First 1
        if ($m) { [int]$m.Matches[0].Groups[1].Value } else { '' }
    } catch { '' }
}

function Get-EventDataMap($e) {
    $h = @{}
    try { foreach ($d in ([xml]$e.ToXml()).Event.EventData.Data) { if ($d.Name) { $h[$d.Name] = $d.'#text' } } } catch { }
    $h
}

function Get-SessionEvents([string]$LogName, [string[]]$Providers, [datetime]$From) {
    $fh = @{ LogName = $LogName; StartTime = $From }
    if ($Providers) { $fh['ProviderName'] = $Providers }
    try { @(Get-WinEvent -FilterHashtable $fh -ErrorAction Stop | Sort-Object TimeCreated) } catch { @() }
}

function Format-Event($e) {
    "[{0:yyyy-MM-dd HH:mm:ss}] {1} | Id {2} | {3}`r`n{4}`r`n" -f $e.TimeCreated, $e.LogName, $e.Id, $e.ProviderName, ($e.Message -replace "`r?`n", "`r`n    ")
}

# Runs a console tool with captured output, feeding Enter on stdin (CiTool waits for a key press)
function Invoke-Captured([string]$Exe, [string]$ArgLine, [string]$OutFile, [int]$TimeoutSec = 60) {
    $in  = Join-Path $env:TEMP "pdc_in_$PID.txt"
    $err = "$OutFile.err"
    Set-Content -LiteralPath $in -Value "`r`n`r`n" -Encoding ASCII
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList $ArgLine -NoNewWindow -PassThru `
                -RedirectStandardInput $in -RedirectStandardOutput $OutFile -RedirectStandardError $err
        if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch { }; Write-Step "  $Exe timed out." 'WARN' }
    } finally {
        Remove-Item -LiteralPath $in -Force -ErrorAction SilentlyContinue
        if ((Test-Path -LiteralPath $err) -and (Get-Item -LiteralPath $err).Length -eq 0) { Remove-Item -LiteralPath $err -Force }
    }
}

# Fusion (assembly binding) log - registry values are backed up and restored
$FusionKeys = @('HKLM:\SOFTWARE\Microsoft\Fusion', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Fusion')
$FusionVals = @('ForceLog', 'LogFailures', 'LogResourceBinds', 'LogPath')
$script:FusionBackup = $null

function Enable-FusionLog([string]$Dir) {
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $script:FusionBackup = @{}
    foreach ($k in $FusionKeys) {
        $existed = Test-Path $k
        $vals = @{}
        if ($existed) {
            $props = Get-ItemProperty $k -ErrorAction SilentlyContinue
            foreach ($v in $FusionVals) { if ($props -and $null -ne $props.$v) { $vals[$v] = $props.$v } }
        } else { New-Item -Path $k -Force | Out-Null }
        $script:FusionBackup[$k] = @{ Existed = $existed; Values = $vals }
        New-ItemProperty -Path $k -Name ForceLog         -Value 1 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $k -Name LogFailures      -Value 1 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $k -Name LogResourceBinds -Value 1 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $k -Name LogPath          -Value ($Dir.TrimEnd('\') + '\') -PropertyType String -Force | Out-Null
    }
    Write-Step "Assembly binding log enabled -> $Dir (will be restored afterwards)"
}

function Restore-FusionLog {
    if (-not $script:FusionBackup) { return }
    foreach ($k in $script:FusionBackup.Keys) {
        $b = $script:FusionBackup[$k]
        try {
            if (-not $b.Existed) { Remove-Item -Path $k -Recurse -Force -ErrorAction Stop; continue }
            foreach ($v in $FusionVals) {
                if ($b.Values.ContainsKey($v)) { Set-ItemProperty -Path $k -Name $v -Value $b.Values[$v] }
                else { Remove-ItemProperty -Path $k -Name $v -ErrorAction SilentlyContinue }
            }
        } catch { Write-Step "Could not restore $k : $($_.Exception.Message)" 'WARN' }
    }
    $script:FusionBackup = $null
    Write-Step 'Assembly binding log settings restored.'
}

# ==================================== MAIN ====================================
Write-Host "`n===== ProcDumpCase v$ScriptVersion =====" -ForegroundColor Cyan
if (-not $IsAdmin) { Write-Step 'Running WITHOUT admin rights: CodeIntegrity log, CiTool and -FusionLog may not work.' 'WARN' }

# ---- target ----
$prompted = $false
if (-not $ExePath) {
    if (-not $CanPrompt) { Write-Step 'No -ExePath given.' 'ERROR'; Exit-Script 2 }
    $ExePath = (Read-Host 'Full path of the exe to start').Trim().Trim('"')
    $prompted = $true
}
if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) { Write-Step "Exe not found: $ExePath" 'ERROR'; Exit-Script 2 }
$ExePath  = (Resolve-Path -LiteralPath $ExePath).Path
$ExeName  = Split-Path $ExePath -Leaf
$BaseName = [IO.Path]::GetFileNameWithoutExtension($ExeName)
$AppDir   = Split-Path $ExePath -Parent
if (-not $WorkingDirectory) { $WorkingDirectory = $AppDir }

$IsManaged = $false
try { $null = [Reflection.AssemblyName]::GetAssemblyName($ExePath); $IsManaged = $true } catch { }

# ---- capture mode (interactive only when nothing was specified) ----
$modeGiven = $Auto -or $ExceptionFilter.Count -or $FirstChance -or $DumpOnExit -or $Unhandled -or $Hang
if ($prompted -and $CanPrompt) {
    if (-not $Arguments) { $Arguments = Read-Host 'Command-line arguments (Enter for none)' }
    if (-not $modeGiven) {
        Write-Host "`nCapture mode:" -ForegroundColor Cyan
        Write-Host ' 1) Auto (recommended)   - catches a crash, a silent exit OR a hang; use when the cause is unknown (default)'
        Write-Host ' 2) Specific exception   - first-chance dump of named exception(s), e.g. FileLoadException'
        Write-Host ' 3) All first-chance     - every exception, even handled ones (noisy, limited by max dumps)'
        Write-Host ' 4) Hang only            - dump when the window stops responding'
        Write-Host ' 5) Crash / exit only    - unhandled exception or process exit, no hang trigger'
        switch (Read-Choice 'Select' '1') {
            '2' { $ExceptionFilter = @((Read-Choice 'Exception name(s), comma separated' 'FileLoadException') -split ',' |
                                       ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
            '3' { $FirstChance = $true }
            '4' { $Hang = $true }
            '5' { $Unhandled = $true; $DumpOnExit = $true }
            default { $Auto = $true }
        }
        $MaxDumps       = [int](Read-Choice 'Max dumps' "$MaxDumps")
        $TimeoutSeconds = [int](Read-Choice 'Stop after how many seconds if the app keeps running (0 = until it exits)' "$TimeoutSeconds")
    }
    if ($IsManaged -and -not $FusionLog -and $IsAdmin) {
        $FusionLog = (Read-Choice '.NET app detected - enable assembly binding log for this run? (y/n)' 'y') -eq 'y'
    }
}

# ---- resolve capture triggers (what we DON'T specify defaults to the agnostic Auto set) ----
$useFirstChance = [bool]($FirstChance -or $ExceptionFilter.Count)   # -e 1 : first-chance (incl. handled)
$useUnhandled   = [bool]$Unhandled                                 # -e   : 2nd-chance (real crash)
$useExit        = [bool]$DumpOnExit                                # -t   : process termination
$useHang        = [bool]$Hang                                      # -h   : window not responding
if ($Auto -or -not ($useFirstChance -or $useUnhandled -or $useExit -or $useHang)) {
    # Nothing (or -Auto) was asked for: catch whatever happens - crash, silent exit, or hang.
    $useUnhandled = $true
    $useExit      = $true
    $useHang      = -not $NoHang
}
$ModeDesc = if ($useFirstChance -and $ExceptionFilter.Count) { "first-chance of: $($ExceptionFilter -join ', ')" }
            elseif ($useFirstChance) { 'all first-chance exceptions' }
            else { (@(if ($useUnhandled) { 'unhandled exception' }; if ($useExit) { 'process exit' }; if ($useHang) { 'hang' }) -join ' + ') }

# ---- case folder ----
$stamp    = Get-Date -Format 'yyyyMMdd_HHmmss'
# Prefix the case folder with the computer name so its origin is obvious once collected from many machines.
$CaseDir  = Join-Path $OutputRoot "${env:COMPUTERNAME}_${BaseName}_$stamp"
$DumpDir  = Join-Path $CaseDir 'Dumps'
$LogsDir  = Join-Path $CaseDir 'Logs'
$EventDir = Join-Path $CaseDir 'Events'
$FilesDir = Join-Path $CaseDir 'Files'
foreach ($d in @($DumpDir, $LogsDir, $EventDir, $FilesDir)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
$script:CaseLog = Join-Path $LogsDir 'collect.log'
$script:Buffered | Add-Content -LiteralPath $script:CaseLog -Encoding UTF8
Write-Step "Case folder: $CaseDir"

# ---- ProcDump ----
$ProcDump = Find-ProcDump
if (-not $ProcDump) {
    Write-Step 'ProcDump not found on this machine.' 'WARN'
    $ok = $AllowDownload
    if (-not $ok -and $CanPrompt) { $ok = (Read-Choice "Download it from Sysinternals to $ToolsDir? (y/n)" 'y') -eq 'y' }
    if ($ok) { $ProcDump = Install-ProcDump }
}
if (-not $ProcDump) { Write-Step 'No ProcDump available - cannot capture dumps. Use -ProcDumpPath or -AllowDownload.' 'ERROR'; Exit-Script 3 }
$PdVer = Get-FileVer $ProcDump
Write-Step "Using ProcDump: $ProcDump (v$PdVer)" 'OK'

# ---- ProcDump arguments ----
$pdArgs = New-Object System.Collections.Generic.List[string]
$pdArgs.AddRange([string[]]@('-accepteula', '-ma'))
if ($useFirstChance)   { $pdArgs.AddRange([string[]]@('-e', '1')) }   # first-chance (includes the -f filter below)
elseif ($useUnhandled) { $pdArgs.Add('-e') }                         # 2nd-chance / unhandled only
foreach ($f in $ExceptionFilter) { $pdArgs.Add('-f'); $pdArgs.Add($f) }
if ($useHang) { $pdArgs.Add('-h') }
if ($useExit) { $pdArgs.Add('-t') }
$pdArgs.AddRange([string[]]@('-n', "$MaxDumps", '-x', $DumpDir, $ExePath))
$ArgLine = ($pdArgs | ForEach-Object { ConvertTo-Arg $_ }) -join ' '
if ($Arguments) { $ArgLine += " $Arguments" }

# ================================== CAPTURE ===================================
$PdOut = Join-Path $LogsDir 'procdump_output.txt'
$PdErr = Join-Path $LogsDir 'procdump_errors.txt'
$Start = Get-Date
$StopReason = 'App exited / ProcDump finished'
$Target = $null
$TargetExit = $null

try {
    if ($FusionLog) {
        if ($IsAdmin) { Enable-FusionLog (Join-Path $FilesDir 'FusionLog') }
        else { Write-Step '-FusionLog needs admin rights - skipped.' 'WARN' }
    }

    Write-Step "Capture mode: $ModeDesc"
    Write-Step "Starting: `"$ProcDump`" $ArgLine"
    Write-Step "Working directory: $WorkingDirectory"
    Write-Host "`nCapturing... press Q to stop (snapshot dump, ProcDump detaches, app keeps running).`n" -ForegroundColor Cyan

    $pd = Start-Process -FilePath $ProcDump -ArgumentList $ArgLine -WorkingDirectory $WorkingDirectory `
            -NoNewWindow -PassThru -RedirectStandardOutput $PdOut -RedirectStandardError $PdErr
    try { $null = $pd.Handle } catch { }

    $deadline = if ($TimeoutSeconds -gt 0) { $Start.AddSeconds($TimeoutSeconds) } else { [datetime]::MaxValue }
    $prevCtrlC = $null
    try { $prevCtrlC = [Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput = $true } catch { }
    try {
        while (-not $pd.HasExited) {
            Show-ProcDumpOutput $PdOut
            if (-not $Target) {
                $c = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($pd.Id)" -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -ieq $ExeName } | Select-Object -First 1
                if ($c) { $Target = Get-Process -Id $c.ProcessId -ErrorAction SilentlyContinue }
                else {
                    # fallback (e.g. procdump.exe relaunching procdump64.exe): newest instance started after launch
                    $Target = Get-Process -Name $BaseName -ErrorAction SilentlyContinue |
                              Where-Object { try { $_.StartTime -ge $Start.AddSeconds(-2) } catch { $false } } |
                              Sort-Object StartTime -Descending | Select-Object -First 1
                }
                if ($Target) { try { $null = $Target.Handle } catch { }; Write-Step "$ExeName started, PID $($Target.Id)" 'OK' }
            }
            if ((Get-Date) -ge $deadline) { $StopReason = "Timeout ($TimeoutSeconds s) - app still running"; break }
            $quit = $false
            try { while ([Console]::KeyAvailable) { if ([Console]::ReadKey($true).Key -eq 'Q') { $quit = $true } } } catch { }
            if ($quit) { $StopReason = 'Stopped by user (Q)'; break }
            Start-Sleep -Milliseconds 500
        }
    } finally {
        if ($null -ne $prevCtrlC) { try { [Console]::TreatControlCAsInput = $prevCtrlC } catch { } }
    }

    # Stopped early while the app is alive: snapshot + graceful detach (never kill ProcDump - that kills the app)
    if (-not $pd.HasExited) {
        Write-Step $StopReason 'WARN'
        if ($Target -and -not $Target.HasExited) {
            $snap = Join-Path $DumpDir ('{0}_snapshot_{1:yyyyMMdd_HHmmss}.dmp' -f $BaseName, (Get-Date))
            Write-Step "Writing snapshot dump of PID $($Target.Id)..."
            & $ProcDump -accepteula -ma $Target.Id $snap 2>&1 | Out-File -LiteralPath (Join-Path $LogsDir 'procdump_snapshot.txt') -Encoding UTF8
            if ($PdVer -ge [version]'10.0') {
                Write-Step 'Detaching ProcDump (app keeps running)...'
                & $ProcDump -accepteula -cancel $Target.Id 2>&1 | Out-Null
            }
        }
        if (-not $pd.WaitForExit(30000)) {
            Write-Step 'ProcDump is still attached. Close the application to finish the capture (waiting)...' 'WARN'
            while (-not $pd.HasExited) { Show-ProcDumpOutput $PdOut; Start-Sleep -Milliseconds 500 }
        }
    }
    Show-ProcDumpOutput $PdOut -Final
    if ($Target -and $Target.HasExited) { try { $TargetExit = $Target.ExitCode } catch { } }
}
finally {
    Restore-FusionLog
}
$End = Get-Date
$WinStart = $Start.AddSeconds(-10)
Write-Step ("Capture finished after {0:N0} s. {1}" -f ($End - $Start).TotalSeconds, $StopReason) 'OK'
if ($null -ne $TargetExit) { Write-Step ('{0} exit code: {1} (0x{1:X8})' -f $ExeName, $TargetExit) }
elseif ($Target -and -not $Target.HasExited) { Write-Step "$ExeName is still running (PID $($Target.Id))." }
Start-Sleep -Seconds 3   # give WER / event log a moment to write

# ================================== COLLECT ===================================
$CiEvents = @(); $AppEvents = @(); $SigRows = @()

Invoke-Collect 'session events (readable)' {
    $script:CiEvents  = Get-SessionEvents 'Microsoft-Windows-CodeIntegrity/Operational' $null $WinStart
    $appProviders = @('.NET Runtime', 'Application Error', 'Windows Error Reporting', 'Application Hang', 'SideBySide')
    $script:AppEvents = @(Get-SessionEvents 'Application' $null $WinStart | Where-Object { $_.ProviderName -in $appProviders })
    $other = @(Get-SessionEvents 'Microsoft-Windows-AppLocker/EXE and DLL' $null $WinStart) +
             @(Get-SessionEvents 'Microsoft-Windows-Windows Defender/Operational' $null $WinStart)
    $all = @($script:CiEvents) + @($script:AppEvents) + $other | Sort-Object TimeCreated
    $txt = @("Events from $WinStart to $(Get-Date)  ($($all.Count) events)", '') + ($all | ForEach-Object { Format-Event $_ })
    Set-Content -LiteralPath (Join-Path $EventDir 'session_events.txt') -Value $txt -Encoding UTF8
    Write-Step "  $($all.Count) events during the capture ($(@($script:CiEvents).Count) Code Integrity)."
}

Invoke-Collect "event log exports (last $EventHours h)" {
    $ms = [int64]$EventHours * 3600000
    $q  = "*[System[TimeCreated[timediff(@SystemTime) <= $ms]]]"
    foreach ($l in @('Application', 'System', 'Microsoft-Windows-CodeIntegrity/Operational',
                     'Microsoft-Windows-AppLocker/EXE and DLL', 'Microsoft-Windows-Windows Defender/Operational')) {
        $file = Join-Path $EventDir (($l -replace '[\\/ ]', '_') + '.evtx')
        $out  = & wevtutil.exe epl $l $file "/q:$q" /ow:true 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Step "  $l not exported: $out" 'WARN' }
    }
}

Invoke-Collect 'Code Integrity policies (CiTool)' {
    $ci = Get-Command CiTool.exe -ErrorAction SilentlyContinue
    if ($ci) { Invoke-Captured $ci.Source '-lp' (Join-Path $FilesDir 'citool_policies.txt') }
    else { Write-Step '  CiTool not available on this Windows version.' }
}

if (-not $SkipSignatureScan) {
    Invoke-Collect "signatures + Mark-of-the-Web of files in $AppDir" {
        $files = @(Get-ChildItem -LiteralPath $AppDir -Recurse -File -Include *.exe, *.dll -ErrorAction SilentlyContinue | Select-Object -First 3000)
        $script:SigRows = foreach ($f in $files) {
            $s = try { Get-AuthenticodeSignature -LiteralPath $f.FullName -ErrorAction Stop } catch { $null }
            [pscustomobject]@{
                Path        = $f.FullName
                FileVersion = $f.VersionInfo.FileVersion
                Signature   = if ($s) { "$($s.Status)" } else { 'Error' }
                Signer      = if ($s -and $s.SignerCertificate) { $s.SignerCertificate.Subject } else { '' }
                ZoneId      = Get-ZoneId $f.FullName
                Modified    = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                SizeKB      = [math]::Round($f.Length / 1KB)
            }
        }
        $script:SigRows | Export-Csv -LiteralPath (Join-Path $FilesDir 'signatures.csv') -NoTypeInformation -Encoding UTF8
        Write-Step "  $($files.Count) files scanned."
    }
}

Invoke-Collect 'Windows Error Reporting reports' {
    foreach ($root in @('ReportArchive', 'ReportQueue')) {
        $dir = Join-Path $env:ProgramData "Microsoft\Windows\WER\$root"
        Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*$BaseName*" -and $_.LastWriteTime -ge $WinStart } |
            ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $FilesDir "WER\$root") -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

if ($IncludeAppConfig) {
    Invoke-Collect 'application .config files' {
        $dst = Join-Path $FilesDir 'AppConfig'
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        Get-ChildItem -LiteralPath $AppDir -Filter *.config -File -ErrorAction SilentlyContinue | Copy-Item -Destination $dst -Force
    }
}

$Sac   = Get-SacState
$NetFx = Get-NetFxVersion

Invoke-Collect 'system information' {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $dg = try { Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop } catch { $null }
    $mp = try { Get-MpComputerStatus -ErrorAction Stop } catch { $null }
    $sig = try { Get-AuthenticodeSignature -LiteralPath $ExePath -ErrorAction Stop } catch { $null }
    $vi  = (Get-Item -LiteralPath $ExePath).VersionInfo
    $ciMode = { param($v) switch ($v) { 0 {'Off'} 1 {'Audit'} 2 {'Enforced'} default {"$v"} } }

    $lines = @(
        "ProcDumpCase      : v$ScriptVersion"
        "Computer / user   : $env:COMPUTERNAME / $env:USERDOMAIN\$env:USERNAME (admin: $IsAdmin)"
        "OS                : $($os.Caption) $($cv.DisplayVersion) - build $($cv.CurrentBuild).$($cv.UBR) ($env:PROCESSOR_ARCHITECTURE)"
        "Culture / UI      : $((Get-Culture).Name) / $((Get-UICulture).Name) - time zone $((Get-TimeZone).Id)"
        ".NET Framework    : $NetFx"
        "Smart App Control : $Sac"
        "VBS status        : $(if ($dg) { $dg.VirtualizationBasedSecurityStatus } else { 'n/a' }) (0 off, 1 configured, 2 running)"
        "Code Integrity    : kernel $(if ($dg) { & $ciMode $dg.CodeIntegrityPolicyEnforcementStatus } else { 'n/a' }), user mode $(if ($dg) { & $ciMode $dg.UsermodeCodeIntegrityPolicyEnforcementStatus } else { 'n/a' })"
        "Defender          : $(if ($mp) { "engine $($mp.AMEngineVersion), real-time $($mp.RealTimeProtectionEnabled)" } else { 'n/a' })"
        ''
        "Target exe        : $ExePath"
        "File / product ver: $($vi.FileVersion) / $($vi.ProductVersion)"
        "Managed (.NET)    : $IsManaged"
        "Signature         : $(if ($sig) { "$($sig.Status) $(if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject })" } else { 'n/a' })"
        "Mark of the Web   : ZoneId $(Get-ZoneId $ExePath) (empty = none, 3 = Internet)"
        "Arguments         : $Arguments"
        "Working directory : $WorkingDirectory"
        ''
        "ProcDump          : $ProcDump (v$PdVer)"
        "Capture mode      : $ModeDesc"
        "ProcDump command  : $ArgLine"
        "Capture           : $Start  ->  $End  ($StopReason)"
        "Target PID        : $(if ($Target) { $Target.Id } else { 'not detected' })"
        "Target exit code  : $(if ($null -ne $TargetExit) { '{0} (0x{0:X8})' -f $TargetExit } else { 'n/a (not exited or unknown)' })"
    )
    Set-Content -LiteralPath (Join-Path $CaseDir 'system_info.txt') -Value $lines -Encoding UTF8
}

# ================================== SUMMARY ===================================
$Dumps = @(Get-ChildItem -LiteralPath $DumpDir -Filter *.dmp -File -ErrorAction SilentlyContinue | Sort-Object CreationTime)

$blocked = foreach ($e in @($CiEvents | Where-Object { $_.Id -in 3033, 3034, 3076, 3077 })) {
    $m = Get-EventDataMap $e
    $file = if ($m['File Name']) { $m['File Name'] } else { ($e.Message -split "`r?`n")[0] }
    [pscustomobject]@{
        Time   = $e.TimeCreated
        Mode   = if ($e.Id -in 3033, 3077) { 'BLOCKED' } else { 'audit only' }
        File   = $file
        Policy = $m['PolicyName']
        Proc   = $m['Process Name']
    }
}
$blocked = @($blocked | Sort-Object File, Mode -Unique)

if ($blocked | Where-Object Mode -eq 'BLOCKED') {
    $script:Findings.Add("Code Integrity BLOCKED $(@($blocked | Where-Object Mode -eq 'BLOCKED').Count) file(s) from loading during the capture (see list below).")
    if ($Sac -like 'On*' -or ($blocked.Policy -match 'VerifiedAndReputable')) {
        $script:Findings.Add('The blocking policy is Smart App Control (VerifiedAndReputableDesktop). It blocks files that are unsigned or have no reputation. Vendor fix: code-sign all shipped binaries.')
    }
}
if ($null -ne $TargetExit) {
    $hex = '{0:X8}' -f $TargetExit
    switch ($hex) {
        'E0434352' { $script:Findings.Add('Process ended with an unhandled .NET exception (0xE0434352). See the .NET Runtime event in session_events.txt.') }
        'C0000005' { $script:Findings.Add('Process ended with an access violation (0xC0000005).') }
        'C0000135' { $script:Findings.Add('Process could not start: a required DLL was not found (0xC0000135).') }
        'C000007B' { $script:Findings.Add('Process could not start: 32/64-bit mismatch or corrupt image (0xC000007B).') }
        'C0000409' { $script:Findings.Add('Process ended with a fail-fast / stack buffer overrun (0xC0000409).') }
    }
}
$netErr = @($AppEvents | Where-Object { $_.ProviderName -eq '.NET Runtime' -and $_.Id -eq 1026 })
if ($netErr) { $script:Findings.Add(".NET Runtime logged $($netErr.Count) unhandled exception event(s) (Id 1026).") }
if ($SigRows) {
    $unsigned = @($SigRows | Where-Object { $_.Signature -ne 'Valid' })
    $motw     = @($SigRows | Where-Object { "$($_.ZoneId)" -in '3', '4' })
    if ($unsigned) { $script:Findings.Add("$($unsigned.Count) of $(@($SigRows).Count) exe/dll files in the app folder are not validly signed (see Files\signatures.csv).") }
    if ($motw)     { $script:Findings.Add("$($motw.Count) files carry Mark-of-the-Web (downloaded from the Internet). Unblock-File may be needed.") }
}
if (-not $Dumps) {
    $hint = if ($useFirstChance) { 'the app may have exited without throwing - try the Auto mode (crash + exit + hang).' }
            else { 'the app may still be running, or stopped in a way no trigger caught - try -FirstChance, or raise -TimeoutSeconds.' }
    $script:Findings.Add("No dump was written - the trigger ($ModeDesc) did not fire; $hint")
}

$sum = New-Object System.Collections.Generic.List[string]
$sum.Add("CASE SUMMARY - $ExeName - $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
$sum.Add('=' * 70)
$sum.Add("Application : $ExePath  (version $((Get-Item -LiteralPath $ExePath).VersionInfo.FileVersion))")
$sum.Add("Computer    : $env:COMPUTERNAME | $((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption) build $([Environment]::OSVersion.Version)")
$sum.Add("Smart App Control: $Sac | .NET Framework $NetFx")
$sum.Add("Capture     : $Start -> $End | $StopReason")
$sum.Add("Exit code   : $(if ($null -ne $TargetExit) { '0x{0:X8}' -f $TargetExit } else { 'n/a' })")
$sum.Add('')
$sum.Add('FINDINGS')
if ($script:Findings.Count) { $script:Findings | ForEach-Object { $sum.Add(" - $_") } } else { $sum.Add(' - Nothing conclusive detected automatically; see dumps and session_events.txt.') }
$sum.Add('')
$sum.Add("DUMPS ($($Dumps.Count))")
$Dumps | ForEach-Object { $sum.Add((' - {0}  ({1:N0} MB)' -f $_.Name, ($_.Length / 1MB))) }
if ($blocked) {
    $sum.Add('')
    $sum.Add('CODE INTEGRITY EVENTS')
    $blocked | ForEach-Object { $sum.Add((' - [{0}] {1}{2}' -f $_.Mode, $_.File, $(if ($_.Policy) { "  (policy: $($_.Policy))" }))) }
}
if ($netErr) {
    $sum.Add('')
    $sum.Add('.NET UNHANDLED EXCEPTION (first event, shortened)')
    ($netErr[0].Message -split "`r?`n" | Select-Object -First 15) | ForEach-Object { $sum.Add("   $_") }
}
$sum.Add('')
$sum.Add('CONTENTS: Dumps\, Logs\procdump_output.txt, Events\session_events.txt + *.evtx, Files\signatures.csv,')
$sum.Add('          Files\citool_policies.txt, Files\WER\, Files\FusionLog\ (if enabled), system_info.txt')
$sum.Add('NOTE: full dumps contain process memory. Share only through the vendor''s official support channel.')
Set-Content -LiteralPath (Join-Path $CaseDir 'SUMMARY.txt') -Value $sum -Encoding UTF8

Write-Host ''
$sum | Select-Object -First 30 | ForEach-Object { Write-Host $_ }

# ==================================== ZIP =====================================
$Zip = $null
if (-not $NoZip) {
    Invoke-Collect 'zip archive' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $script:Zip = "$CaseDir.zip"
        if (Test-Path -LiteralPath $script:Zip) { Remove-Item -LiteralPath $script:Zip -Force }
        # ZipFile supports Zip64, so multi-GB dumps work (Compress-Archive in PS 5.1 does not)
        [IO.Compression.ZipFile]::CreateFromDirectory($CaseDir, $script:Zip, [IO.Compression.CompressionLevel]::Optimal, $true)
        Write-Step ("  {0} ({1:N0} MB)" -f $script:Zip, ((Get-Item -LiteralPath $script:Zip).Length / 1MB)) 'OK'
    }
}

Write-Step "Done. Case folder: $CaseDir" 'OK'
if ($CanPrompt) {
    try { Start-Process explorer.exe -ArgumentList "/select,`"$(if ($Zip) { $Zip } else { $CaseDir })`"" } catch { }
    if ($script:Relaunched) { Read-Host 'Press Enter to close' | Out-Null }
}
