# Dump fault-signature engine - loader shim.
#
# The engine is split by concern into Dump\*.ps1 (each one focused and maintainable); this file just
# dot-sources them in dependency order. Callers keep dot-sourcing THIS file (ProcDumpMonitor.ps1,
# DumpTriage.ps1), and the bitness-redirected child (Walk.ps1 Invoke-InMatchingHost) reloads THIS file
# via $script:DumpIdPath - so splitting the engine changed nothing for any caller.
#
#   Dump\Core.ps1        machine key, short hash, KnownIssues dir
#   Dump\Minidump.ps1    byte-parse of minidump streams (signature, bitness, OS/CPU, comment)
#   Dump\Signature.ps1   scheme-versioned stable id
#   Dump\Walk.ps1        ClrMD managed walk + bitness dispatch + dep checks
#   Dump\Diagnosis.ps1   kind-aware fact -> plain-language problem statement
#   Dump\Facts.ps1       per-event procdump-facts JSON emitter
#   Dump\KnownIssues.ps1 local registry / per-machine dedupe / occurrences / baseline
#   Dump\Triage.ps1      triage one dump end-to-end

# This shim's own path, so a bitness-redirected child (Invoke-InMatchingHost) reloads the whole engine.
$script:DumpIdPath = $PSCommandPath

$__dumpDir = Join-Path (Split-Path -Parent $PSCommandPath) 'Dump'
if (-not (Test-Path -LiteralPath $__dumpDir)) {
    throw "Dump engine folder not found: $__dumpDir. The deploy is incomplete (Common\Dump\ missing) - re-run Install on the Monitor tab."
}
foreach ($__m in 'Core', 'Minidump', 'Signature', 'Walk', 'Diagnosis', 'KnownIssues', 'Facts', 'Triage') {
    $__f = Join-Path $__dumpDir "$__m.ps1"
    if (-not (Test-Path -LiteralPath $__f)) { throw "Dump engine file missing: $__f (incomplete deploy - re-run Install on the Monitor tab)." }
    . $__f
}
