<#
.SYNOPSIS
    Pktmon-based packet capture that auto-saves on network dropout detection.
.DESCRIPTION
    Runs pktmon in circular ring-buffer mode while continuously pinging the
    default gateway and an external target. When 2+ consecutive ping failures
    are detected to any target, the script stops pktmon, saves a timestamped
    copy of the ETL file, converts it to pcapng, queries Event Viewer for
    I226-V link-drop events, and restarts pktmon capture.

    Designed to gather packet-level evidence distinguishing NIC link drops
    from eero reboots from ISP failures on an Intel I226-V + eero 7 setup.
.PARAMETER RingBufferMB
    Pktmon ring buffer size in MB (default 100).
.PARAMETER OutputDir
    Directory for saved ETL/pcapng files (default: captures\ next to script).
.PARAMETER MaxCaptures
    Stop after N captured dropout events. 0 = unlimited (default 10).
.PARAMETER PingIntervalMs
    How often to ping targets in milliseconds (default 1000).
.EXAMPLE
    .\network_capture.ps1
    .\network_capture.ps1 -RingBufferMB 200 -MaxCaptures 5
    .\network_capture.ps1 -PingIntervalMs 500 -MaxCaptures 0
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [int]$RingBufferMB   = 100,
    [string]$OutputDir   = (Join-Path $PSScriptRoot '..\captures'),
    [int]$MaxCaptures    = 10,
    [int]$PingIntervalMs = 1000
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
    @{ Name = 'gateway';  IP = $gatewayIP }
    @{ Name = 'external'; IP = '1.1.1.1' }
)

# ── Output Setup ──────────────────────────────────────────────────────────────
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# Ring buffer ETL lives in OutputDir so pktmon writes there
$ringEtlPath = Join-Path $OutputDir 'pktmon_ring.etl'

# ── Ping Object ───────────────────────────────────────────────────────────────
$pinger = New-Object System.Net.NetworkInformation.Ping
$pingTimeout = 1000

# ── Tracking State ────────────────────────────────────────────────────────────
$sampleCount    = 0
$captureCount   = 0
$startTime      = Get-Date
$pktmonRunning  = $false

# Consecutive failure tracking per target
$consecFail = @{ gateway = 0; external = 0 }

# Dropout event log
$dropoutEvents = New-Object System.Collections.ArrayList

# Per-target loss counters for summary
$lossCounts = @{ gateway = 0; external = 0 }
$rttSums    = @{ gateway = [double]0; external = [double]0 }
$rttCounts  = @{ gateway = 0; external = 0 }

# ── Max captures label ────────────────────────────────────────────────────────
$maxLabel = 'unlimited'
if ($MaxCaptures -gt 0) {
    $maxLabel = $MaxCaptures.ToString()
}

# ── Relative path for display ────────────────────────────────────────────────
$displayDir = $OutputDir
$currentDir = Get-Location
$currentDirStr = $currentDir.Path
if ($OutputDir.StartsWith($currentDirStr)) {
    $displayDir = $OutputDir.Substring($currentDirStr.Length).TrimStart('\')
}

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

# ── Helper: Start pktmon capture ──────────────────────────────────────────────
function Start-PktmonCapture {
    # Clean up any stale pktmon session
    try { & pktmon stop 2>$null } catch { }

    # Remove old ring file if it exists so we start fresh
    if (Test-Path $ringEtlPath) {
        Remove-Item -Path $ringEtlPath -Force -ErrorAction SilentlyContinue
    }

    & pktmon start --capture --file-name $ringEtlPath --file-size $RingBufferMB --log-mode circular 2>$null
    $script:pktmonRunning = $true
}

# ── Helper: Stop pktmon capture ───────────────────────────────────────────────
function Stop-PktmonCapture {
    try { & pktmon stop 2>$null } catch { }
    $script:pktmonRunning = $false
}

# ── Helper: Query Event Viewer for I226-V link events ─────────────────────────
function Get-RecentNicEvents {
    param([int]$WindowSeconds = 10)
    $events = @()
    try {
        $startTimeXml = (Get-Date).AddSeconds(-$WindowSeconds).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        # e2fnexpress Event ID 27 = link state change for Intel I226-V
        $filter = '<QueryList><Query Id="0"><Select Path="System">' +
            '*[System[Provider[@Name="e2fnexpress"] and (EventID=27) and ' +
            'TimeCreated[@SystemTime&gt;="' + $startTimeXml + '"]]]' +
            '</Select></Query></QueryList>'
        $found = Get-WinEvent -FilterXml $filter -ErrorAction SilentlyContinue
        if ($null -ne $found) {
            foreach ($evt in $found) {
                $events += @{
                    TimeCreated = $evt.TimeCreated
                    EventID     = $evt.Id
                    Message     = $evt.Message
                }
            }
        }
    }
    catch {
        # Event query failed — non-fatal, just means no NIC events found
    }
    return $events
}

# ── Helper: Save dropout capture ──────────────────────────────────────────────
function Save-DropoutCapture {
    param(
        [DateTime]$Timestamp,
        [string]$TriggerTarget,
        [int]$ConsecFailures
    )

    $tsStr = $Timestamp.ToString('yyyyMMdd_HHmmss')
    $etlDest    = Join-Path $OutputDir ('dropout_' + $tsStr + '.etl')
    $pcapngDest = Join-Path $OutputDir ('dropout_' + $tsStr + '.pcapng')

    # Stop pktmon to flush the ring buffer
    Stop-PktmonCapture

    # Copy the ring ETL to a timestamped file
    $etlSaved = $false
    if (Test-Path $ringEtlPath) {
        try {
            Copy-Item -Path $ringEtlPath -Destination $etlDest -Force
            $etlSaved = $true
        }
        catch {
            Write-Host ('  [WARN] Failed to copy ETL: ' + $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    else {
        Write-Host '  [WARN] Ring ETL file not found — pktmon may not have written data yet.' -ForegroundColor Yellow
    }

    # Convert to pcapng
    $pcapngSaved = $false
    if ($etlSaved) {
        try {
            & pktmon etl2pcap $etlDest --out $pcapngDest 2>$null
            if (Test-Path $pcapngDest) {
                $pcapngSaved = $true
            }
        }
        catch {
            Write-Host ('  [WARN] ETL-to-pcapng conversion failed: ' + $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    # Query Event Viewer for NIC link events
    $nicEvents = Get-RecentNicEvents -WindowSeconds 10

    # Build event record
    $eventRecord = @{
        timestamp       = $Timestamp
        triggerTarget   = $TriggerTarget
        consecFailures  = $ConsecFailures
        etlFile         = $null
        pcapngFile      = $null
        nicEvents       = $nicEvents
    }
    if ($etlSaved)    { $eventRecord.etlFile    = $etlDest }
    if ($pcapngSaved) { $eventRecord.pcapngFile = $pcapngDest }
    $dropoutEvents.Add($eventRecord) | Out-Null

    # Print alert
    $timeStr = $Timestamp.ToString('HH:mm:ss')
    Write-Host ''
    Write-Host ('  [' + $timeStr + '] >>> DROPOUT DETECTED <<<') -ForegroundColor Red
    Write-Host ('    Target    : ' + $TriggerTarget) -ForegroundColor Red
    Write-Host ('    Failures  : ' + $ConsecFailures.ToString() + ' consecutive pings') -ForegroundColor Red
    if ($etlSaved)    { Write-Host ('    ETL       : ' + $etlDest) -ForegroundColor Yellow }
    if ($pcapngSaved) { Write-Host ('    PCAPNG    : ' + $pcapngDest) -ForegroundColor Yellow }

    # Print NIC events if any
    $nicEventCount = $nicEvents.Count
    if ($nicEventCount -gt 0) {
        Write-Host ('    NIC Events: ' + $nicEventCount.ToString() + ' e2fnexpress Event 27 in last 10s') -ForegroundColor Magenta
        foreach ($ne in $nicEvents) {
            $neTime = $ne.TimeCreated.ToString('HH:mm:ss.fff')
            # Truncate message to first 120 chars for readability
            $neMsg = $ne.Message
            if ($neMsg.Length -gt 120) {
                $neMsg = $neMsg.Substring(0, 120) + '...'
            }
            Write-Host ('      ' + $neTime + ' — ' + $neMsg) -ForegroundColor Magenta
        }
    }
    else {
        Write-Host '    NIC Events: none (no e2fnexpress Event 27 in last 10s)' -ForegroundColor DarkGray
    }
    Write-Host ''

    # Restart pktmon capture
    Start-PktmonCapture
}

# ── Startup Banner ────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '=== Network Dropout Packet Capture ===' -ForegroundColor Cyan
Write-Host ('  Gateway      : ' + $gatewayIP)
Write-Host ('  External     : 1.1.1.1')
Write-Host ('  Ping interval: ' + $PingIntervalMs.ToString() + 'ms')
Write-Host ('  Ring buffer  : ' + $RingBufferMB.ToString() + ' MB circular')
Write-Host ('  Max captures : ' + $maxLabel)
Write-Host ('  Output dir   : ' + $displayDir)
Write-Host ''
Write-Host '  Dropout trigger: 2+ consecutive ping failures to any target' -ForegroundColor DarkGray
Write-Host '  On trigger: stop pktmon -> save ETL -> convert pcapng -> check NIC events -> restart' -ForegroundColor DarkGray
Write-Host ''

# ── Start initial pktmon capture ──────────────────────────────────────────────
Write-Host '[*] Starting pktmon ring-buffer capture...' -ForegroundColor Green
Start-PktmonCapture
Write-Host '[*] Capture running. Monitoring for dropouts... (Ctrl+C to stop)' -ForegroundColor Green
Write-Host ''

# ── Main Loop ─────────────────────────────────────────────────────────────────
try {
    while ($true) {
        $now = Get-Date
        $sampleCount++

        # Check MaxCaptures
        if ($MaxCaptures -gt 0 -and $captureCount -ge $MaxCaptures) {
            Write-Host ''
            Write-Host ('[INFO] MaxCaptures (' + $MaxCaptures.ToString() + ') reached, stopping.') -ForegroundColor Yellow
            break
        }

        # Ping all targets
        $results = @{}
        foreach ($t in $targets) {
            $results[$t.Name] = Invoke-SinglePing -Address $t.IP
        }

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

        # Dropout detection — track consecutive failures per target
        $dropoutTriggered = $false
        $triggerTarget = $null
        $triggerConsec = 0

        foreach ($t in $targets) {
            $name = $t.Name
            $r = $results[$name]

            if ($r.Loss -eq 1) {
                $consecFail[$name]++

                # Check if we just crossed the threshold (exactly 2)
                if ($consecFail[$name] -eq 2 -and -not $dropoutTriggered) {
                    $dropoutTriggered = $true
                    $triggerTarget = $name
                    $ip = $t.IP
                    if ($name -eq 'gateway') {
                        $triggerTarget = 'gateway (' + $ip + ')'
                    }
                    elseif ($name -eq 'external') {
                        $triggerTarget = 'external (1.1.1.1)'
                    }
                    $triggerConsec = $consecFail[$name]
                }
            }
            else {
                # Reset consecutive counter on success
                $consecFail[$name] = 0
            }
        }

        # If dropout detected, save capture
        if ($dropoutTriggered) {
            $captureCount++
            Save-DropoutCapture -Timestamp $now -TriggerTarget $triggerTarget -ConsecFailures $triggerConsec

            # Reset all consecutive counters after saving — prevents re-triggering
            # on the same dropout event while pktmon restarts
            foreach ($t in $targets) {
                $consecFail[$t.Name] = 0
            }
        }

        # Progress every 10 samples
        if ($sampleCount % 10 -eq 0) {
            $timeStr = $now.ToString('HH:mm:ss')

            $gwMs = $results['gateway'].Ms
            $extMs = $results['external'].Ms
            $gwDisp = Format-Rtt $gwMs
            $extDisp = Format-Rtt $extMs

            $totalGwLoss  = $lossCounts['gateway']
            $totalExtLoss = $lossCounts['external']

            $line = '[' + $timeStr + '] #' + $sampleCount.ToString() + `
                '  GW=' + $gwDisp + `
                '  EXT=' + $extDisp + `
                '  Loss=' + $totalGwLoss.ToString() + '/' + $totalExtLoss.ToString() + `
                '  Captures=' + $captureCount.ToString()
            Write-Host $line -ForegroundColor DarkGray
        }

        Start-Sleep -Milliseconds $PingIntervalMs
    }
}
finally {
    # ── Cleanup & Summary ─────────────────────────────────────────────────────
    Write-Host ''
    Write-Host '[*] Stopping pktmon...' -ForegroundColor Yellow
    Stop-PktmonCapture

    $endTime = Get-Date
    $runtime = $endTime - $startTime
    $runtimeStr = $runtime.ToString('hh\:mm\:ss')

    Write-Host ''
    Write-Host '=== Capture Summary ===' -ForegroundColor Cyan
    Write-Host ('  Runtime      : ' + $runtimeStr)
    Write-Host ('  Ping samples : ' + $sampleCount.ToString())
    Write-Host ('  Dropouts     : ' + $captureCount.ToString() + ' captured') -ForegroundColor Yellow
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
        Write-Host ('    Avg RTT : ' + $avgRtt)
        Write-Host ('    Loss    : ' + $lossPct.ToString() + '% (' + $drops.ToString() + ' drops)')
    }
    Write-Host ''

    # Dropout event details
    if ($captureCount -eq 0) {
        Write-Host '  No dropout events captured.' -ForegroundColor Green
    }
    else {
        Write-Host '  Dropout Events:' -ForegroundColor Yellow
        $eventIndex = 0
        foreach ($evt in $dropoutEvents) {
            $eventIndex++
            $evtTime = $evt.timestamp.ToString('yyyy-MM-dd HH:mm:ss')
            Write-Host ('    #' + $eventIndex.ToString() + '  ' + $evtTime + '  ' + $evt.triggerTarget) -ForegroundColor White
            if ($null -ne $evt.etlFile) {
                Write-Host ('         ETL   : ' + $evt.etlFile) -ForegroundColor DarkGray
            }
            if ($null -ne $evt.pcapngFile) {
                Write-Host ('         PCAPNG: ' + $evt.pcapngFile) -ForegroundColor DarkGray
            }
            $nicCount = $evt.nicEvents.Count
            if ($nicCount -gt 0) {
                Write-Host ('         NIC   : ' + $nicCount.ToString() + ' e2fnexpress Event 27') -ForegroundColor Magenta
            }
        }
    }

    Write-Host ''
    Write-Host ('  Output dir : ' + $OutputDir) -ForegroundColor Green
    Write-Host ''

    # Dispose pinger
    try { $pinger.Dispose() } catch { }
}
