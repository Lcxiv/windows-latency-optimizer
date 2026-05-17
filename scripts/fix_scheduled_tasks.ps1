#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Disable latency-impacting scheduled tasks for gaming optimization.
.DESCRIPTION
    Identifies and disables scheduled tasks that fire frequently (hourly or less)
    and cause CPU, disk I/O, or network spikes during gaming. Creates a backup
    for full rollback. Also cleans up stale LatencyGuard tasks.
.PARAMETER Audit
    Preview mode — show what would change without modifying anything.
.PARAMETER Restore
    Re-enable all tasks from a previous backup file.
.PARAMETER BackupFile
    Path to backup JSON for -Restore mode. If omitted, uses most recent.
.PARAMETER SkipCleanup
    Don't remove stale LatencyGuard_ duplicate tasks.
.NOTES
    Reboot: NO
    Rollback: Run with -Restore to re-enable all tasks from backup
#>

param(
    [switch]$Audit,
    [switch]$Restore,
    [string]$BackupFile = '',
    [switch]$SkipCleanup
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$captureDir  = Join-Path $projectRoot 'captures'

# ─── Task Disable List ────────���───────────────────────────────────────────────
# Each entry: @{ TaskPath; TaskName; Reason }
# TaskPath must include leading and trailing backslash.

$tasksToDisable = @(
    # Hourly — Edge update check (network + disk I/O)
    @{ TaskPath = '\'; TaskName = 'MicrosoftEdgeUpdateTaskMachineUA'; Reason = 'Hourly Edge update (PT1H) — network + disk spikes' }
    @{ TaskPath = '\'; TaskName = 'MicrosoftEdgeUpdateTaskMachineCore'; Reason = 'Edge update core task' }

    # Hourly — Office background
    @{ TaskPath = '\Microsoft\Office\'; TaskName = 'Office Actions Server'; Reason = 'Hourly Office integration (PT1H)' }
    @{ TaskPath = '\Microsoft\Office\'; TaskName = 'Office Automatic Updates 2.0'; Reason = 'Office update check' }

    # 6h — Windows Update scan (redundant — LatencyOptimizer-WU-4AM-Scan handles this)
    @{ TaskPath = '\Microsoft\Windows\UpdateOrchestrator\'; TaskName = 'Schedule Scan'; Reason = '6h WU scan (PT6H) — custom 4AM task handles this' }

    # Telemetry — Flighting/FeatureConfig
    @{ TaskPath = '\Microsoft\Windows\Flighting\FeatureConfig\'; TaskName = 'UsageDataFlushing'; Reason = 'Telemetry — flushes experiment data to Microsoft' }
    @{ TaskPath = '\Microsoft\Windows\Flighting\FeatureConfig\'; TaskName = 'UsageDataReceiver'; Reason = 'Telemetry — receives feature experiment data' }
    @{ TaskPath = '\Microsoft\Windows\Flighting\FeatureConfig\'; TaskName = 'ReconcileFeatures'; Reason = 'Telemetry — reconciles feature experiment state' }

    # Telemetry — OneSettings
    @{ TaskPath = '\Microsoft\Windows\Flighting\OneSettings\'; TaskName = 'RefreshCache'; Reason = 'Feature experiment cache refresh (PT6H4M)' }

    # 4h — Windows Error Reporting
    @{ TaskPath = '\Microsoft\Windows\Windows Error Reporting\'; TaskName = 'QueueReporting'; Reason = 'Crash report upload (PT4H)' }

    # Recall AI — still active despite Recall being "disabled"
    @{ TaskPath = '\Microsoft\Windows\WindowsAI\'; TaskName = 'PolicyConfiguration'; Reason = 'Recall AI policy — running despite Recall disabled' }

    # 12h — Program Compatibility Assistant
    @{ TaskPath = '\Microsoft\Windows\Application Experience\'; TaskName = 'PcaPatchDbTask'; Reason = 'Compat DB patch (PT12H)' }
)

# Stale tasks to remove
$staleTasks = @(
    @{ TaskPath = '\'; TaskName = 'LatencyGuard_RegistryWatchdog'; Reason = 'Superseded by LatencyOptimizer-RegistryWatchdog' }
    @{ TaskPath = '\'; TaskName = 'LatencyGuard_BootInventory'; Reason = 'Superseded — never ran' }
)

# ─── Restore Mode ────────────────────────────────────────────────────────────
if ($Restore) {
    Write-Host '=== Restore Scheduled Tasks from Backup ===' -ForegroundColor Cyan
    Write-Host ''

    if (-not $BackupFile) {
        # Find most recent backup
        $backups = @(Get-ChildItem $captureDir -Filter 'backup_pre_tasksched_*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        if ($backups.Count -eq 0) {
            Write-Host 'No backup files found in captures/.' -ForegroundColor Red
            exit 1
        }
        $BackupFile = $backups[0].FullName
    }

    if (-not (Test-Path $BackupFile)) {
        Write-Host ('Backup file not found: ' + $BackupFile) -ForegroundColor Red
        exit 1
    }

    Write-Host ('Loading: ' + $BackupFile) -ForegroundColor Yellow
    $backup = Get-Content $BackupFile -Raw | ConvertFrom-Json

    $restored = 0
    foreach ($entry in $backup) {
        $fullPath = $entry.TaskPath + $entry.TaskName
        try {
            $task = Get-ScheduledTask -TaskPath $entry.TaskPath -TaskName $entry.TaskName -ErrorAction SilentlyContinue
            if (-not $task) {
                Write-Host ('  SKIP (not found): ' + $fullPath) -ForegroundColor Yellow
                continue
            }
            if ($entry.OriginalState -eq 'Ready' -and $task.State -eq 'Disabled') {
                Enable-ScheduledTask -TaskPath $entry.TaskPath -TaskName $entry.TaskName | Out-Null
                Write-Host ('  Restored: ' + $fullPath) -ForegroundColor Green
                $restored++
            } else {
                Write-Host ('  No change needed: ' + $fullPath + ' (state=' + $task.State.ToString() + ')') -ForegroundColor Gray
            }
        } catch {
            Write-Host ('  FAILED: ' + $fullPath + ' — ' + $_.Exception.Message) -ForegroundColor Red
        }
    }

    Write-Host ''
    Write-Host ('Restored ' + $restored + ' task(s).') -ForegroundColor Cyan
    exit 0
}

# ─── Main: Audit / Apply ──────��──────────────────────────────────────────────
if ($Audit) {
    Write-Host '=== Scheduled Task Optimization — AUDIT MODE (no changes) ===' -ForegroundColor Cyan
} else {
    Write-Host '=== Scheduled Task Optimization for Gaming ===' -ForegroundColor Cyan
}
Write-Host ''

# Phase 1 — Discover current state + build backup
Write-Host 'Phase 1: Scanning task state...' -ForegroundColor Yellow
$backupEntries = @()
$actionPlan = @()

foreach ($td in $tasksToDisable) {
    $fullPath = $td.TaskPath + $td.TaskName
    try {
        $task = Get-ScheduledTask -TaskPath $td.TaskPath -TaskName $td.TaskName -ErrorAction SilentlyContinue
    } catch {
        $task = $null
    }

    if (-not $task) {
        $actionPlan += @{ FullPath = $fullPath; Action = 'NOT FOUND'; Reason = $td.Reason; State = 'N/A' }
        continue
    }

    $state = $task.State.ToString()
    $backupEntries += @{
        TaskPath      = $td.TaskPath
        TaskName      = $td.TaskName
        OriginalState = $state
        Reason        = $td.Reason
    }

    if ($state -eq 'Disabled') {
        $actionPlan += @{ FullPath = $fullPath; Action = 'ALREADY DISABLED'; Reason = $td.Reason; State = $state }
    } elseif ($state -eq 'Ready' -or $state -eq 'Running' -or $state -eq 'Queued') {
        $actionPlan += @{ FullPath = $fullPath; Action = 'DISABLE'; Reason = $td.Reason; State = $state }
    } else {
        $actionPlan += @{ FullPath = $fullPath; Action = 'SKIP (' + $state + ')'; Reason = $td.Reason; State = $state }
    }
}

# Display plan
Write-Host ''
Write-Host ('  Tasks scanned:        ' + $tasksToDisable.Count)
$toDisableCount = @($actionPlan | Where-Object { $_.Action -eq 'DISABLE' }).Count
$alreadyCount   = @($actionPlan | Where-Object { $_.Action -eq 'ALREADY DISABLED' }).Count
$notFoundCount  = @($actionPlan | Where-Object { $_.Action -eq 'NOT FOUND' }).Count
Write-Host ('  To disable:           ' + $toDisableCount) -ForegroundColor $(if ($toDisableCount -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ('  Already disabled:     ' + $alreadyCount) -ForegroundColor Green
Write-Host ('  Not found on system:  ' + $notFoundCount) -ForegroundColor Gray
Write-Host ''

foreach ($ap in $actionPlan) {
    $color = 'Gray'
    if ($ap.Action -eq 'DISABLE') { $color = 'Yellow' }
    elseif ($ap.Action -eq 'ALREADY DISABLED') { $color = 'Green' }
    elseif ($ap.Action -eq 'NOT FOUND') { $color = 'DarkGray' }
    $line = '  [' + $ap.Action.PadRight(17) + '] ' + $ap.FullPath
    Write-Host $line -ForegroundColor $color
    Write-Host ('                        ' + $ap.Reason) -ForegroundColor DarkGray
}

if ($Audit) {
    Write-Host ''
    Write-Host 'Audit complete. No changes made. Remove -Audit to apply.' -ForegroundColor Cyan
    exit 0
}

if ($toDisableCount -eq 0) {
    Write-Host 'All target tasks already disabled. Nothing to do.' -ForegroundColor Green
} else {
    # Phase 2 — Backup
    $timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupPath = Join-Path $captureDir ('backup_pre_tasksched_' + $timestamp + '.json')

    if (-not (Test-Path $captureDir)) {
        New-Item -Path $captureDir -ItemType Directory -Force | Out-Null
    }
    $backupEntries | ConvertTo-Json -Depth 5 | Out-File -FilePath $backupPath -Encoding UTF8
    Write-Host ''
    Write-Host ('Backup saved: ' + $backupPath) -ForegroundColor Green

    # Phase 3 — Apply
    Write-Host ''
    Write-Host 'Disabling tasks...' -ForegroundColor Yellow
    $disabled = 0
    foreach ($ap in $actionPlan) {
        if ($ap.Action -ne 'DISABLE') { continue }

        # Find the matching entry to get TaskPath/TaskName
        $entry = $null
        foreach ($td in $tasksToDisable) {
            if (($td.TaskPath + $td.TaskName) -eq $ap.FullPath) {
                $entry = $td
                break
            }
        }
        if (-not $entry) { continue }

        try {
            Disable-ScheduledTask -TaskPath $entry.TaskPath -TaskName $entry.TaskName -ErrorAction Stop | Out-Null
            Write-Host ('  Disabled: ' + $ap.FullPath) -ForegroundColor Green
            $disabled++
        } catch {
            Write-Host ('  FAILED:   ' + $ap.FullPath + ' — ' + $_.Exception.Message) -ForegroundColor Red
        }
    }
    Write-Host ''
    Write-Host ('Disabled ' + $disabled + '/' + $toDisableCount + ' task(s).') -ForegroundColor Cyan
}

# Phase 4 — Cleanup stale tasks
if (-not $SkipCleanup) {
    Write-Host ''
    Write-Host 'Cleaning up stale tasks...' -ForegroundColor Yellow
    $cleaned = 0
    foreach ($st in $staleTasks) {
        $fullPath = $st.TaskPath + $st.TaskName
        try {
            $task = Get-ScheduledTask -TaskPath $st.TaskPath -TaskName $st.TaskName -ErrorAction SilentlyContinue
            if ($task) {
                Unregister-ScheduledTask -TaskPath $st.TaskPath -TaskName $st.TaskName -Confirm:$false -ErrorAction Stop
                Write-Host ('  Removed: ' + $fullPath + ' (' + $st.Reason + ')') -ForegroundColor Green
                $cleaned++
            } else {
                Write-Host ('  Not found: ' + $fullPath) -ForegroundColor Gray
            }
        } catch {
            Write-Host ('  FAILED: ' + $fullPath + ' — ' + $_.Exception.Message) -ForegroundColor Red
        }
    }
    Write-Host ('Cleaned ' + $cleaned + ' stale task(s).') -ForegroundColor Cyan
}

# Phase 5 — Verification
Write-Host ''
Write-Host 'Verifying...' -ForegroundColor Yellow
$verified = 0
foreach ($td in $tasksToDisable) {
    $task = Get-ScheduledTask -TaskPath $td.TaskPath -TaskName $td.TaskName -ErrorAction SilentlyContinue
    if (-not $task) { continue }
    if ($task.State -eq 'Disabled') {
        $verified++
    } else {
        Write-Host ('  NOT disabled: ' + $td.TaskPath + $td.TaskName + ' (state=' + $task.State.ToString() + ')') -ForegroundColor Red
    }
}
$foundTasks = @($tasksToDisable | ForEach-Object {
    Get-ScheduledTask -TaskPath $_.TaskPath -TaskName $_.TaskName -ErrorAction SilentlyContinue
} | Where-Object { $_ })
Write-Host ('Verified: ' + $verified + '/' + $foundTasks.Count + ' target tasks are disabled.') -ForegroundColor Green

Write-Host ''
Write-Host 'Done. No reboot required.' -ForegroundColor Cyan
Write-Host 'Rollback: .\fix_scheduled_tasks.ps1 -Restore' -ForegroundColor DarkGray
