<#
.SYNOPSIS
    Post-capture analyzer for network dropout events.
.DESCRIPTION
    Reads packet capture data (.etl or .pcapng) and Event Viewer logs to
    determine the root cause of a network dropout. Classifies each event as:
    nic-drop, eero-reboot, isp-failure, broadcast-storm, or unknown.

    tshark is OPTIONAL — if not in PATH the script falls back to pktmon
    counters + Event Viewer analysis only.
.PARAMETER CaptureFile
    Path to .etl or .pcapng file from a dropout capture.
.PARAMETER DropoutTime
    Approximate time of the dropout. If not provided, infers from file
    modification time.
.PARAMETER GatewayIP
    Gateway IP to look for in captures. Auto-detected via Get-NetRoute
    if not provided.
.EXAMPLE
    .\analyze_dropout.ps1 -CaptureFile C:\captures\dropout_20260507.pcapng
.EXAMPLE
    .\analyze_dropout.ps1 -CaptureFile C:\captures\dropout.etl -DropoutTime '2026-05-07 07:29:16'
.EXAMPLE
    .\analyze_dropout.ps1 -CaptureFile C:\captures\dropout.pcapng -GatewayIP 192.168.4.1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$CaptureFile,

    [datetime]$DropoutTime,

    [string]$GatewayIP = ''
)

$ErrorActionPreference = 'Stop'

# ── Helpers ──────────────────────────────────────────────────────────────────

function Write-Check {
    param(
        [string]$Label,
        [bool]$Found,
        [string]$Detail
    )
    if ($Found) {
        $marker = '[+]'
        $color  = 'Green'
    }
    else {
        $marker = '[-]'
        $color  = 'DarkGray'
    }
    Write-Host ('    ' + $marker + ' ' + $Label + ': ' + $Detail) -ForegroundColor $color
}

function Convert-EtlToPcapng {
    param([string]$EtlPath)
    $pcapOut = [System.IO.Path]::ChangeExtension($EtlPath, '.pcapng')
    if (Test-Path $pcapOut) { return $pcapOut }
    Write-Host '  Converting .etl to .pcapng via pktmon...' -ForegroundColor Yellow
    try {
        $pktmonResult = & pktmon etl2pcap $EtlPath --out $pcapOut 2>&1
        if (Test-Path $pcapOut) {
            Write-Host ('  Converted: ' + $pcapOut) -ForegroundColor Green
            return $pcapOut
        }
        Write-Host ('  pktmon conversion failed: ' + $pktmonResult) -ForegroundColor Red
        return $null
    }
    catch {
        Write-Host ('  pktmon conversion error: ' + $_.Exception.Message) -ForegroundColor Red
        return $null
    }
}

function Invoke-Tshark {
    param(
        [string]$File,
        [string]$Filter,
        [string[]]$Fields
    )
    $fieldArgs = @()
    foreach ($f in $Fields) {
        $fieldArgs += '-e'
        $fieldArgs += $f
    }
    $args = @('-r', $File, '-Y', $Filter, '-T', 'fields') + $fieldArgs + @('-E', 'separator=|')
    try {
        $output = & tshark @args 2>$null
        return $output
    }
    catch {
        return @()
    }
}

function Parse-TimestampFromTshark {
    param([string]$TimeStr)
    $TimeStr = $TimeStr.Trim()
    if ([string]::IsNullOrEmpty($TimeStr)) { return $null }
    # tshark -T fields -e frame.time outputs various formats
    # Try common patterns
    $parsed = $null
    $ok = [datetime]::TryParse($TimeStr, [ref]$parsed)
    if ($ok) { return $parsed }
    return $null
}

# ── Validate inputs ─────────────────────────────────────────────────────────

if (-not (Test-Path $CaptureFile)) {
    Write-Error ('Capture file not found: ' + $CaptureFile)
    return
}

$captureExt = [System.IO.Path]::GetExtension($CaptureFile).ToLower()
if ($captureExt -ne '.etl' -and $captureExt -ne '.pcapng') {
    Write-Error ('Unsupported capture format: ' + $captureExt + '. Expected .etl or .pcapng')
    return
}

# Determine dropout time
if (-not $PSBoundParameters.ContainsKey('DropoutTime')) {
    $fileInfo = Get-Item $CaptureFile
    $DropoutTime = $fileInfo.LastWriteTime
    Write-Host ('  Dropout time not specified, using file modification time: ' + $DropoutTime.ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor Yellow
}

# Auto-detect gateway IP
if ([string]::IsNullOrEmpty($GatewayIP)) {
    try {
        $defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric |
            Select-Object -First 1
        if ($defaultRoute -and $defaultRoute.NextHop) {
            $GatewayIP = $defaultRoute.NextHop
            Write-Host ('  Auto-detected gateway IP: ' + $GatewayIP) -ForegroundColor Cyan
        }
        else {
            $GatewayIP = '192.168.4.1'
            Write-Host ('  Could not auto-detect gateway, using default: ' + $GatewayIP) -ForegroundColor Yellow
        }
    }
    catch {
        $GatewayIP = '192.168.4.1'
        Write-Host ('  Gateway auto-detect failed, using default: ' + $GatewayIP) -ForegroundColor Yellow
    }
}

# Check for tshark
$hasTshark = $false
$tsharkCmd = Get-Command tshark -ErrorAction SilentlyContinue
if ($tsharkCmd) {
    $hasTshark = $true
    Write-Host ('  tshark found: ' + $tsharkCmd.Source) -ForegroundColor Cyan
}
else {
    Write-Host '  tshark not found in PATH — pcapng analysis will be limited' -ForegroundColor Yellow
}

# ── Evidence collection ─────────────────────────────────────────────────────

Write-Host ''
Write-Host '=== Dropout Analysis ===' -ForegroundColor Cyan
Write-Host ('  Capture     : ' + $CaptureFile)
Write-Host ('  Dropout Time: ' + $DropoutTime.ToString('yyyy-MM-dd HH:mm:ss'))
Write-Host ('  Gateway IP  : ' + $GatewayIP)
Write-Host ''

# Time window for event search: ±30 seconds around dropout
$windowStart = $DropoutTime.AddSeconds(-30)
$windowEnd   = $DropoutTime.AddSeconds(30)

# Initialize evidence record
$evidence = @{
    EventViewerEvent27   = $false
    EventViewerEvent32   = $false
    Event27Time          = $null
    Event32Time          = $null
    GratuitousArp        = $false
    GratuitousArpTime    = $null
    GratuitousArpMac     = $null
    CaptureGap           = $false
    CaptureGapStartTime  = $null
    CaptureGapEndTime    = $null
    CaptureGapDuration   = 0.0
    TcpRetransmissions   = 0
    BroadcastStorm       = $false
    BroadcastStormPeak   = 0
    DnsFailures          = 0
    IcmpUnreachable      = 0
    Verdict              = 'unknown'
    Recommendation       = ''
}

# ── Check 1: Event Viewer — NIC Link Drop ────────────────────────────────────

Write-Host '  [1/3] Checking Event Viewer for NIC link events...' -ForegroundColor White

try {
    $filterEvent27 = @{
        LogName      = 'System'
        ProviderName = 'e2fnexpress'
        Id           = 27
        StartTime    = $windowStart
        EndTime      = $windowEnd
    }
    $events27 = Get-WinEvent -FilterHashtable $filterEvent27 -ErrorAction SilentlyContinue

    if ($events27 -and $events27.Count -gt 0) {
        $evidence.EventViewerEvent27 = $true
        $evidence.Event27Time = $events27[0].TimeCreated
    }
}
catch {
    # No matching events is not an error
}

try {
    $filterEvent32 = @{
        LogName      = 'System'
        ProviderName = 'e2fnexpress'
        Id           = 32
        StartTime    = $windowStart
        EndTime      = $windowEnd.AddSeconds(30)
    }
    $events32 = Get-WinEvent -FilterHashtable $filterEvent32 -ErrorAction SilentlyContinue

    if ($events32 -and $events32.Count -gt 0) {
        $evidence.EventViewerEvent32 = $true
        $evidence.Event32Time = $events32[0].TimeCreated
    }
}
catch {
    # No matching events is not an error
}

# ── Check 2: tshark Analysis ────────────────────────────────────────────────

# Prepare pcapng path (convert if needed)
$pcapngFile = $null
if ($captureExt -eq '.pcapng') {
    $pcapngFile = $CaptureFile
}
elseif ($captureExt -eq '.etl') {
    $pcapngFile = Convert-EtlToPcapng -EtlPath $CaptureFile
}

if ($hasTshark -and $pcapngFile -and (Test-Path $pcapngFile)) {
    Write-Host '  [2/3] Running tshark analysis on pcapng...' -ForegroundColor White

    # 2a: Gratuitous ARP from gateway
    $arpFilter = 'arp.isgratuitous == true and arp.src.proto_ipv4 == ' + $GatewayIP
    $arpLines = Invoke-Tshark -File $pcapngFile -Filter $arpFilter -Fields @('frame.time', 'arp.src.hw_mac')
    if ($arpLines -and $arpLines.Count -gt 0) {
        foreach ($line in $arpLines) {
            if ([string]::IsNullOrEmpty($line)) { continue }
            $parts = $line.Split('|')
            $evidence.GratuitousArp = $true
            if ($parts.Count -ge 1) {
                $evidence.GratuitousArpTime = Parse-TimestampFromTshark -TimeStr $parts[0]
            }
            if ($parts.Count -ge 2) {
                $evidence.GratuitousArpMac = $parts[1].Trim()
            }
            break  # Only need the first one
        }
    }

    # 2b: Broadcast storm detection (>100 broadcasts in any 1-second window)
    $bcastLines = Invoke-Tshark -File $pcapngFile -Filter 'eth.dst == ff:ff:ff:ff:ff:ff' -Fields @('frame.time_epoch')
    if ($bcastLines -and $bcastLines.Count -gt 0) {
        $epochs = @()
        foreach ($line in $bcastLines) {
            if ([string]::IsNullOrEmpty($line)) { continue }
            $epochVal = 0.0
            $parseOk = [double]::TryParse($line.Trim(), [ref]$epochVal)
            if ($parseOk) { $epochs += $epochVal }
        }

        if ($epochs.Count -gt 0) {
            # Sliding 1-second window: count per integer-second bucket
            $buckets = @{}
            foreach ($ep in $epochs) {
                $bucket = [Math]::Floor($ep)
                $bucketKey = $bucket.ToString()
                if ($buckets.ContainsKey($bucketKey)) {
                    $buckets[$bucketKey] = $buckets[$bucketKey] + 1
                }
                else {
                    $buckets[$bucketKey] = 1
                }
            }
            $peakBroadcasts = 0
            foreach ($k in $buckets.Keys) {
                if ($buckets[$k] -gt $peakBroadcasts) {
                    $peakBroadcasts = $buckets[$k]
                }
            }
            $evidence.BroadcastStormPeak = $peakBroadcasts
            if ($peakBroadcasts -gt 100) {
                $evidence.BroadcastStorm = $true
            }
        }
    }

    # 2c: TCP retransmissions
    $retransLines = Invoke-Tshark -File $pcapngFile -Filter 'tcp.analysis.retransmission' -Fields @('frame.time_epoch')
    if ($retransLines) {
        $retransCount = 0
        foreach ($line in $retransLines) {
            if (-not [string]::IsNullOrEmpty($line.Trim())) { $retransCount++ }
        }
        $evidence.TcpRetransmissions = $retransCount
    }

    # 2d: DNS failures
    $dnsLines = Invoke-Tshark -File $pcapngFile -Filter 'dns.flags.rcode != 0' -Fields @('frame.time', 'dns.qry.name')
    if ($dnsLines) {
        $dnsCount = 0
        foreach ($line in $dnsLines) {
            if (-not [string]::IsNullOrEmpty($line.Trim())) { $dnsCount++ }
        }
        $evidence.DnsFailures = $dnsCount
    }

    # 2e: ICMP unreachable
    $icmpLines = Invoke-Tshark -File $pcapngFile -Filter 'icmp.type == 3' -Fields @('frame.time', 'ip.src')
    if ($icmpLines) {
        $icmpCount = 0
        foreach ($line in $icmpLines) {
            if (-not [string]::IsNullOrEmpty($line.Trim())) { $icmpCount++ }
        }
        $evidence.IcmpUnreachable = $icmpCount
    }

    # ── Check 3: Capture Gap Detection ───────────────────────────────────────

    Write-Host '  [3/3] Analyzing packet timestamps for capture gaps...' -ForegroundColor White

    $tsLines = Invoke-Tshark -File $pcapngFile -Filter '' -Fields @('frame.time_epoch')
    if ($tsLines -and $tsLines.Count -gt 1) {
        $timestamps = @()
        foreach ($line in $tsLines) {
            if ([string]::IsNullOrEmpty($line)) { continue }
            $tsVal = 0.0
            $tsOk = [double]::TryParse($line.Trim(), [ref]$tsVal)
            if ($tsOk) { $timestamps += $tsVal }
        }

        if ($timestamps.Count -gt 1) {
            $maxGap = 0.0
            $gapStartEpoch = 0.0
            $gapEndEpoch = 0.0
            for ($i = 1; $i -lt $timestamps.Count; $i++) {
                $gap = $timestamps[$i] - $timestamps[$i - 1]
                if ($gap -gt $maxGap) {
                    $maxGap = $gap
                    $gapStartEpoch = $timestamps[$i - 1]
                    $gapEndEpoch = $timestamps[$i]
                }
            }

            if ($maxGap -gt 2.0) {
                $evidence.CaptureGap = $true
                $evidence.CaptureGapDuration = [Math]::Round($maxGap, 1)
                $unixEpoch = [datetime]::new(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
                $evidence.CaptureGapStartTime = $unixEpoch.AddSeconds($gapStartEpoch).ToLocalTime()
                $evidence.CaptureGapEndTime   = $unixEpoch.AddSeconds($gapEndEpoch).ToLocalTime()
            }
        }
    }
}
else {
    Write-Host '  [2/3] Skipping tshark analysis (tshark not available or no pcapng)' -ForegroundColor DarkGray
    Write-Host '  [3/3] Skipping capture gap detection (requires tshark)' -ForegroundColor DarkGray
}

# ── Verdict Logic ────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '  Determining verdict...' -ForegroundColor White

# Priority 1: Event 27 + capture gap = confirmed NIC drop
if ($evidence.EventViewerEvent27 -and $evidence.CaptureGap) {
    $evidence.Verdict = 'nic-drop'
    $evidence.Recommendation = 'I226-V NIC link drop confirmed. Check NVM firmware version (target 2.22+). If EEE already disabled, update NVM via motherboard OEM.'
}
# Priority 2: Gratuitous ARP from gateway = eero reboot
elseif ($evidence.GratuitousArp) {
    $evidence.Verdict = 'eero-reboot'
    $evidence.Recommendation = 'eero gateway rebooted. Check eero firmware version in app. Contact eero support to pull device logs. Consider eero bypass test (connect directly to Frontier ONT).'
}
# Priority 3: Event 27 without capture gap = suspected NIC drop
elseif ($evidence.EventViewerEvent27 -and (-not $evidence.CaptureGap)) {
    $evidence.Verdict = 'nic-drop-suspected'
    $evidence.Recommendation = 'Event Viewer indicates NIC link drop but packet capture does not show a gap. Possible timing mismatch. Re-run capture with pktmon active during next dropout. Check NVM firmware version (target 2.22+).'
}
# Priority 4: TCP retransmissions without NIC or gateway issues = ISP
elseif ($evidence.TcpRetransmissions -gt 10 -and (-not $evidence.EventViewerEvent27) -and (-not $evidence.GratuitousArp)) {
    $evidence.Verdict = 'isp-failure'
    $evidence.Recommendation = 'WAN-side failure detected. Gateway reachable but internet not. Contact Frontier with this evidence. Run tracert to identify failing hop.'
}
# Priority 5: Broadcast storm
elseif ($evidence.BroadcastStorm) {
    $evidence.Verdict = 'broadcast-storm'
    $evidence.Recommendation = 'Broadcast storm detected. Check for network loops or misbehaving IoT devices. Inspect all switch connections to eero.'
}
# Priority 6: Unknown
else {
    $evidence.Verdict = 'unknown'
    $evidence.Recommendation = 'Could not determine root cause from available evidence. Consider running a pktmon capture to catch the next event with packet data active.'
}

# ── Compute dropout duration estimate ────────────────────────────────────────

$durationEstimate = '?'
if ($evidence.CaptureGap) {
    $durationEstimate = '~' + $evidence.CaptureGapDuration.ToString() + ' seconds'
}
elseif ($evidence.EventViewerEvent27 -and $evidence.EventViewerEvent32) {
    $evtDuration = ($evidence.Event32Time - $evidence.Event27Time).TotalSeconds
    if ($evtDuration -gt 0) {
        $durationEstimate = '~' + [Math]::Round($evtDuration, 1).ToString() + ' seconds (Event Viewer)'
    }
}

# ── Print report ─────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '=== Dropout Analysis Report ===' -ForegroundColor Cyan
Write-Host ('  Capture     : ' + $CaptureFile)
Write-Host ('  Dropout Time: ' + $DropoutTime.ToString('yyyy-MM-dd HH:mm:ss'))
Write-Host ('  Duration    : ' + $durationEstimate)
Write-Host ''

# Verdict line with color
$verdictColor = 'White'
if ($evidence.Verdict -eq 'nic-drop')          { $verdictColor = 'Red' }
elseif ($evidence.Verdict -eq 'nic-drop-suspected') { $verdictColor = 'Yellow' }
elseif ($evidence.Verdict -eq 'eero-reboot')   { $verdictColor = 'Yellow' }
elseif ($evidence.Verdict -eq 'isp-failure')   { $verdictColor = 'Magenta' }
elseif ($evidence.Verdict -eq 'broadcast-storm') { $verdictColor = 'Red' }
elseif ($evidence.Verdict -eq 'unknown')       { $verdictColor = 'DarkGray' }

Write-Host ('  Verdict     : ' + $evidence.Verdict) -ForegroundColor $verdictColor
Write-Host ''
Write-Host '  Evidence:' -ForegroundColor White

# Event Viewer
$ev27Detail = 'not found'
if ($evidence.EventViewerEvent27) {
    $ev27Detail = 'e2fnexpress Event 27 at ' + $evidence.Event27Time.ToString('HH:mm:ss')
    if ($evidence.EventViewerEvent32) {
        $ev27Detail = $ev27Detail + ', Event 32 at ' + $evidence.Event32Time.ToString('HH:mm:ss')
    }
}
Write-Check -Label 'Event Viewer (NIC link)' -Found $evidence.EventViewerEvent27 -Detail $ev27Detail

# Gratuitous ARP
$arpDetail = 'not found'
if ($evidence.GratuitousArp) {
    $arpDetail = 'from gateway'
    if ($evidence.GratuitousArpMac) {
        $arpDetail = $arpDetail + ' (MAC: ' + $evidence.GratuitousArpMac + ')'
    }
    if ($evidence.GratuitousArpTime) {
        $arpDetail = $arpDetail + ' at ' + $evidence.GratuitousArpTime.ToString('HH:mm:ss')
    }
}
Write-Check -Label 'Gratuitous ARP from gateway' -Found $evidence.GratuitousArp -Detail $arpDetail

# Capture gap
$gapDetail = 'none (< 2s)'
if ($evidence.CaptureGap) {
    $gapDetail = $evidence.CaptureGapDuration.ToString() + 's silence'
    if ($evidence.CaptureGapStartTime -and $evidence.CaptureGapEndTime) {
        $gapDetail = $gapDetail + ' from ' + $evidence.CaptureGapStartTime.ToString('HH:mm:ss') + ' to ' + $evidence.CaptureGapEndTime.ToString('HH:mm:ss')
    }
}
Write-Check -Label 'Capture gap' -Found $evidence.CaptureGap -Detail $gapDetail

# TCP retransmissions
$retransDetail = 'none'
if ($evidence.TcpRetransmissions -gt 0) {
    $retransDetail = $evidence.TcpRetransmissions.ToString() + ' retransmissions'
}
$retransFound = ($evidence.TcpRetransmissions -gt 10)
Write-Check -Label 'TCP retransmissions' -Found $retransFound -Detail $retransDetail

# Broadcast storm
$bcastDetail = 'none'
if ($evidence.BroadcastStormPeak -gt 0) {
    $bcastDetail = 'peak ' + $evidence.BroadcastStormPeak.ToString() + ' broadcasts/sec'
}
Write-Check -Label 'Broadcast storm' -Found $evidence.BroadcastStorm -Detail $bcastDetail

# DNS failures
$dnsDetail = 'none'
if ($evidence.DnsFailures -gt 0) {
    $dnsDetail = $evidence.DnsFailures.ToString() + ' failures'
}
Write-Check -Label 'DNS failures' -Found ($evidence.DnsFailures -gt 0) -Detail $dnsDetail

# ICMP unreachable
$icmpDetail = 'none'
if ($evidence.IcmpUnreachable -gt 0) {
    $icmpDetail = $evidence.IcmpUnreachable.ToString() + ' unreachable'
}
Write-Check -Label 'ICMP unreachable' -Found ($evidence.IcmpUnreachable -gt 0) -Detail $icmpDetail

# tshark availability note
if (-not $hasTshark) {
    Write-Host ''
    Write-Host '    NOTE: tshark not installed. Packet-level analysis (ARP, broadcast,' -ForegroundColor DarkYellow
    Write-Host '    retransmissions, DNS, ICMP, gap detection) was skipped.' -ForegroundColor DarkYellow
    Write-Host '    Install Wireshark and add tshark to PATH for full analysis.' -ForegroundColor DarkYellow
}

Write-Host ''
Write-Host ('  Recommendation: ' + $evidence.Recommendation) -ForegroundColor Yellow
Write-Host ''

# ── Build result object for programmatic use ─────────────────────────────────

# Pre-compute nullable timestamps (no if/else inside hashtable literal — PS 5.1 pitfall)
$ev27TimeStr = $null
if ($evidence.Event27Time) { $ev27TimeStr = $evidence.Event27Time.ToString('yyyy-MM-dd HH:mm:ss') }
$ev32TimeStr = $null
if ($evidence.Event32Time) { $ev32TimeStr = $evidence.Event32Time.ToString('yyyy-MM-dd HH:mm:ss') }

$result = [PSCustomObject]@{
    CaptureFile          = $CaptureFile
    DropoutTime          = $DropoutTime.ToString('yyyy-MM-dd HH:mm:ss')
    GatewayIP            = $GatewayIP
    DurationEstimate     = $durationEstimate
    Verdict              = $evidence.Verdict
    Recommendation       = $evidence.Recommendation
    TsharkAvailable      = $hasTshark
    EventViewer          = [PSCustomObject]@{
        Event27Found     = $evidence.EventViewerEvent27
        Event27Time      = $ev27TimeStr
        Event32Found     = $evidence.EventViewerEvent32
        Event32Time      = $ev32TimeStr
    }
    PacketAnalysis       = [PSCustomObject]@{
        GratuitousArp    = $evidence.GratuitousArp
        GratuitousArpMac = $evidence.GratuitousArpMac
        CaptureGap       = $evidence.CaptureGap
        CaptureGapSec    = $evidence.CaptureGapDuration
        TcpRetransmissions = $evidence.TcpRetransmissions
        BroadcastStorm   = $evidence.BroadcastStorm
        BroadcastPeakSec = $evidence.BroadcastStormPeak
        DnsFailures      = $evidence.DnsFailures
        IcmpUnreachable  = $evidence.IcmpUnreachable
    }
}

# Output the object (can be piped to ConvertTo-Json or captured in a variable)
Write-Output $result
