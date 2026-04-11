# helpers/smi-detect.ps1
# SMI (System Management Interrupt) blackout detection via ETW gap analysis.
# Runs a lightweight xperf capture and analyzes DPC/ISR timing histograms
# for evidence of SMI-induced stalls (DPCs >1024us across multiple drivers).
# Also correlates per-CPU perf counter data for simultaneous spike detection.
# PowerShell 5.1 compatible.

function Invoke-SmiGapCapture {
    <#
    .SYNOPSIS
        Run a short xperf capture and analyze for SMI blackout indicators.
    .OUTPUTS
        [hashtable] SMI analysis data, or $null if xperf unavailable.
    #>
    param(
        [string]$OutDir,
        [int]$DurationSec = 10
    )

    $xperfPath = $script:ToolPaths.Xperf
    if (-not $xperfPath -or -not (Test-Path $xperfPath)) {
        Log 'xperf not found - SMI detection skipped' 'WARN'
        return $null
    }

    Log ''
    Log '=== Phase 3F: SMI health check ==='
    Log ('Capturing ' + $DurationSec + 's DPC/ISR trace for SMI detection...')

    $tempEtl = Join-Path $OutDir 'smi_check.etl'
    $dpcIsrReport = Join-Path $OutDir 'smi_dpcisr.txt'

    # Start lightweight xperf trace (DPC + Interrupt + CSwitch only)
    try {
        $startArgs = @('-on', 'PROC_THREAD+DPC+INTERRUPT+CSWITCH',
                       '-BufferSize', '256', '-MaxBuffers', '64',
                       '-f', $tempEtl)
        $startResult = & $xperfPath @startArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            $msg = ($startResult | Out-String).Trim()
            if ($msg -match 'already running|in use|0xB7') {
                Log 'Kernel logger busy (WPR active) - SMI check skipped' 'INFO'
            } else {
                Log ('xperf start failed: ' + $msg) 'WARN'
            }
            return $null
        }
    } catch {
        Log ('xperf start exception: ' + $_.Exception.Message) 'WARN'
        return $null
    }

    Start-Sleep -Seconds $DurationSec

    # Stop trace
    try {
        $stopResult = & $xperfPath -d $tempEtl 2>&1
        if ($LASTEXITCODE -ne 0) {
            Log ('xperf stop failed (exit ' + $LASTEXITCODE + '): ' + ($stopResult | Out-String).Trim()) 'WARN'
            return $null
        }
        if (-not (Test-Path $tempEtl)) {
            Log 'xperf trace file not created' 'WARN'
            return $null
        }
        $etlSize = [math]::Round((Get-Item $tempEtl).Length / 1KB, 1)
        Log ('SMI trace captured: ' + $etlSize + ' KB') 'PASS'
    } catch {
        Log ('xperf stop exception: ' + $_.Exception.Message) 'WARN'
        return $null
    }

    # Run dpcisr analysis on the SMI check trace
    try {
        & $xperfPath -i $tempEtl -o $dpcIsrReport -a dpcisr 2>&1 | Out-Null
    } catch {
        Log ('xperf dpcisr analysis failed: ' + $_.Exception.Message) 'WARN'
        return $null
    }

    if (-not (Test-Path $dpcIsrReport)) {
        Log 'SMI dpcisr report not generated' 'WARN'
        return $null
    }

    $result = Find-SmiBlackouts -ReportPath $dpcIsrReport -FallbackDurationSec $DurationSec

    # Clean up the ETL (large, not needed after analysis)
    try { Remove-Item $tempEtl -Force -ErrorAction SilentlyContinue } catch {}

    $verdictColor = 'PASS'
    if ($result.verdict -eq 'FAIL') { $verdictColor = 'FAIL' }
    elseif ($result.verdict -eq 'REVIEW') { $verdictColor = 'WARN' }

    Log ('SMI health: ' + $result.verdict + ' | high-latency DPCs: ' + $result.highLatencyDpcCount + ' | max bucket: ' + $result.maxBucketUs + 'us') $verdictColor

    return $result
}


function Find-SmiBlackouts {
    <#
    .SYNOPSIS
        Parse a dpcisr report for SMI blackout indicators.
    .DESCRIPTION
        Analyzes per-module DPC timing histograms for entries in high-latency
        buckets (>1024us). Multiple drivers showing >1024us DPCs simultaneously
        is the strongest SMI indicator (all cores freeze together).
    .OUTPUTS
        [hashtable] with maxBucketUs, highLatencyDpcCount, affectedDrivers, verdict.
    #>
    param(
        [string]$ReportPath,
        [int]$FallbackDurationSec = 0
    )

    $result = @{
        source               = 'xperf-dpcisr-histogram'
        captureDurationSec   = $FallbackDurationSec
        gapThresholdUs       = 1024
        highLatencyDpcCount  = 0
        maxBucketUs          = 0
        affectedDrivers      = @()
        driversWithHighDpc   = 0
        verdict              = 'PASS'
    }

    if (-not (Test-Path $ReportPath)) { return $result }

    $lines = Get-Content $ReportPath
    $inModuleSection = $false
    $currentModule = ''
    $moduleHighCount = 0
    $moduleMaxUs = 0
    $affectedDrivers = @()

    foreach ($line in $lines) {
        # Detect trace duration (overrides fallback)
        if ($line -match 'CPU Usage from 0 us to (\d+) us') {
            $traceDurationUs = [long]$Matches[1]
            $result['traceDurationUs'] = $traceDurationUs
            $result['captureDurationSec'] = [math]::Round($traceDurationUs / 1000000, 1)
        }

        # Skip overall histogram (before per-module breakdown) to avoid double-counting
        if ($line -match '^Total = (\d+)$') {
            continue
        }

        # Detect per-module section
        if ($line -match '^Total = (\d+) for module (\S+)') {
            # Save previous module if it had high-latency DPCs
            if ($currentModule -ne '' -and $moduleHighCount -gt 0) {
                $affectedDrivers += @{
                    driver   = $currentModule
                    count    = $moduleHighCount
                    maxUs    = $moduleMaxUs
                }
            }

            $currentModule = $Matches[2]
            $moduleHighCount = 0
            $moduleMaxUs = 0
            $inModuleSection = $true
            continue
        }

        # Parse timing buckets (only count per-module, not overall)
        if ($inModuleSection -and $line -match 'Elapsed Time.*<=\s+(\d+) usecs,\s+(\d+),') {
            $bucket = [int]$Matches[1]
            $count  = [int]$Matches[2]

            if ($bucket -ge 1024 -and $count -gt 0) {
                $moduleHighCount += $count
                if ($bucket -gt $moduleMaxUs) { $moduleMaxUs = $bucket }
                if ($bucket -gt $result.maxBucketUs) {
                    $result['maxBucketUs'] = $bucket
                }
            }
        }

        # ISR section starts - save last DPC module and stop DPC parsing
        if ($line -match 'ISR Info') {
            if ($currentModule -ne '' -and $moduleHighCount -gt 0) {
                $affectedDrivers += @{
                    driver   = $currentModule
                    count    = $moduleHighCount
                    maxUs    = $moduleMaxUs
                }
            }
            $currentModule = ''
            $moduleHighCount = 0
            $inModuleSection = $false
        }
    }

    # Save final module
    if ($currentModule -ne '' -and $moduleHighCount -gt 0) {
        $affectedDrivers += @{
            driver   = $currentModule
            count    = $moduleHighCount
            maxUs    = $moduleMaxUs
        }
    }

    # Sum per-module counts (avoids double-counting from overall histogram)
    $totalHighLatency = 0
    foreach ($d in $affectedDrivers) { $totalHighLatency += $d.count }

    $result['highLatencyDpcCount'] = $totalHighLatency
    $result['affectedDrivers'] = $affectedDrivers
    $result['driversWithHighDpc'] = $affectedDrivers.Count

    # Verdict:
    # - 3+ drivers with >1024us DPCs = strong SMI indicator (all cores stall)
    # - Any DPC >8192us (8ms) = almost certainly SMI
    # - Single driver >1024us = could be a slow driver (REVIEW)
    if ($result.maxBucketUs -ge 8192 -or $affectedDrivers.Count -ge 3) {
        $result['verdict'] = 'FAIL'
    } elseif ($totalHighLatency -gt 0) {
        $result['verdict'] = 'REVIEW'
    }

    return $result
}


function Get-SmiCorrelation {
    <#
    .SYNOPSIS
        Analyze per-CPU perf counter data for simultaneous DPC spikes.
    .DESCRIPTION
        Computes the coefficient of variation of DPC% across CPUs.
        Low CV (DPC evenly spread) = suspicious (SMI aftermath).
        High CV (concentrated on few cores) = normal affinity behavior.
    .OUTPUTS
        [int] Correlation score 0-100 (higher = more suspicious).
    #>
    param(
        [array]$CpuData
    )

    if (-not $CpuData -or $CpuData.Count -lt 2) { return 0 }

    # Collect DPC% values, excluding CPU 0 (preferred core always has high DPC)
    $dpcValues = @()
    foreach ($cpu in $CpuData) {
        if ($cpu.cpu -ne 0) { $dpcValues += $cpu.dpcPct }
    }
    if ($dpcValues.Count -lt 2) { return 0 }

    $stats = Get-Stats $dpcValues
    if ($stats.avg -lt 0.01) { return 0 }

    # CV = stdev / mean. Low CV = evenly spread = suspicious
    $cv = $stats.stdev / $stats.avg

    # Score: CV < 0.5 (very uniform) = 80, CV < 1.0 = 50, CV < 2.0 = 25
    $score = 0
    if ($cv -lt 0.5) { $score = 80 }
    elseif ($cv -lt 1.0) { $score = 50 }
    elseif ($cv -lt 2.0) { $score = 25 }

    # Boost if avg DPC% is high across non-preferred cores
    if ($stats.avg -gt 0.5) { $score = [math]::Min(100, $score + 20) }

    return $score
}
