# =============================================================================
# Reporting & Troubleshooting toolset - shared logging component
# =============================================================================
# Non-locking, size-rolling, pruned log engine shared by the tools that log this way
# (PerfViewCapture, ProcDumpMonitor). Dot-source it so the functions run in the caller's
# script scope and read/write the caller's state directly.
#
# The caller must define, before calling these:
#   $LogDir              folder for log files
#   $AppName             used as the file-name filter when pruning
#   $script:LogPrefix    base name for the log file
#   $script:EchoLog      [bool] also print to the console
#   $script:LogMaxMB     [int]  roll to a new part past this size
#   $script:LogFile / $script:LogBase / $script:LogPart / $script:LogCount  (state; may start $null/0)
#
# Log name: <prefix>_<launch datetime>.log  ->  rolled parts: <prefix>_<launch datetime>_part2.log ...
# =============================================================================

function New-LogFile {
    $script:LogBase = '{0}_{1:yyyyMMdd_HHmmss}' -f $script:LogPrefix, (Get-Date)
    $script:LogPart = 1
    $script:LogFile = Join-Path $LogDir "$($script:LogBase).log"
}

# Non-locking: open, append, close for every line; others may read/write/delete meanwhile.
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss.fff} [{1,-5}] [PID {2}] {3}' -f (Get-Date), $Level, $PID, $Message

    if ($script:EchoLog) {
        switch ($Level) {
            'ERROR' { Write-Host $Message -ForegroundColor Red }
            'WARN'  { Write-Host $Message -ForegroundColor Yellow }
            default { Write-Host $Message }
        }
    }
    if (-not $script:LogFile) { return }

    # Check size every 200 lines too, so a burst of logging can't outgrow the limit between cleanups
    $script:LogCount++
    if ($script:LogCount % 200 -eq 0) { Update-LogRoll }

    try { if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null } } catch { return }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($line + [Environment]::NewLine)
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    for ($i = 0; $i -lt 5; $i++) {
        try {
            $fs = New-Object System.IO.FileStream($script:LogFile, [System.IO.FileMode]::Append,
                                                  [System.IO.FileAccess]::Write, $share)
            try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
            return
        } catch { Start-Sleep -Milliseconds 100 }
    }
}

# Size rotation: when the current log exceeds LogMaxMB, continue in <base>_partN.log.
function Update-LogRoll {
    try {
        if ($script:LogFile -and (Test-Path $script:LogFile) -and
            (Get-Item $script:LogFile).Length -ge ($script:LogMaxMB * 1MB)) {
            $old = Split-Path $script:LogFile -Leaf
            $script:LogPart++
            $script:LogFile = Join-Path $LogDir ('{0}_part{1}.log' -f $script:LogBase, $script:LogPart)
            Write-Log "Log continued from $old (size limit $($script:LogMaxMB) MB)."
        }
    } catch { }
}

function Remove-OldLogs([int]$Keep) {
    Get-ChildItem -Path $LogDir -Filter "$AppName*.log" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $script:LogFile } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip ([Math]::Max($Keep - 1, 0)) |
        ForEach-Object { try { Remove-Item $_.FullName -Force -ErrorAction Stop } catch { } }
}
