<#
  Downloads + installs the toolset to %ProgramData%\ReportingTroubleshooting and launches it.
  -Branch <name> installs that branch's head instead of the latest release; -Dev = -Branch develop;
  -Force reinstalls.
#>
param(
    [string]$Branch,     # install this branch's head, e.g. -Branch develop / -Branch feature/foo
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

# Effective branch: -Branch wins, -Dev means develop, otherwise stable (latest release). A branch build is NOT
# isolated - it installs to the SAME location as a normal install and replaces it (the monitor task, tool store
# and data are machine-wide anyway, so isolating only the scripts was illusory and caused "which copy runs?"
# confusion). To return a machine to the release build, reinstall stable (no -Branch).
$EffBranch   = if ($Branch) { $Branch.Trim() } elseif ($Dev) { 'develop' } else { '' }
$InstallDir  = $StableDir
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
    # Re-fetch THIS bootstrap for the elevated relaunch - from the branch when installing a branch, so the
    # branch's own Get.ps1 (this logic) runs elevated, not main's.
    $selfUrl = if ($EffBranch) { "https://raw.githubusercontent.com/$Owner/$Repo/$EffBranch/src/Get.ps1" } else { $RawGet }
    try { Invoke-RestMethod $selfUrl -OutFile $self } catch { Write-Error "Could not download the bootstrap: $_"; return }
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
if ($EffBranch) { Write-Host " BRANCH BUILD: $EffBranch  (replaces the release install at $InstallDir)" -ForegroundColor Yellow }
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
        # Replace the installed scripts, but PRESERVE the machine-wide runtime data under the install dir: the
        # shared tool store, logs and per-tool data (wiping these made installed packages vanish on every
        # update). Same for a branch build now that it installs to this same location; .branch records that
        # this install came from a branch so the in-app updater re-pulls it.
        $preserve = @('.version', '.branch', 'Packages', 'Logs', 'PerfView', 'Monitor', 'Case', 'Icons')
        Get-ChildItem $InstallDir -Force | Where-Object { $preserve -notcontains $_.Name } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Get-ChildItem $root.FullName -Force | Copy-Item -Destination $InstallDir -Recurse -Force
        Get-ChildItem $InstallDir -Recurse -File -Include *.ps1, *.bat, *.cmd |
            ForEach-Object { Unblock-File $_.FullName -ErrorAction SilentlyContinue }

        Set-Content -Path $VersionFile -Value $ref -Encoding ASCII
        # Record the branch so the in-app updater re-pulls it; clear the marker on a stable/release install so
        # the machine is no longer treated as a branch build.
        $branchMarker = Join-Path $InstallDir '.branch'
        if ($EffBranch) { Set-Content -Path $branchMarker -Value $EffBranch -Encoding ASCII }
        elseif (Test-Path $branchMarker) { Remove-Item $branchMarker -Force -ErrorAction SilentlyContinue }
        Write-Host "> Downloaded to $InstallDir"
    }
    catch { Write-Error "Install failed: $_"; return }
    finally {
        Remove-Item $stageZip -Force -ErrorAction SilentlyContinue
        Remove-Item $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$entry = Join-Path $InstallDir $EntryScript
if (-not (Test-Path $entry)) { Write-Error "Entry script not found: $entry"; return }
Write-Host '> Launching...'
Write-Host ''
& $entry
