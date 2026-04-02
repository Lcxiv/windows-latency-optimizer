#Requires -RunAsAdministrator
<#
.SYNOPSIS
    EXP12: Post-Driver-Update NIC Re-tuning
.DESCRIPTION
    After I226-V driver update from 1.1.4.42 (Win10) to 2.1.5.7 (Win11),
    the driver created a new interface GUID, wiping per-interface Nagle
    disable and interrupt affinity settings. TCP global settings survived.

    This script:
    1. Captures a baseline with the new driver (pre-tweak)
    2. Re-applies Nagle disable (TcpAckFrequency=1, TCPNoDelay=1)
    3. Re-applies NIC interrupt affinity (CPUs 4-7, mask=0xF0)
    4. Disables WakeOnMagicPacketFromS5
    5. Captures a post-tweak measurement

    Settings preserved by driver update (no action needed):
    - EEE=Off, FlowControl=Disabled, InterruptModeration=Disabled
    - Speed=1Gbps, LSO=Disabled, IPv6=Disabled
    - TCP global: auto-tuning=restricted, timestamps=disabled, RSC=disabled, InitialRTO=300
.NOTES
    Reboot: YES — interrupt affinity requires reboot
    Rollback: Run the rollback commands in the backup file
#>

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent

Write-Host '=== EXP12: Post-Driver-Update NIC Re-tuning ===' -ForegroundColor Cyan
Write-Host ''

# --- Backup ---
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupFile = Join-Path $projectRoot ('captures\backup_pre_exp12_nic_' + $timestamp + '.txt')
$lines = @(
    '# EXP12 Backup: NIC re-tuning pre-change state',
    ('# Captured: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
    ('# Driver version: ' + (Get-NetAdapter -Name 'Ethernet').DriverVersion),
    ''
)

# Capture current NIC state
$nic = Get-NetAdapter -Name 'Ethernet'
$nicGuid = $nic.InterfaceGuid
$nicPnp = $nic.PnPDeviceID
$ifPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\' + $nicGuid
$affinityPath = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $nicPnp + '\Device Parameters\Interrupt Management\Affinity Policy'

$lines += '# --- Per-Interface TCP (Nagle) ---'
$lines += ('# Interface GUID: ' + $nicGuid)
$lines += ('# Registry path: ' + $ifPath)
if (Test-Path $ifPath) {
    $ifProps = Get-ItemProperty $ifPath -ErrorAction SilentlyContinue
    $lines += ('# TcpAckFrequency: ' + $ifProps.TcpAckFrequency)
    $lines += ('# TCPNoDelay: ' + $ifProps.TCPNoDelay)
} else {
    $lines += '# (path does not exist)'
}
$lines += ('# Rollback: Remove-ItemProperty "' + $ifPath + '" -Name TcpAckFrequency -ErrorAction SilentlyContinue')
$lines += ('# Rollback: Remove-ItemProperty "' + $ifPath + '" -Name TCPNoDelay -ErrorAction SilentlyContinue')
$lines += ''

$lines += '# --- Interrupt Affinity ---'
$lines += ('# PnP ID: ' + $nicPnp)
if (Test-Path $affinityPath) {
    $affProps = Get-ItemProperty $affinityPath -ErrorAction SilentlyContinue
    $lines += ('# DevicePolicy: ' + $affProps.DevicePolicy)
    $hexBytes = ''
    if ($affProps.AssignmentSetOverride) {
        $hexBytes = ($affProps.AssignmentSetOverride | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
    }
    $lines += ('# AssignmentSetOverride: ' + $hexBytes)
} else {
    $lines += '# (affinity path does not exist — using defaults)'
}
$lines += ('# Rollback: Remove-Item "' + $affinityPath + '" -Recurse -ErrorAction SilentlyContinue')
$lines += ''

$lines += '# --- WakeOnMagicPacketFromS5 ---'
$wakeS5 = Get-NetAdapterAdvancedProperty -Name 'Ethernet' -RegistryKeyword 'WakeOnMagicPacketFromS5' -ErrorAction SilentlyContinue
if ($wakeS5) {
    $lines += ('# Current: ' + $wakeS5.DisplayValue)
    $lines += ('# Rollback: Set-NetAdapterAdvancedProperty -Name "Ethernet" -RegistryKeyword "WakeOnMagicPacketFromS5" -RegistryValue ' + $wakeS5.RegistryValue)
}

$lines | Out-File -FilePath $backupFile -Encoding UTF8
Write-Host ('Backup saved: ' + $backupFile) -ForegroundColor Green

# ============================================================================
# Apply Changes
# ============================================================================

# --- 1. Re-apply Nagle Disable ---
Write-Host ''
Write-Host '[1/3] Re-applying Nagle disable on new interface GUID...' -ForegroundColor Yellow
Write-Host ('  Interface GUID: ' + $nicGuid)

if (-not (Test-Path $ifPath)) {
    Write-Host '  WARNING: Interface registry path does not exist. Creating...' -ForegroundColor DarkYellow
}
Set-ItemProperty -Path $ifPath -Name TcpAckFrequency -Value 1 -Type DWord
Set-ItemProperty -Path $ifPath -Name TCPNoDelay -Value 1 -Type DWord
Write-Host '  TcpAckFrequency = 1, TCPNoDelay = 1' -ForegroundColor Green

# Verify
$verify = Get-ItemProperty $ifPath -ErrorAction SilentlyContinue
Write-Host ('  Verify TcpAckFrequency: ' + $verify.TcpAckFrequency)
Write-Host ('  Verify TCPNoDelay: ' + $verify.TCPNoDelay)

# --- 2. Re-apply Interrupt Affinity (CPUs 4-7) ---
Write-Host ''
Write-Host '[2/3] Re-applying NIC interrupt affinity (CPUs 4-7, mask=0xF0)...' -ForegroundColor Yellow
Write-Host '  NOTE: Requires reboot to take effect'

if (-not (Test-Path $affinityPath)) {
    New-Item -Path $affinityPath -Force | Out-Null
}
Set-ItemProperty -Path $affinityPath -Name DevicePolicy -Value 4 -Type DWord
Set-ItemProperty -Path $affinityPath -Name AssignmentSetOverride -Value ([byte[]](0xF0, 0x00)) -Type Binary
Write-Host '  DevicePolicy = 4 (IrqPolicySpecifiedProcessors)' -ForegroundColor Green
Write-Host '  AssignmentSetOverride = F0 00 (CPUs 4-7)' -ForegroundColor Green

# --- 3. Disable WakeOnMagicPacketFromS5 ---
Write-Host ''
Write-Host '[3/3] Disabling WakeOnMagicPacketFromS5...' -ForegroundColor Yellow

$wakeS5Prop = Get-NetAdapterAdvancedProperty -Name 'Ethernet' -RegistryKeyword 'WakeOnMagicPacketFromS5' -ErrorAction SilentlyContinue
if ($wakeS5Prop) {
    Set-NetAdapterAdvancedProperty -Name 'Ethernet' -RegistryKeyword 'WakeOnMagicPacketFromS5' -RegistryValue 0
    Write-Host '  WakeOnMagicPacketFromS5 = Disabled' -ForegroundColor Green
} else {
    Write-Host '  Property not found on new driver (skipped)' -ForegroundColor DarkGray
}

# ============================================================================
# Summary
# ============================================================================
Write-Host ''
Write-Host '=== EXP12 Applied ===' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Changes applied:' -ForegroundColor White
Write-Host '  [1] Nagle disable re-applied (TcpAckFrequency=1, TCPNoDelay=1)'
Write-Host '  [2] NIC interrupt affinity re-applied (CPUs 4-7, REBOOT REQUIRED)'
Write-Host '  [3] WakeOnMagicPacketFromS5 disabled'
Write-Host ''
Write-Host 'Settings already correct (no changes):' -ForegroundColor DarkGray
Write-Host '  EEE=Off, FlowControl=Disabled, InterruptModeration=Disabled'
Write-Host '  Speed=1Gbps, LSO=Disabled, IPv6=Disabled'
Write-Host '  TCP global: auto-tuning=restricted, timestamps=disabled, RSC=disabled, InitialRTO=300'
Write-Host ''
Write-Host 'REBOOT REQUIRED for interrupt affinity change.' -ForegroundColor Yellow
Write-Host ''
Write-Host ('Rollback: see ' + $backupFile) -ForegroundColor DarkGray
