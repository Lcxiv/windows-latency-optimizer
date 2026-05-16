<#
.SYNOPSIS
    Phase 7 orchestrator — drives EAC mitigation phases in order with state tracking.
.DESCRIPTION
    Runs phases sequentially, persisting per-phase state. Each phase mutation script
    has its own apply/rollback pair; orchestrator coordinates execution + receipts.

    Default behavior: prompts before each mutation. Use -NonInteractive to drive
    from a runbook. Use -DryRun to print plan without execution.

    Phase order (v3):
      P1  -> capture pre-exclusion baseline
      P2  -> Defender exclusions apply
      P1' -> capture post-exclusion baseline
      P0  -> hypothesis gate verdict
      P3  -> gamemode quiet apply
      P4a -> launch wrapper (interactive only)
      P5  -> storage path bench (run twice with different drivers)
      P6  -> NOT YET IMPLEMENTED
      P7  -> docs, this script
      [optional] P4b, P5b — gated, NOT auto-run

.PARAMETER Phase
    Run a single phase by name. Valid: 1, 2, 1post, 0, 3, 4a, 5
    If omitted, runs the next phase from state file.

.PARAMETER NonInteractive
    Skip confirmations. Required for unattended runbook execution.

.PARAMETER DryRun
    Print phase plan; do not execute.

.PARAMETER CaptureDuration
    Seconds for Phase 1 captures. Default 300.

.PARAMETER StorageDriverLabel
    Required for Phase 5. Tag distinguishing the driver candidate (e.g. "stornvme-inbox").

.EXAMPLE
    .\eac_orchestrator.ps1 -DryRun
    .\eac_orchestrator.ps1 -Phase 1 -CaptureDuration 300
    .\eac_orchestrator.ps1 -Phase 2
    .\eac_orchestrator.ps1 -Phase 5 -StorageDriverLabel stornvme-inbox
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateSet('1', '2', '1post', '0', '3', '4a', '5', 'next')]
    [string]$Phase = 'next',

    [switch]$NonInteractive,
    [switch]$DryRun,

    [ValidateRange(60, 1800)]
    [int]$CaptureDuration = 300,

    [string]$StorageDriverLabel
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptsDir = Join-Path $repoRoot 'scripts'
$stateDir = Join-Path $repoRoot 'captures\backups\orchestrator'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$stateFile = Join-Path $stateDir 'orchestrator_state.json'

# ---- State ----
$state = $null
if (Test-Path $stateFile) {
    $state = Get-Content $stateFile -Raw | ConvertFrom-Json
} else {
    $state = [pscustomobject]@{
        startedAt   = Get-Date -Format 'o'
        completed   = @()
        last        = $null
        captures    = [pscustomobject]@{ pre = $null; post = $null }
        manifests   = [pscustomobject]@{ phase2 = $null; phase3 = $null }
    }
}

function Save-State { $state | ConvertTo-Json -Depth 10 | Out-File -FilePath $stateFile -Encoding utf8 }

function Confirm-Phase {
    param([string]$PhaseName, [string]$Action)
    if ($NonInteractive) { return $true }
    Write-Host ''
    Write-Host ('Phase ' + $PhaseName + ': ' + $Action) -ForegroundColor Yellow
    $r = Read-Host 'Proceed? (y/N)'
    return ($r -eq 'y' -or $r -eq 'Y')
}

function Get-NextPhase {
    if ($state.completed -notcontains '1') { return '1' }
    if ($state.completed -notcontains '2') { return '2' }
    if ($state.completed -notcontains '1post') { return '1post' }
    if ($state.completed -notcontains '0') { return '0' }
    if ($state.completed -notcontains '3') { return '3' }
    if ($state.completed -notcontains '4a') { return '4a' }
    if ($state.completed -notcontains '5') { return '5' }
    return $null
}

function Get-LatestCapture {
    param([string]$TagPattern)
    $base = Join-Path $repoRoot 'captures\experiments'
    Get-ChildItem -Path $base -Directory -Filter ('exp-eac-baseline-fortnite-' + $TagPattern + '*') -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Get-LatestFile {
    param([string]$Path, [string]$Pattern)
    if (-not (Test-Path $Path)) { return $null }
    Get-ChildItem -Path $Path -Filter $Pattern -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

# ---- Resolve phase ----
$resolvedPhase = $Phase
if ($Phase -eq 'next') {
    $resolvedPhase = Get-NextPhase
    if (-not $resolvedPhase) {
        Write-Host 'All phases complete.' -ForegroundColor Green
        Write-Host ('State: ' + $stateFile)
        exit 0
    }
}

Write-Host '=== EAC Orchestrator ===' -ForegroundColor Cyan
Write-Host ('Phase: ' + $resolvedPhase)
Write-Host ('State: ' + $stateFile)
Write-Host ('Completed so far: ' + ($state.completed -join ', '))
Write-Host ''

if ($DryRun) {
    Write-Host '(DryRun — would execute phase, no actions taken)' -ForegroundColor Yellow
    exit 0
}

# ---- Execute phase ----
switch ($resolvedPhase) {

    '1' {
        if (-not (Confirm-Phase '1' 'Capture pre-exclusion Fortnite baseline')) { Write-Host 'Aborted.'; exit 4 }
        & (Join-Path $scriptsDir 'eac_baseline_capture.ps1') -Tag pre-exclusion -DurationSec $CaptureDuration
        $cap = Get-LatestCapture 'pre-exclusion'
        if ($cap) {
            $state.captures.pre = $cap.FullName
            $state.completed += '1'
            $state.last = '1'
            Save-State
            Write-Host ('Phase 1 done. Capture: ' + $cap.FullName) -ForegroundColor Green
        }
    }

    '2' {
        if (-not (Confirm-Phase '2' 'Apply Defender exclusions for Fortnite + EAC paths')) { Write-Host 'Aborted.'; exit 4 }
        & (Join-Path $scriptsDir 'eac_phase2_defender_apply.ps1')
        $manifest = Get-LatestFile (Join-Path $repoRoot 'captures\backups\defender') 'apply_manifest_*.json'
        if ($manifest) {
            $state.manifests.phase2 = $manifest.FullName
            $state.completed += '2'
            $state.last = '2'
            Save-State
            Write-Host ('Phase 2 done. Manifest: ' + $manifest.FullName) -ForegroundColor Green
        }
    }

    '1post' {
        if (-not (Confirm-Phase '1post' 'Re-capture Fortnite baseline post-Defender-exclusions')) { Write-Host 'Aborted.'; exit 4 }
        & (Join-Path $scriptsDir 'eac_baseline_capture.ps1') -Tag post-exclusion -DurationSec $CaptureDuration
        $cap = Get-LatestCapture 'post-exclusion'
        if ($cap) {
            $state.captures.post = $cap.FullName
            $state.completed += '1post'
            $state.last = '1post'
            Save-State
            Write-Host ('Phase 1post done. Capture: ' + $cap.FullName) -ForegroundColor Green
        }
    }

    '0' {
        if (-not $state.captures.post) {
            Write-Error 'Phase 0 requires post-exclusion capture (run Phase 1post first).'
            exit 5
        }
        & (Join-Path $scriptsDir 'analyze_eac_dpcs.ps1') -CaptureDir $state.captures.post
        $verdictExit = $LASTEXITCODE
        $state.completed += '0'
        $state.last = '0'
        $state | Add-Member -NotePropertyName 'phase0VerdictExit' -NotePropertyValue $verdictExit -Force
        Save-State
        switch ($verdictExit) {
            0 { Write-Host 'Phase 0: PROCEED — EAC dominant. Continue plan.' -ForegroundColor Green }
            2 { Write-Host 'Phase 0: PROCEED_LOW_CONFIDENCE — partial signal. Continue cautiously.' -ForegroundColor Yellow }
            3 { Write-Host 'Phase 0: HALT_INVESTIGATE_ALTERNATE — branch to network/GPU/driver investigation.' -ForegroundColor Red; exit 3 }
            default { Write-Host ('Phase 0: unknown exit ' + $verdictExit) -ForegroundColor Yellow }
        }
    }

    '3' {
        if (-not (Confirm-Phase '3' 'Apply gamemode quiet (pause OneDrive, Steam updates, Backblaze)')) { Write-Host 'Aborted.'; exit 4 }
        & (Join-Path $scriptsDir 'eac_phase3_gamemode_quiet_apply.ps1')
        $stateF = Get-LatestFile (Join-Path $repoRoot 'captures\backups\gamemode') 'quiet_state_*.json'
        if ($stateF) {
            $state.manifests.phase3 = $stateF.FullName
            $state.completed += '3'
            $state.last = '3'
            Save-State
            Write-Host ('Phase 3 done. State: ' + $stateF.FullName) -ForegroundColor Green
        }
    }

    '4a' {
        Write-Host 'Phase 4a is interactive — launches Fortnite. Run wrapper directly:'
        Write-Host '  .\scripts\eac_phase4a_launch_fortnite_pinned.ps1'
        $state.completed += '4a'
        $state.last = '4a'
        Save-State
    }

    '5' {
        if (-not $StorageDriverLabel) {
            Write-Error 'Phase 5 requires -StorageDriverLabel <tag> (e.g. stornvme-inbox or samsung-vendor)'
            exit 5
        }
        if (-not (Confirm-Phase '5' ('Storage bench under driver tag: ' + $StorageDriverLabel))) { Write-Host 'Aborted.'; exit 4 }
        & (Join-Path $scriptsDir 'eac_phase5_storage_path_bench.ps1') -DriverLabel $StorageDriverLabel -DurationSec 60
        if ($state.completed -notcontains '5') { $state.completed += '5' }
        $state.last = '5'
        Save-State
        Write-Host 'Phase 5 done. Re-run with different driver to compare.' -ForegroundColor Green
    }

    default {
        Write-Error ('Unknown phase: ' + $resolvedPhase)
        exit 1
    }
}

Write-Host ''
Write-Host '=== Phase Complete ===' -ForegroundColor Green
$next = Get-NextPhase
if ($next) {
    Write-Host ('Next phase: ' + $next)
    Write-Host ('Run: .\scripts\eac_orchestrator.ps1 -Phase ' + $next)
} else {
    Write-Host 'Plan complete.'
}
