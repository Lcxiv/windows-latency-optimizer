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
    [ValidateRange(1, 3600)][int]$IntervalSec        = 1,
    [ValidateRange(1, 3600)][int]$ProcessIntervalSec = 5,
    [ValidateRange(1, 3600)][int]$NetworkIntervalSec = 5,
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
. "$PSScriptRoot\helpers\monitor-network.ps1"

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
        Atomically overwrite snapshot.js with the current full state object.
        Uses temp file + rename to prevent partial reads by the dashboard.
    #>
    param([hashtable]$Data)
    $json    = ConvertTo-JsonCompat $Data
    $content = 'window.MONITOR_SNAPSHOT = ' + $json + ';'
    $tmpFile = $snapshotFile + '.tmp'
    $content | Out-File -FilePath $tmpFile -Encoding utf8 -Force
    Move-Item -Path $tmpFile -Destination $snapshotFile -Force
}

function Add-HistoryEntry {
    <#
    .SYNOPSIS
        Append one push() line to history.js for timeline charts.
    #>
    param([hashtable]$Data)
    $json = ConvertTo-JsonCompat $Data
    $line = 'window.MONITOR_HISTORY.push(' + $json + ');'
    Add-Content -Path $historyFile -Value $line -Encoding utf8
}

# ─── Startup banner ───────────────────────────────────────────────────────────
Write-Host ''
Write-Host '=== Latency Monitor Collector ==='
Write-Host ('  Snapshot : ' + $snapshotFile)
Write-Host ('  History  : ' + $historyFile)
Write-Host ('  Interval : ' + $IntervalSec + 's counters  /  ' + $ProcessIntervalSec + 's processes  /  ' + $NetworkIntervalSec + 's network')
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
$lastNetworkPoll = [datetime]::MinValue
$processData     = $null
$xperfData       = $null
$networkData     = $null
$lastNicEventCheck = Get-Date

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

        # ── Network sample (every NetworkIntervalSec) ────────────────────
        $timeSinceNetwork = ($now - $lastNetworkPoll).TotalSeconds
        if ($timeSinceNetwork -ge $NetworkIntervalSec) {
            $networkData     = Get-MonitorNetworkSample
            $lastNetworkPoll = $now
        }

        # ── NIC link drop detection (Event Viewer e2fnexpress Event 27) ──
        $nicLinkDrop = $null
        try {
            $nicEvents = Get-WinEvent -FilterHashtable @{
                LogName      = 'System'
                ProviderName = 'e2fnexpress'
                Id           = 27
                StartTime    = $lastNicEventCheck
            } -MaxEvents 1 -ErrorAction SilentlyContinue
            if ($null -ne $nicEvents -and $nicEvents.Count -gt 0) {
                $nicLinkDrop = @{
                    detected  = $true
                    timestamp = $nicEvents[0].TimeCreated.ToString('o')
                }
            }
        } catch {
            # No events found or provider not present — safe to ignore
        }
        $lastNicEventCheck = $now

        # ── Increment sample count (before assembly so meta is 1-based) ────
        $sampleCount++

        # ── Assemble snapshot ─────────────────────────────────────────────────
        # counterData.timestamp is already an ISO-8601 string from the helper
        $snapshot = @{
            timestamp = $counterData.timestamp
            counters  = $counterData
            processes = $processData
            xperf     = $xperfData
            network      = $networkData
            nicLinkDrop  = $nicLinkDrop
            meta         = @{
                sampleCount  = $sampleCount
                intervalSec  = $IntervalSec
                hostname     = $env:COMPUTERNAME
                collectorPid = $PID
            }
        }

        # ── Write outputs ─────────────────────────────────────────────────────
        Write-Snapshot $snapshot

        # Build minimal network history (keep footprint small)
        $netHist = $null
        if ($null -ne $networkData) {
            $gwRtt  = $null
            $extRtt = $null
            if ($null -ne $networkData.gateway)    { $gwRtt  = $networkData.gateway.rttMs }
            if ($null -ne $networkData.targets -and $networkData.targets.Count -gt 0) {
                foreach ($t in $networkData.targets) {
                    if ($t.reachable -and ($null -eq $extRtt -or $t.rttMs -lt $extRtt)) {
                        $extRtt = $t.rttMs
                    }
                }
            }
            $plGw   = $null
            $plExt  = $null
            if ($null -ne $networkData.packetLoss) {
                $plGw  = $networkData.packetLoss.gateway
                $plExt = $networkData.packetLoss.external
            }
            $netHist = @{
                gatewayRtt  = $gwRtt
                externalRtt = $extRtt
                gwLoss      = $plGw
                extLoss     = $plExt
                verdict     = $networkData.verdict
            }
        }

        Add-HistoryEntry @{
            timestamp = $counterData.timestamp
            system    = $counterData.system
            spikes    = $counterData.spikes
            network   = $netHist
        }

        # ── Progress line ─────────────────────────────────────────────────────
        $dpcStr    = [math]::Round($counterData.system.dpcPct, 2).ToString('F2')
        $intrStr   = [math]::Round($counterData.system.intrPct, 2).ToString('F2')
        $ctxStr    = [math]::Round($counterData.system.ctxSwitchSec, 0).ToString()
        $timeLabel = $now.ToString('HH:mm:ss')

        $spikeTag = ''
        if ($counterData.spikes.totalDpcSpike)        { $spikeTag = $spikeTag + ' [DPC-SPIKE]' }
        if ($counterData.spikes.totalInterruptSpike)  { $spikeTag = $spikeTag + ' [INTR-SPIKE]' }
        if ($counterData.spikes.contextSwitchSpike)   { $spikeTag = $spikeTag + ' [CTX-SPIKE]' }
        if ($counterData.spikes.highDpcCpus.Count -gt 0) {
            $cpuList   = $counterData.spikes.highDpcCpus -join ','
            $spikeTag  = $spikeTag + ' [HIGH-DPC-CPU:' + $cpuList + ']'
        }

        # NIC link drop tag
        $nicTag = ''
        if ($null -ne $nicLinkDrop) {
            $nicTag = ' [NIC-LINK-DROP]'
        }

        # Network verdict tag
        $netTag = ''
        if ($null -ne $networkData) {
            $v = $networkData.verdict
            if ($v -eq 'gateway-issue') { $netTag = ' [NET:GATEWAY-DOWN]' }
            elseif ($v -eq 'wan-issue') { $netTag = ' [NET:WAN-DOWN]' }
            elseif ($v -eq 'no-gateway') { $netTag = ' [NET:NO-GW]' }
            $gwMs = '--'
            if ($null -ne $networkData.gateway -and $networkData.gateway.reachable) {
                $gwMs = [math]::Round($networkData.gateway.rttMs, 0).ToString()
            }
            $netTag = ' GW=' + $gwMs + 'ms' + $netTag
        }

        Write-Host ('[' + $timeLabel + '] #' + $sampleCount + ' DPC=' + $dpcStr + '% INTR=' + $intrStr + '% CTX=' + $ctxStr + '/s' + $netTag + $nicTag + $spikeTag)

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
