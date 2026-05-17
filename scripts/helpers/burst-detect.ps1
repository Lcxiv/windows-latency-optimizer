# helpers/burst-detect.ps1
# Burst pattern detection and analysis functions.
# Dot-sourced by diagnose-burst-pattern.ps1.
# PowerShell 5.1 compatible — no ternary, no null-coalescing.

function Get-BurstinessScore {
    <#
    .SYNOPSIS
        Compute coefficient of variation (CV) for a numeric series.
        CV = stdev / mean. 0 = perfectly smooth, >1 = very bursty.
    .PARAMETER Values
        Array of numeric values (e.g., CPU% samples over time).
    .OUTPUTS
        [double] CV score. Returns 0 if mean is 0 or array is empty.
    #>
    param([double[]]$Values)

    if ($null -eq $Values -or $Values.Count -lt 2) { return 0.0 }

    $m = $Values | Measure-Object -Average
    $avg = $m.Average
    if ($avg -eq 0) { return 0.0 }

    $sumSq = 0.0
    foreach ($v in $Values) { $sumSq += ($v - $avg) * ($v - $avg) }
    $sd = [math]::Sqrt($sumSq / ($Values.Count - 1))

    return [math]::Round($sd / $avg, 4)
}

function Get-BurstPeaks {
    <#
    .SYNOPSIS
        Find samples that exceed mean + ThresholdSigma * stdev.
    .PARAMETER Samples
        Array of hashtables with 'timestampMs' and 'value' keys.
    .PARAMETER ThresholdSigma
        Number of standard deviations above mean to consider a peak. Default 2.0.
    .OUTPUTS
        Array of hashtables: @{ timestampMs; value; threshold }
    #>
    param(
        [array]$Samples,
        [double]$ThresholdSigma = 2.0
    )

    if ($null -eq $Samples -or $Samples.Count -lt 3) { return @() }

    $values = @($Samples | ForEach-Object { [double]$_.value })
    $m = $values | Measure-Object -Average
    $avg = $m.Average

    $sumSq = 0.0
    foreach ($v in $values) { $sumSq += ($v - $avg) * ($v - $avg) }
    $sd = [math]::Sqrt($sumSq / ($values.Count - 1))

    $threshold = $avg + ($ThresholdSigma * $sd)
    $peaks = @()

    foreach ($s in $Samples) {
        if ([double]$s.value -gt $threshold) {
            $peaks += @{
                timestampMs = $s.timestampMs
                value       = [double]$s.value
                threshold   = [math]::Round($threshold, 2)
            }
        }
    }

    return $peaks
}

function Get-BurstFrequency {
    <#
    .SYNOPSIS
        Compute dominant burst frequency from peak timestamps.
        Builds histogram of inter-peak intervals, returns mode.
    .PARAMETER PeakTimestampsMs
        Array of peak timestamps in milliseconds.
    .PARAMETER BinWidthMs
        Histogram bin width. Default 50ms.
    .OUTPUTS
        Hashtable: @{ dominantIntervalMs; peakCount; regularityScore; histogram }
        regularityScore: 0-1, how concentrated peaks are around the dominant interval.
    #>
    param(
        [double[]]$PeakTimestampsMs,
        [int]$BinWidthMs = 50
    )

    $result = @{
        dominantIntervalMs = 0
        peakCount          = 0
        regularityScore    = 0.0
        histogram          = @()
    }

    if ($null -eq $PeakTimestampsMs -or $PeakTimestampsMs.Count -lt 2) {
        $result.peakCount = 0
        if ($PeakTimestampsMs) { $result.peakCount = $PeakTimestampsMs.Count }
        return $result
    }

    $result.peakCount = $PeakTimestampsMs.Count

    # Sort timestamps
    $sorted = @($PeakTimestampsMs | Sort-Object)

    # Compute inter-peak intervals
    $intervals = @()
    for ($i = 1; $i -lt $sorted.Count; $i++) {
        $intervals += ($sorted[$i] - $sorted[$i - 1])
    }

    if ($intervals.Count -eq 0) { return $result }

    # Build histogram
    $bins = @{}
    foreach ($interval in $intervals) {
        $binKey = [math]::Floor($interval / $BinWidthMs) * $BinWidthMs
        if (-not $bins.ContainsKey($binKey)) { $bins[$binKey] = 0 }
        $bins[$binKey]++
    }

    # Find mode (most common bin)
    $maxCount = 0
    $modeBin = 0
    foreach ($key in $bins.Keys) {
        if ($bins[$key] -gt $maxCount) {
            $maxCount = $bins[$key]
            $modeBin = $key
        }
    }

    $result.dominantIntervalMs = $modeBin + ($BinWidthMs / 2)  # bin center

    # Regularity score: what fraction of intervals fall in the dominant bin ± 1 bin
    $nearDominant = 0
    foreach ($interval in $intervals) {
        $diff = [math]::Abs($interval - $result.dominantIntervalMs)
        if ($diff -le ($BinWidthMs * 1.5)) { $nearDominant++ }
    }
    $result.regularityScore = [math]::Round($nearDominant / $intervals.Count, 3)

    # Flatten histogram for JSON
    $histArray = @()
    foreach ($key in ($bins.Keys | Sort-Object)) {
        $histArray += @{ binMs = $key; count = $bins[$key] }
    }
    $result.histogram = $histArray

    return $result
}

function Get-CrossCorrelation {
    <#
    .SYNOPSIS
        Check if peaks in two series coincide within a time tolerance.
    .PARAMETER PeaksA
        Array of peak hashtables from Get-BurstPeaks (must have timestampMs).
    .PARAMETER PeaksB
        Array of peak hashtables from Get-BurstPeaks (must have timestampMs).
    .PARAMETER ToleranceMs
        Time window to consider peaks as coincident. Default 200ms.
    .OUTPUTS
        Hashtable: @{ coincidentCount; totalA; totalB; correlationScore }
        correlationScore: fraction of A peaks that have a matching B peak.
    #>
    param(
        [array]$PeaksA,
        [array]$PeaksB,
        [int]$ToleranceMs = 200
    )

    $result = @{
        coincidentCount  = 0
        totalA           = 0
        totalB           = 0
        correlationScore = 0.0
    }

    if ($null -eq $PeaksA) { $PeaksA = @() }
    if ($null -eq $PeaksB) { $PeaksB = @() }
    $result.totalA = $PeaksA.Count
    $result.totalB = $PeaksB.Count

    if ($PeaksA.Count -eq 0 -or $PeaksB.Count -eq 0) { return $result }

    $bTimestamps = @($PeaksB | ForEach-Object { [double]$_.timestampMs })

    $coincident = 0
    foreach ($peakA in $PeaksA) {
        $tsA = [double]$peakA.timestampMs
        foreach ($tsB in $bTimestamps) {
            if ([math]::Abs($tsA - $tsB) -le $ToleranceMs) {
                $coincident++
                break
            }
        }
    }

    $result.coincidentCount = $coincident
    $result.correlationScore = [math]::Round($coincident / $PeaksA.Count, 3)

    return $result
}

function Get-BurstDiagnosis {
    <#
    .SYNOPSIS
        Classify burst root cause based on scores, frequency, and system state.
    .PARAMETER Scores
        Hashtable of burstiness scores per source: @{ cpu; dpc; gpu; nic; ctxSwitch }
    .PARAMETER DominantIntervalMs
        Dominant burst interval in milliseconds (from Get-BurstFrequency).
    .PARAMETER SystemState
        Hashtable of system state: @{ timerResolutionMs; timerCoalescing; gpuClockLocked; nicITR; powerPlan }
    .PARAMETER Correlations
        Hashtable of cross-correlations: @{ cpuDpc; cpuGpu; cpuNic }
    .OUTPUTS
        Array of diagnosis hashtables sorted by confidence:
        @{ cause; confidence; burstinessScore; intervalMatch; fix; fixScript }
    #>
    param(
        [hashtable]$Scores,
        [double]$DominantIntervalMs,
        [hashtable]$SystemState,
        [hashtable]$Correlations
    )

    $diagnoses = @()

    # --- Pattern 1: WMI/Afterburner polling (~1000ms ± 200ms) ---
    if ($DominantIntervalMs -ge 800 -and $DominantIntervalMs -le 1200) {
        $conf = 0.7
        if ($Scores.dpc -gt 0.3) { $conf += 0.1 }
        $diagnoses += @{
            cause            = 'WMI/Afterburner polling cycle'
            confidence       = [math]::Round($conf, 2)
            burstinessScore  = $Scores.cpu
            intervalMatch    = '~1s matches Afterburner/WMI polling interval'
            fix              = 'Increase Afterburner polling to 2000ms. Winmgmt polling (3,425/sec) is unfixable Windows bug.'
            fixScript        = 'MSI Afterburner > Settings > Hardware Monitoring > Update Period'
        }
    }

    # --- Pattern 2: Timer tick alignment (~15.6ms or multiples) ---
    $timerMultiple = $false
    if ($DominantIntervalMs -gt 0) {
        $ratio = $DominantIntervalMs / 15.625
        $remainder = $ratio - [math]::Round($ratio)
        if ([math]::Abs($remainder) -lt 0.15) { $timerMultiple = $true }
    }
    if ($timerMultiple) {
        $conf = 0.5
        if ($SystemState.timerResolutionMs -gt 1.0) { $conf += 0.2 }
        if ($SystemState.timerCoalescing -eq $true) { $conf += 0.2 }
        $diagnoses += @{
            cause            = 'Timer tick coalescing'
            confidence       = [math]::Round($conf, 2)
            burstinessScore  = $Scores.cpu
            intervalMatch    = 'Interval is multiple of 15.625ms timer tick'
            fix              = 'Disable timer coalescing via powercfg. Check if Set Timer Resolution Service is running.'
            fixScript        = 'powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP IDLETIMER 0'
        }
    }

    # --- Pattern 3: GPU P-state transitions ---
    if ($Scores.gpu -gt 0.3) {
        $conf = 0.4
        if ($Correlations -and $Correlations.cpuGpu -and $Correlations.cpuGpu.correlationScore -gt 0.3) {
            $conf += 0.3
        }
        $gpuLocked = $false
        if ($SystemState.gpuClockLocked) { $gpuLocked = $true }
        if (-not $gpuLocked) { $conf += 0.15 }
        $diagnoses += @{
            cause            = 'GPU P-state transitions'
            confidence       = [math]::Round($conf, 2)
            burstinessScore  = $Scores.gpu
            intervalMatch    = 'GPU clock variance correlates with CPU bursts'
            fix              = 'Lock GPU clocks to prevent P-state DPC generation.'
            fixScript        = '.\scripts\exp21_msi_gpu_clocks.ps1'
        }
    }

    # --- Pattern 4: NIC interrupt bursts ---
    if ($Scores.nic -gt 0.4) {
        $conf = 0.3
        if ($Correlations -and $Correlations.cpuNic -and $Correlations.cpuNic.correlationScore -gt 0.3) {
            $conf += 0.3
        }
        $diagnoses += @{
            cause            = 'NIC interrupt moderation / packet bursts'
            confidence       = [math]::Round($conf, 2)
            burstinessScore  = $Scores.nic
            intervalMatch    = 'NIC packet rate correlates with CPU bursts'
            fix              = 'Check ITR setting. Use pktmon to capture packet timing.'
            fixScript        = '.\scripts\exp12_nic_framepacing_apply.ps1'
        }
    }

    # --- Pattern 5: DPC batching ---
    if ($Scores.dpc -gt 0.5) {
        $conf = 0.5
        if ($Correlations -and $Correlations.cpuDpc -and $Correlations.cpuDpc.correlationScore -gt 0.5) {
            $conf += 0.2
        }
        $diagnoses += @{
            cause            = 'DPC batching / driver stalls'
            confidence       = [math]::Round($conf, 2)
            burstinessScore  = $Scores.dpc
            intervalMatch    = 'DPC% spikes coincide with CPU bursts'
            fix              = 'Run analyze-dpc-deep.ps1 to identify offending driver. Check interrupt affinity.'
            fixScript        = '.\scripts\analyze-dpc-deep.ps1'
        }
    }

    # --- Pattern 6: Context switch storms ---
    if ($Scores.ctxSwitch -gt 0.4) {
        $conf = 0.3
        $diagnoses += @{
            cause            = 'Context switch storms (MMCSS or scheduler)'
            confidence       = [math]::Round($conf, 2)
            burstinessScore  = $Scores.ctxSwitch
            intervalMatch    = 'Context switch rate variance indicates scheduling bursts'
            fix              = 'Check MMCSS SystemResponsiveness. Verify no CPU-bound background processes.'
            fixScript        = 'Registry: HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\SystemResponsiveness'
        }
    }

    # --- Always present: C-state wake pattern ---
    $diagnoses += @{
        cause            = 'CPU C-state idle/wake transitions (expected)'
        confidence       = 0.9
        burstinessScore  = $Scores.cpu
        intervalMatch    = 'All modern CPUs burst by design — sleep during idle, wake for work'
        fix              = 'Normal behavior. Disable C-states in BIOS only if latency-critical (increases idle power).'
        fixScript        = '.\scripts\exp07_cstates_guide.ps1'
    }

    # Sort by confidence descending
    $diagnoses = @($diagnoses | Sort-Object { -$_.confidence })

    return $diagnoses
}
