# Text menu (-CLI or GUI-unavailable fallback): lists the tools and launches the chosen one.
function Show-CliMenu {
    $items = @(
        @{ Name = 'PerfView performance tracing';   Path = $script:ToolPerfView },
        @{ Name = 'ProcDump monitor (background)';   Path = $script:ToolMonitor },
        @{ Name = 'One-shot process dump capture';   Path = $script:ToolCase }
    )
    while ($true) {
        Write-Host "`n========== Reporting & Troubleshooting toolset (v$ScriptVersion) ==========" -ForegroundColor Cyan
        for ($i = 0; $i -lt $items.Count; $i++) { Write-Host (" {0}) {1}" -f ($i + 1), $items[$i].Name) }
        Write-Host ' S) Install desktop shortcut'
        Write-Host ' Q) Quit'
        try { $sel = (Read-Host 'Select').Trim().ToUpper() }
        catch { Write-Host 'No interactive input available.' -ForegroundColor Yellow; return }
        if ($sel -eq 'Q') { return }
        if ($sel -eq 'S') {
            try { $lnk = Install-DesktopShortcut -TargetBat (Join-Path $script:ToolkitRoot 'run.bat'); Write-Host "Desktop shortcut created: $lnk" -ForegroundColor Green }
            catch { Write-Host "Shortcut install failed: $($_.Exception.Message)" -ForegroundColor Yellow }
            continue
        }
        $n = 0
        if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $items.Count) { Start-Tool $items[$n - 1].Path }
        else { Write-Host 'Unknown choice.' -ForegroundColor Yellow }
    }
}
