# =============================================================================
# Reporting & Troubleshooting toolset - shared helper component
# =============================================================================
# Stateless helpers shared across the tools. Dot-source it; nothing here keeps state.
# =============================================================================

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
