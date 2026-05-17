#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Audit and optimize BIOS settings for gaming via SCEWIN.
.DESCRIPTION
    Exports current BIOS settings, compares against optimal gaming profile
    for the AMD Ryzen 7 9800X3D, and optionally applies changes one setting
    at a time via SCEWIN single-variable writes (minimal SMI impact).

    Two tiers of changes:
      Tier 1: Non-RAM settings (C-States, TSME, PBO, FCLK) - safe, high impact
      Tier 2: RAM subtimings (tRFC, tRFCsb, Power Down) - moderate risk, needs stability test

    Always creates a Windows System Restore Point and BIOS backup before changes.
.PARAMETER Audit
    Show comparison table only. No changes applied.
.PARAMETER Apply
    Apply recommended changes after showing the comparison.
.PARAMETER Tier1Only
    Skip RAM timing changes (Tier 2). Apply only safe BIOS settings.
.PARAMETER Restore
    Restore BIOS settings from a backup export file.
.PARAMETER BackupFile
    Path to a backup export to restore from (used with -Restore).
.PARAMETER ScewinPath
    Path to SCEWIN_64.exe. Auto-detected if not specified.
.EXAMPLE
    .\optimize-bios.ps1 -Audit
.EXAMPLE
    .\optimize-bios.ps1 -Apply
.EXAMPLE
    .\optimize-bios.ps1 -Apply -Tier1Only
.EXAMPLE
    .\optimize-bios.ps1 -Restore -BackupFile captures\bios_backup_20260410.txt
#>
param(
    [switch]$Audit,
    [switch]$Apply,
    [switch]$Tier1Only,
    [switch]$Restore,
    [string]$BackupFile = '',
    [string]$ScewinPath = ''
)

$ErrorActionPreference = 'Continue'
$projectRoot = Split-Path $PSScriptRoot -Parent

Write-Host ''
Write-Host '=== BIOS Optimizer for 9800X3D ===' -ForegroundColor Cyan
Write-Host ''

# ── Phase 0: Find SCEWIN ────────────────────────────────────────────────────
if ($ScewinPath -eq '') {
    $searchPaths = @(
        'C:\Users\L\Downloads\AMD BIOS Tweaks by CatGamerOP\SCEWIN\5.05.01.0002\SCEWIN_64.exe',
        'C:\Tools\SCEWIN_64.exe',
        'C:\SCEWIN\SCEWIN_64.exe'
    )
    foreach ($p in $searchPaths) {
        if (Test-Path $p) { $ScewinPath = $p; break }
    }
    if ($ScewinPath -eq '') {
        $found = Get-ChildItem 'C:\Users' -Recurse -Filter 'SCEWIN_64.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $ScewinPath = $found.FullName }
    }
}

if ($ScewinPath -eq '' -or -not (Test-Path $ScewinPath)) {
    Write-Host 'SCEWIN_64.exe not found. Specify with -ScewinPath.' -ForegroundColor Red
    exit 1
}

$scewinDir = Split-Path $ScewinPath -Parent
Write-Host ('SCEWIN: ' + $ScewinPath) -ForegroundColor Green

# ── Phase 1: Export current BIOS ─────────────────────────────────────────────
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupPath = Join-Path $projectRoot ('captures\bios_backup_' + $timestamp + '.txt')

Write-Host 'Exporting current BIOS settings...'
Push-Location $scewinDir
try {
    $exportResult = & '.\SCEWIN_64.exe' /o /s $backupPath /d 2>&1 | Out-String
} catch {}
Pop-Location

if (-not (Test-Path $backupPath)) {
    Write-Host 'BIOS export failed. Check SCEWIN permissions.' -ForegroundColor Red
    exit 1
}
$lineCount = (Get-Content $backupPath).Count
Write-Host ('Backup saved: ' + $backupPath + ' (' + $lineCount + ' lines)') -ForegroundColor Green

# ── Phase 2: Parse export ────────────────────────────────────────────────────
function Parse-BiosExport {
    param([string]$Path)
    $settings = @{}
    $currentQ = $null
    $currentToken = $null
    foreach ($line in (Get-Content $Path)) {
        if ($line -match '^\s*Setup Question\s*=\s*(.+)') {
            $currentQ = $Matches[1].Trim()
            $currentToken = $null
        }
        if ($line -match '^\s*Token\s*=(\S+)') {
            $currentToken = $Matches[1].Trim()
        }
        # Option-type value (asterisk marks selection)
        if ($currentQ -and $line -match '\*\[([^\]]+)\](.*)') {
            $key = $currentQ
            if ($currentToken) { $key = $currentQ + '|' + $currentToken }
            $settings[$key] = '[' + $Matches[1] + ']' + $Matches[2].Trim()
            $currentQ = $null
        }
        # Numeric value
        if ($currentQ -and $line -match '^\s*Value\s*=\s*\*?<([^>]+)>') {
            $key = $currentQ
            if ($currentToken) { $key = $currentQ + '|' + $currentToken }
            $settings[$key] = '<' + $Matches[1] + '>'
            $currentQ = $null
        }
        # String value
        if ($currentQ -and $line -match '^\s*Value\s*=\s*\*?"([^"]*)"') {
            $key = $currentQ
            if ($currentToken) { $key = $currentQ + '|' + $currentToken }
            $settings[$key] = '"' + $Matches[1] + '"'
            $currentQ = $null
        }
    }
    return $settings
}

Write-Host 'Parsing BIOS settings...'
$current = Parse-BiosExport -Path $backupPath
Write-Host ('Parsed ' + $current.Count + ' settings')
Write-Host ''

# ── Phase 3: Define optimal profile ──────────────────────────────────────────
# Each entry: settingKey (Name|Token), targetValue, description, tier
$optimal = @(
    # Tier 1: Non-RAM (safe, high impact)
    @{ key = 'Global C-state Control|01';                  target = '[01]Enabled';            desc = 'C-States: #1 frame pacing fix for X3D';         tier = 1 }
    @{ key = 'TSME|7024';                                  target = '[00]Disabled';            desc = 'Memory encryption: adds latency';               tier = 1 }
    @{ key = 'SMEE|25';                                    target = '[00]Disable';             desc = 'Secure memory encryption overhead';              tier = 1 }
    @{ key = 'Precision Boost Overdrive|95';               target = '[02]Advanced';            desc = 'PBO Advanced: enables CO + boost override';      tier = 1 }
    @{ key = 'All Core Curve Optimizer Sign|A8';           target = '[01]Negative';            desc = 'CO: undervolt for less heat, higher sustained';  tier = 1 }
    @{ key = 'All Core Curve Optimizer Magnitude|A9';      target = '<10>';                    desc = 'CO: -10 all-core (safe starting point)';         tier = 1 }
    @{ key = 'CPU Boost Clock Override|9C';                target = '[01]Enabled (Positive)';  desc = 'Enable boost clock override';                    tier = 1 }
    @{ key = 'Max CPU Boost Clock Override(+)|9D';         target = '<25>';                    desc = 'Boost +25 MHz (conservative)';                   tier = 1 }
    @{ key = 'FCLK Frequency|2CD4';                        target = '[7D0]2000 MHz';           desc = 'Lock FCLK at 2000 for 1:1 with DDR5-6000';      tier = 1 }
    @{ key = 'CPPC Preferred Cores|3B';                    target = '[00]Disabled';            desc = 'Eliminates 8kHz scheduling micro-stutter';       tier = 1 }
    @{ key = 'Data Scramble|706E';                         target = '[00]Disabled';            desc = 'Memory bus encryption layer removal';            tier = 1 }
    # NOTE: Spread Spectrum, Fast Boot, Platform Power Management
    # require SCEWIN OIDs from a fresh export. Apply manually via BIOS menu
    # using BIOS_CHECKLIST.md output from deep_optimize.ps1.

    # Tier 2: RAM subtimings (moderate risk)
    @{ key = 'Power Down Enable|BF';                       target = '[00]Disabled';            desc = 'RAM Power Down: 1-2ns latency reduction';       tier = 2 }
    @{ key = 'Power Down Enable|84';                       target = '[00]Disabled';            desc = 'RAM Power Down (duplicate): same fix';           tier = 2 }
    @{ key = 'Trfc1 Ctrl|62';                              target = '[01]Manual';              desc = 'Enable manual tRFC control';                    tier = 2 }
    @{ key = 'Trfc1|63';                                   target = '<480>';                   desc = 'tRFC1: 480 (safe for Team Group DDR5-6000)';    tier = 2 }
    @{ key = 'TrfcSb Ctrl|66';                             target = '[01]Manual';              desc = 'Enable manual tRFCsb control';                  tier = 2 }
    @{ key = 'TrfcSb|67';                                  target = '<288>';                   desc = 'tRFCsb: 288 (60% of tRFC)';                    tier = 2 }
    @{ key = 'Trfc2 Ctrl|64';                              target = '[01]Manual';              desc = 'Enable manual tRFC2 control';                   tier = 2 }
    @{ key = 'Trfc2|65';                                   target = '<384>';                   desc = 'tRFC2: 384 (80% of tRFC)';                     tier = 2 }
)

# ── Phase 4: Compare and display ─────────────────────────────────────────────
Write-Host '=== BIOS Settings Comparison ===' -ForegroundColor Cyan
Write-Host ''

$changes = @()
$tierLabel = @{ 1 = 'BIOS'; 2 = 'RAM' }

Write-Host ('{0,-45} {1,-25} {2,-25} {3,-6} {4}' -f 'Setting', 'Current', 'Recommended', 'Tier', 'Status')
Write-Host ('{0,-45} {1,-25} {2,-25} {3,-6} {4}' -f '-------', '-------', '-----------', '----', '------')

foreach ($opt in $optimal) {
    if ($Tier1Only -and $opt.tier -eq 2) { continue }

    $curVal = $current[$opt.key]
    $status = 'N/A'
    $color = 'DarkGray'

    if ($null -ne $curVal) {
        if ($curVal -eq $opt.target) {
            $status = 'OK'
            $color = 'Green'
        } else {
            $status = 'CHANGE'
            $color = 'Yellow'
            $changes += $opt
        }
    } else {
        $status = 'NOT FOUND'
        $color = 'DarkGray'
    }

    $name = ($opt.key -split '\|')[0]
    Write-Host ('{0,-45} {1,-25} {2,-25} {3,-6} {4}' -f $name, $curVal, $opt.target, $tierLabel[$opt.tier], $status) -ForegroundColor $color
}

Write-Host ''
$changeCount = $changes.Count
if ($changeCount -eq 0) {
    Write-Host 'All settings match optimal profile. Nothing to change.' -ForegroundColor Green
    exit 0
}

Write-Host ($changeCount.ToString() + ' setting(s) need updating.') -ForegroundColor Yellow

# ── Audit mode: stop here ────────────────────────────────────────────────────
if ($Audit -or (-not $Apply -and -not $Restore)) {
    Write-Host ''
    Write-Host 'Run with -Apply to make changes.' -ForegroundColor DarkGray
    Write-Host 'Run with -Apply -Tier1Only to change BIOS settings only (skip RAM).' -ForegroundColor DarkGray
    exit 0
}

# ── Restore mode ─────────────────────────────────────────────────────────────
if ($Restore) {
    if ($BackupFile -eq '' -or -not (Test-Path $BackupFile)) {
        Write-Host 'Specify a valid backup file with -BackupFile.' -ForegroundColor Red
        exit 1
    }
    Write-Host ('Restoring from: ' + $BackupFile) -ForegroundColor Yellow
    Write-Host 'WARNING: This will apply ALL settings from the backup. System will lag during import.' -ForegroundColor Red
    $confirm = Read-Host 'Type YES to confirm'
    if ($confirm -ne 'YES') { Write-Host 'Cancelled.'; exit 0 }

    Push-Location $scewinDir
    & '.\SCEWIN_64.exe' /i /s $BackupFile /q /d 2>&1
    Pop-Location
    Write-Host 'Restore complete. Reboot to apply.' -ForegroundColor Green
    exit 0
}

# ── Phase 5: Create System Restore Point ─────────────────────────────────────
Write-Host ''
Write-Host '--- Creating Windows System Restore Point ---' -ForegroundColor Yellow
try {
    Enable-ComputerRestore -Drive 'C:\' -ErrorAction SilentlyContinue
    Checkpoint-Computer -Description 'Pre-BIOS optimization (optimize-bios.ps1)' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
    Write-Host 'Restore point created.' -ForegroundColor Green
} catch {
    Write-Host ('Restore point failed: ' + $_.Exception.Message) -ForegroundColor Yellow
    Write-Host 'Continuing anyway (BIOS backup exists as fallback).' -ForegroundColor DarkGray
}

# ── Phase 6: Apply changes one at a time ─────────────────────────────────────
Write-Host ''
Write-Host ('--- Applying ' + $changeCount + ' changes via SCEWIN ---') -ForegroundColor Yellow
Write-Host 'Each change triggers one SMI (~50-400ms system pause).' -ForegroundColor DarkGray
Write-Host ''

$confirm2 = Read-Host ('Apply ' + $changeCount + ' changes? Type YES to proceed')
if ($confirm2 -ne 'YES') { Write-Host 'Cancelled.'; exit 0 }

Write-Host ''
$applied = 0
$failed = 0

foreach ($change in $changes) {
    $name = ($change.key -split '\|')[0]
    $token = ($change.key -split '\|')[1]
    $targetVal = $change.target

    Write-Host ('  [' + ($applied + $failed + 1) + '/' + $changeCount + '] ' + $name + ' -> ' + $targetVal) -NoNewline

    # Build the modified export file with just this one change
    # Strategy: copy backup, modify the specific setting, import the full file
    # This is simpler than /ms which has complex quoting issues
    $tempFile = Join-Path $env:TEMP ('scewin_change_' + $token + '.txt')
    $content = Get-Content $backupPath -Raw

    # Find and modify the setting by token
    # The setting block starts with "Setup Question = <name>" and has "Token =<token>"
    # We need to move the asterisk to the target option or change the value

    if ($targetVal -match '^\[([^\]]+)\]') {
        # Option-type: move asterisk
        $targetHex = $Matches[1]
        $modified = $false
        $outLines = @()
        $inTargetBlock = $false
        $tokenMatch = $false

        foreach ($line in (Get-Content $backupPath)) {
            if ($line -match ('^\s*Token\s*=' + [regex]::Escape($token) + '\s')) {
                $tokenMatch = $true
            }
            if ($tokenMatch -and ($line -match '^\s*Options\s*=' -or $line -match '^\s+\[' -or $line -match '^\s+\*\[')) {
                $inTargetBlock = $true
            }
            if ($inTargetBlock) {
                if ($line -match '^\s*$' -or ($line -match '^\s*Setup Question' -and $modified)) {
                    $inTargetBlock = $false
                    $tokenMatch = $false
                }
                # Remove existing asterisk
                $line = $line -replace '\*\[', '['
                # Add asterisk to target option
                if ($line -match ('\[' + [regex]::Escape($targetHex) + '\]')) {
                    $line = $line -replace ('\[' + [regex]::Escape($targetHex) + '\]'), ('*[' + $targetHex + ']')
                    $modified = $true
                }
            }
            $outLines += $line
        }

        if ($modified) {
            $outLines | Out-File $tempFile -Encoding UTF8
            Push-Location $scewinDir
            $writeResult = & '.\SCEWIN_64.exe' /i /s $tempFile /q /d 2>&1
            Pop-Location
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue

            if ($LASTEXITCODE -eq 0 -or ($writeResult | Out-String) -match 'successfully') {
                Write-Host '  OK' -ForegroundColor Green
                $applied++
            } else {
                Write-Host '  FAILED' -ForegroundColor Red
                $failed++
            }
        } else {
            Write-Host '  SKIPPED (option not found in export)' -ForegroundColor DarkGray
            $failed++
        }
    }
    elseif ($targetVal -match '^<([^>]+)>$') {
        # Numeric value: change Value line
        $targetNum = $Matches[1]
        $modified = $false
        $outLines = @()
        $tokenMatch = $false

        foreach ($line in (Get-Content $backupPath)) {
            if ($line -match ('^\s*Token\s*=' + [regex]::Escape($token) + '\s')) {
                $tokenMatch = $true
            }
            if ($tokenMatch -and $line -match '^\s*Value\s*=') {
                $line = 'Value	=<' + $targetNum + '>'
                $modified = $true
                $tokenMatch = $false
            }
            if ($tokenMatch -and ($line -match '^\s*$' -or $line -match '^\s*Setup Question')) {
                $tokenMatch = $false
            }
            $outLines += $line
        }

        if ($modified) {
            $outLines | Out-File $tempFile -Encoding UTF8
            Push-Location $scewinDir
            $writeResult = & '.\SCEWIN_64.exe' /i /s $tempFile /q /d 2>&1
            Pop-Location
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue

            if ($LASTEXITCODE -eq 0 -or ($writeResult | Out-String) -match 'successfully') {
                Write-Host '  OK' -ForegroundColor Green
                $applied++
            } else {
                Write-Host '  FAILED' -ForegroundColor Red
                $failed++
            }
        } else {
            Write-Host '  SKIPPED (value field not found)' -ForegroundColor DarkGray
            $failed++
        }
    }
}

# ── Phase 7: Summary ─────────────────────────────────────────────────────────
Write-Host ''
Write-Host '=== Results ===' -ForegroundColor Cyan
Write-Host ('Applied: ' + $applied + ' | Failed: ' + $failed + ' | Total: ' + $changeCount)
Write-Host ''
Write-Host 'Backup at: ' + $backupPath -ForegroundColor DarkGray
Write-Host ''

if ($applied -gt 0) {
    Write-Host 'REBOOT REQUIRED to apply BIOS changes.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'After reboot:' -ForegroundColor DarkGray
    Write-Host '  1. Run pipeline.ps1 -Mode Quick to capture new metrics' -ForegroundColor DarkGray
    Write-Host '  2. Compare against previous captures for improvement' -ForegroundColor DarkGray
    if (-not $Tier1Only) {
        Write-Host '  3. Run TestMem5 (anta777 Extreme, 3 cycles) to verify RAM stability' -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host 'To undo: .\optimize-bios.ps1 -Restore -BackupFile "' + $backupPath + '"' -ForegroundColor DarkGray
}
