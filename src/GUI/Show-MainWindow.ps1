# Builds and shows the main window; each tool's actions run in its own background runspace.
function Show-MainWindow {
    Add-Type -AssemblyName PresentationFramework, System.Windows.Forms -ErrorAction Stop
    # Global mark hotkey via a LOW-LEVEL keyboard hook (WH_KEYBOARD_LL), not RegisterHotKey. RegisterHotKey
    # silently loses to any app that already owns the combo, and on a European layout Ctrl+Alt is AltGr, so the
    # focused app eats Ctrl+Alt+<key> first - which is exactly why pressing it while clicking in another program
    # recorded nothing. A low-level hook sees every keystroke system-wide BEFORE any app, can't fail to
    # register, and can SWALLOW the chord so the foreground app never sees it. The chord detection runs in
    # compiled code (fast per keystroke; a slow hook gets dropped by Windows); PowerShell only supplies the
    # OnMark callback and toggles Active. Swallowing is gated on Active (a capture is running), so the key is a
    # pure pass-through at all other times. Guarded: a second load in the session throws, which is harmless.
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace RtHook {
  public static class Hook {
    public delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll", SetLastError=true)] static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr GetModuleHandle(string name);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vKey);

    public static int  TargetVk;
    public static bool NeedCtrl, NeedAlt, NeedShift, NeedWin;
    public static bool Active;          // set by the UI: true only while a capture is running
    public static Action OnMark;        // set by the UI: fires a mark
    static IntPtr _hook = IntPtr.Zero;
    static readonly LowLevelKeyboardProc _proc = Callback;   // kept alive by this static field

    public static bool Install()  { if (_hook == IntPtr.Zero) _hook = SetWindowsHookEx(13, _proc, GetModuleHandle(null), 0); return _hook != IntPtr.Zero; }
    public static void Uninstall(){ if (_hook != IntPtr.Zero) { UnhookWindowsHookEx(_hook); _hook = IntPtr.Zero; } }

    static bool Down(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }
    static bool ModsHeld() {
      if (NeedCtrl  && !Down(0x11)) return false;                 // VK_CONTROL
      if (NeedAlt   && !Down(0x12)) return false;                 // VK_MENU (Alt / AltGr)
      if (NeedShift && !Down(0x10)) return false;                 // VK_SHIFT
      if (NeedWin   && !(Down(0x5B) || Down(0x5C))) return false; // VK_LWIN / VK_RWIN
      return true;
    }
    static IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam) {
      if (nCode >= 0) {
        int msg = wParam.ToInt32();
        if (msg == 0x100 || msg == 0x104) {                       // WM_KEYDOWN / WM_SYSKEYDOWN
          int vk = Marshal.ReadInt32(lParam);
          if (vk == TargetVk && Active && ModsHeld()) {
            var cb = OnMark; if (cb != null) { try { cb(); } catch {} }
            return (IntPtr)1;                                     // swallow: override the foreground app
          }
        }
      }
      return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
    }
  }
}
'@ -ErrorAction Stop
    } catch {}

    # Force software rendering. On clean/VM/RDP/low-desktop-heap machines WPF's hardware composition
    # render target fails to allocate (HwndTarget.UpdateWindowSettings throws Win32 1816 "Not enough
    # quota is available to process this command" on the WM_WINDOWPOSCHANGED messages during show),
    # spamming the recovery handler. A diagnostic GUI gains nothing from GPU accel, so take it off the
    # table. Must be set before the window's HwndTarget is created (i.e. before XamlReader.Load/ShowDialog).
    try { [System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly } catch {}

    # Load a XAML file into an object (shell or a reusable tab control).
    function script:Read-Xaml([string]$path) {
        $x = Get-Content -Path $path -Raw
        $r = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($x))
        try { [System.Windows.Markup.XamlReader]::Load($r) } finally { $r.Close() }
    }

    # Shell window + each tab body as its own reusable control (Schemas\Tabs\*.xaml), injected into the
    # matching TabItem. Keeping tabs in separate files makes them easy to maintain in isolation.
    $w = script:Read-Xaml $script:MainWindowSchema
    $tabsDir = Join-Path (Split-Path $script:MainWindowSchema -Parent) 'Tabs'
    $script:TabPages = [ordered]@{
        TabPackages = script:Read-Xaml (Join-Path $tabsDir 'PackagesTab.xaml')
        TabPerfView = script:Read-Xaml (Join-Path $tabsDir 'PerfViewTab.xaml')
        TabMonitor  = script:Read-Xaml (Join-Path $tabsDir 'MonitorTab.xaml')
        TabGeneral  = script:Read-Xaml (Join-Path $tabsDir 'GeneralTab.xaml')
    }
    foreach ($tabName in $script:TabPages.Keys) {
        $tabItem = $w.FindName($tabName)
        if (-not $tabItem) { throw "Shell is missing TabItem '$tabName'." }
        $tabItem.Content = $script:TabPages[$tabName]
    }

    Set-WindowThemeResources -window $w -usesDarkMode (Get-SystemUsesDarkMode)
    $script:FgBrush  = $w.Resources['AppFgColor']
    $script:IdBrush  = $w.Resources['AppIdColor']
    $script:ChipBg   = $w.Resources['CardHoverColor']

    # Each XamlReader.Load makes its own name scope, so a named element lives in the shell OR one of the tab
    # controls. Resolve every name across all of them.
    $findScopes = @($w) + @($script:TabPages.Values)
    foreach ($n in 'TxtOutput','LblBusy','LblVersion',
                   'CmbPvProfile','TxtPvLabel','BtnPvStart','BtnPvStop','BtnPvAbort','TxtPvSeconds','BtnPvOpen','BtnPvStatus','LblPvStatus','BtnPvMark','TxtPvMark','LblPvHotkey',
                   'TxtPvProfName','TxtPvProfDesc','PnlPvKernel','CmbPvClr','PnlPvProviders','TxtPvProvOther','TxtPvExtra','TxtPvCircular','TxtPvBuffer','BtnPvProfSave','BtnPvProfDelete','BtnPvProfDefault',
                   'TxtPvOutput','TxtPvSym','TxtPvHotkey','TxtPvLogKeep','TxtPvLogMax','ChkPvMerge','ChkPvZip','ChkPvStartRundown','ChkPvMarkOnCrash','BtnPvSettingsSave',
                   'BtnMonEnable','BtnMonStart','BtnMonStop','BtnMonStatus','BtnMonTestTelemetry','BtnMonForceFlush','BtnMonCollect','BtnMonDisable','LblMonStatus','BtnMonVerify','LblMonVerify','PnlCfgProcess','PnlCfgMonitor','PnlCfgGeneral','BtnMonSave','BtnMonReload','ChkMonTail','TxtMonLog','LblMonCompress','PbMonCompress',
                   'BtnPkgInstallAll','BtnPkgRefresh','BtnPkgOpen','BtnPkgUpdate','LblPkgUpdate','PnlPackages','LblPkgStatus',
                   'ChkGenWerEnabled','TxtGenWerFolder','CmbGenWerType','TxtGenWerCount','ChkGenWerAllApps','BtnGenWerApply','BtnGenWerRemove','LblGenWerStatus',
                   'TxtGenSymPath','BtnGenSymSave','BtnGenSymBuild','LblGenSymStatus',
                   'BtnShortcut') {
        $el = $null
        foreach ($s in $findScopes) { $el = $s.FindName($n); if ($el) { break } }
        Set-Variable -Name $n -Scope script -Value $el
    }
    $script:LblVersion.Text = "v$ScriptVersion"

    $script:RsPv  = New-ToolRunspace -ToolPath $script:ToolPerfViewPath -Load
    # Second PerfView runspace for control actions (Stop/Abort/Status). A capture blocks RsPv for its whole
    # duration, so Stop (fire the event) and status must run here or they'd be stuck behind it.
    $script:RsPvCtl = New-ToolRunspace -ToolPath $script:ToolPerfViewPath -Load
    # Dedicated runspace for marks so a quick mark (button or global hotkey) never contends with a Stop/Abort/
    # Status already running on RsPvCtl - each fires its own labeled search point into the live capture.
    $script:RsPvMark = New-ToolRunspace -ToolPath $script:ToolPerfViewPath -Load
    $script:RsMon = New-ToolRunspace -ToolPath $script:ToolMonitorPath  -Load
    $script:RsPkg = New-ToolRunspace -ToolPath $script:ToolPackagesPath -Load
    # General tab (shared platform): the symbol store + platform.json + the PDB generator.
    $script:RsGen = New-ToolRunspace -ToolPath $script:ToolPlatformPath -Load
    $script:RsUpd = New-ToolRunspace    # plain runspace for the lightweight GitHub update check (off the Pkg runspace)
    $script:Busy  = @{ Pv = $false; Mon = $false; Pkg = $false; Gen = $false }
    $script:PvProfiles = @()
    $script:PvLoading  = $false
    $script:MonCtls    = @{}

    # known PerfView toggles (rendered as checkboxes / dropdown instead of free text)
    $script:PvKernelKeywords  = @('Default','ThreadTime','FileIOInit','FileIO','DiskIO','MemoryHardFaults','VirtualAlloc','NetworkTCPIP','Registry','ImageLoad')
    $script:PvProviderPresets = @('Microsoft-Windows-Kernel-Memory','Microsoft-Windows-TCPIP',
                                  'Microsoft-Windows-DNS-Client','Microsoft-Windows-WinINet','Microsoft-Windows-WinHttp','Microsoft-Windows-WebIO',
                                  'Microsoft-Windows-Kernel-Power','Microsoft-Antimalware-Service','Microsoft-Antimalware-Engine')
    $script:PvClrPresets      = @('Default','None','Verbose')
    # dropdown options for Monitor config fields (anything not listed falls back to checkbox/text by type)
    $script:MonFieldMeta = @{ DuplicateAction = @('Delete','Keep'); RunMode = @('Logon','Startup'); WorkerPriority = @('Idle','BelowNormal','Normal'); WerDumpType = @('Full','Mini') }
    # Which config sub-tab each field belongs to (#53). ProcDumpArgs is rendered as toggles on 'Process', so it is
    # not listed here. Any field not listed falls through to 'General'.
    $script:MonFieldGroup = @{
        Apps = 'Monitor'; DumpDir = 'Monitor'; CheckSeconds = 'Monitor'; CooldownSeconds = 'Monitor'
        DuplicateAction = 'Monitor'; DuplicateWindowSeconds = 'Monitor'; RunMode = 'Monitor'; TaskUser = 'Monitor'; HeadlessLauncher = 'Monitor'
        DumpDiskLimitGB = 'General'; DumpGraceSeconds = 'General'; CleanupSeconds = 'General'; KnownIssuesEnabled = 'General'; SuppressKnown = 'General'; WorkerPriority = 'General'
        BaselinePath = 'General'; TelemetrySendEnabled = 'General'; TelemetrySeconds = 'General'; LogKeep = 'General'; LogMaxMB = 'General'
    }
    # RT-2 WER LocalDumps fields are edited on the top-level General tab (a Windows-environment setting,
    # independent of the ProcDump monitor), so they are NOT rendered in this per-tool config editor.
    $script:MonHiddenFields = @('WerDumpsEnabled','WerDumpFolder','WerDumpType','WerDumpCount','WerAllApps')

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

    # ---------- PerfView mark hotkey (global) ----------
    # Parse a combo like "Ctrl+Alt+M" into a modifier bitmask (0x1 Alt, 0x2 Ctrl, 0x4 Shift, 0x8 Win) + the
    # virtual-key code the low-level hook watches for. A-Z / 0-9 map to their ASCII value (= the VK code);
    # F1..F12 are supported too. Vk=0 means the combo had no usable key.
    function script:ConvertTo-HotkeySpec([string]$combo) {
        $mods = 0; $vk = 0
        foreach ($raw in ("$combo" -split '\+')) {
            $part = $raw.Trim()
            switch -Regex ($part.ToLower()) {
                '^(ctrl|control)$' { $mods = $mods -bor 0x2 }
                '^alt$'            { $mods = $mods -bor 0x1 }
                '^shift$'          { $mods = $mods -bor 0x4 }
                '^(win|windows)$'  { $mods = $mods -bor 0x8 }
                '^$'               { }
                default {
                    $k = $part.ToUpper()
                    if ($k.Length -eq 1 -and $k -match '[A-Z0-9]') { $vk = [int][char]$k }
                    elseif ($k -match '^F([1-9]|1[0-2])$')         { $vk = 0x70 + [int]$k.Substring(1) - 1 }
                }
            }
        }
        return @{ Mods = $mods; Vk = $vk }
    }

    # Arm the global mark key via the low-level keyboard hook: load the chord into the compiled hook, point its
    # OnMark callback at Fire-PvMark, and install it. Called from SourceInitialized. Failure is non-fatal - the
    # Mark button still works. The hook only swallows/fires while Active (set from the timer when a capture is
    # running), so the key is a pure pass-through otherwise.
    function script:Register-PvHotkey {
        try {
            if ([string]::IsNullOrWhiteSpace($script:PvMarkHotkey)) { return }
            if (-not ('RtHook.Hook' -as [type])) { & $script:Append 'PerfView: mark hotkey hook unavailable on this host - use the Mark button.'; return }
            $spec = script:ConvertTo-HotkeySpec $script:PvMarkHotkey
            if (-not $spec.Vk) { & $script:Append "PerfView: mark hotkey '$($script:PvMarkHotkey)' not understood - use the Mark button."; return }
            [RtHook.Hook]::TargetVk  = [int]$spec.Vk
            [RtHook.Hook]::NeedCtrl  = ($spec.Mods -band 0x2) -ne 0
            [RtHook.Hook]::NeedAlt   = ($spec.Mods -band 0x1) -ne 0
            [RtHook.Hook]::NeedShift = ($spec.Mods -band 0x4) -ne 0
            [RtHook.Hook]::NeedWin   = ($spec.Mods -band 0x8) -ne 0
            [RtHook.Hook]::Active    = [bool](Test-Path $script:PvActiveFile)
            # Keep a reference so the delegate isn't collected; it marshals the compiled hook's callback to Fire-PvMark.
            $script:PvMarkAction = [Action]{ try { script:Fire-PvMark '' } catch {} }
            [RtHook.Hook]::OnMark = $script:PvMarkAction
            if ([RtHook.Hook]::Install()) {
                & $script:Append "PerfView: mark hotkey $($script:PvMarkHotkey) armed globally - it overrides other apps while a capture is running."
            } else {
                & $script:Append "PerfView: failed to install the mark hotkey hook - use the Mark button."
            }
        } catch { & $script:Append "PerfView: mark hotkey setup failed: $($_.Exception.Message)" }
    }

    function script:Unregister-PvHotkey {
        try { if ('RtHook.Hook' -as [type]) { [RtHook.Hook]::Active = $false; [RtHook.Hook]::OnMark = $null; [RtHook.Hook]::Uninstall() } } catch {}
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

    # Live dump-compression indicator (#65). Dumps are gzipped at rest by the INGEST worker (DumpTriage), and
    # also any flush-time compression by Telemetry - both log "compressing <dump>: NN%" and a final
    # "compressed <dump>: X -> Y (Z% of raw)". Read the newest of those logs that carries a compress line and
    # mirror it into the Monitor tab's progress bar + label, so a user with the app open sees a large dump being
    # compressed (including during a Force flush) and when it is done.
    $script:CompressLast = ''
    function script:Update-CompressionProgress {
        if (-not $script:LblMonCompress) { return }
        try {
            $logs = @(Get-ChildItem $script:MonLogDir -File -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -match '^(DumpTriage|Telemetry)_.*\.log$' } |
                      Sort-Object LastWriteTime -Descending | Select-Object -First 4)
            $line = $null
            foreach ($f in $logs) {
                $line = Get-Content -LiteralPath $f.FullName -Tail 60 -ErrorAction SilentlyContinue |
                        Where-Object { $_ -match 'compress(ing|ed) ' } | Select-Object -Last 1
                if ($line) { break }
            }
            if (-not $line -or $line -eq $script:CompressLast) { return }
            $script:CompressLast = $line
            $p = Get-CompressionProgressLine $line
            if ($p) { $script:LblMonCompress.Text = $p.Text; if ($p.Percent -ge 0) { $script:PbMonCompress.Value = $p.Percent } }
        } catch {}
    }

    # Cancel a running Force flush. Runs on the UI thread, so it works even while the 'Mon' runspace is busy
    # inside Invoke-ForceFlush (the per-tool Busy guard would otherwise just drop a Stop/Force-flush click). It
    # drops the forceflush.stop marker the workers poll AND kills the worker processes outright, so a long
    # gzip/upload ends at once. Force flush is the only user of this marker ($BaseDir\forceflush.stop).
    $script:FlushRunning  = $false
    $script:FlushStopFile = Join-Path (Split-Path $script:MonLogDir -Parent) 'forceflush.stop'
    function script:Cancel-ForceFlush {
        try { Set-Content -LiteralPath $script:FlushStopFile -Value (Get-Date -Format o) -Encoding ASCII -ErrorAction SilentlyContinue } catch {}
        $killed = 0
        try {
            Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                Where-Object { "$($_.CommandLine)" -match '(DumpTriage|Send-Telemetry)\.ps1' } |
                ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; $killed++ } catch {} }
        } catch {}
        & $script:Append ("Force flush: cancel requested{0}; it stops at the next checkpoint." -f $(if ($killed) { " - stopped $killed worker process(es)" } else { '' }))
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
        $pv  = if (Test-Path $PerfViewExe) { (Get-Item $PerfViewExe).VersionInfo.FileVersion } else { 'not downloaded' }
        $act = if ($active) { "active: '$($active.Profile)'$(if($active.Label){" / $($active.Label)"})" } else { 'no active trace' }
        "PerfView: $pv  |  $act  |  output: $($cfg.OutputDir)"
    }
    $monStatusSB = {
        $cfg = Read-Config; $task = Get-MonitorTask
        $state = if ($task) { $task.State } else { 'not enabled' }
        $tel = ''
        # The outbox is always written by ingest; show its depth whichever way sending is set, and flag when
        # sending is OFF so a growing backlog is not mistaken for a stuck sender.
        $ob = Join-Path $env:ProgramData 'ReportingTroubleshooting\Monitor\KnownIssues\outbox'
        $pending = if (Test-Path $ob) { @(Get-ChildItem $ob -Filter *.json -File -ErrorAction SilentlyContinue).Count } else { 0 }
        $tel = if ($cfg.TelemetrySendEnabled) { "  |  telemetry: $pending event(s) pending" } else { "  |  telemetry send OFF: $pending event(s) held locally" }
        "Task: $state  |  apps: $($cfg.Apps -join ', ')  |  dump budget: $($cfg.DumpDiskLimitGB) GB  |  dumps in $($cfg.DumpDir)$tel"
    }
    $script:RefreshPv  = [scriptblock]::Create("Start-ToolJob -Runspace `$script:RsPvCtl -Script { $($pvStatusSB.ToString()) }  -OnText `$script:SetPvStatus  | Out-Null")
    $script:RefreshMon = [scriptblock]::Create("Start-ToolJob -Runspace `$script:RsMon -Script { $($monStatusSB.ToString()) } -OnText `$script:SetMonStatus | Out-Null")

    $script:ToolName = @{ Pv = 'PerfView'; Mon = 'Monitor'; Pkg = 'Packages'; Gen = 'General' }
    function script:Invoke-Action($toolKey, $rs, [scriptblock]$sb, [object[]]$argList, [scriptblock]$onDone) {
        if ($script:Busy[$toolKey]) {
            $n = $script:ToolName[$toolKey]; if (-not $n) { $n = $toolKey }
            & $script:Append "$n is still running the previous action - watch the Output above for progress; it will report when done."
            return
        }
        $script:Busy[$toolKey] = $true
        $done = [scriptblock]::Create("`$script:Busy['$toolKey'] = `$false; " + $(if ($onDone) { $onDone.ToString() } else { '' }))
        Start-ToolJob -Runspace $rs -Script $sb -ArgList $argList -OnText $script:Append -OnDone $done | Out-Null
    }

    # ---------- PerfView: profile / settings editor ----------
    function script:Load-PvProfileFields([string]$name) {
        $p = $script:PvProfiles | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
        if (-not $p) { return }
        $script:TxtPvProfName.Text = [string]$p.Name
        $script:TxtPvProfDesc.Text = [string]$p.Description
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
        $script:TxtPvOutput.Text   = [string]$c.OutputDir
        $script:TxtPvSym.Text      = [string]$c.SymbolPath
        $script:TxtPvHotkey.Text   = "$($c.MarkHotkey)".Trim()
        $script:TxtPvLogKeep.Text  = "$($c.LogKeep)"
        $script:TxtPvLogMax.Text   = "$($c.LogMaxMB)"
        $script:ChkPvMerge.IsChecked = [bool]$c.Merge
        $script:ChkPvZip.IsChecked   = [bool]$c.Zip
        $script:ChkPvStartRundown.IsChecked = [bool]$c.StartRundown
        $script:ChkPvMarkOnCrash.IsChecked  = [bool]$c.MarkOnCrash
        $script:PvMarkHotkey = "$($c.MarkHotkey)".Trim()
        $script:LblPvHotkey.Text = if ($script:PvMarkHotkey) { "mark hotkey: $($script:PvMarkHotkey)  -  works anywhere while capturing" } else { 'mark hotkey: none set (set it in Global settings below)' }
        script:Load-PvProfileFields ([string]$script:CmbPvProfile.SelectedItem)
    }

    $script:CmbPvProfile.Add_SelectionChanged({ if (-not $script:PvLoading) { script:Load-PvProfileFields ([string]$script:CmbPvProfile.SelectedItem) } })

    # One Start for every trace: a 'collect' with the stop event always armed; the Max-sec field adds a
    # hard cap only when > 0 (0 = run until Stop). The capture blocks RsPv for its whole duration (live
    # progress streams to Output); Stop/Abort/Status run on RsPvCtl so they work while it is running.
    $script:BtnPvStart.Add_Click({
        $p = [string]$script:CmbPvProfile.SelectedItem; $l = $script:TxtPvLabel.Text
        $s = 0; [void][int]::TryParse($script:TxtPvSeconds.Text, [ref]$s); if ($s -lt 0) { $s = 0 }
        $lim = if ($s -gt 0) { "up to ${s}s, or until Stop" } else { 'until Stop' }
        & $script:Append "PerfView: start capture (profile '$p', $lim)..."
        script:Invoke-Action 'Pv' $script:RsPv { param($pp,$ll,$ss) Start-Trace $pp $ll $ss } @($p, $l, $s) $script:RefreshPv
    })
    $script:BtnPvStop.Add_Click({
        & $script:Append 'PerfView: stop capture (signalling; it will merge, zip and report the file)...'
        Start-ToolJob -Runspace $script:RsPvCtl -Script { Stop-Trace } -OnText $script:Append -OnDone $script:RefreshPv | Out-Null
    })
    $script:BtnPvAbort.Add_Click({
        & $script:Append 'PerfView: abort (force-cancel, no data saved)...'
        Start-ToolJob -Runspace $script:RsPvCtl -Script { Stop-Abort } -OnText $script:Append -OnDone $script:RefreshPv | Out-Null
    })
    # Drop a labeled 'search point' into the running capture (button or global hotkey). Fires Add-Mark on the
    # dedicated RsPvMark runspace (never blocks, never contends with Stop/Abort), with an in-flight gate so a
    # rapid double-press is ignored rather than colliding on the runspace. A system sound confirms the press
    # even when another app is focused.
    function script:Fire-PvMark([string]$note) {
        if (-not (Test-Path $script:PvActiveFile)) { & $script:Append 'PerfView: no capture running - start one before marking.'; return }
        if ($script:PvMarkInFlight) { & $script:Append 'PerfView: mark still registering - press ignored (try again in a moment).'; return }
        $script:PvMarkInFlight = $true
        & $script:Append ('PerfView: mark' + $(if ($note) { " '$note'" } else { '' }) + '...')
        try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}
        $done = { $script:PvMarkInFlight = $false; & $script:RefreshPv }
        Start-ToolJob -Runspace $script:RsPvMark -Script { param($t) Add-Mark $t } -ArgList @($note) -OnText $script:Append -OnDone $done | Out-Null
    }
    $script:BtnPvMark.Add_Click({
        $note = [string]$script:TxtPvMark.Text
        script:Fire-PvMark $note
        $script:TxtPvMark.Clear()
    })
    $script:BtnPvOpen.Add_Click({ script:Invoke-Action 'Pv' $script:RsPv { $cfg = Read-Config; if (Test-Path $cfg.OutputDir) { Start-Process explorer.exe $cfg.OutputDir; 'opened output folder' } else { 'output folder does not exist yet' } } @() $null })
    $script:BtnPvStatus.Add_Click({ & $script:RefreshPv })

    $reloadPv = { script:Load-PvAll }
    $script:BtnPvProfSave.Add_Click({
        $kernel = (@($script:PvKernelKeywords | Where-Object { $script:PvKernelChecks[$_].IsChecked }) -join ',')
        $provChecked = @($script:PvProviderPresets | Where-Object { $script:PvProviderChecks[$_].IsChecked })
        $provOther   = @(($script:TxtPvProvOther.Text -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $providers = (@($provChecked + $provOther) -join ',')
        $vals = @($script:TxtPvProfName.Text, $kernel, $script:CmbPvClr.Text, $providers, $script:TxtPvExtra.Text, $script:TxtPvCircular.Text, $script:TxtPvBuffer.Text, $script:TxtPvProfDesc.Text)
        if (-not $vals[0]) { & $script:Append 'Enter a profile name first.'; return }
        & $script:Append "PerfView: save profile '$($vals[0])'..."
        script:Invoke-Action 'Pv' $script:RsPv {
            param($name,$kernel,$clr,$prov,$extra,$circ,$buf,$desc)
            $cfg = Read-Config
            $p = $cfg.Profiles | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
            if (-not $p) {
                $p = [pscustomobject]@{ Name=$name; Description=''; KernelEvents=''; ClrEvents=''; Providers=''; CircularMB=2048; BufferSizeMB=1024; ExtraArgs='' }
                $cfg.Profiles = @($cfg.Profiles) + $p
            }
            $p.Name = $name; $p.Description = $desc; $p.KernelEvents = $kernel; $p.ClrEvents = $clr; $p.Providers = $prov; $p.ExtraArgs = $extra
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
        $hot = ([string]$script:TxtPvHotkey.Text).Trim()
        $vals = @($script:TxtPvOutput.Text, $script:TxtPvSym.Text,
                  $(if ($script:ChkPvMerge.IsChecked) { 'true' } else { 'false' }), $(if ($script:ChkPvZip.IsChecked) { 'true' } else { 'false' }),
                  $hot, $script:TxtPvLogKeep.Text, $script:TxtPvLogMax.Text,
                  $(if ($script:ChkPvStartRundown.IsChecked) { 'true' } else { 'false' }), $(if ($script:ChkPvMarkOnCrash.IsChecked) { 'true' } else { 'false' }))
        & $script:Append 'PerfView: save settings...'
        script:Invoke-Action 'Pv' $script:RsPv {
            param($out,$sym,$merge,$zip,$hotkey,$logkeep,$logmax,$rundown,$markcrash)
            $cfg = Read-Config; $cfg.OutputDir = $out; $cfg.SymbolPath = $sym
            $cfg.Merge = ($merge -eq 'true'); $cfg.Zip = ($zip -eq 'true')
            $cfg.MarkHotkey = $hotkey
            $cfg.StartRundown = ($rundown -eq 'true'); $cfg.MarkOnCrash = ($markcrash -eq 'true')
            $k = 0; if ([int]::TryParse("$logkeep", [ref]$k) -and $k -ge 0) { $cfg.LogKeep = $k }
            $m = 0; if ([int]::TryParse("$logmax",  [ref]$m) -and $m -ge 1) { $cfg.LogMaxMB = $m }
            Save-Config $cfg; "settings saved (output: $out)"
        } $vals $script:RefreshPv
        # Re-arm the global mark hotkey with the new chord (UI thread; independent of the async config save).
        $script:PvMarkHotkey = $hot
        script:Unregister-PvHotkey
        script:Register-PvHotkey
        $script:LblPvHotkey.Text = if ($script:PvMarkHotkey) { "mark hotkey: $($script:PvMarkHotkey)  -  works anywhere while capturing" } else { 'mark hotkey: none set (set it in Global settings below)' }
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

    # Candidate users for the TaskUser picker: who is running the GUI, the interactive console user, and the
    # enabled local accounts. Editable so a domain account not listed can still be typed.
    function script:Get-TaskUserCandidates {
        $c = @("$env:USERDOMAIN\$env:USERNAME")
        try { $c += (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch {}
        try { $c += (Get-LocalUser -ErrorAction Stop | Where-Object Enabled | ForEach-Object { '{0}\{1}' -f $env:COMPUTERNAME, $_.Name }) } catch {}
        @($c | Where-Object { "$_".Trim() } | Select-Object -Unique)
    }

    function script:New-ConfigRow($name, $value, $options) {
        $row = New-Object System.Windows.Controls.DockPanel; $row.Margin = '0,0,0,6'
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = $name; $lbl.Width = 180; $lbl.VerticalAlignment = 'Center'; $lbl.Foreground = $script:FgBrush
        [System.Windows.Controls.DockPanel]::SetDock($lbl, 'Left')
        [void]$row.Children.Add($lbl)
        if ($name -eq 'TaskUser') {
            # Editable dropdown of discovered users, defaulting to the current value or, if empty, the current user.
            $ctl = New-Object System.Windows.Controls.ComboBox
            $ctl.Width = 260; $ctl.HorizontalAlignment = 'Left'; $ctl.IsEditable = $true
            $cands = script:Get-TaskUserCandidates
            foreach ($u in $cands) { [void]$ctl.Items.Add($u) }
            $ctl.Text = if ("$value".Trim()) { "$value".Trim() } elseif ($cands.Count) { $cands[0] } else { "$env:USERDOMAIN\$env:USERNAME" }
        } elseif ($options) {
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
    # One capture-switch checkbox for the ProcDump sub-tab.
    function script:New-ArgToggle($label, $checked, $hint) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $label; $cb.IsChecked = [bool]$checked; $cb.Foreground = $script:FgBrush; $cb.Margin = '0,0,0,6'
        if ($hint) { $cb.ToolTip = $hint }
        $cb
    }
    # Render the ProcDump capture switches as toggles (+ a dumps-per-session count) into the Process sub-tab, from
    # the ProcDumpArgs string. -accepteula is always applied and never shown. Controls are kept in $script:MonArgCtls
    # so BtnMonSave can rebuild the arg string with ConvertTo-ProcDumpArgs. (#53)
    function script:Build-ArgToggles($argString) {
        $t = ConvertFrom-ProcDumpArgs $argString
        $script:MonArgCtls = [ordered]@{}
        $p = $script:PnlCfgProcess
        $intro = New-Object System.Windows.Controls.TextBlock
        $intro.Text = 'ProcDump capture switches (-accepteula is always applied).'; $intro.Foreground = $script:IdBrush
        $intro.TextWrapping = 'Wrap'; $intro.Margin = '0,0,0,10'
        [void]$p.Children.Add($intro)

        # Dump type: a single choice - -ma and -mp are mutually exclusive, so a dropdown, not checkboxes.
        $dtRow = New-Object System.Windows.Controls.DockPanel; $dtRow.Margin = '0,0,0,8'
        $dtLbl = New-Object System.Windows.Controls.TextBlock
        $dtLbl.Text = 'Dump type'; $dtLbl.Width = 120; $dtLbl.VerticalAlignment = 'Center'; $dtLbl.Foreground = $script:FgBrush
        [System.Windows.Controls.DockPanel]::SetDock($dtLbl, 'Left'); [void]$dtRow.Children.Add($dtLbl)
        $dtCb = New-Object System.Windows.Controls.ComboBox; $dtCb.Width = 220; $dtCb.HorizontalAlignment = 'Left'
        $dtCb.ToolTip = 'Full (-ma): all memory, richest. Mini-plus (-mp): lighter, usually still walkable for the signature. Mini: smallest (stacks only); signatures may be provisional.'
        $script:DumpTypeItems = [ordered]@{ Full = 'Full (-ma)'; MiniPlus = 'Mini-plus (-mp)'; Mini = 'Mini (smallest)' }
        foreach ($disp in $script:DumpTypeItems.Values) { [void]$dtCb.Items.Add($disp) }
        $dtCb.SelectedItem = $(if ($script:DumpTypeItems.Contains("$($t.DumpType)")) { $script:DumpTypeItems["$($t.DumpType)"] } else { $script:DumpTypeItems['Full'] })
        [void]$dtRow.Children.Add($dtCb); [void]$p.Children.Add($dtRow)
        $script:MonArgCtls.DumpType = $dtCb

        # Exception: one -e checkbox + an inline level box (blank = unhandled/2nd-chance only; 1 = also first-chance).
        $exRow = New-Object System.Windows.Controls.StackPanel; $exRow.Orientation = 'Horizontal'; $exRow.Margin = '0,0,0,6'
        $exCb = script:New-ArgToggle 'Dump on exception (-e)' $t.OnException 'Unchecked = never dump on exceptions. Checked = dump on unhandled (2nd-chance) exceptions; put 1 in the box to also dump on first-chance exceptions (noisier).'
        $exCb.Margin = '0,0,8,0'; $exCb.VerticalAlignment = 'Center'
        $exLvl = New-Object System.Windows.Controls.TextBox; $exLvl.Width = 44; $exLvl.VerticalAlignment = 'Center'; $exLvl.Text = "$($t.ExceptionLevel)"
        $exLvl.ToolTip = 'Blank = -e (unhandled only). 1 = -e 1 (also first-chance).'
        script:Set-NumericOnly $exLvl
        $exHint = New-Object System.Windows.Controls.TextBlock; $exHint.Text = 'level (blank = unhandled only; 1 = also first-chance)'
        $exHint.Foreground = $script:IdBrush; $exHint.VerticalAlignment = 'Center'; $exHint.Margin = '8,0,0,0'
        [void]$exRow.Children.Add($exCb); [void]$exRow.Children.Add($exLvl); [void]$exRow.Children.Add($exHint)
        [void]$p.Children.Add($exRow)
        $script:MonArgCtls.OnException    = $exCb
        $script:MonArgCtls.ExceptionLevel = $exLvl

        $script:MonArgCtls.OnHang         = script:New-ArgToggle 'Dump on hang / unresponsive window (-h)'   $t.OnHang         'Dump when the window stops responding.'
        $script:MonArgCtls.WaitForProcess = script:New-ArgToggle 'Wait for the process to start (-w)'        $t.WaitForProcess 'If the app is not running yet, wait and attach when it starts.'
        foreach ($k in 'OnHang','WaitForProcess') { [void]$p.Children.Add($script:MonArgCtls[$k]) }
        $row = New-Object System.Windows.Controls.DockPanel; $row.Margin = '0,4,0,0'
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = 'Dumps per session (-n)'; $lbl.Width = 180; $lbl.VerticalAlignment = 'Center'; $lbl.Foreground = $script:FgBrush
        [System.Windows.Controls.DockPanel]::SetDock($lbl, 'Left'); [void]$row.Children.Add($lbl)
        $tb = New-Object System.Windows.Controls.TextBox; $tb.Width = 80; $tb.HorizontalAlignment = 'Left'; $tb.Text = "$($t.DumpsPerSession)"
        script:Set-NumericOnly $tb
        $script:MonArgCtls.DumpsPerSession = $tb
        [void]$row.Children.Add($tb); [void]$p.Children.Add($row)
    }
    function script:Build-MonEditor {
        if ($script:Busy['Mon']) { & $script:Append 'Monitor busy - cannot reload config now.'; return }
        $cfg = Invoke-ToolSync -Runspace $script:RsMon -Script { Read-Config } | Select-Object -First 1
        if (-not $cfg) { return }
        $script:PnlCfgProcess.Children.Clear(); $script:PnlCfgMonitor.Children.Clear(); $script:PnlCfgGeneral.Children.Clear()
        $script:MonCtls = @{}
        foreach ($prop in $cfg.PSObject.Properties) {
            if ($prop.Name -eq 'ProcDumpArgs') { continue }        # rendered as toggles on the Process sub-tab
            if ($script:MonHiddenFields -contains $prop.Name) { continue }   # WER fields live on the top-level General tab
            $grp = $script:MonFieldGroup[$prop.Name]; if (-not $grp) { $grp = 'General' }
            $panel = switch ($grp) { 'Process' { $script:PnlCfgProcess } 'Monitor' { $script:PnlCfgMonitor } default { $script:PnlCfgGeneral } }
            $r = script:New-ConfigRow $prop.Name $prop.Value $script:MonFieldMeta[$prop.Name]
            [void]$panel.Children.Add($r.Row)
            $script:MonCtls[$prop.Name] = $r.Ctl
        }
        script:Build-ArgToggles $cfg.ProcDumpArgs
    }

    # Enable from the GUI always refreshes the registered task (that is the button's purpose), so force the
    # "re-register same version?" / downgrade confirmations the non-interactive runspace cannot answer.
    $script:BtnMonEnable.Add_Click({ & $script:Append 'Monitor: enabling service...'; script:Invoke-Action 'Mon' $script:RsMon { $script:Force = $true; Enable-Service } @() $script:RefreshMon })
    $script:BtnMonStart.Add_Click({ & $script:Append 'Monitor: starting... (live attach/dump activity shows in the "Monitor log (live)" panel below)'; script:Invoke-Action 'Mon' $script:RsMon { Start-Monitor } @() $script:RefreshMon })
    $script:BtnMonStop.Add_Click({ & $script:Append 'Monitor: stopping...'; if ($script:FlushRunning) { script:Cancel-ForceFlush }; script:Invoke-Action 'Mon' $script:RsMon { Stop-Monitor (Read-Config) } @() $script:RefreshMon })
    $script:BtnMonStatus.Add_Click({ & $script:RefreshMon })
    $script:BtnMonTestTelemetry.Add_Click({ & $script:Append 'Telemetry: testing reachability + auth...'; script:Invoke-Action 'Mon' $script:RsMon { Test-Telemetry } @() $null })
    $script:BtnMonForceFlush.Add_Click({
        # Second click while a flush is running = cancel (the per-tool Busy guard would otherwise drop it).
        if ($script:FlushRunning) { script:Cancel-ForceFlush; return }
        & $script:Append 'Force flush: processing every dump in the dump dir now, then pushing telemetry (sync + drain outbox + upload granted dumps)... Click "Force flush" again, or Stop, to cancel.'
        $script:FlushRunning = $true
        script:Invoke-Action 'Mon' $script:RsMon { Invoke-ForceFlush } @() ([scriptblock]::Create('$script:FlushRunning = $false; & $script:RefreshMon'))
    })
    $script:BtnMonCollect.Add_Click({ & $script:Append 'Telemetry: collecting pending reports + gzipped dumps into <dump dir>\manual-outbox...'; script:Invoke-Action 'Mon' $script:RsMon { $r = Move-ToManualOutbox; "Collected $($r.Events) report(s) and $($r.Dumps) dump(s) to $($r.Dest)" } @() $script:RefreshMon })
    $script:BtnMonDisable.Add_Click({ & $script:Append 'Monitor: disabling service...'; if ($script:FlushRunning) { script:Cancel-ForceFlush }; script:Invoke-Action 'Mon' $script:RsMon { Disable-Service } @() $script:RefreshMon })
    $script:BtnMonVerify.Add_Click({
        if ($script:Busy['Mon']) { & $script:Append 'Monitor: busy - try again in a moment.'; return }
        $script:LblMonVerify.Text = 'Verifying dependencies for the monitored apps (attaching briefly to each running app)...'
        & $script:Append 'Monitor: verifying fault-id dependencies for the configured apps...'
        $done = { $script:LblMonVerify.Text = 'Dependency check complete - details in Output above.' }
        Start-ToolJob -Runspace $script:RsMon -Script { Get-MonitorDepReport } -OnText $script:Append -OnDone $done | Out-Null
    })
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
        # ProcDumpArgs is edited as toggles on the Process sub-tab; rebuild the arg string from them (#53).
        if ($script:MonArgCtls -and $script:MonArgCtls.Count) {
            $kv['ProcDumpArgs'] = ConvertTo-ProcDumpArgs ([ordered]@{
                DumpType        = switch -Wildcard ("$($script:MonArgCtls.DumpType.SelectedItem)") { '*-ma*' { 'Full' } '*-mp*' { 'MiniPlus' } default { 'Mini' } }
                OnException     = [bool]$script:MonArgCtls.OnException.IsChecked
                ExceptionLevel  = $script:MonArgCtls.ExceptionLevel.Text
                OnHang          = [bool]$script:MonArgCtls.OnHang.IsChecked
                WaitForProcess  = [bool]$script:MonArgCtls.WaitForProcess.IsChecked
                DumpsPerSession = $script:MonArgCtls.DumpsPerSession.Text
            })
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

    # ---------- General tab: WER crash dumps (Windows env) + shared symbols ----------
    foreach ($t in @('Full','Mini')) { [void]$script:CmbGenWerType.Items.Add($t) }
    script:Set-NumericOnly $script:TxtGenWerCount

    # WER settings are stored in (and applied by) the MONITOR tool's functions, but surfaced here as a
    # host-level "Windows environment" setting: applying writes HKLM directly, no need to run the monitor.
    function script:Load-GenAll {
        try {
            $c = Invoke-ToolSync -Runspace $script:RsMon -Script { Read-Config } | Select-Object -First 1
            if ($c) {
                $script:ChkGenWerEnabled.IsChecked = [bool]$c.WerDumpsEnabled
                $script:TxtGenWerFolder.Text       = [string]$c.WerDumpFolder
                $script:CmbGenWerType.SelectedItem = $(if ("$($c.WerDumpType)" -match '(?i)mini') { 'Mini' } else { 'Full' })
                $script:TxtGenWerCount.Text        = "$($c.WerDumpCount)"
                $script:ChkGenWerAllApps.IsChecked = [bool]$c.WerAllApps
            }
        } catch { & $script:Append "General: WER settings load failed: $($_.Exception.Message)" }
        try {
            # Prefill with the saved override, or - when none is set (blank = default) - the resolved default
            # shared-store path, so the field always SHOWS the effective symbol path. The default is remembered
            # so Save can re-blank it (keep it dynamic) if the user leaves it untouched.
            $p = Invoke-ToolSync -Runspace $script:RsGen -Script {
                [pscustomobject]@{ Saved = (Read-PlatformConfig).SymbolPath; Default = (Get-SharedSymbolPath '') }
            } | Select-Object -First 1
            $script:GenSymDefault = [string]$p.Default
            $script:TxtGenSymPath.Text = if ("$($p.Saved)".Trim()) { [string]$p.Saved } else { $script:GenSymDefault }
        } catch { & $script:Append "General: symbol path load failed: $($_.Exception.Message)" }
        script:Refresh-GenWerStatus
    }

    # The current LocalDumps registry state (what Windows will actually do), independent of the saved config.
    function script:Refresh-GenWerStatus {
        try {
            $s = Invoke-ToolSync -Runspace $script:RsMon -Script {
                $cfg  = Read-Config
                $keys = Get-WerTargetKeys $cfg
                $on   = @($keys | Where-Object { (Get-WerKeyState $_).DumpFolder })
                [pscustomobject]@{
                    Scope  = $(if ($cfg.WerAllApps) { 'all applications' } else { "$(@($cfg.Apps).Count) app(s)" })
                    Active = $on.Count; Total = @($keys).Count; Folder = $cfg.WerDumpFolder
                }
            } | Select-Object -First 1
            if ($s) {
                $script:LblGenWerStatus.Text = if ($s.Active) { "In Windows now: LocalDumps set for $($s.Active)/$($s.Total) target key(s) ($($s.Scope)) -> $($s.Folder)." }
                                               else { "In Windows now: LocalDumps not set by this app ($($s.Scope))." }
            }
        } catch { $script:LblGenWerStatus.Text = "WER status unavailable: $($_.Exception.Message)" }
    }

    $script:BtnGenWerApply.Add_Click({
        $vals = @(
            $(if ($script:ChkGenWerEnabled.IsChecked) { 'true' } else { 'false' }),
            $script:TxtGenWerFolder.Text,
            [string]$script:CmbGenWerType.SelectedItem,
            $script:TxtGenWerCount.Text,
            $(if ($script:ChkGenWerAllApps.IsChecked) { 'true' } else { 'false' }))
        & $script:Append 'General: saving WER settings and applying to Windows...'
        $done = { script:Refresh-GenWerStatus; & $script:RefreshMon }
        script:Invoke-Action 'Mon' $script:RsMon {
            param($en, $folder, $type, $count, $all)
            $cfg = Read-Config
            $cfg.WerDumpsEnabled = ($en -eq 'true')
            if ("$folder".Trim()) { $cfg.WerDumpFolder = "$folder".Trim() }
            $cfg.WerDumpType = $(if ("$type" -match '(?i)mini') { 'Mini' } else { 'Full' })
            $n = 0; if ([int]::TryParse("$count", [ref]$n) -and $n -ge 1) { $cfg.WerDumpCount = $n }
            $cfg.WerAllApps = ($all -eq 'true')
            Save-Config $cfg
            # Apply directly (writes/restores HKLM) without needing the monitor task to be running.
            if ($cfg.WerDumpsEnabled) { Sync-WerLocalDumps $cfg } else { Restore-WerLocalDumps }
            $(if ($cfg.WerDumpsEnabled) { "WER LocalDumps applied -> $($cfg.WerDumpFolder)" } else { 'WER LocalDumps removed (prior registry restored)' })
        } $vals $done
    })

    $script:BtnGenWerRemove.Add_Click({
        & $script:Append 'General: removing WER LocalDumps from Windows (restoring prior registry)...'
        $done = { script:Refresh-GenWerStatus; & $script:RefreshMon }
        script:Invoke-Action 'Mon' $script:RsMon {
            $cfg = Read-Config; $cfg.WerDumpsEnabled = $false; Save-Config $cfg
            Restore-WerLocalDumps
            'WER LocalDumps removed (prior registry restored)'
        } @() $done
        $script:ChkGenWerEnabled.IsChecked = $false
    })

    $script:BtnGenSymSave.Add_Click({
        & $script:Append 'General: saving shared symbol path...'
        script:Invoke-Action 'Gen' $script:RsGen {
            param($p, $def)
            $val = "$p".Trim()
            # If left at the prefilled default, store blank so the path stays dynamic (tracks the app root)
            # rather than freezing today's default as an explicit override.
            if ($val -eq "$def".Trim()) { $val = '' }
            $cfg = Read-PlatformConfig; $cfg.SymbolPath = $val; Save-PlatformConfig $cfg
            if ($val) { "symbol path saved (override: $val)" }
            else { "symbol path saved (default shared store: $(Get-SharedSymbolPath ''))" }
        } @($script:TxtGenSymPath.Text, $script:GenSymDefault) $null
    })

    $script:BtnGenSymBuild.Add_Click({
        if ($script:Busy['Gen']) { & $script:Append 'General: a symbol build is already running.'; return }
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = 'Select native-image binaries to build symbols for'
        $dlg.Filter = 'Binaries (*.dll;*.exe)|*.dll;*.exe|All files (*.*)|*.*'
        $dlg.Multiselect = $true
        if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $files = @($dlg.FileNames)
        if (-not $files.Count) { return }
        $script:LblGenSymStatus.Text = "Building symbols for $($files.Count) file(s)..."
        & $script:Append "General: building symbols for $($files.Count) file(s) (ngen createpdb; files whose symbols are already on the public server are skipped)..."
        $done = { $script:LblGenSymStatus.Text = 'Symbol build complete - see Output above.' }
        # Pass the configured symbol path so the public-symbol check queries the same server(s) (msdl, plus any
        # you added, e.g. the NuGet symbol server). Only binaries with NO public symbols get a generated PDB.
        script:Invoke-Action 'Gen' $script:RsGen {
            param($files, $sym)
            $res  = Build-Pdbs -Files $files -SkipIfPublic -SymbolPath $sym
            $ok   = @($res | Where-Object { $_.Generated })
            $pub  = @($res | Where-Object { $_.Reason -match 'public symbols already' })
            $skip = @($res | Where-Object { -not $_.Generated -and $_.Reason -notmatch 'public symbols already' })
            foreach ($s in $pub)  { "  skipped $([IO.Path]::GetFileName($s.File)): public symbols already available" }
            foreach ($s in $skip) { "  skipped $([IO.Path]::GetFileName($s.File)): $($s.Reason)" }
            "Built $($ok.Count) PDB(s); $($pub.Count) already public; skipped $($skip.Count). Store: $(Get-SymbolStore)"
        } @($files, $script:TxtGenSymPath.Text) $done
    })

    # ---------- Packages: one shared, verified tool store ----------
    function script:Install-Pkg([string]$Id, [bool]$Force) {
        if ($script:Busy['Pkg']) { & $script:Append 'Packages: a download is already running.'; return }
        $script:Busy['Pkg'] = $true
        $script:LblPkgStatus.Text = "Downloading $Id..."
        & $script:Append "Packages: download '$Id'$(if ($Force) { ' (redownload)' } else { '' })..."
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
            $btn.Content = if ($s.Installed) { 'Redownload' } else { 'Download' }
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
            $t3.Text = if ($s.Installed) { "Downloaded - $($s.ToolCount) tool(s)" } else { 'Not downloaded' }
            [void]$info.Children.Add($t1); [void]$info.Children.Add($t2); [void]$info.Children.Add($t3)
            [void]$row.Children.Add($info)

            $card.Child = $row
            [void]$script:PnlPackages.Children.Add($card)
        }
    }
    $script:BtnPkgInstallAll.Add_Click({
        if ($script:Busy['Pkg']) { & $script:Append 'Packages: a download is already running.'; return }
        $script:Busy['Pkg'] = $true; $script:LblPkgStatus.Text = 'Downloading all...'
        & $script:Append 'Packages: download / verify all...'
        $done = { $script:Busy['Pkg'] = $false; $script:LblPkgStatus.Text = 'Done.'; script:Build-PkgEditor }
        Start-ToolJob -Runspace $script:RsPkg -Script { Install-AllPackages | Out-Null } -OnText $script:Append -OnDone $done | Out-Null
    })
    $script:BtnPkgRefresh.Add_Click({ script:Build-PkgEditor })
    $script:BtnPkgOpen.Add_Click({
        Start-ToolJob -Runspace $script:RsPkg -Script { $d = Get-PackageRoot; New-Item -ItemType Directory -Path $d -Force | Out-Null; Start-Process explorer.exe $d; "opened $d" } -OnText $script:Append | Out-Null
    })

    # ---------- App self-update (stable follows releases; a branch build follows its branch head) ----------
    # Install context: ToolkitRoot is ...\src, so the install root is its parent. A branch build lives under
    # ...\branch\<name> and records the real branch in a .branch marker (the folder name is sanitised).
    $script:InstallRoot     = Split-Path $script:ToolkitRoot -Parent
    $script:IsBranchInstall = [bool]($script:InstallRoot -match '\\branch\\')
    $script:BranchName      = if (Test-Path (Join-Path $script:InstallRoot '.branch')) { (Get-Content (Join-Path $script:InstallRoot '.branch') -Raw).Trim() }
                              elseif ($script:IsBranchInstall) { Split-Path $script:InstallRoot -Leaf } else { '' }
    # A branch build shares the release VERSION number but runs different code - make it visibly distinct so
    # you can tell a branch install from the release (show the branch name + the installed commit sha).
    if ($script:BranchName) {
        $__sha = if (Test-Path (Join-Path $script:InstallRoot '.version')) { (Get-Content (Join-Path $script:InstallRoot '.version') -Raw).Trim() } else { '' }
        $__short = if ($__sha.Length -ge 7) { $__sha.Substring(0, 7) } else { $__sha }
        $script:LblVersion.Text = "v$ScriptVersion  (branch: $($script:BranchName)$(if ($__short) { "@$__short" } else { '' }))"
    }
    $script:UpdateAvailable = $false

    # Runs in the dedicated RsUpd runspace (self-contained, built-in cmdlets only) and returns ONE sentinel
    # line the UI parses. Stable = latest release tag; branch build = that branch's head sha.
    $script:UpdateCheckSB = {
        param($installRoot, $isBranch, $branchName)
        $Owner = 'mcpolo99'; $Repo = 'reporting-troubleshooting'; $ApiBase = "https://api.github.com/repos/$Owner/$Repo"
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $h = @{ 'User-Agent' = 'reporting-troubleshooting-update' }
        $verFile = Join-Path $installRoot '.version'
        $current = if (Test-Path $verFile) { (Get-Content $verFile -Raw).Trim() } else { '' }
        try {
            if ($isBranch) {
                $latest  = (Invoke-RestMethod "$ApiBase/commits/$branchName" -Headers $h).sha
                $chan    = "branch $branchName"
                $latDisp = $latest.Substring(0, 7)
                $curDisp = if ($current) { $current.Substring(0, [Math]::Min(7, $current.Length)) } else { '(unknown)' }
            } else {
                $latest  = (Invoke-RestMethod "$ApiBase/releases/latest" -Headers $h).tag_name
                $chan    = 'release'
                $latDisp = "$latest"; $curDisp = if ($current) { "$current" } else { '(unknown)' }
            }
            $avail = if ($current -and "$current" -ne "$latest") { 1 } else { 0 }
            "RTUPDATE|$avail|$curDisp|$latDisp|$chan"
        } catch { "RTUPDATE|err|$current||$($_.Exception.Message)" }
    }

    # Parses the sentinel on the UI thread and sets the button + status line.
    $script:OnUpdateText = {
        param($line)
        if ("$line" -notlike 'RTUPDATE|*') { & $script:Append $line; return }
        $p = "$line" -split '\|', 5
        $avail = $p[1]; $cur = $p[2]; $lat = $p[3]; $chan = $p[4]
        if ($avail -eq 'err') {
            $script:UpdateAvailable = $false
            $script:BtnPkgUpdate.Content = 'Check for updates'
            $script:LblPkgUpdate.Text = "Update check failed: $chan"
        } elseif ($avail -eq '1') {
            $script:UpdateAvailable = $true
            $script:BtnPkgUpdate.Content = "Update now -> $lat"
            $script:LblPkgUpdate.Text = "Update available ($chan): $cur -> $lat. Click 'Update now' to update and relaunch."
        } else {
            $script:UpdateAvailable = $false
            $script:BtnPkgUpdate.Content = 'Check for updates'
            $script:LblPkgUpdate.Text = "Up to date ($chan $lat)."
        }
    }

    function script:Check-ForUpdate {
        $script:LblPkgUpdate.Text = 'Checking for updates...'
        Start-ToolJob -Runspace $script:RsUpd -Script $script:UpdateCheckSB `
            -ArgList @($script:InstallRoot, $script:IsBranchInstall, $script:BranchName) -OnText $script:OnUpdateText | Out-Null
    }

    # Re-bootstrap via the online installer on the right channel; it installs the newer build and relaunches,
    # then this window closes. (Already elevated; Get.ps1 self-elevates anyway.)
    function script:Do-AppUpdate {
        $raw = 'https://raw.githubusercontent.com/mcpolo99/reporting-troubleshooting/main/src/Get.ps1'
        $cmd = if ($script:IsBranchInstall) { "& ([scriptblock]::Create((irm '$raw'))) -Branch `"$($script:BranchName)`"" }
               else { "& ([scriptblock]::Create((irm '$raw')))" }
        try {
            Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd)
            & $script:Append 'Update started in a new window - it will update the new version and reopen the app. Closing...'
            if ($script:MainWin) { $script:MainWin.Close() }
        } catch { & $script:Append "Could not start the update: $($_.Exception.Message)" }
    }

    $script:BtnPkgUpdate.Add_Click({
        if ($script:UpdateAvailable) { script:Do-AppUpdate } else { script:Check-ForUpdate }
    })

    # ---------- desktop shortcut ----------
    $script:BtnShortcut.Add_Click({
        try {
            $lnk = Install-DesktopShortcut -TargetBat (Join-Path $script:ToolkitRoot 'run.bat')
            & $script:Append "Desktop shortcut created: $lnk"
        } catch { & $script:Append "Shortcut creation failed: $($_.Exception.Message)" }
    })

    # ---------- initial load ----------
    foreach ($nTb in @($script:TxtPvSeconds, $script:TxtPvCircular, $script:TxtPvBuffer)) { script:Set-NumericOnly $nTb }
    script:Build-PvToggles
    # crash recovery: a trace left active by a previous (crashed/killed) session is aborted now
    if (Test-Path $script:PvActiveFile) { & $script:Append 'Found an orphaned PerfView trace from a previous session - aborting it.'; script:Stop-PerfViewHard }
    try { script:Load-PvAll } catch { & $script:Append "PerfView config load failed: $($_.Exception.Message)" }
    try { script:Build-MonEditor } catch { & $script:Append "Monitor config load failed: $($_.Exception.Message)" }
    try { script:Load-GenAll }     catch { & $script:Append "General settings load failed: $($_.Exception.Message)" }
    try { script:Build-PkgEditor } catch { & $script:Append "Package status load failed: $($_.Exception.Message)" }
    & $script:RefreshPv; & $script:RefreshMon
    # Non-blocking check on startup: enable the update button / status line if a newer build exists.
    try { script:Check-ForUpdate } catch { & $script:Append "Update check failed: $($_.Exception.Message)" }

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
            if ($script:TailCounter % 5 -eq 0) {
                script:Update-MonTail; script:Update-CompressionProgress   # ~1s cadence
                # Tell the global mark hook whether a capture is live, so Ctrl+Alt+M only overrides other apps
                # (swallows the key + fires a mark) while a trace is actually running.
                try { if ('RtHook.Hook' -as [type]) { [RtHook.Hook]::Active = [bool](Test-Path $script:PvActiveFile) } } catch {}
            }
        } catch { & $script:Append "Timer error: $($_.Exception.Message)" }
    })
    $timer.Start()

    # ---------- terminate an active PerfView trace on close / crash ----------
    # Graceful close signals the stop event so the capture finalizes (merge+zip); a crash aborts it
    # (Stop-PerfViewHard, data discarded). A hard kill that bypasses these is recovered on next startup
    # (orphan cleanup above). active.json is the live-trace flag.
    [System.AppDomain]::CurrentDomain.add_UnhandledException({ script:Stop-PerfViewHard })
    [System.AppDomain]::CurrentDomain.add_ProcessExit({ script:Stop-PerfViewHard })

    # Register the global mark hotkey once the window has an HWND (SourceInitialized fires inside ShowDialog).
    $w.Add_SourceInitialized({ script:Register-PvHotkey })

    $w.Add_Closed({
        $timer.Stop()
        script:Unregister-PvHotkey
        try {
            # Graceful close with a capture running: signal the stop event so PerfView finalizes (merge+zip)
            # on its own - the collect is an independent process and finishes after we exit. Only fall back
            # to a hard abort (discards data) if signalling fails.
            if (Test-Path $script:PvActiveFile) {
                Invoke-ToolSync -Runspace $script:RsPvCtl -Script { Send-StopEvent } | Out-Null
            }
        } catch { script:Stop-PerfViewHard }
        foreach ($rs in @($script:RsPv, $script:RsPvCtl, $script:RsPvMark, $script:RsMon, $script:RsPkg, $script:RsGen, $script:RsUpd)) { try { $rs.Close() } catch {} }
    })

    $script:MainWin = $w
    [void]$w.ShowDialog()
}
