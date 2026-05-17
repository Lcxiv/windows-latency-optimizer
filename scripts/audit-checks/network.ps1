#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Network audit checks (Deep Tier).
.DESCRIPTION
    TCP tuning (auto-tuning, timestamps, RSC, InitialRTO), IPv6, flow control,
    Defender CPU limit, network latency probe, anti-cheat driver detection.
#>

# ---------------------------------------------------------------------------
# Deep Tier: Network Checks (24-32)
# ---------------------------------------------------------------------------
function Invoke-NetworkChecks {
    $results = @()

    # Read netsh tcp globals once
    $tcpGlobal = netsh int tcp show global 2>&1 | Out-String

    # --- Check 24: TCP Auto-Tuning ---
    $atMatch = [regex]::Match($tcpGlobal, 'Receive Window Auto-Tuning Level\s*:\s*(\S+)')
    $atVal   = ''
    if ($atMatch.Success) { $atVal = $atMatch.Groups[1].Value.ToLower() }
    if ($atVal -eq 'restricted') {
        $results += New-CheckResult -Name 'TCP Auto-Tuning' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'restricted' -Expected 'restricted'
    } elseif ($atVal -eq '') {
        $results += New-CheckResult -Name 'TCP Auto-Tuning' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'ERROR' -Current 'Could not parse netsh output' -Expected 'restricted'
    } else {
        $results += New-CheckResult -Name 'TCP Auto-Tuning' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current $atVal -Expected 'restricted' `
            -Message 'Normal auto-tuning can over-allocate receive buffers, increasing bufferbloat.' `
            -Fix 'netsh int tcp set global autotuninglevel=restricted'
    }

    # --- Check 25: TCP Timestamps ---
    $tsMatch = [regex]::Match($tcpGlobal, 'Timestamps\s*:\s*(\S+)')
    $tsVal   = ''
    if ($tsMatch.Success) { $tsVal = $tsMatch.Groups[1].Value.ToLower() }
    if ($tsVal -eq 'disabled') {
        $results += New-CheckResult -Name 'TCP Timestamps' -Category 'Network' -Tier 'Deep' -Severity 'LOW' `
            -Status 'PASS' -Current 'disabled' -Expected 'disabled'
    } else {
        $tsCurrent = $tsVal
        if ($tsCurrent -eq '') { $tsCurrent = 'unknown' }
        $results += New-CheckResult -Name 'TCP Timestamps' -Category 'Network' -Tier 'Deep' -Severity 'LOW' `
            -Status 'WARN' -Current $tsCurrent -Expected 'disabled' `
            -Fix 'netsh int tcp set global timestamps=disabled'
    }

    # --- Check 26: TCP RSC ---
    $rscMatch = [regex]::Match($tcpGlobal, 'Receive Segment Coalescing State\s*:\s*(\S+)')
    $rscVal   = ''
    if ($rscMatch.Success) { $rscVal = $rscMatch.Groups[1].Value.ToLower() }
    if ($rscVal -eq 'disabled') {
        $results += New-CheckResult -Name 'TCP RSC' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'disabled' -Expected 'disabled'
    } else {
        $rscCurrent = $rscVal
        if ($rscCurrent -eq '') { $rscCurrent = 'unknown' }
        $results += New-CheckResult -Name 'TCP RSC' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current $rscCurrent -Expected 'disabled' `
            -Message 'RSC coalesces received segments, adding latency in exchange for CPU savings.' `
            -Fix 'netsh int tcp set global rsc=disabled'
    }

    # --- Check 27: TCP InitialRTO ---
    $rtoMatch = [regex]::Match($tcpGlobal, 'Initial RTO\s*:\s*(\d+)')
    $rtoVal   = -1
    if ($rtoMatch.Success) { $rtoVal = [int]$rtoMatch.Groups[1].Value }
    if ($rtoVal -eq 300) {
        $results += New-CheckResult -Name 'TCP InitialRTO' -Category 'Network' -Tier 'Deep' -Severity 'LOW' `
            -Status 'PASS' -Current '300' -Expected '300'
    } elseif ($rtoVal -eq -1) {
        $results += New-CheckResult -Name 'TCP InitialRTO' -Category 'Network' -Tier 'Deep' -Severity 'LOW' `
            -Status 'ERROR' -Current 'Could not parse' -Expected '300'
    } else {
        $results += New-CheckResult -Name 'TCP InitialRTO' -Category 'Network' -Tier 'Deep' -Severity 'LOW' `
            -Status 'WARN' -Current ([string]$rtoVal) -Expected '300' `
            -Message 'Default 3000ms initial retransmit timeout causes 3-second freeze on first packet loss.' `
            -Fix 'netsh int tcp set global initialRto=300'
    }

    # --- Check 28: NIC IPv6 ---
    $nic = $null
    try {
        $nic = Get-NetAdapter -Physical -ErrorAction Stop |
            Where-Object { $_.Status -eq 'Up' -and $_.MediaType -ne 'Native 802.11' } |
            Select-Object -First 1
    } catch {}
    if ($null -eq $nic) {
        $results += New-CheckResult -Name 'NIC IPv6 Disabled' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'SKIP' -Current 'No active wired NIC' -Expected 'Active NIC'
    } else {
        $ipv6Binding = $null
        try { $ipv6Binding = Get-NetAdapterBinding -Name $nic.Name -ComponentID 'ms_tcpip6' -ErrorAction Stop } catch {}
        if ($null -eq $ipv6Binding) {
            $results += New-CheckResult -Name 'NIC IPv6 Disabled' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
                -Status 'SKIP' -Current 'Could not read binding' -Expected 'Disabled'
        } elseif (-not $ipv6Binding.Enabled) {
            $results += New-CheckResult -Name 'NIC IPv6 Disabled' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
                -Status 'PASS' -Current 'IPv6 disabled' -Expected 'Disabled'
        } else {
            $results += New-CheckResult -Name 'NIC IPv6 Disabled' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
                -Status 'WARN' -Current 'IPv6 enabled' -Expected 'Disabled' `
                -Message 'IPv6 on I226-V can cause dual-stack resolution delays and additional interrupt overhead.' `
                -Fix ('Disable-NetAdapterBinding -Name "' + $nic.Name + '" -ComponentID ms_tcpip6')
        }
    }

    # --- Check 29: NIC Flow Control ---
    $fcResult = 'SKIP'
    $fcDetail = ''
    if ($null -ne $nic) {
        $fc = $null
        try {
            $fc = Get-NetAdapterAdvancedProperty -Name $nic.Name -ErrorAction SilentlyContinue |
                Where-Object { $_.RegistryKeyword -eq '*FlowControl' } | Select-Object -First 1
        } catch {}
        if ($null -ne $fc) {
            $fcDetail = [string]$fc.RegistryValue
            if ($fc.RegistryValue -eq 0) { $fcResult = 'PASS' } else { $fcResult = 'WARN' }
        }
    }
    if ($fcResult -eq 'PASS') {
        $results += New-CheckResult -Name 'NIC Flow Control' -Category 'Network' -Tier 'Deep' -Severity 'LOW' `
            -Status 'PASS' -Current 'Disabled (0)' -Expected 'Disabled'
    } elseif ($fcResult -eq 'WARN') {
        $results += New-CheckResult -Name 'NIC Flow Control' -Category 'Network' -Tier 'Deep' -Severity 'LOW' `
            -Status 'WARN' -Current ('Value ' + $fcDetail) -Expected 'Disabled (0)' `
            -Message 'Flow control pauses can add variable latency spikes.' `
            -Fix ('Set-NetAdapterAdvancedProperty -Name "' + $nic.Name + '" -RegistryKeyword "*FlowControl" -RegistryValue 0')
    } else {
        $results += New-CheckResult -Name 'NIC Flow Control' -Category 'Network' -Tier 'Deep' -Severity 'LOW' `
            -Status 'SKIP' -Current 'No active NIC or property not found' -Expected 'Disabled'
    }

    # --- Check 30: Defender CPU Limit ---
    $defCPU = $null
    try {
        $mp     = Get-MpPreference -ErrorAction Stop
        $defCPU = $mp.ScanAvgCPULoadFactor
    } catch {}
    if ($null -eq $defCPU) {
        $results += New-CheckResult -Name 'Defender CPU Limit' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'ERROR' -Current 'Could not read MpPreference' -Expected '<= 10'
    } elseif ($defCPU -le 10) {
        $results += New-CheckResult -Name 'Defender CPU Limit' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'PASS' -Current ([string]$defCPU + '%') -Expected '<= 10%'
    } else {
        $results += New-CheckResult -Name 'Defender CPU Limit' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ([string]$defCPU + '%') -Expected '<= 10%' `
            -Message 'High Defender CPU limit allows scans to steal CPU time during gaming.' `
            -Fix 'Set-MpPreference -ScanAvgCPULoadFactor 10'
    }

    # --- Check 32: Network Latency Probe ---
    $targets = @(
        @{ Host='8.8.8.8';          Name='Cloudflare DNS' },
        @{ Host='epicgames.com';     Name='Epic Games' }
    )
    $probeLines = @()
    $worstP99   = 0
    foreach ($t in $targets) {
        $pings = @()
        try {
            1..10 | ForEach-Object {
                $r = Test-Connection -ComputerName $t.Host -Count 1 -ErrorAction Stop
                $pings += $r.ResponseTime
            }
        } catch {}
        if ($pings.Count -gt 0) {
            $sorted = $pings | Sort-Object
            $p50    = $sorted[[math]::Floor($sorted.Count * 0.50)]
            $p99    = $sorted[$sorted.Count - 1]
            if ($p99 -gt $worstP99) { $worstP99 = $p99 }
            $probeLines += ($t.Name + ': p50=' + $p50 + 'ms p99=' + $p99 + 'ms')
        } else {
            $probeLines += ($t.Name + ': unreachable')
        }
    }
    $probeSummary = $probeLines -join '; '
    if ($worstP99 -lt 50) {
        $results += New-CheckResult -Name 'Network Latency Probe' -Category 'Network' -Tier 'Deep' -Severity 'INFO' `
            -Status 'PASS' -Current $probeSummary -Expected 'p99 < 50ms'
    } elseif ($worstP99 -lt 100) {
        $results += New-CheckResult -Name 'Network Latency Probe' -Category 'Network' -Tier 'Deep' -Severity 'INFO' `
            -Status 'WARN' -Current $probeSummary -Expected 'p99 < 50ms' `
            -Message 'High p99 latency. Check for background downloads, ISP throttling, or bufferbloat.'
    } else {
        $results += New-CheckResult -Name 'Network Latency Probe' -Category 'Network' -Tier 'Deep' -Severity 'INFO' `
            -Status 'FAIL' -Current $probeSummary -Expected 'p99 < 50ms' `
            -Message 'Very high p99 latency. Likely bufferbloat or ISP congestion. Run a bufferbloat test at waveform.com/tools/bufferbloat'
    }

    return $results
}

# ---------------------------------------------------------------------------
# Deep Tier: Anti-Cheat Driver Detection
# ---------------------------------------------------------------------------
function Invoke-AntiCheatChecks {
    $results = @()

    $acDrivers = @(
        @{ Name = 'EasyAntiCheat';  ServiceName = 'EasyAntiCheat' },
        @{ Name = 'EAC EOS';        ServiceName = 'EasyAntiCheat_EOSSys' },
        @{ Name = 'BattlEye';       ServiceName = 'BEService' },
        @{ Name = 'Vanguard';       ServiceName = 'vgk' },
        @{ Name = 'Vanguard (vgc)'; ServiceName = 'vgc' }
    )

    $detected = @()
    foreach ($ac in $acDrivers) {
        $svc = Get-Service -Name $ac.ServiceName -ErrorAction SilentlyContinue
        if ($null -ne $svc) {
            $detected += ($ac.Name + ' (' + $svc.Status + ')')
        }
    }

    # Check fltmc for minifilter instances
    $fltOutput = ''
    try { $fltOutput = (fltmc instances 2>&1) -join ' ' } catch {}
    if ($fltOutput -match 'EasyAntiCheat' -and $detected.Count -eq 0) {
        $detected += 'EasyAntiCheat (minifilter active)'
    }

    if ($detected.Count -eq 0) {
        $results += New-CheckResult -Name 'Anti-Cheat Drivers' -Category 'OS' -Tier 'Deep' -Severity 'INFO' `
            -Status 'PASS' -Current 'No anti-cheat kernel drivers detected' -Expected 'None or known drivers'
    } else {
        $detectedStr = $detected -join ', '
        $results += New-CheckResult -Name 'Anti-Cheat Drivers' -Category 'OS' -Tier 'Deep' -Severity 'INFO' `
            -Status 'WARN' -Current $detectedStr -Expected 'Awareness only' `
            -Message 'Anti-cheat drivers operate at kernel level. EAC uses PASSIVE_LEVEL callbacks (not visible in DPC/ISR but adds CPU overhead). Vanguard loads at boot.' `
            -Fix '' -FixNote 'Not fixable — informational. Use WPR InputLatency profile to measure actual CPU impact during gameplay.'
    }

    return $results
}
