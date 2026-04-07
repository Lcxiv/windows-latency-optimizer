#Requires -RunAsAdministrator
<#
.SYNOPSIS
    EXP21: Re-enable MSI interrupts for GPU + lock GPU clocks to reduce DPC latency.
.DESCRIPTION
    NVIDIA driver updates silently reset MSISupported to 0, forcing shared IRQ line-based
    interrupts. Shared lines add latency (CPU polls "was this mine?") to every GPU interrupt.
    MSI uses dedicated interrupt vectors — no sharing, no polling overhead.
    GPU clock locking prevents P-state transition DPCs that stall input processing.
    MSI change requires reboot. Clock lock is immediate but resets on reboot/driver restart.
.EXAMPLE
    .\exp21_msi_gpu_clocks.ps1
    .\exp21_msi_gpu_clocks.ps1 -WhatIf
    .\exp21_msi_gpu_clocks.ps1 -Revert
#>
param(
    [switch]$WhatIf,
    [switch]$Revert
)

$ErrorActionPreference = 'Stop'
$backupDir = Join-Path (Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent) 'captures'
$backupFile = Join-Path $backupDir ('backup_pre_exp21_msi_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt')

Write-Host ''
Write-Host '=== EXP21: GPU MSI Interrupts + Clock Lock ===' -ForegroundColor Cyan

# --- Find GPU PCI device ---
$gpuPciKey = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -like '*VEN_10DE*' } | Select-Object -First 1
if (-not $gpuPciKey) {
    Write-Host '  ERROR: No NVIDIA GPU found in PCI registry' -ForegroundColor Red
    return
}
$gpuInstKey = Get-ChildItem $gpuPciKey.PSPath | Select-Object -First 1
$msiPath = Join-Path $gpuInstKey.PSPath 'Device Parameters\Interrupt Management\MessageSignaledInterruptProperties'

# Read current MSI state
$currentMSI = 0
if (Test-Path $msiPath) {
    $currentMSI = (Get-ItemProperty $msiPath -ErrorAction SilentlyContinue).MSISupported
}
$msiDesc = if ($currentMSI -eq 1) { 'Enabled' } else { 'Disabled' }
Write-Host ('  GPU: ' + $gpuPciKey.PSChildName)
Write-Host ('  MSI: ' + $currentMSI + ' (' + $msiDesc + ')')

# --- Revert ---
if ($Revert) {
    Write-Host ''
    Write-Host '  Reverting MSI to disabled (0)...' -ForegroundColor Yellow
    if (-not $WhatIf) {
        Set-ItemProperty -Path $msiPath -Name 'MSISupported' -Value 0 -Type DWord
        Write-Host '  MSI reverted to 0. Reboot required.' -ForegroundColor Green
        # Unlock clocks
        $nvsmi = 'C:\Windows\System32\nvidia-smi.exe'
        if (Test-Path $nvsmi) {
            & $nvsmi -rgc 2>&1 | Out-Null
            & $nvsmi -rmc 2>&1 | Out-Null
            Write-Host '  GPU clocks unlocked.' -ForegroundColor Green
        }
    } else {
        Write-Host '  [WhatIf] Would set MSISupported = 0 and unlock clocks' -ForegroundColor Yellow
    }
    return
}

if ($currentMSI -eq 1) {
    Write-Host '  MSI already enabled — skipping registry change.' -ForegroundColor Green
} else {
    # Backup
    Write-Host ''
    Write-Host '  Backing up current values...' -ForegroundColor Yellow
    $backupContent = @(
        '# EXP21 Backup — GPU MSI + Clock Lock'
        '# Created: ' + (Get-Date).ToString('o')
        '# Rollback: .\scripts\exp21_msi_gpu_clocks.ps1 -Revert'
        ''
        '# MSI was: ' + $currentMSI + ' (' + $msiDesc + ')'
        '# Registry: ' + $msiPath.Replace('Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE','HKLM:')
        ''
        '# Manual revert:'
        '# Set-ItemProperty -Path "' + $msiPath.Replace('Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE','HKLM:') + '" -Name MSISupported -Value 0 -Type DWord'
        '# nvidia-smi -rgc   # unlock core clocks'
        '# nvidia-smi -rmc   # unlock memory clocks'
    )
    if (-not $WhatIf) {
        $backupContent | Out-File -FilePath $backupFile -Encoding UTF8
        Write-Host ('  Backup: ' + $backupFile) -ForegroundColor Green
    }

    # Apply MSI
    Write-Host ''
    if ($WhatIf) {
        Write-Host '  [WhatIf] Would set MSISupported = 1' -ForegroundColor Yellow
    } else {
        Set-ItemProperty -Path $msiPath -Name 'MSISupported' -Value 1 -Type DWord
        $verify = (Get-ItemProperty $msiPath).MSISupported
        if ($verify -eq 1) {
            Write-Host '  Applied: MSISupported = 1 (Enabled)' -ForegroundColor Green
        } else {
            Write-Host '  ERROR: MSI value did not change' -ForegroundColor Red
        }
    }
}

# --- GPU Clock Lock ---
Write-Host ''
Write-Host '  Locking GPU clocks...' -ForegroundColor Yellow
$nvsmi = 'C:\Windows\System32\nvidia-smi.exe'
if (Test-Path $nvsmi) {
    if ($WhatIf) {
        Write-Host '  [WhatIf] Would run: nvidia-smi -lgc 2820,2820' -ForegroundColor Yellow
    } else {
        $lockResult = & $nvsmi -lgc 2820,2820 2>&1
        Write-Host ('  Core clock: ' + $lockResult) -ForegroundColor Green
        $memResult = & $nvsmi -lmc 14001,14001 2>&1
        Write-Host ('  Memory clock: ' + $memResult) -ForegroundColor Green
    }
} else {
    Write-Host '  nvidia-smi not found — skip clock lock' -ForegroundColor Yellow
}

Write-Host ''
if ($currentMSI -ne 1) {
    Write-Host '  IMPORTANT: Reboot required for MSI change.' -ForegroundColor Red
}
Write-Host '  GPU clock lock is immediate but resets on reboot.' -ForegroundColor Yellow
Write-Host '  After reboot, re-run clock lock and mouse diagnostic:' -ForegroundColor Cyan
Write-Host '    nvidia-smi -lgc 2820,2820' -ForegroundColor Cyan
Write-Host '    .\scripts\diagnose-mouse.ps1 -DurationSec 10' -ForegroundColor Cyan
Write-Host ''
Write-Host '  To revert: .\scripts\exp21_msi_gpu_clocks.ps1 -Revert' -ForegroundColor Yellow
Write-Host ''
