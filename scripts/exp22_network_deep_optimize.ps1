#Requires -RunAsAdministrator
<#
.SYNOPSIS
    EXP22: Deep Network Latency Optimization

.DESCRIPTION
    Comprehensive network stack optimization covering:
    - TCP/IP stack tuning (Nagle, delayed ACK, congestion, auto-tuning)
    - NIC adapter settings (buffers, offloads, power, bindings)
    - DNS optimization (Cloudflare direct, bypass router)
    - NDIS filter cleanup (ExitLag, QoS, bridge, virtualization)
    - Registry parameters (AFD, MMCSS, throttling, ephemeral ports)
    - Keepalive and timeout tuning

    Built from TCP Optimizer + manual registry audit on 2026-04-27.
    System: Intel I226-V 2.5GbE, Windows 11 Build 26200.

.PARAMETER Audit
    Audit-only mode: show current state + recommendations. No changes.

.PARAMETER SkipDns
    Skip DNS server changes.

.PARAMETER SkipBindings
    Skip adapter binding changes (QoS, Bridge, NNV, ExitLag).

.PARAMETER SkipRevert
    Skip the revert of EXP08/EXP12 settings that are suboptimal.

.NOTES
    Reboot: NO — most changes immediate. NIC binding changes may cause ~2s link flap.
    Rollback: backup file written to captures/
    Related: [[burst-pattern-analysis]], [[ping-regression]]
#>
[CmdletBinding()]
param(
    [switch]$Audit,
    [switch]$SkipDns,
    [switch]$SkipBindings,
    [switch]$SkipRevert
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$nicName = 'Ethernet'
$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
$changes = @()
$warnings = @()

Write-Host ''
Write-Host '======================================================' -ForegroundColor Cyan
Write-Host '  EXP22: Deep Network Latency Optimization'           -ForegroundColor Cyan
Write-Host '======================================================' -ForegroundColor Cyan
if ($Audit) { Write-Host '  MODE: AUDIT ONLY (no changes)' -ForegroundColor Yellow }
Write-Host ''

# ────────────────────────────────────────────────────────────────────────────
# BACKUP (skip in audit mode)
# ────────────────────────────────────────────────────────────────────────────
$backupFile = $null
if (-not $Audit) {
    $backupFile = Join-Path $projectRoot ('captures\backup_pre_exp22_network_' + $ts + '.txt')
    New-Item -ItemType Directory -Path (Split-Path $backupFile -Parent) -Force | Out-Null
    $backup = @(
        '# EXP22 Backup: Deep Network Optimization',
        ('# Captured: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        '',
        '# === TCP Global ===',
        (netsh int tcp show global 2>&1 | Out-String),
        '# === TCP Supplemental ===',
        (netsh int tcp show supplemental 2>&1 | Out-String),
        '# === Adapter Bindings ===',
        (Get-NetAdapterBinding -Name $nicName | Format-Table DisplayName, ComponentId, Enabled -AutoSize | Out-String),
        '# === Advanced Properties ===',
        (Get-NetAdapterAdvancedProperty -Name $nicName | Format-Table DisplayName, DisplayValue, RegistryKeyword | Out-String)
    )

    # Capture per-interface TCP
    $nic = Get-NetAdapter -Name $nicName
    $ifPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\' + $nic.InterfaceGuid
    if (Test-Path $ifPath) {
        $ifProps = Get-ItemProperty $ifPath -ErrorAction SilentlyContinue
        $backup += '# === Per-Interface TCP ==='
        $backup += ('# TcpAckFrequency=' + $ifProps.TcpAckFrequency)
        $backup += ('# TCPNoDelay=' + $ifProps.TCPNoDelay)
        $backup += ('# TcpDelAckTicks=' + $ifProps.TcpDelAckTicks)
    }

    # Capture global TCP params
    $tcpParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    $backup += ''
    $backup += '# === Tcpip\Parameters ==='
    $backup += (Get-ItemProperty -Path $tcpParams | Select-Object * -ExcludeProperty PS* | Format-List | Out-String)

    # DNS
    $backup += '# === DNS ==='
    $backup += (Get-DnsClientServerAddress -InterfaceAlias $nicName | Format-Table | Out-String)

    $backup | Out-File -FilePath $backupFile -Encoding UTF8
    Write-Host ('[BACKUP] ' + $backupFile) -ForegroundColor Green
    Write-Host ''
}

# Helper: apply or audit
function Apply-Setting {
    param(
        [string]$Name,
        [string]$Current,
        [string]$Target,
        [scriptblock]$Action,
        [string]$Rollback
    )
    if ($Current -eq $Target) {
        Write-Host ('  [OK]   ' + $Name + ' = ' + $Current) -ForegroundColor Green
        return
    }
    if ($Audit) {
        Write-Host ('  [TODO] ' + $Name + ': ' + $Current + ' -> ' + $Target) -ForegroundColor Yellow
    } else {
        try {
            & $Action
            Write-Host ('  [SET]  ' + $Name + ': ' + $Current + ' -> ' + $Target) -ForegroundColor Cyan
            $script:changes += ($Name + ': ' + $Current + ' -> ' + $Target)
        } catch {
            Write-Host ('  [FAIL] ' + $Name + ': ' + $_.Exception.Message) -ForegroundColor Red
            $script:warnings += ($Name + ': ' + $_.Exception.Message)
        }
    }
}

# ════════════════════════════════════════════════════════════════════════════
# SECTION 1: TCP GLOBAL PARAMETERS
# ════════════════════════════════════════════════════════════════════════════
Write-Host '--- 1. TCP Global Parameters ---' -ForegroundColor Yellow

# 1a. Auto-Tuning Level
# EXP08 set "restricted" but this HURTS large downloads. "normal" is best for gaming
# because game packets are tiny (< MTU) and auto-tuning doesn't affect them.
$autoTune = ((netsh int tcp show global | Select-String 'Auto-Tuning') -replace '.*:\s*', '').Trim()
Apply-Setting 'AutoTuningLevel' $autoTune 'normal' {
    netsh int tcp set global autotuninglevel=normal | Out-Null
} 'netsh int tcp set global autotuninglevel=restricted'

# 1b. ECN — keep disabled (some routers/ISPs drop ECN-marked packets)
$ecn = ((netsh int tcp show global | Select-String 'ECN Cap') -replace '.*:\s*', '').Trim()
Apply-Setting 'ECN' $ecn 'disabled' {
    netsh int tcp set global ecncapability=disabled | Out-Null
} 'netsh int tcp set global ecncapability=enabled'

# 1c. Timestamps — keep disabled (saves 12 bytes per packet)
$tsTcp = ((netsh int tcp show global | Select-String 'Timestamps') -replace '.*:\s*', '').Trim()
Apply-Setting 'Timestamps' $tsTcp 'disabled' {
    netsh int tcp set global timestamps=disabled | Out-Null
} 'netsh int tcp set global timestamps=allowed'

# 1d. RSC — keep disabled (prevents packet coalescing latency)
$rsc = ((netsh int tcp show global | Select-String 'Receive Segment Coalescing') -replace '.*:\s*', '').Trim()
Apply-Setting 'RSC' $rsc 'disabled' {
    netsh int tcp set global rsc=disabled | Out-Null
} 'netsh int tcp set global rsc=enabled'

# 1e. Initial RTO — 300ms (already set by EXP08, was default 1000ms in original Windows)
$rto = ((netsh int tcp show global | Select-String 'Initial RTO') -replace '.*:\s*', '').Trim()
Apply-Setting 'InitialRTO' $rto '300' {
    netsh int tcp set global initialRto=300 | Out-Null
} 'netsh int tcp set global initialRto=1000'

# 1f. Max SYN Retransmissions — reduce from 4 to 2 (fail faster on unreachable)
$synRetrans = ((netsh int tcp show global | Select-String 'Max SYN Retrans') -replace '.*:\s*', '').Trim()
Apply-Setting 'MaxSynRetransmissions' $synRetrans '2' {
    netsh int tcp set global maxsynretransmissions=2 | Out-Null
} 'netsh int tcp set global maxsynretransmissions=4'

# 1g. TCP Fast Open — keep enabled (saves 1 RTT on reconnection)
$fastOpenLines = @(netsh int tcp show global | Select-String 'Fast Open\b')
$fastOpen = 'unknown'
if ($fastOpenLines.Count -gt 0) {
    $fastOpen = ($fastOpenLines[0].ToString() -replace '.*:\s*', '').Trim()
}
Apply-Setting 'FastOpen' $fastOpen 'enabled' {
    netsh int tcp set global fastopen=enabled | Out-Null
} 'netsh int tcp set global fastopen=disabled'

# 1h. Window Scaling Heuristics — keep disabled
$heuristicsLines = @(netsh int tcp show heuristics | Select-String 'Window Scaling heuristics')
$heuristics = 'unknown'
if ($heuristicsLines.Count -gt 0) {
    $heuristics = ($heuristicsLines[0].ToString() -replace '.*:\s*', '').Trim()
}
Apply-Setting 'Heuristics' $heuristics 'disabled' {
    netsh int tcp set heuristics disabled | Out-Null
} 'netsh int tcp set heuristics enabled'

Write-Host ''

# ════════════════════════════════════════════════════════════════════════════
# SECTION 2: TCP SUPPLEMENTAL (Congestion Control)
# ════════════════════════════════════════════════════════════════════════════
Write-Host '--- 2. Congestion Control ---' -ForegroundColor Yellow

# CUBIC is good for gaming. BBR is better for throughput but needs kernel support.
$ccpLine = (netsh int tcp show supplemental | Select-String 'Congestion Control Provider')
$ccp = ($ccpLine -replace '.*:\s*', '').Trim()
Apply-Setting 'CongestionProvider' $ccp 'cubic' {
    netsh int tcp set supplemental template=internet congestionprovider=cubic | Out-Null
} 'netsh int tcp set supplemental template=internet congestionprovider=default'

# Initial Congestion Window = 10 MSS (good, some set to 4 but 10 is RFC 6928 standard)
$icw = ((netsh int tcp show supplemental | Select-String 'Initial Congestion Window') -replace '.*:\s*', '').Trim()
Apply-Setting 'InitialCongestionWindow' $icw '10' {
    netsh int tcp set supplemental template=internet icw=10 | Out-Null
} ''

# Delayed ACK timeout — reduce from 40ms to 10ms for faster ACK
$delayedAck = ((netsh int tcp show supplemental | Select-String 'Delayed ACK timeout') -replace '.*:\s*', '').Trim()
Apply-Setting 'DelayedACKTimeout' $delayedAck '10' {
    netsh int tcp set supplemental template=internet delayedacktimeout=10 | Out-Null
} 'netsh int tcp set supplemental template=internet delayedacktimeout=40'

# Minimum RTO — 300ms is already aggressive (default 300ms in Win11)
$minRto = ((netsh int tcp show supplemental | Select-String 'Minimum RTO') -replace '.*:\s*', '').Trim()
Apply-Setting 'MinimumRTO' $minRto '300' {
    netsh int tcp set supplemental template=internet minrto=300 | Out-Null
} ''

Write-Host ''

# ════════════════════════════════════════════════════════════════════════════
# SECTION 3: PER-INTERFACE TCP (Nagle / Delayed ACK)
# ════════════════════════════════════════════════════════════════════════════
Write-Host '--- 3. Per-Interface TCP (Nagle/DelayedACK) ---' -ForegroundColor Yellow

$nic = Get-NetAdapter -Name $nicName
$ifPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\' + $nic.InterfaceGuid

# TcpNoDelay=1 (disable Nagle)
$noDelay = (Get-ItemProperty -Path $ifPath -Name TCPNoDelay -ErrorAction SilentlyContinue).TCPNoDelay
$noDelayStr = if ($null -eq $noDelay) { 'not set' } else { $noDelay.ToString() }
Apply-Setting 'TCPNoDelay' $noDelayStr '1' {
    Set-ItemProperty -Path $ifPath -Name TCPNoDelay -Value 1 -Type DWord
} ''

# TcpAckFrequency=1 (ACK every packet, disable delayed ACK)
$ackFreq = (Get-ItemProperty -Path $ifPath -Name TcpAckFrequency -ErrorAction SilentlyContinue).TcpAckFrequency
$ackFreqStr = if ($null -eq $ackFreq) { 'not set' } else { $ackFreq.ToString() }
Apply-Setting 'TcpAckFrequency' $ackFreqStr '1' {
    Set-ItemProperty -Path $ifPath -Name TcpAckFrequency -Value 1 -Type DWord
} ''

# TcpDelAckTicks=0 (zero delayed ACK timer — belt + suspenders with AckFrequency=1)
$delTicks = (Get-ItemProperty -Path $ifPath -Name TcpDelAckTicks -ErrorAction SilentlyContinue).TcpDelAckTicks
$delTicksStr = if ($null -eq $delTicks) { 'not set' } else { $delTicks.ToString() }
Apply-Setting 'TcpDelAckTicks' $delTicksStr '0' {
    Set-ItemProperty -Path $ifPath -Name TcpDelAckTicks -Value 0 -Type DWord
} ''

Write-Host ''

# ════════════════════════════════════════════════════════════════════════════
# SECTION 4: GLOBAL TCP PARAMETERS (Registry)
# ════════════════════════════════════════════════════════════════════════════
Write-Host '--- 4. Global TCP Parameters (Registry) ---' -ForegroundColor Yellow

$tcpParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'

# DefaultTTL — 64 (Linux default, reduces OS fingerprinting, standard hop count)
$ttl = (Get-ItemProperty -Path $tcpParams -Name DefaultTTL -ErrorAction SilentlyContinue).DefaultTTL
$ttlStr = if ($null -eq $ttl) { '128' } else { $ttl.ToString() }
Apply-Setting 'DefaultTTL' $ttlStr '64' {
    Set-ItemProperty -Path $tcpParams -Name DefaultTTL -Value 64 -Type DWord
} 'Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name DefaultTTL'

# Tcp1323Opts — 0 = disable window scaling + timestamps (gaming packets are tiny)
$tcp1323 = (Get-ItemProperty -Path $tcpParams -Name Tcp1323Opts -ErrorAction SilentlyContinue).Tcp1323Opts
$tcp1323Str = if ($null -eq $tcp1323) { '0' } else { $tcp1323.ToString() }
Apply-Setting 'Tcp1323Opts' $tcp1323Str '0' {
    Set-ItemProperty -Path $tcpParams -Name Tcp1323Opts -Value 0 -Type DWord
} ''

# TcpMaxDataRetransmissions — 3 (faster give-up on dead connections, default 5)
$maxRetrans = (Get-ItemProperty -Path $tcpParams -Name TcpMaxDataRetransmissions -ErrorAction SilentlyContinue).TcpMaxDataRetransmissions
$maxRetransStr = if ($null -eq $maxRetrans) { '5' } else { $maxRetrans.ToString() }
Apply-Setting 'TcpMaxDataRetransmissions' $maxRetransStr '3' {
    Set-ItemProperty -Path $tcpParams -Name TcpMaxDataRetransmissions -Value 3 -Type DWord
} 'Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name TcpMaxDataRetransmissions'

# TcpTimedWaitDelay — 30 (seconds, default 120; free up ephemeral ports faster)
$twDelay = (Get-ItemProperty -Path $tcpParams -Name TcpTimedWaitDelay -ErrorAction SilentlyContinue).TcpTimedWaitDelay
$twDelayStr = if ($null -eq $twDelay) { '120' } else { $twDelay.ToString() }
Apply-Setting 'TcpTimedWaitDelay' $twDelayStr '30' {
    Set-ItemProperty -Path $tcpParams -Name TcpTimedWaitDelay -Value 30 -Type DWord
} 'Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name TcpTimedWaitDelay'

# MaxUserPort — keep default (Windows 11 already uses 1025-65535 dynamic range)

# DisableTaskOffload — 0 (keep hardware offload active)
$taskOff = (Get-ItemProperty -Path $tcpParams -Name DisableTaskOffload -ErrorAction SilentlyContinue).DisableTaskOffload
$taskOffStr = if ($null -eq $taskOff) { '0' } else { $taskOff.ToString() }
Apply-Setting 'DisableTaskOffload' $taskOffStr '0' {
    Set-ItemProperty -Path $tcpParams -Name DisableTaskOffload -Value 0 -Type DWord
} ''

# ICMP Redirects — disable (prevents route hijacking)
$icmpRedir = (Get-ItemProperty -Path $tcpParams -Name EnableICMPRedirect -ErrorAction SilentlyContinue).EnableICMPRedirect
$icmpRedirStr = if ($null -eq $icmpRedir) { '1' } else { $icmpRedir.ToString() }
Apply-Setting 'EnableICMPRedirect' $icmpRedirStr '0' {
    Set-ItemProperty -Path $tcpParams -Name EnableICMPRedirect -Value 0 -Type DWord
} 'Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name EnableICMPRedirect -Value 1 -Type DWord'

# Dead Gateway Detection — disable (prevents automatic gateway switching)
$deadGw = (Get-ItemProperty -Path $tcpParams -Name DeadGWDetectDefault -ErrorAction SilentlyContinue).DeadGWDetectDefault
$deadGwStr = if ($null -eq $deadGw) { '1' } else { $deadGw.ToString() }
Apply-Setting 'DeadGWDetect' $deadGwStr '0' {
    Set-ItemProperty -Path $tcpParams -Name DeadGWDetectDefault -Value 0 -Type DWord
} 'Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name DeadGWDetectDefault -Value 1 -Type DWord'

Write-Host ''

# ════════════════════════════════════════════════════════════════════════════
# SECTION 5: MULTIMEDIA / NETWORK THROTTLING
# ════════════════════════════════════════════════════════════════════════════
Write-Host '--- 5. MMCSS / Network Throttling ---' -ForegroundColor Yellow

$mmPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'

# NetworkThrottlingIndex = 0xFFFFFFFF (disable throttling — already set)
$nti = (Get-ItemProperty -Path $mmPath -Name NetworkThrottlingIndex -ErrorAction SilentlyContinue).NetworkThrottlingIndex
$ntiStr = if ($null -eq $nti) { 'not set' } else { $nti.ToString() }
$targetNti = '4294967295'
Apply-Setting 'NetworkThrottlingIndex' $ntiStr $targetNti {
    Set-ItemProperty -Path $mmPath -Name NetworkThrottlingIndex -Value ([uint32]::MaxValue) -Type DWord
} ''

# SystemResponsiveness = 0 (max foreground priority — already set)
$sr = (Get-ItemProperty -Path $mmPath -Name SystemResponsiveness -ErrorAction SilentlyContinue).SystemResponsiveness
$srStr = if ($null -eq $sr) { 'not set' } else { $sr.ToString() }
Apply-Setting 'SystemResponsiveness' $srStr '0' {
    Set-ItemProperty -Path $mmPath -Name SystemResponsiveness -Value 0 -Type DWord
} ''

Write-Host ''

# ════════════════════════════════════════════════════════════════════════════
# SECTION 6: DNS OPTIMIZATION
# ════════════════════════════════════════════════════════════════════════════
if (-not $SkipDns) {
    Write-Host '--- 6. DNS Optimization ---' -ForegroundColor Yellow

    $dnsServers = (Get-DnsClientServerAddress -InterfaceAlias $nicName -AddressFamily IPv4).ServerAddresses
    $currentDns = $dnsServers -join ','
    $targetDns = '1.1.1.1,1.0.0.1'

    # Cloudflare 1.1.1.1 primary, 1.0.0.1 secondary (bypass router DNS for lower latency)
    Apply-Setting 'DNS Servers' $currentDns $targetDns {
        Set-DnsClientServerAddress -InterfaceAlias $nicName -ServerAddresses @('1.1.1.1', '1.0.0.1')
    } ('Set-DnsClientServerAddress -InterfaceAlias "' + $nicName + '" -ServerAddresses @("192.168.4.1","1.1.1.1")')

    # Flush DNS cache after server change
    if (-not $Audit -and $currentDns -ne $targetDns) {
        Clear-DnsClientCache
        Write-Host '  [SET]  DNS cache flushed' -ForegroundColor Cyan
    }

    Write-Host ''
} else {
    Write-Host '--- 6. DNS: skipped ---' -ForegroundColor DarkGray
    Write-Host ''
}

# ════════════════════════════════════════════════════════════════════════════
# SECTION 7: NIC ADAPTER BINDINGS CLEANUP
# ════════════════════════════════════════════════════════════════════════════
if (-not $SkipBindings) {
    Write-Host '--- 7. NIC Adapter Bindings ---' -ForegroundColor Yellow

    # Remove unnecessary protocol bindings that add per-packet overhead
    $bindingsToDisable = @(
        @{ Id = 'ms_pacer';    Name = 'QoS Packet Scheduler';    Reason = 'No QoS policies defined' },
        @{ Id = 'ms_l2bridge'; Name = 'Bridge Driver';           Reason = 'Not using Hyper-V virtual switch' },
        @{ Id = 'ms_l1vhlwf';  Name = 'Nested Network Virt';     Reason = 'Not using nested Hyper-V' }
    )

    foreach ($b in $bindingsToDisable) {
        $binding = Get-NetAdapterBinding -Name $nicName -ComponentId $b.Id -ErrorAction SilentlyContinue
        if (-not $binding) {
            Write-Host ('  [SKIP] ' + $b.Name + ' not present') -ForegroundColor DarkGray
            continue
        }
        $state = if ($binding.Enabled) { 'Enabled' } else { 'Disabled' }
        Apply-Setting $b.Name $state 'Disabled' {
            Disable-NetAdapterBinding -Name $nicName -ComponentId $b.Id
        } ('Enable-NetAdapterBinding -Name "' + $nicName + '" -ComponentId "' + $b.Id + '"')
    }

    # ExitLag — already disabled by fix_exitlag_filter.ps1
    $exitlag = Get-NetAdapterBinding -Name $nicName -ComponentId 'nt_ndextlag' -ErrorAction SilentlyContinue
    if ($exitlag) {
        $elState = if ($exitlag.Enabled) { 'Enabled' } else { 'Disabled' }
        Write-Host ('  [INFO] ExitLag NDIS Filter: ' + $elState + ' (managed by fix_exitlag_filter.ps1)') -ForegroundColor Gray
    }

    Write-Host ''
} else {
    Write-Host '--- 7. Bindings: skipped ---' -ForegroundColor DarkGray
    Write-Host ''
}

# ════════════════════════════════════════════════════════════════════════════
# SECTION 8: NIC ADVANCED PROPERTIES
# ════════════════════════════════════════════════════════════════════════════
Write-Host '--- 8. NIC Advanced Properties ---' -ForegroundColor Yellow

# Helper to read NIC advanced property safely (RegistryValue can be string[])
function Get-NicPropValue {
    param([string]$Keyword)
    $prop = Get-NetAdapterAdvancedProperty -Name $nicName -RegistryKeyword $Keyword -ErrorAction SilentlyContinue
    if (-not $prop) { return 'not set' }
    $raw = $prop.RegistryValue
    if ($raw -is [array]) { return $raw[0].ToString() }
    if ($null -ne $raw) { return $raw.ToString() }
    return 'not set'
}

# Receive/Transmit Buffers — I226-V stores these in driver class registry, not via
# Set-NetAdapterAdvancedProperty. Set directly in driver key.
$wmiNic = Get-CimInstance -ClassName Win32_NetworkAdapter -Filter 'Name like "%I226%"' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($wmiNic -and $wmiNic.PNPDeviceID) {
    $enumKey = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $wmiNic.PNPDeviceID
    $driverSub = (Get-ItemProperty -Path $enumKey -Name 'Driver' -ErrorAction SilentlyContinue).Driver
    if ($driverSub) {
        $driverKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\' + $driverSub
        $rxBuf = (Get-ItemProperty -Path $driverKey -Name '*ReceiveBuffers' -ErrorAction SilentlyContinue).'*ReceiveBuffers'
        $rxBufStr = if ($null -eq $rxBuf) { '1024' } else { $rxBuf.ToString() }
        Apply-Setting 'ReceiveBuffers' $rxBufStr '2048' {
            Set-ItemProperty -Path $driverKey -Name '*ReceiveBuffers' -Value '2048' -Type String
        } ('Set-ItemProperty -Path "' + $driverKey + '" -Name "*ReceiveBuffers" -Value "1024" -Type String')

        $txBuf = (Get-ItemProperty -Path $driverKey -Name '*TransmitBuffers' -ErrorAction SilentlyContinue).'*TransmitBuffers'
        $txBufStr = if ($null -eq $txBuf) { '1024' } else { $txBuf.ToString() }
        Apply-Setting 'TransmitBuffers' $txBufStr '2048' {
            Set-ItemProperty -Path $driverKey -Name '*TransmitBuffers' -Value '2048' -Type String
        } ('Set-ItemProperty -Path "' + $driverKey + '" -Name "*TransmitBuffers" -Value "1024" -Type String')
    }
} else {
    Write-Host '  [SKIP] Could not find I226-V driver key for buffer settings' -ForegroundColor DarkGray
}

# ARP Offload — disable (desktop never sleeps, saves NIC firmware overhead)
$arpOffStr = Get-NicPropValue '*PMARPOffload'
Apply-Setting 'ARPOffload' $arpOffStr '0' {
    Set-NetAdapterAdvancedProperty -Name $nicName -RegistryKeyword '*PMARPOffload' -RegistryValue 0
} ('Set-NetAdapterAdvancedProperty -Name "' + $nicName + '" -RegistryKeyword "*PMARPOffload" -RegistryValue 1')

# NS Offload — disable (same reason)
$nsOffStr = Get-NicPropValue '*PMNSOffload'
Apply-Setting 'NSOffload' $nsOffStr '0' {
    Set-NetAdapterAdvancedProperty -Name $nicName -RegistryKeyword '*PMNSOffload' -RegistryValue 0
} ('Set-NetAdapterAdvancedProperty -Name "' + $nicName + '" -RegistryKeyword "*PMNSOffload" -RegistryValue 1')

# Verify existing good settings
$goodSettings = @(
    @{ Keyword = '*InterruptModeration'; Expected = '0'; Name = 'InterruptModeration' },
    @{ Keyword = '*FlowControl';         Expected = '0'; Name = 'FlowControl' },
    @{ Keyword = '*EEE';                 Expected = '0'; Name = 'EEE' },
    @{ Keyword = '*LsoV2IPv4';           Expected = '0'; Name = 'LSOv2_IPv4' },
    @{ Keyword = '*LsoV2IPv6';           Expected = '0'; Name = 'LSOv2_IPv6' },
    @{ Keyword = '*WakeOnMagicPacket';   Expected = '0'; Name = 'WakeOnMagicPacket' },
    @{ Keyword = '*WakeOnPattern';       Expected = '0'; Name = 'WakeOnPattern' }
)
foreach ($gs in $goodSettings) {
    $prop = Get-NetAdapterAdvancedProperty -Name $nicName -RegistryKeyword $gs.Keyword -ErrorAction SilentlyContinue
    $valStr = 'not set'
    if ($prop) {
        $raw = $prop.RegistryValue
        if ($raw -is [array]) { $valStr = $raw[0].ToString() }
        elseif ($null -ne $raw) { $valStr = $raw.ToString() }
    }
    Apply-Setting $gs.Name $valStr $gs.Expected {
        Set-NetAdapterAdvancedProperty -Name $nicName -RegistryKeyword $gs.Keyword -RegistryValue ([int]$gs.Expected)
    } ''
}

Write-Host ''

# ════════════════════════════════════════════════════════════════════════════
# SECTION 9: NETWORK OFFLOAD GLOBAL
# ════════════════════════════════════════════════════════════════════════════
Write-Host '--- 9. Global Offload Settings ---' -ForegroundColor Yellow

$offload = Get-NetOffloadGlobalSetting
Apply-Setting 'ReceiveSegmentCoalescing' $offload.ReceiveSegmentCoalescing.ToString() 'Disabled' {
    Set-NetOffloadGlobalSetting -ReceiveSegmentCoalescing Disabled
} 'Set-NetOffloadGlobalSetting -ReceiveSegmentCoalescing Enabled'

Apply-Setting 'PacketCoalescingFilter' $offload.PacketCoalescingFilter.ToString() 'Disabled' {
    Set-NetOffloadGlobalSetting -PacketCoalescingFilter Disabled
} 'Set-NetOffloadGlobalSetting -PacketCoalescingFilter Enabled'

# RSS — keep enabled (distributes NIC interrupts across CPUs)
Apply-Setting 'ReceiveSideScaling' $offload.ReceiveSideScaling.ToString() 'Enabled' {
    Set-NetOffloadGlobalSetting -ReceiveSideScaling Enabled
} ''

# Chimney — already disabled/deprecated on Win11
Apply-Setting 'Chimney' $offload.Chimney.ToString() 'Disabled' {
    Set-NetOffloadGlobalSetting -Chimney Disabled
} ''

Write-Host ''

# ════════════════════════════════════════════════════════════════════════════
# SECTION 10: KEEPALIVE TUNING
# ════════════════════════════════════════════════════════════════════════════
Write-Host '--- 10. Keepalive Tuning ---' -ForegroundColor Yellow

# Reduce keepalive from 2 hours to 5 minutes (detect dead connections faster)
$kaTime = (Get-ItemProperty -Path $tcpParams -Name KeepAliveTime -ErrorAction SilentlyContinue).KeepAliveTime
$kaTimeStr = if ($null -eq $kaTime) { '7200000' } else { $kaTime.ToString() }
Apply-Setting 'KeepAliveTime' $kaTimeStr '300000' {
    Set-ItemProperty -Path $tcpParams -Name KeepAliveTime -Value 300000 -Type DWord
} 'Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name KeepAliveTime'

# Keepalive interval — 1000ms (1s between probes, default is fine)
$kaInterval = (Get-ItemProperty -Path $tcpParams -Name KeepAliveInterval -ErrorAction SilentlyContinue).KeepAliveInterval
$kaIntervalStr = if ($null -eq $kaInterval) { '1000' } else { $kaInterval.ToString() }
Apply-Setting 'KeepAliveInterval' $kaIntervalStr '1000' {
    Set-ItemProperty -Path $tcpParams -Name KeepAliveInterval -Value 1000 -Type DWord
} ''

Write-Host ''

# ════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ════════════════════════════════════════════════════════════════════════════
Write-Host '======================================================' -ForegroundColor Cyan
Write-Host '  SUMMARY'                                              -ForegroundColor Cyan
Write-Host '======================================================' -ForegroundColor Cyan
Write-Host ''

if ($Audit) {
    Write-Host '  Mode: AUDIT ONLY — no changes made' -ForegroundColor Yellow
    Write-Host '  Run without -Audit to apply changes.' -ForegroundColor Yellow
} else {
    if ($changes.Count -eq 0) {
        Write-Host '  All settings already optimal!' -ForegroundColor Green
    } else {
        Write-Host ('  Applied ' + $changes.Count + ' changes:') -ForegroundColor Cyan
        foreach ($c in $changes) {
            Write-Host ('    - ' + $c) -ForegroundColor White
        }
    }
    if ($warnings.Count -gt 0) {
        Write-Host ''
        Write-Host ('  ' + $warnings.Count + ' warnings:') -ForegroundColor Red
        foreach ($w in $warnings) {
            Write-Host ('    - ' + $w) -ForegroundColor Yellow
        }
    }
    Write-Host ''
    Write-Host ('  Backup: ' + $backupFile) -ForegroundColor Green
}

Write-Host ''
Write-Host '  Key optimizations in this config:' -ForegroundColor White
Write-Host '    TCP:  Nagle=OFF, DelayedACK=OFF, Timestamps=OFF, RSC=OFF' -ForegroundColor Gray
Write-Host '    TCP:  InitialRTO=300ms, MaxSynRetrans=2, FastOpen=ON' -ForegroundColor Gray
Write-Host '    TCP:  AutoTuning=normal, CUBIC, TcpTimedWaitDelay=30s' -ForegroundColor Gray
Write-Host '    TCP:  DelayedACKTimeout=10ms (supplemental)' -ForegroundColor Gray
Write-Host '    NIC:  IntMod=OFF, EEE=OFF, Flow=OFF, LSO=OFF, Buffers=2048' -ForegroundColor Gray
Write-Host '    NIC:  QoS/Bridge/NNV bindings removed, ExitLag managed' -ForegroundColor Gray
Write-Host '    DNS:  1.1.1.1 + 1.0.0.1 (Cloudflare direct, no router hop)' -ForegroundColor Gray
Write-Host '    SYS:  NetworkThrottling=OFF, SystemResponsiveness=0' -ForegroundColor Gray
Write-Host ''
