#Requires -Version 5.1
<#
.SYNOPSIS
  Deterministic tests for the shared platform symbol service (Common\Symbols.ps1): platform.json round-trip,
  the shared-symbol-path default/override, and the best-effort PDB builder's skip handling. No GUI, no
  network, no registry. Redirects the store/config to a throwaway temp dir so the machine config is untouched.
  Run: powershell -NoProfile -ExecutionPolicy Bypass -File this.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\Common\Symbols.ps1')

# Redirect the platform root to a throwaway dir (the module exposes these as script-scoped vars).
$script:PlatformRoot       = Join-Path ([IO.Path]::GetTempPath()) ('rt_sym_' + [guid]::NewGuid().ToString('N'))
$script:PlatformConfigFile = Join-Path $script:PlatformRoot 'platform.json'
$script:SymbolStoreDir     = Join-Path $script:PlatformRoot 'Symbols'

$script:fail = 0; $script:count = 0
function Check([string]$name, [bool]$cond) { $script:count++; if ($cond) { Write-Host "  ok   $name" } else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ } }

try {
    Write-Host 'defaults'
    Check 'default SymbolPath is blank'        ((Read-PlatformConfig).SymbolPath -eq '')
    Check 'store path ends in \Symbols'         ((Get-SymbolStore) -match '\\Symbols$')
    Check 'store dir is created on demand'       (Test-Path -LiteralPath $script:SymbolStoreDir)

    Write-Host 'shared symbol path'
    $def = Get-SharedSymbolPath ''
    Check 'blank -> SRV* shared store + MS server' ($def -match '^SRV\*.*\\Symbols\*https://msdl\.microsoft\.com/download/symbols$')
    Check 'explicit override wins verbatim'        ((Get-SharedSymbolPath 'SRV*C:\on-site*https://x') -eq 'SRV*C:\on-site*https://x')
    Check 'whitespace override falls back'          ((Get-SharedSymbolPath '   ') -eq $def)

    Write-Host 'platform.json round-trip (heals + merges over defaults)'
    $c = Read-PlatformConfig; $c.SymbolPath = 'SRV*C:\mysym*https://srv'; Save-PlatformConfig $c
    Check 'saved value reads back'      ((Read-PlatformConfig).SymbolPath -eq 'SRV*C:\mysym*https://srv')
    Check 'config file written'          (Test-Path -LiteralPath $script:PlatformConfigFile)
    '{ not json ' | Set-Content -LiteralPath $script:PlatformConfigFile
    Check 'unreadable file heals to default' ((Read-PlatformConfig).SymbolPath -eq '')

    Write-Host 'Build-Pdbs is best-effort per file'
    $txt = Join-Path $script:PlatformRoot 'note.txt'; 'x' | Set-Content -LiteralPath $txt
    $r = Build-Pdbs -Files @($txt, 'Z:\does\not\exist.dll')
    Check 'non-binary skipped, not generated'   (-not $r[0].Generated)
    Check 'non-binary reason given'              ($r[0].Reason -match 'not a \.dll/\.exe')
    Check 'missing file skipped with reason'     ((-not $r[1].Generated) -and ($r[1].Reason -match 'not found'))
    Check 'one result object per input file'     ($r.Count -eq 2)
}
finally {
    Remove-Item -LiteralPath $script:PlatformRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0}/{1} passed" -f ($script:count - $script:fail), $script:count) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 } else { exit 0 }
