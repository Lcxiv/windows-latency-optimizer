# helpers/monitor-counters.ps1
# Performance counter sampling helper for real-time latency monitoring.
# Dot-sourced by monitor_collector.ps1.
# PowerShell 5.1 compatible — no ternary, no null-coalescing, no Join-String,
# no -StandardDeviation on Measure-Object. $error and $pid are reserved.

# ---------------------------------------------------------------------------
# Rolling history buffers (max 30 entries per metric)
# ---------------------------------------------------------------------------
# CPU count — cached once at module load (static, never changes at runtime)
$script:MonitorCpuCount = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors

$script:MonitorHistory = @{
    contextSwitches = New-Object System.Collections.ArrayList
    totalDpc        = New-Object System.Collections.ArrayList
    totalInterrupt  = New-Object System.Collections.ArrayList
}

# ---------------------------------------------------------------------------
# Helper: Add-ToRollingBuffer
# Appends a value to an ArrayList and trims it to MaxCount entries.
# ---------------------------------------------------------------------------
function Add-ToRollingBuffer {
    <#
    .SYNOPSIS
        Add a numeric value to a rolling ArrayList, trimming to a max size.
    .PARAMETER Buffer
        The ArrayList to append to.
    .PARAMETER Value
        Numeric value to append.
    .PARAMETER MaxCount
        Maximum number of entries to retain. Default 30.
    #>
    param(
        [System.Collections.ArrayList]$Buffer,
        [double]$Value,
        [int]$MaxCount = 30
    )

    [void]$Buffer.Add($Value)
    while ($Buffer.Count -gt $MaxCount) {
        $Buffer.RemoveAt(0)
    }
}

# ---------------------------------------------------------------------------
# Helper: Get-RollingAverage
# Returns the arithmetic mean of an ArrayList. Returns 0 when empty.
# ---------------------------------------------------------------------------
function Get-RollingAverage {
    <#
    .SYNOPSIS
        Compute the arithmetic mean of an ArrayList of numeric values.
    .PARAMETER Buffer
        The ArrayList to average.
    .OUTPUTS
        [double] Average, or 0.0 if the buffer is empty.
    #>
    param(
        [System.Collections.ArrayList]$Buffer
    )

    if ($null -eq $Buffer -or $Buffer.Count -eq 0) { return 0.0 }

    $sum = 0.0
    foreach ($v in $Buffer) { $sum += $v }
    return $sum / $Buffer.Count
}

# ---------------------------------------------------------------------------
# Main function: Get-MonitorCounterSample
# ---------------------------------------------------------------------------
function Get-MonitorCounterSample {
    <#
    .SYNOPSIS
        Sample DPC%, Interrupt%, Interrupts/sec for all logical CPUs plus system-level
        counters. Detects spikes via rolling-average comparison.
    .OUTPUTS
        Hashtable with keys:
            timestamp  [datetime]
            perCpu     [array]    — one entry per logical CPU: @{ cpu; dpcPct; intrPct; intrPerSec }
            system     [hashtable]— @{ dpcPct; intrPct; intrPerSec; ctxSwitchSec; procQueueLen }
            spikes     [hashtable]— @{ highDpcCpus; contextSwitchSpike; totalDpcSpike; totalInterruptSpike }
    #>

    # ------------------------------------------------------------------
    # CPU count (cached at module load — see $script:MonitorCpuCount)
    # ------------------------------------------------------------------
    $cpuCount = $script:MonitorCpuCount

    # ------------------------------------------------------------------
    # Build counter path lists (ArrayList avoids array reallocation)
    # ------------------------------------------------------------------
    $cpuCounters = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $cpuCount; $i++) {
        $cpuCounters.Add('\Processor(' + $i + ')\% DPC Time')
        $cpuCounters.Add('\Processor(' + $i + ')\% Interrupt Time')
        $cpuCounters.Add('\Processor(' + $i + ')\Interrupts/sec')
    }

    $systemCounters = @(
        '\Processor(_Total)\% DPC Time',
        '\Processor(_Total)\% Interrupt Time',
        '\Processor(_Total)\Interrupts/sec',
        '\System\Context Switches/sec',
        '\System\Processor Queue Length'
    )

    $allCounters = $cpuCounters.ToArray() + $systemCounters

    # ------------------------------------------------------------------
    # Sample once (1-second window)
    # ------------------------------------------------------------------
    try {
        $rawSamples = Get-Counter -Counter $allCounters -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
    } catch {
        return $null
    }
    if ($null -eq $rawSamples) { return $null }

    # Flatten all CounterSamples into a lookup: path -> CookedValue
    # Normalise path to lowercase for consistent key matching.
    $sampleSet = $rawSamples | Select-Object -First 1
    $lookup = @{}
    foreach ($cs in $sampleSet.CounterSamples) {
        $lookup[$cs.Path.ToLower()] = $cs.CookedValue
    }

    # ------------------------------------------------------------------
    # Parse per-CPU data (all logical CPUs, indices 0 to cpuCount-1)
    # ------------------------------------------------------------------
    $perCpu = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $cpuCount; $i++) {
        $dpcKey  = ('\\' + $env:COMPUTERNAME + '\processor(' + $i + ')\% dpc time').ToLower()
        $intrKey = ('\\' + $env:COMPUTERNAME + '\processor(' + $i + ')\% interrupt time').ToLower()
        $ipsKey  = ('\\' + $env:COMPUTERNAME + '\processor(' + $i + ')\interrupts/sec').ToLower()

        $dpcVal  = 0.0
        $intrVal = 0.0
        $ipsVal  = 0.0

        if ($lookup.ContainsKey($dpcKey))  { $dpcVal  = [math]::Round($lookup[$dpcKey],  3) }
        if ($lookup.ContainsKey($intrKey)) { $intrVal = [math]::Round($lookup[$intrKey], 3) }
        if ($lookup.ContainsKey($ipsKey))  { $ipsVal  = [math]::Round($lookup[$ipsKey],  1) }

        [void]$perCpu.Add(@{
            cpu        = $i
            dpcPct     = $dpcVal
            intrPct    = $intrVal
            intrPerSec = $ipsVal
        })
    }

    # ------------------------------------------------------------------
    # Parse system-level counters
    # ------------------------------------------------------------------
    $totalDpcKey  = ('\\' + $env:COMPUTERNAME + '\processor(_total)\% dpc time').ToLower()
    $totalIntrKey = ('\\' + $env:COMPUTERNAME + '\processor(_total)\% interrupt time').ToLower()
    $totalIpsKey  = ('\\' + $env:COMPUTERNAME + '\processor(_total)\interrupts/sec').ToLower()
    $ctxKey       = ('\\' + $env:COMPUTERNAME + '\system\context switches/sec').ToLower()
    $queueKey     = ('\\' + $env:COMPUTERNAME + '\system\processor queue length').ToLower()

    $sysDpcPct     = 0.0
    $sysIntrPct    = 0.0
    $sysIntrPerSec = 0.0
    $sysCtxSwitch  = 0.0
    $sysProcQueue  = 0.0

    if ($lookup.ContainsKey($totalDpcKey))  { $sysDpcPct     = [math]::Round($lookup[$totalDpcKey],  3) }
    if ($lookup.ContainsKey($totalIntrKey)) { $sysIntrPct    = [math]::Round($lookup[$totalIntrKey], 3) }
    if ($lookup.ContainsKey($totalIpsKey))  { $sysIntrPerSec = [math]::Round($lookup[$totalIpsKey],  1) }
    if ($lookup.ContainsKey($ctxKey))       { $sysCtxSwitch  = [math]::Round($lookup[$ctxKey],       1) }
    if ($lookup.ContainsKey($queueKey))     { $sysProcQueue  = [math]::Round($lookup[$queueKey],     0) }

    $systemData = @{
        dpcPct       = $sysDpcPct
        intrPct      = $sysIntrPct
        intrPerSec   = $sysIntrPerSec
        ctxSwitchSec = $sysCtxSwitch
        procQueueLen = $sysProcQueue
    }

    # ------------------------------------------------------------------
    # Spike detection
    # Compute rolling averages BEFORE adding the current sample so the
    # current value is not included in the baseline it's compared against.
    # ------------------------------------------------------------------
    $avgCtx   = Get-RollingAverage -Buffer $script:MonitorHistory.contextSwitches
    $avgDpc   = Get-RollingAverage -Buffer $script:MonitorHistory.totalDpc
    $avgIntr  = Get-RollingAverage -Buffer $script:MonitorHistory.totalInterrupt

    # ------------------------------------------------------------------
    # Update rolling buffers (after averages are computed)
    # ------------------------------------------------------------------
    Add-ToRollingBuffer -Buffer $script:MonitorHistory.contextSwitches -Value $sysCtxSwitch
    Add-ToRollingBuffer -Buffer $script:MonitorHistory.totalDpc         -Value $sysDpcPct
    Add-ToRollingBuffer -Buffer $script:MonitorHistory.totalInterrupt   -Value $sysIntrPct

    # Spike = current value exceeds 3x rolling average (only meaningful when
    # we have at least 3 prior samples so the average is stable).
    $hasHistory = ($script:MonitorHistory.contextSwitches.Count -ge 3)

    $ctxSpikeFlag   = $false
    $dpcSpikeFlag   = $false
    $intrSpikeFlag  = $false

    if ($hasHistory -and $avgCtx  -gt 0) { $ctxSpikeFlag  = ($sysCtxSwitch  -gt (3.0 * $avgCtx))  }
    if ($hasHistory -and $avgDpc  -gt 0) { $dpcSpikeFlag  = ($sysDpcPct     -gt (3.0 * $avgDpc))   }
    if ($hasHistory -and $avgIntr -gt 0) { $intrSpikeFlag = ($sysIntrPct    -gt (3.0 * $avgIntr))  }

    # Per-CPU spike: any CPU with DPC% > 5 %
    $highDpcCpus = @()
    foreach ($entry in $perCpu) {
        if ($entry.dpcPct -gt 5.0) {
            $highDpcCpus += $entry.cpu
        }
    }

    $spikes = @{
        highDpcCpus          = $highDpcCpus
        contextSwitchSpike   = $ctxSpikeFlag
        totalDpcSpike        = $dpcSpikeFlag
        totalInterruptSpike  = $intrSpikeFlag
    }

    # ------------------------------------------------------------------
    # Return structured result
    # ------------------------------------------------------------------
    return @{
        timestamp = (Get-Date -Format 'o')
        perCpu    = $perCpu
        system    = $systemData
        spikes    = $spikes
    }
}
