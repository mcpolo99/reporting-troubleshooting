#Requires -Version 5.1
# Cut a GitHub release. VERSION (repo root) is the source of truth: -Bump raises it (and writes CHANGELOG),
# -Version sets it explicitly, neither releases the current VERSION. Validates, tags vX.Y.Z, pushes,
# publishes via gh. -UploadGetAsset attaches src\Get.ps1; -WhatIf previews; -AllowDirty skips the clean check.
[CmdletBinding()]
param(
    [ValidateSet('major', 'minor', 'patch')][string]$Bump,
    [string]$Version,
    [string]$Notes,
    [string]$NotesFile,
    [switch]$UploadGetAsset,
    [switch]$Draft,
    [switch]$PreRelease,
    [string]$Remote = 'origin',
    [switch]$AllowDirty,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
function Fail([string]$m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }
function Info([string]$m) { Write-Host $m -ForegroundColor Cyan }

# ---- locate the repo (this script is in <repo>\scripts\) ----
$RepoRoot    = Split-Path -Parent $PSScriptRoot
$VersionFile = Join-Path $RepoRoot 'VERSION'
$ChangelogFile = Join-Path $RepoRoot 'CHANGELOG.md'
$GetScript   = Join-Path $RepoRoot 'src\Get.ps1'
Set-Location -LiteralPath $RepoRoot

# ---- tool checks ----
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Fail 'git is not on PATH.' }
if (-not (Get-Command gh  -ErrorAction SilentlyContinue)) { Fail 'GitHub CLI (gh) is not on PATH - https://cli.github.com/' }
if (-not (Test-Path (Join-Path $RepoRoot '.git'))) { Fail "Not a git repo: $RepoRoot" }
if (-not (Test-Path $VersionFile)) { Fail "VERSION file not found: $VersionFile" }
try { gh auth status 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { throw } } catch { Fail 'gh is not authenticated. Run: gh auth login' }

# ---- repo state ----
$branch = (git rev-parse --abbrev-ref HEAD).Trim()
if ($branch -ne 'main') { Write-Host "WARNING: on branch '$branch', not 'main'." -ForegroundColor Yellow }
$dirty = (git status --porcelain)
if ($dirty -and -not $AllowDirty) { Fail "Working tree is not clean (commit/stash first, or -AllowDirty):`n$dirty" }

# ---- resolve version ----
$current = (Get-Content $VersionFile -Raw).Trim()
if ($current -notmatch '^\d+\.\d+\.\d+$') { Fail "VERSION file holds '$current', not X.Y.Z." }

if ($Bump) {
    $p = $current.Split('.')
    $new = switch ($Bump) {
        'major' { '{0}.0.0' -f ([int]$p[0] + 1) }
        'minor' { '{0}.{1}.0' -f $p[0], ([int]$p[1] + 1) }
        'patch' { '{0}.{1}.{2}' -f $p[0], $p[1], ([int]$p[2] + 1) }
    }
    $newVersion = $new
} elseif ($Version) {
    $newVersion = $Version
} else {
    $newVersion = $current
}
if ($newVersion -notmatch '^\d+\.\d+\.\d+$') { Fail "Version '$newVersion' is not X.Y.Z." }
$Tag = "v$newVersion"
if (git tag --list $Tag) { Fail "Tag $Tag already exists." }
$willBump = ($newVersion -ne $current)

# ---- notes ----
if ($NotesFile) { if (-not (Test-Path $NotesFile)) { Fail "NotesFile not found: $NotesFile" }; $Notes = Get-Content -LiteralPath $NotesFile -Raw }
if (-not $Notes) {
    $lastTag = $null
    try { $lastTag = (& git describe --tags --abbrev=0 2>$null) } catch { $lastTag = $null }
    $range = if ($lastTag) { "$lastTag..HEAD" } else { 'HEAD' }
    $log = git log $range --pretty=format:'- %s (%h)'
    $Notes = if ($log) { ($log -join "`n") } else { "Release $Tag" }
    if ($lastTag) { $Notes = "Changes since $lastTag`:`n`n$Notes" }
}

# ---- plan ----
Info "`n================ Release plan ================"
Write-Host ("Repo       : {0}" -f (gh repo view --json nameWithOwner -q .nameWithOwner 2>$null))
Write-Host ("Version    : {0}{1}" -f $newVersion, $(if ($willBump) { "  (bumped from $current)" } else { '  (unchanged)' }))
Write-Host ("Tag        : {0}  (branch {1})" -f $Tag, $branch)
Write-Host ("Draft      : {0}    Pre-release: {1}    Upload Get.ps1: {2}" -f [bool]$Draft, [bool]$PreRelease, [bool]$UploadGetAsset)
Write-Host  "Notes      :"
$Notes -split "`n" | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }
Write-Host  "=============================================`n"

if ($WhatIf) { Info 'WhatIf: nothing changed.'; return }
if ((Read-Host "Create and publish $Tag? (y/N)") -ne 'y') { Info 'Cancelled.'; return }

# ---- bump VERSION + CHANGELOG + commit ----
if ($willBump) {
    Info "Writing VERSION $newVersion and updating CHANGELOG..."
    Set-Content -LiteralPath $VersionFile -Value $newVersion -NoNewline -Encoding ASCII

    # Single source of truth for the version: stamp $newVersion into every tool script's $ScriptVersion
    # literal so it is NEVER maintained by hand. ReportingToolkit.ps1 reads VERSION at runtime (not a
    # quoted literal) so the pattern deliberately does not match it.
    $srcDir = Join-Path $RepoRoot 'src'
    $rx  = [regex]'(?m)^(\s*\$ScriptVersion\s*=\s*'')\d+\.\d+\.\d+('')'
    $enc = New-Object System.Text.UTF8Encoding($false)
    $stamped = @()
    Get-ChildItem -LiteralPath $srcDir -Recurse -Filter *.ps1 | ForEach-Object {
        $txt = [IO.File]::ReadAllText($_.FullName)
        $out = $rx.Replace($txt, "`${1}$newVersion`${2}")
        if ($out -ne $txt) { [IO.File]::WriteAllText($_.FullName, $out, $enc); $stamped += $_.FullName }
    }
    if ($stamped) { Info ("Stamped v$newVersion into {0} tool script(s)." -f $stamped.Count); git add -- $stamped }
    if (Test-Path $ChangelogFile) {
        $entry = "## [$Tag] - {0}`n{1}`n" -f (Get-Date -Format 'yyyy-MM-dd'), $Notes
        $cl = Get-Content -LiteralPath $ChangelogFile -Raw
        $marker = '<!-- NEW RELEASES INSERTED BELOW -->'
        if ($cl -match [regex]::Escape($marker)) { $cl = $cl -replace [regex]::Escape($marker), "$marker`n`n$entry" }
        else { $cl = "$cl`n`n$entry" }
        Set-Content -LiteralPath $ChangelogFile -Value $cl -Encoding UTF8
        git add -- $VersionFile $ChangelogFile
    } else { git add -- $VersionFile }
    git commit -m "chore: release $Tag"
    git push $Remote $branch
}

# ---- tag, push, release ----
$commit = (git rev-parse --short HEAD).Trim()
Info "Tagging $Tag at $commit..."
git tag -a $Tag -m "Release $Tag"
git push $Remote $Tag

# Tag is already pushed above, so the release binds to it; no --target (a short SHA there is rejected).
$ghArgs = @('release', 'create', $Tag, '--title', $Tag, '--notes', $Notes)
if ($Draft)      { $ghArgs += '--draft' }
if ($PreRelease) { $ghArgs += '--prerelease' }
Info 'Creating GitHub release...'
gh @ghArgs
if ($LASTEXITCODE -ne 0) { Fail "gh release create failed. Tag was pushed; undo with: git push $Remote :$Tag ; git tag -d $Tag" }

if ($UploadGetAsset) {
    if (Test-Path $GetScript) { Info 'Uploading Get.ps1 asset...'; gh release upload $Tag $GetScript --clobber }
    else { Write-Host "WARNING: $GetScript not found; skipped asset upload." -ForegroundColor Yellow }
}

Info "`nDone: $Tag published."
