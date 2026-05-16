<#
.SYNOPSIS
    Dump the worst hitches from a CapFrameX capture with their timestamps.
.DESCRIPTION
    Locates the frames whose frame time exceeds `HitchThresholdMs`, prints
    a table with TimeInSeconds, frame index, frame time, GPU-active%,
    CPU-active%, PcLatency, and whether PresentMode / Dropped changed.
    Use this to correlate stalls with a specific moment in the session.
.PARAMETER Path
    Full path to the .json capture.
.PARAMETER HitchThresholdMs
    Report frames >= this many ms. Default 16.67 ms (one 60 Hz frame).
.PARAMETER TopN
    Show the N worst hitches. Default 20.
.EXAMPLE
    .\capframex_hitches.ps1 -Path 'C:\...\capture.json'
.EXAMPLE
    .\capframex_hitches.ps1 -Path ... -HitchThresholdMs 50 -TopN 40
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Path,
    [double]$HitchThresholdMs = 16.67,
    [int]$TopN = 20
)

$ErrorActionPreference = 'Stop'

$j = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
$run = $j.Runs[0]
$cd = $run.CaptureData

$frames = $cd.MsBetweenPresents.Count
Write-Host ('=== Hitch Report ===') -ForegroundColor Cyan
Write-Host ('File:     ' + (Split-Path -Leaf $Path))
Write-Host ('Captured: ' + $j.Info.CreationDate)
Write-Host ('Frames:   ' + $frames)
Write-Host ('Duration: ' + [Math]::Round($cd.TimeInSeconds[-1] - $cd.TimeInSeconds[0], 2) + 's')
Write-Host ('Threshold: ' + $HitchThresholdMs + 'ms')
Write-Host ''

$hitches = New-Object System.Collections.Generic.List[object]
for ($i = 0; $i -lt $frames; $i++) {
    $ft = [double]$cd.MsBetweenPresents[$i]
    if ($ft -ge $HitchThresholdMs) {
        $gpuAct = $null
        if ($cd.GpuActive -and $i -lt $cd.GpuActive.Count) { $gpuAct = [double]$cd.GpuActive[$i] }
        $cpuAct = $null
        if ($cd.CpuActive -and $i -lt $cd.CpuActive.Count) { $cpuAct = [double]$cd.CpuActive[$i] }
        $pcLat = $null
        if ($cd.PcLatency -and $i -lt $cd.PcLatency.Count) { $pcLat = [double]$cd.PcLatency[$i] }
        $dropped = $false
        if ($cd.Dropped -and $i -lt $cd.Dropped.Count) { $dropped = [bool]$cd.Dropped[$i] }
        $hitches.Add([PSCustomObject]@{
            Frame      = $i
            TimeSec    = [Math]::Round([double]$cd.TimeInSeconds[$i], 3)
            FtMs       = [Math]::Round($ft, 2)
            GpuActPct  = if ($null -ne $gpuAct) { [Math]::Round($gpuAct, 1) } else { $null }
            CpuActPct  = if ($null -ne $cpuAct) { [Math]::Round($cpuAct, 1) } else { $null }
            PcLatMs    = if ($null -ne $pcLat) { [Math]::Round($pcLat, 2) } else { $null }
            Dropped    = $dropped
        })
    }
}

Write-Host ('Total hitches >= ' + $HitchThresholdMs + 'ms : ' + $hitches.Count) -ForegroundColor Yellow
Write-Host ''

$worst = $hitches | Sort-Object -Property FtMs -Descending | Select-Object -First $TopN
Write-Host ('Top ' + $TopN + ' worst hitches (by frame time):') -ForegroundColor Yellow
$worst | Format-Table -AutoSize

# Clustering: group consecutive hitches within 0.5 s of each other
Write-Host ''
Write-Host 'Hitch clusters (adjacent hitches within 0.5 s):' -ForegroundColor Yellow
$ordered = $hitches | Sort-Object -Property TimeSec
$clusters = New-Object System.Collections.Generic.List[object]
$clusterStart = $null
$clusterEnd = $null
$clusterCount = 0
$clusterMaxFt = 0.0
foreach ($h in $ordered) {
    if ($null -eq $clusterStart) {
        $clusterStart = $h.TimeSec
        $clusterEnd = $h.TimeSec
        $clusterCount = 1
        $clusterMaxFt = $h.FtMs
    }
    elseif (($h.TimeSec - $clusterEnd) -le 0.5) {
        $clusterEnd = $h.TimeSec
        $clusterCount += 1
        if ($h.FtMs -gt $clusterMaxFt) { $clusterMaxFt = $h.FtMs }
    }
    else {
        $clusters.Add([PSCustomObject]@{
            StartSec = $clusterStart
            EndSec   = $clusterEnd
            Spread   = [Math]::Round($clusterEnd - $clusterStart, 2)
            Count    = $clusterCount
            MaxFtMs  = $clusterMaxFt
        })
        $clusterStart = $h.TimeSec
        $clusterEnd = $h.TimeSec
        $clusterCount = 1
        $clusterMaxFt = $h.FtMs
    }
}
if ($null -ne $clusterStart) {
    $clusters.Add([PSCustomObject]@{
        StartSec = $clusterStart
        EndSec   = $clusterEnd
        Spread   = [Math]::Round($clusterEnd - $clusterStart, 2)
        Count    = $clusterCount
        MaxFtMs  = $clusterMaxFt
    })
}
$clusters | Sort-Object -Property MaxFtMs -Descending | Select-Object -First 15 | Format-Table -AutoSize

Write-Host ''
Write-Host '--- Notes ---' -ForegroundColor DarkGray
Write-Host '  Fortnite at 360 FPS = ~2.78 ms/frame. Any >= 16.67 ms = lost 60 Hz refresh.'
Write-Host '  >= 33 ms : dropped two refreshes (30 Hz cadence).'
Write-Host '  >= 100 ms: noticeable stall. >= 1000 ms: full freeze event.'
