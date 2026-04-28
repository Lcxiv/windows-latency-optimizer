#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Diagnose bursty system behavior — captures CPU, GPU, NIC, and DPC at
    high frequency, detects burst patterns, cross-correlates sources,
    identifies root causes, and recommends fixes.
.DESCRIPTION
    Samples multiple telemetry sources simultaneously at ~200ms intervals:
      - CPU% per-core (WMI PerfFormattedData — instant, no 1s wait)
      - DPC%, Interrupt%, Context Switches
      - GPU clocks + P-state (nvidia-smi)
      - NIC packet rate (Get-NetAdapterStatistics delta)

    Post-processing:
      - Burstiness score (coefficient of variation) per source
      - Peak detection (2-sigma threshold)
      - Dominant burst frequency (inter-peak histogram)
      - Cross-source correlation
      - Root cause classification + fix recommendations

    Output:
      - burst_timeline.csv  (all samples)
      - burst_analysis.json (full analysis)
      - Console summary with colored recommendations
.EXAMPLE
    .\diagnose-burst-pattern.ps1
    .\diagnose-burst-pattern.ps1 -DurationSec 60 -SampleIntervalMs 100
    .\diagnose-burst-pattern.ps1 -SkipGpu -Label "idle_test"
.NOTES
    PowerShell 5.1 compatible. Requires admin for WMI perf counters.
#>
[CmdletBinding()]
param(
    [int]$DurationSec = 30,
    [int]$SampleIntervalMs = 200,
    [switch]$SkipGpu,
    [switch]$SkipNic,
    [string]$Label = '',
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# SETUP
# ============================================================================

. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\helpers\logging.ps1"
. "$PSScriptRoot\helpers\burst-detect.ps1"

$script:logLines = @()

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$dirLabel = $timestamp + '_BURST_DIAG'
if ($Label -ne '') { $dirLabel = $timestamp + '_' + $Label }

if ($OutDir -eq '') {
    $OutDir = Join-Path $script:ExperimentsDir $dirLabel
}
if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

Write-Host ''
Write-Host '======================================================' -ForegroundColor Cyan
Write-Host '  BURST PATTERN DIAGNOSTIC' -ForegroundColor Cyan
Write-Host '======================================================' -ForegroundColor Cyan
Write-Host ('  Duration:  ' + $DurationSec + 's')
Write-Host ('  Interval:  ' + $SampleIntervalMs + 'ms')
Write-Host ('  Output:    ' + $OutDir)
Write-Host '======================================================' -ForegroundColor Cyan
Write-Host ''

# ============================================================================
# PHASE 1: SYSTEM STATE SNAPSHOT
# ============================================================================

Log 'Phase 1: System state snapshot'

$systemState = [ordered]@{}

# --- Timer Resolution via P/Invoke ---
try {
    $ntdllSig = @'
[DllImport("ntdll.dll")]
public static extern int NtQueryTimerResolution(
    out uint MinimumResolution,
    out uint MaximumResolution,
    out uint CurrentResolution);
'@
    $ntType = Add-Type -MemberDefinition $ntdllSig -Name 'NtDll_BurstDiag' -Namespace 'Win32' -PassThru -ErrorAction SilentlyContinue
    $minRes = [uint32]0
    $maxRes = [uint32]0
    $curRes = [uint32]0
    $ntType::NtQueryTimerResolution([ref]$minRes, [ref]$maxRes, [ref]$curRes) | Out-Null
    $systemState.timerResolutionMs = [math]::Round($curRes / 10000.0, 4)
    $systemState.timerMinMs = [math]::Round($minRes / 10000.0, 4)
    $systemState.timerMaxMs = [math]::Round($maxRes / 10000.0, 4)
    Log ('  Timer resolution: ' + $systemState.timerResolutionMs + 'ms (range: ' + $systemState.timerMaxMs + '-' + $systemState.timerMinMs + 'ms)')
} catch {
    $systemState.timerResolutionMs = 'unknown'
    Log '  Timer resolution: could not query (P/Invoke failed)' 'WARN'
}

# --- Timer Coalescing ---
try {
    $coalescingOutput = powercfg /query SCHEME_CURRENT SUB_SLEEP IDLETIMER 2>&1 | Out-String
    $coalescingEnabled = $true
    if ($coalescingOutput -match 'Current AC Power Setting Index:\s+0x([0-9a-fA-F]+)') {
        $val = [int]('0x' + $Matches[1])
        if ($val -eq 0) { $coalescingEnabled = $false }
        $systemState.timerCoalescing = $coalescingEnabled
        $systemState.timerCoalescingValue = $val
        if ($coalescingEnabled) {
            Log ('  Timer coalescing: ENABLED (value=' + $val + ')') 'WARN'
        } else {
            Log '  Timer coalescing: disabled' 'PASS'
        }
    } else {
        $systemState.timerCoalescing = 'unknown'
        Log '  Timer coalescing: could not parse powercfg output' 'WARN'
    }
} catch {
    $systemState.timerCoalescing = 'unknown'
    Log '  Timer coalescing: query failed' 'WARN'
}

# --- Power Plan ---
try {
    $ppOutput = powercfg /getactivescheme 2>&1 | Out-String
    if ($ppOutput -match '\((.+)\)') {
        $systemState.powerPlan = $Matches[1].Trim()
        Log ('  Power plan: ' + $systemState.powerPlan)
    }
} catch {
    $systemState.powerPlan = 'unknown'
}

# --- GPU Clock State ---
$gpuAvailable = $false
if (-not $SkipGpu) {
    try {
        $gpuInfo = Get-GpuInfo
        $smiCmd = $null
        if ($gpuInfo.vendorConfig -and $gpuInfo.vendorConfig.SmiCommand) {
            $smiCmd = Get-Command $gpuInfo.vendorConfig.SmiCommand -ErrorAction SilentlyContinue
        }
        if (-not $smiCmd) {
            $smiCmd = Get-Command 'nvidia-smi' -ErrorAction SilentlyContinue
        }

        if ($smiCmd) {
            $gpuAvailable = $true
            $gpuQuery = & $smiCmd.Source --query-gpu=clocks.gr,clocks.mem,pstate,power.draw --format=csv,noheader,nounits 2>$null
            if ($gpuQuery) {
                $gpuParts = $gpuQuery.Trim().Split(',')
                $systemState.gpuCoreClock = $gpuParts[0].Trim()
                $systemState.gpuMemClock = $gpuParts[1].Trim()
                $systemState.gpuPstate = $gpuParts[2].Trim()
                $systemState.gpuPower = $gpuParts[3].Trim()

                # Check if clocks appear locked (max application clock = current)
                $gpuMaxQuery = & $smiCmd.Source --query-gpu=clocks.max.graphics,clocks.max.memory --format=csv,noheader,nounits 2>$null
                if ($gpuMaxQuery) {
                    $maxParts = $gpuMaxQuery.Trim().Split(',')
                    $curCore = [int]$gpuParts[0].Trim()
                    $maxCore = [int]$maxParts[0].Trim()
                    $systemState.gpuClockLocked = ($curCore -ge ($maxCore - 50))
                }

                $lockStatus = 'NOT locked'
                if ($systemState.gpuClockLocked) { $lockStatus = 'LOCKED' }
                Log ('  GPU: ' + $systemState.gpuCoreClock + '/' + $systemState.gpuMemClock + ' MHz, ' + $systemState.gpuPstate + ', ' + $systemState.gpuPower + 'W (' + $lockStatus + ')')
            }
        } else {
            Log '  GPU: nvidia-smi not found, skipping GPU monitoring' 'WARN'
        }
    } catch {
        Log ('  GPU: detection failed — ' + $_.Exception.Message) 'WARN'
    }
}

# --- NIC State ---
$nicAvailable = $false
$nicName = ''
if (-not $SkipNic) {
    try {
        $nic = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
        if ($nic) {
            $nicAvailable = $true
            $nicName = $nic.Name

            # ITR / Interrupt Moderation
            $intMod = Get-NetAdapterAdvancedProperty -Name $nicName -DisplayName 'Interrupt Moderation' -ErrorAction SilentlyContinue
            $itr = Get-NetAdapterAdvancedProperty -Name $nicName -DisplayName 'Interrupt Moderation Rate' -ErrorAction SilentlyContinue

            $systemState.nicName = $nicName
            $systemState.nicLinkSpeed = $nic.LinkSpeed
            if ($intMod) { $systemState.nicInterruptModeration = $intMod.DisplayValue }
            if ($itr) { $systemState.nicITR = $itr.DisplayValue }

            $itrStatus = 'unknown'
            if ($intMod) { $itrStatus = $intMod.DisplayValue }
            Log ('  NIC: ' + $nic.InterfaceDescription + ' @ ' + $nic.LinkSpeed + ' (IntMod=' + $itrStatus + ')')
        } else {
            Log '  NIC: no active physical adapter found' 'WARN'
        }
    } catch {
        Log ('  NIC: detection failed — ' + $_.Exception.Message) 'WARN'
    }
}

# --- C-State Config ---
try {
    # Check processor idle disable policy
    $cstateOutput = powercfg /query SCHEME_CURRENT SUB_PROCESSOR IDLEDISABLE 2>&1 | Out-String
    if ($cstateOutput -match 'Current AC Power Setting Index:\s+0x([0-9a-fA-F]+)') {
        $val = [int]('0x' + $Matches[1])
        $systemState.cstateIdleDisable = $val
        if ($val -eq 1) {
            Log '  C-States: idle DISABLED (no C-states)' 'WARN'
        } else {
            Log '  C-States: idle enabled (C-states active)' 'PASS'
        }
    }
} catch {
    $systemState.cstateIdleDisable = 'unknown'
}

Write-Host ''

# ============================================================================
# PHASE 2: HIGH-FREQUENCY SAMPLING LOOP
# ============================================================================

Log ('Phase 2: Sampling at ~' + $SampleIntervalMs + 'ms for ' + $DurationSec + 's')
Write-Host '  Capturing... ' -NoNewline

$timeline = @()
$prevNicRx = 0
$prevNicTx = 0
$firstNicSample = $true

# Get initial NIC stats
if ($nicAvailable) {
    try {
        $nicStats = Get-NetAdapterStatistics -Name $nicName -ErrorAction SilentlyContinue
        $prevNicRx = $nicStats.ReceivedUnicastPackets
        $prevNicTx = $nicStats.SentUnicastPackets
    } catch {}
}

# nvidia-smi path cache
$smiPath = $null
if ($gpuAvailable) {
    $smiCmd2 = Get-Command 'nvidia-smi' -ErrorAction SilentlyContinue
    if ($smiCmd2) { $smiPath = $smiCmd2.Source }
}

# Use Get-Counter with 1s interval for reliable data — WMI PerfFormatted is
# cached at ~1s anyway. Get-Counter gives accurate per-interval rates.
# For sub-second insight, we also interleave fast nvidia-smi + NIC polling.

$counterPaths = @(
    '\Processor(_Total)\% Processor Time'
    '\Processor(_Total)\% DPC Time'
    '\Processor(_Total)\% Interrupt Time'
    '\Processor(_Total)\% Privileged Time'
    '\Processor(_Total)\Interrupts/sec'
    '\System\Context Switches/sec'
    '\Processor(4)\% DPC Time'
    '\Processor(5)\% DPC Time'
    '\Processor(6)\% DPC Time'
    '\Processor(7)\% DPC Time'
)

# Strategy: Run Get-Counter in 1s intervals (its minimum), but interleave
# GPU + NIC fast-polls between counter samples for higher-res on those sources.
# This gives ~1s resolution for CPU/DPC (hardware limitation) but can detect
# GPU/NIC bursts at faster rates.

$sw = [Diagnostics.Stopwatch]::StartNew()
$targetMs = [int64]$DurationSec * 1000
$sampleCount = 0

while ($sw.ElapsedMilliseconds -lt $targetMs) {
    $iterSw = [Diagnostics.Stopwatch]::StartNew()
    $sample = [ordered]@{
        timestampMs = $sw.ElapsedMilliseconds
    }

    # --- CPU / DPC / Interrupt via Get-Counter (1s sample) ---
    try {
        $counters = Get-Counter -Counter $counterPaths -MaxSamples 1 -ErrorAction SilentlyContinue
        if ($counters) {
            foreach ($cs in $counters.CounterSamples) {
                $p = $cs.Path.ToLower()
                if ($p.Contains('_total') -and $p.Contains('% processor time')) { $sample.cpuPct = [math]::Round($cs.CookedValue, 2) }
                elseif ($p.Contains('_total') -and $p.Contains('% dpc time')) { $sample.dpcPct = [math]::Round($cs.CookedValue, 4) }
                elseif ($p.Contains('_total') -and $p.Contains('% interrupt time')) { $sample.intPct = [math]::Round($cs.CookedValue, 4) }
                elseif ($p.Contains('_total') -and $p.Contains('% privileged')) { $sample.privPct = [math]::Round($cs.CookedValue, 2) }
                elseif ($p.Contains('interrupts/sec')) { $sample.intrPerSec = [math]::Round($cs.CookedValue, 0) }
                elseif ($p.Contains('context switches')) { $sample.ctxSwitchPerSec = [math]::Round($cs.CookedValue, 0) }
                elseif ($p.Contains('\processor(4)')) { $sample.cpu4DpcPct = [math]::Round($cs.CookedValue, 4) }
                elseif ($p.Contains('\processor(5)')) { $sample.cpu5DpcPct = [math]::Round($cs.CookedValue, 4) }
                elseif ($p.Contains('\processor(6)')) { $sample.cpu6DpcPct = [math]::Round($cs.CookedValue, 4) }
                elseif ($p.Contains('\processor(7)')) { $sample.cpu7DpcPct = [math]::Round($cs.CookedValue, 4) }
            }
            # Compute bulk DPC average
            $bulkDpcSum = 0.0
            $bulkCount = 0
            if ($sample.cpu4DpcPct -ne $null) { $bulkDpcSum += $sample.cpu4DpcPct; $bulkCount++ }
            if ($sample.cpu5DpcPct -ne $null) { $bulkDpcSum += $sample.cpu5DpcPct; $bulkCount++ }
            if ($sample.cpu6DpcPct -ne $null) { $bulkDpcSum += $sample.cpu6DpcPct; $bulkCount++ }
            if ($sample.cpu7DpcPct -ne $null) { $bulkDpcSum += $sample.cpu7DpcPct; $bulkCount++ }
            if ($bulkCount -gt 0) { $sample.bulkCpuDpcPct = [math]::Round($bulkDpcSum / $bulkCount, 4) }
        }
    } catch {
        $sample.cpuPct = -1
    }

    # --- GPU (nvidia-smi one-liner ~50ms) ---
    if ($gpuAvailable -and $smiPath) {
        try {
            $gpuLine = & $smiPath --query-gpu=clocks.gr,clocks.mem,pstate,utilization.gpu,power.draw --format=csv,noheader,nounits 2>$null
            if ($gpuLine) {
                $gp = $gpuLine.Trim().Split(',')
                $sample.gpuCoreMHz = [int]$gp[0].Trim()
                $sample.gpuMemMHz = [int]$gp[1].Trim()
                $sample.gpuPstate = $gp[2].Trim()
                $sample.gpuUtilPct = [int]$gp[3].Trim()
                $sample.gpuPowerW = [double]$gp[4].Trim()
            }
        } catch {}
    }

    # --- NIC packet delta ---
    if ($nicAvailable) {
        try {
            $nicStats = Get-NetAdapterStatistics -Name $nicName -ErrorAction SilentlyContinue
            if ($nicStats) {
                $curRx = $nicStats.ReceivedUnicastPackets
                $curTx = $nicStats.SentUnicastPackets
                if (-not $firstNicSample) {
                    $sample.nicRxDelta = $curRx - $prevNicRx
                    $sample.nicTxDelta = $curTx - $prevNicTx
                } else {
                    $firstNicSample = $false
                }
                $prevNicRx = $curRx
                $prevNicTx = $curTx
            }
        } catch {}
    }

    $sample.actualIntervalMs = $iterSw.ElapsedMilliseconds
    $timeline += $sample
    $sampleCount++

    # Progress indicator
    if ($sampleCount % 5 -eq 0) {
        Write-Host '.' -NoNewline
    }
}

$totalElapsed = $sw.ElapsedMilliseconds
Write-Host ''
Log ('  Captured ' + $sampleCount + ' samples in ' + [math]::Round($totalElapsed / 1000, 1) + 's (avg interval: ' + [math]::Round($totalElapsed / [math]::Max(1, $sampleCount), 0) + 'ms)')
Write-Host ''

# ============================================================================
# PHASE 3: BURST DETECTION
# ============================================================================

Log 'Phase 3: Burst detection'

# Extract series
$cpuValues = @($timeline | ForEach-Object { [double]$_.cpuPct } | Where-Object { $_ -ge 0 })
$dpcValues = @($timeline | ForEach-Object { [double]$_.dpcPct } | Where-Object { $_ -ge 0 })
$intValues = @($timeline | ForEach-Object { [double]$_.intrPerSec } | Where-Object { $_ -ge 0 })
$ctxValues = @($timeline | ForEach-Object { [double]$_.ctxSwitchPerSec } | Where-Object { $_ -gt 0 })

$gpuClockValues = @()
$nicRxValues = @()
if ($gpuAvailable) {
    $gpuClockValues = @($timeline | Where-Object { $_.gpuCoreMHz } | ForEach-Object { [double]$_.gpuCoreMHz })
}
if ($nicAvailable) {
    $nicRxValues = @($timeline | Where-Object { $_.nicRxDelta -ne $null } | ForEach-Object { [double]$_.nicRxDelta })
}

# Burstiness scores
$scores = @{
    cpu       = Get-BurstinessScore $cpuValues
    dpc       = Get-BurstinessScore $dpcValues
    interrupt = Get-BurstinessScore $intValues
    ctxSwitch = Get-BurstinessScore $ctxValues
    gpu       = 0.0
    nic       = 0.0
}
if ($gpuClockValues.Count -gt 2) {
    $scores.gpu = Get-BurstinessScore $gpuClockValues
}
if ($nicRxValues.Count -gt 2) {
    $scores.nic = Get-BurstinessScore $nicRxValues
}

Log ('  Burstiness scores:')
foreach ($key in @('cpu','dpc','interrupt','ctxSwitch','gpu','nic')) {
    $val = $scores[$key]
    $verdict = 'smooth'
    $color = 'PASS'
    if ($val -gt 0.3) { $verdict = 'moderate'; $color = 'WARN' }
    if ($val -gt 0.6) { $verdict = 'BURSTY'; $color = 'FAIL' }
    Log ('    ' + $key.PadRight(12) + ' = ' + $val.ToString('0.0000') + '  (' + $verdict + ')') $color
}

# Peak detection on CPU%
$cpuSamples = @($timeline | Where-Object { [double]$_.cpuPct -ge 0 } | ForEach-Object {
    @{ timestampMs = [double]$_.timestampMs; value = [double]$_.cpuPct }
})
$cpuPeaks = @(Get-BurstPeaks $cpuSamples 2.0)
Log ('  CPU peaks (>2sigma): ' + $cpuPeaks.Count)

# Burst frequency
$peakTimestamps = @($cpuPeaks | ForEach-Object { [double]$_.timestampMs })
$burstFreq = Get-BurstFrequency $peakTimestamps 50
if ($burstFreq.dominantIntervalMs -gt 0) {
    $freqHz = [math]::Round(1000.0 / $burstFreq.dominantIntervalMs, 2)
    Log ('  Dominant burst interval: ' + [math]::Round($burstFreq.dominantIntervalMs, 0) + 'ms (~' + $freqHz + ' Hz, regularity=' + $burstFreq.regularityScore + ')')
} else {
    Log '  No dominant burst frequency detected (peaks too sparse or irregular)'
}

Write-Host ''

# ============================================================================
# PHASE 4: CROSS-SOURCE CORRELATION
# ============================================================================

Log 'Phase 4: Cross-source correlation'

$correlations = @{}

# Build peak sets for each source
$dpcSamples = @($timeline | Where-Object { [double]$_.dpcPct -ge 0 } | ForEach-Object {
    @{ timestampMs = [double]$_.timestampMs; value = [double]$_.dpcPct }
})
$dpcPeaks = @(Get-BurstPeaks $dpcSamples 2.0)

$correlations.cpuDpc = Get-CrossCorrelation $cpuPeaks $dpcPeaks 300
Log ('  CPU<->DPC:  ' + $correlations.cpuDpc.coincidentCount + '/' + $correlations.cpuDpc.totalA + ' coincident (score=' + $correlations.cpuDpc.correlationScore + ')')

if ($gpuAvailable -and $gpuClockValues.Count -gt 2) {
    $gpuSamples = @($timeline | Where-Object { $_.gpuCoreMHz } | ForEach-Object {
        @{ timestampMs = [double]$_.timestampMs; value = [double]$_.gpuCoreMHz }
    })
    $gpuPeaks = @(Get-BurstPeaks $gpuSamples 2.0)
    $correlations.cpuGpu = Get-CrossCorrelation $cpuPeaks $gpuPeaks 300
    Log ('  CPU<->GPU:  ' + $correlations.cpuGpu.coincidentCount + '/' + $correlations.cpuGpu.totalA + ' coincident (score=' + $correlations.cpuGpu.correlationScore + ')')
}

if ($nicAvailable -and $nicRxValues.Count -gt 2) {
    $nicSamples = @($timeline | Where-Object { $_.nicRxDelta -ne $null } | ForEach-Object {
        @{ timestampMs = [double]$_.timestampMs; value = [double]$_.nicRxDelta }
    })
    $nicPeaks = @(Get-BurstPeaks $nicSamples 2.0)
    $correlations.cpuNic = Get-CrossCorrelation $cpuPeaks $nicPeaks 300
    Log ('  CPU<->NIC:  ' + $correlations.cpuNic.coincidentCount + '/' + $correlations.cpuNic.totalA + ' coincident (score=' + $correlations.cpuNic.correlationScore + ')')
}

Write-Host ''

# ============================================================================
# PHASE 5: ROOT CAUSE DIAGNOSIS
# ============================================================================

Log 'Phase 5: Root cause diagnosis'

$diagnoses = @(Get-BurstDiagnosis -Scores $scores -DominantIntervalMs $burstFreq.dominantIntervalMs -SystemState $systemState -Correlations $correlations)

Write-Host ''
Write-Host '  ============================================' -ForegroundColor Yellow
Write-Host '  BURST PATTERN DIAGNOSIS' -ForegroundColor Yellow
Write-Host '  ============================================' -ForegroundColor Yellow
Write-Host ''

$rank = 1
foreach ($d in $diagnoses) {
    $confPct = [int]($d.confidence * 100)
    $color = 'DarkGray'
    if ($d.confidence -ge 0.7) { $color = 'Red' }
    elseif ($d.confidence -ge 0.4) { $color = 'Yellow' }
    else { $color = 'DarkGray' }

    Write-Host ('  #' + $rank + ' [' + $confPct + '%] ') -NoNewline -ForegroundColor $color
    Write-Host $d.cause -ForegroundColor White
    Write-Host ('       Burstiness: ' + $d.burstinessScore) -ForegroundColor DarkGray
    Write-Host ('       Pattern:    ' + $d.intervalMatch) -ForegroundColor DarkGray
    Write-Host ('       Fix:        ' + $d.fix) -ForegroundColor Cyan
    if ($d.fixScript) {
        Write-Host ('       Script:     ' + $d.fixScript) -ForegroundColor DarkCyan
    }
    Write-Host ''
    $rank++
}

# --- pktmon guidance (if NIC bursts detected) ---
if ($scores.nic -gt 0.3) {
    Write-Host '  --- Network Burst Investigation ---' -ForegroundColor Yellow
    Write-Host '  NIC burstiness detected. To investigate further:' -ForegroundColor White
    Write-Host ''
    Write-Host '  1. Capture packets:' -ForegroundColor Cyan
    Write-Host '     pktmon start --capture --pkt-size 128 --comp nics'
    Write-Host '     (reproduce the issue for 30 seconds)'
    Write-Host '     pktmon stop'
    Write-Host ''
    Write-Host '  2. Convert for analysis:' -ForegroundColor Cyan
    Write-Host '     pktmon etl2pcap pktmon.etl -o burst_capture.pcapng'
    Write-Host ''
    Write-Host '  3. Analyze packet timing:' -ForegroundColor Cyan
    Write-Host '     - Wireshark: Statistics > IO Graph (set interval to 10ms)'
    Write-Host '     - Or: tshark -r burst_capture.pcapng -T fields -e frame.time_delta'
    Write-Host ''
    Write-Host '  Note: Wireshark not currently installed.' -ForegroundColor DarkGray
    Write-Host '  Download: https://www.wireshark.org/download.html' -ForegroundColor DarkGray
    Write-Host '  pktmon (built-in) is sufficient for timing analysis.' -ForegroundColor DarkGray
    Write-Host ''
}

# ============================================================================
# PHASE 6: OUTPUT
# ============================================================================

Log 'Phase 6: Saving results'

# --- CSV timeline ---
$csvPath = Join-Path $OutDir 'burst_timeline.csv'
$csvHeader = 'timestampMs,cpuPct,dpcPct,intPct,privPct,intrPerSec,ctxSwitchPerSec,bulkCpuDpcPct'
if ($gpuAvailable) { $csvHeader += ',gpuCoreMHz,gpuMemMHz,gpuPstate,gpuUtilPct,gpuPowerW' }
if ($nicAvailable) { $csvHeader += ',nicRxDelta,nicTxDelta' }
$csvHeader += ',actualIntervalMs'

function Safe-Str($val) {
    if ($null -eq $val) { return '' }
    return $val.ToString()
}

$csvLines = @($csvHeader)
foreach ($s in $timeline) {
    $line = (Safe-Str $s.timestampMs) + ',' +
            (Safe-Str $s.cpuPct) + ',' +
            (Safe-Str $s.dpcPct) + ',' +
            (Safe-Str $s.intPct) + ',' +
            (Safe-Str $s.privPct) + ',' +
            (Safe-Str $s.intrPerSec) + ',' +
            (Safe-Str $s.ctxSwitchPerSec) + ',' +
            (Safe-Str $s.bulkCpuDpcPct)

    if ($gpuAvailable) {
        $line += ',' + (Safe-Str $s.gpuCoreMHz) + ',' + (Safe-Str $s.gpuMemMHz) + ',' + (Safe-Str $s.gpuPstate) + ',' + (Safe-Str $s.gpuUtilPct) + ',' + (Safe-Str $s.gpuPowerW)
    }
    if ($nicAvailable) {
        $line += ',' + (Safe-Str $s.nicRxDelta) + ',' + (Safe-Str $s.nicTxDelta)
    }
    $line += ',' + (Safe-Str $s.actualIntervalMs)
    $csvLines += $line
}
$csvLines | Set-Content -Path $csvPath -Encoding UTF8
Log ('  Timeline CSV: ' + $csvPath)

# --- JSON analysis ---
$jsonPath = Join-Path $OutDir 'burst_analysis.json'
$analysis = [ordered]@{
    _meta = [ordered]@{
        capturedAt    = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        durationSec   = $DurationSec
        sampleInterval = $SampleIntervalMs
        sampleCount   = $sampleCount
        avgIntervalMs = [math]::Round($totalElapsed / [math]::Max(1, $sampleCount), 1)
    }
    systemState = $systemState
    burstinessScores = $scores
    cpuStats = Get-Stats $cpuValues
    dpcStats = Get-Stats $dpcValues
    interruptStats = Get-Stats $intValues
    ctxSwitchStats = Get-Stats $ctxValues
    peakDetection = [ordered]@{
        cpuPeakCount = $cpuPeaks.Count
        dpcPeakCount = $dpcPeaks.Count
        dominantIntervalMs = $burstFreq.dominantIntervalMs
        regularityScore = $burstFreq.regularityScore
        burstHistogram = $burstFreq.histogram
    }
    correlations = $correlations
    diagnoses = $diagnoses
}

if ($gpuClockValues.Count -gt 2) {
    $analysis.gpuClockStats = Get-Stats $gpuClockValues
}
if ($nicRxValues.Count -gt 2) {
    $analysis.nicRxStats = Get-Stats $nicRxValues
}

$analysis | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8
Log ('  Analysis JSON: ' + $jsonPath)

# --- Summary ---
Write-Host ''
Write-Host '======================================================' -ForegroundColor Cyan
Write-Host '  SUMMARY' -ForegroundColor Cyan
Write-Host '======================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host ('  Samples:        ' + $sampleCount + ' in ' + [math]::Round($totalElapsed / 1000, 1) + 's')
Write-Host ('  CPU burstiness: ' + $scores.cpu.ToString('0.0000'))
Write-Host ('  DPC burstiness: ' + $scores.dpc.ToString('0.0000'))
Write-Host ('  GPU burstiness: ' + $scores.gpu.ToString('0.0000'))
Write-Host ('  NIC burstiness: ' + $scores.nic.ToString('0.0000'))
if ($burstFreq.dominantIntervalMs -gt 0) {
    Write-Host ('  Burst frequency: ~' + [math]::Round($burstFreq.dominantIntervalMs, 0) + 'ms interval')
}
Write-Host ''
Write-Host ('  Top diagnosis:  ' + $diagnoses[0].cause + ' (' + [int]($diagnoses[0].confidence * 100) + '% confidence)')
Write-Host ''

# Open output directory
Write-Host ('  Results: ' + $OutDir) -ForegroundColor Green
Write-Host ('  CSV:     ' + $csvPath) -ForegroundColor Green
Write-Host ('  JSON:    ' + $jsonPath) -ForegroundColor Green
Write-Host ''
