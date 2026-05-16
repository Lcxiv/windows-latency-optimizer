<#
.SYNOPSIS
    Diagnostic dispatcher — triage symptoms and run domain-specific diagnostics.
.DESCRIPTION
    Interactive or CLI-driven dispatcher that classifies symptoms, runs the
    relevant diagnostic scripts, and produces a scored JSON report with
    recommendations.

    No args → interactive menu. Pass -Symptom for keyword classification or
    -Domain to skip classification and run a specific domain directly.
.PARAMETER Symptom
    Free-text symptom description. Keywords are matched to domains automatically.
.PARAMETER Domain
    Direct domain selection: dpc, gpu, net, system, all.
.PARAMETER Quick
    Only run diagnostics that do not require admin elevation.
.PARAMETER Interactive
    Force interactive menu (default when no args are provided).
.PARAMETER OutputDir
    Override output directory (default: captures\diagnostics).
.PARAMETER MonitorOutput
    Also write diagnose_latest.js for the live monitoring dashboard.
.EXAMPLE
    .\diagnose.ps1
    .\diagnose.ps1 -Symptom "mouse stutters in Fortnite"
    .\diagnose.ps1 -Domain dpc -Quick
    .\diagnose.ps1 -Domain all
.NOTES
    PowerShell 5.1 compatible. Most full diagnostics require admin elevation.
#>
param(
    [string]$Symptom = '',
    [ValidateSet('','dpc','gpu','net','system','all')]
    [string]$Domain = '',
    [switch]$Quick,
    [switch]$Interactive,
    [string]$OutputDir = '',
    [switch]$MonitorOutput
)

$ErrorActionPreference = 'Continue'
$projectRoot = Split-Path $PSScriptRoot -Parent
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$timestampIso = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'

# ============================================================================
# Admin detection
# ============================================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

# ============================================================================
# Output directory
# ============================================================================
if ($OutputDir -eq '') {
    $OutputDir = Join-Path $projectRoot 'captures\diagnostics'
}
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# ============================================================================
# Keyword → Domain classification
# ============================================================================
$keywordMap = @{
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
$audioDomain = 'dpc'

function Classify-Symptom {
    param([string]$Text)

    $lower = $Text.ToLower()
    $matches = @{}

    foreach ($domainKey in $keywordMap.Keys) {
        $matched = @()
        foreach ($kw in $keywordMap[$domainKey]) {
            if ($lower.Contains($kw)) {
                $matched += $kw
            }
        }
        if ($matched.Count -gt 0) {
            $effectiveDomain = $domainKey
            if ($domainKey -eq 'audio') { $effectiveDomain = $audioDomain }
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

# ============================================================================
# Domain → Script definitions
# ============================================================================
function Get-DomainScripts {
    param([string]$DomainName)

    $scripts = @()

    switch ($DomainName) {
        'dpc' {
            $scripts += @{
                script       = 'analyze_affinity_overlap.ps1'
                args         = @()
                requireAdmin = $false
                domain       = 'dpc'
            }
            $scripts += @{
                script       = 'audio_diag.ps1'
                args         = @()
                requireAdmin = $false
                domain       = 'dpc'
            }
            $scripts += @{
                script       = 'diagnose-mouse.ps1'
                args         = @('-DurationSec', '10')
                requireAdmin = $true
                domain       = 'dpc'
            }
        }
        'gpu' {
            $scripts += @{
                script       = 'hw_pcie_state.ps1'
                args         = @('-OutDir', $OutputDir, '-Phase', 'diag')
                requireAdmin = $false
                domain       = 'gpu'
            }
            $scripts += @{
                script       = 'hw_gpu_ecc.ps1'
                args         = @('-OutDir', $OutputDir, '-DurationSec', '10', '-Phase', 'diag')
                requireAdmin = $false
                domain       = 'gpu'
            }
        }
        'net' {
            $scripts += @{
                script       = 'hw_nic_errors.ps1'
                args         = @('-OutDir', $OutputDir, '-Mode', 'Snap', '-Phase', 'diag')
                requireAdmin = $false
                domain       = 'net'
            }
        }
        'system' {
            $scripts += @{
                script       = 'audit.ps1'
                args         = @('-Mode', 'Quick', '-Quiet')
                requireAdmin = $true
                domain       = 'system'
            }
            $scripts += @{
                script       = 'health-check.ps1'
                args         = @()
                requireAdmin = $true
                domain       = 'system'
            }
        }
    }

    return $scripts
}

# ============================================================================
# Interactive menu
# ============================================================================
function Show-Menu {
    Write-Host ''
    Write-Host ([char]0x2554 + ([string][char]0x2550 * 54) + [char]0x2557) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '  Windows Latency Optimizer - Diagnostic Dispatcher   ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2560 + ([string][char]0x2550 * 54) + [char]0x2563) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '                                                      ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '  [1] Input / Mouse          Mouse stutter, HID gaps, ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '                             polling, Razer issues     ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '  [2] GPU / Frames           Frame drops, hitches,     ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '                             clocks, G-Sync, tearing   ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '  [3] Network                Ping spikes, packet loss, ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '                             bufferbloat, DNS           ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '  [4] System Health          Full audit, Defender,     ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '                             services, registry         ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '  [5] Audio                  Warble, glitches, HDMI    ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '                             audio pitch shift          ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '  [6] Full Diagnostic        All domains (slowest)     ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '                                                      ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '  [0] Describe symptom       Type what''s wrong         ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '                                                      ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x255A + ([string][char]0x2550 * 54) + [char]0x255D) -ForegroundColor Cyan
    Write-Host ''

    $choice = Read-Host 'Select option'

    switch ($choice) {
        '1' { return 'dpc'    }
        '2' { return 'gpu'    }
        '3' { return 'net'    }
        '4' { return 'system' }
        '5' { return 'dpc'    }  # audio → dpc domain
        '6' { return 'all'    }
        '0' {
            $userSymptom = Read-Host 'Describe your symptom'
            if ($userSymptom -eq '') {
                Write-Host 'No symptom entered, defaulting to system health.' -ForegroundColor Yellow
                return 'system'
            }
            $script:Symptom = $userSymptom
            return '__classify__'
        }
        default {
            Write-Host ('Invalid choice: ' + $choice) -ForegroundColor Red
            return ''
        }
    }
}

# ============================================================================
# Resolve ambiguous classification interactively
# ============================================================================
function Resolve-Ambiguity {
    param([hashtable]$Classification)

    Write-Host ''
    Write-Host 'Multiple domains matched your symptom:' -ForegroundColor Yellow
    $idx = 1
    $domList = @($Classification.allMatches.Keys)
    foreach ($d in $domList) {
        $kws = $Classification.allMatches[$d] -join ', '
        Write-Host ('  [' + $idx + '] ' + $d.ToUpper() + ' (matched: ' + $kws + ')')
        $idx++
    }
    Write-Host ('  [' + $idx + '] Run ALL matched domains')
    Write-Host ''
    $pick = Read-Host 'Pick a domain'

    $pickInt = 0
    if ([int]::TryParse($pick, [ref]$pickInt)) {
        if ($pickInt -ge 1 -and $pickInt -le $domList.Count) {
            return $domList[$pickInt - 1]
        }
        if ($pickInt -eq ($domList.Count + 1)) {
            return 'all'
        }
    }
    # Default to best match
    return $Classification.domain
}

# ============================================================================
# Run a single diagnostic script
# ============================================================================
function Invoke-DiagnosticScript {
    param([hashtable]$ScriptDef)

    $scriptPath = Join-Path $PSScriptRoot $ScriptDef.script
    $result = [ordered]@{
        script       = $ScriptDef.script
        domain       = $ScriptDef.domain
        status       = 'pending'
        exitCode     = -1
        durationMs   = 0
        summary      = ''
        requiresAdmin = $ScriptDef.requireAdmin
        output       = ''
    }

    # Check if script exists
    if (-not (Test-Path $scriptPath)) {
        $result.status = 'missing'
        $result.summary = 'Script not found: ' + $ScriptDef.script
        return $result
    }

    # Skip admin-required scripts when not elevated (or -Quick mode)
    if ($ScriptDef.requireAdmin -and (-not $isAdmin -or $Quick)) {
        $result.status = 'skipped'
        if ($Quick) {
            $result.summary = 'Skipped (-Quick mode, requires admin)'
        } else {
            $result.summary = 'Skipped (requires admin elevation)'
        }
        return $result
    }

    $label = '[' + $ScriptDef.domain + ']'
    Write-Host ('' + $label + ' Running ' + $ScriptDef.script + '...') -ForegroundColor Yellow

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $output = & $scriptPath @($ScriptDef.args) 2>&1 | Out-String
        $result.exitCode = $LASTEXITCODE
        if ($null -eq $result.exitCode) { $result.exitCode = 0 }
        $result.output = $output
        $result.status = 'completed'
        $result.summary = Extract-Summary $output $ScriptDef.script
    }
    catch {
        $result.status = 'error'
        $result.exitCode = 1
        $result.summary = 'Error: ' + $_.Exception.Message
        $result.output = $_.Exception.Message
    }
    $sw.Stop()
    $result.durationMs = [int]$sw.ElapsedMilliseconds

    return $result
}

# ============================================================================
# Extract a one-line summary from script output
# ============================================================================
function Extract-Summary {
    param([string]$Output, [string]$ScriptName)

    if ([string]::IsNullOrWhiteSpace($Output)) {
        return 'No output captured'
    }

    $lines = $Output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    if ($lines.Count -eq 0) { return 'No output captured' }

    # Script-specific summary extraction
    switch -Wildcard ($ScriptName) {
        'diagnose-mouse*' {
            foreach ($line in $lines) {
                if ($line -match '(\d+)\s+gap' -or $line -match 'gap.*?(\d+)') {
                    return $line
                }
                if ($line -match 'No.*gaps' -or $line -match 'PASS' -or $line -match 'clean') {
                    return $line
                }
            }
        }
        'analyze_affinity*' {
            foreach ($line in $lines) {
                if ($line -match 'overlap' -or $line -match 'conflict' -or $line -match 'deconflict') {
                    return $line
                }
            }
        }
        'audio_diag*' {
            # Return last non-empty line as summary
        }
        'hw_gpu_ecc*' {
            foreach ($line in $lines) {
                if ($line -match 'ECC' -or $line -match 'PerfCap' -or $line -match 'flag') {
                    return $line
                }
            }
        }
        'hw_pcie_state*' {
            foreach ($line in $lines) {
                if ($line -match 'degrad' -or $line -match 'Gen\d' -or $line -match 'x16') {
                    return $line
                }
            }
        }
        'hw_nic_errors*' {
            foreach ($line in $lines) {
                if ($line -match 'CRC' -or $line -match 'error' -or $line -match 'link') {
                    return $line
                }
            }
        }
        'audit*' {
            foreach ($line in $lines) {
                if ($line -match 'Score|score|PASS|FAIL|WARN' -or $line -match '\d+/\d+') {
                    return $line
                }
            }
        }
        'health-check*' {
            foreach ($line in $lines) {
                if ($line -match 'Score|score|Overall' -or $line -match '\d+/100') {
                    return $line
                }
            }
        }
    }

    # Fallback: last meaningful line (trim to 120 chars)
    $last = $lines[$lines.Count - 1]
    if ($last.Length -gt 120) {
        $last = $last.Substring(0, 117) + '...'
    }
    return $last
}

# ============================================================================
# Determine status label from script result
# ============================================================================
function Get-StatusLabel {
    param([hashtable]$Result)

    if ($Result.status -eq 'skipped') { return 'SKIP' }
    if ($Result.status -eq 'missing') { return 'SKIP' }
    if ($Result.status -eq 'error')   { return 'FAIL' }

    $lowerOut = $Result.output.ToLower()
    $lowerSum = $Result.summary.ToLower()

    # Check for failure signals
    if ($lowerOut.Contains('fail') -or $lowerOut.Contains('critical') -or $Result.exitCode -gt 1) {
        return 'FAIL'
    }
    # Check for warning signals
    if ($lowerOut.Contains('warn') -or $lowerOut.Contains('degrad') -or
        $lowerOut.Contains('overlap') -or $lowerOut.Contains('gap') -or
        $lowerOut.Contains('flag')) {
        # Distinguish between "no gaps" (pass) and "47 gaps" (warn)
        if ($lowerSum.Contains('no overlap') -or $lowerSum.Contains('no gap') -or
            $lowerSum.Contains('0 gap') -or $lowerSum.Contains('no flag') -or
            $lowerSum.Contains('0 flag')) {
            return 'PASS'
        }
        return 'WARN'
    }

    return 'PASS'
}

# ============================================================================
# Calculate overall severity
# ============================================================================
function Get-Severity {
    param([array]$Results)

    $hasFail = $false
    $hasWarn = $false
    $hasPass = $false
    $hasSkip = $false

    foreach ($r in $Results) {
        $label = Get-StatusLabel $r
        switch ($label) {
            'FAIL' { $hasFail = $true }
            'WARN' { $hasWarn = $true }
            'PASS' { $hasPass = $true }
            'SKIP' { $hasSkip = $true }
        }
    }

    if ($hasFail) { return 'HIGH' }
    if ($hasWarn) { return 'MEDIUM' }
    if ($hasPass -and $hasSkip) { return 'LOW' }
    if ($hasPass) { return 'CLEAN' }
    return 'LOW'
}

# ============================================================================
# Generate recommendations based on results
# ============================================================================
function Get-Recommendations {
    param([array]$Results, [string]$DomainName)

    $recs = @()
    $priority = 1

    foreach ($r in $Results) {
        $label = Get-StatusLabel $r
        if ($label -eq 'SKIP' -or $label -eq 'PASS') { continue }

        switch -Wildcard ($r.script) {
            'diagnose-mouse*' {
                $recs += [ordered]@{
                    action   = 'Run fix_gpu_affinity.ps1 to route GPU interrupts off CPU 0'
                    agent    = '@dpc'
                    priority = $priority
                }
                $priority++
                $recs += [ordered]@{
                    action   = 'Check Razer polling rate with fix_razer_polling.ps1'
                    agent    = '@dpc'
                    priority = $priority
                }
                $priority++
            }
            'analyze_affinity*' {
                $recs += [ordered]@{
                    action   = 'Run apply_deconflict_affinity.ps1 to fix CPU overlaps'
                    agent    = '@dpc'
                    priority = $priority
                }
                $priority++
            }
            'audio_diag*' {
                $recs += [ordered]@{
                    action   = 'Run fix_audio_warble.ps1 to fix audio clock issues'
                    agent    = '@dpc'
                    priority = $priority
                }
                $priority++
            }
            'hw_gpu_ecc*' {
                $recs += [ordered]@{
                    action   = 'Investigate GPU ECC errors or PerfCap throttling'
                    agent    = '@gpu'
                    priority = $priority
                }
                $priority++
            }
            'hw_pcie_state*' {
                $recs += [ordered]@{
                    action   = 'Check PCIe slot seating and BIOS Gen5 settings'
                    agent    = '@gpu'
                    priority = $priority
                }
                $priority++
            }
            'hw_nic_errors*' {
                $recs += [ordered]@{
                    action   = 'Check I226-V NIC driver and EEE settings with fix_nic_power_mgmt.ps1'
                    agent    = '@net'
                    priority = $priority
                }
                $priority++
            }
            'audit*' {
                $recs += [ordered]@{
                    action   = 'Run audit.ps1 -GenerateFix to auto-generate fix script'
                    agent    = '@system'
                    priority = $priority
                }
                $priority++
            }
            'health-check*' {
                $recs += [ordered]@{
                    action   = 'Review health-check HTML report for specific failures'
                    agent    = '@system'
                    priority = $priority
                }
                $priority++
            }
        }
    }

    # Add skipped-scripts recommendation if any were skipped
    $skippedCount = 0
    foreach ($r in $Results) {
        if ($r.status -eq 'skipped') { $skippedCount++ }
    }
    if ($skippedCount -gt 0) {
        $recs += [ordered]@{
            action   = 'Re-run with admin elevation for full diagnostics (' + $skippedCount + ' skipped)'
            agent    = ''
            priority = $priority
        }
        $priority++
    }

    return $recs
}

# ============================================================================
# Print colored summary
# ============================================================================
function Write-Summary {
    param([array]$Results, [string]$DomainName, [string]$Severity, [array]$Recs, [string]$JsonPath)

    $domainLabel = $DomainName.ToUpper()
    $domainDesc = switch ($DomainName) {
        'dpc'    { 'DPC/Input' }
        'gpu'    { 'GPU/Frames' }
        'net'    { 'Network' }
        'system' { 'System Health' }
        'all'    { 'All Domains' }
        default  { $DomainName }
    }

    Write-Host ''
    Write-Host ([string][char]0x2550 * 56) -ForegroundColor Cyan
    Write-Host ('  DIAGNOSTIC RESULTS - ' + $domainDesc + ' Domain') -ForegroundColor Cyan
    Write-Host ([string][char]0x2550 * 56) -ForegroundColor Cyan
    Write-Host ''

    foreach ($r in $Results) {
        $label = Get-StatusLabel $r
        $name = $r.script
        # Pad script name to 30 chars
        if ($name.Length -gt 30) { $name = $name.Substring(0, 27) + '...' }
        $padded = $name.PadRight(30)

        $durSec = [math]::Round($r.durationMs / 1000, 1)
        $durText = '(' + $durSec + 's)'
        $summary = $r.summary
        if ($summary.Length -gt 40) {
            $summary = $summary.Substring(0, 37) + '...'
        }

        $color = switch ($label) {
            'PASS' { 'Green' }
            'WARN' { 'Yellow' }
            'FAIL' { 'Red' }
            'SKIP' { 'DarkGray' }
            default { 'White' }
        }

        $line = '  ' + $padded + ' ' + $label.PadRight(6) + ' ' + $summary
        if ($r.status -ne 'skipped' -and $r.status -ne 'missing') {
            $line = $line + ' ' + $durText
        }
        Write-Host $line -ForegroundColor $color
    }

    Write-Host ''

    $sevColor = switch ($Severity) {
        'HIGH'   { 'Red' }
        'MEDIUM' { 'Yellow' }
        'LOW'    { 'DarkYellow' }
        'CLEAN'  { 'Green' }
        default  { 'White' }
    }
    Write-Host ('  Overall: ' + $Severity + ' severity') -ForegroundColor $sevColor
    Write-Host ''

    if ($Recs.Count -gt 0) {
        Write-Host '  Recommendations:' -ForegroundColor White
        foreach ($rec in $Recs) {
            $prefix = '  ' + $rec.priority + '. '
            Write-Host ($prefix + $rec.action) -ForegroundColor White
            if ($rec.agent -ne '') {
                Write-Host ('     -> Claude Code: ' + $rec.agent + ' "' + $rec.action + '"') -ForegroundColor DarkGray
            }
        }
        Write-Host ''
    }

    Write-Host ('  Results saved: ' + $JsonPath) -ForegroundColor DarkGray
    Write-Host ([string][char]0x2550 * 56) -ForegroundColor Cyan
    Write-Host ''
}

# ============================================================================
# MAIN LOGIC
# ============================================================================

$classification = $null
$selectedDomain = ''

# --- Determine domain ---

if ($Domain -ne '') {
    # Direct domain selection
    $selectedDomain = $Domain
    $classification = @{
        domain          = $Domain
        confidence      = 'explicit'
        matchedKeywords = @()
        allMatches      = @{}
        ambiguous       = $false
    }
}
elseif ($Symptom -ne '') {
    # Keyword classification
    $classification = Classify-Symptom $Symptom
    Write-Host ''
    Write-Host ('Classified symptom -> ' + $classification.domain.ToUpper() + ' (confidence: ' + $classification.confidence + ')') -ForegroundColor Cyan
    if ($classification.matchedKeywords.Count -gt 0) {
        Write-Host ('  Matched keywords: ' + ($classification.matchedKeywords -join ', ')) -ForegroundColor DarkGray
    }

    if ($classification.ambiguous) {
        $selectedDomain = Resolve-Ambiguity $classification
    } else {
        $selectedDomain = $classification.domain
    }
}
elseif ($Interactive -or ($Symptom -eq '' -and $Domain -eq '')) {
    # Interactive menu
    $menuResult = Show-Menu
    if ($menuResult -eq '') { return }

    if ($menuResult -eq '__classify__') {
        $classification = Classify-Symptom $Symptom
        Write-Host ''
        Write-Host ('Classified symptom -> ' + $classification.domain.ToUpper() + ' (confidence: ' + $classification.confidence + ')') -ForegroundColor Cyan
        if ($classification.matchedKeywords.Count -gt 0) {
            Write-Host ('  Matched keywords: ' + ($classification.matchedKeywords -join ', ')) -ForegroundColor DarkGray
        }

        if ($classification.ambiguous) {
            $selectedDomain = Resolve-Ambiguity $classification
        } else {
            $selectedDomain = $classification.domain
        }
    } else {
        $selectedDomain = $menuResult
        $classification = @{
            domain          = $menuResult
            confidence      = 'menu'
            matchedKeywords = @()
            allMatches      = @{}
            ambiguous       = $false
        }
    }
}

if ($selectedDomain -eq '') {
    Write-Host 'No domain selected. Exiting.' -ForegroundColor Red
    return
}

# --- Admin status banner ---
Write-Host ''
if ($isAdmin) {
    Write-Host '  Elevated: YES (full diagnostics available)' -ForegroundColor Green
} else {
    Write-Host '  Elevated: NO (some diagnostics will be skipped)' -ForegroundColor Yellow
    Write-Host '  Tip: Run as Administrator for full diagnostics' -ForegroundColor DarkGray
}
if ($Quick) {
    Write-Host '  Mode: QUICK (admin-required scripts skipped)' -ForegroundColor Yellow
}
Write-Host ''

# --- Collect scripts for the domain(s) ---
$allScripts = @()

if ($selectedDomain -eq 'all') {
    foreach ($d in @('dpc','gpu','net','system')) {
        $allScripts += @(Get-DomainScripts $d)
    }
} else {
    $allScripts = @(Get-DomainScripts $selectedDomain)
}

if ($allScripts.Count -eq 0) {
    Write-Host 'No diagnostic scripts defined for domain: ' + $selectedDomain -ForegroundColor Red
    return
}

# --- Run diagnostics ---
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()
$results = @()

foreach ($scriptDef in $allScripts) {
    $result = Invoke-DiagnosticScript $scriptDef
    $results += $result
}

$totalSw.Stop()
$totalMs = [int]$totalSw.ElapsedMilliseconds

# --- Compute severity and recommendations ---
$severity = Get-Severity $results
$recommendations = @(Get-Recommendations $results $selectedDomain)

# --- Build JSON output ---
$diagnosticEntries = @()
foreach ($r in $results) {
    $entry = [ordered]@{
        script        = $r.script
        domain        = $r.domain
        status        = $r.status
        exitCode      = $r.exitCode
        durationMs    = $r.durationMs
        summary       = $r.summary
        statusLabel   = (Get-StatusLabel $r)
        requiresAdmin = $r.requiresAdmin
    }
    $diagnosticEntries += $entry
}

$classificationOutput = $null
if ($null -ne $classification) {
    $matchedKws = @()
    if ($classification.matchedKeywords -is [array]) {
        $matchedKws = $classification.matchedKeywords
    }
    $classificationOutput = [ordered]@{
        domain          = $classification.domain
        confidence      = $classification.confidence
        matchedKeywords = $matchedKws
    }
}

$report = [ordered]@{
    timestamp      = $timestampIso
    domain         = $selectedDomain
    symptomText    = $Symptom
    isAdmin        = $isAdmin
    quickMode      = [bool]$Quick
    totalDurationMs = $totalMs
    classification = $classificationOutput
    diagnostics    = $diagnosticEntries
    severity       = $severity
    recommendations = $recommendations
}

# --- Write JSON ---
$jsonFileName = 'diagnose_' + $timestamp + '.json'
$jsonPath = Join-Path $OutputDir $jsonFileName

$report | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding utf8
Write-Host ''
Write-Host ('JSON report saved: ' + $jsonPath) -ForegroundColor DarkGray

# --- MonitorOutput mode ---
if ($MonitorOutput) {
    $monitorDir = Join-Path $projectRoot 'monitor\data'
    if (Test-Path $monitorDir) {
        $jsPath = Join-Path $monitorDir 'diagnose_latest.js'
        $jsonContent = $report | ConvertTo-Json -Depth 10
        $jsContent = 'window.DIAGNOSE_LATEST = ' + $jsonContent + ';'
        $jsContent | Out-File -FilePath $jsPath -Encoding utf8
        Write-Host ('Monitor JS updated: ' + $jsPath) -ForegroundColor DarkGray
    } else {
        Write-Host ('Monitor directory not found, skipping JS output: ' + $monitorDir) -ForegroundColor DarkGray
    }
}

# --- Print summary ---
Write-Summary $results $selectedDomain $severity $recommendations $jsonPath
