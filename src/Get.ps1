<#
  Online installer: elevate, resolve the latest GitHub release (stable) and when it differs from the
  installed .version (or -Force) download + install to %ProgramData%\ReportingTroubleshooting, then launch
  ReportingToolkit.ps1.

  Branch builds (for testing): -Branch <name> installs that branch's head instead of the stable release;
  -Dev is shorthand for -Branch develop. A branch build is ISOLATED - it installs to
  %ProgramData%\ReportingTroubleshooting\branch\<name> and runs from there, so it never overwrites the stable
  install. The shared tool store (...\Packages) and per-tool data (...\Monitor, ...\PerfView) stay machine-wide,
  so a branch build reuses already-installed tools rather than re-downloading them.
#>
param(
    [string]$Branch,     # install this branch's head (isolated), e.g. -Branch develop / -Branch feature/foo
    [switch]$Dev,        # shorthand for -Branch develop
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Allow the installed .ps1 (and its dot-sources/runspaces, all this process) to run when the machine
# policy is Restricted. Get.ps1 itself runs from memory (irm|iex) so it is not blocked.
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue } catch {}

$Owner       = 'mcpolo99'
$Repo        = 'reporting-troubleshooting'
$ApiBase     = "https://api.github.com/repos/$Owner/$Repo"
$RawGet      = "https://raw.githubusercontent.com/$Owner/$Repo/main/src/Get.ps1"
$StableDir   = Join-Path $env:ProgramData 'ReportingTroubleshooting'
$EntryScript = 'src\ReportingToolkit.ps1'

# Effective branch: -Branch wins, -Dev means develop, otherwise stable (latest release).
$EffBranch = if ($Branch) { $Branch.Trim() } elseif ($Dev) { 'develop' } else { '' }
if ($EffBranch) {
    # Isolate branch builds under ...\branch\<name> so they never overwrite the stable install. The name is
    # sanitised for a folder (feature/foo -> feature-foo); the real branch ref keeps its slashes for GitHub.
    $safeBranch  = ($EffBranch -replace '[^\w.-]', '-')
    $InstallDir  = Join-Path $StableDir "branch\$safeBranch"
} else {
    $InstallDir  = $StableDir
}
$VersionFile = Join-Path $InstallDir '.version'

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Error 'PowerShell is running in constrained language mode; this toolset cannot run here.'
    return
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Installing into %ProgramData% needs admin. When launched from the one-liner there is no script file on
# disk to relaunch, so re-download this bootstrap to a temp file and relaunch THAT elevated.
if (-not (Test-Admin)) {
    Write-Host '> Requesting administrator rights...'
    $self = Join-Path $env:TEMP 'ReportingTroubleshooting-Get.ps1'
    try { Invoke-RestMethod $RawGet -OutFile $self } catch { Write-Error "Could not download the bootstrap: $_"; return }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$self`"")
    if ($Branch) { $a += @('-Branch', "`"$Branch`"") }
    if ($Dev)    { $a += '-Dev' }
    if ($Force)  { $a += '-Force' }
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList ($a -join ' ') }
    catch { Write-Error 'Elevation was declined; the toolset needs administrator rights to install.' }
    return
}

Clear-Host
Write-Host '-------------------------------------------------------------------------------------------'
Write-Host ' Reporting & Troubleshooting toolset'
if ($EffBranch) { Write-Host " BRANCH BUILD: $EffBranch  (isolated at $InstallDir)" -ForegroundColor Yellow }
Write-Host '-------------------------------------------------------------------------------------------'

$headers = @{ 'User-Agent' = 'reporting-troubleshooting-bootstrap' }

# Resolve the ref + download url. A branch build takes that branch's head; otherwise the latest GitHub
# Release (stable), falling back to the main branch head when no release exists yet.
$ref = $null; $zipUrl = $null; $mode = $null
if ($EffBranch) {
    try {
        $ref = (Invoke-RestMethod "$ApiBase/commits/$EffBranch" -Headers $headers).sha
    } catch { Write-Error "Could not resolve branch '$EffBranch' on $Owner/$Repo (does it exist?): $_"; return }
    $zipUrl = "https://github.com/$Owner/$Repo/archive/refs/heads/$EffBranch.zip"
    $mode   = "branch $EffBranch @ $($ref.Substring(0,7))"
}
else {
    try {
        $rel    = Invoke-RestMethod "$ApiBase/releases/latest" -Headers $headers
        $ref    = $rel.tag_name
        $zipUrl = $rel.zipball_url
        $mode   = "release $ref"
    } catch { }   # no releases yet -> fall through to the main head
    if (-not $ref) {
        try {
            $ref    = (Invoke-RestMethod "$ApiBase/commits/main" -Headers $headers).sha
            $zipUrl = "https://github.com/$Owner/$Repo/archive/refs/heads/main.zip"
            $mode   = "main @ $($ref.Substring(0,7))"
        } catch { Write-Error "Could not reach GitHub to determine the latest version: $_"; return }
    }
}

$installed = if (Test-Path $VersionFile) { (Get-Content $VersionFile -Raw).Trim() } else { $null }
$haveEntry = Test-Path (Join-Path $InstallDir $EntryScript)

if ($installed -eq $ref -and $haveEntry -and -not $Force) {
    Write-Host "> Already up to date ($mode)."
}
else {
    if ($haveEntry) { Write-Host "> Update available ($installed -> $ref). Updating..." }
    else            { Write-Host "> Installing toolset ($mode)..." }

    $stageZip = Join-Path $env:TEMP "rt_$PID.zip"
    $stageDir = Join-Path $env:TEMP "rt_$PID"
    try {
        Write-Host '> Downloading...'
        Invoke-RestMethod $zipUrl -OutFile $stageZip -Headers $headers

        Remove-Item $stageDir -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive $stageZip $stageDir -Force

        # GitHub wraps everything in a single top-level folder (<owner>-<repo>-<ref> or <repo>-main).
        $root = Get-ChildItem $stageDir -Directory | Select-Object -First 1
        if (-not $root) { throw 'Unexpected archive layout (no top-level folder).' }

        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        # Replace the installed scripts, but PRESERVE runtime data that lives under the install dir: the
        # shared package store (installed tools) and logs. Wiping these made installed packages vanish on
        # every update. (Other tools keep their own state under %ProgramData%\<tool>.)
        # Stable keeps its machine-wide runtime data (shared tool store, logs, per-tool data) across updates.
        # A branch dir holds only scripts - that data lives under the stable root - so only .version is kept.
        $preserve = if ($EffBranch) { @('.version', '.branch') } else { @('.version', 'Packages', 'Logs', 'PerfView', 'Monitor', 'Case', 'Icons') }
        Get-ChildItem $InstallDir -Force | Where-Object { $preserve -notcontains $_.Name } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Get-ChildItem $root.FullName -Force | Copy-Item -Destination $InstallDir -Recurse -Force
        Get-ChildItem $InstallDir -Recurse -File -Include *.ps1, *.bat, *.cmd |
            ForEach-Object { Unblock-File $_.FullName -ErrorAction SilentlyContinue }

        Set-Content -Path $VersionFile -Value $ref -Encoding ASCII
        # Record the real branch name (the folder name is sanitised and may differ, e.g. feature/foo ->
        # feature-foo) so the in-app updater can re-install the same branch.
        if ($EffBranch) { Set-Content -Path (Join-Path $InstallDir '.branch') -Value $EffBranch -Encoding ASCII }
        Write-Host "> Installed to $InstallDir"
    }
    catch { Write-Error "Install failed: $_"; return }
    finally {
        Remove-Item $stageZip -Force -ErrorAction SilentlyContinue
        Remove-Item $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# A branch build is for TESTING, and the real conflict with a running release install is the machine-wide
# ProcDumpMonitor task (one task; whoever enabled it last owns it) and its ProcDump instances - they would
# keep capturing under the release code while you test the branch. So a branch install STOPS that running
# capture. It must NOT *disable* the task: the task is shared by name, and the branch's own Enable re-registers
# it against the branch copy - disabling it would just stop the branch's Start from working too. Prod is
# effectively "off" once the branch takes the task over via Enable; here we only halt the live capture.
function Stop-ReleaseMonitor {
    Write-Host '> Branch build: stopping the release install''s running monitor/ProcDump so you can test the branch...'
    try { Stop-ScheduledTask -TaskName 'ProcDumpMonitor' -ErrorAction SilentlyContinue } catch {}   # stop the run, do NOT disable
    try {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match 'ProcDumpMonitor\.ps1' } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
    } catch {}
    try { Get-Process -Name procdump, procdump64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
    # If a previous build left the task disabled, re-enable it so the branch's Start/Enable works.
    try { Enable-ScheduledTask -TaskName 'ProcDumpMonitor' -ErrorAction SilentlyContinue | Out-Null } catch {}
    Write-Host '  release capture stopped. In the branch GUI click Enable (registers the task against the branch), then Start.'
}

$entry = Join-Path $InstallDir $EntryScript
if (-not (Test-Path $entry)) { Write-Error "Entry script not found after install: $entry"; return }
if ($EffBranch) { Stop-ReleaseMonitor }
Write-Host '> Launching...'
Write-Host ''
& $entry
