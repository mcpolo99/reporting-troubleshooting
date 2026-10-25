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

# Streams a download to disk, reporting throttled progress (percent / MB) through Write-PkgLog so the GUI
# output shows it live. Invoke-WebRequest -OutFile gives no progress we can surface in a runspace.
function Save-UrlWithProgress([string]$Url, [string]$OutFile, [string]$Label) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'reporting-troubleshooting'
    $req.AllowAutoRedirect = $true
    $resp = $req.GetResponse()
    try {
        $total = [int64]$resp.ContentLength      # -1 when the server does not send a length
        $in  = $resp.GetResponseStream()
        $out = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
        try {
            $buf = New-Object byte[] (128KB)
            $read = 0L; $lastPct = -1; $lastTick = [Environment]::TickCount
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $out.Write($buf, 0, $n); $read += $n
                $now = [Environment]::TickCount
                if ($total -gt 0) {
                    $pct = [int](($read * 100) / $total)
                    if ($pct -ge $lastPct + 5 -or ($pct -ne $lastPct -and ($now - $lastTick) -ge 1000)) {
                        Write-PkgLog ("  {0}: {1}%  ({2:n1}/{3:n1} MB)" -f $Label, $pct, ($read / 1MB), ($total / 1MB))
                        $lastPct = $pct; $lastTick = $now
                    }
                } elseif (($now - $lastTick) -ge 1000) {
                    Write-PkgLog ("  {0}: {1:n1} MB" -f $Label, ($read / 1MB)); $lastTick = $now
                }
            }
        } finally { $out.Dispose() }
    } finally { $resp.Dispose() }
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
            # The full Suite ships 100+ exes; the ProcDump-only fallback ships 3. "Installed" must mean the
            # whole Suite is present, not just ProcDump - otherwise an earlier ProcDump-only install makes the
            # Suite install short-circuit as "already present" and the other tools never arrive. 10 cleanly
            # separates the two and is architecture-agnostic (no per-arch exe names to track).
            MinTools        = 10
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

# Count the installed exes in a package's folder (used to tell a full Suite from a ProcDump-only fallback).
function Get-PackageToolCount([string]$Id) {
    $dir = Get-PackageDir $Id
    if (Test-Path $dir) { @(Get-ChildItem $dir -Filter *.exe -File -ErrorAction SilentlyContinue).Count } else { 0 }
}

# "Installed" means complete: the Primary exe is present and validly Microsoft-signed, AND (for multi-tool
# packages) at least MinTools exes are present. The second clause is what stops a ProcDump-only folder from
# masquerading as the full Sysinternals Suite.
function Test-PackageInstalled([string]$Id) {
    $pkg = Get-Package $Id; if (-not $pkg) { return $false }
    $p = Resolve-PackageTool $Id
    if (-not ($p -and (Test-MicrosoftSignature $p))) { return $false }
    $min = if ($pkg.PSObject.Properties['MinTools'] -and $pkg.MinTools) { [int]$pkg.MinTools } else { 1 }
    (Get-PackageToolCount $Id) -ge $min
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

    $min = if ($pkg.PSObject.Properties['MinTools'] -and $pkg.MinTools) { [int]$pkg.MinTools } else { 1 }
    if ((Test-Path -LiteralPath $primary) -and -not $Force) {
        if (-not (Test-MicrosoftSignature $primary)) {
            Write-PkgLog "$($pkg.Name) failed signature check, re-acquiring." 'WARN'
        } elseif ((Get-PackageToolCount $Id) -lt $min) {
            Write-PkgLog "$($pkg.Name) is incomplete (only $(Get-PackageToolCount $Id) tool(s), expected $min+) - acquiring the full package." 'WARN'
        } else {
            Write-PkgLog "$($pkg.Name) present: $dir"; return $true
        }
    }
    # Reinstall (-Force) is a clean wipe-and-reinstall so stale files from an older version don't linger.
    # Best effort: an in-use binary stays locked and is overwritten in place below (or fails loudly there).
    if ($Force -and (Test-Path -LiteralPath $dir)) {
        Write-PkgLog "$($pkg.Name): removing the existing install for a clean reinstall"
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
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
                        Save-UrlWithProgress $pkg.Url $tmp $pkg.Name
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
                            Save-UrlWithProgress $pkg.Url $zip $pkg.Name
                        } catch {
                            if (-not $pkg.FallbackUrl) { throw }
                            Write-PkgLog "$($pkg.Name) download failed ($($_.Exception.Message)); trying fallback $($pkg.FallbackUrl)" 'WARN'
                            Save-UrlWithProgress $pkg.FallbackUrl $zip $pkg.Name
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
        $n = @(Get-ChildItem $dir -Filter *.exe -File -ErrorAction SilentlyContinue).Count
        Write-PkgLog "$($pkg.Name) installed and verified - $n tool(s) in $dir" 'OK'
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
