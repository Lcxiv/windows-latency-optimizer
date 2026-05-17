#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Analyze WPR traces captured with task-scheduler.wprp for task + GPU correlation.
.DESCRIPTION
    Post-processes ETL traces to extract Task Scheduler events, correlate with
    DPC/ISR data, CPU usage, disk I/O, and GPU activity. Produces a ranked
    impact report showing which scheduled tasks affected gaming latency.
.PARAMETER EtlFile
    Path to the .etl trace file captured with task-scheduler.wprp.
.PARAMETER OutDir
    Output directory for analysis results. Defaults to same dir as ETL file.
.NOTES
    Requires: xperf.exe (Windows ADK / Windows Performance Toolkit)
    Capture: wpr -start .\scripts\task-scheduler.wprp -filemode
             (play game 2-5 min)
             wpr -stop trace.etl "Task+GPU gaming trace"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$EtlFile,
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent

# Dot-source config for tool paths
. "$PSScriptRoot\config.ps1"

if (-not (Test-Path $EtlFile)) {
    Write-Host ('ETL file not found: ' + $EtlFile) -ForegroundColor Red
    exit 1
}

if (-not $OutDir) {
    $OutDir = Split-Path $EtlFile -Parent
}
if (-not (Test-Path $OutDir)) {
    New-Item -Path $OutDir -ItemType Directory -Force | Out-Null
}

$xperf = $script:ToolPaths.Xperf
if (-not $xperf) {
    # Fallback search
    $candidates = @(
        'C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\xperf.exe',
        'C:\Program Files\Windows Kits\10\Windows Performance Toolkit\xperf.exe'
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $xperf = $c; break }
    }
}
if (-not $xperf -or -not (Test-Path $xperf)) {
    Write-Host 'xperf.exe not found. Install Windows Performance Toolkit (part of Windows ADK).' -ForegroundColor Red
    exit 1
}

Write-Host '=== Task + GPU Trace Analysis ===' -ForegroundColor Cyan
Write-Host ('ETL: ' + $EtlFile) -ForegroundColor Gray
Write-Host ''

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

# ─── Phase 1: Extract events from ETL ────────────────────────────────────────
Write-Host 'Phase 1: Extracting events from ETL...' -ForegroundColor Yellow

# DPC/ISR summary
$dpcFile = Join-Path $OutDir ('dpcisr_' + $timestamp + '.txt')
Write-Host '  Extracting DPC/ISR summary...' -ForegroundColor Gray
try {
    $dpcArgs = @('-i', $EtlFile, '-a', 'dpcisr', '-o', $dpcFile)
    & $xperf @dpcArgs 2>&1 | Out-Null
    $hasDpc = Test-Path $dpcFile
    if ($hasDpc) {
        Write-Host ('  DPC/ISR: ' + $dpcFile) -ForegroundColor Green
    }
} catch {
    Write-Host ('  DPC/ISR extraction failed: ' + $_.Exception.Message) -ForegroundColor Yellow
    $hasDpc = $false
}

# CPU usage by process
$cpuFile = Join-Path $OutDir ('cpu_process_' + $timestamp + '.txt')
Write-Host '  Extracting CPU usage by process...' -ForegroundColor Gray
try {
    $cpuArgs = @('-i', $EtlFile, '-a', 'process', '-o', $cpuFile)
    & $xperf @cpuArgs 2>&1 | Out-Null
    $hasCpu = Test-Path $cpuFile
    if ($hasCpu) {
        Write-Host ('  CPU: ' + $cpuFile) -ForegroundColor Green
    }
} catch {
    Write-Host ('  CPU extraction failed: ' + $_.Exception.Message) -ForegroundColor Yellow
    $hasCpu = $false
}

# Disk I/O
$diskFile = Join-Path $OutDir ('diskio_' + $timestamp + '.txt')
Write-Host '  Extracting disk I/O...' -ForegroundColor Gray
try {
    $diskArgs = @('-i', $EtlFile, '-a', 'diskio', '-o', $diskFile)
    & $xperf @diskArgs 2>&1 | Out-Null
    $hasDisk = Test-Path $diskFile
    if ($hasDisk) {
        Write-Host ('  Disk: ' + $diskFile) -ForegroundColor Green
    }
} catch {
    Write-Host ('  Disk I/O extraction failed: ' + $_.Exception.Message) -ForegroundColor Yellow
    $hasDisk = $false
}

# Generic events dump (for Task Scheduler provider)
$eventsFile = Join-Path $OutDir ('generic_events_' + $timestamp + '.csv')
Write-Host '  Extracting generic events (Task Scheduler + Kernel Process)...' -ForegroundColor Gray
try {
    $dumpArgs = @('-i', $EtlFile, '-o', $eventsFile, '-a', 'dumper')
    & $xperf @dumpArgs 2>&1 | Out-Null
    $hasEvents = Test-Path $eventsFile
    if ($hasEvents) {
        $eventSize = (Get-Item $eventsFile).Length / 1MB
        Write-Host ('  Events: ' + $eventsFile + ' (' + [math]::Round($eventSize, 1) + ' MB)') -ForegroundColor Green
    }
} catch {
    Write-Host ('  Event dump failed: ' + $_.Exception.Message) -ForegroundColor Yellow
    $hasEvents = $false
}
Write-Host ''

# ─── Phase 2: Parse Task Scheduler Events ────────────────────────────────────
Write-Host 'Phase 2: Parsing Task Scheduler events...' -ForegroundColor Yellow

$taskEvents = @()

if ($hasEvents) {
    # Read the events file and filter for Task Scheduler provider
    # Task Scheduler GUID: DE7B24EA-73C8-4A09-985D-5BDADCFA9017
    $taskSchedulerGuid = 'de7b24ea-73c8-4a09-985d-5bdadcfa9017'
    $kernelProcessGuid = '22fb2cd6-0e7b-422b-a0c7-2fad1fd0e716'

    $lineCount = 0
    $taskLineCount = 0
    $processLineCount = 0

    # Stream read — file can be very large
    $reader = [System.IO.StreamReader]::new($eventsFile)
    try {
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            $lineCount++

            if ($line.Contains($taskSchedulerGuid)) {
                $taskLineCount++
                # Parse: timestamp, provider, event ID, etc.
                $parts = $line -split ','
                if ($parts.Count -ge 4) {
                    $taskEvents += @{
                        RawLine   = $line
                        Timestamp = $parts[0].Trim()
                        Provider  = 'TaskScheduler'
                        EventData = ($parts[3..($parts.Count-1)] -join ',').Trim()
                    }
                }
            } elseif ($line.Contains($kernelProcessGuid)) {
                $processLineCount++
            }
        }
    } finally {
        $reader.Close()
    }

    Write-Host ('  Total event lines:     ' + $lineCount)
    Write-Host ('  Task Scheduler events: ' + $taskLineCount) -ForegroundColor $(if ($taskLineCount -gt 0) { 'Green' } else { 'Yellow' })
    Write-Host ('  Kernel Process events: ' + $processLineCount)
} else {
    Write-Host '  No events file available — skipping task parse.' -ForegroundColor Yellow
}
Write-Host ''

# ─── Phase 3: Parse DPC/ISR Summary ──────────────────────────────────────────
Write-Host 'Phase 3: Analyzing DPC/ISR impact...' -ForegroundColor Yellow

$dpcModules = @()
if ($hasDpc) {
    $dpcContent = Get-Content $dpcFile -ErrorAction SilentlyContinue
    $inTable = $false
    foreach ($line in $dpcContent) {
        if ($line -match '^\s*Module\s+') { $inTable = $true; continue }
        if ($line -match '^-+') { continue }
        if ($inTable -and $line.Trim().Length -gt 0) {
            # Parse xperf dpcisr table (space-delimited)
            $fields = $line.Trim() -split '\s{2,}'
            if ($fields.Count -ge 3) {
                $dpcModules += @{
                    Module   = $fields[0]
                    Count    = $fields[1]
                    TimeUsec = if ($fields.Count -ge 4) { $fields[3] } else { '0' }
                }
            }
        }
    }
    Write-Host ('  DPC modules found: ' + $dpcModules.Count) -ForegroundColor Green
} else {
    Write-Host '  No DPC data available.' -ForegroundColor Yellow
}
Write-Host ''

# ─── Phase 4: Parse Disk I/O ─────────────────────────────────────────────────
Write-Host 'Phase 4: Analyzing disk I/O...' -ForegroundColor Yellow

$diskStats = @{ TotalReads = 0; TotalWrites = 0; TotalReadBytes = 0; TotalWriteBytes = 0 }
if ($hasDisk) {
    $diskContent = Get-Content $diskFile -ErrorAction SilentlyContinue
    foreach ($line in $diskContent) {
        if ($line -match 'Total Read I/Os:\s+(\d+)') { $diskStats.TotalReads = [int]$Matches[1] }
        if ($line -match 'Total Write I/Os:\s+(\d+)') { $diskStats.TotalWrites = [int]$Matches[1] }
        if ($line -match 'Total Read Bytes:\s+(\d+)') { $diskStats.TotalReadBytes = [long]$Matches[1] }
        if ($line -match 'Total Write Bytes:\s+(\d+)') { $diskStats.TotalWriteBytes = [long]$Matches[1] }
    }
    Write-Host ('  Reads: ' + $diskStats.TotalReads + ' (' + [math]::Round($diskStats.TotalReadBytes / 1MB, 1) + ' MB)')
    Write-Host ('  Writes: ' + $diskStats.TotalWrites + ' (' + [math]::Round($diskStats.TotalWriteBytes / 1MB, 1) + ' MB)')
} else {
    Write-Host '  No disk I/O data available.' -ForegroundColor Yellow
}
Write-Host ''

# ─── Phase 5: Build Analysis Results ────────────────────────���────────────────
Write-Host 'Phase 5: Building analysis...' -ForegroundColor Yellow

$analysis = @{
    timestamp       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    etlFile         = $EtlFile
    taskEvents      = @{
        total              = $taskEvents.Count
        taskSchedulerCount = $taskLineCount
        kernelProcessCount = $processLineCount
    }
    dpcSummary      = @{
        moduleCount = $dpcModules.Count
        topModules  = @($dpcModules | Select-Object -First 10)
    }
    diskIo          = $diskStats
    recommendations = @()
}

# Generate recommendations
if ($taskLineCount -eq 0) {
    $analysis.recommendations += 'No Task Scheduler events captured. Either no tasks fired during the trace, or the provider was not enabled. Ensure task-scheduler.wprp was used.'
}

if ($taskLineCount -gt 50) {
    $analysis.recommendations += ('High task activity: ' + $taskLineCount + ' Task Scheduler events. Run fix_scheduled_tasks.ps1 to disable non-essential tasks during gaming.')
}

if ($diskStats.TotalReads -gt 10000) {
    $analysis.recommendations += ('Heavy disk reads: ' + $diskStats.TotalReads + ' I/Os (' + [math]::Round($diskStats.TotalReadBytes / 1MB, 1) + ' MB). Check if WU scan or Defender was running.')
}

# Save JSON
$jsonPath = Join-Path $OutDir ('task_trace_analysis_' + $timestamp + '.json')
$analysis | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding UTF8
Write-Host ('  JSON: ' + $jsonPath) -ForegroundColor Green

# ─── Phase 6: Console Summary ────────────────────────────────────────────────
Write-Host ''
Write-Host '═══════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host '  Trace Analysis Summary' -ForegroundColor Cyan
Write-Host '═══════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''
Write-Host ('  Task Scheduler events: ' + $taskLineCount) -ForegroundColor $(if ($taskLineCount -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ('  Kernel Process events: ' + $processLineCount)
Write-Host ('  DPC modules:           ' + $dpcModules.Count)
Write-Host ('  Disk reads:            ' + $diskStats.TotalReads + ' (' + [math]::Round($diskStats.TotalReadBytes / 1MB, 1) + ' MB)')
Write-Host ('  Disk writes:           ' + $diskStats.TotalWrites + ' (' + [math]::Round($diskStats.TotalWriteBytes / 1MB, 1) + ' MB)')

if ($dpcModules.Count -gt 0) {
    Write-Host ''
    Write-Host '  Top DPC Modules:' -ForegroundColor Yellow
    $top5 = @($dpcModules | Select-Object -First 5)
    foreach ($m in $top5) {
        Write-Host ('    ' + $m.Module + ': ' + $m.Count + ' calls') -ForegroundColor White
    }
}

if ($analysis.recommendations.Count -gt 0) {
    Write-Host ''
    Write-Host '  Recommendations:' -ForegroundColor Yellow
    foreach ($rec in $analysis.recommendations) {
        Write-Host ('    - ' + $rec) -ForegroundColor White
    }
}

Write-Host ''
Write-Host '  Next steps:' -ForegroundColor DarkGray
Write-Host '    1. Open ETL in WPA for visual timeline analysis' -ForegroundColor DarkGray
Write-Host '    2. Filter Generic Events by Microsoft-Windows-TaskScheduler' -ForegroundColor DarkGray
Write-Host '    3. Cross-reference task fire times with GPU Scheduling timeline' -ForegroundColor DarkGray
Write-Host ''

# Open WPA if available
$wpa = Get-Command 'wpa.exe' -ErrorAction SilentlyContinue
if ($wpa) {
    Write-Host '  WPA found. Open trace with:' -ForegroundColor DarkGray
    Write-Host ('    wpa.exe "' + $EtlFile + '"') -ForegroundColor Cyan
}

Write-Host ''
Write-Host 'Output files:' -ForegroundColor Green
Write-Host ('  ' + $jsonPath) -ForegroundColor White
if ($hasDpc)    { Write-Host ('  ' + $dpcFile) -ForegroundColor White }
if ($hasCpu)    { Write-Host ('  ' + $cpuFile) -ForegroundColor White }
if ($hasDisk)   { Write-Host ('  ' + $diskFile) -ForegroundColor White }
if ($hasEvents) { Write-Host ('  ' + $eventsFile) -ForegroundColor White }
Write-Host ''
Write-Host 'Done.' -ForegroundColor Cyan
