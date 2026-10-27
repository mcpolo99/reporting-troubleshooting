# Dump engine: shared primitives (machine key, short hash, KnownIssues dir). Dot-sourced via ..\DumpId.ps1.


function Get-KnownIssuesDir {
    Join-Path $env:ProgramData 'ReportingTroubleshooting\Monitor\KnownIssues'
}


# Stable, unique per physical machine (survives rename; unlike COMPUTERNAME which can collide/change).
function Get-MachineKey {
    try {
        $g = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
        if ($g) { return "$g".Trim() }
    } catch {}
    return $env:COMPUTERNAME     # last-resort fallback
}


# First 16 hex chars (64 bits) of SHA-256 of the lowercased canonical string. 64 bits is collision-safe
# for this volume and short enough for an issue title.
function Get-ShortHash([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text.ToLowerInvariant())
        $h = $sha.ComputeHash($bytes)
        -join (0..7 | ForEach-Object { '{0:x2}' -f $h[$_] })
    } finally { $sha.Dispose() }
}

