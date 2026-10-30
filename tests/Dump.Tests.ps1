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

Write-Host 'facts event: wire-contract top-level projection (CONTRACT.md 7 - signatureId is load-bearing)'
$tmpDump = Join-Path $env:TEMP ('facts_{0}.dmp' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
Set-Content -LiteralPath $tmpDump -Value 'X' -Encoding ascii
try {
    $fsig = New-Sig @{ Kind = 'hang'; Frames = @('A.B', 'C.D'); ImageVer = '2.3.4' }
    $fido = Get-DumpStableId $fsig
    $fev  = Get-DumpFacts -Sig $fsig -IdObj $fido -DumpPath $tmpDump
    Check 'top-level signatureId present'       ([bool]$fev.signatureId)
    Check 'top-level signatureId == ids value'  ($fev.signatureId -eq $fev.ids.signatureId)
    Check 'top-level signatureId == recipe id'  ($fev.signatureId -eq $fido.Id)
    Check 'top-level deviceId mirrors ids'      ($fev.deviceId -eq $fev.ids.deviceId)
    Check 'top-level productVersion = imageVer' ($fev.productVersion -eq '2.3.4')
    Check 'top-level class + severity present'  ([bool]$fev.class -and [bool]$fev.severity)
    Check 'top-level capturedAtUtc present'     ([bool]$fev.capturedAtUtc)
    Check 'top-level deviceId present'          ([bool]$fev.deviceId)   # CI-bound per CONTRACT 7; required for the per-device grant
} finally { Remove-Item -LiteralPath $tmpDump -Force -ErrorAction SilentlyContinue }

Write-Host 'dump file naming (ProcDump_<pc>_<process>_<tag>_<yyyyMMdd>_<HHmmss>.dmp)'
$when = Get-Date '2026-10-28 14:30:05'
$fn = New-DumpFileName -Computer 'PC01' -Process 'bSuite' -Tag 'hang' -When $when
Check 'builds the full scheme'          ($fn -eq 'ProcDump_PC01_bSuite_hang_20261028_143005.dmp')
Check 'six underscore-delimited fields' ((([IO.Path]::GetFileNameWithoutExtension($fn)) -split '_').Count -eq 6)
Check 'tag: exception when code set'     ((Get-DumpTag -Code ([uint32]3221225477) -Trigger '') -eq 'exception')   # 0xC0000005
Check 'tag: hang from trigger text'      ((Get-DumpTag -Code $null -Trigger 'Hung window detected') -eq 'hang')
Check 'tag: manual otherwise'            ((Get-DumpTag -Code $null -Trigger 'Timed: process ran') -eq 'manual')
Check 'process token round-trips'        ((Get-DumpProcessFromName $fn) -eq 'bSuite')
Check 'process token: legacy name null'  ($null -eq (Get-DumpProcessFromName 'bSuite.exe_261019_084858.dmp'))
Check 'underscores in token collapse'    ((New-DumpFileName -Computer 'PC01' -Process 'my_app' -Tag 'hang' -When $when) -eq 'ProcDump_PC01_my-app_hang_20261028_143005.dmp')
Check 'empty token -> fallback'          ((Get-DumpProcessFromName (New-DumpFileName -Computer 'PC01' -Process '' -Tag 'hang' -When $when)) -eq 'app')
Check 'trailing .exe stripped'           ((Get-DumpProcessFromName (New-DumpFileName -Computer 'PC01' -Process 'bSuite.exe' -Tag 'hang' -When $when)) -eq 'bSuite')
Check 'only .exe stripped, dotted kept'  ((Get-DumpProcessFromName (New-DumpFileName -Computer 'PC01' -Process 'bSuite.NotRespondingHandler.exe' -Tag 'hang' -When $when)) -eq 'bSuite.NotRespondingHandler')

Write-Host 'device profile: fetch-and-overwrite cache, read-only use (#84)'
$pdir = Join-Path $env:TEMP ('devprof_{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
New-Item -ItemType Directory -Force $pdir | Out-Null
try {
    $ppath = Join-Path $pdir 'device-profile.json'
    '{"sigAAA":"uploaded","sigBBB":"granted"}' | Set-Content -LiteralPath $ppath -Encoding UTF8
    $prof = Get-DeviceProfile $ppath
    Check 'profile reads uploaded state'    ($prof['sigAAA'] -eq 'uploaded')
    Check 'profile reads granted state'     ($prof['sigBBB'] -eq 'granted')
    Check 'missing profile -> empty map'    ((Get-DeviceProfile (Join-Path $pdir 'nope.json')).Count -eq 0)

    # triage dedup honours the profile: a signature this device already 'uploaded' is SUPPRESSED (stop collecting),
    # even with an empty local registry; 'granted'/absent keep the first-sample-per-machine decision.
    $sig = New-Sig @{ Kind = 'hang'; Frames = @('A.B', 'C.D') }
    $ido = Get-DumpStableId $sig
    $dmp = Join-Path $pdir 't.dmp'; Set-Content -LiteralPath $dmp -Value 'X' -Encoding ascii
    $up  = Register-DumpOccurrence -IdObj $ido -Sig $sig -DumpPath $dmp -Dir (Join-Path $pdir 'ki_up') -DeviceUploaded $true
    Check 'profile uploaded -> suppress'    ($up.Action -eq 'suppress')
    $keep = Register-DumpOccurrence -IdObj $ido -Sig $sig -DumpPath $dmp -Dir (Join-Path $pdir 'ki_keep') -DeviceUploaded $false
    Check 'not uploaded -> keep first'      ($keep.Action -eq 'keep')

    # Known list / baseline must actually IGNORE (suppress) an already-analysed id, not merely annotate it. A
    # fresh machine (empty registry) with the id in the shipped/synced baseline keeps NO sample for it.
    $base = Join-Path $pdir 'baseline.json'
    (@($ido.Id) | ConvertTo-Json) | Set-Content -LiteralPath $base -Encoding UTF8
    $bk = Register-DumpOccurrence -IdObj $ido -Sig $sig -DumpPath $dmp -Dir (Join-Path $pdir 'ki_base') -BaselinePath $base -SuppressKnown $true -DeviceUploaded $false
    Check 'baseline-known -> suppress'      ($bk.Action -eq 'suppress')
    $bk2 = Register-DumpOccurrence -IdObj $ido -Sig $sig -DumpPath $dmp -Dir (Join-Path $pdir 'ki_base2') -BaselinePath $base -SuppressKnown $false -DeviceUploaded $false
    Check 'baseline-known + no-suppress keeps' ($bk2.Action -eq 'keep')
} finally { Remove-Item -Recurse -Force $pdir -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host ("{0}/{1} passed" -f ($script:count - $script:fail), $script:count) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 } else { exit 0 }
