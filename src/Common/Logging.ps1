# Shared non-locking, size-rolling log engine. Dot-source it; it uses the caller's $LogDir, $AppName and
# $script:LogPrefix/EchoLog/LogMaxMB/LogFile/LogBase/LogPart/LogCount.

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
