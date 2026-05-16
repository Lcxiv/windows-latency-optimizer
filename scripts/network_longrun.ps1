<#
.SYNOPSIS
    Long-running high-resolution network capture for overnight or multi-hour runs.
.DESCRIPTION
    Pings gateway + two external targets at configurable intervals, logs RTT and
    packet loss to CSV, detects burst losses, and prints a full summary on exit.
    Does NOT require admin privileges.
.PARAMETER IntervalMs
    Ping interval in milliseconds (default 1000).
.PARAMETER OutputDir
    Directory for CSV output (default: captures\ next to this script).
.PARAMETER MaxMinutes
    Maximum runtime in minutes. 0 = indefinite, Ctrl+C to stop (default 0).
.EXAMPLE
    .\network_longrun.ps1
    .\network_longrun.ps1 -IntervalMs 500 -MaxMinutes 60
#>
[CmdletBinding()]
param(
    [int]$IntervalMs = 1000,
    [string]$OutputDir = (Join-Path $PSScriptRoot '..\captures'),
    [int]$MaxMinutes = 0
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ── Gateway Detection ─────────────────────────────────────────────────────────
try {
    $defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
        Sort-Object -Property RouteMetric |
        Select-Object -First 1
    $gatewayIP = $defaultRoute.NextHop
}
catch {
    Write-Error 'Could not detect default gateway. Ensure a network connection is active.'
    return
}

if ([string]::IsNullOrWhiteSpace($gatewayIP)) {
    Write-Error 'Default gateway IP is empty. Check network configuration.'
    return
}

# ── Target List ───────────────────────────────────────────────────────────────
$targets = @(
    @{ Name = 'gateway'; IP = $gatewayIP }
    @{ Name = 'target1'; IP = '1.1.1.1' }
    @{ Name = 'target2'; IP = '8.8.8.8' }
)

# ── Output Setup ──────────────────────────────────────────────────────────────
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmm'
$csvFile = Join-Path $OutputDir ('network_longrun_' + $timestamp + '.csv')
$csvHeader = 'timestamp,gateway_ip,gateway_ms,target1_ms,target2_ms,gateway_loss,target1_loss,target2_loss'
Set-Content -Path $csvFile -Value $csvHeader -Encoding UTF8

# ── Ping Object ───────────────────────────────────────────────────────────────
$pinger = New-Object System.Net.NetworkInformation.Ping
$pingTimeout = 1000

# ── Tracking State ────────────────────────────────────────────────────────────
$sampleCount = 0
$startTime = Get-Date

# Per-target accumulators: total RTT (for avg), loss count, sample count with RTT
$rttSums    = @{ gateway = [double]0; target1 = [double]0; target2 = [double]0 }
$rttCounts  = @{ gateway = 0; target1 = 0; target2 = 0 }
$lossCounts = @{ gateway = 0; target1 = 0; target2 = 0 }

# Consecutive loss tracking (for burst detection)
$consecLoss = @{ gateway = 0; target1 = 0; target2 = 0 }
$burstStart = @{ gateway = $null; target1 = $null; target2 = $null }

# Burst log
$bursts = New-Object System.Collections.ArrayList

# ── Max duration label ────────────────────────────────────────────────────────
$maxLabel = 'indefinite (Ctrl+C to stop)'
if ($MaxMinutes -gt 0) {
    $maxLabel = $MaxMinutes.ToString() + ' minutes'
}

# ── Relative path for display ────────────────────────────────────────────────
$displayPath = $csvFile
$currentDir = Get-Location
$currentDirStr = $currentDir.Path
if ($csvFile.StartsWith($currentDirStr)) {
    $displayPath = $csvFile.Substring($currentDirStr.Length).TrimStart('\')
}

# ── Startup Banner ────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '=== Network Long-Run Capture ===' -ForegroundColor Cyan
Write-Host ('  Gateway : ' + $gatewayIP)
Write-Host ('  Targets : 1.1.1.1, 8.8.8.8')
Write-Host ('  Interval: ' + $IntervalMs.ToString() + 'ms')
Write-Host ('  Output  : ' + $displayPath)
Write-Host ('  Max     : ' + $maxLabel)
Write-Host ''

# ── Helper: Ping a single target ─────────────────────────────────────────────
function Invoke-SinglePing {
    param([string]$Address)
    try {
        $reply = $pinger.Send($Address, $pingTimeout)
        if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
            return @{ Ms = $reply.RoundtripTime; Loss = 0 }
        }
        else {
            return @{ Ms = $null; Loss = 1 }
        }
    }
    catch {
        return @{ Ms = $null; Loss = 1 }
    }
}

# ── Helper: Format RTT for display ───────────────────────────────────────────
function Format-Rtt {
    param($ms)
    if ($null -eq $ms) { return '---' }
    return $ms.ToString() + 'ms'
}

# ── Main Loop ─────────────────────────────────────────────────────────────────
try {
    while ($true) {
        $now = Get-Date
        $sampleCount++

        # Check MaxMinutes
        if ($MaxMinutes -gt 0) {
            $elapsed = ($now - $startTime).TotalMinutes
            if ($elapsed -ge $MaxMinutes) {
                Write-Host ''
                Write-Host '[INFO] MaxMinutes reached, stopping capture.' -ForegroundColor Yellow
                break
            }
        }

        # Ping all targets
        $results = @{}
        foreach ($t in $targets) {
            $results[$t.Name] = Invoke-SinglePing -Address $t.IP
        }

        # Build CSV row
        $ts = $now.ToString('yyyy-MM-dd HH:mm:ss.fff')

        $gwMs = $results['gateway'].Ms
        $t1Ms = $results['target1'].Ms
        $t2Ms = $results['target2'].Ms

        $gwMsStr = ''
        if ($null -ne $gwMs) { $gwMsStr = $gwMs.ToString() }
        $t1MsStr = ''
        if ($null -ne $t1Ms) { $t1MsStr = $t1Ms.ToString() }
        $t2MsStr = ''
        if ($null -ne $t2Ms) { $t2MsStr = $t2Ms.ToString() }

        $gwLoss = $results['gateway'].Loss
        $t1Loss = $results['target1'].Loss
        $t2Loss = $results['target2'].Loss

        $row = $ts + ',' + $gatewayIP + ',' + $gwMsStr + ',' + $t1MsStr + ',' + $t2MsStr + ',' + $gwLoss.ToString() + ',' + $t1Loss.ToString() + ',' + $t2Loss.ToString()
        Add-Content -Path $csvFile -Value $row -Encoding UTF8

        # Update accumulators
        foreach ($t in $targets) {
            $name = $t.Name
            $r = $results[$name]
            if ($r.Loss -eq 1) {
                $lossCounts[$name]++
            }
            else {
                $rttSums[$name] += [double]$r.Ms
                $rttCounts[$name]++
            }
        }

        # Burst detection
        foreach ($t in $targets) {
            $name = $t.Name
            $r = $results[$name]

            if ($r.Loss -eq 1) {
                # Increment consecutive loss
                if ($consecLoss[$name] -eq 0) {
                    # Burst may be starting — record timestamp
                    $burstStart[$name] = $now
                }
                $consecLoss[$name]++
            }
            else {
                # Check if a burst just ended (2+ consecutive losses)
                if ($consecLoss[$name] -ge 2) {
                    $bStart = $burstStart[$name]
                    $bDuration = ($now - $bStart).TotalMilliseconds
                    $bCount = $consecLoss[$name]

                    $burstObj = @{
                        startTime        = $bStart
                        endTime          = $now
                        durationMs       = $bDuration
                        target           = $name
                        consecutiveLosses = $bCount
                    }
                    $bursts.Add($burstObj) | Out-Null

                    $targetLabel = $name
                    if ($name -eq 'gateway') { $targetLabel = 'gateway' }
                    elseif ($name -eq 'target1') { $targetLabel = '1.1.1.1' }
                    elseif ($name -eq 'target2') { $targetLabel = '8.8.8.8' }

                    $durationSec = [math]::Round($bDuration / 1000.0, 1)
                    $timeStr = $now.ToString('HH:mm:ss')
                    Write-Host ('[' + $timeStr + '] >>> BURST: ' + $targetLabel + ' lost ' + $bCount.ToString() + ' consecutive pings (' + $durationSec.ToString() + 's)') -ForegroundColor Red
                }
                $consecLoss[$name] = 0
                $burstStart[$name] = $null
            }
        }

        # Progress every 10 samples
        if ($sampleCount % 10 -eq 0) {
            $timeStr = $now.ToString('HH:mm:ss')
            $gwDisp = Format-Rtt $gwMs
            $extDisp = Format-Rtt $t1Ms
            $totalGwLoss = $lossCounts['gateway']
            $totalExtLoss = $lossCounts['target1']
            $burstCount = $bursts.Count

            $line = '[' + $timeStr + '] #' + $sampleCount.ToString() + '  GW=' + $gwDisp + '  EXT=' + $extDisp + '  Loss=' + $totalGwLoss.ToString() + '/' + $totalExtLoss.ToString() + '  Bursts=' + $burstCount.ToString()
            Write-Host $line -ForegroundColor DarkGray
        }

        Start-Sleep -Milliseconds $IntervalMs
    }
}
finally {
    # ── Summary ───────────────────────────────────────────────────────────────
    $endTime = Get-Date
    $runtime = $endTime - $startTime
    $runtimeStr = $runtime.ToString('hh\:mm\:ss')

    Write-Host ''
    Write-Host '=== Capture Summary ===' -ForegroundColor Cyan
    Write-Host ('  Runtime   : ' + $runtimeStr)
    Write-Host ('  Samples   : ' + $sampleCount.ToString())
    Write-Host ''

    # Per-target stats
    foreach ($t in $targets) {
        $name = $t.Name
        $ip = $t.IP

        $label = $name + ' (' + $ip + ')'

        $avgRtt = '---'
        if ($rttCounts[$name] -gt 0) {
            $avg = [math]::Round($rttSums[$name] / $rttCounts[$name], 1)
            $avgRtt = $avg.ToString() + 'ms'
        }

        $drops = $lossCounts[$name]
        $lossPct = 0.0
        if ($sampleCount -gt 0) {
            $lossPct = [math]::Round(($drops / $sampleCount) * 100, 2)
        }

        Write-Host ('  ' + $label) -ForegroundColor White
        Write-Host ('    Avg RTT  : ' + $avgRtt)
        Write-Host ('    Loss     : ' + $lossPct.ToString() + '% (' + $drops.ToString() + ' drops)')
    }

    Write-Host ''

    # Burst summary
    $burstCount = $bursts.Count
    if ($burstCount -eq 0) {
        Write-Host '  Bursts     : none detected' -ForegroundColor Green
    }
    else {
        $totalBurstDur = 0.0
        $maxBurstDur = 0.0
        foreach ($b in $bursts) {
            $totalBurstDur += $b.durationMs
            if ($b.durationMs -gt $maxBurstDur) {
                $maxBurstDur = $b.durationMs
            }
        }
        $avgBurstDur = [math]::Round($totalBurstDur / $burstCount, 0)
        $maxBurstDurRound = [math]::Round($maxBurstDur, 0)

        # Longest gap between bursts
        $maxGap = 0.0
        if ($burstCount -ge 2) {
            $sortedBursts = $bursts | Sort-Object { $_.startTime }
            for ($i = 1; $i -lt $sortedBursts.Count; $i++) {
                $gap = ($sortedBursts[$i].startTime - $sortedBursts[$i - 1].endTime).TotalMilliseconds
                if ($gap -gt $maxGap) {
                    $maxGap = $gap
                }
            }
        }

        Write-Host ('  Bursts     : ' + $burstCount.ToString() + ' detected') -ForegroundColor Yellow
        Write-Host ('    Avg dur  : ' + $avgBurstDur.ToString() + 'ms')
        Write-Host ('    Max dur  : ' + $maxBurstDurRound.ToString() + 'ms')
        if ($burstCount -ge 2) {
            $maxGapSec = [math]::Round($maxGap / 1000.0, 1)
            Write-Host ('    Max gap  : ' + $maxGapSec.ToString() + 's between bursts')
        }
    }

    Write-Host ''
    Write-Host ('  CSV file   : ' + $csvFile) -ForegroundColor Green
    Write-Host ''

    # Dispose pinger
    try { $pinger.Dispose() } catch { }
}
