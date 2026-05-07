#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Latency Monitor Collector — orchestrates counter/process/xperf helpers and
    writes monitor/data/snapshot.js + monitor/data/history.js for the dashboard.

.DESCRIPTION
    Polls performance counters every IntervalSec seconds, process snapshots every
    ProcessIntervalSec seconds, and (optionally) runs xperf DPC/ISR captures
    every XperfIntervalSec seconds.

    snapshot.js  — OVERWRITTEN each cycle: window.MONITOR_SNAPSHOT = {...};
    history.js   — APPENDED  each cycle:  window.MONITOR_HISTORY.push({...});

    Ctrl+C causes a graceful shutdown via the try/finally block — the final
    snapshot is guaranteed to be written before exit.

.PARAMETER IntervalSec
    Main polling interval in seconds (default 1). Controls how often counters
    are sampled and snapshot.js is refreshed.

.PARAMETER ProcessIntervalSec
    How often the process snapshot is refreshed in seconds (default 5).

.PARAMETER XperfIntervalSec
    How often to run an xperf DPC/ISR trace (default 0 = disabled).
    When > 0, a 5-second xperf trace is triggered every XperfIntervalSec
    seconds; this will block for ~5 s per occurrence.

.PARAMETER MaxSamples
    If > 0, collector exits after writing this many snapshots (for testing).
    Default 0 = run indefinitely.

.PARAMETER HistoryMaxEntries
    Maximum rows appended to history.js before a warning is printed. The file
    grows unbounded; the dashboard trims client-side. Default 300 is informational
    only.

.EXAMPLE
    .\scripts\monitor_collector.ps1 -MaxSamples 3 -IntervalSec 1
    # Writes 3 counter samples then exits — used in acceptance testing.
#>
param(
    [int]$IntervalSec        = 1,
    [int]$ProcessIntervalSec = 5,
    [int]$XperfIntervalSec   = 0,
    [int]$MaxSamples         = 0,
    [int]$HistoryMaxEntries  = 300
)

Set-StrictMode -Off   # helpers use script: scope; strict mode would break dot-source
$ErrorActionPreference = 'Stop'

# ─── Dot-source config and helpers ───────────────────────────────────────────
. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\helpers\monitor-counters.ps1"
. "$PSScriptRoot\helpers\monitor-processes.ps1"
. "$PSScriptRoot\helpers\monitor-xperf.ps1"

# ─── Resolve output directory ─────────────────────────────────────────────────
$monitorDataDir = Join-Path $script:ProjectRoot 'monitor'
$monitorDataDir = Join-Path $monitorDataDir 'data'

if (-not (Test-Path $monitorDataDir)) {
    New-Item -ItemType Directory -Path $monitorDataDir -Force | Out-Null
    Write-Host ('Created directory: ' + $monitorDataDir)
}

$snapshotFile = Join-Path $monitorDataDir 'snapshot.js'
$historyFile  = Join-Path $monitorDataDir 'history.js'

# Initialise history file if absent
if (-not (Test-Path $historyFile)) {
    'window.MONITOR_HISTORY = [];' | Out-File -FilePath $historyFile -Encoding utf8
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

function ConvertTo-JsonCompat {
    <#
    .SYNOPSIS
        Serialise an object to compressed JSON, depth 10 (PS 5.1 compatible).
    #>
    param($Object)
    return ($Object | ConvertTo-Json -Depth 10 -Compress)
}

function Write-Snapshot {
    <#
    .SYNOPSIS
        Overwrite snapshot.js with the current full state object.
    #>
    param($Data)
    $json    = ConvertTo-JsonCompat $Data
    $content = 'window.MONITOR_SNAPSHOT = ' + $json + ';'
    $content | Out-File -FilePath $snapshotFile -Encoding utf8 -Force
}

function Add-HistoryEntry {
    <#
    .SYNOPSIS
        Append one push() line to history.js for timeline charts.
    #>
    param($Data)
    $json = ConvertTo-JsonCompat $Data
    $line = 'window.MONITOR_HISTORY.push(' + $json + ');'
    Add-Content -Path $historyFile -Value $line -Encoding utf8
}

# ─── Startup banner ───────────────────────────────────────────────────────────
Write-Host ''
Write-Host '=== Latency Monitor Collector ==='
Write-Host ('  Snapshot : ' + $snapshotFile)
Write-Host ('  History  : ' + $historyFile)
Write-Host ('  Interval : ' + $IntervalSec + 's counters  /  ' + $ProcessIntervalSec + 's processes')
if ($XperfIntervalSec -gt 0) {
    Write-Host ('  Xperf    : every ' + $XperfIntervalSec + 's (5s capture)')
} else {
    Write-Host '  Xperf    : disabled'
}
if ($MaxSamples -gt 0) {
    Write-Host ('  MaxSamples: ' + $MaxSamples + ' (test mode)')
}
Write-Host ''
Write-Host 'Press Ctrl+C to stop cleanly.'
Write-Host ''

# ─── Main loop ────────────────────────────────────────────────────────────────
$sampleCount     = 0
$lastProcessPoll = [datetime]::MinValue
$lastXperfPoll   = [datetime]::MinValue
$processData     = $null
$xperfData       = $null

try {
    while ($true) {
        $now = Get-Date

        # ── Counter sample (every cycle) ──────────────────────────────────────
        $counterData = Get-MonitorCounterSample

        # Get-MonitorCounterSample returns $null if Get-Counter fails
        if ($null -eq $counterData) {
            Write-Warning ('[' + $now.ToString('HH:mm:ss') + '] Counter sample failed — skipping cycle')
            Start-Sleep -Seconds $IntervalSec
            continue
        }

        # ── Process snapshot (every ProcessIntervalSec) ───────────────────────
        $timeSinceProcess = ($now - $lastProcessPoll).TotalSeconds
        if ($timeSinceProcess -ge $ProcessIntervalSec) {
            $processData     = Get-MonitorProcessSnapshot
            $lastProcessPoll = $now
        }

        # ── Xperf capture (every XperfIntervalSec, when enabled) ─────────────
        if ($XperfIntervalSec -gt 0) {
            $timeSinceXperf = ($now - $lastXperfPoll).TotalSeconds
            if ($timeSinceXperf -ge $XperfIntervalSec) {
                Write-Host ('[' + $now.ToString('HH:mm:ss') + '] Running xperf capture (5s)...')
                $xperfData     = Get-MonitorXperfSnapshot -DurationSec 5
                $lastXperfPoll = $now
            }
        }

        # ── Assemble snapshot ─────────────────────────────────────────────────
        $snapshot = @{
            timestamp = $counterData.timestamp.ToString('o')
            counters  = $counterData
            processes = $processData
            xperf     = $xperfData
            meta      = @{
                sampleCount  = $sampleCount
                intervalSec  = $IntervalSec
                hostname     = $env:COMPUTERNAME
                collectorPid = $PID
            }
        }

        # ── Write outputs ─────────────────────────────────────────────────────
        Write-Snapshot $snapshot

        Add-HistoryEntry @{
            timestamp = $counterData.timestamp.ToString('o')
            system    = $counterData.system
            spikes    = $counterData.spikes
        }

        $sampleCount++

        # ── Progress line ─────────────────────────────────────────────────────
        $dpcStr    = [math]::Round($counterData.system.dpcPct, 2).ToString('F2')
        $intrStr   = [math]::Round($counterData.system.intrPct, 2).ToString('F2')
        $ctxStr    = [math]::Round($counterData.system.ctxSwitchSec, 0).ToString()
        $timeLabel = $counterData.timestamp.ToString('HH:mm:ss')

        $spikeTag = ''
        if ($counterData.spikes.totalDpcSpike)        { $spikeTag = $spikeTag + ' [DPC-SPIKE]' }
        if ($counterData.spikes.totalInterruptSpike)  { $spikeTag = $spikeTag + ' [INTR-SPIKE]' }
        if ($counterData.spikes.contextSwitchSpike)   { $spikeTag = $spikeTag + ' [CTX-SPIKE]' }
        if ($counterData.spikes.highDpcCpus.Count -gt 0) {
            $cpuList   = $counterData.spikes.highDpcCpus -join ','
            $spikeTag  = $spikeTag + ' [HIGH-DPC-CPU:' + $cpuList + ']'
        }

        Write-Host ('[' + $timeLabel + '] #' + $sampleCount + ' DPC=' + $dpcStr + '% INTR=' + $intrStr + '% CTX=' + $ctxStr + '/s' + $spikeTag)

        if ($HistoryMaxEntries -gt 0 -and $sampleCount -eq $HistoryMaxEntries) {
            Write-Warning ('history.js has reached ' + $HistoryMaxEntries + ' entries — file will continue to grow (dashboard trims client-side).')
        }

        # ── MaxSamples exit ───────────────────────────────────────────────────
        if ($MaxSamples -gt 0 -and $sampleCount -ge $MaxSamples) {
            Write-Host ''
            Write-Host ('Reached MaxSamples (' + $MaxSamples + '). Exiting.')
            break
        }

        # ── Wait for next cycle ───────────────────────────────────────────────
        Start-Sleep -Seconds $IntervalSec
    }
} finally {
    # Guaranteed to run on Ctrl+C, MaxSamples exit, or any unhandled exception.
    # snapshot.js already contains the latest state from Write-Snapshot above,
    # so no additional write is needed here — the finally block is for cleanup messaging only.
    Write-Host ''
    Write-Host ('Collector stopped. ' + $sampleCount + ' sample(s) written.')
    Write-Host ('  Snapshot : ' + $snapshotFile)
    Write-Host ('  History  : ' + $historyFile)
}
