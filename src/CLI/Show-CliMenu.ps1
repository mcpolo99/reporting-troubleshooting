<#
    .SYNOPSIS
        Text-menu fallback / -CLI mode for the toolset. Lists the tools and launches the chosen one via
        Start-Tool. Uses the tool path variables and $ScriptVersion from ReportingToolkit.ps1.
#>
function Show-CliMenu {
    $items = @(
        @{ Name = 'PerfView performance tracing';   Path = $script:ToolPerfView },
        @{ Name = 'ProcDump monitor (background)';   Path = $script:ToolMonitor },
        @{ Name = 'One-shot process dump capture';   Path = $script:ToolCase }
    )
    while ($true) {
        Write-Host "`n========== Reporting & Troubleshooting toolset (v$ScriptVersion) ==========" -ForegroundColor Cyan
        for ($i = 0; $i -lt $items.Count; $i++) { Write-Host (" {0}) {1}" -f ($i + 1), $items[$i].Name) }
        Write-Host ' Q) Quit'
        try { $sel = (Read-Host 'Select').Trim().ToUpper() }
        catch { Write-Host 'No interactive input available.' -ForegroundColor Yellow; return }
        if ($sel -eq 'Q') { return }
        $n = 0
        if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $items.Count) { Start-Tool $items[$n - 1].Path }
        else { Write-Host 'Unknown choice.' -ForegroundColor Yellow }
    }
}
