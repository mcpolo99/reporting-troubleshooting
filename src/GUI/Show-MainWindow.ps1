# Builds and shows the main window; each tool's actions run in its own background runspace.
function Show-MainWindow {
    Add-Type -AssemblyName PresentationFramework, System.Windows.Forms -ErrorAction Stop

    # Force software rendering. On clean/VM/RDP/low-desktop-heap machines WPF's hardware composition
    # render target fails to allocate (HwndTarget.UpdateWindowSettings throws Win32 1816 "Not enough
    # quota is available to process this command" on the WM_WINDOWPOSCHANGED messages during show),
    # spamming the recovery handler. A diagnostic GUI gains nothing from GPU accel, so take it off the
    # table. Must be set before the window's HwndTarget is created (i.e. before XamlReader.Load/ShowDialog).
    try { [System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly } catch {}

    $xaml   = Get-Content -Path $script:MainWindowSchema -Raw
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
    try { $w = [System.Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    Set-WindowThemeResources -window $w -usesDarkMode (Get-SystemUsesDarkMode)
    $script:FgBrush  = $w.Resources['AppFgColor']
    $script:IdBrush  = $w.Resources['AppIdColor']
    $script:ChipBg   = $w.Resources['CardHoverColor']

    foreach ($n in 'TxtOutput','LblBusy','LblVersion',
                   'CmbPvProfile','TxtPvLabel','BtnPvStart','BtnPvStop','BtnPvAbort','TxtPvSeconds','BtnPvCollect','BtnPvOpen','BtnPvStatus','LblPvStatus',
                   'TxtPvProfName','PnlPvKernel','CmbPvClr','PnlPvProviders','TxtPvProvOther','TxtPvExtra','TxtPvCircular','TxtPvBuffer','BtnPvProfSave','BtnPvProfDelete','BtnPvProfDefault',
                   'TxtPvOutput','TxtPvSym','ChkPvMerge','ChkPvZip','BtnPvSettingsSave',
                   'BtnMonInstall','BtnMonStart','BtnMonStop','BtnMonStatus','BtnMonUninstall','LblMonStatus','PnlMonConfig','BtnMonSave','BtnMonReload','ChkMonTail','TxtMonLog',
                   'TxtCaseExe','BtnCaseBrowse','CmbCaseMode','ChkCaseFusion','ChkCaseAppConfig','TxtCaseTimeout','BtnCaseRun','LblCaseStatus',
                   'BtnPkgInstallAll','BtnPkgRefresh','BtnPkgOpen','PnlPackages','LblPkgStatus',
                   'BtnShortcut') {
        Set-Variable -Name $n -Scope script -Value $w.FindName($n)
    }
    $script:LblVersion.Text = "v$ScriptVersion"

    $script:RsPv  = New-ToolRunspace -ToolPath $script:ToolPerfViewPath -Load
    $script:RsMon = New-ToolRunspace -ToolPath $script:ToolMonitorPath  -Load
    $script:RsPkg = New-ToolRunspace -ToolPath $script:ToolPackagesPath -Load
    $script:Busy  = @{ Pv = $false; Mon = $false; Case = $false; Pkg = $false }
    $script:PvProfiles = @()
    $script:PvLoading  = $false
    $script:MonCtls    = @{}

    # known PerfView toggles (rendered as checkboxes / dropdown instead of free text)
    $script:PvKernelKeywords  = @('Default','ThreadTime','FileIOInit','FileIO','DiskIO','MemoryHardFaults','VirtualAlloc','NetworkTCPIP','Registry','ImageLoad')
    $script:PvProviderPresets = @('Microsoft-Windows-Kernel-Memory','Microsoft-Windows-TCPIP')
    $script:PvClrPresets      = @('Default','None','Verbose')
    # dropdown options for Monitor config fields (anything not listed falls back to checkbox/text by type)
    $script:MonFieldMeta = @{ DuplicateAction = @('Delete','Keep'); RunMode = @('Logon','Startup') }

    # PerfView safety: an ETW session started with 'PerfView start' keeps running after PerfView.exe exits,
    # so if this app closes/crashes mid-trace we must abort the session. These OS/file paths let us do that
    # without the runspace (which may be gone on a crash). active.json presence = a trace is live.
    $script:PvExe        = Join-Path $env:ProgramData 'ReportingTroubleshooting\Packages\perfview\PerfView.exe'
    $script:PvActiveFile = Join-Path $env:ProgramData 'ReportingTroubleshooting\PerfView\active.json'
    $script:PvSession    = 'PerfViewCapture'
    function script:Stop-PerfViewHard {
        if (-not (Test-Path $script:PvActiveFile)) { return }   # no live trace; also prevents double-abort
        try {
            if (Test-Path $script:PvExe) {
                Start-Process -FilePath $script:PvExe -ArgumentList '/AcceptEULA', "/SessionName:$($script:PvSession)", 'abort' -NoNewWindow -Wait -ErrorAction SilentlyContinue
            }
        } catch {}
        Remove-Item $script:PvActiveFile -Force -ErrorAction SilentlyContinue
    }

    # live tail of the background monitor's newest log
    $script:MonLogDir = Join-Path $env:ProgramData 'ReportingTroubleshooting\Monitor\Logs'
    $script:MonLogCur = ''; $script:MonLogLen = -1; $script:TailCounter = 0
    function script:Update-MonTail {
        if (-not $script:ChkMonTail.IsChecked) { return }
        try {
            $f = Get-ChildItem $script:MonLogDir -Filter 'ProcDumpMonitor_*.log' -File -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $f) { return }
            if ($f.FullName -eq $script:MonLogCur -and $f.Length -eq $script:MonLogLen) { return }
            $script:MonLogCur = $f.FullName; $script:MonLogLen = $f.Length
            $lines = Get-Content -LiteralPath $f.FullName -Tail 40 -ErrorAction SilentlyContinue
            $script:TxtMonLog.Text = ($lines -join "`r`n")
            $script:TxtMonLog.ScrollToEnd()
        } catch {}
    }

    function script:Build-PvToggles {
        $script:PvKernelChecks = [ordered]@{}
        foreach ($k in $script:PvKernelKeywords) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content = $k; $cb.Margin = '0,0,12,4'; $cb.Foreground = $script:FgBrush
            [void]$script:PnlPvKernel.Children.Add($cb); $script:PvKernelChecks[$k] = $cb
        }
        $script:PvProviderChecks = [ordered]@{}
        foreach ($p in $script:PvProviderPresets) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content = $p; $cb.Margin = '0,0,12,4'; $cb.Foreground = $script:FgBrush
            [void]$script:PnlPvProviders.Children.Add($cb); $script:PvProviderChecks[$p] = $cb
        }
        foreach ($c in $script:PvClrPresets) { [void]$script:CmbPvClr.Items.Add($c) }
    }

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
        $script:TxtPvProfName.Text = [string]$p.Name
        $kset = @(($p.KernelEvents -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        foreach ($k in $script:PvKernelKeywords) { $script:PvKernelChecks[$k].IsChecked = ($kset -contains $k) }
        $script:CmbPvClr.Text = [string]$p.ClrEvents
        $pset = @(($p.Providers -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        foreach ($pr in $script:PvProviderPresets) { $script:PvProviderChecks[$pr].IsChecked = ($pset -contains $pr) }
        $script:TxtPvProvOther.Text = (@($pset | Where-Object { $script:PvProviderPresets -notcontains $_ }) -join ', ')
        $script:TxtPvExtra.Text    = [string]$p.ExtraArgs
        $script:TxtPvCircular.Text = "$($p.CircularMB)"
        $script:TxtPvBuffer.Text   = "$($p.BufferSizeMB)"
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
        $kernel = (@($script:PvKernelKeywords | Where-Object { $script:PvKernelChecks[$_].IsChecked }) -join ',')
        $provChecked = @($script:PvProviderPresets | Where-Object { $script:PvProviderChecks[$_].IsChecked })
        $provOther   = @(($script:TxtPvProvOther.Text -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $providers = (@($provChecked + $provOther) -join ',')
        $vals = @($script:TxtPvProfName.Text, $kernel, $script:CmbPvClr.Text, $providers, $script:TxtPvExtra.Text, $script:TxtPvCircular.Text, $script:TxtPvBuffer.Text)
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
    # Restrict a TextBox to non-negative integers (typing, space and paste all filtered).
    function script:Set-NumericOnly($tb) {
        $tb.Add_PreviewTextInput({ param($s, $e) if ($e.Text -match '\D') { $e.Handled = $true } })
        $tb.Add_PreviewKeyDown({ param($s, $e) if ($e.Key -eq [System.Windows.Input.Key]::Space) { $e.Handled = $true } })
        [System.Windows.DataObject]::AddPastingHandler($tb, {
            param($s, $e)
            $t = [string]$e.DataObject.GetData([System.Windows.DataFormats]::Text)
            if ($t -match '\D') { $e.CancelCommand() }
        })
    }

    # Chip/tag editor (like mail recipients): type a value, Enter locks it as a removable chip and clears
    # the box for the next one; Backspace on an empty box removes the last chip. Returns the panel + a getter.
    function script:New-TagEditor($values) {
        # Capture the theme brushes as locals: inside the GetNewClosure blocks below, $script:* rebinds to the
        # closure's own (empty) scope, so the chips would get null brushes and render invisibly.
        $fg = $script:FgBrush; $chipBg = $script:ChipBg
        $wrap = New-Object System.Windows.Controls.WrapPanel
        $wrap.HorizontalAlignment = 'Left'

        $tb = New-Object System.Windows.Controls.TextBox
        $tb.MinWidth = 120; $tb.Margin = '2'; $tb.VerticalAlignment = 'Center'
        $tb.BorderThickness = New-Object System.Windows.Thickness(0)
        $tb.Background = [System.Windows.Media.Brushes]::Transparent
        $tb.Foreground = $fg

        $makeChip = {
            param($text)
            $text = "$text".Trim()
            if (-not $text) { return }
            $chip = New-Object System.Windows.Controls.Border
            $chip.Background = $chipBg; $chip.CornerRadius = New-Object System.Windows.CornerRadius(3)
            $chip.Margin = '0,2,4,2'; $chip.Padding = '6,1,3,1'; $chip.Tag = $text
            $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
            $lbl = New-Object System.Windows.Controls.TextBlock
            $lbl.Text = $text; $lbl.Foreground = $fg; $lbl.VerticalAlignment = 'Center'
            $btn = New-Object System.Windows.Controls.Button
            $btn.Content = [char]0x00D7; $btn.Margin = '4,0,0,0'; $btn.Padding = '3,0,3,0'
            $btn.BorderThickness = New-Object System.Windows.Thickness(0); $btn.FontWeight = 'Bold'
            $btn.Background = [System.Windows.Media.Brushes]::Transparent; $btn.Foreground = $fg
            $btn.Cursor = [System.Windows.Input.Cursors]::Hand; $btn.ToolTip = 'Remove'
            # Remove via the visual tree (Button -> StackPanel -> Border chip -> WrapPanel), NOT a captured
            # $wrap: this handler is nested inside the $makeChip closure, where GetNewClosure does not capture
            # $wrap, so a captured reference is null on click ("cannot call a method on a null-valued expression").
            $btn.Add_Click({
                param($sender, $e)
                $theChip = $sender.Parent.Parent          # StackPanel -> Border
                $panel = if ($theChip) { $theChip.Parent } else { $null }   # WrapPanel
                if ($panel) { [void]$panel.Children.Remove($theChip) }
            })
            [void]$sp.Children.Add($lbl); [void]$sp.Children.Add($btn); $chip.Child = $sp
            $idx = $wrap.Children.IndexOf($tb); if ($idx -lt 0) { $idx = $wrap.Children.Count }
            $wrap.Children.Insert($idx, $chip)
        }.GetNewClosure()

        $commit = { if ("$($tb.Text)".Trim()) { & $makeChip $tb.Text; $tb.Clear() } }.GetNewClosure()

        $tb.Add_PreviewKeyDown({
            param($s, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Return) { & $commit; $e.Handled = $true }
            elseif ($e.Key -eq [System.Windows.Input.Key]::Back -and [string]::IsNullOrEmpty($s.Text)) {
                $i = $wrap.Children.IndexOf($tb); if ($i -gt 0) { $wrap.Children.RemoveAt($i - 1) }
            }
        }.GetNewClosure())
        $tb.Add_LostFocus({ & $commit }.GetNewClosure())

        foreach ($v in @($values)) { & $makeChip $v }
        [void]$wrap.Children.Add($tb)

        # Emit $vals (NOT ,$vals): the caller wraps with @(& $c.Tag), and the comma idiom would double-nest
        # into a single array element that -join stringifies to "System.Object[]".
        $getter = {
            $vals = @()
            foreach ($c in $wrap.Children) { if ($c -is [System.Windows.Controls.Border]) { $vals += [string]$c.Tag } }
            if ("$($tb.Text)".Trim()) { $vals += "$($tb.Text)".Trim() }
            $vals
        }.GetNewClosure()

        return @{ Panel = $wrap; Getter = $getter }
    }

    function script:New-ConfigRow($name, $value, $options) {
        $row = New-Object System.Windows.Controls.DockPanel; $row.Margin = '0,0,0,6'
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = $name; $lbl.Width = 180; $lbl.VerticalAlignment = 'Center'; $lbl.Foreground = $script:FgBrush
        [System.Windows.Controls.DockPanel]::SetDock($lbl, 'Left')
        [void]$row.Children.Add($lbl)
        if ($options) {
            $ctl = New-Object System.Windows.Controls.ComboBox; $ctl.Width = 200; $ctl.HorizontalAlignment = 'Left'
            foreach ($o in $options) { [void]$ctl.Items.Add($o) }
            $ctl.SelectedItem = "$value"; if ($ctl.SelectedIndex -lt 0) { $ctl.IsEditable = $true; $ctl.Text = "$value" }
        } elseif ($value -is [bool]) {
            $ctl = New-Object System.Windows.Controls.CheckBox; $ctl.IsChecked = [bool]$value; $ctl.VerticalAlignment = 'Center'
        } elseif ($value -is [System.Array]) {
            $te = script:New-TagEditor $value
            $ctl = $te.Panel; $ctl.Tag = $te.Getter        # getter read back in BtnMonSave
        } elseif ($value -is [int] -or $value -is [long]) {
            $ctl = New-Object System.Windows.Controls.TextBox
            $ctl.Width = 200; $ctl.HorizontalAlignment = 'Left'; $ctl.Text = "$value"
            script:Set-NumericOnly $ctl
        } else {
            $ctl = New-Object System.Windows.Controls.TextBox
            $ctl.Text = "$value"
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
            $r = script:New-ConfigRow $prop.Name $prop.Value $script:MonFieldMeta[$prop.Name]
            [void]$script:PnlMonConfig.Children.Add($r.Row)
            $script:MonCtls[$prop.Name] = $r.Ctl
        }
    }

    $script:BtnMonInstall.Add_Click({ & $script:Append 'Monitor: install...'; script:Invoke-Action 'Mon' $script:RsMon { Invoke-Install } @() $script:RefreshMon })
    $script:BtnMonStart.Add_Click({ & $script:Append 'Monitor: start... (live attach/dump activity shows in the "Monitor log (live)" panel below)'; script:Invoke-Action 'Mon' $script:RsMon { Start-MonitorTask } @() $script:RefreshMon })
    $script:BtnMonStop.Add_Click({ & $script:Append 'Monitor: stop...'; script:Invoke-Action 'Mon' $script:RsMon { Stop-MonitorTask (Read-Config) } @() $script:RefreshMon })
    $script:BtnMonStatus.Add_Click({ & $script:RefreshMon })
    $script:BtnMonUninstall.Add_Click({ & $script:Append 'Monitor: uninstall...'; script:Invoke-Action 'Mon' $script:RsMon { Invoke-Uninstall } @() $script:RefreshMon })
    $script:BtnMonReload.Add_Click({ & $script:Append 'Monitor: reload config'; script:Build-MonEditor })
    $script:BtnMonSave.Add_Click({
        if ($script:MonCtls.Count -eq 0) { return }
        $kv = @{}
        foreach ($k in $script:MonCtls.Keys) {
            $c = $script:MonCtls[$k]
            $kv[$k] = if ($c -is [System.Windows.Controls.CheckBox]) { if ($c.IsChecked) { 'true' } else { 'false' } }
                      elseif ($c -is [System.Windows.Controls.ComboBox]) { if ($null -ne $c.SelectedItem) { [string]$c.SelectedItem } else { [string]$c.Text } }
                      elseif ($c -is [System.Windows.Controls.WrapPanel]) { (@(& $c.Tag) -join ',') }   # tag editor -> array split in the tool
                      else { $c.Text }
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

    # ---------- Packages: one shared, verified tool store ----------
    function script:Install-Pkg([string]$Id, [bool]$Force) {
        if ($script:Busy['Pkg']) { & $script:Append 'Packages: an install is already running.'; return }
        $script:Busy['Pkg'] = $true
        $script:LblPkgStatus.Text = "Installing $Id..."
        & $script:Append "Packages: install '$Id'$(if ($Force) { ' (reinstall)' } else { '' })..."
        $done = { $script:Busy['Pkg'] = $false; $script:LblPkgStatus.Text = 'Done.'; script:Build-PkgEditor }
        Start-ToolJob -Runspace $script:RsPkg -Script { param($i, $f) if ($f) { Install-Package $i -Force | Out-Null } else { Install-Package $i | Out-Null } } -ArgList @($Id, $Force) -OnText $script:Append -OnDone $done | Out-Null
    }
    function script:Build-PkgEditor {
        if ($script:Busy['Pkg']) { & $script:Append 'Packages busy - cannot refresh now.'; return }
        $stat = Invoke-ToolSync -Runspace $script:RsPkg -Script { Get-PackageRegistry | ForEach-Object { Get-PackageStatus $_.Id } }
        $script:PnlPackages.Children.Clear()
        foreach ($s in @($stat)) {
            $card = New-Object System.Windows.Controls.Border
            $card.Background = $script:ChipBg; $card.CornerRadius = New-Object System.Windows.CornerRadius(4)
            $card.Padding = '10,8,10,8'; $card.Margin = '0,0,0,8'
            $row = New-Object System.Windows.Controls.DockPanel

            $btn = New-Object System.Windows.Controls.Button
            $btn.Content = if ($s.Installed) { 'Reinstall' } else { 'Install' }
            $btn.Height = 28; $btn.MinWidth = 90; $btn.VerticalAlignment = 'Center'; $btn.Margin = '8,0,0,0'
            [System.Windows.Controls.DockPanel]::SetDock($btn, 'Right')
            # Per-row data on the control + a plain (non-closure) handler: a GetNewClosure handler rebinds the
            # script: scope and can't resolve script:Install-Pkg, which crashes ShowDialog.
            $btn.Tag = @{ Id = [string]$s.Id; Force = [bool]$s.Installed }
            $btn.Add_Click({ param($sender, $e) script:Install-Pkg $sender.Tag.Id $sender.Tag.Force })
            [void]$row.Children.Add($btn)

            $info = New-Object System.Windows.Controls.StackPanel
            $t1 = New-Object System.Windows.Controls.TextBlock
            $t1.Text = [string]$s.Name; $t1.FontWeight = 'SemiBold'; $t1.Foreground = $script:FgBrush
            $t2 = New-Object System.Windows.Controls.TextBlock
            $t2.Text = [string]$s.Description; $t2.Foreground = $script:IdBrush; $t2.TextWrapping = 'Wrap'
            $t3 = New-Object System.Windows.Controls.TextBlock
            $t3.Foreground = $script:IdBrush; $t3.Margin = '0,2,0,0'
            $t3.Text = if ($s.Installed) { "Installed - $($s.ToolCount) tool(s)" } else { 'Not installed' }
            [void]$info.Children.Add($t1); [void]$info.Children.Add($t2); [void]$info.Children.Add($t3)
            [void]$row.Children.Add($info)

            $card.Child = $row
            [void]$script:PnlPackages.Children.Add($card)
        }
    }
    $script:BtnPkgInstallAll.Add_Click({
        if ($script:Busy['Pkg']) { & $script:Append 'Packages: an install is already running.'; return }
        $script:Busy['Pkg'] = $true; $script:LblPkgStatus.Text = 'Installing all...'
        & $script:Append 'Packages: install / verify all...'
        $done = { $script:Busy['Pkg'] = $false; $script:LblPkgStatus.Text = 'Done.'; script:Build-PkgEditor }
        Start-ToolJob -Runspace $script:RsPkg -Script { Install-AllPackages | Out-Null } -OnText $script:Append -OnDone $done | Out-Null
    })
    $script:BtnPkgRefresh.Add_Click({ script:Build-PkgEditor })
    $script:BtnPkgOpen.Add_Click({
        Start-ToolJob -Runspace $script:RsPkg -Script { $d = Get-PackageRoot; New-Item -ItemType Directory -Path $d -Force | Out-Null; Start-Process explorer.exe $d; "opened $d" } -OnText $script:Append | Out-Null
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
        $mode = switch ($script:CmbCaseMode.SelectedIndex) { 1 { 'crash' } 2 { 'hang' } 3 { 'exit' } default { 'auto' } }
        $fusion = [bool]$script:ChkCaseFusion.IsChecked
        $appcfg = [bool]$script:ChkCaseAppConfig.IsChecked; $to = 0
        [void][int]::TryParse($script:TxtCaseTimeout.Text, [ref]$to); if ($to -lt 1) { $to = 300 }
        $casePath = $script:ToolCasePath
        $script:Busy['Case'] = $true
        $script:LblCaseStatus.Text = 'capturing...'
        & $script:Append "Case: starting capture of $exe (mode: $mode) ..."
        $script:RsCaseLast = New-ToolRunspace -ToolPath $casePath
        $sb = {
            param($casePath, $exe, $mode, $fusion, $appcfg, $to)
            $a = @{ ExePath = $exe; NoElevate = $true; AllowDownload = $true; TimeoutSeconds = [int]$to }
            switch ($mode) {
                'crash' { $a.Unhandled  = $true }
                'hang'  { $a.Hang       = $true }
                'exit'  { $a.DumpOnExit = $true }
                default { $a.Auto       = $true }
            }
            if ($fusion) { $a.FusionLog = $true }
            if ($appcfg) { $a.IncludeAppConfig = $true }
            & $casePath @a
        }
        $done = { $script:Busy['Case'] = $false; $script:LblCaseStatus.Text = 'capture finished'; try { $script:RsCaseLast.Close() } catch {} }
        Start-ToolJob -Runspace $script:RsCaseLast -Script $sb -ArgList @($casePath, $exe, $mode, $fusion, $appcfg, $to) -OnText $script:Append -OnDone $done | Out-Null
    })

    # ---------- desktop shortcut ----------
    $script:BtnShortcut.Add_Click({
        try {
            $lnk = Install-DesktopShortcut -TargetBat (Join-Path $script:ToolkitRoot 'run.bat')
            & $script:Append "Desktop shortcut created: $lnk"
        } catch { & $script:Append "Shortcut install failed: $($_.Exception.Message)" }
    })

    # ---------- initial load ----------
    foreach ($nTb in @($script:TxtPvSeconds, $script:TxtPvCircular, $script:TxtPvBuffer, $script:TxtCaseTimeout)) { script:Set-NumericOnly $nTb }
    script:Build-PvToggles
    # crash recovery: a trace left active by a previous (crashed/killed) session is aborted now
    if (Test-Path $script:PvActiveFile) { & $script:Append 'Found an orphaned PerfView trace from a previous session - aborting it.'; script:Stop-PerfViewHard }
    try { script:Load-PvAll } catch { & $script:Append "PerfView config load failed: $($_.Exception.Message)" }
    try { script:Build-MonEditor } catch { & $script:Append "Monitor config load failed: $($_.Exception.Message)" }
    try { script:Build-PkgEditor } catch { & $script:Append "Package status load failed: $($_.Exception.Message)" }
    & $script:RefreshPv; & $script:RefreshMon

    # Last-resort guard: a stray exception on the UI thread (a bad event handler) must not kill the window.
    # Show it in the output, write the full detail to a log, and keep the app alive.
    $w.Dispatcher.add_UnhandledException({
        param($src, $de)
        try {
            $ex  = $de.Exception
            $txt = "$ex"
            # Known-harmless and self-recovering: WPF cannot (re)create the composition render target during
            # the window's show/resize messages on a constrained desktop (Win32 1816 "Not enough quota",
            # thrown from HwndTarget.UpdateWindowSettings). The window still opens and works; SoftwareOnly
            # doesn't avoid it because the DUCE/DWM channel is the limited resource. Note it ONCE as a benign
            # warning and never write a stack file for it - it is not an app fault.
            $benignRender = ($ex -is [System.ComponentModel.Win32Exception] -or $txt -match 'Win32Exception') -and
                            ($txt -match 'HwndTarget\.UpdateWindowSettings' -or $txt -match 'Not enough quota')
            if ($benignRender) {
                if (-not $script:RenderWarnShown) {
                    $script:RenderWarnShown = $true
                    & $script:Append 'Note: a harmless display-render warning occurred on first show (recovered); the window works normally.'
                }
                $de.Handled = $true; return
            }
            # Collapse identical consecutive recoveries so one transient fault doesn't flood the output.
            $msg = "$($ex.Message)"
            if ($msg -ne $script:LastUiError) {
                $script:LastUiError = $msg
                & $script:Append "UI error (recovered): $msg"
            }
            $logDir = Join-Path $env:ProgramData 'ReportingTroubleshooting\Logs'
            New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
            $txt | Set-Content -LiteralPath (Join-Path $logDir ('ui_error_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))) -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch {}
        $de.Handled = $true
    })

    # ---------- output pump + log tail ----------
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        try {
            Update-ToolJobs
            $script:LblBusy.Text = if (Test-ToolJobsBusy) { 'Working...' } else { 'Ready' }
            $script:TailCounter++
            if ($script:TailCounter % 5 -eq 0) { script:Update-MonTail }   # ~1s cadence
        } catch { & $script:Append "Timer error: $($_.Exception.Message)" }
    })
    $timer.Start()

    # ---------- terminate an active PerfView trace on close / crash ----------
    # Graceful close saves the trace (Stop-Trace); a crash aborts it (Stop-PerfViewHard). A hard kill that
    # bypasses these is recovered on next startup (orphan cleanup above). active.json is the live-trace flag.
    [System.AppDomain]::CurrentDomain.add_UnhandledException({ script:Stop-PerfViewHard })
    [System.AppDomain]::CurrentDomain.add_ProcessExit({ script:Stop-PerfViewHard })

    $w.Add_Closed({
        $timer.Stop()
        try {
            if (Test-Path $script:PvActiveFile) {
                if (-not $script:Busy['Pv']) { Invoke-ToolSync -Runspace $script:RsPv -Script { Stop-Trace } | Out-Null }
                else { script:Stop-PerfViewHard }
            }
        } catch { script:Stop-PerfViewHard }
        foreach ($rs in @($script:RsPv, $script:RsMon, $script:RsPkg)) { try { $rs.Close() } catch {} }
    })

    [void]$w.ShowDialog()
}
