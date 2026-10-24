<#
    .SYNOPSIS
        Returns whether Windows apps are configured to use dark mode.
    .OUTPUTS
        System.Boolean. $false when the personalization setting cannot be read.
#>
function Get-SystemUsesDarkMode {
    try {
        $key = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction Stop
        if ($null -eq $key) { return $false }
        return $key.AppsUseLightTheme -eq 0
    }
    catch { return $false }
}
