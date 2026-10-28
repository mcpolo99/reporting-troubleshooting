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


# --- Dump file naming ---------------------------------------------------------------------------------------
# One scheme, one place: ProcDump_<pc>_<process>_<tag>_<yyyyMMdd>_<HHmmss>.dmp (6 '_'-delimited fields, the
# last two being the date and time). ProcDump cannot write the reason tag (one armed instance catches both
# exception and hang, and there is no filename token for the trigger), so the monitor captures with a
# placeholder tag and renames to the real tag once it has read the dump header - see ProcDumpMonitor.ps1.
$script:DumpNamePrefix = 'ProcDump'

# Sanitize a path component so a '_', space or illegal char can never break the delimited scheme. Keeps . and -
# (version-like tokens); everything else collapses to '-'. Empty -> $Fallback.
function ConvertTo-DumpToken([string]$Text, [string]$Fallback = 'unknown') {
    $t = ("$Text").Trim() -replace '[^A-Za-z0-9.-]', '-'
    $t = $t.Trim('-')
    if ($t) { $t } else { $Fallback }
}

# Capture reason tag from a parsed dump header: an exception record -> 'exception'; a hang trigger with no
# exception record -> 'hang'; otherwise 'manual'. Takes primitives (not the $info object) so it is unit-testable.
function Get-DumpTag {
    param([Nullable[uint32]]$Code, [string]$Trigger)
    if ($null -ne $Code) { return 'exception' }
    if ($Trigger -match '(?i)hang|hung|respond') { return 'hang' }
    return 'manual'
}

# Build the dump base filename (no directory) for a capture. A trailing .exe is stripped from the process token
# (ProcDump's PROCESSNAME expands WITH the extension on some builds), so names stay consistent and the token
# round-trips to the configured app name - only '.exe' is removed, so 'bSuite.NotRespondingHandler.exe' keeps its
# dotted base (#71).
function New-DumpFileName {
    param([string]$Computer, [string]$Process, [string]$Tag, [datetime]$When = (Get-Date))
    $proc = "$Process" -replace '(?i)\.exe$', ''
    '{0}_{1}_{2}_{3}_{4:yyyyMMdd_HHmmss}.dmp' -f $script:DumpNamePrefix,
        (ConvertTo-DumpToken $Computer 'pc'), (ConvertTo-DumpToken $proc 'app'),
        (ConvertTo-DumpToken $Tag 'manual'), $When
}

# The process token from a dump filename in our scheme, or $null if it does not match (e.g. a legacy name).
function Get-DumpProcessFromName([string]$FileName) {
    $p = [IO.Path]::GetFileNameWithoutExtension("$FileName") -split '_'
    if ($p.Count -ge 6 -and $p[0] -eq $script:DumpNamePrefix) { return $p[2] }
    return $null
}

