#Requires -Version 5.1
<#
.SYNOPSIS
  Platform / General host surface backing: the shared symbol store + platform.json config + the best-effort
  PDB generator (Common\Symbols.ps1). The GUI loads this into its own runspace (RT_LIBRARY=1) so the General
  tab can read/save the common symbol path and build symbols off the UI thread.

  This is NOT a capture tool - it owns no app/ETW/registry state. It is the thin entry that dot-sources the
  shared platform services, so it follows the same plugin contract as the other tools (standalone-runnable,
  honours RT_LIBRARY, dot-sources the shared platform).
#>

$AppName   = 'Platform'
$BaseDir   = Join-Path $env:ProgramData 'ReportingTroubleshooting'
$LogDir    = Join-Path $BaseDir 'Logs'
$ScriptDir = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }

$script:LogFile = $null; $script:LogBase = $null; $script:LogPart = 1
$script:LogCount = 0;     $script:LogPrefix = $AppName
$script:EchoLog = $false; $script:LogMaxMB = 10

# Shared platform services (logging + common helpers + the symbol store/generator). Find Common\ upward.
$CommonDir = $null; $__probe = $ScriptDir
for ($__i = 0; $__i -lt 6 -and -not $CommonDir; $__i++) {
    foreach ($__c in @((Join-Path $__probe 'Common'), (Join-Path $__probe 'Scripts\Common'))) {
        if (Test-Path (Join-Path $__c 'Common.ps1')) { $CommonDir = $__c; break }
    }
    $__parent = Split-Path $__probe -Parent
    if (-not $__parent -or $__parent -eq $__probe) { break }
    $__probe = $__parent
}
if (-not $CommonDir) { throw "Shared components (Common\) not found from $ScriptDir upward." }
. (Join-Path $CommonDir 'Logging.ps1')
. (Join-Path $CommonDir 'Common.ps1')
. (Join-Path $CommonDir 'Symbols.ps1')

# Library mode: functions only (the GUI runspace loads us this way). Nothing to auto-run.
if ($env:RT_LIBRARY -eq '1') { return }

# Standalone: show where the shared store + config live and the resolved symbol path.
New-LogFile
Write-Host 'Platform services'
Write-Host ("  symbol store : {0}" -f (Get-SymbolStore))
Write-Host ("  platform.json: {0}" -f (Get-PlatformConfigPath))
Write-Host ("  symbol path  : {0}" -f (Get-SharedSymbolPath (Read-PlatformConfig).SymbolPath))
