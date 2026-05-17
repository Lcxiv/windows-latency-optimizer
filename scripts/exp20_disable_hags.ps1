#Requires -RunAsAdministrator
<#
.SYNOPSIS
    EXP20: Disable Hardware Accelerated GPU Scheduling (HAGS) to reduce nvlddmkm.sys DPC latency.
.DESCRIPTION
    HAGS offloads GPU scheduling to the GPU hardware scheduler. On some NVIDIA driver versions,
    this causes periodic DPC stalls in nvlddmkm.sys that block mouse input processing.
    Disabling HAGS returns to the traditional WDDM software scheduler.
    Requires reboot to take effect.
.EXAMPLE
    .\exp20_disable_hags.ps1
    .\exp20_disable_hags.ps1 -WhatIf
#>
param(
    [switch]$WhatIf,
    [switch]$Revert
)

$ErrorActionPreference = 'Stop'
$regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
$backupDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$backupDir = Join-Path (Split-Path $backupDir -Parent) 'captures'
$backupFile = Join-Path $backupDir ('backup_pre_exp20_hags_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt')

Write-Host ''
Write-Host '=== EXP20: HAGS (Hardware Accelerated GPU Scheduling) ===' -ForegroundColor Cyan

# Read current value
$current = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).HwSchMode
$currentDesc = switch ($current) {
    1 { 'Disabled' }
    2 { 'Enabled' }
    default { 'Unknown (' + $current + ')' }
}
Write-Host ('  Current: HwSchMode = ' + $current + ' (' + $currentDesc + ')')

if ($Revert) {
    Write-Host ''
    Write-Host '  Reverting: Setting HwSchMode = 2 (Enabled)' -ForegroundColor Yellow
    if (-not $WhatIf) {
        Set-ItemProperty -Path $regPath -Name 'HwSchMode' -Value 2 -Type DWord
        Write-Host '  Done. Reboot required.' -ForegroundColor Green
    } else {
        Write-Host '  [WhatIf] Would set HwSchMode = 2' -ForegroundColor Yellow
    }
    return
}

if ($current -eq 1) {
    Write-Host '  HAGS is already disabled — no change needed.' -ForegroundColor Green
    return
}

# Backup
Write-Host ''
Write-Host '  Backing up current value...' -ForegroundColor Yellow
$backupContent = @(
    '# EXP20 Backup — HAGS Setting'
    '# Created: ' + (Get-Date).ToString('o')
    '# Rollback: .\scripts\exp20_disable_hags.ps1 -Revert'
    ''
    '# Previous value:'
    '# HwSchMode = ' + $current + ' (' + $currentDesc + ')'
    ''
    '# To manually revert:'
    '# Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -Value 2 -Type DWord'
)
if (-not $WhatIf) {
    $backupContent | Out-File -FilePath $backupFile -Encoding UTF8
    Write-Host ('  Backup: ' + $backupFile) -ForegroundColor Green
}

# Apply
Write-Host ''
if ($WhatIf) {
    Write-Host '  [WhatIf] Would set HwSchMode = 1 (Disabled)' -ForegroundColor Yellow
} else {
    Set-ItemProperty -Path $regPath -Name 'HwSchMode' -Value 1 -Type DWord
    $verify = (Get-ItemProperty $regPath).HwSchMode
    if ($verify -eq 1) {
        Write-Host '  Applied: HwSchMode = 1 (Disabled)' -ForegroundColor Green
    } else {
        Write-Host '  ERROR: Value did not change' -ForegroundColor Red
        return
    }
}

Write-Host ''
Write-Host '  IMPORTANT: Reboot required for HAGS change to take effect.' -ForegroundColor Red
Write-Host ''
Write-Host '  After reboot, run mouse diagnostic to measure improvement:' -ForegroundColor Cyan
Write-Host '    .\scripts\diagnose-mouse.ps1 -DurationSec 10' -ForegroundColor Cyan
Write-Host ''
Write-Host '  To revert: .\scripts\exp20_disable_hags.ps1 -Revert' -ForegroundColor Yellow
Write-Host ''
