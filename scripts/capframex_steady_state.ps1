<#
.SYNOPSIS
    Recompute CapFrameX metrics from a trimmed time window to exclude
    startup loading screens and capture-boundary artifacts.
.DESCRIPTION
    CapFrameX's first frame + the last frame often capture non-gameplay
    events (shader compile, alt-tab, background). This script lets you
    specify a gameplay-only window (Start/End seconds) and recomputes the
    same metrics as analyze_capframex.ps1 on the trimmed slice.
.PARAMETER Path
    Absolute path to the .json capture.
.PARAMETER StartSec
    First second of the gameplay window (default 25 — skip shader/load).
.PARAMETER EndSec
    Last second of the gameplay window. Default: capture duration - 1 s.
.EXAMPLE
    .\capframex_steady_state.ps1 -Path 'C:\...\cap2.json'
.EXAMPLE
    .\capframex_steady_state.ps1 -Path ... -StartSec 30 -EndSec 200
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Path,
    [double]$StartSec = 25.0,
    [double]$EndSec = -1
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

$j = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
$run = $j.Runs[0]
$cd = $run.CaptureData

$frames = $cd.MsBetweenPresents.Count
$totalDuration = [double]$cd.TimeInSeconds[-1] - [double]$cd.TimeInSeconds[0]
if ($EndSec -lt 0) { $EndSec = $totalDuration - 1.0 }

Write-Host ('=== Steady-State Window Analysis ===') -ForegroundColor Cyan
Write-Host ('File:           ' + (Split-Path -Leaf $Path))
Write-Host ('Total duration: ' + [Math]::Round($totalDuration, 2) + ' s')
Write-Host ('Window:         ' + $StartSec + ' s to ' + $EndSec + ' s')
Write-Host ''

$ftAll = [double[]]$cd.MsBetweenPresents
$tAll = [double[]]$cd.TimeInSeconds
$gpuAct = $null
$cpuAct = $null
$pcLat = $null
if ($cd.GpuActive) { $gpuAct = [double[]]$cd.GpuActive }
if ($cd.CpuActive) { $cpuAct = [double[]]$cd.CpuActive }
if ($cd.PcLatency) { $pcLat = [double[]]$cd.PcLatency }

$trimmedFt = New-Object System.Collections.Generic.List[double]
$trimmedGpu = New-Object System.Collections.Generic.List[double]
$trimmedCpu = New-Object System.Collections.Generic.List[double]
$trimmedPc = New-Object System.Collections.Generic.List[double]
for ($i = 0; $i -lt $ftAll.Count; $i++) {
    $t = [double]$tAll[$i]
    if ($t -ge $StartSec -and $t -le $EndSec) {
        if ($ftAll[$i] -gt 0) { $trimmedFt.Add([double]$ftAll[$i]) }
        if ($gpuAct -and $i -lt $gpuAct.Count -and -not [double]::IsNaN($gpuAct[$i])) { $trimmedGpu.Add([double]$gpuAct[$i]) }
        if ($cpuAct -and $i -lt $cpuAct.Count -and -not [double]::IsNaN($cpuAct[$i])) { $trimmedCpu.Add([double]$cpuAct[$i]) }
        if ($pcLat -and $i -lt $pcLat.Count -and $pcLat[$i] -gt 0 -and -not [double]::IsNaN($pcLat[$i])) { $trimmedPc.Add([double]$pcLat[$i]) }
    }
}

$ft = [double[]]$trimmedFt
if ($ft.Count -eq 0) {
    Write-Error 'No frames in window'
    exit 1
}

$avgFt = ($ft | Measure-Object -Average).Average
$medianFt = Get-Percentile -Values $ft -Pct 50
$p95Ft = Get-Percentile -Values $ft -Pct 95
$p99Ft = Get-Percentile -Values $ft -Pct 99
$p999Ft = Get-Percentile -Values $ft -Pct 99.9
$maxFt = ($ft | Measure-Object -Maximum).Maximum
$avgFps = 1000.0 / $avgFt
$low1 = Get-LowFps -FrameTimesMs $ft -Pct 1
$low01 = Get-LowFps -FrameTimesMs $ft -Pct 0.1
$stutterScore = $p99Ft / $medianFt
$hitchThr = 2.0 * $medianFt
$hitches = ($ft | Where-Object { $_ -gt $hitchThr }).Count

$avgGpuR = 'n/a'
if ($trimmedGpu.Count -gt 0) { $avgGpuR = [string][Math]::Round(($trimmedGpu | Measure-Object -Average).Average, 1) }
$avgCpuR = 'n/a'
if ($trimmedCpu.Count -gt 0) { $avgCpuR = [string][Math]::Round(($trimmedCpu | Measure-Object -Average).Average, 1) }
$avgPcR = 'n/a'
$p99PcR = 'n/a'
if ($trimmedPc.Count -gt 0) {
    $avgPcR = [string][Math]::Round(($trimmedPc | Measure-Object -Average).Average, 2)
    $p99PcR = [string][Math]::Round((Get-Percentile -Values ([double[]]$trimmedPc) -Pct 99), 2)
}

Write-Host 'Steady-state metrics (window only):' -ForegroundColor Yellow
Write-Host ('  Frames (window)    : ' + $ft.Count)
Write-Host ('  Avg FPS            : ' + [Math]::Round($avgFps, 1))
Write-Host ('  1% low FPS         : ' + [Math]::Round($low1, 1))
Write-Host ('  0.1% low FPS       : ' + [Math]::Round($low01, 1))
Write-Host ('  Avg frame time     : ' + [Math]::Round($avgFt, 3) + ' ms')
Write-Host ('  Median frame time  : ' + [Math]::Round($medianFt, 3) + ' ms')
Write-Host ('  P95 / P99 / P99.9  : ' + [Math]::Round($p95Ft, 3) + ' / ' + [Math]::Round($p99Ft, 3) + ' / ' + [Math]::Round($p999Ft, 3) + ' ms')
Write-Host ('  Max frame time     : ' + [Math]::Round($maxFt, 3) + ' ms')
Write-Host ('  Stutter score      : ' + [Math]::Round($stutterScore, 2) + ' (P99/P50)')
Write-Host ('  Hitches >2x median : ' + $hitches)
Write-Host ('  GPU active %       : ' + $avgGpuR)
Write-Host ('  CPU active %       : ' + $avgCpuR)
Write-Host ('  Avg PcLatency      : ' + $avgPcR + ' ms')
Write-Host ('  P99 PcLatency      : ' + $p99PcR + ' ms')
