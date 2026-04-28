<#
.SYNOPSIS
    Top-level hardware diagnostic orchestrator. Runs all hw_*.ps1 scripts in
    sequence, then the comparator + HTML rollup.
.DESCRIPTION
    Phases:
      0 Preflight  — pcie_state, smart, whea (read-only one-shots) + audit
      1 Idle       — voltage sensors, gpu ecc, nic baseline (background polling
                     for DurationSec, then nic delta close)
      2 KillTest   — (only if -InvestigateSlowState24) kill claude.exe procs
                     with cumulative CPU > threshold, recapture per-CPU
      3 Loaded     — (only if Prime95 available + -RunLoad) Prime95 SmallFFT
                     for LoadDurationSec, with voltage + GPU pollers
      4 Aggregate  — compare_to_reference.ps1 → manifest + anomalies + HTML
.EXAMPLE
    .\run_hwdiag.ps1 -Label "hwdiag_full" -InvestigateSlowState24
.EXAMPLE
    .\run_hwdiag.ps1 -Label "preflight_only" -SkipIdle -SkipLoad
#>
#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$Label,

    [switch]$InvestigateSlowState24,
    [switch]$ExecuteKill,
    [switch]$SkipIdle,
    [switch]$SkipLoad,
    [switch]$RunLoad,

    [ValidateRange(15, 600)]
    [int]$DurationSec = 60,

    [ValidateRange(60, 1800)]
    [int]$LoadDurationSec = 300,

    [int]$KillCpuThresholdSec = 3600,

    [string]$OutputRoot = ''
)

$ErrorActionPreference = 'Continue'
$scriptRoot = $PSScriptRoot
$projectRoot = Split-Path $scriptRoot -Parent

if ($OutputRoot -eq '') {
    $OutputRoot = Join-Path $projectRoot 'captures\hwdiag'
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$runDir = Join-Path $OutputRoot ($Label + '_' + $timestamp)
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

# Phase subdirs
$preflightDir = Join-Path $runDir 'preflight'
$auditDir     = Join-Path $runDir 'audit'
$idleDir      = Join-Path $runDir 'idle'
$killDir      = Join-Path $runDir 'kill_test'
$loadedDir    = Join-Path $runDir 'loaded'
foreach ($d in @($preflightDir, $auditDir, $idleDir, $killDir, $loadedDir)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}

function Write-Phase { param([string]$Msg) Write-Host ('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Msg) -ForegroundColor Cyan }
function Write-Step { param([string]$Msg) Write-Host ('  -> ' + $Msg) -ForegroundColor Yellow }

Write-Host ''
Write-Host '=== Hardware Diagnostic Sweep ===' -ForegroundColor Cyan
Write-Host ('Label:    ' + $Label)
Write-Host ('Run dir:  ' + $runDir)
Write-Host ('Investigate 4/24: ' + $InvestigateSlowState24)
Write-Host ''

# --- Phase 0: Preflight ---
Write-Phase 'Phase 0: Preflight'

Write-Step 'PCIe link state...'
& (Join-Path $scriptRoot 'hw_pcie_state.ps1') -OutDir $preflightDir -Phase 'preflight'

Write-Step 'NVMe SMART...'
& (Join-Path $scriptRoot 'hw_storage_smart.ps1') -OutDir $preflightDir -Phase 'preflight'

Write-Step 'WHEA event log (past 7d)...'
& (Join-Path $scriptRoot 'hw_whea_summary.ps1') -OutDir $preflightDir -DaysBack 7

if ($InvestigateSlowState24) {
    Write-Step 'Claude.exe process snapshot (no kill yet, WhatIf only)...'
    & (Join-Path $scriptRoot 'hw_kill_test.ps1') -OutDir $preflightDir -WhatIf -CpuThresholdSec $KillCpuThresholdSec
}

# --- Phase 1: Audit (existing 41 checks) ---
Write-Phase 'Phase 1: Audit (41 OS/NIC/GPU/RAM/peripheral checks)'
$auditScript = Join-Path $scriptRoot 'audit.ps1'
if (Test-Path $auditScript) {
    Write-Step 'Running audit.ps1 -Mode Deep...'
    try {
        & $auditScript -Mode Deep -OutDir $auditDir -Quiet
    } catch {
        Write-Warning ('audit.ps1 failed: ' + $_.Exception.Message)
    }
} else {
    Write-Warning 'audit.ps1 not found — skipping.'
}

# --- Phase 2: Idle capture ---
if (-not $SkipIdle) {
    Write-Phase ('Phase 2: Idle capture (' + $DurationSec + 's)')

    Write-Step 'NIC baseline...'
    & (Join-Path $scriptRoot 'hw_nic_errors.ps1') -OutDir $idleDir -Mode Start -Phase 'idle'

    Write-Step ('GPU ECC + clocks + power (' + $DurationSec + 's)...')
    & (Join-Path $scriptRoot 'hw_gpu_ecc.ps1') -OutDir $idleDir -DurationSec $DurationSec -Phase 'idle'

    Write-Step ('Voltage sensors (HWiNFO64 + ACPI + nvidia-smi, ' + $DurationSec + 's)...')
    & (Join-Path $scriptRoot 'hw_voltage_sensors.ps1') -OutDir $idleDir -DurationSec $DurationSec -Phase 'idle'

    Write-Step 'NIC delta close...'
    & (Join-Path $scriptRoot 'hw_nic_errors.ps1') -OutDir $idleDir -Mode End -Phase 'idle'
} else {
    Write-Phase 'Phase 2 SKIPPED (-SkipIdle)'
}

# --- Phase 2.5: Kill test for 4/24 slow state ---
if ($InvestigateSlowState24 -and $ExecuteKill) {
    Write-Phase 'Phase 2.5: Kill test (executing)'
    & (Join-Path $scriptRoot 'hw_kill_test.ps1') -OutDir $killDir -Execute -CpuThresholdSec $KillCpuThresholdSec -PostCaptureSec 60 -SettleSec 30
} elseif ($InvestigateSlowState24) {
    Write-Phase 'Phase 2.5: Kill test (snapshot only — pass -ExecuteKill to actually terminate processes)'
    & (Join-Path $scriptRoot 'hw_kill_test.ps1') -OutDir $killDir -WhatIf -CpuThresholdSec $KillCpuThresholdSec
}

# --- Phase 3: Loaded capture (Prime95 SmallFFT + sensors) ---
$shouldLoad = $RunLoad -and -not $SkipLoad
if ($shouldLoad) {
    Write-Phase ('Phase 3: Loaded capture (Prime95 SmallFFT, ' + $LoadDurationSec + 's)')

    # Detect Prime95
    $prime95Exe = $null
    $candidates = @(
        (Join-Path $projectRoot 'p95v3019b20.win64\prime95.exe'),
        (Join-Path $projectRoot 'p95v3019b20\prime95.exe')
    )
    foreach ($c in $candidates) { if (Test-Path $c) { $prime95Exe = $c; break } }

    if (-not $prime95Exe) {
        Write-Warning 'Prime95 not found — skipping load phase.'
    } else {
        Write-Step ('Starting Prime95 SmallFFT: ' + $prime95Exe)
        $synthScript = Join-Path $scriptRoot 'synthetic_load.ps1'
        $loadConfigPath = Join-Path $loadedDir 'synthetic_load_config.json'
        if (Test-Path $synthScript) {
            try { & $synthScript -Start -OutputConfigPath $loadConfigPath -Prime95Exe $prime95Exe } catch { Write-Warning ('synthetic_load start failed: ' + $_.Exception.Message) }
        }
        Start-Sleep -Seconds 30  # stabilize

        Write-Step 'NIC baseline...'
        & (Join-Path $scriptRoot 'hw_nic_errors.ps1') -OutDir $loadedDir -Mode Start -Phase 'loaded'

        Write-Step ('GPU ECC + clocks + power (' + $LoadDurationSec + 's)...')
        & (Join-Path $scriptRoot 'hw_gpu_ecc.ps1') -OutDir $loadedDir -DurationSec $LoadDurationSec -Phase 'loaded'

        Write-Step ('Voltage sensors (' + $LoadDurationSec + 's)...')
        & (Join-Path $scriptRoot 'hw_voltage_sensors.ps1') -OutDir $loadedDir -DurationSec $LoadDurationSec -Phase 'load'

        Write-Step 'NIC delta close...'
        & (Join-Path $scriptRoot 'hw_nic_errors.ps1') -OutDir $loadedDir -Mode End -Phase 'loaded'

        if (Test-Path $synthScript) {
            try { & $synthScript -Stop } catch { Write-Warning ('synthetic_load stop failed: ' + $_.Exception.Message) }
        }
    }
} else {
    Write-Phase 'Phase 3 SKIPPED (use -RunLoad to enable)'
}

# --- Phase 4: Comparator + HTML rollup ---
Write-Phase 'Phase 4: Aggregate + comparator'
$compareScript = Join-Path $scriptRoot 'compare_to_reference.ps1'
& $compareScript -RunDir $runDir

# --- Done ---
Write-Host ''
Write-Host '=== Hardware Diagnostic Complete ===' -ForegroundColor Green
$rollup = Join-Path $runDir 'hwdiag_rollup.html'
Write-Host ('Rollup HTML: ' + $rollup) -ForegroundColor Green
Write-Host ('Manifest:    ' + (Join-Path $runDir 'manifest.json')) -ForegroundColor Green
Write-Host ('Anomalies:   ' + (Join-Path $runDir 'anomalies.json')) -ForegroundColor Green
Write-Host ''
if (Test-Path $rollup) {
    Start-Process $rollup -ErrorAction SilentlyContinue
}
