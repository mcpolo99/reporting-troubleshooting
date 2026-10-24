# Launches a tool (path relative to $script:ToolkitRoot) in its own console; used by the CLI menu.
function Start-Tool([string]$RelativePath) {
    $path = Join-Path $script:ToolkitRoot $RelativePath
    if (-not (Test-Path $path)) {
        $msg = "Tool not found:`n$path"
        try { [void][System.Windows.MessageBox]::Show($msg, 'Reporting & Troubleshooting') }
        catch { Write-Host $msg -ForegroundColor Yellow }
        return
    }
    Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$path`""
}
