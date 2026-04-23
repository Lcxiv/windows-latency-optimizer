<#
.SYNOPSIS
    Correlate CapFrameX gameplay hitches with nearest SensorData2 readings.
.DESCRIPTION
    For every frame whose frame time exceeds HitchThresholdMs inside the
    gameplay window [StartSec, EndSec], look up the closest sensor sample
    in SensorData2 and emit a joined row. Also emits per-hitch delta
    sensors (reading at hitch vs rolling-1 s median just before) so we
    can spot transient clock drops, temp spikes, or power anomalies that
    coincide with the stall.
.PARAMETER Path
    Absolute path to the .json capture.
.PARAMETER HitchThresholdMs
    Minimum frame time to count as a hitch. Default: 5.0 (50% over the
    ~2.78 ms median at ~360 FPS — tunable).
.PARAMETER StartSec
    Gameplay-window start. Default 25 s (skip loading).
.PARAMETER EndSec
    Gameplay-window end. Default: capture duration - 1 s.
.PARAMETER TopN
    Rows to emit. Default 40.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Path,
    [double]$HitchThresholdMs = 5.0,
    [double]$StartSec = 25.0,
    [double]$EndSec = -1,
    [int]$TopN = 40
)

$ErrorActionPreference = 'Stop'

$j = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
$run = $j.Runs[0]
$cd = $run.CaptureData
$s  = $run.SensorData2

$totalDuration = [double]$cd.TimeInSeconds[-1] - [double]$cd.TimeInSeconds[0]
if ($EndSec -lt 0) { $EndSec = $totalDuration - 1.0 }

# Sensor series extraction
$sT  = [double[]]$s.MeasureTime.Values
$gT  = [double[]]$s.'/gpu-nvidia/0/temperature/0'.Values
$gC  = [double[]]$s.'/gpu-nvidia/0/clock/0'.Values
$gL  = [double[]]$s.'/gpu-nvidia/0/load/0'.Values
$gP  = [double[]]$s.'/gpu-nvidia/0/power/0'.Values
$cT  = [double[]]$s.'/amdcpu/0/temperature/2'.Values
$cC  = [double[]]$s.'/amdcpu/0/clock/3'.Values
$cL  = [double[]]$s.'/amdcpu/0/load/0'.Values
$cP  = [double[]]$s.'/amdcpu/0/power/0'.Values
$rM  = $null
try { $rM = [double[]]$s.'/ram/data/4'.Values } catch { $rM = $null }

function Find-SensorIdx {
    param([double[]]$SensorTime, [double]$T)
    # binary search for nearest index
    $lo = 0
    $hi = $SensorTime.Count - 1
    if ($T -le $SensorTime[$lo]) { return $lo }
    if ($T -ge $SensorTime[$hi]) { return $hi }
    while ($hi - $lo -gt 1) {
        $mid = [int](($lo + $hi) / 2)
        if ($SensorTime[$mid] -lt $T) { $lo = $mid } else { $hi = $mid }
    }
    $dLo = [Math]::Abs($T - $SensorTime[$lo])
    $dHi = [Math]::Abs($T - $SensorTime[$hi])
    if ($dLo -le $dHi) { return $lo } else { return $hi }
}

# Collect hitches in window
$ftArr = [double[]]$cd.MsBetweenPresents
$tArr  = [double[]]$cd.TimeInSeconds
$cpuActArr = $null
$gpuActArr = $null
$pcLatArr  = $null
if ($cd.CpuActive) { $cpuActArr = [double[]]$cd.CpuActive }
if ($cd.GpuActive) { $gpuActArr = [double[]]$cd.GpuActive }
if ($cd.PcLatency) { $pcLatArr  = [double[]]$cd.PcLatency }

$hitches = New-Object System.Collections.Generic.List[object]
for ($i = 0; $i -lt $ftArr.Count; $i++) {
    $ft = [double]$ftArr[$i]
    $t  = [double]$tArr[$i]
    if ($t -lt $StartSec -or $t -gt $EndSec) { continue }
    if ($ft -lt $HitchThresholdMs) { continue }
    $si = Find-SensorIdx -SensorTime $sT -T $t
    $rmVal = $null
    if ($rM -and $si -lt $rM.Count) { $rmVal = $rM[$si] }
    $pcVal = $null
    if ($pcLatArr -and $i -lt $pcLatArr.Count) { $pcVal = [double]$pcLatArr[$i] }
    $cpuActVal = $null
    if ($cpuActArr -and $i -lt $cpuActArr.Count) { $cpuActVal = [double]$cpuActArr[$i] }
    $gpuActVal = $null
    if ($gpuActArr -and $i -lt $gpuActArr.Count) { $gpuActVal = [double]$gpuActArr[$i] }

    $hitches.Add([PSCustomObject]@{
        Frame    = $i
        TSec     = [Math]::Round($t, 2)
        FtMs     = [Math]::Round($ft, 2)
        PcLatMs  = if ($null -ne $pcVal) { [Math]::Round($pcVal, 2) } else { $null }
        CpuActMs = if ($null -ne $cpuActVal) { [Math]::Round($cpuActVal, 2) } else { $null }
        GpuActMs = if ($null -ne $gpuActVal) { [Math]::Round($gpuActVal, 2) } else { $null }
        GpuTempC = if ($gT) { [Math]::Round($gT[$si], 1) } else { $null }
        GpuClkMHz= if ($gC) { [Math]::Round($gC[$si], 0) } else { $null }
        GpuLoad  = if ($gL) { [Math]::Round($gL[$si], 1) } else { $null }
        GpuPwrW  = if ($gP) { [Math]::Round($gP[$si], 1) } else { $null }
        CpuTempC = if ($cT) { [Math]::Round($cT[$si], 1) } else { $null }
        CpuClkMHz= if ($cC) { [Math]::Round($cC[$si], 0) } else { $null }
        CpuLoad  = if ($cL) { [Math]::Round($cL[$si], 1) } else { $null }
        CpuPwrW  = if ($cP) { [Math]::Round($cP[$si], 1) } else { $null }
        RamUsed  = if ($null -ne $rmVal) { [Math]::Round($rmVal, 2) } else { $null }
    })
}

Write-Host ('=== Hitch vs Sensor Correlation ===') -ForegroundColor Cyan
Write-Host ('File   : ' + (Split-Path -Leaf $Path))
Write-Host ('Window : ' + $StartSec + 's - ' + $EndSec + 's')
Write-Host ('Thresh : ' + $HitchThresholdMs + ' ms')
Write-Host ('Hitches: ' + $hitches.Count)
Write-Host ''
Write-Host ('Top ' + $TopN + ' worst hitches (sorted by frame time):') -ForegroundColor Yellow
$hitches | Sort-Object -Property FtMs -Descending | Select-Object -First $TopN | Format-Table -AutoSize

# Aggregate comparison: hitch-sample sensor stats vs overall window stats
function Stats {
    param([double[]]$V)
    if ($V.Count -eq 0) { return @{avg=$null;min=$null;max=$null} }
    $a = ($V | Measure-Object -Average).Average
    $mi = ($V | Measure-Object -Minimum).Minimum
    $mx = ($V | Measure-Object -Maximum).Maximum
    return @{avg=$a;min=$mi;max=$mx}
}

# Build window-wide sensor stats
$windowSensorIdx = for ($i = 0; $i -lt $sT.Count; $i++) { if ($sT[$i] -ge $StartSec -and $sT[$i] -le $EndSec) { $i } }
$winGClk = foreach ($i in $windowSensorIdx) { [double]$gC[$i] }
$winGLd = foreach ($i in $windowSensorIdx) { [double]$gL[$i] }
$winGPw = foreach ($i in $windowSensorIdx) { [double]$gP[$i] }
$winCClk= foreach ($i in $windowSensorIdx) { [double]$cC[$i] }
$winCLd = foreach ($i in $windowSensorIdx) { [double]$cL[$i] }
$winCPw = foreach ($i in $windowSensorIdx) { [double]$cP[$i] }

$hGClk = $hitches | ForEach-Object { [double]$_.GpuClkMHz }
$hGLd  = $hitches | ForEach-Object { [double]$_.GpuLoad }
$hGPw  = $hitches | ForEach-Object { [double]$_.GpuPwrW }
$hCClk = $hitches | ForEach-Object { [double]$_.CpuClkMHz }
$hCLd  = $hitches | ForEach-Object { [double]$_.CpuLoad }
$hCPw  = $hitches | ForEach-Object { [double]$_.CpuPwrW }

$s1 = Stats -V $winGClk
$s2 = Stats -V $hGClk
$s3 = Stats -V $winGLd
$s4 = Stats -V $hGLd
$s5 = Stats -V $winGPw
$s6 = Stats -V $hGPw
$s7 = Stats -V $winCClk
$s8 = Stats -V $hCClk
$s9 = Stats -V $winCLd
$s10 = Stats -V $hCLd
$s11 = Stats -V $winCPw
$s12 = Stats -V $hCPw

Write-Host ''
Write-Host 'Aggregate comparison: window-wide vs hitch-sampled' -ForegroundColor Yellow
Write-Host ('                         Window avg / min / max      Hitch avg / min / max')
$fmt = '{0,-23} {1,5:F0} / {2,5:F0} / {3,5:F0}     {4,5:F0} / {5,5:F0} / {6,5:F0}'
Write-Host ($fmt -f 'GPU clock (MHz)', $s1.avg, $s1.min, $s1.max, $s2.avg, $s2.min, $s2.max)
Write-Host ($fmt -f 'GPU load  (%)',   $s3.avg, $s3.min, $s3.max, $s4.avg, $s4.min, $s4.max)
Write-Host ($fmt -f 'GPU power (W)',   $s5.avg, $s5.min, $s5.max, $s6.avg, $s6.min, $s6.max)
Write-Host ($fmt -f 'CPU clock (MHz)', $s7.avg, $s7.min, $s7.max, $s8.avg, $s8.min, $s8.max)
Write-Host ($fmt -f 'CPU load  (%)',   $s9.avg, $s9.min, $s9.max, $s10.avg, $s10.min, $s10.max)
Write-Host ($fmt -f 'CPU power (W)',   $s11.avg, $s11.min, $s11.max, $s12.avg, $s12.min, $s12.max)
Write-Host ''
Write-Host '--- Interpretation hints ---' -ForegroundColor DarkGray
Write-Host '  Hitch avg GPU clock noticeably BELOW window avg => P-state drop / clock stretch during stall.'
Write-Host '  Hitch avg CPU load noticeably BELOW window avg  => CPU-bound stall unlikely (something else blocking).'
Write-Host '  Hitch CpuActMs close to FtMs                    => CPU waiting on present (alt-tab / background).'
Write-Host '  Hitch GpuActMs close to FtMs                    => GPU busy for the full frame (genuine GPU stall).'
