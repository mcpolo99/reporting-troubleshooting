<#
    .SYNOPSIS
        Builds and shows the interactive main window. Each tool's actions run in its own background
        runspace (see ToolRunspace.ps1); the UI stays responsive and output streams into the Output box.
    .NOTES
        Dot-sourced by ReportingToolkit.ps1 (uses its $ScriptVersion, $script:*Schema and the tool paths
        $script:ToolPerfViewPath / ToolMonitorPath / ToolCasePath). Requires an STA desktop session and
        admin (the GUI self-elevates in ReportingToolkit.ps1 so runspace actions inherit the rights).
#>
function Show-MainWindow {
    Add-Type -AssemblyName PresentationFramework, System.Windows.Forms -ErrorAction Stop

    $xaml   = Get-Content -Path $script:MainWindowSchema -Raw
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
    try { $w = [System.Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    Set-WindowThemeResources -window $w -usesDarkMode (Get-SystemUsesDarkMode)

    # ---- controls (script-scoped so the async callbacks can reach them) ----
    foreach ($n in 'TxtOutput','LblBusy','LblVersion',
                   'BtnPvInstall','CmbPvProfile','TxtPvLabel','BtnPvStart','BtnPvStop','BtnPvAbort','TxtPvSeconds','BtnPvCollect','BtnPvOpen','BtnPvStatus','LblPvStatus',
                   'TxtMonApps','TxtMonKeep','BtnMonSave','BtnMonInstall','BtnMonStart','BtnMonStop','BtnMonStatus','BtnMonUninstall','LblMonStatus',
                   'TxtCaseExe','BtnCaseBrowse','ChkCaseHang','ChkCaseFusion','ChkCaseAppConfig','TxtCaseTimeout','BtnCaseRun','LblCaseStatus') {
        Set-Variable -Name $n -Scope script -Value $w.FindName($n)
    }
    $script:LblVersion.Text = "v$ScriptVersion"

    # ---- per-tool runspaces (PerfView + Monitor loaded as libraries; Case runs per-capture) ----
    $script:RsPv  = New-ToolRunspace -ToolPath $script:ToolPerfViewPath -Load
    $script:RsMon = New-ToolRunspace -ToolPath $script:ToolMonitorPath  -Load
    $script:Busy  = @{ Pv = $false; Mon = $false; Case = $false }

    # ---- output + status helpers (script-scoped scriptblocks) ----
    $script:Append = {
        param($t)
        if ($null -eq $t -or $t -eq '') { return }
        $script:TxtOutput.AppendText(("{0}  {1}`r`n" -f (Get-Date -Format 'HH:mm:ss'), $t))
        $script:TxtOutput.ScrollToEnd()
    }
    $script:SetPvStatus  = { param($t) $script:LblPvStatus.Text  = $t }
    $script:SetMonStatus = { param($t) $script:LblMonStatus.Text = $t }

    # status query scriptblocks (return a single string; no console output)
    $pvStatusSB = {
        $cfg = Read-Config; $active = Read-ActiveState
        $pv  = if (Test-Path $PerfViewExe) { (Get-Item $PerfViewExe).VersionInfo.FileVersion } else { 'not installed' }
        $act = if ($active) { "active: '$($active.Profile)'$(if($active.Label){" / $($active.Label)"})" } else { 'no active trace' }
        "PerfView: $pv  |  $act  |  output: $($cfg.OutputDir)"
    }
    $monStatusSB = {
        $cfg = Read-Config; $task = Get-MonitorTask
        $state = if ($task) { $task.State } else { 'not installed' }
        "Task: $state  |  apps: $($cfg.Apps -join ', ')  |  keep: $($cfg.KeepDumps)  |  dumps in $($cfg.DumpDir)"
    }
    # Refresh closures: run the status query in the tool runspace and route its single-string result
    # to the status label (via OnText). Built with Create() so the query body is embedded literally.
    $script:RefreshPv  = [scriptblock]::Create("Start-ToolJob -Runspace `$script:RsPv  -Script { $($pvStatusSB.ToString()) }  -OnText `$script:SetPvStatus  | Out-Null")
    $script:RefreshMon = [scriptblock]::Create("Start-ToolJob -Runspace `$script:RsMon -Script { $($monStatusSB.ToString()) } -OnText `$script:SetMonStatus | Out-Null")

    # generic action launcher with per-tool busy guard
    function script:Invoke-Action($toolKey, $rs, [scriptblock]$sb, [object[]]$argList, [scriptblock]$onDone) {
        if ($script:Busy[$toolKey]) { & $script:Append 'Busy - wait for the current action to finish.'; return }
        $script:Busy[$toolKey] = $true
        $done = [scriptblock]::Create("`$script:Busy['$toolKey'] = `$false; " + $(if ($onDone) { $onDone.ToString() } else { '' }))
        Start-ToolJob -Runspace $rs -Script $sb -ArgList $argList -OnText $script:Append -OnDone $done | Out-Null
    }

    # ================= PerfView wiring =================
    $script:BtnPvInstall.Add_Click({ & $script:Append 'PerfView: install / verify...'; script:Invoke-Action 'Pv' $script:RsPv { $null = Install-PerfView } @() $script:RefreshPv })
    $script:BtnPvStart.Add_Click({
        $p = [string]$script:CmbPvProfile.SelectedItem; $l = $script:TxtPvLabel.Text
        & $script:Append "PerfView: start trace (profile '$p')..."
        script:Invoke-Action 'Pv' $script:RsPv { param($pp,$ll) Start-Trace $pp $ll } @($p, $l) $script:RefreshPv
    })
    $script:BtnPvStop.Add_Click({ & $script:Append 'PerfView: stop trace...'; script:Invoke-Action 'Pv' $script:RsPv { Stop-Trace } @() $script:RefreshPv })
    $script:BtnPvAbort.Add_Click({ & $script:Append 'PerfView: abort...'; script:Invoke-Action 'Pv' $script:RsPv { Stop-Abort } @() $script:RefreshPv })
    $script:BtnPvCollect.Add_Click({
        $p = [string]$script:CmbPvProfile.SelectedItem; $l = $script:TxtPvLabel.Text; $s = 0
        [void][int]::TryParse($script:TxtPvSeconds.Text, [ref]$s); if ($s -lt 1) { $s = 600 }
        & $script:Append "PerfView: timed collect ($s s, profile '$p')..."
        script:Invoke-Action 'Pv' $script:RsPv { param($pp,$ll,$ss) Invoke-CollectTimed $pp $ll $ss } @($p, $l, $s) $script:RefreshPv
    })
    $script:BtnPvOpen.Add_Click({ script:Invoke-Action 'Pv' $script:RsPv { $cfg = Read-Config; if (Test-Path $cfg.OutputDir) { Start-Process explorer.exe $cfg.OutputDir; 'opened output folder' } else { 'output folder does not exist yet' } } @() $null })
    $script:BtnPvStatus.Add_Click({ & $script:RefreshPv })

    # ================= Monitor wiring =================
    $script:BtnMonSave.Add_Click({
        $apps = $script:TxtMonApps.Text; $keep = $script:TxtMonKeep.Text
        & $script:Append 'Monitor: save config...'
        script:Invoke-Action 'Mon' $script:RsMon {
            param($apps,$keep)
            $cfg = Read-Config
            $cfg.Apps = @($apps -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { if ($_ -notlike '*.exe') { "$_.exe" } else { $_ } })
            $k = 0; if ([int]::TryParse("$keep", [ref]$k) -and $k -ge 1) { $cfg.KeepDumps = $k }
            Save-Config $cfg; "saved: apps=$($cfg.Apps -join ', ') keep=$($cfg.KeepDumps)"
        } @($apps, $keep) $script:RefreshMon
    })
    $script:BtnMonInstall.Add_Click({ & $script:Append 'Monitor: install...'; script:Invoke-Action 'Mon' $script:RsMon { Invoke-Install } @() $script:RefreshMon })
    $script:BtnMonStart.Add_Click({ & $script:Append 'Monitor: start...'; script:Invoke-Action 'Mon' $script:RsMon { Start-MonitorTask } @() $script:RefreshMon })
    $script:BtnMonStop.Add_Click({ & $script:Append 'Monitor: stop...'; script:Invoke-Action 'Mon' $script:RsMon { Stop-MonitorTask (Read-Config) } @() $script:RefreshMon })
    $script:BtnMonStatus.Add_Click({ & $script:RefreshMon })
    $script:BtnMonUninstall.Add_Click({ & $script:Append 'Monitor: uninstall...'; script:Invoke-Action 'Mon' $script:RsMon { Invoke-Uninstall } @() $script:RefreshMon })

    # ================= Case wiring =================
    $script:BtnCaseBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Executable (*.exe)|*.exe|All files (*.*)|*.*'
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $script:TxtCaseExe.Text = $dlg.FileName }
    })
    $script:BtnCaseRun.Add_Click({
        $exe = $script:TxtCaseExe.Text
        if (-not $exe -or -not (Test-Path $exe)) { & $script:Append 'Case: enter a valid exe path first.'; return }
        if ($script:Busy['Case']) { & $script:Append 'Case: a capture is already running.'; return }
        $hang = [bool]$script:ChkCaseHang.IsChecked; $fusion = [bool]$script:ChkCaseFusion.IsChecked
        $appcfg = [bool]$script:ChkCaseAppConfig.IsChecked; $to = 0
        [void][int]::TryParse($script:TxtCaseTimeout.Text, [ref]$to); if ($to -lt 1) { $to = 300 }
        $casePath = $script:ToolCasePath
        $script:Busy['Case'] = $true
        $script:LblCaseStatus.Text = 'capturing...'
        & $script:Append "Case: starting capture of $exe ..."
        $rsCase = New-ToolRunspace -ToolPath $casePath   # fresh, not preloaded (Case runs via params)
        $sb = {
            param($casePath, $exe, $hang, $fusion, $appcfg, $to)
            $a = @{ ExePath = $exe; NoElevate = $true; AllowDownload = $true; TimeoutSeconds = [int]$to }
            if ($hang)   { $a.Hang = $true }
            if ($fusion) { $a.FusionLog = $true }
            if ($appcfg) { $a.IncludeAppConfig = $true }
            & $casePath @a
        }
        $done = { $script:Busy['Case'] = $false; $script:LblCaseStatus.Text = 'capture finished'; $script:RsCaseLast.Close() }
        $script:RsCaseLast = $rsCase
        Start-ToolJob -Runspace $rsCase -Script $sb -ArgList @($casePath, $exe, $hang, $fusion, $appcfg, $to) -OnText $script:Append -OnDone $done | Out-Null
    })

    # ---- prefill from config (synchronous; runspaces are idle at startup) ----
    try {
        $ips = [powershell]::Create(); $ips.Runspace = $script:RsPv
        [void]$ips.AddScript('$c = Read-Config; $c.Profiles | ForEach-Object { $_.Name }')
        foreach ($n in $ips.Invoke()) { [void]$script:CmbPvProfile.Items.Add([string]$n) }
        $ips.Dispose()
        if ($script:CmbPvProfile.Items.Count) { $script:CmbPvProfile.SelectedIndex = [Math]::Max(0, $script:CmbPvProfile.Items.IndexOf('Balanced')) }
    } catch { }
    try {
        $ims = [powershell]::Create(); $ims.Runspace = $script:RsMon
        [void]$ims.AddScript('$c = Read-Config; "$($c.Apps -join ', ')|$($c.KeepDumps)"')
        $r = ($ims.Invoke() | Select-Object -First 1) -split '\|'
        $ims.Dispose()
        if ($r.Count -ge 2) { $script:TxtMonApps.Text = $r[0]; $script:TxtMonKeep.Text = $r[1] }
    } catch { }
    & $script:RefreshPv; & $script:RefreshMon

    # ---- output pump (UI thread) ----
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({ Update-ToolJobs; $script:LblBusy.Text = if (Test-ToolJobsBusy) { 'Working...' } else { 'Ready' } })
    $timer.Start()

    $w.Add_Closed({
        $timer.Stop()
        foreach ($rs in @($script:RsPv, $script:RsMon)) { try { $rs.Close() } catch {} }
    })

    [void]$w.ShowDialog()
}
