# Single source of truth for the external tool packages this toolset uses (PerfView, Sysinternals).
# Dot-source AFTER Common.ps1 (needs Test-MicrosoftSignature). Logging is optional: Write-Log is used
# when present (PerfView/Monitor/the Packages runspace), otherwise messages go to the host.
#
# Everything about a package - what to download, where it lives, how it is verified - is defined here and
# nowhere else. The GUI "Packages" tab, the PerfView/ProcDump tools and the detached monitor task all
# install and resolve through these functions, so there is exactly one place that knows how to install.
# All packages share one machine-wide folder so a tool is downloaded once and every consumer reuses it.

$script:PackageRoot = Join-Path $env:ProgramData 'ReportingTroubleshooting\Packages'

function Write-PkgLog([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO') {
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log $Message $(if ($Level -eq 'OK') { 'INFO' } else { $Level })
    } else {
        $c = switch ($Level) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } 'OK' { 'Green' } default { 'Gray' } }
        Write-Host $Message -ForegroundColor $c
    }
}

# ProcDump ships per-architecture binaries; pick the one matching the real OS (honour WOW64).
function Get-ProcDumpExeName {
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch ($arch) { 'ARM64' { 'procdump64a.exe' } 'AMD64' { 'procdump64.exe' } default { 'procdump.exe' } }
}

# The package catalogue. Primary = the exe used for the status/version read and the signature gate.
function Get-PackageRegistry {
    @(
        [pscustomobject]@{
            Id          = 'perfview'
            Name        = 'PerfView'
            Description = 'ETW/ETL performance tracing (Microsoft).'
            Kind        = 'exe'
            Url         = 'https://github.com/microsoft/perfview/releases/latest/download/PerfView.exe'
            Primary     = 'PerfView.exe'
        },
        [pscustomobject]@{
            Id              = 'sysinternals'
            Name            = 'Sysinternals Suite'
            Description     = 'Sysinternals tools: ProcDump, Process Explorer, Handle and more.'
            Kind            = 'zip'
            Url             = 'https://download.sysinternals.com/files/SysinternalsSuite.zip'
            FallbackUrl     = 'https://download.sysinternals.com/files/Procdump.zip'   # single-tool fallback
            ExtractPatterns = @('*.exe', '*.chm', 'Eula*')
            Primary         = (Get-ProcDumpExeName)
        }
    )
}

function Get-Package([string]$Id) { Get-PackageRegistry | Where-Object { $_.Id -ieq $Id } | Select-Object -First 1 }
function Get-PackageRoot { $script:PackageRoot }
function Get-PackageDir([string]$Id) { Join-Path $script:PackageRoot $Id }

# Full path to a specific exe inside an installed package, or $null if absent. $Exe defaults to Primary.
function Resolve-PackageTool([string]$Id, [string]$Exe) {
    $pkg = Get-Package $Id; if (-not $pkg) { return $null }
    if (-not $Exe) { $Exe = $pkg.Primary }
    $p = Join-Path (Get-PackageDir $Id) $Exe
    if (Test-Path -LiteralPath $p) { $p } else { $null }
}

function Test-PackageInstalled([string]$Id) {
    $p = Resolve-PackageTool $Id
    [bool]($p -and (Test-MicrosoftSignature $p))
}

function Get-PackageStatus([string]$Id) {
    $pkg = Get-Package $Id
    $dir = Get-PackageDir $Id
    $primary   = if ($pkg) { Join-Path $dir $pkg.Primary } else { $null }
    $installed = Test-PackageInstalled $Id
    $ver   = if ($installed) { try { (Get-Item -LiteralPath $primary).VersionInfo.FileVersion } catch { $null } } else { $null }
    $count = if (Test-Path $dir) { @(Get-ChildItem $dir -Filter *.exe -File -ErrorAction SilentlyContinue).Count } else { 0 }
    [pscustomobject]@{
        Id = $pkg.Id; Name = $pkg.Name; Description = $pkg.Description; Kind = $pkg.Kind
        Installed = [bool]$installed; Version = $ver; Dir = $dir; Primary = $pkg.Primary; ToolCount = $count
    }
}

# Install (or re-verify) a package into its shared folder. $LocalSource = local exe(s)/zip to use instead
# of downloading (offline). Returns $true when the Primary exe is present and validly Microsoft-signed.
function Install-Package {
    param([Parameter(Mandatory)][string]$Id, [switch]$Force, [string[]]$LocalSource)
    $pkg = Get-Package $Id
    if (-not $pkg) { Write-PkgLog "Unknown package '$Id'." 'ERROR'; return $false }
    $dir = Get-PackageDir $Id
    $primary = Join-Path $dir $pkg.Primary

    if ((Test-Path -LiteralPath $primary) -and -not $Force) {
        if (Test-MicrosoftSignature $primary) { Write-PkgLog "$($pkg.Name) present: $dir"; return $true }
        Write-PkgLog "$($pkg.Name) failed signature check, re-acquiring." 'WARN'
    }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'

    try {
        switch ($pkg.Kind) {
            'exe' {
                $placed = $false
                foreach ($c in @($LocalSource)) {
                    if ($c -and (Test-Path -LiteralPath $c) -and (Test-MicrosoftSignature $c)) {
                        Copy-Item -LiteralPath $c -Destination $primary -Force
                        Unblock-File -LiteralPath $primary -ErrorAction SilentlyContinue
                        Write-PkgLog "$($pkg.Name): using local source $c"; $placed = $true; break
                    }
                }
                if (-not $placed) {
                    $g = Get-Command $pkg.Primary -ErrorAction SilentlyContinue
                    if ($g -and (Test-MicrosoftSignature $g.Source)) {
                        Copy-Item -LiteralPath $g.Source -Destination $primary -Force
                        Unblock-File -LiteralPath $primary -ErrorAction SilentlyContinue
                        Write-PkgLog "$($pkg.Name): using $($g.Source) from PATH"; $placed = $true
                    }
                }
                if (-not $placed) {
                    $tmp = Join-Path $env:TEMP ('{0}_{1}.exe' -f $Id, $PID)
                    try {
                        Write-PkgLog "Downloading $($pkg.Name) from $($pkg.Url)"
                        Invoke-WebRequest -Uri $pkg.Url -OutFile $tmp -UseBasicParsing -ErrorAction Stop
                        Copy-Item -LiteralPath $tmp -Destination $primary -Force
                        Unblock-File -LiteralPath $primary -ErrorAction SilentlyContinue
                    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
                }
            }
            'zip' {
                $zip = Join-Path $env:TEMP ('{0}_{1}.zip' -f $Id, $PID)
                $ex  = Join-Path $env:TEMP ('{0}_{1}' -f $Id, $PID)
                $localZip = @($LocalSource) | Where-Object { $_ -and ($_ -like '*.zip') -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
                try {
                    if ($localZip) { $zip = $localZip; Write-PkgLog "$($pkg.Name): using local archive $localZip" }
                    else {
                        try {
                            Write-PkgLog "Downloading $($pkg.Name) from $($pkg.Url)"
                            Invoke-WebRequest -Uri $pkg.Url -OutFile $zip -UseBasicParsing -ErrorAction Stop
                        } catch {
                            if (-not $pkg.FallbackUrl) { throw }
                            Write-PkgLog "$($pkg.Name) download failed ($($_.Exception.Message)); trying fallback $($pkg.FallbackUrl)" 'WARN'
                            Invoke-WebRequest -Uri $pkg.FallbackUrl -OutFile $zip -UseBasicParsing -ErrorAction Stop
                        }
                    }
                    Expand-Archive -Path $zip -DestinationPath $ex -Force
                    $pats = @($pkg.ExtractPatterns); if (-not $pats -or $pats.Count -eq 0) { $pats = @('*') }
                    Get-ChildItem $ex -File | Where-Object { $name = $_.Name; ($pats | Where-Object { $name -like $_ }).Count -gt 0 } |
                        Copy-Item -Destination $dir -Force
                } finally {
                    if (-not $localZip) { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
                    Remove-Item $ex -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            default { throw "unsupported package kind '$($pkg.Kind)'." }
        }

        if (-not (Test-Path -LiteralPath $primary)) { throw "$($pkg.Primary) not found after install." }
        if (-not (Test-MicrosoftSignature $primary)) {
            Remove-Item -LiteralPath $primary -Force -ErrorAction SilentlyContinue
            throw "signature check failed for $($pkg.Primary) (not a valid Microsoft-signed binary)."
        }
        $v = try { (Get-Item -LiteralPath $primary).VersionInfo.FileVersion } catch { '' }
        $n = @(Get-ChildItem $dir -Filter *.exe -File -ErrorAction SilentlyContinue).Count
        Write-PkgLog "$($pkg.Name) installed and verified in $dir ($n tool(s); primary $($pkg.Primary) $v)" 'OK'
        return $true
    } catch {
        Write-PkgLog "$($pkg.Name) install failed: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

# Install/verify everything in the registry. Returns $true only if every package ends up installed.
function Install-AllPackages([switch]$Force) {
    $ok = $true
    foreach ($p in Get-PackageRegistry) { if (-not (Install-Package $p.Id -Force:$Force)) { $ok = $false } }
    $ok
}
