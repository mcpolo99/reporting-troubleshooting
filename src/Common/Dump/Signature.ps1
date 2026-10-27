# Dump engine: stable fault signature (scheme-versioned canonical string -> short id).


# Signature SCHEME version. It is baked into every canonical string (so it is part of the hash) AND reported
# on each event (ids.signatureScheme). Bump it ONLY when the recipe that forms the canonical string changes
# (different frame count, extra fields, normalisation change). Bumping makes new ids provably distinct from
# old ones instead of silently colliding/drifting, so historical data stays valid and the centre can map
# old->new on its own terms. Do NOT bump for ordinary app/build changes - a crash is build-scoped by its
# module+offset already, and cross-build grouping is the Layer-2 issue's job, not the signature's.
$script:SIG_SCHEME = 1


# Builds the canonical id string + short id from a signature. For Tier-2 kinds (hang / managed
# exception) the id needs the managed frames; if $sig.Frames is empty the id is PROVISIONAL (Tier-1
# fallback) and WalkPending is $true - the caller should run Invoke-DumpWalk and recompute.
function Get-DumpStableId($Sig, [int]$TopN = 8) {
    if (-not $Sig) { return $null }
    $walkPending = $false
    switch ($Sig.Kind) {
        'crash' {
            $loc = if ($Sig.Module) { '{0}+0x{1:x}' -f $Sig.Module, $Sig.Offset } else { '0x{0:x}' -f $Sig.Address }
            $canonical = 't1|{0}|{1}' -f $Sig.Code, $loc
        }
        default {
            # hang or managed-exception: identity = the top N normalised managed frames (leaf-first); a
            # managed exception also pins its exception type. These come from Invoke-DumpWalk.
            if ($Sig.Frames -and $Sig.Frames.Count) {
                $top = @($Sig.Frames | Select-Object -First $TopN) -join '|'
                $canonical = if ($Sig.Kind -eq 'hang') { 't2h|{0}' -f $top }
                             else { 't2m|{0}|{1}' -f "$($Sig.ExceptionType)", $top }
            } else {
                # provisional until a stack walk fills Frames - this id MUST NOT be used to suppress
                $walkPending = $true
                $loc = if ($Sig.Module) { '{0}+0x{1:x}' -f $Sig.Module, $Sig.Offset } else { '0x{0:x}' -f $Sig.Address }
                $canonical = 't1prov|{0}|{1}|{2}' -f $Sig.Kind, $Sig.Code, $loc
            }
        }
    }
    # Bake the scheme version into the canonical string so the id is tied to the recipe that produced it
    # (part of the hash) and a future recipe change yields provably distinct ids instead of silent drift.
    $canonical = 's{0}|{1}' -f $script:SIG_SCHEME, $canonical
    [pscustomobject]@{
        Id          = Get-ShortHash $canonical
        Kind        = $Sig.Kind
        Scheme      = $script:SIG_SCHEME
        Canonical   = $canonical
        WalkPending = $walkPending
    }
}

