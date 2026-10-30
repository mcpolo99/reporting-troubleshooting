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

# The human CAPTURE REASON out of ProcDump's comment stream. ProcDump records its full command line as the
# first "*** ..." line - which echoes our output-filename TEMPLATE with the literal, UNEXPANDED tokens
# (PROCESSNAME / YYMMDD / HHMMSS) and the local procdump path. That line is noise (and a local-path leak), so
# we drop any line mentioning procdump and keep only the real reason line(s) (e.g. "Hung window detected: ..").
# Returns the joined reason, or $null.
function Get-DumpReason([string]$Comment) {
    if (-not $Comment) { return $null }
    $lines  = @("$Comment" -split "`r?`n" | ForEach-Object { ($_ -replace '^\*+\s*', '').Trim() } | Where-Object { $_ })
    $reason = @($lines | Where-Object { $_ -notmatch '(?i)procdump(64|64a)?(\.exe)?["\s]' })
    if (-not $reason.Count) { $reason = $lines }   # fallback: nothing matched the filter - keep what we have
    if ($reason.Count) { $reason -join '; ' } else { $null }
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

# The computer token from a dump filename. Handles the current scheme (ProcDump_<pc>_<proc>_<tag>_<date>_<time>,
# field 1) and the legacy <proc>.exe_<machine>_<date>_<time> (field 1 of 4). The capturing box stamps its own
# name into the filename, so this is the authoritative machine id off-box (where the capturing host's
# $env:COMPUTERNAME would be wrong). $null if the name matches no known scheme.
function Get-DumpComputerFromName([string]$FileName) {
    $stem = [IO.Path]::GetFileNameWithoutExtension("$FileName") -replace '\.dmp$', ''   # tolerate a .dmp.gz double ext
    $p = $stem -split '_'
    if ($p.Count -ge 6 -and $p[0] -eq $script:DumpNamePrefix) { return $p[1] }           # ProcDump_<pc>_...
    if ($p.Count -eq 4 -and $p[0] -match '(?i)\.exe$') { return $p[1] }                   # legacy <proc>.exe_<machine>_<date>_<time>
    return $null
}


# The FINAL dump name for a placeholder, once triage knows the real tag. ProcDump writes a placeholder with the
# tag field set to 'pending' (it cannot know exception-vs-hang at capture); triage replaces just that field.
# Returns the final '<...>.dmp' name, or $null if the placeholder does not match the scheme (caller rebuilds via
# New-DumpFileName). Pure/testable.
function Get-RestingDumpName([string]$PlaceholderName, [string]$Tag) {
    $tag = ConvertTo-DumpToken $Tag 'manual'
    $stem = [IO.Path]::GetFileNameWithoutExtension("$PlaceholderName")
    $p = $stem -split '_'
    if ($p.Count -ge 6 -and $p[0] -eq $script:DumpNamePrefix) { $p[3] = $tag; return (($p -join '_') + '.dmp') }
    return $null
}


# --- Device ledger location -----------------------------------------------------------------------------------
# The single local dedup store (state/count/sample per signature). Read/write + the collect decision live in
# Ledger.ps1; the PATH lives here (dump engine) so the detached triage worker and the flush can both reach it.
function Get-DeviceLedgerPath([string]$Dir) {
    if (-not $Dir) { $Dir = Get-KnownIssuesDir }
    Join-Path $Dir 'device-ledger.json'
}

