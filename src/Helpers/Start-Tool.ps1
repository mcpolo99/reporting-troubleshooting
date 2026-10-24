<#
    .SYNOPSIS
        Launches a toolset tool in its own console. The tool self-elevates as needed; if we are already
        elevated the child inherits it. Path is relative to $script:ToolkitRoot.
#>
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
