<#
.SYNOPSIS
    Kill Defender services via automated Safe Mode reboot.
.DESCRIPTION
    WdFilter.sys kernel callback blocks ALL writes to Defender service
    registry keys in Normal mode — regardless of privilege level.
    In Safe Mode, WdFilter doesn't load → registry writes succeed.

    This script:
      1. Creates a batch file that disables Defender services
      2. Registers it as a RunOnce command (runs once in Safe Mode)
      3. Creates a second RunOnce to exit Safe Mode and reboot normally
      4. Sets BCD for Safe Mode boot
      5. Reboots into Safe Mode → changes apply → auto-reboots to Normal

    Requires: Admin. The machine will reboot TWICE.
    Reversible: .\defender_safemode_kill.ps1 -Restore (also uses Safe Mode)
.PARAMETER Restore
    Restore all Defender services to default Start values via Safe Mode.
.PARAMETER Prepare
    Set up RunOnce + BCD only, don't reboot. User reboots manually.
#>
#Requires -RunAsAdministrator
param(
    [switch]$Restore,
    [switch]$Prepare
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path $MyInvocation.MyCommand.Path -Parent
$projectRoot = Split-Path $scriptRoot -Parent
$tempDir = Join-Path $projectRoot 'captures\defender_safemode'

# ── Create temp directory ───────────────────────────────────────────────────
if (-not (Test-Path $tempDir)) {
    New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
}

# ── Build the batch file ───────────────────────────────────────────────────

if ($Restore) {
    $batchName = 'defender_restore.cmd'
    $logName = 'defender_restore_log.txt'
    $label = 'RESTORE'
    # Default Start values: WinDefend=2(Auto), WdNisSvc=3(Manual), WdFilter=0(Boot), WdBoot=0(Boot)
    $commands = @(
        'reg add "HKLM\SYSTEM\CurrentControlSet\Services\WinDefend" /v Start /t REG_DWORD /d 2 /f'
        'reg add "HKLM\SYSTEM\CurrentControlSet\Services\WdNisSvc" /v Start /t REG_DWORD /d 3 /f'
        'reg add "HKLM\SYSTEM\CurrentControlSet\Services\WdFilter" /v Start /t REG_DWORD /d 0 /f'
        'reg add "HKLM\SYSTEM\CurrentControlSet\Services\WdBoot" /v Start /t REG_DWORD /d 0 /f'
    )
} else {
    $batchName = 'defender_kill.cmd'
    $logName = 'defender_kill_log.txt'
    $label = 'KILL'
    # Start=4 (Disabled) for all Defender services
    $commands = @(
        'reg add "HKLM\SYSTEM\CurrentControlSet\Services\WinDefend" /v Start /t REG_DWORD /d 4 /f'
        'reg add "HKLM\SYSTEM\CurrentControlSet\Services\WdNisSvc" /v Start /t REG_DWORD /d 4 /f'
        'reg add "HKLM\SYSTEM\CurrentControlSet\Services\WdFilter" /v Start /t REG_DWORD /d 4 /f'
        'reg add "HKLM\SYSTEM\CurrentControlSet\Services\WdBoot" /v Start /t REG_DWORD /d 4 /f'
    )
}

$batchPath = Join-Path $tempDir $batchName
$logPath = Join-Path $tempDir $logName

# Build batch content with logging
$batchLines = @()
$batchLines += '@echo off'
$batchLines += 'echo === Defender ' + $label + ' (Safe Mode) === > "' + $logPath + '"'
$batchLines += 'echo Time: %date% %time% >> "' + $logPath + '"'
$batchLines += 'echo. >> "' + $logPath + '"'

foreach ($cmd in $commands) {
    $batchLines += 'echo Running: ' + $cmd + ' >> "' + $logPath + '"'
    $batchLines += $cmd + ' >> "' + $logPath + '" 2>&1'
    $batchLines += 'echo Result: %errorlevel% >> "' + $logPath + '"'
}

# Verify the changes
$batchLines += 'echo. >> "' + $logPath + '"'
$batchLines += 'echo === Verification === >> "' + $logPath + '"'
$batchLines += 'reg query "HKLM\SYSTEM\CurrentControlSet\Services\WinDefend" /v Start >> "' + $logPath + '" 2>&1'
$batchLines += 'reg query "HKLM\SYSTEM\CurrentControlSet\Services\WdNisSvc" /v Start >> "' + $logPath + '" 2>&1'
$batchLines += 'reg query "HKLM\SYSTEM\CurrentControlSet\Services\WdFilter" /v Start >> "' + $logPath + '" 2>&1'
$batchLines += 'reg query "HKLM\SYSTEM\CurrentControlSet\Services\WdBoot" /v Start >> "' + $logPath + '" 2>&1'
$batchLines += 'echo. >> "' + $logPath + '"'
$batchLines += 'echo === Done === >> "' + $logPath + '"'

$batchContent = $batchLines -join "`r`n"
$batchContent | Out-File $batchPath -Encoding ASCII
Write-Host ('Created: ' + $batchPath) -ForegroundColor Gray

# ── Create exit-safemode batch ─────────────────────────────────────────────
$exitBatchPath = Join-Path $tempDir 'exit_safemode.cmd'
$exitLines = @(
    '@echo off'
    'bcdedit /deletevalue {current} safeboot'
    'shutdown /r /t 5 /c "LatencyGuard: Defender ' + $label + ' complete. Rebooting to Normal mode..."'
)
$exitContent = $exitLines -join "`r`n"
$exitContent | Out-File $exitBatchPath -Encoding ASCII
Write-Host ('Created: ' + $exitBatchPath) -ForegroundColor Gray

# ── Register RunOnce commands ──────────────────────────────────────────────
# RunOnce keys execute in alphabetical order, so prefix with numbers
$runOncePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'

# First: run the kill/restore batch
Set-ItemProperty $runOncePath -Name '01_DefenderModify' -Value ('cmd.exe /c "' + $batchPath + '"') -Type String
Write-Host 'RunOnce registered: 01_DefenderModify' -ForegroundColor Cyan

# Second: exit Safe Mode and reboot to Normal
Set-ItemProperty $runOncePath -Name '02_ExitSafeMode' -Value ('cmd.exe /c "' + $exitBatchPath + '"') -Type String
Write-Host 'RunOnce registered: 02_ExitSafeMode' -ForegroundColor Cyan

# ── Set BCD for Safe Mode ──────────────────────────────────────────────────
$bcdResult = & bcdedit /set '{current}' safeboot minimal 2>&1
Write-Host ('BCD safeboot: ' + $bcdResult) -ForegroundColor Cyan

# ── Summary ────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host ('=== Ready for Safe Mode ' + $label + ' ===') -ForegroundColor Yellow
Write-Host ''
Write-Host 'What will happen:' -ForegroundColor White
Write-Host '  1. Machine reboots into Safe Mode (minimal)' -ForegroundColor White
Write-Host ('  2. RunOnce runs: ' + $batchName + ' (' + $label + ' all 4 Defender services)') -ForegroundColor White
Write-Host '  3. RunOnce runs: exit_safemode.cmd (clears safeboot BCD + reboots)' -ForegroundColor White
Write-Host '  4. Machine boots normally — Defender services will NOT load' -ForegroundColor White
Write-Host ''
Write-Host ('  Log file: ' + $logPath) -ForegroundColor Gray
Write-Host ''

if ($Prepare) {
    Write-Host 'PREPARE MODE: BCD and RunOnce set. Reboot manually when ready.' -ForegroundColor Yellow
    Write-Host '  To cancel: bcdedit /deletevalue {current} safeboot' -ForegroundColor DarkCyan
    Write-Host '  Then remove RunOnce keys from: HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -ForegroundColor DarkCyan
} else {
    Write-Host 'Rebooting in 10 seconds...' -ForegroundColor Red
    Write-Host 'Press Ctrl+C to abort (then run: bcdedit /deletevalue {current} safeboot)' -ForegroundColor Yellow
    Start-Sleep -Seconds 10
    shutdown /r /t 0 /c 'LatencyGuard: Entering Safe Mode to disable Defender services'
}
