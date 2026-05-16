<#
.SYNOPSIS
    Analyze one or more CapFrameX .json captures and emit a side-by-side
    frame-timing comparison table.
.DESCRIPTION
    CapFrameX writes the full frame-time series under Runs[].CaptureData.
    This script computes FPS averages, percentile frame times, 1% + 0.1%
    low FPS, stutter score (P99/P50 frame time ratio), PresentMon-derived
    GPU + CPU active %, and PcLatency when available. Designed for
    quick A/B comparisons across captures taken before/after a tweak.
.PARAMETER CaptureDir
    Folder containing CapFrameX .json files. Defaults to the CapFrameX
    default location under the current user's Documents folder.
.PARAMETER Files
    Explicit file paths (absolute). Overrides CaptureDir enumeration.
.EXAMPLE
    .\analyze_capframex.ps1
.EXAMPLE
    .\analyze_capframex.ps1 -Files @('C:\...\cap1.json','C:\...\cap2.json')
#>
[CmdletBinding()]
param(
    [string]$CaptureDir = (Join-Path $env:USERPROFILE 'Documents\CapFrameX\Captures'),
    [string[]]$Files
)

$ErrorActionPreference = 'Stop'

function Get-Percentile {
    param([double[]]$Values, [double]$Pct)
    if ($Values.Count -eq 0) { return $null }
    $sorted = $Values | Sort-Object
    $idx = [int][Math]::Floor(($Pct / 100.0) * ($sorted.Count - 1))
    if ($idx -lt 0) { $idx = 0 }
    if ($idx -ge $sorted.Count) { $idx = $sorted.Count - 1 }
    return $sorted[$idx]
}

function Get-LowFps {
    param([double[]]$FrameTimesMs, [double]$Pct)
    if ($FrameTimesMs.Count -eq 0) { return $null }
    $sortedDesc = $FrameTimesMs | Sort-Object -Descending
    $count = [int][Math]::Ceiling(($Pct / 100.0) * $sortedDesc.Count)
    if ($count -lt 1) { $count = 1 }
    $slice = $sortedDesc[0..($count - 1)]
    $avgMs = ($slice | Measure-Object -Average).Average
    if ($avgMs -le 0) { return $null }
    return 1000.0 / $avgMs
}

function Get-Stdev {
    param([double[]]$Values)
    if ($Values.Count -lt 2) { return 0 }
    $mean = ($Values | Measure-Object -Average).Average
    $sumSq = 0.0
    foreach ($v in $Values) { $sumSq += [Math]::Pow($v - $mean, 2) }
    return [Math]::Sqrt($sumSq / ($Values.Count - 1))
}

function Analyze-Capture {
    param([string]$Path)

    $j = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $run = $j.Runs[0]
    $cd = $run.CaptureData

    $ft = [double[]]($cd.MsBetweenPresents | Where-Object { $_ -gt 0 })
    $tSec = [double[]]$cd.TimeInSeconds
    $dropped = ($cd.Dropped | Where-Object { $_ -eq $true }).Count
    $gpuActive = $null; $cpuActive = $null
    if ($cd.GpuActive) { $gpuActive = [double[]]$cd.GpuActive }
    if ($cd.CpuActive) { $cpuActive = [double[]]$cd.CpuActive }
    $pcLatency = $null
    if ($cd.PcLatency) { $pcLatency = [double[]]($cd.PcLatency | Where-Object { $_ -gt 0 }) }

    $duration = 0.0
    if ($tSec.Count -gt 0) { $duration = $tSec[-1] - $tSec[0] }

    $avgFt = ($ft | Measure-Object -Average).Average
    $medianFt = Get-Percentile -Values $ft -Pct 50
    $p95Ft = Get-Percentile -Values $ft -Pct 95
    $p99Ft = Get-Percentile -Values $ft -Pct 99
    $p999Ft = Get-Percentile -Values $ft -Pct 99.9
    $maxFt = ($ft | Measure-Object -Maximum).Maximum
    $stdFt = Get-Stdev -Values $ft

    $avgFps = 0
    if ($avgFt -gt 0) { $avgFps = 1000.0 / $avgFt }
    $low1 = Get-LowFps -FrameTimesMs $ft -Pct 1
    $low01 = Get-LowFps -FrameTimesMs $ft -Pct 0.1

    $stutterScore = $null
    if ($medianFt -gt 0) { $stutterScore = $p99Ft / $medianFt }

    # Hitches: frames > 2x median (canonical stutter threshold)
    $hitchThreshold = 2.0 * $medianFt
    $hitches = ($ft | Where-Object { $_ -gt $hitchThreshold }).Count
    $hitchPct = 0.0
    if ($ft.Count -gt 0) { $hitchPct = 100.0 * $hitches / $ft.Count }

    $avgGpuActive = $null
    if ($gpuActive -and $gpuActive.Count -gt 0) { $avgGpuActive = ($gpuActive | Measure-Object -Average).Average }
    $avgCpuActive = $null
    if ($cpuActive -and $cpuActive.Count -gt 0) { $avgCpuActive = ($cpuActive | Measure-Object -Average).Average }
    $avgPcLat = $null; $p99PcLat = $null
    if ($pcLatency -and $pcLatency.Count -gt 0) {
        $avgPcLat = ($pcLatency | Measure-Object -Average).Average
        $p99PcLat = Get-Percentile -Values $pcLatency -Pct 99
    }

    # Pre-compute nullable rounded values (PS 5.1 doesn't allow if/else inside hashtable literals)
    $avgGpuR = $null
    if ($null -ne $avgGpuActive) { $avgGpuR = [Math]::Round($avgGpuActive, 1) }
    $avgCpuR = $null
    if ($null -ne $avgCpuActive) { $avgCpuR = [Math]::Round($avgCpuActive, 1) }
    $avgPcR = $null
    if ($null -ne $avgPcLat) { $avgPcR = [Math]::Round($avgPcLat, 2) }
    $p99PcR = $null
    if ($null -ne $p99PcLat) { $p99PcR = [Math]::Round($p99PcLat, 2) }

    [PSCustomObject]@{
        File               = Split-Path -Leaf $Path
        CreationDate       = $j.Info.CreationDate
        GPU                = $j.Info.GPU
        CPU                = $j.Info.Processor
        Resolution         = $j.Info.ResolutionInfo
        PresentationMode   = $j.Info.PresentationMode
        WinGameMode        = $j.Info.WinGameMode
        HAGS               = $j.Info.HAGS
        ResizableBar       = $j.Info.ResizableBar
        DriverVersion      = $j.Info.GPUDriverVersion
        Api                = $j.Info.ApiInfo
        Comment            = $j.Info.Comment
        Frames             = $ft.Count
        DurationSec        = [Math]::Round($duration, 2)
        AvgFps             = [Math]::Round($avgFps, 1)
        Low1pctFps         = [Math]::Round($low1, 1)
        Low0_1pctFps       = [Math]::Round($low01, 1)
        AvgFtMs            = [Math]::Round($avgFt, 3)
        MedianFtMs         = [Math]::Round($medianFt, 3)
        P95FtMs            = [Math]::Round($p95Ft, 3)
        P99FtMs            = [Math]::Round($p99Ft, 3)
        P999FtMs           = [Math]::Round($p999Ft, 3)
        MaxFtMs            = [Math]::Round($maxFt, 3)
        StdFtMs            = [Math]::Round($stdFt, 3)
        StutterScore       = [Math]::Round($stutterScore, 2)
        Hitches_gt2xMedian = $hitches
        HitchPct           = [Math]::Round($hitchPct, 3)
        Dropped            = $dropped
        AvgGpuActivePct    = $avgGpuR
        AvgCpuActivePct    = $avgCpuR
        AvgPcLatMs         = $avgPcR
        P99PcLatMs         = $p99PcR
    }
}

# Collect target files
if (-not $Files -or $Files.Count -eq 0) {
    if (-not (Test-Path $CaptureDir)) {
        Write-Error "CaptureDir not found: $CaptureDir"
        exit 1
    }
    $Files = @(Get-ChildItem -LiteralPath $CaptureDir -Filter '*.json' -File | Sort-Object LastWriteTime | ForEach-Object { $_.FullName })
}

if ($Files.Count -eq 0) {
    Write-Error 'No CapFrameX .json captures located.'
    exit 1
}

Write-Host ('=== CapFrameX Analysis: ' + $Files.Count + ' capture(s) ===') -ForegroundColor Cyan
Write-Host ''

$results = foreach ($f in $Files) { Analyze-Capture -Path $f }

# Transposed side-by-side print for readability
$metrics = @(
    'File','CreationDate','Comment','Api','PresentationMode','HAGS','ResizableBar','WinGameMode',
    'Resolution','GPU','CPU','DriverVersion',
    'Frames','DurationSec',
    'AvgFps','Low1pctFps','Low0_1pctFps',
    'AvgFtMs','MedianFtMs','P95FtMs','P99FtMs','P999FtMs','MaxFtMs','StdFtMs',
    'StutterScore','Hitches_gt2xMedian','HitchPct','Dropped',
    'AvgGpuActivePct','AvgCpuActivePct','AvgPcLatMs','P99PcLatMs'
)

$maxLabel = ($metrics | Measure-Object -Property Length -Maximum).Maximum
$colWidth = 28

$header = 'Metric'.PadRight($maxLabel + 2)
for ($i = 0; $i -lt $results.Count; $i++) {
    $header += ('Cap' + ($i + 1)).PadRight($colWidth)
}
Write-Host $header -ForegroundColor Yellow
Write-Host ('-' * $header.Length) -ForegroundColor DarkGray

foreach ($m in $metrics) {
    $line = $m.PadRight($maxLabel + 2)
    foreach ($r in $results) {
        $v = $r.$m
        if ($null -eq $v) { $v = '(none)' }
        $s = [string]$v
        if ($s.Length -gt ($colWidth - 1)) { $s = $s.Substring(0, $colWidth - 2) + '.' }
        $line += $s.PadRight($colWidth)
    }
    Write-Host $line
}

Write-Host ''
Write-Host '--- Legend ---' -ForegroundColor DarkGray
Write-Host '  Low1pctFps / Low0.1pctFps : tail-latency FPS (lower = more stutter-prone frames)'
Write-Host '  StutterScore (P99 / P50)  : >= 1.25 = noticeable, >= 1.5 = bad, >= 2.0 = severe'
Write-Host '  Hitches_gt2xMedian        : frames >= 2x median frame time (canonical stutter def)'
Write-Host '  AvgGpuActivePct           : PresentMon GPU-active share (bottleneck indicator)'
Write-Host '  AvgCpuActivePct           : PresentMon CPU-active share (bottleneck indicator)'
