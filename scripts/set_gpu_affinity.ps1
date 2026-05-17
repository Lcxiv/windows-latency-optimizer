<#
.SYNOPSIS
    Set or clear interrupt affinity override for the primary NVIDIA GPU.
.DESCRIPTION
    Discovered 2026-04-23: RTX 5070 Ti (VEN_10DE&DEV_2C05) has no Affinity Policy
    registry override, causing all GPU driver (nvlddmkm.sys + dxgkrnl.sys) DPCs to
    route to CPU 0. Over a 120-second capture, this consumed 46.8% of CPU 0's time
    (56.1 seconds of DPC).

    Project topology (per CLAUDE.md): CPUs 4-7 are the GPU/NIC/USB bulk DPC group.
    Mask 0xF0 = CPUs 4-7.

    This script:
      1. Backs up the current state (registry export + JSON summary) to
         captures/backup_pre_gpu_affinity_<timestamp>.{reg,json}
      2. Writes DevicePolicy = 3 (IrqPolicySpecifiedProcessors) and
         AssignmentSetOverride = 0xF0 0x00 to the GPU device's
         Interrupt Management\Affinity Policy subkey.
      3. Requires a reboot to take effect (Windows caches MSI routing at driver
         load time).

    Use -WhatIf to preview. Use -Rollback to restore from the most recent backup.

    References:
      - Plan: C:\Users\L\.claude\plans\deep-test-report-20260423.md
      - Memory: C:\Users\L\.claude\projects\C--Users-L-Desktop-windows-latency-optimizer\memory\project_20260423_rca_gpu_affinity.md
      - Microsoft RSS with MSI-X: https://learn.microsoft.com/en-us/windows-hardware/drivers/network/rss-with-message-signaled-interrupts

.PARAMETER Mask
    Affinity mask as byte array. Default: 0xF0 0x00 (CPUs 4-7 in processor group 0).
    Other sensible values on 16-CPU systems:
      [byte[]]@(0xF0, 0x00)       # CPUs 4-7  (default — project GPU/bulk group)
      [byte[]]@(0xFF, 0x00)       # CPUs 0-7
      [byte[]]@(0x00, 0xFF)       # CPUs 8-15 (game group)

.PARAMETER GpuDeviceIdPattern
    Partial PCI device path to match. Default: 'VEN_10DE&DEV_2C05' (RTX 5070 Ti).
    If you swap GPU later, update or pass the new device ID explicitly.

.PARAMETER Rollback
    Remove the Affinity Policy subkey entirely, reverting to Windows default
    (which sends DPCs to CPU 0). Requires reboot to take effect.

.PARAMETER WhatIf
    Preview what would change without writing. Shows current registry state +
    planned writes.

.EXAMPLE
    # Apply default (CPUs 4-7)
    .\set_gpu_affinity.ps1

.EXAMPLE
    # Preview only
    .\set_gpu_affinity.ps1 -WhatIf

.EXAMPLE
    # Remove override
    .\set_gpu_affinity.ps1 -Rollback

.EXAMPLE
    # Custom mask (CPUs 8-15)
    .\set_gpu_affinity.ps1 -Mask ([byte[]]@(0x00, 0xFF))
#>
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
param(
    [byte[]]$Mask = ([byte[]]@(0xF0, 0x00)),
    [string]$GpuDeviceIdPattern = 'VEN_10DE&DEV_2C05',
    [switch]$Rollback
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
$backupDir = Join-Path $repoRoot 'captures'
if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupRegPath = Join-Path $backupDir ('backup_pre_gpu_affinity_' + $timestamp + '.reg')
$backupJsonPath = Join-Path $backupDir ('backup_pre_gpu_affinity_' + $timestamp + '.json')

# ---------------------------------------------------------------------------
# Locate the GPU device registry instance
# ---------------------------------------------------------------------------
Write-Host '=== set_gpu_affinity.ps1 ===' -ForegroundColor Cyan
Write-Host ('Searching for device matching: ' + $GpuDeviceIdPattern)

$pciRoot = 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI'
$match = Get-ChildItem $pciRoot -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match [regex]::Escape($GpuDeviceIdPattern) } | Select-Object -First 1

if (-not $match) {
    Write-Error ('No PCI device found matching pattern: ' + $GpuDeviceIdPattern + '. Enumerate with: Get-ChildItem ' + $pciRoot)
    exit 1
}

$instance = Get-ChildItem $match.PSPath -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $instance) {
    Write-Error ('PCI device key exists but has no instance subkey: ' + $match.PSPath)
    exit 1
}

$deviceParamsPath = Join-Path $instance.PSPath 'Device Parameters'
$interruptMgmtPath = Join-Path $deviceParamsPath 'Interrupt Management'
$policyKeyPath = Join-Path $interruptMgmtPath 'Affinity Policy'

Write-Host ('Device:   ' + $match.PSChildName) -ForegroundColor Green
Write-Host ('Instance: ' + $instance.PSChildName) -ForegroundColor Green
Write-Host ('Policy:   ' + $policyKeyPath)
Write-Host ''

# ---------------------------------------------------------------------------
# Read current state
# ---------------------------------------------------------------------------
$currentPolicy = $null
$currentOverride = $null
if (Test-Path $policyKeyPath) {
    $cp = Get-ItemProperty -Path $policyKeyPath -ErrorAction SilentlyContinue
    $currentPolicy = $cp.DevicePolicy
    $currentOverride = $cp.AssignmentSetOverride
}

$currentPolicyStr = '<not set>'
if ($null -ne $currentPolicy) { $currentPolicyStr = [string]$currentPolicy }
$currentOverrideStr = '<not set>'
if ($null -ne $currentOverride) { $currentOverrideStr = ($currentOverride | ForEach-Object { '0x{0:X2}' -f $_ }) -join ' ' }
Write-Host 'Current state:' -ForegroundColor Yellow
Write-Host ('  DevicePolicy:          ' + $currentPolicyStr)
Write-Host ('  AssignmentSetOverride: ' + $currentOverrideStr)
Write-Host ''

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------
if ($PSCmdlet.ShouldProcess($policyKeyPath, 'Backup current state')) {
    # reg.exe needs HKLM\... form. $policyKeyPath may be either HKLM:\... or
    # Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\... depending on
    # how we got it. Normalize both to HKLM\<path>.
    $regPathForExport = $policyKeyPath `
        -replace '^Microsoft\.PowerShell\.Core\\Registry::HKEY_LOCAL_MACHINE\\', 'HKLM\' `
        -replace '^HKLM:\\', 'HKLM\'
    if (Test-Path $policyKeyPath) {
        $null = & reg.exe export $regPathForExport $backupRegPath /y 2>&1
        Write-Host ('Backup saved: ' + $backupRegPath) -ForegroundColor Green
    } else {
        # Key does not yet exist — write a placeholder .reg that represents "no key"
        Set-Content -Path $backupRegPath -Encoding UTF8 -Value @'
Windows Registry Editor Version 5.00

; Placeholder — Affinity Policy subkey did not exist at backup time.
; Rollback path: if applied fix, run .\set_gpu_affinity.ps1 -Rollback.
'@
        Write-Host ('Backup placeholder saved (key did not exist): ' + $backupRegPath) -ForegroundColor Yellow
    }

    # JSON summary for scripting
    $summary = @{
        timestamp = $timestamp
        device = $match.PSChildName
        instance = $instance.PSChildName
        policyKeyPath = $policyKeyPath
        preApply = @{ }
        planned = @{ }
    }
    $preOverrideStr = $null
    if ($null -ne $currentOverride) { $preOverrideStr = ($currentOverride | ForEach-Object { '0x{0:X2}' -f $_ }) -join ' ' }
    $summary.preApply = @{
        DevicePolicy = $currentPolicy
        AssignmentSetOverride = $preOverrideStr
        keyExisted = (Test-Path $policyKeyPath)
    }
    if ($Rollback) {
        $summary.planned = @{ action = 'Rollback'; DevicePolicy = $null; AssignmentSetOverride = $null }
    } else {
        $plannedMaskStr = ($Mask | ForEach-Object { '0x{0:X2}' -f $_ }) -join ' '
        $summary.planned = @{ action = 'Apply'; DevicePolicy = 3; AssignmentSetOverride = $plannedMaskStr }
    }
    $summary | ConvertTo-Json -Depth 4 | Set-Content -Path $backupJsonPath -Encoding UTF8
    Write-Host ('Summary saved: ' + $backupJsonPath) -ForegroundColor Green
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Apply or rollback
# ---------------------------------------------------------------------------
if ($Rollback) {
    Write-Host 'Planned action: ROLLBACK (remove Affinity Policy subkey)' -ForegroundColor Yellow
    if (Test-Path $policyKeyPath) {
        if ($PSCmdlet.ShouldProcess($policyKeyPath, 'Remove Affinity Policy key')) {
            Remove-Item -Path $policyKeyPath -Recurse -Force
            Write-Host 'Affinity Policy key removed.' -ForegroundColor Green
        }
    } else {
        Write-Host 'Affinity Policy key did not exist; nothing to roll back.' -ForegroundColor Yellow
    }
} else {
    $maskStr = ($Mask | ForEach-Object { '0x{0:X2}' -f $_ }) -join ' '
    Write-Host ('Planned action: APPLY DevicePolicy=3, AssignmentSetOverride=' + $maskStr) -ForegroundColor Yellow
    if ($PSCmdlet.ShouldProcess($policyKeyPath, ('Apply DevicePolicy=3 + AssignmentSetOverride=' + $maskStr))) {
        # Ensure parent keys exist
        if (-not (Test-Path $deviceParamsPath)) {
            New-Item -Path $deviceParamsPath -Force | Out-Null
        }
        if (-not (Test-Path $interruptMgmtPath)) {
            New-Item -Path $interruptMgmtPath -Force | Out-Null
        }
        if (-not (Test-Path $policyKeyPath)) {
            New-Item -Path $policyKeyPath -Force | Out-Null
        }
        Set-ItemProperty -Path $policyKeyPath -Name 'DevicePolicy' -Value 3 -Type DWord
        Set-ItemProperty -Path $policyKeyPath -Name 'AssignmentSetOverride' -Value $Mask -Type Binary
        Write-Host 'Affinity Policy applied.' -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# Verify + report
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Post-operation state:' -ForegroundColor Yellow
if (Test-Path $policyKeyPath) {
    $np = Get-ItemProperty -Path $policyKeyPath -ErrorAction SilentlyContinue
    $npPolicyStr = '<not set>'
    if ($null -ne $np.DevicePolicy) { $npPolicyStr = [string]$np.DevicePolicy }
    $npOverrideStr = '<not set>'
    if ($null -ne $np.AssignmentSetOverride) { $npOverrideStr = ($np.AssignmentSetOverride | ForEach-Object { '0x{0:X2}' -f $_ }) -join ' ' }
    Write-Host ('  DevicePolicy:          ' + $npPolicyStr)
    Write-Host ('  AssignmentSetOverride: ' + $npOverrideStr)
} else {
    Write-Host '  Affinity Policy key does not exist (Windows default: DPCs route to CPU 0).'
}

Write-Host ''
Write-Host 'REBOOT REQUIRED to take effect.' -ForegroundColor Magenta
Write-Host 'After reboot, validate with:' -ForegroundColor Cyan
Write-Host '  .\pipeline.ps1 -Label GPU_AFFINITY_POST -Description "Post gpu affinity fix" -DurationSec 120 -WPRProfile InputLatency -SkipProcMon -SkipPktMon -SkipBufferbloat'
Write-Host '  .\analyze-dpc-deep.ps1 -ReportFile <latest dpcisr_report.txt>'
Write-Host 'Target: CPU 0 DPC < 5%, GPU DPCs redistribute to CPUs 4-7.'
Write-Host ''
Write-Host 'Rollback if needed:' -ForegroundColor Cyan
Write-Host '  .\set_gpu_affinity.ps1 -Rollback'
Write-Host ('  Or manually import: reg import "' + $backupRegPath + '"')
