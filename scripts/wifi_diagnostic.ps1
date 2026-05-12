<#
.SYNOPSIS
    One-shot comprehensive network health diagnostic.
.DESCRIPTION
    Measures gateway latency, external ping stats, DNS resolution timing,
    bufferbloat, connection quality, router probe, and VoIP readiness.
    Produces a JSON report + console summary. No admin required.
.PARAMETER DurationSec
    How long to sample pings (seconds). Default 30.
.PARAMETER OutputDir
    Where to write the JSON report. Default: captures folder.
.PARAMETER SkipBufferbloat
    Skip the bufferbloat load test.
.EXAMPLE
    .\wifi_diagnostic.ps1
    .\wifi_diagnostic.ps1 -DurationSec 60 -SkipBufferbloat
#>
param(
    [int]$DurationSec = 30,
    [string]$OutputDir = (Join-Path $PSScriptRoot '..\captures'),
    [switch]$SkipBufferbloat
)

# --- Bootstrap ---
$script:logLines = @()
. "$PSScriptRoot\helpers\logging.ps1"
. "$PSScriptRoot\helpers\network.ps1"

$startTime = Get-Date
Log '=== Network Diagnostic Report ==='
Log ('Duration: ' + $DurationSec + 's  SkipBufferbloat: ' + $SkipBufferbloat)

# --- 1. Gateway Detection ---
Log ''
Log '--- Gateway Detection ---'

$gatewayIp = $null
try {
    $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop)
    if ($routes.Count -gt 0) {
        $gatewayIp = $routes[0].NextHop
    }
} catch {
    Log ('Failed to detect gateway: ' + $_.Exception.Message) 'WARN'
}

$gatewayPing = $null
if ($null -ne $gatewayIp) {
    Log ('Default gateway: ' + $gatewayIp)
    try {
        $gwReplies = @(Test-Connection -ComputerName $gatewayIp -Count 10 -ErrorAction SilentlyContinue)
        $gwTimes = @()
        $gwReceived = 0
        foreach ($r in $gwReplies) {
            if ($null -ne $r.ResponseTime) {
                $gwTimes += [double]$r.ResponseTime
                $gwReceived++
            }
        }
        if ($gwTimes.Count -gt 0) {
            $gwStats = Get-Stats $gwTimes
            $gwLoss = [math]::Round(((10 - $gwReceived) / 10) * 100, 2)
            $gatewayPing = @{
                avg        = $gwStats.avg
                min        = $gwStats.min
                max        = $gwStats.max
                stdev      = $gwStats.stdev
                packetLoss = $gwLoss
                samples    = $gwTimes.Count
            }
            Log ('  avg=' + $gwStats.avg + 'ms  loss=' + $gwLoss + '%') 'PASS'
        } else {
            Log '  No replies from gateway' 'WARN'
        }
    } catch {
        Log ('  Gateway ping failed: ' + $_.Exception.Message) 'WARN'
    }
} else {
    Log 'No default gateway found' 'WARN'
}

# Traceroute first 5 hops
Log '  Traceroute to 1.1.1.1 (5 hops)...'
$tracerouteHops = @()
try {
    $trOutput = & tracert -h 5 -w 1000 1.1.1.1 2>&1
    foreach ($line in $trOutput) {
        $lineStr = [string]$line
        # Match lines like "  1     1 ms     1 ms     1 ms  192.168.1.1"
        # or             "  2     *        8 ms     7 ms  10.0.0.1"
        if ($lineStr -match '^\s+(\d+)\s+(.+)$') {
            $hopNum = [int]$Matches[1]
            $rest = $Matches[2].Trim()
            # Extract IP from end of line
            $hopIp = $null
            if ($rest -match '(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s*$') {
                $hopIp = $Matches[1]
            }
            # Extract RTT values (up to 3 columns of "N ms" or "*")
            $rttValues = @()
            $rttMatches = [regex]::Matches($rest, '(\d+)\s+ms')
            foreach ($rm in $rttMatches) {
                $rttValues += [double]$rm.Groups[1].Value
            }
            $avgRtt = $null
            if ($rttValues.Count -gt 0) {
                $measure = $rttValues | Measure-Object -Average
                $avgRtt = [math]::Round($measure.Average, 1)
            }
            $tracerouteHops += @{
                hop    = $hopNum
                ip     = $hopIp
                avgRtt = $avgRtt
            }
            $hopLabel = 'Hop ' + $hopNum + ': '
            if ($null -ne $hopIp) { $hopLabel += $hopIp } else { $hopLabel += '*' }
            if ($null -ne $avgRtt) { $hopLabel += ' (' + $avgRtt + 'ms)' }
            Log ('    ' + $hopLabel)
        }
    }
} catch {
    Log ('  Traceroute failed: ' + $_.Exception.Message) 'WARN'
}

# --- 2. Ping Burst ---
Log ''
Log '--- Ping Burst ---'
Log ('Pinging gateway + 1.1.1.1 + 8.8.8.8 for ' + $DurationSec + 's...')

$pingTargets = @('1.1.1.1', '8.8.8.8')
if ($null -ne $gatewayIp) {
    $pingTargets = @($gatewayIp) + $pingTargets
}

# Use .NET Ping for precise timing
$pingResults = @{}
foreach ($target in $pingTargets) {
    $pingResults[$target] = @{
        times  = @()
        sent   = 0
        received = 0
    }
}

$pinger = New-Object System.Net.NetworkInformation.Ping
$elapsed = 0
while ($elapsed -lt $DurationSec) {
    foreach ($target in $pingTargets) {
        $pingResults[$target].sent++
        try {
            $reply = $pinger.Send($target, 2000)
            if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $pingResults[$target].times += [double]$reply.RoundtripTime
                $pingResults[$target].received++
            }
        } catch {
            # Timeout or unreachable, counted as lost
        }
    }
    Start-Sleep -Seconds 1
    $elapsed++
}
$pinger.Dispose()

# Compute per-target statistics
$pingStats = @{}
foreach ($target in $pingTargets) {
    $data = $pingResults[$target]
    $times = @($data.times)
    $sent = $data.sent
    $received = $data.received

    if ($times.Count -eq 0) {
        $pingStats[$target] = @{
            avg        = $null
            min        = $null
            max        = $null
            p50        = $null
            p95        = $null
            stdev      = $null
            jitter     = $null
            packetLoss = 100.0
            samples    = 0
        }
        Log ('  ' + $target + ': no replies') 'FAIL'
        continue
    }

    $sorted = @($times | Sort-Object)
    $count = $sorted.Count
    $stats = Get-Stats $times

    # Percentiles (nearest-rank)
    $p50Idx = [math]::Min([math]::Ceiling($count * 0.50) - 1, $count - 1)
    if ($p50Idx -lt 0) { $p50Idx = 0 }
    $p95Idx = [math]::Min([math]::Ceiling($count * 0.95) - 1, $count - 1)
    if ($p95Idx -lt 0) { $p95Idx = 0 }
    $p50Val = [math]::Round($sorted[$p50Idx], 2)
    $p95Val = [math]::Round($sorted[$p95Idx], 2)

    # Loss
    $lossVal = [math]::Round((($sent - $received) / [math]::Max(1, $sent)) * 100, 2)

    # Jitter: average of absolute differences between consecutive samples
    $jitterVal = 0.0
    if ($times.Count -gt 1) {
        $jitterSum = 0.0
        for ($i = 1; $i -lt $times.Count; $i++) {
            $jitterSum += [math]::Abs($times[$i] - $times[$i - 1])
        }
        $jitterVal = [math]::Round($jitterSum / ($times.Count - 1), 2)
    }

    $pingStats[$target] = @{
        avg        = $stats.avg
        min        = $stats.min
        max        = $stats.max
        p50        = $p50Val
        p95        = $p95Val
        stdev      = $stats.stdev
        jitter     = $jitterVal
        packetLoss = $lossVal
        samples    = $count
    }

    Log ('  ' + $target + ': avg=' + $stats.avg + 'ms p50=' + $p50Val + 'ms p95=' + $p95Val + 'ms jitter=' + $jitterVal + 'ms loss=' + $lossVal + '%') 'PASS'
}

# --- 3. DNS Resolution Timing ---
Log ''
Log '--- DNS Resolution Timing ---'

$dnsDomains = @('google.com', 'cloudflare.com', 'epicgames.com', 'discord.com', 'teams.microsoft.com')
$dnsResults = @()

foreach ($domain in $dnsDomains) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resolvedIp = $null
    $dnsError = $null
    try {
        $addresses = [System.Net.Dns]::GetHostAddresses($domain)
        $sw.Stop()
        if ($addresses.Count -gt 0) {
            $resolvedIp = $addresses[0].ToString()
        }
    } catch {
        $sw.Stop()
        $dnsError = $_.Exception.Message
    }

    $durationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)

    $dnsResults += @{
        domain     = $domain
        resolvedIp = $resolvedIp
        durationMs = $durationMs
        error      = $dnsError
    }

    if ($null -ne $resolvedIp) {
        Log ('  ' + $domain + ' -> ' + $resolvedIp + ' (' + $durationMs + 'ms)') 'PASS'
    } else {
        $errMsg = 'failed'
        if ($null -ne $dnsError) { $errMsg = $dnsError }
        Log ('  ' + $domain + ' -> ' + $errMsg + ' (' + $durationMs + 'ms)') 'WARN'
    }
}

# --- 4. Bufferbloat Test ---
Log ''
Log '--- Bufferbloat Test ---'

$bufferbloat = $null
if ($SkipBufferbloat) {
    Log 'Skipped (use without -SkipBufferbloat to enable)' 'INFO'
} else {
    $bufferbloat = Test-Bufferbloat -SkipBufferbloat:$SkipBufferbloat
}

# --- 5. Connection Quality Score ---
Log ''
Log '--- Connection Quality Score ---'

$qualityScore = Get-ConnectionQualityScore -NetworkLatency $pingStats -Bufferbloat $bufferbloat
Log ('Score: ' + $qualityScore + '/100')

# --- 6. Router Probe ---
Log ''
Log '--- Router Probe ---'

$routerProbe = @{
    attempted = $false
    status    = $null
    server    = $null
    contentLength = $null
    error     = $null
}

if ($null -ne $gatewayIp) {
    $routerProbe.attempted = $true
    $routerUrl = 'http://' + $gatewayIp
    Log ('  Probing ' + $routerUrl + '...')
    try {
        $resp = Invoke-WebRequest -Uri $routerUrl -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        $routerProbe.status = [int]$resp.StatusCode
        if ($null -ne $resp.Headers -and $resp.Headers.ContainsKey('Server')) {
            $routerProbe.server = $resp.Headers['Server']
        }
        $routerProbe.contentLength = $resp.RawContentLength
        Log ('  Status: ' + $routerProbe.status + '  Server: ' + $routerProbe.server + '  Size: ' + $routerProbe.contentLength + 'B') 'PASS'
    } catch {
        $routerProbe.error = $_.Exception.Message
        Log ('  Router did not respond to HTTP: ' + $_.Exception.Message) 'INFO'
    }
} else {
    Log '  Skipped (no gateway)' 'INFO'
}

# --- 7. VoIP Readiness Assessment ---
Log ''
Log '--- VoIP Readiness ---'

# Use the best external target (1.1.1.1 preferred) for VoIP assessment
$voipTarget = $null
$voipRtt = $null
$voipLoss = $null
$voipJitter = $null

$externalTargets = @('1.1.1.1', '8.8.8.8')
foreach ($et in $externalTargets) {
    if ($pingStats.ContainsKey($et) -and $null -ne $pingStats[$et].avg) {
        $voipTarget = $et
        $voipRtt = $pingStats[$et].avg
        $voipLoss = $pingStats[$et].packetLoss
        $voipJitter = $pingStats[$et].jitter
        break
    }
}

$voipResult = @{
    target      = $voipTarget
    rtt         = $voipRtt
    loss        = $voipLoss
    jitter      = $voipJitter
    rttVerdict  = 'FAIL'
    lossVerdict = 'FAIL'
    jitterVerdict = 'FAIL'
    overall     = 'FAIL'
}

if ($null -ne $voipRtt) {
    # RTT: <150ms PASS, <300ms WARN, else FAIL
    if ($voipRtt -lt 150) { $voipResult.rttVerdict = 'PASS' }
    elseif ($voipRtt -lt 300) { $voipResult.rttVerdict = 'WARN' }

    # Loss: <1% PASS, <3% WARN, else FAIL
    if ($voipLoss -lt 1) { $voipResult.lossVerdict = 'PASS' }
    elseif ($voipLoss -lt 3) { $voipResult.lossVerdict = 'WARN' }

    # Jitter: <30ms PASS, <50ms WARN, else FAIL
    if ($voipJitter -lt 30) { $voipResult.jitterVerdict = 'PASS' }
    elseif ($voipJitter -lt 50) { $voipResult.jitterVerdict = 'WARN' }

    # Overall PASS only if all three pass
    $allPass = ($voipResult.rttVerdict -eq 'PASS') -and ($voipResult.lossVerdict -eq 'PASS') -and ($voipResult.jitterVerdict -eq 'PASS')
    if ($allPass) {
        $voipResult.overall = 'PASS'
    } else {
        $anyFail = ($voipResult.rttVerdict -eq 'FAIL') -or ($voipResult.lossVerdict -eq 'FAIL') -or ($voipResult.jitterVerdict -eq 'FAIL')
        if ($anyFail) {
            $voipResult.overall = 'FAIL'
        } else {
            $voipResult.overall = 'WARN'
        }
    }

    $voipLogLevel = $voipResult.overall
    Log ('  RTT: ' + $voipRtt + 'ms [' + $voipResult.rttVerdict + ']  Loss: ' + $voipLoss + '% [' + $voipResult.lossVerdict + ']  Jitter: ' + $voipJitter + 'ms [' + $voipResult.jitterVerdict + ']') $voipLogLevel
    Log ('  Overall: ' + $voipResult.overall) $voipLogLevel
} else {
    Log '  No external ping data available for VoIP assessment' 'WARN'
}

# --- Build JSON Report ---
$endTime = Get-Date
$stamp = Get-Date -Format 'yyyyMMdd_HHmm'

$report = @{
    meta = @{
        tool       = 'wifi_diagnostic.ps1'
        version    = '1.0'
        startTime  = $startTime.ToString('o')
        endTime    = $endTime.ToString('o')
        durationSec = $DurationSec
        hostname   = $env:COMPUTERNAME
    }
    gateway = @{
        ip         = $gatewayIp
        ping       = $gatewayPing
        traceroute = $tracerouteHops
    }
    pingBurst      = $pingStats
    dns            = $dnsResults
    bufferbloat    = $bufferbloat
    qualityScore   = $qualityScore
    routerProbe    = $routerProbe
    voipReadiness  = $voipResult
}

# Ensure output directory exists
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$jsonPath = Join-Path $OutputDir ('network_diag_' + $stamp + '.json')
$report | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding utf8

# --- Console Summary ---
Log ''
Log '=== Summary ==='

# Gateway line
$gwSummary = 'Gateway: '
if ($null -ne $gatewayIp -and $null -ne $gatewayPing) {
    $gwSummary += $gatewayIp + ' (avg ' + $gatewayPing.avg + 'ms, loss ' + $gatewayPing.packetLoss + '%)'
} elseif ($null -ne $gatewayIp) {
    $gwSummary += $gatewayIp + ' (no response)'
} else {
    $gwSummary += 'not detected'
}
Log $gwSummary

# External line
$extParts = @()
foreach ($et in @('1.1.1.1', '8.8.8.8')) {
    if ($pingStats.ContainsKey($et) -and $null -ne $pingStats[$et].avg) {
        $extParts += $et + ' (avg ' + $pingStats[$et].avg + 'ms, loss ' + $pingStats[$et].packetLoss + '%)'
    }
}
if ($extParts.Count -gt 0) {
    Log ('External: ' + ($extParts -join ', '))
}

# DNS line
$dnsParts = @()
foreach ($d in $dnsResults) {
    $dnsParts += $d.domain + ' ' + $d.durationMs + 'ms'
}
Log ('DNS: ' + ($dnsParts -join ', '))

# Bufferbloat line
if ($null -ne $bufferbloat) {
    Log ('Bufferbloat: ' + $bufferbloat.bloatFactor + 'x (' + $bufferbloat.bloatRating + ')')
} else {
    Log 'Bufferbloat: skipped'
}

# Quality score
Log ('Quality Score: ' + $qualityScore + '/100')

# VoIP line
if ($null -ne $voipRtt) {
    Log ('VoIP Ready: ' + $voipResult.overall + ' (RTT ' + $voipRtt + 'ms, Loss ' + $voipLoss + '%, Jitter ' + $voipJitter + 'ms)') $voipResult.overall
} else {
    Log 'VoIP Ready: N/A (no data)' 'WARN'
}

Log ('Report saved: ' + $jsonPath) 'PASS'
Log ('Completed in ' + [math]::Round(($endTime - $startTime).TotalSeconds, 1) + 's')
