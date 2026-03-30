#Requires -RunAsAdministrator
<#
.SYNOPSIS
    EXP09: Disable HPET Sync (bcdedit)
.DESCRIPTION
    Removes useplatformclock from BCD, forcing standalone TSC.
    The 9800X3D has invariant TSC (zero-latency on-die read vs HPET PCIe round-trip).
.NOTES
    Reboot: YES — changes take effect after restart
    Rollback: bcdedit /set useplatformclock true
#>

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent

Write-Host '=== EXP09: Disable HPET Sync ===' -ForegroundColor Cyan

# --- Backup ---
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupFile = Join-Path $projectRoot "captures\backup_pre_exp09_hpet_$timestamp.txt"
$lines = @(
    "# EXP09 Backup: HPET/BCD pre-change state",
    "# Captured: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "",
    "# Current BCD configuration:"
)
$lines += (bcdedit /enum '{current}' 2>&1)
$lines += ""
$lines += "# Rollback command:"
$lines += "# bcdedit /set useplatformclock true"
$lines | Set-Content $backupFile
Write-Host "Backup saved: $backupFile"

# --- Apply ---
Write-Host ''
Write-Host 'Applying: bcdedit /deletevalue useplatformclock' -ForegroundColor Yellow
$result = bcdedit /deletevalue useplatformclock 2>&1
Write-Host "Result: $result"

# --- Verify ---
Write-Host ''
Write-Host 'Verifying BCD (useplatformclock should be absent):' -ForegroundColor Cyan
$bcd = (bcdedit /enum '{current}' 2>&1) -join "`n"
if ($bcd -match 'useplatformclock') {
    Write-Host 'WARNING: useplatformclock still present' -ForegroundColor Red
} else {
    Write-Host 'PASS: useplatformclock removed from BCD' -ForegroundColor Green
}

# --- Reboot Notice ---
Write-Host ''
Write-Host '*** REBOOT REQUIRED ***' -ForegroundColor Red
Write-Host 'After reboot, run:' -ForegroundColor Yellow
Write-Host "  cd $projectRoot"
Write-Host '  .\scripts\pipeline.ps1 -Label "EXP09_HPET_DISABLED" -Description "useplatformclock removed, standalone TSC" -DurationSec 120 -SkipPresentMon -SkipWPR'
Write-Host ''
Write-Host 'Rollback: bcdedit /set useplatformclock true' -ForegroundColor Red
