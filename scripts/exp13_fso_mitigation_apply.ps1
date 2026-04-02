#Requires -RunAsAdministrator
<#
.SYNOPSIS
    EXP13: Disable Fullscreen Optimizations (FSO) for all detected games.
.DESCRIPTION
    Scans common game installation directories for known game executables
    and applies DISABLEDXMAXIMIZEDWINDOWEDMODE to each via AppCompatFlags.
    Mitigates KB5077181/KB5079473 rhythmic stutter on Windows 11 Build 26200.
.NOTES
    Reboot: NO
    Rollback: Run rollback.ps1 -BackupFile <backupFile>
#>

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent

Write-Host '=== EXP13: FSO Mitigation for All Games ===' -ForegroundColor Cyan
Write-Host ''

# --- Game Discovery ---
$searchDirs = @(
    'C:\Program Files\Epic Games',
    'C:\Program Files (x86)\Steam\steamapps\common',
    'D:\SteamLibrary\steamapps\common',
    'E:\SteamLibrary\steamapps\common',
    'C:\Program Files\Riot Games',
    'C:\Riot Games'
)

$gameExePatterns = @(
    'FortniteClient-Win64-Shipping.exe',
    'FPSAimTrainer.exe',
    'cs2.exe',
    'VALORANT-Win64-Shipping.exe',
    'r5apex.exe',
    'OverwatchOW.exe',
    'RocketLeague.exe',
    'PUBG-Win64-Shipping.exe',
    'destiny2.exe',
    'cod.exe'
)

Write-Host 'Scanning for game executables...' -ForegroundColor Yellow
$gamePaths = @()
foreach ($dir in $searchDirs) {
    if (Test-Path $dir) {
        foreach ($exeName in $gameExePatterns) {
            $found = @(Get-ChildItem $dir -Filter $exeName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($found.Count -gt 0) {
                $gamePaths += $found[0].FullName
                Write-Host ('  Found: ' + $found[0].FullName) -ForegroundColor Green
            }
        }
    }
}

if ($gamePaths.Count -eq 0) {
    Write-Host 'No game executables found in common directories.' -ForegroundColor Yellow
    Write-Host 'Done.' -ForegroundColor Cyan
    exit 0
}

Write-Host ''
Write-Host ('Found ' + $gamePaths.Count + ' game executable(s)') -ForegroundColor Cyan

# --- Check current FSO state ---
$layersKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
if (-not (Test-Path $layersKey)) {
    New-Item -Path $layersKey -Force | Out-Null
}

$existingLayers = @{}
$layerProps = Get-ItemProperty $layersKey -ErrorAction SilentlyContinue
if ($layerProps) {
    foreach ($prop in $layerProps.PSObject.Properties) {
        if ($prop.Name -like 'PS*') { continue }  # skip PowerShell metadata
        $existingLayers[$prop.Name] = $prop.Value
    }
}

$alreadyApplied = @()
$toApply = @()
foreach ($gp in $gamePaths) {
    if ($existingLayers.ContainsKey($gp) -and $existingLayers[$gp] -eq 'DISABLEDXMAXIMIZEDWINDOWEDMODE') {
        $alreadyApplied += $gp
    } else {
        $toApply += $gp
    }
}

Write-Host ('  Already mitigated: ' + $alreadyApplied.Count)
Write-Host ('  To apply:          ' + $toApply.Count)
Write-Host ''

if ($toApply.Count -eq 0) {
    Write-Host 'All detected games already have FSO disabled.' -ForegroundColor Green
    Write-Host 'Done.' -ForegroundColor Cyan
    exit 0
}

# --- Backup ---
$timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupFile = Join-Path $projectRoot ('captures\backup_pre_exp13_fso_' + $timestamp + '.txt')

$lines = @()
$lines += '# EXP13 Backup: AppCompatFlags\Layers pre-change state'
$lines += ('# Captured: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$lines += ''
$lines += '# Current AppCompatFlags\Layers entries:'
foreach ($key in $existingLayers.Keys) {
    $lines += ('# ' + $key + ' = ' + $existingLayers[$key])
}
$lines += ''
$lines += '=== Rollback Commands ==='
$lines += '# Run these to restore previous settings:'
foreach ($gp in $toApply) {
    if ($existingLayers.ContainsKey($gp)) {
        # Restore original value
        $lines += ('Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers" -Name "' + $gp + '" -Value "' + $existingLayers[$gp] + '"')
    } else {
        # Remove the entry entirely
        $lines += ('Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers" -Name "' + $gp + '" -ErrorAction SilentlyContinue')
    }
}
$lines | Out-File -FilePath $backupFile -Encoding UTF8
Write-Host ('Backup: ' + $backupFile) -ForegroundColor Green

# --- Apply FSO disable ---
Write-Host ''
Write-Host 'Applying FSO disable...' -ForegroundColor Yellow
foreach ($gp in $toApply) {
    Set-ItemProperty -Path $layersKey -Name $gp -Value 'DISABLEDXMAXIMIZEDWINDOWEDMODE' -Type String
    Write-Host ('  Applied: ' + $gp) -ForegroundColor Green
}

# --- Verify ---
Write-Host ''
Write-Host 'Verifying...' -ForegroundColor Yellow
$verifyProps = Get-ItemProperty $layersKey -ErrorAction SilentlyContinue
$verified = 0
foreach ($gp in $toApply) {
    $val = $verifyProps.$gp
    if ($val -eq 'DISABLEDXMAXIMIZEDWINDOWEDMODE') {
        $verified++
    } else {
        Write-Host ('  FAILED to verify: ' + $gp) -ForegroundColor Red
    }
}
Write-Host ('Verified: ' + $verified + '/' + $toApply.Count) -ForegroundColor Green

Write-Host ''
Write-Host ('Done. ' + $verified + ' game(s) patched. No reboot required.') -ForegroundColor Cyan
