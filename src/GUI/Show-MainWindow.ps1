<#
    .SYNOPSIS
        Builds and shows the interactive main window. Each tool's actions run in its own background
        runspace (ToolRunspace.ps1); the UI stays responsive and output streams into the Output box.
        PerfView exposes a profile/logging-settings editor; ProcDump Monitor a live config editor.
    .NOTES
        Dot-sourced by ReportingToolkit.ps1 (uses its $ScriptVersion, $script:*Schema and the tool paths).
        Requires an STA desktop session and admin (the GUI self-elevates in ReportingToolkit.ps1).
#>
function Show-MainWindow {
    Add-Type -AssemblyName PresentationFramework, System.Windows.Forms -ErrorAction Stop

    $xaml   = Get-Content -Path $script:MainWindowSchema -Raw
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
    try { $w = [System.Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    Set-WindowThemeResources -window $w -usesDarkMode (Get-SystemUsesDarkMode)
    $script:FgBrush = $w.Resources['AppFgColor']

    foreach ($n in 'TxtOutput','LblBusy','LblVersion',
                   'BtnPvInstall','CmbPvProfile','TxtPvLabel','BtnPvStart','BtnPvStop','BtnPvAbort','TxtPvSeconds','BtnPvCollect','BtnPvOpen','BtnPvStatus','LblPvStatus',
                   'TxtPvProfName','TxtPvKernel','TxtPvClr','TxtPvProviders','TxtPvExtra','TxtPvCircular','TxtPvBuffer','BtnPvProfSave','BtnPvProfDelete','BtnPvProfDefault',
                   'TxtPvOutput','TxtPvSym','ChkPvMerge','ChkPvZip','BtnPvSettingsSave',
                   'BtnMonInstall','BtnMonStart','BtnMonStop','BtnMonStatus','BtnMonUninstall','LblMonStatus','PnlMonConfig','BtnMonSave','BtnMonReload',
                   'TxtCaseExe','BtnCaseBrowse','ChkCaseHang','ChkCaseFusion','ChkCaseAppConfig','TxtCaseTimeout','BtnCaseRun','LblCaseStatus') {
        Set-Variable -Name $n -Scope script -Value $w.FindName($n)
    }
    $script:LblVersion.Text = "v$ScriptVersion"

    $script:RsPv  = New-ToolRunspace -ToolPath $script:ToolPerfViewPath -Load
    $script:RsMon = New-ToolRunspace -ToolPath $script:ToolMonitorPath  -Load
    $script:Busy  = @{ Pv = $false; Mon = $false; Case = $false }
    $script:PvProfiles = @()
    $script:PvLoading  = $false
    $script:MonCtls    = @{}

    $script:Append = {
        param($t)
        if ($null -eq $t -or $t -eq '') { return }
        $script:TxtOutput.AppendText(("{0}  {1}`r`n" -f (Get-Date -Format 'HH:mm:ss'), $t))
        $script:TxtOutput.ScrollToEnd()
    }
    $script:SetPvStatus  = { param($t) $script:LblPvStatus.Text  = $t }
    $script:SetMonStatus = { param($t) $script:LblMonStatus.Text = $t }

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
    $script:RefreshPv  = [scriptblock]::Create("Start-ToolJob -Runspace `$script:RsPv  -Script { $($pvStatusSB.ToString()) }  -OnText `$script:SetPvStatus  | Out-Null")
    $script:RefreshMon = [scriptblock]::Create("Start-ToolJob -Runspace `$script:RsMon -Script { $($monStatusSB.ToString()) } -OnText `$script:SetMonStatus | Out-Null")

    function script:Invoke-Action($toolKey, $rs, [scriptblock]$sb, [object[]]$argList, [scriptblock]$onDone) {
        if ($script:Busy[$toolKey]) { & $script:Append 'Busy - wait for the current action to finish.'; return }
        $script:Busy[$toolKey] = $true
        $done = [scriptblock]::Create("`$script:Busy['$toolKey'] = `$false; " + $(if ($onDone) { $onDone.ToString() } else { '' }))
        Start-ToolJob -Runspace $rs -Script $sb -ArgList $argList -OnText $script:Append -OnDone $done | Out-Null
    }

    # ---------- PerfView: profile / settings editor ----------
    function script:Load-PvProfileFields([string]$name) {
        $p = $script:PvProfiles | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
        if (-not $p) { return }
        $script:TxtPvProfName.Text  = [string]$p.Name
        $script:TxtPvKernel.Text    = [string]$p.KernelEvents
        $script:TxtPvClr.Text       = [string]$p.ClrEvents
        $script:TxtPvProviders.Text = [string]$p.Providers
        $script:TxtPvExtra.Text     = [string]$p.ExtraArgs
        $script:TxtPvCircular.Text  = "$($p.CircularMB)"
        $script:TxtPvBuffer.Text    = "$($p.BufferSizeMB)"
    }
    function script:Load-PvAll {
        if ($script:Busy['Pv']) { return }
        $c = Invoke-ToolSync -Runspace $script:RsPv -Script { Read-Config } | Select-Object -First 1
        if (-not $c) { return }
        $script:PvProfiles = @($c.Profiles)
        $script:PvLoading = $true
        $script:CmbPvProfile.Items.Clear()
        foreach ($p in $script:PvProfiles) { [void]$script:CmbPvProfile.Items.Add([string]$p.Name) }
        $idx = $script:CmbPvProfile.Items.IndexOf([string]$c.DefaultProfile); if ($idx -lt 0) { $idx = 0 }
        if ($script:CmbPvProfile.Items.Count) { $script:CmbPvProfile.SelectedIndex = $idx }
        $script:PvLoading = $false
        $script:TxtPvOutput.Text = [string]$c.OutputDir
        $script:TxtPvSym.Text    = [string]$c.SymbolPath
        $script:ChkPvMerge.IsChecked = [bool]$c.Merge
        $script:ChkPvZip.IsChecked   = [bool]$c.Zip
        script:Load-PvProfileFields ([string]$script:CmbPvProfile.SelectedItem)
    }

    $script:CmbPvProfile.Add_SelectionChanged({ if (-not $script:PvLoading) { script:Load-PvProfileFields ([string]$script:CmbPvProfile.SelectedItem) } })

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

    $reloadPv = { script:Load-PvAll }
    $script:BtnPvProfSave.Add_Click({
        $vals = @($script:TxtPvProfName.Text, $script:TxtPvKernel.Text, $script:TxtPvClr.Text, $script:TxtPvProviders.Text, $script:TxtPvExtra.Text, $script:TxtPvCircular.Text, $script:TxtPvBuffer.Text)
        if (-not $vals[0]) { & $script:Append 'Enter a profile name first.'; return }
        & $script:Append "PerfView: save profile '$($vals[0])'..."
        script:Invoke-Action 'Pv' $script:RsPv {
            param($name,$kernel,$clr,$prov,$extra,$circ,$buf)
            $cfg = Read-Config
            $p = $cfg.Profiles | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
            if (-not $p) {
                $p = [pscustomobject]@{ Name=$name; Description=''; KernelEvents=''; ClrEvents=''; Providers=''; CircularMB=2048; BufferSizeMB=1024; ExtraArgs='' }
                $cfg.Profiles = @($cfg.Profiles) + $p
            }
            $p.Name = $name; $p.KernelEvents = $kernel; $p.ClrEvents = $clr; $p.Providers = $prov; $p.ExtraArgs = $extra
            $ci = 0; if ([int]::TryParse("$circ", [ref]$ci) -and $ci -ge 0) { $p.CircularMB = $ci }
            $bi = 0; if ([int]::TryParse("$buf", [ref]$bi) -and $bi -ge 1) { $p.BufferSizeMB = $bi }
            Save-Config $cfg; "profile '$name' saved"
        } $vals $reloadPv
    })
    $script:BtnPvProfDelete.Add_Click({
        $name = [string]$script:CmbPvProfile.SelectedItem
        if (-not $name) { return }
        & $script:Append "PerfView: delete profile '$name'..."
        script:Invoke-Action 'Pv' $script:RsPv {
            param($name)
            $cfg = Read-Config
            $cfg.Profiles = @($cfg.Profiles | Where-Object { $_.Name -ine $name })
            if ($cfg.DefaultProfile -ieq $name -and $cfg.Profiles) { $cfg.DefaultProfile = $cfg.Profiles[0].Name }
            Save-Config $cfg; "profile '$name' deleted"
        } @($name) $reloadPv
    })
    $script:BtnPvProfDefault.Add_Click({
        $name = [string]$script:CmbPvProfile.SelectedItem
        if (-not $name) { return }
        & $script:Append "PerfView: set default profile '$name'..."
        script:Invoke-Action 'Pv' $script:RsPv { param($name) $cfg = Read-Config; $cfg.DefaultProfile = $name; Save-Config $cfg; "default profile = $name" } @($name) $reloadPv
    })
    $script:BtnPvSettingsSave.Add_Click({
        $vals = @($script:TxtPvOutput.Text, $script:TxtPvSym.Text, $(if ($script:ChkPvMerge.IsChecked) { 'true' } else { 'false' }), $(if ($script:ChkPvZip.IsChecked) { 'true' } else { 'false' }))
        & $script:Append 'PerfView: save settings...'
        script:Invoke-Action 'Pv' $script:RsPv {
            param($out,$sym,$merge,$zip)
            $cfg = Read-Config; $cfg.OutputDir = $out; $cfg.SymbolPath = $sym
            $cfg.Merge = ($merge -eq 'true'); $cfg.Zip = ($zip -eq 'true')
            Save-Config $cfg; "settings saved (output: $out)"
        } $vals $script:RefreshPv
    })

    # ---------- Monitor: live config editor ----------
    function script:New-ConfigRow($name, $value) {
        $row = New-Object System.Windows.Controls.DockPanel; $row.Margin = '0,0,0,6'
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = $name; $lbl.Width = 180; $lbl.VerticalAlignment = 'Center'; $lbl.Foreground = $script:FgBrush
        [System.Windows.Controls.DockPanel]::SetDock($lbl, 'Left')
        [void]$row.Children.Add($lbl)
        if ($value -is [bool]) {
            $ctl = New-Object System.Windows.Controls.CheckBox; $ctl.IsChecked = [bool]$value; $ctl.VerticalAlignment = 'Center'
        } else {
            $ctl = New-Object System.Windows.Controls.TextBox
            $ctl.Text = if ($value -is [System.Array]) { ($value -join ', ') } else { "$value" }
        }
        [void]$row.Children.Add($ctl)
        return @{ Row = $row; Ctl = $ctl }
    }
    function script:Build-MonEditor {
        if ($script:Busy['Mon']) { & $script:Append 'Monitor busy - cannot reload config now.'; return }
        $cfg = Invoke-ToolSync -Runspace $script:RsMon -Script { Read-Config } | Select-Object -First 1
        if (-not $cfg) { return }
        $script:PnlMonConfig.Children.Clear(); $script:MonCtls = @{}
        foreach ($prop in $cfg.PSObject.Properties) {
            $r = script:New-ConfigRow $prop.Name $prop.Value
            [void]$script:PnlMonConfig.Children.Add($r.Row)
            $script:MonCtls[$prop.Name] = $r.Ctl
        }
    }

    $script:BtnMonInstall.Add_Click({ & $script:Append 'Monitor: install...'; script:Invoke-Action 'Mon' $script:RsMon { Invoke-Install } @() $script:RefreshMon })
    $script:BtnMonStart.Add_Click({ & $script:Append 'Monitor: start...'; script:Invoke-Action 'Mon' $script:RsMon { Start-MonitorTask } @() $script:RefreshMon })
    $script:BtnMonStop.Add_Click({ & $script:Append 'Monitor: stop...'; script:Invoke-Action 'Mon' $script:RsMon { Stop-MonitorTask (Read-Config) } @() $script:RefreshMon })
    $script:BtnMonStatus.Add_Click({ & $script:RefreshMon })
    $script:BtnMonUninstall.Add_Click({ & $script:Append 'Monitor: uninstall...'; script:Invoke-Action 'Mon' $script:RsMon { Invoke-Uninstall } @() $script:RefreshMon })
    $script:BtnMonReload.Add_Click({ & $script:Append 'Monitor: reload config'; script:Build-MonEditor })
    $script:BtnMonSave.Add_Click({
        if ($script:MonCtls.Count -eq 0) { return }
        $kv = @{}
        foreach ($k in $script:MonCtls.Keys) {
            $c = $script:MonCtls[$k]
            $kv[$k] = if ($c -is [System.Windows.Controls.CheckBox]) { if ($c.IsChecked) { 'true' } else { 'false' } } else { $c.Text }
        }
        & $script:Append 'Monitor: save config...'
        $doneMon = { script:Build-MonEditor; & $script:RefreshMon }
        script:Invoke-Action 'Mon' $script:RsMon {
            param($kv)
            $cfg = Read-Config
            foreach ($k in $kv.Keys) {
                if (-not $cfg.PSObject.Properties[$k]) { continue }
                $cur = $cfg.$k
                if ($cur -is [bool]) { $cfg.$k = ($kv[$k] -match '^(1|true|y|yes)$') }
                elseif ($cur -is [int] -or $cur -is [long]) { $n = 0; if ([int]::TryParse("$($kv[$k])", [ref]$n)) { $cfg.$k = $n } }
                elseif ($cur -is [System.Array]) { $cfg.$k = @($kv[$k] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
                else { $cfg.$k = $kv[$k] }
            }
            Save-Config $cfg; 'config saved'
        } @($kv) $doneMon
    })

    # ---------- Case ----------
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
        $script:RsCaseLast = New-ToolRunspace -ToolPath $casePath
        $sb = {
            param($casePath, $exe, $hang, $fusion, $appcfg, $to)
            $a = @{ ExePath = $exe; NoElevate = $true; AllowDownload = $true; TimeoutSeconds = [int]$to }
            if ($hang)   { $a.Hang = $true }
            if ($fusion) { $a.FusionLog = $true }
            if ($appcfg) { $a.IncludeAppConfig = $true }
            & $casePath @a
        }
        $done = { $script:Busy['Case'] = $false; $script:LblCaseStatus.Text = 'capture finished'; try { $script:RsCaseLast.Close() } catch {} }
        Start-ToolJob -Runspace $script:RsCaseLast -Script $sb -ArgList @($casePath, $exe, $hang, $fusion, $appcfg, $to) -OnText $script:Append -OnDone $done | Out-Null
    })

    # ---------- initial load ----------
    try { script:Load-PvAll } catch { & $script:Append "PerfView config load failed: $($_.Exception.Message)" }
    try { script:Build-MonEditor } catch { & $script:Append "Monitor config load failed: $($_.Exception.Message)" }
    & $script:RefreshPv; & $script:RefreshMon

    # ---------- output pump ----------
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
