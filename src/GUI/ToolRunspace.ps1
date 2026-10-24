<#
    .SYNOPSIS
        Background runspace host for the interactive UI. Each tool runs in its OWN isolated runspace, so
        their colliding names ($AppName, Read-Config, Install-*, Show-Status ...) never clash and long
        actions never freeze the window. Actions stream their console output into a sink, drained on the
        UI thread by Update-ToolJobs (a DispatcherTimer tick).
    .NOTES
        Dot-sourced by Show-MainWindow.ps1. A tool loaded with -Load is dot-sourced with RT_LIBRARY=1 so
        it defines its functions without running its entry/elevation; the UI then calls those functions.
#>

$script:ToolJobs = New-Object System.Collections.ArrayList

# Creates an isolated STA runspace. With -Load, dot-sources the tool as a library (functions only) and
# turns on console echo so Write-Log output is captured on the Information stream.
function New-ToolRunspace {
    param([string]$ToolPath, [switch]$Load)
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    if ($Load) {
        $init = [powershell]::Create(); $init.Runspace = $rs
        [void]$init.AddScript(@"
`$env:RT_LIBRARY = '1'
. "$ToolPath"
`$script:EchoLog = `$true
New-LogFile
"@)
        [void]$init.Invoke()
        $init.Dispose()
    }
    return $rs
}

# Runs a scriptblock async in the given runspace. OnText receives each output line (on the UI thread,
# from Update-ToolJobs); OnDone fires once when the action completes.
function Start-ToolJob {
    param(
        [System.Management.Automation.Runspaces.Runspace]$Runspace,
        [scriptblock]$Script,
        [object[]]$ArgList = @(),
        [scriptblock]$OnText,
        [scriptblock]$OnDone
    )
    $ps = [powershell]::Create()
    $ps.Runspace = $Runspace
    [void]$ps.AddScript($Script)
    foreach ($a in $ArgList) { [void]$ps.AddArgument($a) }
    $job = [pscustomobject]@{ PS = $ps; Async = $ps.BeginInvoke(); InfoIdx = 0; OnText = $OnText; OnDone = $OnDone }
    [void]$script:ToolJobs.Add($job)
    return $job
}

# Drains new output from every in-flight job and finalizes completed ones. Call on the UI thread.
function Update-ToolJobs {
    for ($i = $script:ToolJobs.Count - 1; $i -ge 0; $i--) {
        $job  = $script:ToolJobs[$i]
        $info = $job.PS.Streams.Information
        while ($job.InfoIdx -lt $info.Count) {
            $rec = $info[$job.InfoIdx]; $job.InfoIdx++
            if ($job.OnText) { & $job.OnText ([string]$rec.MessageData) }
        }
        if ($job.Async.IsCompleted) {
            try {
                $out = $job.PS.EndInvoke($job.Async)
                if ($out) { foreach ($o in $out) { if ($o -ne $null -and $job.OnText) { & $job.OnText ([string]$o) } } }
            } catch { if ($job.OnText) { & $job.OnText "ERROR: $($_.Exception.Message)" } }
            foreach ($e in $job.PS.Streams.Error) { if ($job.OnText) { & $job.OnText "ERROR: $($e.ToString())" } }
            $job.PS.Dispose()
            $script:ToolJobs.RemoveAt($i)
            if ($job.OnDone) { & $job.OnDone }
        }
    }
}

# True while any job is still running (used to keep the poll timer alive / guard re-entrancy).
function Test-ToolJobsBusy { return ($script:ToolJobs.Count -gt 0) }

# Runs a scriptblock synchronously in a runspace and returns its output. For reading config/profiles to
# populate the editors - call only when that runspace is idle (no in-flight job for the tool).
function Invoke-ToolSync {
    param([System.Management.Automation.Runspaces.Runspace]$Runspace, [scriptblock]$Script, [object[]]$ArgList = @())
    $ps = [powershell]::Create(); $ps.Runspace = $Runspace
    [void]$ps.AddScript($Script)
    foreach ($a in $ArgList) { [void]$ps.AddArgument($a) }
    try { return $ps.Invoke() } finally { $ps.Dispose() }
}
