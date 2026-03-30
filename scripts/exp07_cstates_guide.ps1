#Requires -RunAsAdministrator
<#
.SYNOPSIS
    EXP07: Enable C-States (BIOS change)
.DESCRIPTION
    BIOS-only change. Counterintuitively, ENABLING C-states fixes stuttering
    on AM5 boards with 9800X3D. Well-documented in Zen 5 X3D Owner's Club threads.
.NOTES
    Reboot: YES — requires BIOS entry
    This script only documents steps and provides post-reboot verification.
#>

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent

Write-Host '=== EXP07: Enable C-States (BIOS) ===' -ForegroundColor Cyan
Write-Host ''
Write-Host 'This is a BIOS change. No registry/command-line changes possible.' -ForegroundColor Yellow
Write-Host ''
Write-Host 'BIOS STEPS:' -ForegroundColor Cyan
Write-Host '  1. Reboot into BIOS (Del/F2 during POST)'
Write-Host '  2. Navigate to: Advanced > AMD CBS > CPU Common Options'
Write-Host '  3. Find: Global C-state Control'
Write-Host '  4. Set to: Enabled'
Write-Host '  5. Save and Exit'
Write-Host ''

# --- Current C-State verification ---
Write-Host 'CURRENT C-STATE STATUS:' -ForegroundColor Cyan
$cstateQuery = powercfg -query scheme_current SUB_PROCESSOR 68f262a7-f621-4069-b9a5-4874169be23f 2>&1
if ($cstateQuery) {
    $cstateQuery | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host '  Could not query C-state power setting'
}

Write-Host ''
Write-Host 'POST-REBOOT VERIFICATION:' -ForegroundColor Cyan
Write-Host '  # Check if C-states are active (C1/C6 should appear):'
Write-Host '  powercfg -query scheme_current SUB_PROCESSOR 68f262a7-f621-4069-b9a5-4874169be23f'
Write-Host ''
Write-Host '  # Then capture:'
Write-Host "  cd $projectRoot"
Write-Host '  .\scripts\pipeline.ps1 -Label "EXP07_CSTATES_ENABLED" -Description "Global C-state Control = Enabled in BIOS" -DurationSec 120 -SkipPresentMon -SkipWPR'
Write-Host ''
Write-Host 'ROLLBACK: BIOS > AMD CBS > CPU Common Options > Global C-state Control > Auto/Disabled' -ForegroundColor Red
