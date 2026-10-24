# True when Windows apps use dark mode; $false if the setting can't be read.
function Get-SystemUsesDarkMode {
    try {
        $key = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction Stop
        if ($null -eq $key) { return $false }
        return $key.AppsUseLightTheme -eq 0
    }
    catch { return $false }
}
