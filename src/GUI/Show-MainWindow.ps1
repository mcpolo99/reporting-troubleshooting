<#
    .SYNOPSIS
        Creates and displays the toolset main window. Loads Schemas\MainWindow.xaml, applies the theme
        + shared styles, and wires each tool card to Start-Tool. Requires an STA desktop session.
    .NOTES
        Dot-sourced by ReportingToolkit.ps1, so it uses that script's $ScriptVersion, $script:*Schema
        paths, the tool path variables and Start-Tool / Set-WindowThemeResources / Get-SystemUsesDarkMode.
#>
function Show-MainWindow {
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop

    $xaml   = Get-Content -Path $script:MainWindowSchema -Raw
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
    try { $window = [System.Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Close() }

    Set-WindowThemeResources -window $window -usesDarkMode (Get-SystemUsesDarkMode)

    $window.FindName('LblVersion').Text = "v$ScriptVersion"
    $window.FindName('BtnPerfView').Add_Click({ Start-Tool $script:ToolPerfView })
    $window.FindName('BtnMonitor').Add_Click({ Start-Tool $script:ToolMonitor })
    $window.FindName('BtnCase').Add_Click({ Start-Tool $script:ToolCase })
    $window.FindName('BtnClose').Add_Click({ $window.Close() })

    [void]$window.ShowDialog()
}
