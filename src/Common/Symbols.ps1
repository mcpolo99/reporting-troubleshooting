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
# The public symbol servers the default path searches (in order), all caching into the one shared store:
#   - Microsoft (msdl): OS / CLR / .NET Framework symbols
#   - NuGet.org: symbols for packages that published a .snupkg (Newtonsoft.Json and many OSS libraries)
# A site can still override SymbolPath entirely (e.g. an on-prem store) on the General tab.
$script:PublicSymbolServers = @(
    'https://msdl.microsoft.com/download/symbols',
    'https://symbols.nuget.org/download/symbols'
)

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
        # Blank = the default: cache into the shared symbol store, backed by the public symbol servers.
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
    # One SRV entry, one downstream store, multiple upstream servers tried in order (symsrv/PerfView syntax).
    if (-not $sp) { $sp = "SRV*$(Get-SymbolStore)*" + ($script:PublicSymbolServers -join '*') }
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

# The http(s) symbol servers referenced by an _NT_SYMBOL_PATH (the `*https://...` legs of SRV*/SRV entries).
# Used to ask "are this module's symbols already published publicly?" before we bother generating them.
function Get-SymbolServers([string]$SymbolPath) {
    if (-not "$SymbolPath".Trim()) { $SymbolPath = Get-SharedSymbolPath '' }
    @([regex]::Matches($SymbolPath, '(?i)https?://[^*;]+') | ForEach-Object { $_.Value.TrimEnd('/') }) | Select-Object -Unique
}

# Read a PE's debug directory and return its PDB symbol-server key(s):
#   @{ PdbName=<leaf>; Signature=<primary key>; Signatures=@(all candidate keys); Embedded=<bool> }
# or $null when the file has no CodeView entry (no debug directory, native-without-PDB, unreadable).
# The SSQP key is <GUID:N upper> + <age>: a WINDOWS PDB uses the CodeView age (hex), a PORTABLE PDB uses the
# literal 'FFFFFFFF' (its real age is meaningless to the server). A portable PDB is signalled by a PdbChecksum
# (type 19) or Embedded (type 17) debug entry, so we scan ALL entries before forming the key. An embedded PDB
# lives inside the DLL itself (no server, no generation needed) -> Embedded=$true means "already resolvable".
# Same keying dbghelp/symsrv use, so we can probe a symbol server with a plain HTTP GET - no symchk/dbghelp
# dependency (RT ships neither).
function Get-PdbKey([string]$File) {
    try { $b = [System.IO.File]::ReadAllBytes($File) } catch { return $null }
    if ($b.Length -lt 0x40) { return $null }
    $pe = [BitConverter]::ToInt32($b, 0x3C)
    if ($pe -le 0 -or ($pe + 0x18) -ge $b.Length) { return $null }
    if ($b[$pe] -ne 0x50 -or $b[$pe+1] -ne 0x45) { return $null }   # 'PE'
    $coff = $pe + 4
    $numSec  = [BitConverter]::ToUInt16($b, $coff + 2)
    $optSize = [BitConverter]::ToUInt16($b, $coff + 16)
    $opt     = $coff + 20
    if (($opt + 2) -ge $b.Length) { return $null }
    $magic = [BitConverter]::ToUInt16($b, $opt)             # 0x10b=PE32, 0x20b=PE32+
    $dd    = $opt + $(if ($magic -eq 0x20b) { 112 } else { 96 })   # data-directory table offset
    $dbgDir = $dd + 6 * 8                                   # IMAGE_DIRECTORY_ENTRY_DEBUG = index 6
    if (($dbgDir + 8) -gt $b.Length) { return $null }
    $dbgRva  = [BitConverter]::ToUInt32($b, $dbgDir)
    $dbgSize = [BitConverter]::ToUInt32($b, $dbgDir + 4)
    if ($dbgRva -eq 0 -or $dbgSize -eq 0) { return $null }
    # RVA -> file offset via the section table (starts right after the optional header).
    $sec = $opt + $optSize
    $rvaToFile = {
        param($rva)
        for ($i = 0; $i -lt $numSec; $i++) {
            $s = $sec + $i * 40
            if (($s + 40) -gt $b.Length) { break }
            $va  = [BitConverter]::ToUInt32($b, $s + 12)
            $vsz = [BitConverter]::ToUInt32($b, $s + 8)
            $raw = [BitConverter]::ToUInt32($b, $s + 20)
            if ($rva -ge $va -and $rva -lt ($va + [Math]::Max($vsz, 1))) { return ($raw + ($rva - $va)) }
        }
        0
    }
    $dbgOff = & $rvaToFile $dbgRva
    if (-not $dbgOff) { return $null }
    # Scan ALL 28-byte debug directory entries: capture the CodeView (type 2) record, and note whether a
    # PdbChecksum (19) or Embedded portable PDB (17) entry marks this as a portable PDB.
    $guid = $null; $age = 0; $name = $null; $portable = $false; $embedded = $false
    for ($e = $dbgOff; ($e + 28) -le $b.Length -and ($e - $dbgOff) -lt $dbgSize; $e += 28) {
        $type = [BitConverter]::ToUInt32($b, $e + 12)
        if ($type -eq 19) { $portable = $true; continue }                      # IMAGE_DEBUG_TYPE_PDBCHECKSUM
        if ($type -eq 17) { $portable = $true; $embedded = $true; continue }    # EMBEDDED_PORTABLE_PDB
        if ($type -ne 2)  { continue }                                         # CODEVIEW
        $cv = [BitConverter]::ToUInt32($b, $e + 24)         # PointerToRawData (file offset of the CV record)
        if (($cv + 24) -gt $b.Length) { continue }
        if ([BitConverter]::ToUInt32($b, $cv) -ne 0x53445352) { continue }      # 'RSDS'
        $guid = [guid]::new([byte[]]($b[($cv+4)..($cv+19)]))
        $age  = [BitConverter]::ToUInt32($b, $cv + 20)
        $end  = $cv + 24; while ($end -lt $b.Length -and $b[$end] -ne 0) { $end++ }
        $path = [System.Text.Encoding]::UTF8.GetString($b[($cv+24)..($end-1)])
        $name = [System.IO.Path]::GetFileName(($path -replace '\\', '/'))
    }
    if (-not $guid -or -not $name) { return $null }
    $gN   = $guid.ToString('N').ToUpperInvariant()
    $aHex = '{0:X}' -f $age
    # Portable: 'FFFFFFFF' is the real server key; keep the raw-age key as a harmless fallback. Windows: age only.
    # (Per-branch statement assignment, then re-wrap: a single-element array from an if-EXPRESSION unrolls to a
    # scalar string, which would make Signatures[0] index the first character instead of the whole key.)
    if ($portable) { $sigs = @("${gN}FFFFFFFF", "$gN$aHex") } else { $sigs = @("$gN$aHex") }
    $sigs = @($sigs | Select-Object -Unique)
    [pscustomobject]@{ PdbName = $name; Signature = $sigs[0]; Signatures = $sigs; Embedded = $embedded }
}

# Are this module's symbols already available without us generating them? $true = yes (an embedded PDB, or a
# PDB published on a configured public server) -> skip; $false = every reachable server returned not-found;
# $null = unknown (no CodeView key, or every server errored/unreachable). Callers treat $null as "build anyway"
# so a vendor symbol is never wrongly skipped. Portable PDBs carry two candidate keys (FFFFFFFF + raw age);
# a hit on either, on any server, counts as published.
function Test-SymbolPublished([string]$File, [string]$SymbolPath) {
    $key = Get-PdbKey $File
    if (-not $key) { return $null }
    if ($key.Embedded) { return $true }        # symbols live inside the DLL - nothing to download or generate
    $servers = Get-SymbolServers $SymbolPath
    if (-not $servers.Count) { return $null }
    $sawServer = $false
    foreach ($srv in $servers) {
        foreach ($sig in @($key.Signatures)) {
            $url = "$srv/$($key.PdbName)/$sig/$($key.PdbName)"
            try {
                $r = Invoke-WebRequest -Uri $url -Method Get -Headers @{ Range = 'bytes=0-0' } -MaximumRedirection 5 -TimeoutSec 20 -UseBasicParsing -ErrorAction Stop
                $sawServer = $true
                if ([int]$r.StatusCode -ge 200 -and [int]$r.StatusCode -lt 300) { return $true }
            } catch {
                $sc = $null; try { $sc = [int]$_.Exception.Response.StatusCode } catch { }
                if ($sc -eq 416) { return $true }                 # range-not-satisfiable = the file exists (0 bytes)
                if ($sc -eq 404 -or $sc -eq 403) { $sawServer = $true; continue }   # not on this server under this key
                # any other error (DNS/timeout/offline/proxy) = we cannot tell from this server
            }
        }
    }
    if ($sawServer) { return $false } else { return $null }
}

# Best-effort "build symbols from files": for each selected binary, ask ngen to emit a PDB for its native
# image into the shared store (or $OutDir). `ngen createpdb` only works on a file that HAS an NGEN native
# image (R2R / .NET Core need crossgen2 - not here; native-without-PDB can't be generated). Each file is
# attempted independently and reported generated/skipped + reason, so one unsupported file never stops the
# batch. Returns one result object per input file: @{ File; Generated; Pdb; Reason }.
function Build-Pdbs {
    param(
        [string[]]$Files,
        [string]$OutDir,
        # When set, first ask the public symbol server(s) in $SymbolPath whether this module's PDB already
        # exists; if so, skip it (we only generate for binaries with NO public symbols, e.g. vendor DLLs).
        [switch]$SkipIfPublic,
        [string]$SymbolPath)
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
        if ($SkipIfPublic) {
            $pub = Test-SymbolPublished $f $SymbolPath
            if ($pub -eq $true) {
                Write-SymLog "skip $name - symbols already published publicly"
                $results += [pscustomobject]@{ File = $f; Generated = $false; Pdb = $null; Reason = 'public symbols already available (symbol server)' }; continue
            }
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
