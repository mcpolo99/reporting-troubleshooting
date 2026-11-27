# Shared platform: the common symbol store + a platform-level config, and a best-effort PDB generator.
# These are HOST/platform services (not a tool): dot-sourced by the host and by any tool that needs a symbol
# path. The store and platform.json live under the one app root %ProgramData%\ReportingTroubleshooting\ and
# are shared by every tool and build variant - never per-tool or per-case (like the package store).
#
# platform.json is the PLATFORM-resource config (a shared resource), distinct from a tool's own per-tool
# config. Today it holds one value, the common symbol path.

$script:PlatformRoot       = Join-Path $env:ProgramData 'ReportingTroubleshooting'
$script:PlatformConfigFile = Join-Path $script:PlatformRoot 'platform.json'
$script:SymbolStoreDir     = Join-Path $script:PlatformRoot 'Symbols'
$script:MsSymbolServer     = 'https://msdl.microsoft.com/download/symbols'

# Thin log shim: use the shared Write-Log when present (a tool runspace), else the console. Lets this file be
# dot-sourced both into a tool (with logging) and standalone without a hard dependency.
function Write-SymLog([string]$Message, [string]$Level = 'INFO') {
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log $Message $Level } else { Write-Host $Message }
}

# The shared symbol store (downstream cache for MS/OS/CLR symbols + generated app PDBs). Created on demand.
function Get-SymbolStore {
    if (-not (Test-Path -LiteralPath $script:SymbolStoreDir)) {
        New-Item -ItemType Directory -Path $script:SymbolStoreDir -Force -ErrorAction SilentlyContinue | Out-Null
    }
    $script:SymbolStoreDir
}

function Get-PlatformConfigPath { $script:PlatformConfigFile }

function Get-DefaultPlatformConfig {
    [pscustomobject]@{
        # Blank = the default: cache into the shared symbol store, backed by the Microsoft public server.
        # A non-blank value is used verbatim as _NT_SYMBOL_PATH (so an air-gapped site can point at a local store).
        SymbolPath = ''
    }
}

# Merge the saved platform.json over the defaults, so a new setting appears without discarding a user's edits
# and an unreadable file heals back to defaults (same convention as a tool's Read-Config).
function Read-PlatformConfig {
    $cfg = Get-DefaultPlatformConfig
    if (Test-Path -LiteralPath $script:PlatformConfigFile) {
        try {
            $file = Get-Content -LiteralPath $script:PlatformConfigFile -Raw | ConvertFrom-Json
            foreach ($name in $cfg.PSObject.Properties.Name) {
                if ($null -ne $file.$name) { $cfg.$name = $file.$name }
            }
        } catch {
            Write-SymLog "platform.json unreadable, using defaults: $($_.Exception.Message)" 'WARN'
        }
    }
    $cfg
}

function Save-PlatformConfig($cfg) {
    if (-not (Test-Path -LiteralPath $script:PlatformRoot)) { New-Item -ItemType Directory -Path $script:PlatformRoot -Force | Out-Null }
    $cfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:PlatformConfigFile -Encoding UTF8
}

# Resolve the _NT_SYMBOL_PATH to use. An explicit override (a saved SymbolPath) wins; otherwise the shared
# store backed by the MS public server. Any local down-stream cache dir(s) referenced are created so the
# symbol engine can write to them. This is the single shared default; PerfView and any future tool call it.
function Get-SharedSymbolPath([string]$Override) {
    $sp = "$Override".Trim()
    if (-not $sp) { $sp = "SRV*$(Get-SymbolStore)*$script:MsSymbolServer" }
    foreach ($m in [regex]::Matches($sp, '(?i)(?:SRV\*)?([A-Za-z]:\\[^*;]+)')) {
        $dir = $m.Groups[1].Value.Trim()
        if ($dir -and $dir -notmatch '^https?:') { New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null }
    }
    $sp
}

# Locate ngen.exe (ships with the .NET Framework). Prefer the 64-bit v4 runtime. $null if not present.
function Resolve-NgenPath {
    foreach ($p in @(
            (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\ngen.exe'),
            (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\ngen.exe'))) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $null
}

# Best-effort "build symbols from files": for each selected binary, ask ngen to emit a PDB for its native
# image into the shared store (or $OutDir). `ngen createpdb` only works on a file that HAS an NGEN native
# image (R2R / .NET Core need crossgen2 - not here; native-without-PDB can't be generated). Each file is
# attempted independently and reported generated/skipped + reason, so one unsupported file never stops the
# batch. Returns one result object per input file: @{ File; Generated; Pdb; Reason }.
function Build-Pdbs {
    param([string[]]$Files, [string]$OutDir)
    if (-not $OutDir) { $OutDir = Get-SymbolStore }
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force -ErrorAction SilentlyContinue | Out-Null }
    $ngen = Resolve-NgenPath
    $results = @()
    foreach ($f in @($Files)) {
        $name = Split-Path $f -Leaf
        if (-not (Test-Path -LiteralPath $f)) {
            $results += [pscustomobject]@{ File = $f; Generated = $false; Pdb = $null; Reason = 'file not found' }; continue
        }
        if ($f -notmatch '\.(dll|exe)$') {
            Write-SymLog "skip $name - not a .dll/.exe"
            $results += [pscustomobject]@{ File = $f; Generated = $false; Pdb = $null; Reason = 'not a .dll/.exe' }; continue
        }
        if (-not $ngen) {
            $results += [pscustomobject]@{ File = $f; Generated = $false; Pdb = $null; Reason = 'ngen.exe (.NET Framework) not found on this machine' }; continue
        }
        Write-SymLog "createpdb $name ..."
        try {
            $out  = & $ngen createpdb "$f" "$OutDir" 2>&1
            $code = $LASTEXITCODE
            $text = ($out | Out-String).Trim()
            if ($code -eq 0) {
                Write-SymLog "  generated PDB for $name -> $OutDir"
                $results += [pscustomobject]@{ File = $f; Generated = $true; Pdb = $OutDir; Reason = '' }
            } else {
                $reason = if ($text) { @($text -split "`r?`n" | Where-Object { $_ })[-1] } else { "ngen exit $code" }
                Write-SymLog "  skipped $name - $reason"
                $results += [pscustomobject]@{ File = $f; Generated = $false; Pdb = $null; Reason = $reason }
            }
        } catch {
            Write-SymLog "  skipped $name - $($_.Exception.Message)"
            $results += [pscustomobject]@{ File = $f; Generated = $false; Pdb = $null; Reason = $_.Exception.Message }
        }
    }
    $results
}
