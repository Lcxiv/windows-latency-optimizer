#Requires -RunAsAdministrator
<#
.SYNOPSIS
    EXP21: Lock GPU clocks to reduce P-state transition DPC latency.
.DESCRIPTION
    GPU clock locking prevents P-state transition DPCs that stall input processing.
    Clock lock is immediate but resets on reboot/driver restart.

    NOTE: MSI interrupts are now managed by fix_gpu_affinity.ps1 -Apply.
    This script only handles GPU clock locking.
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
$backupFile = Join-Path $backupDir ('backup_pre_exp21_clocks_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt')

Write-Host ''
Write-Host '=== EXP21: GPU Clock Lock ===' -ForegroundColor Cyan

# --- Check MSI status (informational only) ---
$gpuPciKey = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -like '*VEN_10DE*' } | Select-Object -First 1
if ($gpuPciKey) {
    $gpuInstKey = Get-ChildItem $gpuPciKey.PSPath | Select-Object -First 1
    $msiPath = Join-Path $gpuInstKey.PSPath 'Device Parameters\Interrupt Management\MessageSignaledInterruptProperties'
    $currentMSI = 0
    if (Test-Path $msiPath) {
        $currentMSI = (Get-ItemProperty $msiPath -ErrorAction SilentlyContinue).MSISupported
    }
    $msiStatus = 'Enabled'
    if ($currentMSI -ne 1) { $msiStatus = 'DISABLED - run fix_gpu_affinity.ps1 -Apply to enable' }
    Write-Host ('  GPU: ' + $gpuPciKey.PSChildName)
    Write-Host ('  MSI: ' + $msiStatus)
} else {
    Write-Host '  ERROR: No NVIDIA GPU found in PCI registry' -ForegroundColor Red
    return
}

# --- Revert ---
if ($Revert) {
    Write-Host ''
    Write-Host '  Unlocking GPU clocks...' -ForegroundColor Yellow
    if (-not $WhatIf) {
        $nvsmi = 'C:\Windows\System32\nvidia-smi.exe'
        if (Test-Path $nvsmi) {
            & $nvsmi -rgc 2>&1 | Out-Null
            & $nvsmi -rmc 2>&1 | Out-Null
            Write-Host '  GPU clocks unlocked.' -ForegroundColor Green
        }
    } else {
        Write-Host '  [WhatIf] Would unlock GPU core and memory clocks' -ForegroundColor Yellow
    }
    return
}

# --- Backup ---
$backupContent = @(
    '# EXP21 Backup - GPU Clock Lock',
    ('# Created: ' + (Get-Date).ToString('o')),
    '# Rollback: .\scripts\exp21_msi_gpu_clocks.ps1 -Revert',
    '',
    '# Manual revert:',
    '# nvidia-smi -rgc   # unlock core clocks',
    '# nvidia-smi -rmc   # unlock memory clocks'
)
if (-not $WhatIf) {
    $backupContent | Out-File -FilePath $backupFile -Encoding UTF8
    Write-Host ('  Backup: ' + $backupFile) -ForegroundColor Green
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
Write-Host '  GPU clock lock is immediate but resets on reboot.' -ForegroundColor Yellow
Write-Host '  After reboot, re-run clock lock:' -ForegroundColor Cyan
Write-Host '    nvidia-smi -lgc 2820,2820' -ForegroundColor Cyan
Write-Host ''
Write-Host '  To revert: .\scripts\exp21_msi_gpu_clocks.ps1 -Revert' -ForegroundColor Yellow
Write-Host '  For MSI/affinity: .\scripts\fix_gpu_affinity.ps1 -Apply' -ForegroundColor DarkGray
Write-Host ''
