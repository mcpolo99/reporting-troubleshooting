# Applies light/dark theme brushes (keyed to the XAML DynamicResource names) to a window and merges
# SharedStyles.xaml from $script:SharedStylesSchema.
function Set-WindowThemeResources {
    param($window, [bool]$usesDarkMode)

    $ThemeColor = @{
        AppBgColor    = @{ Light = '#f3f3f3'; Dark = '#1e1e24' }
        AppFgColor    = @{ Light = '#000000'; Dark = '#f2f2f7' }
        AppIdColor    = @{ Light = '#666666'; Dark = '#9a9aa6' }
        AppAccentColor = @{ Light = '#0067c0'; Dark = '#4aa3ff' }
        CardBgColor   = @{ Light = '#fbfbfb'; Dark = '#2d2d37' }
        CardHoverColor = @{ Light = '#eef3fb'; Dark = '#3a3a46' }
    }

    $theme = if ($usesDarkMode) { 'Dark' } else { 'Light' }
    foreach ($entry in $ThemeColor.GetEnumerator()) {
        $window.Resources[$entry.Key] = [System.Windows.Media.SolidColorBrush]::new(
            [System.Windows.Media.ColorConverter]::ConvertFromString($entry.Value[$theme]))
    }

    if (-not $window.Resources.Contains('AppSharedStylesLoaded') -and
        $script:SharedStylesSchema -and (Test-Path $script:SharedStylesSchema)) {
        $sharedXaml = Get-Content -Path $script:SharedStylesSchema -Raw
        $sharedReader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($sharedXaml))
        try {
            $sharedDict = [System.Windows.Markup.XamlReader]::Load($sharedReader)
            $window.Resources.MergedDictionaries.Add($sharedDict)
            $window.Resources['AppSharedStylesLoaded'] = $true
        }
        finally { $sharedReader.Close() }
    }
}
