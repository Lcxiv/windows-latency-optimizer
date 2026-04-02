#Requires -RunAsAdministrator
<#
.SYNOPSIS
    EXP11: Periodic Stutter Mitigation (FSO + MPO + Hyper-V + CFG + Shader Cache)
.DESCRIPTION
    Addresses periodic ~2-second rhythmic gaming stutter identified through deep research.
    Applies multiple independent fixes targeting different root causes:

    1. Disable Fullscreen Optimizations (FSO) for Fortnite
       - KB5077181 (Build 26200.7840) introduced rhythmic stutter via FSO/DWM interaction
       - Registry: AppCompatFlags\Layers -> DISABLEDXMAXIMIZEDWINDOWEDMODE

    2. Disable Multi-Plane Overlay (MPO) — Windows 11 25H2 method
       - #1 documented cause of periodic frame-time spikes on NVIDIA
       - Registry: GraphicsDrivers\DisableOverlays = 1
       - NOTE: Old OverlayTestMode key does NOT work on 24H2/25H2

    3. Disable Hyper-V hypervisor
       - hypervisorlaunchtype=Auto adds 5-15ns latency to all operations
       - Separate from VBS/Core Isolation (already disabled)
       - bcdedit /set hypervisorlaunchtype off

    4. Disable Control Flow Guard (CFG) for Fortnite
       - Windows security feature that slows DX12 shader compilation
       - Set-ProcessMitigation -> CFG off for FortniteClient

    5. Clear shader caches (DX, NVIDIA, Fortnite pipeline)
       - Fortnite DX12 shader recompilation loop causes periodic hitches
       - Forces clean rebuild on next launch

    Research sources:
    - KB5077181 rhythmic stutter: NotebookCheck, WindowsForum (Feb 2026)
    - MPO stutter: Ordoh, SmoothFPS, NVIDIA forums (2025-2026)
    - I226-V disconnects: Intel Official, ASUS ROG, Guru3D (2023-2026)
    - RTX 5070 Ti stutter: NVIDIA GeForce Forums bug report (2026)
    - DX12 shader loop: Epic Games official, Intel Community (2025-2026)
    - 9800X3D DPC spikes: Level1Techs, Blur Busters, Tom's Hardware (2025-2026)
.NOTES
    Reboot: YES — MPO and Hyper-V changes require reboot
    Rollback: Run the rollback commands in the backup file
#>

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent

Write-Host '=== EXP11: Periodic Stutter Mitigation ===' -ForegroundColor Cyan

# --- Backup ---
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupFile = Join-Path $projectRoot ('captures\backup_pre_exp11_stutter_' + $timestamp + '.txt')
$lines = @(
    '# EXP11 Backup: Stutter mitigation pre-change state',
    ('# Captured: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
    ''
)

# Capture current state
$fortnitePath = 'C:\Program Files\Epic Games\Fortnite\FortniteGame\Binaries\Win64\FortniteClient-Win64-Shipping.exe'
$layersKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
$gfxDriversKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'

# FSO state
$lines += '# --- Fullscreen Optimizations (AppCompatFlags\Layers) ---'
$currentFSO = $null
if (Test-Path $layersKey) {
    $currentFSO = (Get-ItemProperty $layersKey -ErrorAction SilentlyContinue).$fortnitePath
}
if ($currentFSO) {
    $lines += ('# Current value: ' + $currentFSO)
    $lines += ('# Rollback: Set-ItemProperty "' + $layersKey + '" -Name "' + $fortnitePath + '" -Value "' + $currentFSO + '"')
} else {
    $lines += '# Current value: (not set)'
    $lines += ('# Rollback: Remove-ItemProperty "' + $layersKey + '" -Name "' + $fortnitePath + '" -ErrorAction SilentlyContinue')
}
$lines += ''

# MPO state
$lines += '# --- Multi-Plane Overlay (GraphicsDrivers\DisableOverlays) ---'
$currentMPO = $null
if (Test-Path $gfxDriversKey) {
    $currentMPO = (Get-ItemProperty $gfxDriversKey -ErrorAction SilentlyContinue).DisableOverlays
}
if ($null -ne $currentMPO) {
    $lines += ('# Current value: ' + $currentMPO)
    $lines += ('# Rollback: Set-ItemProperty "' + $gfxDriversKey + '" -Name "DisableOverlays" -Value ' + $currentMPO + ' -Type DWord')
} else {
    $lines += '# Current value: (not set / MPO enabled)'
    $lines += ('# Rollback: Remove-ItemProperty "' + $gfxDriversKey + '" -Name "DisableOverlays" -ErrorAction SilentlyContinue')
}
$lines += ''

# Hyper-V state
$lines += '# --- Hyper-V hypervisorlaunchtype ---'
$bcdOutput = bcdedit /enum '{current}' 2>&1 | Out-String
$hvMatch = [regex]::Match($bcdOutput, 'hypervisorlaunchtype\s+(\S+)')
if ($hvMatch.Success) {
    $currentHV = $hvMatch.Groups[1].Value
    $lines += ('# Current value: ' + $currentHV)
    $lines += ('# Rollback: bcdedit /set "{current}" hypervisorlaunchtype ' + $currentHV)
} else {
    $lines += '# Current value: (not found in bcdedit output)'
    $lines += '# Rollback: bcdedit /set "{current}" hypervisorlaunchtype Auto'
}
$lines += ''

# CFG state
$lines += '# --- Control Flow Guard for Fortnite ---'
$lines += '# Rollback: Set-ProcessMitigation -Name "' + $fortnitePath + '" -Enable CFG'
$lines += ''

$lines | Out-File -FilePath $backupFile -Encoding UTF8
Write-Host ('Backup saved: ' + $backupFile) -ForegroundColor Green

# ============================================================================
# Apply Changes
# ============================================================================

# --- 1. Disable Fullscreen Optimizations for Fortnite ---
Write-Host ''
Write-Host '[1/5] Disabling Fullscreen Optimizations for Fortnite...' -ForegroundColor Yellow

if (-not (Test-Path $layersKey)) {
    New-Item -Path $layersKey -Force | Out-Null
}
$regPath = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
reg add $regPath /v $fortnitePath /t REG_SZ /d 'DISABLEDXMAXIMIZEDWINDOWEDMODE' /f | Out-Null
Write-Host '  FSO disabled for FortniteClient-Win64-Shipping.exe' -ForegroundColor Green

# --- 2. Disable MPO (Windows 11 25H2 method) ---
Write-Host ''
Write-Host '[2/5] Disabling Multi-Plane Overlay (MPO)...' -ForegroundColor Yellow
Write-Host '  NOTE: Old OverlayTestMode key does NOT work on 24H2/25H2'

reg add 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' /v DisableOverlays /t REG_DWORD /d 1 /f | Out-Null
Write-Host '  DisableOverlays = 1 (verify with dxdiag -> Display tab)' -ForegroundColor Green

# --- 3. Disable Hyper-V hypervisor ---
Write-Host ''
Write-Host '[3/5] Disabling Hyper-V hypervisor...' -ForegroundColor Yellow
Write-Host '  WARNING: This will disable WSL2, Windows Sandbox, and Docker Hyper-V backend'

bcdedit /set '{current}' hypervisorlaunchtype off | Out-Null
Write-Host '  hypervisorlaunchtype = off' -ForegroundColor Green

# --- 4. Disable Control Flow Guard for Fortnite ---
Write-Host ''
Write-Host '[4/5] Disabling Control Flow Guard (CFG) for Fortnite...' -ForegroundColor Yellow

Set-ProcessMitigation -Name $fortnitePath -Disable CFG
Write-Host '  CFG disabled for FortniteClient-Win64-Shipping.exe' -ForegroundColor Green

# --- 5. Clear shader caches ---
Write-Host ''
Write-Host '[5/5] Clearing shader caches...' -ForegroundColor Yellow

$cacheLocations = @(
    @{ Path = (Join-Path $env:LOCALAPPDATA 'FortniteGame\Saved\PipelineCaches'); Name = 'Fortnite Pipeline' },
    @{ Path = (Join-Path $env:LOCALAPPDATA 'D3DSCache'); Name = 'Windows DX Shader' },
    @{ Path = (Join-Path $env:LOCALAPPDATA 'NVIDIA\DXCache'); Name = 'NVIDIA DX' }
)

foreach ($cache in $cacheLocations) {
    if (Test-Path $cache.Path) {
        $items = Get-ChildItem -Path $cache.Path -Recurse -ErrorAction SilentlyContinue
        $count = 0
        if ($items) { $count = $items.Count }
        Remove-Item -Path (Join-Path $cache.Path '*') -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host ('  ' + $cache.Name + ' cache cleared (' + $count + ' items)') -ForegroundColor Green
    } else {
        Write-Host ('  ' + $cache.Name + ' cache not found (skipped)') -ForegroundColor DarkGray
    }
}

# ============================================================================
# Summary
# ============================================================================
Write-Host ''
Write-Host '=== EXP11 Applied ===' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Changes applied:' -ForegroundColor White
Write-Host '  [1] FSO disabled for Fortnite (no reboot needed)'
Write-Host '  [2] MPO disabled via DisableOverlays=1 (REBOOT REQUIRED)'
Write-Host '  [3] Hyper-V hypervisor disabled (REBOOT REQUIRED)'
Write-Host '  [4] CFG disabled for Fortnite (no reboot needed)'
Write-Host '  [5] Shader caches cleared (rebuild on next game launch)'
Write-Host ''
Write-Host 'MANUAL STEPS REQUIRED:' -ForegroundColor Red
Write-Host '  [A] Enable EXPO in BIOS (RAM: 4800 -> 6000 MT/s)'
Write-Host '  [B] In Epic Launcher: Fortnite -> Options -> "Pre-download Streamed Assets"'
Write-Host '  [C] Test with USB Ethernet adapter to isolate I226-V network drops'
Write-Host '  [D] In eero app: Check for double NAT, enable "Optimize for Gaming"'
Write-Host ''
Write-Host 'REBOOT NOW to apply MPO and Hyper-V changes.' -ForegroundColor Yellow
Write-Host ''
Write-Host ('Rollback: .\rollback.ps1 -BackupFile "' + $backupFile + '"') -ForegroundColor DarkGray
