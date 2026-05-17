<#
.SYNOPSIS
    Daily registry watchdog analysis. Takes fresh snapshot, analyzes drift
    trends across all historical snapshots, writes findings to memory.
.DESCRIPTION
    Scheduled to run daily at 9 AM via Task Scheduler.
    1. Runs boot_registry_watchdog.ps1 for fresh snapshot
    2. Reads all snapshots + diffs for trend analysis
    3. Identifies unstable keys (changed >1 time)
    4. Writes/appends to drift log in project memory
.OUTPUTS
    Updates: memory\project_registry_drift_log.md
#>
param(
    [string]$WatchdogDir = '',
    [string]$MemoryDir = ''
)

$ErrorActionPreference = 'Continue'
$projectRoot = 'C:\Users\L\Desktop\windows-latency-optimizer'
$memoryRoot = 'C:\Users\L\.claude\projects\C--Users-L-Desktop-windows-latency-optimizer\memory'

if ($WatchdogDir -eq '') { $WatchdogDir = Join-Path $projectRoot 'captures\registry_watchdog' }
if ($MemoryDir -eq '') { $MemoryDir = $memoryRoot }

$today = Get-Date -Format 'yyyy-MM-dd'
$now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

# --- 1. Take fresh snapshot ---
$watchdogScript = Join-Path $projectRoot 'scripts\boot_registry_watchdog.ps1'
if (Test-Path $watchdogScript) {
    & $watchdogScript -AlertFile (Join-Path ([Environment]::GetFolderPath('Desktop')) 'REGISTRY_DRIFT.txt')
}

# --- 2. Analyze all snapshots for trends ---
$snapshots = Get-ChildItem $WatchdogDir -Filter 'snapshot_*.json' | Sort-Object Name
$diffs = Get-ChildItem $WatchdogDir -Filter 'diff_*.json' -ErrorAction SilentlyContinue | Sort-Object Name

$totalSnapshots = $snapshots.Count
$totalDiffs = 0
if ($diffs) { $totalDiffs = $diffs.Count }

# Count per-key change frequency across all diffs
$keyChangeCounts = @{}
$keyLastValues = @{}
if ($diffs) {
    foreach ($df in $diffs) {
        try {
            $diffData = Get-Content $df.FullName -Raw | ConvertFrom-Json
            foreach ($change in $diffData.changes) {
                $k = $change.key
                if (-not $keyChangeCounts.ContainsKey($k)) { $keyChangeCounts[$k] = 0 }
                $keyChangeCounts[$k] = [int]$keyChangeCounts[$k] + 1
                $keyLastValues[$k] = $change.current
            }
        } catch {}
    }
}

# Identify unstable keys (changed >1 time)
$unstableKeys = @()
foreach ($k in $keyChangeCounts.Keys) {
    if ([int]$keyChangeCounts[$k] -gt 1) {
        $unstableKeys += @{ key = $k; changes = $keyChangeCounts[$k]; lastValue = $keyLastValues[$k] }
    }
}

# Latest diff details
$latestDiffSummary = 'none'
$latestDiffCount = 0
if ($diffs -and $diffs.Count -gt 0) {
    $latestDf = $diffs | Select-Object -Last 1
    try {
        $latestDiffData = Get-Content $latestDf.FullName -Raw | ConvertFrom-Json
        $latestDiffCount = $latestDiffData.changeCount
        if ($latestDiffCount -gt 0) {
            $names = ($latestDiffData.changes | ForEach-Object { $_.key }) -join ', '
            $latestDiffSummary = $latestDiffCount.ToString() + ' change(s): ' + $names
        } else {
            $latestDiffSummary = 'clean'
        }
    } catch {
        $latestDiffSummary = 'parse error'
    }
}

# --- 3. Write to memory drift log ---
$logPath = Join-Path $MemoryDir 'project_registry_drift_log.md'

# Create file with header if not exists
if (-not (Test-Path $logPath)) {
    $header = @(
        '# Registry Drift Log'
        ''
        'Daily watchdog analysis. Tracks registry changes that affect gaming latency.'
        'Unstable keys (changed >1 time across boots) indicate OS/driver reset behavior.'
        ''
        '## Daily Entries'
        ''
    )
    $header | Set-Content -Path $logPath -Encoding UTF8
}

# Append today's entry
$entry = @()
$entry += ('### ' + $today)
$entry += ''
$entry += ('- **Snapshots total**: ' + $totalSnapshots)
$entry += ('- **Diffs total**: ' + $totalDiffs)
$entry += ('- **Latest diff**: ' + $latestDiffSummary)

if ($unstableKeys.Count -gt 0) {
    $entry += ('- **Unstable keys** (' + $unstableKeys.Count + '):')
    foreach ($uk in $unstableKeys) {
        $entry += ('  - `' + $uk.key + '` changed ' + $uk.changes + 'x (last: ' + $uk.lastValue + ')')
    }
} else {
    $entry += '- **Unstable keys**: none'
}

$verdict = 'CLEAN'
if ($latestDiffCount -gt 0 -and $latestDiffSummary -notmatch 'defender') {
    $verdict = 'DRIFT'
} elseif ($latestDiffCount -gt 0) {
    $verdict = 'CLEAN (defender timing only)'
}
$entry += ('- **Verdict**: ' + $verdict)
$entry += ''

# Append (avoid duplicating today's entry)
$existing = Get-Content $logPath -Raw -ErrorAction SilentlyContinue
if ($existing -notmatch ('### ' + $today)) {
    Add-Content -Path $logPath -Value $entry -Encoding UTF8
}

Write-Host ('[watchdog-daily] ' + $now + ' — ' + $verdict + ' (' + $totalSnapshots + ' snapshots, ' + $totalDiffs + ' diffs)')
if ($unstableKeys.Count -gt 0) {
    Write-Host ('  Unstable keys:')
    foreach ($uk in $unstableKeys) {
        Write-Host ('    ' + $uk.key + ' (' + $uk.changes + 'x)')
    }
}
