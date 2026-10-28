#Requires -Version 5.1
<#
.SYNOPSIS
  Encode the fleet telemetry endpoints + send-only key into the opaque blob the client reads, and decode one
  back to verify.

  By default it PRINTS the blob to paste into Common\Telemetry.ps1 ($script:TelemetryBlob) - that blob ships
  with the build, so machines get the endpoints with the normal update and need no manual step. -Save instead
  writes a local, untracked per-machine override file. Encoding only keeps the URL/key out of clear text / out
  of grep - it is still a public send-only ingest key; this is obfuscation, not secrecy. Never put the CLEAR
  values in git - only the encoded blob.

.USAGE
  # print the blob to paste into Common\Telemetry.ps1 (ships with updates; client appends /v1/events,
  # /v1/known-signatures, /v1/dumps to the host):
  .\New-TelemetryBlob.ps1 -BaseUrl https://telemetry.example.com -DeviceKey ftk_xxx

  # or write a per-machine local override instead of editing source:
  .\New-TelemetryBlob.ps1 -BaseUrl https://telemetry.example.com -DeviceKey ftk_xxx -Save

  # or distinct hosts:
  .\New-TelemetryBlob.ps1 -EventSink https://a -KnownSource https://b -DumpTarget https://c -DeviceKey ftk_xxx

  # verify a blob (prints the decoded endpoints; key is shown masked):
  .\New-TelemetryBlob.ps1 -Decode <blob>
#>
[CmdletBinding(DefaultParameterSetName = 'Encode')]
param(
    [Parameter(ParameterSetName = 'Encode')][string]$BaseUrl,
    [Parameter(ParameterSetName = 'Encode')][string]$EventSink,
    [Parameter(ParameterSetName = 'Encode')][string]$KnownSource,
    [Parameter(ParameterSetName = 'Encode')][string]$DumpTarget,
    [Parameter(ParameterSetName = 'Encode')][string]$DeviceKey,
    [Parameter(ParameterSetName = 'Encode')][switch]$Save,   # write the blob to the local untracked file instead of printing it
    [Parameter(ParameterSetName = 'Decode', Mandatory)][string]$Decode
)
$BlobFile = Join-Path $env:ProgramData 'ReportingTroubleshooting\Monitor\telemetry.blob'

function Encode-Blob([hashtable]$o) {
    $json  = ($o | ConvertTo-Json -Compress)
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $out   = New-Object System.IO.MemoryStream
    $gz    = New-Object System.IO.Compression.GZipStream($out, [System.IO.Compression.CompressionMode]::Compress)
    $gz.Write($bytes, 0, $bytes.Length); $gz.Close()
    [Convert]::ToBase64String($out.ToArray())
}
function Decode-Blob([string]$b) {
    $bytes = [Convert]::FromBase64String($b)
    $in = New-Object System.IO.MemoryStream (,$bytes)
    $gz = New-Object System.IO.Compression.GZipStream($in, [System.IO.Compression.CompressionMode]::Decompress)
    $sr = New-Object System.IO.StreamReader($gz)
    $json = $sr.ReadToEnd(); $sr.Close()
    $json | ConvertFrom-Json
}

if ($PSCmdlet.ParameterSetName -eq 'Decode') {
    $o = Decode-Blob $Decode
    $mask = if ("$($o.key)".Length -gt 10) { "$($o.key)".Substring(0, 6) + '...' + "$($o.key)".Substring("$($o.key)".Length - 4) } else { '(set)' }
    [pscustomobject]@{ EventSink = $o.e; KnownSource = $o.k; DumpTarget = $o.d; DeviceKey = $mask } | Format-List
    return
}

if ($BaseUrl) { if (-not $EventSink) { $EventSink = $BaseUrl }; if (-not $KnownSource) { $KnownSource = $BaseUrl }; if (-not $DumpTarget) { $DumpTarget = $BaseUrl } }
if (-not ($EventSink -and $KnownSource -and $DumpTarget -and $DeviceKey)) {
    Write-Error 'Provide -BaseUrl (or all three endpoints) and -DeviceKey.'; return
}
$blob = Encode-Blob @{ e = $EventSink.TrimEnd('/'); k = $KnownSource.TrimEnd('/'); d = $DumpTarget.TrimEnd('/'); key = $DeviceKey }
if ($Save) {
    $dir = Split-Path -Parent $BlobFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -LiteralPath $BlobFile -Value $blob -Encoding ASCII
    Write-Host "Wrote the telemetry blob to $BlobFile (local, untracked - never commit this)."
} else {
    Write-Host "Paste this into Common\Telemetry.ps1 as  `$script:TelemetryBlob = '<blob>'  (ships with updates),"
    Write-Host "or re-run with -Save to write a local per-machine override at $BlobFile :"
    Write-Host ''
    Write-Host $blob
}
