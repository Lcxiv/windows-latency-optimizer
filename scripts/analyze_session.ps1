<#
.SYNOPSIS
    Unified session analyzer — correlates ALL data sources and auto-classifies hitches.
.DESCRIPTION
    Loads perf counters, GPU dmon, ping monitor, process samples, and optionally
    CapFrameX frame timing from a capture_session.ps1 output directory.

    For each detected hitch, builds a multi-dimensional snapshot showing what
    every data source recorded at that moment. Auto-classifies root cause:
      SHADER_COMPILE, IO_STORM, DPC_STORM, NETWORK, THERMAL, GPU_BOUND, CPU_BOUND

.PARAMETER SessionDir
    Path to capture_session.ps1 output directory.
.PARAMETER CapFrameXFile
    Optional CapFrameX JSON file for frame-level correlation.
.PARAMETER HitchThresholdMs
    Frame time threshold for hitch detection. Default 33ms.
.PARAMETER TopN
    Number of worst hitches to display. Default 30.
.EXAMPLE
    .\analyze_session.ps1 -SessionDir "captures\sessions\fortnite-reload_20260509_170039"
    .\analyze_session.ps1 -SessionDir "captures\sessions\..." -CapFrameXFile "C:\...\CapFrameX-....json"
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$SessionDir,

    [string]$CapFrameXFile,

    [double]$HitchThresholdMs = 33,

    [int]$TopN = 30
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $SessionDir)) {
    Write-Error ('Session directory not found: ' + $SessionDir)
    return
}

# ============================================================================
# DATA LOADERS
# ============================================================================

function Load-RunMeta {
    param([string]$dir)
    $metaPath = Join-Path $dir 'run_meta.json'
    if (-not (Test-Path $metaPath)) { return $null }
    return (Get-Content $metaPath -Raw | ConvertFrom-Json)
}

function Load-PerfCounters {
    param([string]$dir)
    $csvPath = Join-Path $dir 'percpu_counters.csv'
    if (-not (Test-Path $csvPath)) { return @() }
    $raw = Import-Csv $csvPath
    if ($raw.Count -eq 0) { return @() }
    return $raw
}

function Load-GpuDmon {
    param([string]$dir)
    $csvPath = Join-Path $dir 'gpu_dmon.csv'
    if (-not (Test-Path $csvPath)) { return @() }
    $raw = Import-Csv $csvPath
    if ($null -eq $raw -or $raw.Count -eq 0) { return @() }
    return $raw
}

function Load-PingMonitor {
    param([string]$dir)
    $csvPath = Join-Path $dir 'ping_monitor.csv'
    if (-not (Test-Path $csvPath)) { return @() }
    $raw = Import-Csv $csvPath
    if ($null -eq $raw -or $raw.Count -eq 0) { return @() }
    return $raw
}

function Load-ProcessSamples {
    param([string]$dir)
    $csvPath = Join-Path $dir 'process_samples.csv'
    if (-not (Test-Path $csvPath)) { return @() }
    $raw = Import-Csv $csvPath
    if ($null -eq $raw -or $raw.Count -eq 0) { return @() }
    return $raw
}

function Load-CapFrameX {
    param([string]$jsonPath)
    if (-not $jsonPath -or -not (Test-Path $jsonPath)) { return $null }
    Write-Host ('  Loading CapFrameX JSON (' + [math]::Round((Get-Item $jsonPath).Length / 1MB, 1) + ' MB)...') -ForegroundColor Gray
    $j = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json

    $cd = $j.Runs[0].CaptureData
    $frameCount = $cd.MsBetweenPresents.Count

    # Parse capture start time
    $creationDate = $j.Info.CreationDate
    $cfxStart = [DateTimeOffset]::Parse($creationDate)
    $cfxStartMs = $cfxStart.ToUnixTimeMilliseconds()

    # Build frame array
    $frames = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $frameCount; $i++) {
        $ftMs = $cd.MsBetweenPresents[$i]
        $timeSec = $cd.TimeInSeconds[$i]
        $epochMs = $cfxStartMs + [long]($timeSec * 1000)

        $cpuAct = 0; $gpuAct = 0; $pcLat = 0; $dropped = $false
        if ($cd.PSObject.Properties['CpuActive']) { $cpuAct = $cd.CpuActive[$i] }
        if ($cd.PSObject.Properties['GpuActive']) { $gpuAct = $cd.GpuActive[$i] }
        if ($cd.PSObject.Properties['PcLatency']) { $pcLat = $cd.PcLatency[$i] }
        if ($cd.PSObject.Properties['Dropped']) { $dropped = $cd.Dropped[$i] }

        [void]$frames.Add(@{
            idx = $i; timeSec = $timeSec; epochMs = $epochMs
            ftMs = $ftMs; cpuActMs = $cpuAct; gpuActMs = $gpuAct
            pcLatMs = $pcLat; dropped = $dropped
        })
    }

    # Parse sensor data
    $sensors = @()
    $sd2 = $j.Runs[0].SensorData2
    if ($sd2) {
        $gpuTemp = $null; $gpuClk = $null; $gpuLoad = $null; $gpuPwr = $null
        $cpuTemp = $null; $cpuClk = $null; $cpuLoad = $null; $cpuPwr = $null
        foreach ($s in $sd2) {
            $id = $s.Identifier
            if ($id -eq '/gpu-nvidia/0/temperature/0') { $gpuTemp = $s }
            elseif ($id -eq '/gpu-nvidia/0/clock/0') { $gpuClk = $s }
            elseif ($id -eq '/gpu-nvidia/0/load/0') { $gpuLoad = $s }
            elseif ($id -eq '/gpu-nvidia/0/power/0') { $gpuPwr = $s }
            elseif ($id -eq '/amdcpu/0/temperature/2') { $cpuTemp = $s }
            elseif ($id -eq '/amdcpu/0/clock/3') { $cpuClk = $s }
            elseif ($id -eq '/amdcpu/0/load/0') { $cpuLoad = $s }
            elseif ($id -eq '/amdcpu/0/power/0') { $cpuPwr = $s }
        }

        # Build sensor timeline indexed by MeasureTime
        if ($gpuTemp -and $gpuTemp.Values.Count -gt 0) {
            $sensorCount = $gpuTemp.Values.Count
            $sensors = New-Object System.Collections.ArrayList
            for ($i = 0; $i -lt $sensorCount; $i++) {
                $mt = $gpuTemp.MeasureTime[$i]
                $sEpochMs = $cfxStartMs + [long]($mt * 1000)
                $entry = @{ measureTime = $mt; epochMs = $sEpochMs }
                if ($gpuTemp) { $entry.gpuTempC = $gpuTemp.Values[$i] }
                if ($gpuClk) { $entry.gpuClkMHz = $gpuClk.Values[$i] }
                if ($gpuLoad) { $entry.gpuLoadPct = $gpuLoad.Values[$i] }
                if ($gpuPwr) { $entry.gpuPwrW = $gpuPwr.Values[$i] }
                if ($cpuTemp) { $entry.cpuTempC = $cpuTemp.Values[$i] }
                if ($cpuClk) { $entry.cpuClkMHz = $cpuClk.Values[$i] }
                if ($cpuLoad) { $entry.cpuLoadPct = $cpuLoad.Values[$i] }
                if ($cpuPwr) { $entry.cpuPwrW = $cpuPwr.Values[$i] }
                [void]$sensors.Add($entry)
            }
        }
    }

    $durationSec = 0
    if ($frameCount -gt 0) { $durationSec = $cd.TimeInSeconds[$frameCount - 1] }

    $avgFps = 0
    if ($durationSec -gt 0) { $avgFps = [math]::Round($frameCount / $durationSec, 1) }

    Write-Host ('  Loaded: ' + $frameCount + ' frames, ' + [math]::Round($durationSec, 1) + 's, ' + $avgFps + ' FPS avg') -ForegroundColor Gray
    return @{
        frames = $frames; sensors = $sensors; startEpochMs = $cfxStartMs
        durationSec = $durationSec; frameCount = $frameCount; avgFps = $avgFps
    }
}

# ============================================================================
# CORRELATION HELPERS
# ============================================================================

function Find-NearestRows {
    param([long]$targetMs, [array]$rows, [string]$epochField, [long]$windowMs)
    $result = @()
    foreach ($r in $rows) {
        $em = [long]$r.$epochField
        if ([math]::Abs($em - $targetMs) -le $windowMs) {
            $result += $r
        }
    }
    return $result
}

function Get-PerfSnapshot {
    param([long]$epochMs, [array]$perfRows, [long]$windowMs)
    if ($perfRows.Count -eq 0) { return $null }
    $near = Find-NearestRows -targetMs $epochMs -rows $perfRows -epochField 'EpochMs' -windowMs $windowMs
    if ($near.Count -eq 0) { return $null }

    $sysRow = $near | Where-Object { $_.Cpu -eq '-1' } | Select-Object -First 1
    $cpuRows = $near | Where-Object { $_.Cpu -ne '-1' }

    $dpcByCpu = @{}
    $isrByCpu = @{}
    $dpcSum = 0; $isrSum = 0
    foreach ($cr in $cpuRows) {
        $cpuIdx = [int]$cr.Cpu
        $dpcVal = 0; $isrVal = 0
        if ($cr.DpcPct -ne '') { $dpcVal = [double]$cr.DpcPct }
        if ($cr.IsrPct -ne '') { $isrVal = [double]$cr.IsrPct }
        $dpcByCpu[$cpuIdx] = $dpcVal
        $isrByCpu[$cpuIdx] = $isrVal
        $dpcSum += $dpcVal
        $isrSum += $isrVal
    }

    $cpuPct = $null; $memMB = $null; $pagesSec = $null; $diskLatMs = $null; $diskQ = $null
    if ($sysRow) {
        if ($sysRow.TotalCpuPct -ne '') { $cpuPct = [double]$sysRow.TotalCpuPct }
        if ($sysRow.AvailMemMB -ne '') { $memMB = [double]$sysRow.AvailMemMB }
        if ($sysRow.PagesSec -ne '') { $pagesSec = [double]$sysRow.PagesSec }
        if ($sysRow.DiskReadLatMs -ne '') { $diskLatMs = [double]$sysRow.DiskReadLatMs }
        if ($sysRow.DiskQueueLen -ne '') { $diskQ = [double]$sysRow.DiskQueueLen }
    }

    return @{
        dpcByCpu = $dpcByCpu; isrByCpu = $isrByCpu
        dpcSum = [math]::Round($dpcSum, 2); isrSum = [math]::Round($isrSum, 2)
        cpuPct = $cpuPct; memMB = $memMB; pagesSec = $pagesSec
        diskLatMs = $diskLatMs; diskQ = $diskQ
    }
}

function Get-GpuSnapshot {
    param([long]$epochMs, [array]$gpuRows, [long]$windowMs)
    if ($gpuRows.Count -eq 0) { return $null }
    $near = Find-NearestRows -targetMs $epochMs -rows $gpuRows -epochField 'EpochMs' -windowMs $windowMs
    if ($near.Count -eq 0) { return $null }
    $r = $near | Select-Object -First 1
    $snap = @{}
    if ($r.PwrW -ne '') { $snap.pwrW = [double]$r.PwrW }
    if ($r.GpuTempC -ne '') { $snap.tempC = [double]$r.GpuTempC }
    if ($r.SmPct -ne '') { $snap.smPct = [double]$r.SmPct }
    if ($r.GfxClkMHz -ne '') { $snap.gfxClkMHz = [double]$r.GfxClkMHz }
    if ($r.MemBwPct -ne '') { $snap.memBwPct = [double]$r.MemBwPct }
    if ($r.FbUsedMB -ne '') { $snap.fbMB = [double]$r.FbUsedMB }
    if ($r.PcieRxMBs -ne '') { $snap.pcieRx = [double]$r.PcieRxMBs }
    if ($r.PcieTxMBs -ne '') { $snap.pcieTx = [double]$r.PcieTxMBs }
    return $snap
}

function Get-PingSnapshot {
    param([long]$epochMs, [array]$pingRows, [long]$windowMs, [string]$gwIp)
    if ($pingRows.Count -eq 0) { return $null }
    $near = Find-NearestRows -targetMs $epochMs -rows $pingRows -epochField 'EpochMs' -windowMs $windowMs
    if ($near.Count -eq 0) { return $null }
    $gwPing = $near | Where-Object { $_.Target -eq $gwIp } | Select-Object -First 1
    $wanPings = $near | Where-Object { $_.Target -ne $gwIp }
    $gwRtt = $null; $wanRtt = $null; $anyDrop = $false
    if ($gwPing) {
        $gwRtt = [int]$gwPing.RttMs
        if ($gwPing.Reachable -eq 'False') { $anyDrop = $true }
    }
    foreach ($wp in $wanPings) {
        $rtt = [int]$wp.RttMs
        if ($wp.Reachable -eq 'False') { $anyDrop = $true }
        if ($rtt -ge 0 -and ($null -eq $wanRtt -or $rtt -lt $wanRtt)) { $wanRtt = $rtt }
    }
    return @{ gwRttMs = $gwRtt; wanRttMs = $wanRtt; anyDrop = $anyDrop }
}

function Get-ProcessSnapshot {
    param([long]$epochMs, [array]$procRows, [long]$windowMs)
    if ($procRows.Count -eq 0) { return $null }
    $near = Find-NearestRows -targetMs $epochMs -rows $procRows -epochField 'EpochMs' -windowMs $windowMs
    if ($near.Count -eq 0) { return $null }
    $topProcs = $near | Sort-Object { [double]$_.CpuSec } -Descending | Select-Object -First 5
    $result = @()
    foreach ($p in $topProcs) {
        $result += ($p.Name + '(' + $p.Pid + ')')
    }
    return ($result -join ', ')
}

function Find-NearestSensor {
    param([double]$timeSec, [array]$sensors)
    if ($sensors.Count -eq 0) { return $null }
    $bestIdx = 0
    $bestDiff = [math]::Abs($sensors[0].measureTime - $timeSec)
    for ($i = 1; $i -lt $sensors.Count; $i++) {
        $diff = [math]::Abs($sensors[$i].measureTime - $timeSec)
        if ($diff -lt $bestDiff) { $bestDiff = $diff; $bestIdx = $i }
        if ($diff -gt $bestDiff) { break }
    }
    if ($bestDiff -gt 2.0) { return $null }
    return $sensors[$bestIdx]
}

# ============================================================================
# CLASSIFICATION ENGINE
# ============================================================================

function Classify-Hitch {
    param($snap, $baseline)

    $cat = 'UNKNOWN'
    $conf = 'LOW'
    $evidence = ''

    $ftMs = $snap.ftMs
    $cpuActMs = $snap.cpuActMs
    $gpuActMs = $snap.gpuActMs
    $perf = $snap.perf
    $gpu = $snap.gpu
    $ping = $snap.ping
    $sensor = $snap.sensor

    # ---- SHADER_COMPILE: CPU blocks render thread, GPU starves ----
    $cpuRatio = 0
    if ($ftMs -gt 0 -and $cpuActMs -gt 0) { $cpuRatio = $cpuActMs / $ftMs }

    # GPU idle detection: check multiple signals
    $gpuIdle = $false
    if ($sensor) {
        if ($sensor.gpuLoadPct -ne $null -and $sensor.gpuLoadPct -lt 15) { $gpuIdle = $true }
    }
    if ($gpu) {
        if ($gpu.smPct -ne $null -and $gpu.smPct -lt 15) { $gpuIdle = $true }
    }
    # Frame-level: if GpuActMs is tiny relative to FtMs, GPU was starved
    if ($ftMs -gt 33 -and $gpuActMs -gt 0 -and $gpuActMs -lt 10) { $gpuIdle = $true }

    $gpuPwrLow = $false
    if ($sensor -and $baseline.medGpuPwrW -gt 0) {
        if ($sensor.gpuPwrW -ne $null -and $sensor.gpuPwrW -lt ($baseline.medGpuPwrW * 0.6)) { $gpuPwrLow = $true }
    }
    if ($gpu -and $baseline.medDmonPwrW -gt 0) {
        if ($gpu.pwrW -ne $null -and $gpu.pwrW -lt ($baseline.medDmonPwrW * 0.6)) { $gpuPwrLow = $true }
    }

    if ($cpuRatio -gt 0.8 -and ($gpuIdle -or $gpuPwrLow)) {
        $cat = 'SHADER_COMPILE'
        $conf = 'HIGH'
        $loadStr = 'GpuAct=' + [math]::Round($gpuActMs, 1) + 'ms'
        if ($sensor -and $sensor.gpuLoadPct -ne $null) { $loadStr = $loadStr + ' load=' + [math]::Round($sensor.gpuLoadPct, 0) + '%' }
        elseif ($gpu -and $gpu.smPct -ne $null) { $loadStr = $loadStr + ' SM=' + [math]::Round($gpu.smPct, 0) + '%' }
        $evidence = 'CpuAct=' + [math]::Round($cpuActMs, 0) + 'ms~FtMs, ' + $loadStr
        return @{ category = $cat; confidence = $conf; evidence = $evidence }
    }

    # ---- DPC_STORM ----
    if ($perf) {
        $worstCpu = -1; $worstDpc = 0
        foreach ($k in $perf.dpcByCpu.Keys) {
            if ($perf.dpcByCpu[$k] -gt $worstDpc) { $worstDpc = $perf.dpcByCpu[$k]; $worstCpu = $k }
        }
        if ($perf.dpcSum -gt 20 -or $worstDpc -gt 10) {
            $cat = 'DPC_STORM'
            $conf = 'HIGH'
            $evidence = 'DPC sum ' + $perf.dpcSum + '%, worst CPU' + $worstCpu + '=' + [math]::Round($worstDpc, 1) + '%'
            return @{ category = $cat; confidence = $conf; evidence = $evidence }
        }
    }

    # ---- IO_STORM ----
    if ($perf) {
        $pgHigh = ($perf.pagesSec -ne $null -and $perf.pagesSec -gt 5000)
        $diskHigh = ($perf.diskLatMs -ne $null -and $perf.diskLatMs -gt 5)
        if ($pgHigh -or $diskHigh) {
            $cat = 'IO_STORM'
            $conf = 'HIGH'
            $evidence = 'Pages/sec=' + $perf.pagesSec + ', DiskLat=' + $perf.diskLatMs + 'ms'
            return @{ category = $cat; confidence = $conf; evidence = $evidence }
        }
    }

    # ---- NETWORK ----
    if ($ping) {
        $netBad = $false
        if ($ping.anyDrop) { $netBad = $true }
        if ($ping.gwRttMs -ne $null -and $ping.gwRttMs -gt 50) { $netBad = $true }
        if ($ping.wanRttMs -ne $null -and $ping.wanRttMs -gt 100) { $netBad = $true }
        if ($netBad) {
            $cat = 'NETWORK'
            $conf = 'MEDIUM'
            $evidence = 'GW=' + $ping.gwRttMs + 'ms, WAN=' + $ping.wanRttMs + 'ms, drop=' + $ping.anyDrop
            return @{ category = $cat; confidence = $conf; evidence = $evidence }
        }
    }

    # ---- THERMAL ----
    $thermal = $false
    $thermEvidence = ''
    if ($sensor -and $sensor.gpuTempC -gt 80) {
        $thermal = $true
        $thermEvidence = 'GPU temp ' + [math]::Round($sensor.gpuTempC, 0) + 'C'
    }
    if ($gpu -and $gpu.tempC -gt 80) {
        $thermal = $true
        $thermEvidence = 'GPU temp ' + [math]::Round($gpu.tempC, 0) + 'C'
    }
    if ($sensor -and $baseline.medGpuClkMHz -gt 0) {
        $clkDrop = $baseline.medGpuClkMHz - $sensor.gpuClkMHz
        if ($clkDrop -gt 200) {
            $thermal = $true
            $thermEvidence = $thermEvidence + ' clk drop -' + [math]::Round($clkDrop, 0) + 'MHz'
        }
    }
    if ($thermal) {
        $cat = 'THERMAL'
        $conf = 'MEDIUM'
        $evidence = $thermEvidence
        return @{ category = $cat; confidence = $conf; evidence = $evidence }
    }

    # ---- GPU_BOUND ----
    $gpuRatio = 0
    if ($ftMs -gt 0 -and $gpuActMs -gt 0) { $gpuRatio = $gpuActMs / $ftMs }
    if ($gpuRatio -gt 0.8) {
        $cat = 'GPU_BOUND'
        $conf = 'MEDIUM'
        $evidence = 'GpuAct=' + [math]::Round($gpuActMs, 1) + 'ms~FtMs'
        return @{ category = $cat; confidence = $conf; evidence = $evidence }
    }

    # ---- CPU_BOUND ----
    if ($perf -and $perf.cpuPct -ne $null -and $perf.cpuPct -gt 90) {
        $cat = 'CPU_BOUND'
        $conf = 'LOW'
        $evidence = 'CPU ' + [math]::Round($perf.cpuPct, 0) + '%'
        return @{ category = $cat; confidence = $conf; evidence = $evidence }
    }

    # ---- UNKNOWN ----
    $parts = @()
    if ($cpuActMs -gt 0) { $parts += 'CpuAct=' + [math]::Round($cpuActMs, 0) + 'ms' }
    if ($gpuActMs -gt 0) { $parts += 'GpuAct=' + [math]::Round($gpuActMs, 0) + 'ms' }
    if ($perf) { $parts += 'DPC=' + $perf.dpcSum + '%' }
    if ($ping) { $parts += 'GW=' + $ping.gwRttMs + 'ms' }
    $evidence = $parts -join ', '
    return @{ category = $cat; confidence = $conf; evidence = $evidence }
}

# ============================================================================
# MAIN ANALYSIS
# ============================================================================

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host '  Session Analysis' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ('  Dir: ' + $SessionDir)
Write-Host ''

# ---- Load all data sources ----
Write-Host 'Loading data sources...' -ForegroundColor Gray
$meta = Load-RunMeta -dir $SessionDir
$perfRows = Load-PerfCounters -dir $SessionDir
$gpuRows = Load-GpuDmon -dir $SessionDir
$pingRows = Load-PingMonitor -dir $SessionDir
$procRows = Load-ProcessSamples -dir $SessionDir

$cfxData = $null
if ($CapFrameXFile) {
    $cfxData = Load-CapFrameX -jsonPath $CapFrameXFile
}

Write-Host ('  Perf counters: ' + $perfRows.Count + ' rows')
Write-Host ('  GPU dmon:      ' + $gpuRows.Count + ' rows')
Write-Host ('  Ping monitor:  ' + $pingRows.Count + ' rows')
Write-Host ('  Process samps: ' + $procRows.Count + ' rows')
if ($cfxData) {
    Write-Host ('  CapFrameX:     ' + $cfxData.frameCount + ' frames, ' + [math]::Round($cfxData.durationSec, 1) + 's')
} else {
    Write-Host '  CapFrameX:     not provided' -ForegroundColor Yellow
}
Write-Host ''

# ---- Detect gateway IP from ping data ----
$gwIp = '192.168.4.1'
if ($meta -and $meta.PSObject.Properties['gateway']) { $gwIp = $meta.gateway }
if ($pingRows.Count -gt 0) {
    $targets = $pingRows | Select-Object -ExpandProperty Target -Unique
    foreach ($t in $targets) {
        if ($t -ne '8.8.8.8' -and $t -ne '1.1.1.1') { $gwIp = $t; break }
    }
}

# ---- Compute session baselines ----
Write-Host 'Computing baselines...' -ForegroundColor Gray
$baseline = @{
    medGpuClkMHz = 0; medGpuPwrW = 0; medGpuTempC = 0
    medDmonPwrW = 0; medDmonSmPct = 0; medDmonClkMHz = 0
    medCpuPct = 0; medPagesSec = 0; medDpcSum = 0
}

# From CapFrameX sensors
if ($cfxData -and $cfxData.sensors.Count -gt 0) {
    $clkVals = @(); $pwrVals = @(); $tmpVals = @()
    foreach ($s in $cfxData.sensors) {
        if ($s.gpuClkMHz) { $clkVals += $s.gpuClkMHz }
        if ($s.gpuPwrW) { $pwrVals += $s.gpuPwrW }
        if ($s.gpuTempC) { $tmpVals += $s.gpuTempC }
    }
    if ($clkVals.Count -gt 0) {
        $sorted = $clkVals | Sort-Object
        $baseline.medGpuClkMHz = $sorted[[math]::Floor($sorted.Count / 2)]
    }
    if ($pwrVals.Count -gt 0) {
        $sorted = $pwrVals | Sort-Object
        $baseline.medGpuPwrW = $sorted[[math]::Floor($sorted.Count / 2)]
    }
    if ($tmpVals.Count -gt 0) {
        $sorted = $tmpVals | Sort-Object
        $baseline.medGpuTempC = $sorted[[math]::Floor($sorted.Count / 2)]
    }
}

# From GPU dmon
if ($gpuRows.Count -gt 0) {
    $pwrVals = @(); $smVals = @(); $clkVals = @()
    foreach ($r in $gpuRows) {
        if ($r.PwrW -ne '') { $pwrVals += [double]$r.PwrW }
        if ($r.SmPct -ne '') { $smVals += [double]$r.SmPct }
        if ($r.GfxClkMHz -ne '') { $clkVals += [double]$r.GfxClkMHz }
    }
    if ($pwrVals.Count -gt 0) { $s = $pwrVals | Sort-Object; $baseline.medDmonPwrW = $s[[math]::Floor($s.Count/2)] }
    if ($smVals.Count -gt 0) { $s = $smVals | Sort-Object; $baseline.medDmonSmPct = $s[[math]::Floor($s.Count/2)] }
    if ($clkVals.Count -gt 0) { $s = $clkVals | Sort-Object; $baseline.medDmonClkMHz = $s[[math]::Floor($s.Count/2)] }
}

# From perf counters
$sysPerf = $perfRows | Where-Object { $_.Cpu -eq '-1' }
if ($sysPerf.Count -gt 0) {
    $cpuVals = @(); $pgVals = @()
    foreach ($r in $sysPerf) {
        if ($r.TotalCpuPct -ne '') { $cpuVals += [double]$r.TotalCpuPct }
        if ($r.PagesSec -ne '') { $pgVals += [double]$r.PagesSec }
    }
    if ($cpuVals.Count -gt 0) { $s = $cpuVals | Sort-Object; $baseline.medCpuPct = $s[[math]::Floor($s.Count/2)] }
    if ($pgVals.Count -gt 0) { $s = $pgVals | Sort-Object; $baseline.medPagesSec = $s[[math]::Floor($s.Count/2)] }
}

# ---- Detect hitches ----
Write-Host 'Detecting hitches...' -ForegroundColor Gray
$hitches = New-Object System.Collections.ArrayList

if ($cfxData) {
    # Mode A: frame-level detection from CapFrameX
    foreach ($f in $cfxData.frames) {
        if ($f.ftMs -ge $HitchThresholdMs) {
            [void]$hitches.Add(@{
                epochMs = $f.epochMs; timeSec = $f.timeSec; source = 'capframex'
                ftMs = $f.ftMs; cpuActMs = $f.cpuActMs; gpuActMs = $f.gpuActMs
                pcLatMs = $f.pcLatMs; dropped = $f.dropped; frameIdx = $f.idx
            })
        }
    }
} else {
    # Mode B: infer from perf counter anomalies
    foreach ($r in $sysPerf) {
        $anomaly = $false
        if ($r.TotalCpuPct -ne '' -and [double]$r.TotalCpuPct -gt 95) { $anomaly = $true }
        if ($r.PagesSec -ne '' -and [double]$r.PagesSec -gt 5000) { $anomaly = $true }
        if ($anomaly) {
            [void]$hitches.Add(@{
                epochMs = [long]$r.EpochMs; timeSec = 0; source = 'perf_counter'
                ftMs = 0; cpuActMs = 0; gpuActMs = 0; pcLatMs = 0; dropped = $false; frameIdx = -1
            })
        }
    }
    # Also check per-CPU DPC spikes
    $cpuPerf = $perfRows | Where-Object { $_.Cpu -ne '-1' }
    $dpcByEpoch = @{}
    foreach ($r in $cpuPerf) {
        $em = $r.EpochMs
        if (-not $dpcByEpoch.ContainsKey($em)) { $dpcByEpoch[$em] = 0 }
        if ($r.DpcPct -ne '') { $dpcByEpoch[$em] += [double]$r.DpcPct }
    }
    foreach ($em in $dpcByEpoch.Keys) {
        if ($dpcByEpoch[$em] -gt 30) {
            $already = $false
            foreach ($h in $hitches) {
                if ([math]::Abs($h.epochMs - [long]$em) -lt 1000) { $already = $true; break }
            }
            if (-not $already) {
                [void]$hitches.Add(@{
                    epochMs = [long]$em; timeSec = 0; source = 'dpc_spike'
                    ftMs = 0; cpuActMs = 0; gpuActMs = 0; pcLatMs = 0; dropped = $false; frameIdx = -1
                })
            }
        }
    }
}

Write-Host ('  Found ' + $hitches.Count + ' hitches >= ' + $HitchThresholdMs + 'ms')

# ---- Sort by severity ----
$hitches = @($hitches | Sort-Object { $_.ftMs } -Descending)

# ---- Correlate and classify ----
Write-Host 'Correlating across all data sources...' -ForegroundColor Gray
$windowMs = 1500

$classified = New-Object System.Collections.ArrayList
$catCounts = @{
    SHADER_COMPILE = 0; DPC_STORM = 0; IO_STORM = 0; NETWORK = 0
    THERMAL = 0; GPU_BOUND = 0; CPU_BOUND = 0; UNKNOWN = 0
}

$displayCount = [math]::Min($TopN, $hitches.Count)

foreach ($h in $hitches) {
    $perf = Get-PerfSnapshot -epochMs $h.epochMs -perfRows $perfRows -windowMs $windowMs
    $gpu = Get-GpuSnapshot -epochMs $h.epochMs -gpuRows $gpuRows -windowMs $windowMs
    $ping = Get-PingSnapshot -epochMs $h.epochMs -pingRows $pingRows -windowMs $windowMs -gwIp $gwIp
    $procs = Get-ProcessSnapshot -epochMs $h.epochMs -procRows $procRows -windowMs 5000

    $sensor = $null
    if ($cfxData -and $cfxData.sensors.Count -gt 0) {
        $sensor = Find-NearestSensor -timeSec $h.timeSec -sensors $cfxData.sensors
    }

    $snap = @{
        ftMs = $h.ftMs; cpuActMs = $h.cpuActMs; gpuActMs = $h.gpuActMs
        pcLatMs = $h.pcLatMs; perf = $perf; gpu = $gpu; ping = $ping
        sensor = $sensor; procs = $procs; timeSec = $h.timeSec
        source = $h.source
    }

    $result = Classify-Hitch -snap $snap -baseline $baseline
    $catCounts[$result.category]++

    [void]$classified.Add(@{
        hitch = $h; snap = $snap; classification = $result
    })
}

# ============================================================================
# OUTPUT
# ============================================================================

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host '  Results' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

# ---- Summary ----
$tagStr = ''
if ($meta) { $tagStr = $meta.tag }
Write-Host ('  Tag:        ' + $tagStr)
if ($cfxData) {
    Write-Host ('  CapFrameX:  ' + $cfxData.frameCount + ' frames, ' + $cfxData.avgFps + ' FPS, ' + [math]::Round($cfxData.durationSec, 0) + 's')
}
Write-Host ('  Hitches:    ' + $hitches.Count + ' (threshold ' + $HitchThresholdMs + 'ms)')
Write-Host ''

# ---- Category breakdown ----
Write-Host '  Root Cause Breakdown:' -ForegroundColor Yellow
$totalH = $hitches.Count
if ($totalH -eq 0) { $totalH = 1 }
foreach ($cat in @('SHADER_COMPILE', 'DPC_STORM', 'IO_STORM', 'NETWORK', 'THERMAL', 'GPU_BOUND', 'CPU_BOUND', 'UNKNOWN')) {
    $n = $catCounts[$cat]
    $pct = [math]::Round(($n / $totalH) * 100, 0)
    $bar = ''
    $barLen = [math]::Min(20, [int]($pct / 5))
    for ($i = 0; $i -lt $barLen; $i++) { $bar += '|' }
    $color = 'Gray'
    if ($n -gt 0) { $color = 'White' }
    if ($cat -eq 'SHADER_COMPILE' -and $n -gt 0) { $color = 'Red' }
    if ($cat -eq 'DPC_STORM' -and $n -gt 0) { $color = 'Red' }
    if ($cat -eq 'IO_STORM' -and $n -gt 0) { $color = 'Yellow' }
    if ($cat -eq 'NETWORK' -and $n -gt 0) { $color = 'Yellow' }
    Write-Host ('    ' + $cat.PadRight(18) + $n.ToString().PadLeft(4) + ' (' + $pct.ToString().PadLeft(3) + '%) ' + $bar) -ForegroundColor $color
}
Write-Host ''

# ---- Top N hitches detail ----
Write-Host ('  Top ' + $displayCount + ' Worst Hitches:') -ForegroundColor Yellow
Write-Host ('  ' + '#'.PadRight(4) + 'TimeSec'.PadRight(10) + 'FtMs'.PadRight(10) + 'Category'.PadRight(18) + 'Conf'.PadRight(7) + 'Evidence')
Write-Host ('  ' + ('-' * 90))

for ($i = 0; $i -lt $displayCount; $i++) {
    $c = $classified[$i]
    $h = $c.hitch
    $cl = $c.classification
    $s = $c.snap

    $timeStr = [math]::Round($h.timeSec, 1).ToString()
    $ftStr = [math]::Round($h.ftMs, 1).ToString()

    # Build detail string
    $detail = $cl.evidence
    if ($s.perf) {
        $detail += ' | DPC=' + $s.perf.dpcSum + '%'
        if ($s.perf.pagesSec -gt 0) { $detail += ' Pg=' + $s.perf.pagesSec }
    }
    if ($s.ping -and $s.ping.gwRttMs -ne $null) {
        $detail += ' | GW=' + $s.ping.gwRttMs + 'ms'
    }

    $color = 'White'
    if ($cl.category -eq 'SHADER_COMPILE') { $color = 'Red' }
    elseif ($cl.category -eq 'DPC_STORM') { $color = 'Red' }
    elseif ($cl.category -eq 'IO_STORM') { $color = 'Yellow' }
    elseif ($cl.category -eq 'NETWORK') { $color = 'Yellow' }
    elseif ($cl.category -eq 'UNKNOWN') { $color = 'DarkGray' }

    Write-Host ('  ' + ($i+1).ToString().PadRight(4) + $timeStr.PadRight(10) + $ftStr.PadRight(10) + $cl.category.PadRight(18) + $cl.confidence.PadRight(7) + $detail) -ForegroundColor $color
}

# ---- Aggregate comparison ----
if ($cfxData -and $cfxData.sensors.Count -gt 0) {
    Write-Host ''
    Write-Host '  Normal vs Hitch Comparison:' -ForegroundColor Yellow
    Write-Host ('  ' + 'Metric'.PadRight(22) + 'Session Median'.PadRight(18) + 'Hitch Avg'.PadRight(18) + 'Delta')
    Write-Host ('  ' + ('-' * 70))

    # Compute hitch-window averages from classified hitches
    $hitchGpuLoad = @(); $hitchGpuPwr = @(); $hitchGpuClk = @()
    foreach ($c in $classified) {
        if ($c.snap.sensor) {
            if ($c.snap.sensor.gpuLoadPct) { $hitchGpuLoad += $c.snap.sensor.gpuLoadPct }
            if ($c.snap.sensor.gpuPwrW) { $hitchGpuPwr += $c.snap.sensor.gpuPwrW }
            if ($c.snap.sensor.gpuClkMHz) { $hitchGpuClk += $c.snap.sensor.gpuClkMHz }
        }
    }

    if ($hitchGpuClk.Count -gt 0) {
        $hAvg = [math]::Round(($hitchGpuClk | Measure-Object -Average).Average, 0)
        $delta = $hAvg - [math]::Round($baseline.medGpuClkMHz, 0)
        $sign = '+'; if ($delta -lt 0) { $sign = '' }
        Write-Host ('  ' + 'GPU Clock (MHz)'.PadRight(22) + ([math]::Round($baseline.medGpuClkMHz, 0).ToString()).PadRight(18) + $hAvg.ToString().PadRight(18) + $sign + $delta)
    }
    if ($hitchGpuPwr.Count -gt 0) {
        $hAvg = [math]::Round(($hitchGpuPwr | Measure-Object -Average).Average, 0)
        $delta = $hAvg - [math]::Round($baseline.medGpuPwrW, 0)
        $sign = '+'; if ($delta -lt 0) { $sign = '' }
        Write-Host ('  ' + 'GPU Power (W)'.PadRight(22) + ([math]::Round($baseline.medGpuPwrW, 0).ToString()).PadRight(18) + $hAvg.ToString().PadRight(18) + $sign + $delta)
    }
    if ($hitchGpuLoad.Count -gt 0) {
        $hAvg = [math]::Round(($hitchGpuLoad | Measure-Object -Average).Average, 0)
        Write-Host ('  ' + 'GPU Load (%)'.PadRight(22) + '(see dmon)'.PadRight(18) + $hAvg.ToString().PadRight(18) + '')
    }
}

Write-Host ''

# ---- Save JSON results ----
$jsonOut = Join-Path $SessionDir 'analysis_results.json'
$jsonData = [ordered]@{
    sessionDir = $SessionDir
    capFrameXFile = $CapFrameXFile
    hitchThresholdMs = $HitchThresholdMs
    totalHitches = $hitches.Count
    categoryBreakdown = $catCounts
    baseline = $baseline
}
$jsonData | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonOut -Encoding utf8
Write-Host ('  Results saved: ' + $jsonOut) -ForegroundColor Green
Write-Host ''
