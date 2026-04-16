<#
.SYNOPSIS
    Fully disable NIC power management for low-latency audio/gaming.

.DESCRIPTION
    Two-pronged fix because Windows exposes these settings in different ways:
      1. Set-NetAdapterPowerManagement -SelectiveSuspend Disabled  (cmdlet-managed)
      2. PnPCapabilities = 0x18 in driver class registry key
         (controls "Allow computer to turn off this device" Device Manager checkbox)

    Backs up previous state to captures/.
    Requires reboot or driver re-init for PnPCapabilities to take effect.
#>
[CmdletBinding()]
param(
    [string]$NicMatch = 'I226'
)

$ErrorActionPreference = 'Stop'
$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
$repoRoot = Split-Path $PSScriptRoot -Parent
$backupFile = Join-Path $repoRoot ('captures\backup_nic_pnp_' + $ts + '.txt')
New-Item -ItemType Directory -Path (Split-Path $backupFile -Parent) -Force | Out-Null

# Admin check
$current = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '[FATAL] Run as Administrator' -ForegroundColor Red; exit 1
}

Write-Host '=== NIC Power Management Fix ===' -ForegroundColor Cyan
$nic = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match $NicMatch -and $_.Status -eq 'Up' } | Select-Object -First 1
if (-not $nic) {
    Write-Host ('[FAIL] No NIC matching "' + $NicMatch + '" found') -ForegroundColor Red; exit 1
}
Write-Host ('NIC: ' + $nic.InterfaceDescription + ' (' + $nic.Name + ')') -ForegroundColor Yellow

# Get the PnP instance ID (not the interface GUID) and find the driver class subkey
# Get-NetAdapter.DeviceID is the interface GUID; PnpDeviceID is on Win32_NetworkAdapter
$wmi = Get-CimInstance -ClassName Win32_NetworkAdapter -Filter ('Name = "' + $nic.InterfaceDescription + '"') -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $wmi -or -not $wmi.PNPDeviceID) {
    Write-Host '[FAIL] Could not resolve PNPDeviceID for NIC' -ForegroundColor Red; exit 1
}
$instanceId = $wmi.PNPDeviceID  # e.g., PCI\VEN_8086&DEV_125C&SUBSYS...\...
$enumKey = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $instanceId
$driverSub = (Get-ItemProperty -Path $enumKey -Name 'Driver' -ErrorAction Stop).Driver
$driverKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\' + $driverSub
Write-Host ('Driver class key: ' + $driverKey) -ForegroundColor Gray

if (-not (Test-Path $driverKey)) {
    Write-Host '[FAIL] Driver class key does not exist' -ForegroundColor Red; exit 1
}

# Read current state for backup
$prevPnP = (Get-ItemProperty -Path $driverKey -Name 'PnPCapabilities' -ErrorAction SilentlyContinue).PnPCapabilities
$prevDriverDesc = (Get-ItemProperty -Path $driverKey -Name 'DriverDesc' -ErrorAction SilentlyContinue).DriverDesc
Write-Host ('DriverDesc: ' + $prevDriverDesc)
$prevPnPStr = if ($null -eq $prevPnP) { 'null (not set)' } else { '0x' + [Convert]::ToString($prevPnP,16).PadLeft(2,'0') }
Write-Host ('Current PnPCapabilities: ' + $prevPnPStr)

$pmBefore = Get-NetAdapterPowerManagement -Name $nic.Name
Write-Host ('Current SelectiveSuspend: ' + $pmBefore.SelectiveSuspend)

# Backup
@"
# NIC Power Management Backup
# Timestamp: $ts
# NIC: $($nic.InterfaceDescription) ($($nic.Name))
# Driver key: $driverKey
# Previous PnPCapabilities: $prevPnPStr
# Previous SelectiveSuspend: $($pmBefore.SelectiveSuspend)

# To rollback:
#   Set-NetAdapterPowerManagement -Name '$($nic.Name)' -SelectiveSuspend $($pmBefore.SelectiveSuspend)
"@ + $(if ($null -eq $prevPnP) {
"
#   Remove-ItemProperty -Path '$driverKey' -Name PnPCapabilities -ErrorAction SilentlyContinue
"
} else {
"
#   Set-ItemProperty -Path '$driverKey' -Name PnPCapabilities -Value $prevPnP -Type DWord
"
}) | Set-Content -Path $backupFile -Encoding UTF8

Write-Host ''
Write-Host 'Applying fixes...' -ForegroundColor Cyan

# Fix A: Cmdlet-based SelectiveSuspend
try {
    Set-NetAdapterPowerManagement -Name $nic.Name -SelectiveSuspend Disabled -Confirm:$false -ErrorAction Stop
    Write-Host '[OK] SelectiveSuspend=Disabled (cmdlet)' -ForegroundColor Green
} catch {
    Write-Host ('[FAIL] SelectiveSuspend: ' + $_.Exception.Message) -ForegroundColor Red
}

# Fix B: Registry PnPCapabilities = 0x18
# Bit 0x08 = "no wake from device"; bit 0x10 = "no power-off"
# Combined 0x18 = fully disable "Allow computer to turn off"
try {
    Set-ItemProperty -Path $driverKey -Name 'PnPCapabilities' -Value 0x18 -Type DWord
    Write-Host '[OK] PnPCapabilities=0x18 written (no power-off, no wake-from-device)' -ForegroundColor Green
} catch {
    Write-Host ('[FAIL] PnPCapabilities: ' + $_.Exception.Message) -ForegroundColor Red
}

Write-Host ''
Write-Host 'Verifying...' -ForegroundColor Cyan
$pmAfter = Get-NetAdapterPowerManagement -Name $nic.Name
Write-Host ('SelectiveSuspend: ' + $pmAfter.SelectiveSuspend)
$newPnP = (Get-ItemProperty -Path $driverKey -Name 'PnPCapabilities' -ErrorAction SilentlyContinue).PnPCapabilities
Write-Host ('PnPCapabilities: 0x' + [Convert]::ToString($newPnP,16).PadLeft(2,'0'))

Write-Host ''
Write-Host ('Backup: ' + $backupFile) -ForegroundColor Cyan
Write-Host 'Note: PnPCapabilities takes effect after reboot or NIC restart.' -ForegroundColor Yellow
