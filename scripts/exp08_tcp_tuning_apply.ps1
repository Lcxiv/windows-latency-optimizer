#Requires -RunAsAdministrator
<#
.SYNOPSIS
    EXP08: TCP Stack Low-Latency Tuning
.DESCRIPTION
    Applies TCP global parameter changes for lower network latency:
    - Auto-Tuning Level = restricted (prevents dynamic receive window jitter)
    - RFC 1323 Timestamps = disabled (removes 12 bytes/packet overhead)
    - Receive Segment Coalescing = disabled (prevents packet batching latency)
    - Initial RTO = 300ms (faster retransmit on first SYN, default 1000ms)
.NOTES
    Reboot: NO — changes take effect immediately
    Rollback: Run the rollback commands printed at the end
#>

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent

Write-Host '=== EXP08: TCP Stack Low-Latency Tuning ===' -ForegroundColor Cyan

# --- Backup ---
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupFile = Join-Path $projectRoot ('captures\backup_pre_exp08_tcp_' + $timestamp + '.txt')
$lines = @(
    '# EXP08 Backup: TCP global parameters pre-change state',
    ('# Captured: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
    '',
    '# Current TCP global settings:'
)
$lines += (netsh int tcp show global 2>&1)
$lines += ''
$lines += '=== Rollback Commands ==='
$lines += '# Run these to restore previous settings:'
$lines += 'netsh int tcp set global autotuninglevel=normal'
$lines += 'netsh int tcp set global timestamps=allowed'
$lines += 'netsh int tcp set global rsc=enabled'
$lines += 'netsh int tcp set global initialRto=1000'
$lines | Set-Content $backupFile
Write-Host ('Backup saved: ' + $backupFile)

# --- Apply ---
Write-Host ''
Write-Host 'Applying TCP tuning...' -ForegroundColor Yellow

Write-Host '  [1/4] Auto-Tuning Level = restricted'
netsh int tcp set global autotuninglevel=restricted | Out-Null

Write-Host '  [2/4] Timestamps = disabled'
netsh int tcp set global timestamps=disabled | Out-Null

Write-Host '  [3/4] Receive Segment Coalescing = disabled'
netsh int tcp set global rsc=disabled | Out-Null

Write-Host '  [4/4] Initial RTO = 300ms'
netsh int tcp set global initialRto=300 | Out-Null

# --- Verify ---
Write-Host ''
Write-Host 'Verifying TCP settings:' -ForegroundColor Cyan
$tcp = netsh int tcp show global 2>&1
$errors = 0

$autoTune = ($tcp | Select-String 'Auto-Tuning').ToString()
if ($autoTune -match 'restricted') {
    Write-Host ('  PASS: ' + $autoTune.Trim()) -ForegroundColor Green
} else {
    Write-Host ('  FAIL: ' + $autoTune.Trim()) -ForegroundColor Red
    $errors++
}

$ts = ($tcp | Select-String 'Timestamps').ToString()
if ($ts -match 'disabled') {
    Write-Host ('  PASS: ' + $ts.Trim()) -ForegroundColor Green
} else {
    Write-Host ('  FAIL: ' + $ts.Trim()) -ForegroundColor Red
    $errors++
}

$rsc = ($tcp | Select-String 'Receive Segment Coalescing').ToString()
if ($rsc -match 'disabled') {
    Write-Host ('  PASS: ' + $rsc.Trim()) -ForegroundColor Green
} else {
    Write-Host ('  FAIL: ' + $rsc.Trim()) -ForegroundColor Red
    $errors++
}

$rto = ($tcp | Select-String 'Initial RTO').ToString()
if ($rto -match '300') {
    Write-Host ('  PASS: ' + $rto.Trim()) -ForegroundColor Green
} else {
    Write-Host ('  FAIL: ' + $rto.Trim()) -ForegroundColor Red
    $errors++
}

if ($errors -eq 0) {
    Write-Host ''
    Write-Host 'All 4 TCP settings applied successfully.' -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host ($errors.ToString() + ' setting(s) failed to apply.') -ForegroundColor Red
}

# --- Next Steps ---
Write-Host ''
Write-Host 'Run capture:' -ForegroundColor Yellow
Write-Host ('  cd ' + $projectRoot)
Write-Host '  .\scripts\pipeline.ps1 -Label "EXP08_TCP_TUNING" -Description "TCP auto-tuning restricted, timestamps disabled, RSC disabled, InitialRTO=300" -DurationSec 120 -SkipPresentMon -SkipWPR'
Write-Host ''
Write-Host 'Rollback:' -ForegroundColor Red
Write-Host '  netsh int tcp set global autotuninglevel=normal'
Write-Host '  netsh int tcp set global timestamps=allowed'
Write-Host '  netsh int tcp set global rsc=enabled'
Write-Host '  netsh int tcp set global initialRto=1000'
