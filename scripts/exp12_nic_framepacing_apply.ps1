#Requires -RunAsAdministrator
<#
.SYNOPSIS
    EXP12: I226-V NIC Stabilization + Frame Pacing Fixes
.DESCRIPTION
    Addresses persistent stutter after Phase 1 (EXP11) by targeting the Intel I226-V
    NIC hardware bug and frame pacing issues.

    Changes:
    1. Force I226-V link speed to 1 Gbps Full Duplex
       - Eliminates 2.5 Gbps auto-negotiation renegotiation bug
       - Gaming uses <10 Mbps; no perceptible difference
    2. Disable I226-V Selective Suspend
       - Prevents USB-style power saving micro-drops on the NIC
    3. Disable IPv6 on the Ethernet adapter
       - Known interop issues between I226-V and fiber ONTs with IPv6
    4. Increase Selective Suspend Idle Timeout to 60s
       - Failsafe in case Selective Suspend re-enables

    CRITICAL: Driver 1.1.4.42 is a Windows 10 driver (2023).
    Manual step: Update to Windows 11 driver 2.1.5.7 (WHQL, Jan 2026) from:
    https://www.intel.com/content/www/us/en/products/sku/210599/intel-ethernet-controller-i226v/downloads.html

    Research sources:
    - Intel Official: I226-V Connection Issue (KB000095752)
    - Intel Community: I226-V packet rate degrades, CONSTANT ID27 disconnects
    - ASUS ROG Forum: I226-V randomly disconnecting
    - Guru3D: I226-V prone to connection loss
    - AnandTech: Intel stopgap solution for I226 series
.NOTES
    Reboot: NO - NIC renegotiates link automatically (~5s downtime)
    Rollback: Run the rollback commands in the backup file
#>

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$nicName = 'Ethernet'

Write-Host '=== EXP12: I226-V NIC Stabilization ===' -ForegroundColor Cyan

# --- Backup ---
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupFile = Join-Path $projectRoot ('captures\backup_pre_exp12_nic_' + $timestamp + '.txt')
$lines = @(
    '# EXP12 Backup: I226-V NIC settings pre-change state',
    ('# Captured: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
    ''
)

# Capture current NIC state
$lines += '# --- NIC Link State ---'
$nic = Get-NetAdapter -Name $nicName
$lines += ('# Link Speed: ' + $nic.LinkSpeed)
$lines += ('# Status: ' + $nic.Status)
$lines += ('# Driver Version: ' + $nic.DriverVersion)
$lines += ''

# Capture advanced properties we will change
$propsToChange = @('*SpeedDuplex', '*SelectiveSuspend', '*SSIdleTimeout')
$lines += '# --- Advanced Properties (changed by EXP12) ---'
foreach ($kw in $propsToChange) {
    $prop = Get-NetAdapterAdvancedProperty -Name $nicName -RegistryKeyword $kw -ErrorAction SilentlyContinue
    if ($prop) {
        $lines += ('# ' + $prop.DisplayName + ': ' + $prop.DisplayValue + ' (RegistryValue=' + $prop.RegistryValue + ')')
        $lines += ('# Rollback: Set-NetAdapterAdvancedProperty -Name "' + $nicName + '" -RegistryKeyword "' + $kw + '" -RegistryValue ' + $prop.RegistryValue)
    }
}
$lines += ''

# Capture IPv6 state
$ipv6 = Get-NetAdapterBinding -Name $nicName -ComponentID 'ms_tcpip6' -ErrorAction SilentlyContinue
if ($ipv6) {
    $lines += ('# IPv6 Enabled: ' + $ipv6.Enabled)
    if ($ipv6.Enabled) {
        $lines += '# Rollback: Enable-NetAdapterBinding -Name "' + $nicName + '" -ComponentID "ms_tcpip6"'
    } else {
        $lines += '# Rollback: (already disabled, no action needed)'
    }
}

$lines | Out-File -FilePath $backupFile -Encoding UTF8
Write-Host ('Backup saved: ' + $backupFile) -ForegroundColor Green

# ============================================================================
# Apply Changes
# ============================================================================

# --- 1. Force 1 Gbps Full Duplex ---
Write-Host ''
Write-Host '[1/4] Forcing link speed to 1.0 Gbps Full Duplex...' -ForegroundColor Yellow
Write-Host '  Reason: 2.5 Gbps auto-negotiation triggers known I226-V disconnect bug'
Write-Host '  Impact: Gaming uses <10 Mbps; no perceptible speed difference'

Set-NetAdapterAdvancedProperty -Name $nicName -RegistryKeyword '*SpeedDuplex' -RegistryValue 6
Write-Host '  Speed & Duplex = 1.0 Gbps Full Duplex' -ForegroundColor Green

# --- 2. Disable Selective Suspend ---
Write-Host ''
Write-Host '[2/4] Disabling Selective Suspend...' -ForegroundColor Yellow
Write-Host '  Reason: Power saving feature causes micro-drops on I226-V'

Set-NetAdapterAdvancedProperty -Name $nicName -RegistryKeyword '*SelectiveSuspend' -RegistryValue 0
Write-Host '  Selective Suspend = Disabled' -ForegroundColor Green

# --- 3. Set Idle Timeout to max ---
Write-Host ''
Write-Host '[3/4] Setting Selective Suspend Idle Timeout to 60s...' -ForegroundColor Yellow

Set-NetAdapterAdvancedProperty -Name $nicName -RegistryKeyword '*SSIdleTimeout' -RegistryValue 60
Write-Host '  Idle Timeout = 60s' -ForegroundColor Green

# --- 4. Disable IPv6 ---
Write-Host ''
Write-Host '[4/4] Disabling IPv6 on Ethernet adapter...' -ForegroundColor Yellow
Write-Host '  Reason: Known interop issues between I226-V and fiber ONTs with IPv6'

$ipv6Binding = Get-NetAdapterBinding -Name $nicName -ComponentID 'ms_tcpip6' -ErrorAction SilentlyContinue
if ($ipv6Binding -and $ipv6Binding.Enabled) {
    Disable-NetAdapterBinding -Name $nicName -ComponentID 'ms_tcpip6'
    Write-Host '  IPv6 = Disabled' -ForegroundColor Green
} else {
    Write-Host '  IPv6 already disabled (skipped)' -ForegroundColor DarkGray
}

# ============================================================================
# Wait for link renegotiation
# ============================================================================
Write-Host ''
Write-Host 'Waiting for link renegotiation...' -ForegroundColor Yellow
Start-Sleep -Seconds 5

$nicAfter = Get-NetAdapter -Name $nicName
Write-Host ('  Link Speed: ' + $nicAfter.LinkSpeed) -ForegroundColor Cyan
Write-Host ('  Status: ' + $nicAfter.Status) -ForegroundColor Cyan

if ($nicAfter.Status -ne 'Up') {
    Write-Host '  WARNING: NIC not yet up. Wait 10-15 seconds and check again.' -ForegroundColor Red
}

# ============================================================================
# Summary
# ============================================================================
Write-Host ''
Write-Host '=== EXP12 Applied ===' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Changes applied:' -ForegroundColor White
Write-Host '  [1] Speed & Duplex = 1.0 Gbps Full Duplex (was Auto/2.5 Gbps)'
Write-Host '  [2] Selective Suspend = Disabled (was Enabled)'
Write-Host '  [3] Idle Timeout = 60s (was 5s)'
Write-Host '  [4] IPv6 = Disabled on adapter'
Write-Host ''
Write-Host 'MANUAL STEPS REQUIRED:' -ForegroundColor Red
Write-Host '  [A] UPDATE NIC DRIVER: Current 1.1.4.42 is a Windows 10 driver!'
Write-Host '      Download 2.1.5.7 (Win11) from:'
Write-Host '      https://www.intel.com/content/www/us/en/products/sku/210599/intel-ethernet-controller-i226v/downloads.html'
Write-Host '  [B] In Fortnite: Cap FPS to monitor refresh - 3 (e.g., 162 for 165Hz)'
Write-Host '  [C] In Fortnite: Use actual Fullscreen mode (not Borderless Windowed)'
Write-Host '  [D] NVIDIA Reflex: On + Boost'
Write-Host ''
Write-Host 'If stutter persists: Test with a USB Ethernet adapter to bypass I226-V entirely.' -ForegroundColor Yellow
Write-Host ''
Write-Host ('Rollback: See backup at "' + $backupFile + '"') -ForegroundColor DarkGray
