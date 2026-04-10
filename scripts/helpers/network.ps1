# helpers/network.ps1
# Network latency capture, bufferbloat testing, connection quality scoring.
# PowerShell 5.1 compatible.

function Invoke-NetworkLatencyCapture {
    <#
    .SYNOPSIS
        Ping multiple targets and compute latency statistics.
    .OUTPUTS
        Hashtable with per-target stats: avg, min, max, p50, p95, p99, stdev, jitter, packetLoss
    #>
    param(
        [string[]]$Targets = @(
            'ping-naw.ds.on.epicgames.com',
            'ping-nac.ds.on.epicgames.com',
            'ping-nae.ds.on.epicgames.com',
            '1.1.1.1'
        ),
        [int]$PingSamples = 60,
        [switch]$SkipNetworkLatency
    )

    if ($SkipNetworkLatency) {
        Log ''
        Log '=== Phase 3D: Network latency skipped ==='
        return $null
    }

    Log ''
    Log '=== Phase 3D: Network latency capture ==='
    Log ('Targets: ' + ($Targets -join ', '))
    Log ('Samples: ' + $PingSamples + ' per target')

    $result = @{}

    foreach ($target in $Targets) {
        Log ('  Pinging ' + $target + '...')
        $times = @()
        $sent = 0
        $received = 0

        try {
            $replies = @(Test-Connection $target -Count $PingSamples -ErrorAction SilentlyContinue)
            $sent = $PingSamples
            foreach ($r in $replies) {
                if ($null -ne $r.ResponseTime) {
                    $times += [double]$r.ResponseTime
                    $received++
                }
            }
        } catch {
            Log ('  FAIL: ' + $_.Exception.Message) 'WARN'
            $result[$target] = @{
                avg = $null; min = $null; max = $null
                p50 = $null; p95 = $null; p99 = $null
                stdev = $null; jitter = $null
                packetLoss = 100; error = $_.Exception.Message
            }
            continue
        }

        if ($times.Count -eq 0) {
            $result[$target] = @{
                avg = $null; min = $null; max = $null
                p50 = $null; p95 = $null; p99 = $null
                stdev = $null; jitter = $null
                packetLoss = 100; error = 'No replies'
            }
            continue
        }

        $sorted = @($times | Sort-Object)
        $count = $sorted.Count

        # Percentile helper (nearest-rank)
        $p50Idx = [math]::Min([math]::Ceiling($count * 0.50) - 1, $count - 1)
        $p95Idx = [math]::Min([math]::Ceiling($count * 0.95) - 1, $count - 1)
        $p99Idx = [math]::Min([math]::Ceiling($count * 0.99) - 1, $count - 1)

        $stats = Get-Stats $times
        $loss = [math]::Round((($sent - $received) / [math]::Max(1, $sent)) * 100, 2)

        # Jitter: average of absolute differences between consecutive pings
        $jitterSum = 0
        for ($i = 1; $i -lt $times.Count; $i++) {
            $jitterSum += [math]::Abs($times[$i] - $times[$i - 1])
        }
        $jitterVal = 0
        if ($times.Count -gt 1) {
            $jitterVal = [math]::Round($jitterSum / ($times.Count - 1), 2)
        }

        $result[$target] = @{
            avg        = $stats.avg
            min        = $stats.min
            max        = $stats.max
            p50        = [math]::Round($sorted[$p50Idx], 2)
            p95        = [math]::Round($sorted[$p95Idx], 2)
            p99        = [math]::Round($sorted[$p99Idx], 2)
            stdev      = $stats.stdev
            jitter     = $jitterVal
            packetLoss = $loss
        }

        Log ('    avg=' + $stats.avg + 'ms  p99=' + [math]::Round($sorted[$p99Idx], 2) + 'ms  jitter=' + $jitterVal + 'ms  loss=' + $loss + '%') 'PASS'
    }

    return $result
}

function Test-Bufferbloat {
    <#
    .SYNOPSIS
        Measure bufferbloat by comparing idle vs loaded RTT.
    .DESCRIPTION
        Pings a target at idle, saturates the connection with a BITS download,
        pings again under load, and computes the bloat factor.
    .OUTPUTS
        [hashtable] with idle/loaded RTT, bloat factor, and rating.
    #>
    param(
        [string]$Target = '1.1.1.1',
        [int]$IdleSamples = 20,
        [int]$LoadedSamples = 20,
        [switch]$SkipBufferbloat
    )

    if ($SkipBufferbloat) { return $null }

    Log 'Running bufferbloat test...' 'INFO'

    # Phase 1: Idle RTT
    Log '  Measuring idle RTT...'
    $idleTimes = @()
    try {
        1..$IdleSamples | ForEach-Object {
            $r = Test-Connection -ComputerName $Target -Count 1 -ErrorAction Stop
            $idleTimes += $r.ResponseTime
        }
    } catch {
        Log ('  Idle ping failed: ' + $_.Exception.Message) 'WARN'
        return $null
    }

    if ($idleTimes.Count -lt 5) {
        Log '  Not enough idle samples' 'WARN'
        return $null
    }

    $idleSorted = $idleTimes | Sort-Object
    $idleP50 = $idleSorted[[math]::Floor($idleSorted.Count * 0.50)]
    $idleAvg = [math]::Round(($idleTimes | Measure-Object -Average).Average, 1)

    Log ('  Idle RTT: p50=' + $idleP50 + 'ms avg=' + $idleAvg + 'ms')

    # Phase 2: Saturate connection
    Log '  Saturating connection...'
    $downloadUrls = @(
        'http://proof.ovh.net/files/10Mb.dat',
        'http://speedtest.tele2.net/10MB.zip'
    )
    $tempFile = Join-Path $env:TEMP 'latencyguard_bloat_test.dat'
    $bitsJob = $null
    $webJob = $null

    # Try BITS first
    try {
        Import-Module BitsTransfer -ErrorAction Stop
        foreach ($url in $downloadUrls) {
            try {
                $bitsJob = Start-BitsTransfer -Source $url -Destination $tempFile -Asynchronous -ErrorAction Stop
                break
            } catch { continue }
        }
    } catch {
        # BITS not available, fall back to WebRequest job
        $webJob = Start-Job -ScriptBlock {
            param($urls, $dest)
            foreach ($u in $urls) {
                try {
                    Invoke-WebRequest -Uri $u -OutFile $dest -UseBasicParsing -ErrorAction Stop
                    break
                } catch { continue }
            }
        } -ArgumentList @(,$downloadUrls), $tempFile
    }

    # Wait for saturation to build up
    Start-Sleep -Seconds 5

    # Phase 3: Loaded RTT
    Log '  Measuring loaded RTT...'
    $loadedTimes = @()
    try {
        1..$LoadedSamples | ForEach-Object {
            $r = Test-Connection -ComputerName $Target -Count 1 -ErrorAction Stop
            $loadedTimes += $r.ResponseTime
        }
    } catch {
        Log ('  Loaded ping failed: ' + $_.Exception.Message) 'WARN'
    }

    # Phase 4: Cleanup
    if ($null -ne $bitsJob) {
        try {
            $bitsJob | Complete-BitsTransfer -ErrorAction SilentlyContinue
            $bitsJob | Remove-BitsTransfer -ErrorAction SilentlyContinue
        } catch {}
    }
    if ($null -ne $webJob) {
        try {
            Stop-Job $webJob -ErrorAction SilentlyContinue
            Remove-Job $webJob -Force -ErrorAction SilentlyContinue
        } catch {}
    }
    if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }

    if ($loadedTimes.Count -lt 5) {
        Log '  Not enough loaded samples' 'WARN'
        return $null
    }

    # Phase 5: Compute results
    $loadedSorted = $loadedTimes | Sort-Object
    $loadedP50 = $loadedSorted[[math]::Floor($loadedSorted.Count * 0.50)]
    $loadedAvg = [math]::Round(($loadedTimes | Measure-Object -Average).Average, 1)

    $bloatFactor = 1.0
    if ($idleP50 -gt 0) { $bloatFactor = [math]::Round($loadedP50 / $idleP50, 1) }

    $bloatRating = 'none'
    if ($bloatFactor -ge 20) { $bloatRating = 'severe' }
    elseif ($bloatFactor -ge 5) { $bloatRating = 'significant' }
    elseif ($bloatFactor -ge 2) { $bloatRating = 'mild' }

    $statusColor = 'PASS'
    if ($bloatRating -eq 'severe') { $statusColor = 'FAIL' }
    elseif ($bloatRating -eq 'significant') { $statusColor = 'FAIL' }
    elseif ($bloatRating -eq 'mild') { $statusColor = 'WARN' }

    Log ('  Loaded RTT: p50=' + $loadedP50 + 'ms avg=' + $loadedAvg + 'ms') 'INFO'
    Log ('  Bloat factor: ' + $bloatFactor + 'x (' + $bloatRating + ')') $statusColor

    return @{
        target        = $Target
        idleP50       = $idleP50
        idleAvg       = $idleAvg
        loadedP50     = $loadedP50
        loadedAvg     = $loadedAvg
        bloatFactor   = $bloatFactor
        bloatRating   = $bloatRating
        idleSamples   = $idleTimes.Count
        loadedSamples = $loadedTimes.Count
    }
}

function Get-ConnectionQualityScore {
    <#
    .SYNOPSIS
        Compute a 0-100 network quality score from latency, jitter, loss, and bufferbloat data.
    #>
    param(
        $NetworkLatency,
        $Bufferbloat
    )

    $score = 0

    # RTT component (40 points) — use best target p50
    $bestP50 = 999
    if ($null -ne $NetworkLatency) {
        foreach ($key in $NetworkLatency.Keys) {
            if ($key -eq 'targets') { continue }
            $val = $NetworkLatency[$key]
            if ($null -ne $val -and $null -ne $val.avg) {
                if ($val.avg -lt $bestP50) { $bestP50 = $val.avg }
            }
        }
    }
    if ($bestP50 -lt 20) { $score += 40 }
    elseif ($bestP50 -lt 40) { $score += 30 }
    elseif ($bestP50 -lt 60) { $score += 20 }
    elseif ($bestP50 -lt 100) { $score += 10 }

    # Jitter component (20 points)
    $bestJitter = 999
    if ($null -ne $NetworkLatency) {
        foreach ($key in $NetworkLatency.Keys) {
            $val = $NetworkLatency[$key]
            if ($null -ne $val -and $null -ne $val.jitter) {
                if ($val.jitter -lt $bestJitter) { $bestJitter = $val.jitter }
            }
        }
    }
    if ($bestJitter -lt 3) { $score += 20 }
    elseif ($bestJitter -lt 10) { $score += 15 }
    elseif ($bestJitter -lt 20) { $score += 10 }
    elseif ($bestJitter -lt 50) { $score += 5 }

    # Loss component (20 points)
    $bestLoss = 100
    if ($null -ne $NetworkLatency) {
        foreach ($key in $NetworkLatency.Keys) {
            $val = $NetworkLatency[$key]
            if ($null -ne $val -and $null -ne $val.packetLoss) {
                if ($val.packetLoss -lt $bestLoss) { $bestLoss = $val.packetLoss }
            }
        }
    }
    if ($bestLoss -eq 0) { $score += 20 }
    elseif ($bestLoss -lt 1) { $score += 15 }
    elseif ($bestLoss -lt 3) { $score += 10 }
    elseif ($bestLoss -lt 5) { $score += 5 }

    # Bloat component (20 points)
    if ($null -ne $Bufferbloat -and $null -ne $Bufferbloat.bloatFactor) {
        $bf = $Bufferbloat.bloatFactor
        if ($bf -lt 2) { $score += 20 }
        elseif ($bf -lt 5) { $score += 15 }
        elseif ($bf -lt 10) { $score += 10 }
        elseif ($bf -lt 20) { $score += 5 }
    } else {
        $score += 10  # Assume average if not measured
    }

    return $score
}

