#Requires -RunAsAdministrator
<#
.SYNOPSIS
    EXP10: Disable Memory Compression
.DESCRIPTION
    Disables Windows memory compression. Decompression creates CPU DPCs.
    Marginal impact on 32GB systems (compression rarely activates).
.NOTES
    Reboot: YES — changes take effect after restart
    Rollback: Enable-MMAgent -MemoryCompression
#>

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent

Write-Host '=== EXP10: Disable Memory Compression ===' -ForegroundColor Cyan

# --- Backup ---
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupFile = Join-Path $projectRoot "captures\backup_pre_exp10_memcompression_$timestamp.txt"
$current = Get-MMAgent
$lines = @(
    "# EXP10 Backup: Memory Compression pre-change state",
    "# Captured: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "",
    "# Current state:",
    "MemoryCompression: $($current.MemoryCompression)",
    "MaxOperationAPIFiles: $($current.MaxOperationAPIFiles)",
    "OperationAPI: $($current.OperationAPI)",
    "",
    "# Rollback command:",
    "# Enable-MMAgent -MemoryCompression"
)
$lines | Set-Content $backupFile
Write-Host "Backup saved: $backupFile"

# --- Apply ---
Write-Host ''
Write-Host 'Applying: Disable-MMAgent -MemoryCompression' -ForegroundColor Yellow
Disable-MMAgent -MemoryCompression
Write-Host 'Done'

# --- Verify ---
Write-Host ''
$after = Get-MMAgent
Write-Host "MemoryCompression: $($after.MemoryCompression)"
if (-not $after.MemoryCompression) {
    Write-Host 'PASS: Memory compression disabled' -ForegroundColor Green
} else {
    Write-Host 'WARNING: Memory compression still enabled' -ForegroundColor Red
}

# --- Reboot Notice ---
Write-Host ''
Write-Host '*** REBOOT REQUIRED ***' -ForegroundColor Red
Write-Host 'After reboot, run:' -ForegroundColor Yellow
Write-Host "  cd $projectRoot"
Write-Host '  .\scripts\pipeline.ps1 -Label "EXP10_MEMCOMPRESSION_OFF" -Description "Memory compression disabled" -DurationSec 120 -SkipPresentMon -SkipWPR'
Write-Host ''
Write-Host 'Rollback: Enable-MMAgent -MemoryCompression' -ForegroundColor Red
