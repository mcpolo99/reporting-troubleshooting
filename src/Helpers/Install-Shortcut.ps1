# Desktop shortcut to the offline launcher (run.bat), with a generated "RT" icon so it is easy to spot.
# The icon is rendered on the fly (no binary asset in the repo) into %LOCALAPPDATA%\ReportingTroubleshooting.

# Renders a 256x256 blue tile with white bold "RT" and writes it as a PNG-compressed .ico (Win Vista+).
function New-RtIcon {
    param([Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $size = 256
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $g.Clear([System.Drawing.ColorTranslator]::FromHtml('#0067C0'))   # same blue as the app accent
        $font = New-Object System.Drawing.Font('Segoe UI', 118, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $sf   = New-Object System.Drawing.StringFormat
        $sf.Alignment = [System.Drawing.StringAlignment]::Center
        $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
        $rect = New-Object System.Drawing.RectangleF(0, 0, $size, $size)
        $g.DrawString('RT', $font, [System.Drawing.Brushes]::White, $rect, $sf)
        $font.Dispose(); $sf.Dispose()
    } finally { $g.Dispose() }

    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    $png = $ms.ToArray(); $ms.Dispose()

    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create)
    $bw = New-Object System.IO.BinaryWriter($fs)
    try {
        $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]1)   # ICONDIR: reserved, type=icon, count=1
        $bw.Write([byte]0); $bw.Write([byte]0)                             # width/height 0 => 256
        $bw.Write([byte]0); $bw.Write([byte]0)                             # palette, reserved
        $bw.Write([uint16]1); $bw.Write([uint16]32)                        # planes, bpp
        $bw.Write([uint32]$png.Length); $bw.Write([uint32]22)             # image size, offset (6+16)
        $bw.Write($png)
        $bw.Flush()
    } finally { $bw.Dispose(); $fs.Dispose() }
}

# Creates (or refreshes) a Desktop shortcut to $TargetBat with the generated icon. Returns the .lnk path.
function Install-DesktopShortcut {
    param(
        [Parameter(Mandatory)][string]$TargetBat,
        [string]$Name = 'Reporting & Troubleshooting'
    )
    if (-not (Test-Path $TargetBat)) { throw "Launcher not found: $TargetBat" }
    $iconDir = Join-Path $env:ProgramData 'ReportingTroubleshooting\Icons'
    New-Item -ItemType Directory -Path $iconDir -Force | Out-Null
    $ico = Join-Path $iconDir 'rt.ico'
    New-RtIcon -Path $ico

    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "$Name.lnk"
    $sh  = New-Object -ComObject WScript.Shell
    try {
        $s = $sh.CreateShortcut($lnk)
        $s.TargetPath       = $TargetBat
        $s.WorkingDirectory = Split-Path $TargetBat -Parent
        $s.IconLocation     = "$ico,0"
        $s.Description       = 'Reporting & Troubleshooting toolset'
        $s.WindowStyle       = 1
        $s.Save()
    } finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh) }
    return $lnk
}
