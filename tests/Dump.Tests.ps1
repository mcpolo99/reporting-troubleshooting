#Requires -Version 5.1
<#
.SYNOPSIS
  Deterministic unit tests for the dump engine's PURE logic (classification, signature, diagnosis).

  Inputs are SYNTHETIC, fixed signatures - never real dumps. Real dumps are live data that changes with
  every capture, so they are not a test surface; what must stay correct is the logic that turns a signature
  into a verdict. Dependency-free (no Pester) so it runs in stock Windows PowerShell 5.1 and pwsh alike.

  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Dump.Tests.ps1   (exit 0 = pass)
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\Common\DumpId.ps1')

$script:fail = 0; $script:count = 0
function Check([string]$name, [bool]$cond) {
    $script:count++
    if ($cond) { Write-Host "  ok   $name" } else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}
# synthetic signature with sensible defaults; override any field by name
function New-Sig([hashtable]$over) {
    $s = @{ Kind = 'hang'; Code = $null; Module = $null; Offset = $null; Address = $null; ThreadId = 0
            ModuleVer = $null; ModuleTs = $null; ImageName = 'app'; ImageVer = '1.0'; ClrName = 'clr'; ClrVer = '4.8'
            Os = 'Windows NT 10.0.17763'; Cpus = 4; Arch = 'x64'; ProcDumpComment = 'Hung window detected'
            Frames = @(); ExceptionType = $null; UiConfirmed = $true; DispatcherFrame = 'System.Windows.Threading.Dispatcher.PushFrame'
            AppFrame = $null; AppFrameDepth = 0; StormOperations = @(); StormDominantFrame = $null; StormDominantCount = 0; StackDepth = 0 }
    foreach ($k in $over.Keys) { $s[$k] = $over[$k] }
    [pscustomobject]$s
}

Write-Host 'frame classification'
Check 'framework: System.*'     (Test-FrameworkFrame 'System.Windows.Data.BindingExpression.Activate')
Check 'framework: MS.Internal'  (Test-FrameworkFrame 'MS.Internal.Data.PropertyPathWorker.ReplaceItem')
Check 'app: bInterop.*'         (-not (Test-FrameworkFrame 'bInterop.PavWrapper.Process'))
Check 'app: <Module>.*'         (-not (Test-FrameworkFrame '<Module>.ExecuteHelper.CamProcessOptimizeProgram'))
Check 'bootstrap: EntryPoint.Main' (Test-BootstrapFrame 'bSuite.EntryPoint.Main')
Check 'not bootstrap: app method'  (-not (Test-BootstrapFrame 'bControl.Foo.Bar'))

Write-Host 'exception severity (NTSTATUS bits, dynamic - no code table)'
Check 'fatal: C0000005 (error)'      (Test-FatalExceptionCode 'C0000005')
Check 'fatal: C0000374 (error)'      (Test-FatalExceptionCode 'C0000374')
Check 'not fatal: 40000005 (warning)' (-not (Test-FatalExceptionCode '40000005'))
Check 'not fatal: 00000000'          (-not (Test-FatalExceptionCode '00000000'))

Write-Host 'exception name (dynamic via ntdll)'
Check 'C0000005 resolves to text'    ([bool](Get-ExceptionName 'C0000005'))
Check 'DEADBEEF unknown -> null'     (-not (Get-ExceptionName 'DEADBEEF'))

Write-Host 'signature (scheme-versioned canonical)'
$id = Get-DumpStableId (New-Sig @{ Kind = 'crash'; Code = 'C0000374'; Module = 'CamOptimizers'; Offset = 0xa220; Address = 0x1 })
Check 'crash canonical s1|t1|code|mod+off' ($id.Canonical -eq 's1|t1|C0000374|CamOptimizers+0xa220')
Check 'scheme = 1'                         ($id.Scheme -eq 1)
$idh = Get-DumpStableId (New-Sig @{ Kind = 'hang'; Frames = @('A.B', 'C.D') })
Check 'hang canonical s1|t2h|frames'       ($idh.Canonical -eq 's1|t2h|A.B|C.D')

Write-Host 'diagnosis (kind-aware verdict)'
Check 'crash -> category crash'            ((Get-DumpDiagnosis (New-Sig @{ Kind = 'crash'; Code = 'C0000374'; Module = 'M'; Offset = 1 })).category -eq 'crash')
Check 'crash problem cites the code'       ((Get-DumpDiagnosis (New-Sig @{ Kind = 'crash'; Code = 'C0000374'; Module = 'M'; Offset = 1 })).problem -match 'C0000374')
Check 'managed-exception -> category'      ((Get-DumpDiagnosis (New-Sig @{ Kind = 'managed-exception'; Code = 'E0434352'; ExceptionType = 'System.NullReferenceException'; Frames = @('A.B') })).category -eq 'managed-exception')
Check 'vendor at leaf -> ui-thread-busy'   ((Get-DumpDiagnosis (New-Sig @{ Frames = @('bInterop.PavWrapper.Process'); AppFrame = 'bInterop.PavWrapper.Process'; AppFrameDepth = 1; StackDepth = 2 })).category -eq 'ui-thread-busy')
Check 'deep app + storm -> storm-triggered' ((Get-DumpDiagnosis (New-Sig @{ Frames = @('System.Windows.A'); AppFrame = 'Platform.X.OnLoaded'; AppFrameDepth = 117; StormOperations = @('visual-tree-walk', 'layout'); StormDominantFrame = 'System.Windows.DescendentsWalker.X'; StormDominantCount = 16; StackDepth = 145 })).category -eq 'ui-thread-storm-triggered')
Check 'storm, no app -> hang-wpf-storm'    ((Get-DumpDiagnosis (New-Sig @{ Frames = @('System.Windows.Data.A'); AppFrame = $null; StormOperations = @('data-binding', 'layout'); StormDominantFrame = 'System.Windows.DependencyObject.UpdateEffectiveValue'; StormDominantCount = 10; StackDepth = 120 })).category -eq 'hang-wpf-storm')
Check 'shallow framework -> framework-only' ((Get-DumpDiagnosis (New-Sig @{ Frames = @('MS.Win32.HwndSubclass.DefWndProcWrapper'); AppFrame = $null; StormOperations = @(); StormDominantCount = 0; StackDepth = 7 })).category -eq 'hang-framework-only')
Check 'captureReason hung-window'          ((Get-DumpDiagnosis (New-Sig @{ Frames = @('A.B'); AppFrame = 'A.B'; AppFrameDepth = 1 })).captureReason -eq 'hung-window')

Write-Host ''
Write-Host ("{0}/{1} passed" -f ($script:count - $script:fail), $script:count) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 } else { exit 0 }
