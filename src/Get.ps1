<#
  Online installer: elevate, resolve the latest GitHub release (or main head with -Dev), and when it
  differs from the installed .version (or -Force) download + install to %ProgramData%\ReportingTroubleshooting,
  then launch ReportingToolkit.ps1.
#>
param(
    [switch]$Dev,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$Owner       = 'mcpolo99'
$Repo        = 'reporting-troubleshooting'
$ApiBase     = "https://api.github.com/repos/$Owner/$Repo"
$RawGet      = "https://raw.githubusercontent.com/$Owner/$Repo/main/src/Get.ps1"
$InstallDir  = Join-Path $env:ProgramData 'ReportingTroubleshooting'
$VersionFile = Join-Path $InstallDir '.version'
$EntryScript = 'src\ReportingToolkit.ps1'

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
    if ($Dev)   { $a += '-Dev' }
    if ($Force) { $a += '-Force' }
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList ($a -join ' ') }
    catch { Write-Error 'Elevation was declined; the toolset needs administrator rights to install.' }
    return
}

Clear-Host
Write-Host '-------------------------------------------------------------------------------------------'
Write-Host ' Reporting & Troubleshooting toolset'
Write-Host '-------------------------------------------------------------------------------------------'

$headers = @{ 'User-Agent' = 'reporting-troubleshooting-bootstrap' }

# Resolve the latest ref + download url: a GitHub Release if one exists, else the main branch head.
$ref = $null; $zipUrl = $null; $mode = $null
if (-not $Dev) {
    try {
        $rel    = Invoke-RestMethod "$ApiBase/releases/latest" -Headers $headers
        $ref    = $rel.tag_name
        $zipUrl = $rel.zipball_url
        $mode   = "release $ref"
    } catch { }   # no releases yet -> fall through to the branch head
}
if (-not $ref) {
    try {
        $ref    = (Invoke-RestMethod "$ApiBase/commits/main" -Headers $headers).sha
        $zipUrl = "https://github.com/$Owner/$Repo/archive/refs/heads/main.zip"
        $mode   = "main @ $($ref.Substring(0,7))"
    } catch { Write-Error "Could not reach GitHub to determine the latest version: $_"; return }
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
        # Replace the installed scripts. The tools keep their runtime state under their own
        # %ProgramData%\<tool> folders, so nothing in the install dir needs preserving.
        Get-ChildItem $InstallDir -Force | Where-Object { $_.Name -ne '.version' } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Get-ChildItem $root.FullName -Force | Copy-Item -Destination $InstallDir -Recurse -Force
        Get-ChildItem $InstallDir -Recurse -File -Include *.ps1, *.bat, *.cmd |
            ForEach-Object { Unblock-File $_.FullName -ErrorAction SilentlyContinue }

        Set-Content -Path $VersionFile -Value $ref -Encoding ASCII
        Write-Host "> Installed to $InstallDir"
    }
    catch { Write-Error "Install failed: $_"; return }
    finally {
        Remove-Item $stageZip -Force -ErrorAction SilentlyContinue
        Remove-Item $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$entry = Join-Path $InstallDir $EntryScript
if (-not (Test-Path $entry)) { Write-Error "Entry script not found after install: $entry"; return }
Write-Host '> Launching...'
Write-Host ''
& $entry
