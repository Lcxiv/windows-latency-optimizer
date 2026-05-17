#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deep DPC analysis — per-CPU breakdown, temporal patterns, input gap correlation.
.DESCRIPTION
    Parses dpcisr_report.txt for per-CPU DPC distribution and temporal 1-second patterns.
    Optionally correlates with mouse input gaps from input_latency_analysis.json.
    Can launch GPUView capture for GPU-DPC visual correlation.
.EXAMPLE
    .\analyze-dpc-deep.ps1 -ReportFile captures\experiments\...\dpcisr_report.txt
    .\analyze-dpc-deep.ps1 -ReportFile ... -InputGapsJson captures\experiments\...\input_latency_analysis.json
    .\analyze-dpc-deep.ps1 -GpuViewCapture -DurationSec 15
#>
param(
    [string]$ReportFile = '',
    [string]$InputGapsJson = '',
    [string]$OutDir = '',
    [switch]$GpuViewCapture,
    [int]$DurationSec = 15
)

$ErrorActionPreference = 'Stop'

# --- GPUView Capture Mode ---
if ($GpuViewCapture) {
    Write-Host '=== GPUView Capture ===' -ForegroundColor Cyan
    $gpuViewDir = 'C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\GPUView'
    $logCmd = Join-Path $gpuViewDir 'log.cmd'
    if (-not (Test-Path $logCmd)) {
        Write-Host ('  GPUView not found at: ' + $gpuViewDir) -ForegroundColor Red
        Write-Host '  Install Windows ADK Windows Performance Toolkit' -ForegroundColor Yellow
        return
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $captureDir = Join-Path (Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent) ('captures\experiments\' + $timestamp + '_GPUVIEW')
    New-Item -Path $captureDir -ItemType Directory -Force | Out-Null

    Write-Host ('  Starting GPUView trace (' + $DurationSec + 's)...')
    Push-Location $gpuViewDir
    & $logCmd 2>&1 | Out-Null
    Write-Host '  Trace running. Reproduce the issue now...' -ForegroundColor Yellow
    Start-Sleep -Seconds $DurationSec
    Write-Host '  Stopping trace...'
    & $logCmd 2>&1 | Out-Null
    Pop-Location

    # Move Merged.etl to capture dir
    $mergedEtl = Join-Path $gpuViewDir 'Merged.etl'
    if (Test-Path $mergedEtl) {
        $destEtl = Join-Path $captureDir 'gpuview_trace.etl'
        Move-Item $mergedEtl $destEtl -Force
        Write-Host ('  Trace saved: ' + $destEtl) -ForegroundColor Green
        Write-Host ''
        Write-Host '  Open in GPUView:' -ForegroundColor Cyan
        Write-Host ('    "' + (Join-Path $gpuViewDir 'GPUView.exe') + '" "' + $destEtl + '"') -ForegroundColor Cyan
    } else {
        Write-Host '  ERROR: Merged.etl not found after capture' -ForegroundColor Red
    }
    return
}

# --- Deep DPC Analysis Mode ---
if ($ReportFile -eq '') {
    # Auto-find latest dpcisr_report.txt
    $expDir = Join-Path (Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent) 'captures\experiments'
    if (Test-Path $expDir) {
        $latestDir = Get-ChildItem $expDir -Directory | Sort-Object Name -Descending | Select-Object -First 1
        if ($latestDir) {
            $candidate = Join-Path $latestDir.FullName 'dpcisr_report.txt'
            if (Test-Path $candidate) { $ReportFile = $candidate }
        }
    }
    if ($ReportFile -eq '') {
        Write-Host 'No dpcisr_report.txt found. Run pipeline or diagnose-mouse.ps1 first.' -ForegroundColor Red
        return
    }
}

if ($OutDir -eq '') { $OutDir = Split-Path $ReportFile -Parent }

Write-Host '=== Deep DPC Analysis ===' -ForegroundColor Cyan
Write-Host ('  Report: ' + $ReportFile)
Write-Host ''

$result = [ordered]@{
    perCpuDpc    = @()
    topDrivers   = @()
    temporal     = @()
    correlation  = @()
}

$lines = Get-Content $ReportFile

# --- Stage A: Per-CPU DPC Distribution ---
Write-Host '[A] Per-CPU DPC distribution...' -ForegroundColor Yellow

$inCpuTable = $false
foreach ($line in $lines) {
    # Detect the per-CPU usage table (starts after "CPU Usage from 0 us to")
    if ($line -match 'CPU Usage from') { $inCpuTable = $true; continue }
    if ($line -match '^\s*CPU \d+ Usage') { continue }  # header row
    if ($line -match '^\s*usec\s+%') { continue }  # sub-header

    if ($inCpuTable -and $line -match ',\s+\S+$') {
        # Parse per-CPU columns: "   usec   %,   usec   %,   ..., Module"
        $parts = $line.Trim() -split ',\s*'
        if ($parts.Count -ge 17) {
            $moduleName = $parts[-1].Trim()
            $cpuData = @()
            for ($c = 0; $c -lt 16; $c++) {
                $cell = $parts[$c].Trim()
                if ($cell -match '(\d+)\s+([\d.]+)') {
                    $cpuData += @{ cpu = $c; usec = [int]$Matches[1]; pct = [double]$Matches[2] }
                }
            }
            if ($cpuData.Count -gt 0) {
                $totalUsec = 0
                foreach ($cd in $cpuData) { $totalUsec += $cd.usec }
                $result.perCpuDpc += @{
                    module   = $moduleName
                    totalUs  = $totalUsec
                    cpus     = $cpuData
                }
            }
        }
    }

    # End of CPU table at blank line or "Total ="
    if ($inCpuTable -and ($line -match '^\s*$' -or $line -match '^Total =')) {
        if ($line -match '^Total =') { $inCpuTable = $false }
    }
}

# Print top drivers by total DPC time
$sorted = $result.perCpuDpc | Sort-Object { $_.totalUs } -Descending
$result.topDrivers = @($sorted | Select-Object -First 10)

Write-Host ''
Write-Host '  Top DPC drivers by CPU time:' -ForegroundColor Green
foreach ($d in ($sorted | Select-Object -First 5)) {
    $cpuList = ''
    foreach ($cd in $d.cpus) {
        if ($cd.pct -gt 0.01) {
            $cpuList += 'CPU' + $cd.cpu + '(' + $cd.pct + '%) '
        }
    }
    Write-Host ('    ' + $d.module + ': ' + $d.totalUs + 'us total — ' + $cpuList)
}

# Show CPU heatmap summary
Write-Host ''
Write-Host '  Per-CPU DPC load:' -ForegroundColor Green
$cpuTotals = @()
for ($c = 0; $c -lt 16; $c++) {
    $total = 0
    foreach ($d in $result.perCpuDpc) {
        foreach ($cd in $d.cpus) {
            if ($cd.cpu -eq $c) { $total += $cd.usec }
        }
    }
    $cpuTotals += $total
    $bar = ''
    $barLen = [math]::Min(40, [math]::Max(1, [int]($total / 5000)))
    for ($b = 0; $b -lt $barLen; $b++) { $bar += '#' }
    $label = if ($c -lt 4) { 'Pref' } elseif ($c -lt 8) { 'GPU ' } else { 'Game' }
    Write-Host ('    CPU' + $c.ToString().PadLeft(2) + ' [' + $label + '] ' + $bar + ' ' + $total + 'us')
}

# --- Stage B: Per-Module Histogram Detail ---
Write-Host ''
Write-Host '[B] Driver DPC latency histogram...' -ForegroundColor Yellow

$currentModule = ''
$moduleHistograms = @{}
foreach ($line in $lines) {
    if ($line -match 'Total = (\d+) for module (\S+)') {
        $currentModule = $Matches[2]
        $moduleHistograms[$currentModule] = @{ total = [int]$Matches[1]; buckets = @(); maxUs = 0; highLat = 0 }
    }
    if ($line -match '^Total,') {
        $currentModule = ''
    } elseif ($currentModule -ne '' -and $line -match 'Elapsed Time.*<=\s+(\d+) usecs,\s+(\d+),') {
        $bucket = [int]$Matches[1]
        $count  = [int]$Matches[2]
        if ($count -gt 0) {
            $moduleHistograms[$currentModule].buckets += @{ maxUs = $bucket; count = $count }
            if ($bucket -gt $moduleHistograms[$currentModule].maxUs) {
                $moduleHistograms[$currentModule].maxUs = $bucket
            }
            if ($bucket -ge 512) {
                $moduleHistograms[$currentModule].highLat += $count
            }
        }
    }
}

foreach ($mod in ($moduleHistograms.Keys | Sort-Object { $moduleHistograms[$_].maxUs } -Descending | Select-Object -First 5)) {
    $h = $moduleHistograms[$mod]
    Write-Host ('  ' + $mod + ': ' + $h.total + ' DPCs, max bucket ' + $h.maxUs + 'us')
    foreach ($b in $h.buckets) {
        $pct = [math]::Round($b.count * 100.0 / $h.total, 1)
        $bar = ''
        $barLen = [math]::Min(30, [math]::Max(1, [int]($pct / 2)))
        for ($i = 0; $i -lt $barLen; $i++) { $bar += '=' }
        Write-Host ('    <=' + $b.maxUs.ToString().PadLeft(6) + 'us: ' + $b.count.ToString().PadLeft(6) + ' (' + $pct.ToString().PadLeft(5) + '%) ' + $bar)
    }
}

# --- Stage C: Correlate with Input Gaps ---
if ($InputGapsJson -eq '') {
    $candidate = Join-Path $OutDir 'input_latency_analysis.json'
    if (Test-Path $candidate) { $InputGapsJson = $candidate }
}

if ($InputGapsJson -ne '' -and (Test-Path $InputGapsJson)) {
    Write-Host ''
    Write-Host '[C] Correlating with mouse input gaps...' -ForegroundColor Yellow
    $content = Get-Content $InputGapsJson -Raw
    $clean = $content -replace '^\xEF\xBB\xBF',''
    $analysis = $clean | ConvertFrom-Json

    if ($analysis.mouseInputGaps -and $analysis.mouseInputGaps.gapCount -gt 0) {
        $gaps = $analysis.mouseInputGaps.gaps
        Write-Host ('  Found ' + $analysis.mouseInputGaps.gapCount + ' input gaps')

        # Group gaps by severity
        $minor   = @($gaps | Where-Object { $_.gapMs -lt 10 })
        $medium  = @($gaps | Where-Object { $_.gapMs -ge 10 -and $_.gapMs -lt 50 })
        $severe  = @($gaps | Where-Object { $_.gapMs -ge 50 -and $_.gapMs -lt 200 })
        $extreme = @($gaps | Where-Object { $_.gapMs -ge 200 })

        Write-Host ''
        Write-Host '  Gap severity breakdown:' -ForegroundColor Green
        Write-Host ('    Minor   (4-10ms):   ' + $minor.Count)
        Write-Host ('    Medium  (10-50ms):  ' + $medium.Count)
        Write-Host ('    Severe  (50-200ms): ' + $severe.Count)
        Write-Host ('    Extreme (>200ms):   ' + $extreme.Count)

        # Show worst gaps with timestamps
        Write-Host ''
        Write-Host '  Worst input gaps:' -ForegroundColor Red
        $worstGaps = @($gaps | Sort-Object { $_.gapMs } -Descending | Select-Object -First 10)
        foreach ($g in $worstGaps) {
            $timeStr = [math]::Round($g.timestampUs / 1000000.0, 2).ToString() + 's'
            Write-Host ('    ' + $g.gapMs.ToString().PadLeft(8) + 'ms at t=' + $timeStr + ' — blamed: ' + $g.blamedDriver)
        }

        $result.correlation = @{
            totalGaps = $analysis.mouseInputGaps.gapCount
            minor     = $minor.Count
            medium    = $medium.Count
            severe    = $severe.Count
            extreme   = $extreme.Count
            worstGaps = $worstGaps
        }
    } else {
        Write-Host '  No input gaps found in analysis' -ForegroundColor Green
    }
} else {
    Write-Host ''
    Write-Host '[C] No input_latency_analysis.json found — skipping gap correlation' -ForegroundColor Yellow
}

# --- Save Results ---
Write-Host ''
$jsonPath = Join-Path $OutDir 'dpc_deep_analysis.json'
($result | ConvertTo-Json -Depth 8) | Out-File -FilePath $jsonPath -Encoding UTF8
Write-Host ('Results: ' + $jsonPath) -ForegroundColor Green

# --- Recommendations ---
Write-Host ''
Write-Host '=== RECOMMENDATIONS ===' -ForegroundColor Cyan

$nvDpc = $moduleHistograms['nvlddmkm.sys']
if ($nvDpc -and $nvDpc.maxUs -ge 128) {
    Write-Host ('  1. nvlddmkm.sys DPCs reaching ' + $nvDpc.maxUs + 'us — check:') -ForegroundColor Yellow
    Write-Host '     - MSI interrupts enabled (exp21_msi_gpu_clocks.ps1)'
    Write-Host '     - HAGS disabled (exp20_disable_hags.ps1)'
    Write-Host '     - GPU clocks locked (nvidia-smi -lgc)'
}

# Check if GPU DPCs are concentrated on few CPUs
$gpuCpus = @()
foreach ($d in $result.perCpuDpc) {
    if ($d.module -eq 'nvlddmkm.sys') {
        foreach ($cd in $d.cpus) {
            if ($cd.usec -gt 10000) { $gpuCpus += $cd.cpu }
        }
    }
}
if ($gpuCpus.Count -gt 0 -and $gpuCpus.Count -le 4) {
    Write-Host ('  2. GPU DPCs concentrated on CPUs: ' + ($gpuCpus -join ', ') + ' — affinity working correctly') -ForegroundColor Green
} elseif ($gpuCpus.Count -gt 4) {
    Write-Host ('  2. GPU DPCs spread across ' + $gpuCpus.Count + ' CPUs — consider tighter affinity') -ForegroundColor Yellow
}

Write-Host ''
Write-Host '  For visual analysis, run:' -ForegroundColor Cyan
Write-Host '    .\scripts\analyze-dpc-deep.ps1 -GpuViewCapture -DurationSec 15'
Write-Host '  Then open the trace in GPUView to see GPU queue depth + DPC overlay.'
Write-Host ''
Write-Host 'Done.' -ForegroundColor Cyan
