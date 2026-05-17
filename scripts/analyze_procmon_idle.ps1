#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Capture and analyze ProcMon idle system I/O with CLI noise exclusion.
.DESCRIPTION
    Runs a 30-second ProcMon capture, exports to CSV, then analyzes with
    automatic exclusion of Claude Code processes (claude.exe, bash.exe,
    node.exe, python*.exe, conhost.exe, powershell.exe, cmd.exe, cat.exe,
    dirname.exe, Procmon64.exe, sentry-*).

    Reports: per-process event rates, svchost service breakdown, top registry
    paths, top file I/O paths, and comparison against baseline.
.PARAMETER CsvPath
    Analyze an existing CSV instead of capturing new data.
.PARAMETER DurationSec
    Capture duration in seconds (default 30).
.PARAMETER Label
    Label for the capture directory.
.PARAMETER SkipCapture
    Skip capture, only analyze existing CSV at CsvPath.
.NOTES
    ProcMon location: C:\Users\L\Desktop\ProcessMonitor\Procmon64.exe
    Baseline: 8,512 events/sec (2026-04-27 pre-fix)
#>

param(
    [string]$CsvPath,
    [int]$DurationSec = 30,
    [string]$Label = 'idle_analysis',
    [switch]$SkipCapture
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$procmon = 'C:\Users\L\Desktop\ProcessMonitor\Procmon64.exe'

# Noise processes to exclude from analysis
$noiseProcesses = @(
    'claude.exe', 'Procmon64.exe', 'bash.exe', 'node.exe',
    'python3.exe', 'python.exe', 'conhost.exe', 'powershell.exe',
    'cmd.exe', 'cat.exe', 'dirname.exe', 'uname.exe', 'git.exe',
    'env.exe', 'tr.exe', 'wc.exe', 'sed.exe', 'grep.exe', 'awk.exe'
)

# ─── Capture ─────────────────────────────────────────────────────────────────
if (-not $SkipCapture) {
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $captureDir = Join-Path $projectRoot ('captures\experiments\' + $ts + '_' + $Label)
    New-Item -ItemType Directory -Path $captureDir -Force | Out-Null

    $pmlPath = Join-Path $captureDir 'procmon.pml'
    $CsvPath = Join-Path $captureDir 'procmon.csv'

    # Kill existing ProcMon
    Stop-Process -Name Procmon64 -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    Write-Host ('Capturing ' + $DurationSec + ' seconds of idle activity...') -ForegroundColor Cyan
    & $procmon /Quiet /Minimized /BackingFile $pmlPath
    Start-Sleep -Seconds $DurationSec
    & $procmon /Terminate
    Write-Host 'Capture complete. Exporting CSV...' -ForegroundColor Gray
    Start-Sleep -Seconds 5

    # Export to CSV
    & $procmon /Quiet /OpenLog $pmlPath /SaveAs $CsvPath
    Start-Sleep -Seconds 15
    Stop-Process -Name Procmon64 -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $CsvPath)) {
        Write-Host 'ERROR: CSV export failed.' -ForegroundColor Red
        return
    }
    $csvSize = [math]::Round((Get-Item $CsvPath).Length / 1MB, 1)
    Write-Host ('CSV exported: ' + $CsvPath + ' (' + $csvSize + ' MB)') -ForegroundColor Green
}

if (-not $CsvPath -or -not (Test-Path $CsvPath)) {
    Write-Host 'ERROR: No CSV path specified or file not found.' -ForegroundColor Red
    return
}

# ─── Parse ───────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '=== ANALYZING ===' -ForegroundColor Cyan

$reader = [System.IO.StreamReader]::new($CsvPath)
$header = $reader.ReadLine()

$totalEvents = 0
$noiseEvents = 0
$processCounts = @{}
$svchostPids = @{}
$systemOps = @{}
$systemPaths = @{}
$regPaths = @{}  # per-process registry path grouping

while ($null -ne ($line = $reader.ReadLine())) {
    $totalEvents++
    $fields = $line.Split(',')
    if ($fields.Count -lt 5) { continue }

    $proc = $fields[1].Trim('"')
    $procId = $fields[2].Trim('"')
    $op = $fields[3].Trim('"')
    $path = $fields[4].Trim('"')

    # Check noise
    $isNoise = $false
    foreach ($n in $noiseProcesses) {
        if ($proc -eq $n) { $isNoise = $true; break }
    }
    if ($proc.StartsWith('sentry-')) { $isNoise = $true }

    if ($isNoise) {
        $noiseEvents++
        continue
    }

    # Process counts
    if ($processCounts.ContainsKey($proc)) { $processCounts[$proc]++ } else { $processCounts[$proc] = 1 }

    # svchost by PID
    if ($proc -eq 'svchost.exe') {
        if ($svchostPids.ContainsKey($procId)) { $svchostPids[$procId]++ } else { $svchostPids[$procId] = 1 }
    }

    # System kernel breakdown
    if ($proc -eq 'System') {
        if ($systemOps.ContainsKey($op)) { $systemOps[$op]++ } else { $systemOps[$op] = 1 }
        if ($path.Length -gt 3) {
            $parts = $path.Split('\')
            $groupKey = if ($parts.Count -gt 3) { $parts[0] + '\' + $parts[1] + '\' + $parts[2] } else { $path }
            if ($systemPaths.ContainsKey($groupKey)) { $systemPaths[$groupKey]++ } else { $systemPaths[$groupKey] = 1 }
        }
    }

    # Registry path tracking for high-volume processes
    if ($op.StartsWith('Reg') -and $path.StartsWith('HK')) {
        $regKey = $proc + '|' + $path.Split('\')[0..3] -join '\'
        if ($regPaths.ContainsKey($regKey)) { $regPaths[$regKey]++ } else { $regPaths[$regKey] = 1 }
    }
}
$reader.Close()

$cleanEvents = $totalEvents - $noiseEvents
$totalPerSec = [math]::Round($totalEvents / $DurationSec, 0)
$noisePerSec = [math]::Round($noiseEvents / $DurationSec, 0)
$cleanPerSec = [math]::Round($cleanEvents / $DurationSec, 0)

# ─── Report ──────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '=== SUMMARY ===' -ForegroundColor Cyan
Write-Host ('  Total events:   {0,10:N0}  ({1,6:N0}/sec)' -f $totalEvents, $totalPerSec)
Write-Host ('  CLI noise:      {0,10:N0}  ({1,6:N0}/sec)  [excluded]' -f $noiseEvents, $noisePerSec)
Write-Host ('  System events:  {0,10:N0}  ({1,6:N0}/sec)' -f $cleanEvents, $cleanPerSec)
Write-Host ('  Baseline:                    8,512/sec')
$deltaStr = if ($cleanPerSec -lt 8512) { '-' + [math]::Round((1 - $cleanPerSec/8512) * 100, 1) + '%' } else { '+' + [math]::Round(($cleanPerSec/8512 - 1) * 100, 1) + '%' }
Write-Host ('  Delta:                       ' + $deltaStr)
Write-Host ''

Write-Host '=== TOP PROCESSES (noise excluded) ===' -ForegroundColor Yellow
$processCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20 | ForEach-Object {
    $perSec = [math]::Round($_.Value / $DurationSec, 1)
    Write-Host ('{0,-35} {1,8} events ({2,8}/sec)' -f $_.Key, $_.Value, $perSec)
}

Write-Host ''
Write-Host '=== SVCHOST SERVICE BREAKDOWN ===' -ForegroundColor Yellow
$svchostPids.GetEnumerator() | Sort-Object Value -Descending | Where-Object { $_.Value -gt ($DurationSec * 2) } | ForEach-Object {
    $svcNames = (Get-WmiObject Win32_Service -Filter ('ProcessId=' + $_.Key) -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) -join ', '
    $perSec = [math]::Round($_.Value / $DurationSec, 1)
    Write-Host ('PID {0,-6} {1,8} events ({2,7}/sec)  {3}' -f $_.Key, $_.Value, $perSec, $svcNames)
}

Write-Host ''
Write-Host '=== SYSTEM KERNEL (PID 4) TOP OPERATIONS ===' -ForegroundColor Yellow
$systemOps.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10 | ForEach-Object {
    $perSec = [math]::Round($_.Value / $DurationSec, 1)
    Write-Host ('{0,-45} {1,8} ({2,7}/sec)' -f $_.Key, $_.Value, $perSec)
}

Write-Host ''
Write-Host '=== SYSTEM KERNEL TOP PATHS ===' -ForegroundColor Yellow
$systemPaths.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10 | ForEach-Object {
    Write-Host ('{0,-60} {1,8}' -f $_.Key, $_.Value)
}

Write-Host ''
Write-Host '=== TOP REGISTRY POLLING PATHS (all processes) ===' -ForegroundColor Yellow
$regPaths.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 15 | ForEach-Object {
    $parts = $_.Key.Split('|')
    $perSec = [math]::Round($_.Value / $DurationSec, 1)
    Write-Host ('{0,-25} {1,-50} {2,6}/sec' -f $parts[0], $parts[1], $perSec)
}

Write-Host ''
Write-Host '=== VERDICT ===' -ForegroundColor Cyan
if ($cleanPerSec -lt 3000) {
    Write-Host ('  PASS: {0:N0}/sec < 3,000/sec target' -f $cleanPerSec) -ForegroundColor Green
} elseif ($cleanPerSec -lt 5000) {
    Write-Host ('  WARN: {0:N0}/sec — above 3,000 target but under 5,000' -f $cleanPerSec) -ForegroundColor Yellow
} else {
    Write-Host ('  FAIL: {0:N0}/sec — significantly above 3,000/sec target' -f $cleanPerSec) -ForegroundColor Red
}

Write-Host ''
Write-Host ('Report complete. CSV: ' + $CsvPath) -ForegroundColor Gray
