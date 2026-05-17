# helpers/monitor-network.ps1
# Network ping sampler for real-time latency monitoring.
# Dot-sourced by monitor_collector.ps1.
# PowerShell 5.1 compatible — no ternary, no null-coalescing.
#
# Depends on Add-ToRollingBuffer from monitor-counters.ps1 (loaded first).
# For standalone testing, dot-source monitor-counters.ps1 beforehand.

# ---------------------------------------------------------------------------
# Rolling history buffers (max 30 entries)
# ---------------------------------------------------------------------------
$script:NetworkHistory = @{
    gatewayRtt   = New-Object System.Collections.ArrayList
    externalRtt  = New-Object System.Collections.ArrayList
    gatewayLoss  = New-Object System.Collections.ArrayList
    externalLoss = New-Object System.Collections.ArrayList
}
$script:LastGatewayRtt  = $null
$script:LastExternalRtt = $null
$script:CachedGatewayIp = $null

# Reusable .NET Ping instance (avoids per-call allocation)
$script:NetPinger = New-Object System.Net.NetworkInformation.Ping

# ---------------------------------------------------------------------------
# Main function: Get-MonitorNetworkSample
# ---------------------------------------------------------------------------
function Get-MonitorNetworkSample {
    <#
    .SYNOPSIS
        Ping the default gateway and two external targets. Returns a hashtable
        with RTT, packet loss, jitter, and a triage verdict.
    .DESCRIPTION
        Uses .NET System.Net.NetworkInformation.Ping for explicit 1-second
        timeouts. Non-blocking enough for the 2-second collector loop.

        Verdict logic:
          - gateway unreachable or >5% rolling loss → 'gateway-issue'
          - gateway OK but external unreachable or >5% loss → 'wan-issue'
          - everything OK → 'stable'

    .OUTPUTS
        Hashtable with keys:
            timestamp  [string]    — ISO-8601
            gateway    [hashtable] — @{ ip; rttMs; reachable }
            targets    [array]     — @( @{ host; rttMs; reachable } )
            packetLoss [hashtable] — @{ gateway; external } (rolling % over 30 samples)
            jitter     [hashtable] — @{ gateway; external } (ms, inter-sample delta)
            verdict    [string]    — 'stable' | 'gateway-issue' | 'wan-issue' | 'no-gateway'
    #>

    $now = Get-Date -Format 'o'

    # ------------------------------------------------------------------
    # Detect default gateway (cached — only resolves once)
    # ------------------------------------------------------------------
    if ($null -eq $script:CachedGatewayIp) {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($null -ne $route) {
            $script:CachedGatewayIp = $route.NextHop
        } else {
            return @{
                timestamp  = $now
                gateway    = @{ ip = $null; rttMs = $null; reachable = $false }
                targets    = @()
                packetLoss = @{ gateway = 100.0; external = 100.0 }
                jitter     = @{ gateway = 0; external = 0 }
                verdict    = 'no-gateway'
            }
        }
    }

    $pingTimeout = 1000

    # ------------------------------------------------------------------
    # Ping gateway
    # ------------------------------------------------------------------
    $gwResult = @{
        ip        = $script:CachedGatewayIp
        rttMs     = $null
        reachable = $false
    }
    try {
        $reply = $script:NetPinger.Send($script:CachedGatewayIp, $pingTimeout)
        if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
            $gwResult.rttMs     = [double]$reply.RoundtripTime
            $gwResult.reachable = $true
        }
    } catch {
        # Ping failed — gwResult stays unreachable
    }

    # ------------------------------------------------------------------
    # Ping external targets (Cloudflare + Google DNS)
    # ------------------------------------------------------------------
    $externalHosts = @('1.1.1.1', '8.8.8.8')
    $targetResults = New-Object System.Collections.ArrayList
    $bestExtRtt = $null
    $anyExtReachable = $false

    foreach ($host_ in $externalHosts) {
        $tr = @{ host = $host_; rttMs = $null; reachable = $false }
        try {
            $reply = $script:NetPinger.Send($host_, $pingTimeout)
            if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $tr.rttMs     = [double]$reply.RoundtripTime
                $tr.reachable = $true
                $anyExtReachable = $true
                if ($null -eq $bestExtRtt -or $reply.RoundtripTime -lt $bestExtRtt) {
                    $bestExtRtt = [double]$reply.RoundtripTime
                }
            }
        } catch {
            # Target unreachable
        }
        [void]$targetResults.Add($tr)
    }

    # ------------------------------------------------------------------
    # Update rolling buffers
    # ------------------------------------------------------------------
    $gwLossVal = 1
    if ($gwResult.reachable) { $gwLossVal = 0 }
    $extLossVal = 1
    if ($anyExtReachable) { $extLossVal = 0 }

    Add-ToRollingBuffer -Buffer $script:NetworkHistory.gatewayLoss  -Value $gwLossVal
    Add-ToRollingBuffer -Buffer $script:NetworkHistory.externalLoss -Value $extLossVal

    if ($gwResult.reachable) {
        Add-ToRollingBuffer -Buffer $script:NetworkHistory.gatewayRtt -Value $gwResult.rttMs
    }
    if ($null -ne $bestExtRtt) {
        Add-ToRollingBuffer -Buffer $script:NetworkHistory.externalRtt -Value $bestExtRtt
    }

    # ------------------------------------------------------------------
    # Compute rolling packet loss %
    # ------------------------------------------------------------------
    $gwLossSum = 0.0
    foreach ($v in $script:NetworkHistory.gatewayLoss) { $gwLossSum += $v }
    $gwLossPct = 0.0
    if ($script:NetworkHistory.gatewayLoss.Count -gt 0) {
        $gwLossPct = [math]::Round(($gwLossSum / $script:NetworkHistory.gatewayLoss.Count) * 100, 1)
    }

    $extLossSum = 0.0
    foreach ($v in $script:NetworkHistory.externalLoss) { $extLossSum += $v }
    $extLossPct = 0.0
    if ($script:NetworkHistory.externalLoss.Count -gt 0) {
        $extLossPct = [math]::Round(($extLossSum / $script:NetworkHistory.externalLoss.Count) * 100, 1)
    }

    # ------------------------------------------------------------------
    # Compute jitter (absolute delta from previous sample)
    # ------------------------------------------------------------------
    $gwJitter = 0.0
    if ($gwResult.reachable -and $null -ne $script:LastGatewayRtt) {
        $gwJitter = [math]::Round([math]::Abs($gwResult.rttMs - $script:LastGatewayRtt), 2)
    }
    if ($gwResult.reachable) { $script:LastGatewayRtt = $gwResult.rttMs }

    $extJitter = 0.0
    if ($null -ne $bestExtRtt -and $null -ne $script:LastExternalRtt) {
        $extJitter = [math]::Round([math]::Abs($bestExtRtt - $script:LastExternalRtt), 2)
    }
    if ($null -ne $bestExtRtt) { $script:LastExternalRtt = $bestExtRtt }

    # ------------------------------------------------------------------
    # Determine verdict
    # ------------------------------------------------------------------
    $verdict = 'stable'
    if (-not $gwResult.reachable) {
        $verdict = 'gateway-issue'
    } elseif (-not $anyExtReachable) {
        $verdict = 'wan-issue'
    } elseif ($gwLossPct -gt 5) {
        $verdict = 'gateway-issue'
    } elseif ($extLossPct -gt 5) {
        $verdict = 'wan-issue'
    }

    # ------------------------------------------------------------------
    # Return structured result
    # ------------------------------------------------------------------
    return @{
        timestamp  = $now
        gateway    = $gwResult
        targets    = @($targetResults.ToArray())
        packetLoss = @{ gateway = $gwLossPct; external = $extLossPct }
        jitter     = @{ gateway = $gwJitter; external = $extJitter }
        verdict    = $verdict
    }
}
