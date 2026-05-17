<#
.SYNOPSIS
    Summary extraction, severity scoring, and reporting for diagnose.ps1.
.DESCRIPTION
    Parses per-script output for one-line summaries, classifies PASS/WARN/
    FAIL/SKIP, computes overall severity, generates recommendations, and
    writes the colored console summary. Dot-sourced by diagnose.ps1.
#>

# Idempotency guard
if (Get-Command 'Extract-Summary' -ErrorAction SilentlyContinue) { return }

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
