#Requires -RunAsAdministrator
<#
.SYNOPSIS
    EXP15: Apply deep latency mitigations from research findings.
.DESCRIPTION
    Disables unnecessary ETW autologgers (LwtNetLog, DiagTrack),
    adds Defender exclusions for game processes and shader caches,
    sets NVIDIA GPU power management to max performance.
    All changes are backed up with rollback commands.
.NOTES
    Reboot: RECOMMENDED (autologger changes take effect on next boot)
    Rollback: Run rollback.ps1 -BackupFile <backupFile>
#>

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent

Write-Host '=== EXP15: Deep Latency Mitigations ===' -ForegroundColor Cyan
Write-Host ''

$timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupFile = Join-Path $projectRoot ('captures\backup_pre_exp15_latency_' + $timestamp + '.txt')
$lines      = @()
$lines += '# EXP15 Backup: Deep latency mitigations pre-change state'
$lines += ('# Captured: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$lines += ''
$applied = 0

# ─── 1. Disable LwtNetLog autologger ─────────────────────────────────────────
Write-Host '[1/4] LwtNetLog autologger...' -ForegroundColor Yellow
$lwtKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\LwtNetLog'
if (Test-Path $lwtKey) {
    $lwtCurrent = (Get-ItemProperty $lwtKey -ErrorAction SilentlyContinue).Start
    $lines += ('# LwtNetLog Start was: ' + $lwtCurrent)
    $lines += ''
    $lines += '=== Rollback Commands ==='
    $lines += ('Set-ItemProperty -Path "' + $lwtKey + '" -Name Start -Value ' + $lwtCurrent + ' -Type DWord')
    if ($lwtCurrent -ne 0) {
        Set-ItemProperty -Path $lwtKey -Name Start -Value 0 -Type DWord
        Write-Host '  Disabled LwtNetLog (was Start=' + $lwtCurrent + ')' -ForegroundColor Green
        $applied++
    } else {
        Write-Host '  Already disabled' -ForegroundColor Green
    }
} else {
    Write-Host '  Key not found — skipping' -ForegroundColor Yellow
}

# ─── 2. Disable DiagTrack-Listener autologger ────────────────────────────────
Write-Host '[2/4] DiagTrack-Listener autologger...' -ForegroundColor Yellow
$diagKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\Diagtrack-Listener'
if (Test-Path $diagKey) {
    $diagCurrent = (Get-ItemProperty $diagKey -ErrorAction SilentlyContinue).Start
    $lines += ('# DiagTrack-Listener Start was: ' + $diagCurrent)
    $lines += ('Set-ItemProperty -Path "' + $diagKey + '" -Name Start -Value ' + $diagCurrent + ' -Type DWord')
    if ($diagCurrent -ne 0) {
        Set-ItemProperty -Path $diagKey -Name Start -Value 0 -Type DWord
        Write-Host ('  Disabled DiagTrack-Listener (was Start=' + $diagCurrent + ')') -ForegroundColor Green
        $applied++
    } else {
        Write-Host '  Already disabled' -ForegroundColor Green
    }
} else {
    Write-Host '  Key not found — skipping' -ForegroundColor Yellow
}

# ─── 3. Defender exclusions ──────────────────────────────────────────────────
Write-Host '[3/4] Defender exclusions...' -ForegroundColor Yellow

# Process exclusions
$processExclusions = @('FPSAimTrainer.exe', 'cs2.exe', 'r5apex.exe', 'OverwatchOW.exe', 'RocketLeague.exe', 'dwm.exe')
$existingProcs = @()
try { $existingProcs = @((Get-MpPreference -ErrorAction Stop).ExclusionProcess) } catch {}

foreach ($proc in $processExclusions) {
    if ($existingProcs -contains $proc) {
        Write-Host ('  Process already excluded: ' + $proc) -ForegroundColor Green
    } else {
        Add-MpPreference -ExclusionProcess $proc
        Write-Host ('  Added process exclusion: ' + $proc) -ForegroundColor Green
        $lines += ('Remove-MpPreference -ExclusionProcess "' + $proc + '"')
        $applied++
    }
}

# Path exclusions (shader caches + Steam)
$pathExclusions = @(
    ($env:LOCALAPPDATA + '\NVIDIA\DXCache'),
    ($env:LOCALAPPDATA + '\D3DSCache'),
    'C:\Program Files (x86)\Steam\steamapps\common'
)
$existingPaths = @()
try { $existingPaths = @((Get-MpPreference -ErrorAction Stop).ExclusionPath) } catch {}

foreach ($path in $pathExclusions) {
    if ($existingPaths -contains $path) {
        Write-Host ('  Path already excluded: ' + $path) -ForegroundColor Green
    } else {
        Add-MpPreference -ExclusionPath $path
        Write-Host ('  Added path exclusion: ' + $path) -ForegroundColor Green
        $lines += ('Remove-MpPreference -ExclusionPath "' + $path + '"')
        $applied++
    }
}

# ─── 4. NVIDIA Power Management ─────────────────────────────────────────────
Write-Host '[4/4] NVIDIA power management...' -ForegroundColor Yellow
$nvClasses = @(
    'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000',
    'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0001'
)
$nvApplied = $false
foreach ($nvKey in $nvClasses) {
    if (-not (Test-Path $nvKey)) { continue }
    $desc = (Get-ItemProperty $nvKey -ErrorAction SilentlyContinue).DriverDesc
    if ($null -eq $desc -or $desc -notmatch 'NVIDIA') { continue }
    $currentPerfLevel = (Get-ItemProperty $nvKey -ErrorAction SilentlyContinue).PerfLevelSrc
    $lines += ('# NVIDIA PerfLevelSrc was: ' + $currentPerfLevel + ' at ' + $nvKey)
    if ($null -ne $currentPerfLevel) {
        $lines += ('Set-ItemProperty -Path "' + $nvKey + '" -Name PerfLevelSrc -Value ' + $currentPerfLevel + ' -Type DWord')
    } else {
        $lines += ('Remove-ItemProperty -Path "' + $nvKey + '" -Name PerfLevelSrc -ErrorAction SilentlyContinue')
    }
    Set-ItemProperty -Path $nvKey -Name PerfLevelSrc -Value 0x2222 -Type DWord
    Write-Host ('  Set PerfLevelSrc=0x2222 at ' + $nvKey) -ForegroundColor Green
    $nvApplied = $true
    $applied++
    break
}
if (-not $nvApplied) {
    Write-Host '  NVIDIA adapter key not found — skipping' -ForegroundColor Yellow
}

# ─── Save backup ─────────────────────────────────────────────────────────────
$lines | Out-File -FilePath $backupFile -Encoding UTF8
Write-Host ''
Write-Host ('Backup: ' + $backupFile) -ForegroundColor Green
Write-Host ('Applied: ' + $applied + ' change(s)') -ForegroundColor Cyan
Write-Host ''
Write-Host 'Reboot recommended for autologger changes to take effect.' -ForegroundColor Yellow
Write-Host 'Done.' -ForegroundColor Cyan
