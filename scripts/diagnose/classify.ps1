<#
.SYNOPSIS
    Symptom-keyword classification for diagnose.ps1.
.DESCRIPTION
    Maps free-text symptom descriptions to diagnostic domains via keyword
    matching with disambiguation rules. Dot-sourced by diagnose.ps1.
#>

# Idempotency guard — re-sourcing must not redefine.
if (Get-Command 'Classify-Symptom' -ErrorAction SilentlyContinue) { return }

# ============================================================================
# Keyword → Domain map (script-scoped so callers can extend at runtime)
# ============================================================================
$script:KeywordMap = @{
    dpc    = @('mouse','input','cursor','stutter','polling','hid','razer','keyboard',
               'freeze','micro-stutter','lag input','usb','interrupt','dpc')
    gpu    = @('frame','fps','hitch','gpu','nvidia','gsync','g-sync','tearing',
               'rtss','reflex','drop','render','display','flicker','screen',
               'present','frametime','frame time')
    net    = @('ping','packet','network','dns','tcp','wifi','nic','bufferbloat',
               'jitter','disconnect','latency','bandwidth','i226')
    system = @('audit','health','defender','bios','service','registry','slow',
               'sluggish','windows update','boot','memory','process','bloat')
    audio  = @('audio','warble','sound','pitch','hdmi audio','speaker',
               'headphone','crackle','pop','glitch')
}

# Audio maps to dpc domain (audio issues are DPC-rooted)
$script:AudioDomain = 'dpc'

# ============================================================================
# Classify-Symptom — pure function over $script:KeywordMap
# ============================================================================
function Classify-Symptom {
    param([string]$Text)

    $lower = $Text.ToLower()
    $matches = @{}

    foreach ($domainKey in $script:KeywordMap.Keys) {
        $matched = @()
        foreach ($kw in $script:KeywordMap[$domainKey]) {
            if ($lower.Contains($kw)) {
                $matched += $kw
            }
        }
        if ($matched.Count -gt 0) {
            $effectiveDomain = $domainKey
            if ($domainKey -eq 'audio') { $effectiveDomain = $script:AudioDomain }
            if (-not $matches.ContainsKey($effectiveDomain)) {
                $matches[$effectiveDomain] = @()
            }
            $matches[$effectiveDomain] += $matched
        }
    }

    # Disambiguate "stutter" — if "input" or "mouse" also present, it's dpc
    if ($matches.ContainsKey('gpu') -and $matches.ContainsKey('dpc')) {
        $gpuOnly = @()
        foreach ($kw in $matches['gpu']) {
            if ($kw -ne 'stutter') { $gpuOnly += $kw }
        }
        if ($gpuOnly.Count -eq 0) {
            $matches.Remove('gpu')
        }
    }

    # Disambiguate "lag" — if "input" also present, it's dpc not net
    if ($matches.ContainsKey('net') -and $matches.ContainsKey('dpc')) {
        $netOnly = @()
        foreach ($kw in $matches['net']) {
            if ($kw -ne 'lag' -and $kw -ne 'latency') { $netOnly += $kw }
        }
        if ($netOnly.Count -eq 0) {
            $matches.Remove('net')
        }
    }

    if ($matches.Count -eq 0) {
        return @{
            domain          = 'system'
            confidence      = 'low'
            matchedKeywords = @()
            allMatches      = @{}
            ambiguous       = $false
        }
    }

    if ($matches.Count -eq 1) {
        $dom = @($matches.Keys)[0]
        $kws = $matches[$dom]
        $conf = 'medium'
        if ($kws.Count -ge 2) { $conf = 'high' }
        return @{
            domain          = $dom
            confidence      = $conf
            matchedKeywords = $kws
            allMatches      = $matches
            ambiguous       = $false
        }
    }

    # Multiple domains matched — pick highest keyword count, flag ambiguous
    $best = ''
    $bestCount = 0
    foreach ($d in $matches.Keys) {
        if ($matches[$d].Count -gt $bestCount) {
            $bestCount = $matches[$d].Count
            $best = $d
        }
    }
    return @{
        domain          = $best
        confidence      = 'medium'
        matchedKeywords = $matches[$best]
        allMatches      = $matches
        ambiguous       = $true
    }
}
