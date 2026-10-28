# Shared stateless helpers. Dot-source it.

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ConsoleUser {
    try { $u = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch { $u = $null }
    if ($u) { $u } else { "$env:USERDOMAIN\$env:USERNAME" }
}

# Valid Authenticode signature from Microsoft. Used to gate every tool binary we run / download.
function Test-MicrosoftSignature([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try { $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop } catch { return $false }
    return ($sig.Status -eq 'Valid' -and $sig.SignerCertificate -and $sig.SignerCertificate.Subject -match 'O=Microsoft Corporation')
}

function Get-ScriptVersionFromFile([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $m = Select-String -LiteralPath $Path -Pattern '^\$ScriptVersion\s*=\s*''([\d\.]+)''' -List -ErrorAction SilentlyContinue
    if ($m) { [version]$m.Matches[0].Groups[1].Value } else { [version]'0.0.0' }
}

function Format-Version($v) {
    if ($null -eq $v) { 'not installed' } elseif ($v -eq [version]'0.0.0') { 'unversioned' } else { "$v" }
}

# --- interactive prompts (Enter keeps the current value) ---
function Read-Value([string]$Prompt, $Current) {
    $v = Read-Host "$Prompt [$Current]"
    if ([string]::IsNullOrWhiteSpace($v)) { $Current } else { $v.Trim() }
}

function Read-Int([string]$Prompt, [int]$Current, [int]$Min = 1) {
    while ($true) {
        $v = Read-Value $Prompt $Current
        $n = 0
        if ([int]::TryParse("$v", [ref]$n) -and $n -ge $Min) { return $n }
        Write-Host "Enter a whole number >= $Min." -ForegroundColor Yellow
    }
}

function Read-Bool([string]$Prompt, [bool]$Current) {
    (Read-Value "$Prompt (y/n)" ($(if ($Current) { 'y' } else { 'n' }))) -match '^(y|yes|true|1)$'
}

# --- ProcDump argument toggles (settings UI <-> the ProcDumpArgs string, #53) ---------------------------------
# -accepteula is always required and implied, never a toggle. The meaningful switches map to checkboxes and a
# count so the UI never shows a raw arg string. Order mirrors the shipped default: -accepteula -ma -e[ 1] -h -n N -w.
function ConvertFrom-ProcDumpArgs {
    param([string]$Arguments)
    $t = @(("$Arguments") -split '\s+' | Where-Object { $_ })
    $n = 1
    for ($i = 0; $i -lt $t.Count; $i++) { if ($t[$i] -ieq '-n' -and $i + 1 -lt $t.Count) { [void][int]::TryParse($t[$i + 1], [ref]$n) } }
    $e = $false; $fc = $false
    for ($i = 0; $i -lt $t.Count; $i++) { if ($t[$i] -ieq '-e') { $e = $true; if ($i + 1 -lt $t.Count -and $t[$i + 1] -eq '1') { $fc = $true } } }
    [ordered]@{
        FullDump        = [bool]($t -contains '-ma')
        OnException     = $e
        FirstChance     = $fc
        OnHang          = [bool]($t -contains '-h')
        WaitForProcess  = [bool]($t -contains '-w')
        DumpsPerSession = [Math]::Max($n, 1)
    }
}

function ConvertTo-ProcDumpArgs {
    param($Toggles)
    $a = @('-accepteula')
    if ($Toggles.FullDump)    { $a += '-ma' }
    if ($Toggles.FirstChance) { $a += @('-e', '1') } elseif ($Toggles.OnException) { $a += '-e' }
    if ($Toggles.OnHang)      { $a += '-h' }
    $n = 1; if ($Toggles.DumpsPerSession) { [void][int]::TryParse("$($Toggles.DumpsPerSession)", [ref]$n) }; if ($n -lt 1) { $n = 1 }
    $a += @('-n', "$n")
    if ($Toggles.WaitForProcess) { $a += '-w' }
    $a -join ' '
}

# Parse a telemetry-log line (Write-Log format) into a dump-compression display message + progress percent (#65).
# Returns $null for a non-compression line. Percent: NN% while compressing, 100 when done, 0 at the start line,
# else -1 (message only, no bar change). Pure, so the GUI's live indicator can be unit-tested.
function Get-CompressionProgressLine {
    param([string]$Line)
    if ("$Line" -notmatch 'compress(ing|ed) ') { return $null }
    $msg = "$Line" -replace '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \[.+?\] \[PID \d+\]\s*', ''
    $pct = -1
    if     ($Line -match 'compressing .+?: (\d+)%')      { $pct = [int]$matches[1] }
    elseif ($Line -match 'compressed ')                  { $pct = 100 }
    elseif ($Line -match 'compressing .+ before upload') { $pct = 0 }
    [ordered]@{ Text = $msg; Percent = $pct }
}
