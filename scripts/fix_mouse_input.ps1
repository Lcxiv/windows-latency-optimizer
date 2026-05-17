<#
.SYNOPSIS
    Apply Windows mouse/keyboard input stack optimizations for gaming.
.DESCRIPTION
    Tier 1+2 registry tweaks for reducing input processing overhead.
    Creates registry backup before changes. Use -Rollback to restore.

    What this does NOT fix: physical mouse button pre-travel (mechanical).
    What this DOES fix: Windows input stack latency, cursor update rate,
    cursor magnetism, tracing overhead, buffer sizes.

    Proven tweaks only — no cargo-cult undocumented parameters.
.PARAMETER Apply
    Apply all input optimizations (default action).
.PARAMETER Rollback
    Restore previous registry values from backup file.
.PARAMETER BackupFile
    Path to backup file for rollback. Auto-detected if omitted.
.PARAMETER Verify
    Show current vs optimal values without changing anything.
.PARAMETER WhatIf
    Preview changes without applying.
.EXAMPLE
    .\fix_mouse_input.ps1
.EXAMPLE
    .\fix_mouse_input.ps1 -Verify
.EXAMPLE
    .\fix_mouse_input.ps1 -Rollback
#>
#Requires -RunAsAdministrator
param(
    [switch]$Apply,
    [switch]$Rollback,
    [string]$BackupFile,
    [switch]$Verify,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

# ── Configuration ─────────────────────────────────────────────────────────────
# Each entry: registry path, value name, desired value, type, description
$tweaks = @(
    # --- mouclass (mouse class driver) ---
    @{
        Path  = 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters'
        Name  = 'MouseDataQueueSize'
        Value = 32
        Type  = 'DWord'
        Desc  = 'Mouse ring buffer size (default 100, reduced to 32)'
    },
    @{
        Path  = 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters'
        Name  = 'WppRecorder_UseTimeStamp'
        Value = 0
        Type  = 'DWord'
        Desc  = 'Disable WPP tracing timestamp overhead'
    },

    # --- kbdclass (keyboard class driver) ---
    @{
        Path  = 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters'
        Name  = 'KeyboardDataQueueSize'
        Value = 32
        Type  = 'DWord'
        Desc  = 'Keyboard ring buffer size (default 100, reduced to 32)'
    },
    @{
        Path  = 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters'
        Name  = 'WppRecorder_UseTimeStamp'
        Value = 0
        Type  = 'DWord'
        Desc  = 'Disable WPP tracing timestamp overhead'
    },
    @{
        Path  = 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters'
        Name  = 'SendOutputToAllPorts'
        Value = 0
        Type  = 'DWord'
        Desc  = 'Stop broadcasting keyboard output to all ports'
    },

    # --- mouhid (mouse HID driver) ---
    @{
        Path  = 'HKLM:\SYSTEM\CurrentControlSet\Services\mouhid\Parameters'
        Name  = 'TreatAbsolutePointerAsAbsolute'
        Value = 1
        Type  = 'DWord'
        Desc  = 'Correct absolute pointer coordinate handling'
    },
    @{
        Path  = 'HKLM:\SYSTEM\CurrentControlSet\Services\mouhid\Parameters'
        Name  = 'WppRecorder_UseTimeStamp'
        Value = 0
        Type  = 'DWord'
        Desc  = 'Disable WPP tracing timestamp overhead'
    },

    # --- Cursor update rate ---
    @{
        Path  = 'HKLM:\SOFTWARE\Microsoft\Input\Settings\ControllerProcessor\CursorSpeed'
        Name  = 'CursorUpdateInterval'
        Value = 1
        Type  = 'DWord'
        Desc  = 'Cursor position update interval (default 5, set to 1 = fastest)'
    },

    # --- Cursor magnetism (disable for gaming) ---
    @{
        Path  = 'HKLM:\SOFTWARE\Microsoft\Input\Settings\ControllerProcessor\CursorMagnetism'
        Name  = 'AttractionRectInsetInDIPS'
        Value = 0
        Type  = 'DWord'
        Desc  = 'Disable cursor magnetism attraction zone'
    },
    @{
        Path  = 'HKLM:\SOFTWARE\Microsoft\Input\Settings\ControllerProcessor\CursorMagnetism'
        Name  = 'DistanceThresholdInDIPS'
        Value = 0
        Type  = 'DWord'
        Desc  = 'Disable cursor magnetism distance threshold'
    },
    @{
        Path  = 'HKLM:\SOFTWARE\Microsoft\Input\Settings\ControllerProcessor\CursorMagnetism'
        Name  = 'MagnetismDelayInMilliseconds'
        Value = 0
        Type  = 'DWord'
        Desc  = 'Disable cursor magnetism delay'
    },
    @{
        Path  = 'HKLM:\SOFTWARE\Microsoft\Input\Settings\ControllerProcessor\CursorMagnetism'
        Name  = 'MagnetismUpdateIntervalInMilliseconds'
        Value = 0
        Type  = 'DWord'
        Desc  = 'Disable cursor magnetism update interval'
    },
    @{
        Path  = 'HKLM:\SOFTWARE\Microsoft\Input\Settings\ControllerProcessor\CursorMagnetism'
        Name  = 'VelocityInDIPSPerSecond'
        Value = 0
        Type  = 'DWord'
        Desc  = 'Disable cursor magnetism velocity'
    }
)

# ── Functions ─────────────────────────────────────────────────────────────────

function Get-CurrentValue {
    param([string]$Path, [string]$Name)
    try {
        $val = Get-ItemProperty $Path -Name $Name -ErrorAction Stop
        return $val.$Name
    } catch {
        return $null
    }
}

function Save-Backup {
    param([string]$OutPath)
    $lines = @()
    $lines += '# Mouse Input Tweak Backup'
    $lines += '# Created: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $lines += '# Restore with: .\fix_mouse_input.ps1 -Rollback -BackupFile "' + $OutPath + '"'
    $lines += ''

    foreach ($t in $tweaks) {
        $current = Get-CurrentValue -Path $t.Path -Name $t.Name
        $valStr = 'NULL'
        if ($null -ne $current) { $valStr = [string]$current }
        $lines += $t.Path + '|' + $t.Name + '|' + $valStr + '|' + $t.Type
    }

    $lines | Out-File $OutPath -Encoding UTF8
    Write-Host ('Backup saved: ' + $OutPath) -ForegroundColor Green
}

function Restore-Backup {
    param([string]$FilePath)
    if (-not (Test-Path $FilePath)) {
        Write-Host ('Backup not found: ' + $FilePath) -ForegroundColor Red
        exit 1
    }

    $lines = Get-Content $FilePath | Where-Object { $_ -and -not $_.StartsWith('#') }
    $restored = 0
    foreach ($line in $lines) {
        $parts = $line.Split('|')
        if ($parts.Count -lt 4) { continue }
        $path = $parts[0]
        $name = $parts[1]
        $val  = $parts[2]
        $type = $parts[3]

        if ($val -eq 'NULL') {
            # Value didn't exist before — remove it
            try {
                Remove-ItemProperty $path -Name $name -ErrorAction Stop
                Write-Host ('  [REMOVED] ' + $name) -ForegroundColor Yellow
                $restored++
            } catch {
                Write-Host ('  [SKIP] ' + $name + ' (already absent)') -ForegroundColor DarkGray
            }
        } else {
            if (-not (Test-Path $path)) {
                New-Item -Path $path -Force | Out-Null
            }
            Set-ItemProperty $path -Name $name -Value ([int]$val) -Type $type
            Write-Host ('  [RESTORED] ' + $name + ' = ' + $val) -ForegroundColor Green
            $restored++
        }
    }
    Write-Host ''
    Write-Host ('Restored ' + $restored + ' values from backup.') -ForegroundColor Green
    Write-Host 'Reboot recommended for full effect.' -ForegroundColor Yellow
}

# ── Main ──────────────────────────────────────────────────────────────────────

Write-Host '=== Mouse & Keyboard Input Optimization ===' -ForegroundColor Cyan
Write-Host ''

# --- Rollback mode ---
if ($Rollback) {
    if (-not $BackupFile) {
        # Find latest backup
        $backupDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'captures'
        $latest = Get-ChildItem $backupDir -Filter 'backup_pre_mouse_input_*.txt' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($latest) {
            $BackupFile = $latest.FullName
            Write-Host ('Auto-detected backup: ' + $BackupFile)
        } else {
            Write-Host 'No backup found. Specify -BackupFile path.' -ForegroundColor Red
            exit 1
        }
    }
    Write-Host 'Restoring from backup...'
    Restore-Backup -FilePath $BackupFile
    exit 0
}

# --- Verify mode ---
if ($Verify) {
    Write-Host 'Current vs Optimal:' -ForegroundColor Yellow
    Write-Host ''
    $needsFix = 0
    foreach ($t in $tweaks) {
        $current = Get-CurrentValue -Path $t.Path -Name $t.Name
        $currentStr = if ($null -eq $current) { '(not set)' } else { [string]$current }
        $match = ($null -ne $current -and [int]$current -eq $t.Value)
        $icon = if ($match) { '[OK]' } else { '[FIX]' }
        $color = if ($match) { 'Green' } else { 'Yellow' }
        Write-Host ('  ' + $icon + ' ' + $t.Name + ': ' + $currentStr + ' -> ' + $t.Value + '  (' + $t.Desc + ')') -ForegroundColor $color
        if (-not $match) { $needsFix++ }
    }
    Write-Host ''
    if ($needsFix -eq 0) {
        Write-Host 'All values already optimal.' -ForegroundColor Green
    } else {
        Write-Host ($needsFix.ToString() + ' value(s) need updating. Run without -Verify to apply.') -ForegroundColor Yellow
    }
    exit 0
}

# --- Apply mode (default) ---
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupPath = Join-Path (Split-Path $PSScriptRoot -Parent) ('captures\backup_pre_mouse_input_' + $timestamp + '.txt')

# Save backup first
Save-Backup -OutPath $backupPath

Write-Host ''
Write-Host 'Applying input optimizations...' -ForegroundColor Cyan
Write-Host ''

$applied = 0
$skipped = 0
foreach ($t in $tweaks) {
    $current = Get-CurrentValue -Path $t.Path -Name $t.Name
    if ($null -ne $current -and [int]$current -eq $t.Value) {
        Write-Host ('  [SKIP] ' + $t.Name + ' = ' + $t.Value + ' (already set)') -ForegroundColor DarkGray
        $skipped++
        continue
    }

    if ($WhatIf) {
        $fromStr = if ($null -eq $current) { '(not set)' } else { [string]$current }
        Write-Host ('  [WOULD] ' + $t.Name + ': ' + $fromStr + ' -> ' + $t.Value) -ForegroundColor Yellow
        $applied++
        continue
    }

    # Ensure path exists
    if (-not (Test-Path $t.Path)) {
        New-Item -Path $t.Path -Force | Out-Null
    }

    $fromStr = if ($null -eq $current) { '(not set)' } else { [string]$current }
    Set-ItemProperty $t.Path -Name $t.Name -Value $t.Value -Type $t.Type
    Write-Host ('  [SET] ' + $t.Name + ': ' + $fromStr + ' -> ' + $t.Value + '  (' + $t.Desc + ')') -ForegroundColor Green
    $applied++
}

Write-Host ''
if ($WhatIf) {
    Write-Host ('Would apply ' + $applied + ' changes, skip ' + $skipped + ' (already set).') -ForegroundColor Yellow
    Write-Host 'Run without -WhatIf to apply.' -ForegroundColor Yellow
} else {
    Write-Host ('Applied ' + $applied + ' changes, skipped ' + $skipped + ' (already set).') -ForegroundColor Green
    Write-Host ('Backup: ' + $backupPath) -ForegroundColor Cyan
    Write-Host 'Reboot recommended for full effect.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Rollback: .\fix_mouse_input.ps1 -Rollback' -ForegroundColor DarkCyan
}
