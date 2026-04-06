#Requires -RunAsAdministrator
<#
.SYNOPSIS
    EXP19: Add comprehensive Defender exclusions for gaming.
.DESCRIPTION
    Adds process and path exclusions to Windows Defender for Fortnite,
    Epic Games, EasyAntiCheat, and other game launchers/anti-cheat.
    Reduces Defender filesystem filter overhead during gameplay.
    EXP18 showed 186K Defender I/O ops in 2 minutes of Fortnite.
.NOTES
    Reboot: NOT required (takes effect immediately)
    Rollback: Run rollback.ps1 -BackupFile <backupFile>
#>

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent

Write-Host '=== EXP19: Defender Gaming Exclusions ===' -ForegroundColor Cyan
Write-Host ''

$timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupFile = Join-Path $projectRoot ('captures\backup_pre_exp19_defender_' + $timestamp + '.txt')
$lines      = @()
$lines += '# EXP19 Backup: Defender gaming exclusions pre-change state'
$lines += ('# Captured: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$lines += ''
$applied = 0

# ─── Snapshot BEFORE ────────────────────────────────────────────────────────
$existingProcs = @()
$existingPaths = @()
try {
    $mpPref = Get-MpPreference -ErrorAction Stop
    $existingProcs = @($mpPref.ExclusionProcess)
    $existingPaths = @($mpPref.ExclusionPath)
} catch {
    Write-Host 'ERROR: Cannot read Defender preferences. Is Windows Defender running?' -ForegroundColor Red
    exit 1
}

Write-Host ('Current exclusions: ' + $existingProcs.Count + ' processes, ' + $existingPaths.Count + ' paths') -ForegroundColor Gray
Write-Host ''

# ─── 1. Process exclusions ──────────────────────────────────────────────────
Write-Host '[1/2] Game process exclusions...' -ForegroundColor Yellow

$processExclusions = @(
    'FortniteClient-Win64-Shipping.exe',
    'FortniteClient-Win64-Shipping_EAC_EOS.exe',
    'EpicGamesLauncher.exe',
    'EasyAntiCheat_EOS.exe',
    'UnrealEnginePak.exe',
    'CrashReportClient.exe'
)

$lines += '=== Rollback Commands ==='

foreach ($proc in $processExclusions) {
    if ($existingProcs -contains $proc) {
        Write-Host ('  Already excluded: ' + $proc) -ForegroundColor Green
    } else {
        Add-MpPreference -ExclusionProcess $proc
        Write-Host ('  Added: ' + $proc) -ForegroundColor Green
        $lines += ('Remove-MpPreference -ExclusionProcess "' + $proc + '"')
        $applied++
    }
}

# ─── 2. Path exclusions (only if they exist on disk) ────────────────────────
Write-Host '[2/2] Game path exclusions...' -ForegroundColor Yellow

$candidatePaths = @(
    'C:\Program Files\Epic Games',
    ($env:LOCALAPPDATA + '\FortniteGame'),
    ($env:LOCALAPPDATA + '\EpicGamesLauncher'),
    'C:\Program Files (x86)\EasyAntiCheat',
    ($env:PROGRAMDATA + '\EasyAntiCheat')
)

foreach ($path in $candidatePaths) {
    if (-not (Test-Path $path)) {
        Write-Host ('  Not found, skipping: ' + $path) -ForegroundColor Gray
        continue
    }
    if ($existingPaths -contains $path) {
        Write-Host ('  Already excluded: ' + $path) -ForegroundColor Green
    } else {
        Add-MpPreference -ExclusionPath $path
        Write-Host ('  Added: ' + $path) -ForegroundColor Green
        $lines += ('Remove-MpPreference -ExclusionPath "' + $path + '"')
        $applied++
    }
}

# ─── Save backup ────────────────────────────────────────────────────────────
$lines | Out-File -FilePath $backupFile -Encoding UTF8

# ─── Snapshot AFTER ─────────────────────────────────────────────────────────
Write-Host ''
$afterPref = Get-MpPreference -ErrorAction Stop
$afterProcs = @($afterPref.ExclusionProcess)
$afterPaths = @($afterPref.ExclusionPath)

Write-Host '--- Before / After ---' -ForegroundColor Cyan
Write-Host ('  Processes: ' + $existingProcs.Count + ' -> ' + $afterProcs.Count) -ForegroundColor White
Write-Host ('  Paths:     ' + $existingPaths.Count + ' -> ' + $afterPaths.Count) -ForegroundColor White
Write-Host ''
Write-Host ('Backup:  ' + $backupFile) -ForegroundColor Green
Write-Host ('Applied: ' + $applied + ' change(s)') -ForegroundColor Cyan
Write-Host ''
Write-Host 'No reboot needed — exclusions take effect immediately.' -ForegroundColor Green
Write-Host 'Rollback: .\rollback.ps1 -BackupFile "' -NoNewline
Write-Host $backupFile -NoNewline -ForegroundColor Yellow
Write-Host '"'
