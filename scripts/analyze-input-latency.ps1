#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Analyze an ETL trace for input-to-display pipeline latency stages.
.DESCRIPTION
    Parses WPR/xperf ETL traces captured with the InputLatency profile.
    Extracts per-stage event counts and DPC histogram data.
    Uses xperf -a dumper with provider GUID filtering for stage analysis.
.EXAMPLE
    .\analyze-input-latency.ps1 -EtlFile "captures\experiments\...\trace.etl"
.OUTPUTS
    [hashtable] with stages, dpcAlerts, totalEventsAnalyzed, analysisMethod
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$EtlFile,

    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $EtlFile)) {
    Write-Error ('ETL file not found: ' + $EtlFile)
    return $null
}

if ($OutDir -eq '') { $OutDir = Split-Path $EtlFile -Parent }

$xperfPath = 'C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\xperf.exe'
if (-not (Test-Path $xperfPath)) {
    Write-Warning 'xperf.exe not found — install Windows ADK'
    return $null
}

Write-Host '=== Input Latency Analysis ===' -ForegroundColor Cyan
Write-Host ('ETL: ' + $EtlFile)
Write-Host ''

$result = [ordered]@{
    analysisMethod      = 'xperf-dumper'
    totalEventsAnalyzed = 0
    stages              = [ordered]@{}
    dpcHistogram        = @()
    dpcAlerts           = @()
    providerEventCounts = [ordered]@{}
}

# --- Stage 1: DPC/ISR histogram analysis (always works) ---
Write-Host '[1/4] DPC/ISR histogram analysis...' -ForegroundColor Yellow
$dpcIsrReport = Join-Path $OutDir 'dpcisr_report.txt'
if (-not (Test-Path $dpcIsrReport)) {
    Write-Host '  Generating DPC/ISR report...'
    & $xperfPath -i $EtlFile -o $dpcIsrReport -a dpcisr 2>&1 | Out-Null
}

if (Test-Path $dpcIsrReport) {
    $currentModule = ''
    $currentTotal  = 0
    $currentMaxUs  = 0
    $highLatCount  = 0
    $dpcDrivers    = @()

    foreach ($rline in (Get-Content $dpcIsrReport)) {
        if ($rline -match 'Total = (\d+) for module (\S+)') {
            if ($currentModule -ne '' -and $currentTotal -gt 0) {
                $dpcDrivers += [ordered]@{
                    module       = $currentModule
                    count        = $currentTotal
                    maxUs        = $currentMaxUs
                    highLatCount = $highLatCount
                }
            }
            $currentModule = $Matches[2]
            $currentTotal  = [int]$Matches[1]
            $currentMaxUs  = 0
            $highLatCount  = 0
        }
        if ($rline -match 'Elapsed Time.*<=\s+(\d+) usecs,\s+(\d+),') {
            $bucket = [int]$Matches[1]
            $count  = [int]$Matches[2]
            if ($count -gt 0 -and $bucket -gt $currentMaxUs) { $currentMaxUs = $bucket }
            if ($bucket -ge 512 -and $count -gt 0) { $highLatCount += $count }
        }
    }
    if ($currentModule -ne '' -and $currentTotal -gt 0) {
        $dpcDrivers += [ordered]@{
            module       = $currentModule
            count        = $currentTotal
            maxUs        = $currentMaxUs
            highLatCount = $highLatCount
        }
    }

    $result.dpcHistogram = $dpcDrivers | Sort-Object { $_.maxUs } -Descending | Select-Object -First 15

    # Alerts
    foreach ($d in $dpcDrivers) {
        if ($d.module -eq 'nvlddmkm.sys' -and $d.highLatCount -gt 0) {
            $result.dpcAlerts += [ordered]@{
                driver   = 'nvlddmkm.sys'
                severity = 'HIGH'
                message  = 'NVIDIA DPC >500us: ' + $d.highLatCount + ' occurrences (max bucket ' + $d.maxUs + 'us)'
            }
            Write-Host ('  ALERT: nvlddmkm.sys ' + $d.highLatCount + ' DPCs >500us') -ForegroundColor Red
        }
        if ($d.module -match 'EasyAntiCheat|BEService|vgk\.sys') {
            $result.dpcAlerts += [ordered]@{
                driver   = $d.module
                severity = 'INFO'
                message  = 'Anti-cheat in trace: ' + $d.module + ' (' + $d.count + ' DPCs, max ' + $d.maxUs + 'us)'
            }
            Write-Host ('  INFO: ' + $d.module + ' detected in DPC trace') -ForegroundColor Yellow
        }
    }

    $topModule = ''
    $topMax    = 0
    foreach ($d in $dpcDrivers) {
        if ($d.maxUs -gt $topMax) { $topMax = $d.maxUs; $topModule = $d.module }
    }
    if ($topModule -ne '') {
        Write-Host ('  Top DPC: ' + $topModule + ' max ' + $topMax + 'us') -ForegroundColor Green
    }
} else {
    Write-Host '  DPC/ISR report not available' -ForegroundColor Yellow
}

# --- Stage 2: Per-provider event extraction ---
$providers = [ordered]@{
    'Win32k (Input)'   = '8C416C79-D49B-4F01-A467-E56D3AA8234C'
    'DWM Core'         = '9E9BBA3C-2E38-40CB-99F4-9E8281425164'
    'DxgKrnl (GPU)'    = '802EC45A-1E99-4B83-9920-87C98277BA9D'
    'DXGI (Present)'   = 'CA11C036-0102-4A2D-A6AD-F03CFED5D3C9'
    'HID Class'        = '6465DA78-E7A0-4F39-B084-8F53C7C30DC6'
    'USB Hub'          = 'AC52AD17-CC01-4F85-8DF5-4DCE4333C99B'
}

Write-Host ''
Write-Host '[2/4] Extracting per-provider event counts...' -ForegroundColor Yellow

foreach ($pName in $providers.Keys) {
    $guid    = $providers[$pName]
    $dumpFile = Join-Path $OutDir ('events_' + $pName.Replace(' ','_').Replace('(','').Replace(')','') + '.txt')

    try {
        & $xperfPath -i $EtlFile -o $dumpFile -a dumper -provider ('{' + $guid + '}') 2>&1 | Out-Null
        if (Test-Path $dumpFile) {
            $lineCount = @(Get-Content $dumpFile).Count
            $result.providerEventCounts[$pName] = $lineCount
            $result.totalEventsAnalyzed += $lineCount
            Write-Host ('  ' + $pName + ': ' + $lineCount + ' event lines') -ForegroundColor Green
        } else {
            $result.providerEventCounts[$pName] = 0
            Write-Host ('  ' + $pName + ': no events (provider not in trace)') -ForegroundColor Yellow
        }
    } catch {
        $result.providerEventCounts[$pName] = 0
        Write-Host ('  ' + $pName + ': extraction failed') -ForegroundColor Red
    }
}

# --- Stage 2B: DWM frame timing extraction (fallback for PresentMon) ---
Write-Host ''
Write-Host '[2B/4] Extracting DWM frame timing from DxgKrnl events...' -ForegroundColor Yellow

$dwmFrameTiming = $null
$dxgiDumpFile = Join-Path $OutDir 'events_DXGI_Present.txt'
if (Test-Path $dxgiDumpFile) {
    # Parse DXGI Present/Start event timestamps from xperf dumper output
    # Format: "Microsoft-Windows-DXGI/Present/win:Start, TIMESTAMP, process (PID), ..."
    $timestamps = @()
    foreach ($line in (Get-Content $dxgiDumpFile)) {
        if ($line -match 'DXGI/Present/win:Start,\s+(\d+),') {
            $timestamps += [double]$Matches[1]
        }
    }
    if ($timestamps.Count -gt 10) {
        # Compute inter-present deltas as frame times (microseconds -> milliseconds)
        $frameTimes = @()
        for ($i = 1; $i -lt $timestamps.Count; $i++) {
            $deltaUs = $timestamps[$i] - $timestamps[$i - 1]
            $deltaMs = $deltaUs / 1000.0
            # Filter: 1ms < frame time < 200ms (0.5fps to 1000fps range)
            if ($deltaMs -gt 1 -and $deltaMs -lt 200) {
                $frameTimes += $deltaMs
            }
        }
        if ($frameTimes.Count -gt 10) {
            $sorted = $frameTimes | Sort-Object
            $ftCount = $sorted.Count
            $ftAvg   = ($sorted | Measure-Object -Average).Average
            $ftP50   = $sorted[[math]::Floor($ftCount * 0.50)]
            $ftP95   = $sorted[[math]::Floor($ftCount * 0.95)]
            $ftP99   = $sorted[[math]::Floor($ftCount * 0.99)]

            # Stutter detection
            $ftStutters  = @()
            $halfWin     = 15
            for ($i = 0; $i -lt $frameTimes.Count; $i++) {
                $wS = [math]::Max(0, $i - $halfWin)
                $wE = [math]::Min($frameTimes.Count - 1, $i + $halfWin)
                $win = @($frameTimes[$wS..$wE] | Sort-Object)
                $med = $win[[math]::Floor($win.Count / 2)]
                if ($frameTimes[$i] -gt ($med * 2) -and $frameTimes[$i] -lt 50 -and $med -gt 0) {
                    $ftStutters += @{
                        frameIndex  = $i
                        frameTimeMs = [math]::Round($frameTimes[$i], 2)
                        medianMs    = [math]::Round($med, 2)
                    }
                }
            }

            $dwmFrameTiming = @{
                source        = 'DxgKrnl-Present'
                totalFrames   = $ftCount
                stutterCount  = $ftStutters.Count
                stutters      = $ftStutters
                frameTimeMs   = @{
                    avg  = [math]::Round($ftAvg, 2)
                    p50  = [math]::Round($ftP50, 2)
                    p95  = [math]::Round($ftP95, 2)
                    p99  = [math]::Round($ftP99, 2)
                    max  = [math]::Round($sorted[-1], 2)
                    min  = [math]::Round($sorted[0], 2)
                }
                fps = @{
                    avg   = [math]::Round(1000.0 / $ftAvg, 1)
                    p1Low = [math]::Round(1000.0 / $ftP99, 1)
                }
            }
            Write-Host ('  Extracted ' + $ftCount + ' frames from DXGI presents') -ForegroundColor Green
            Write-Host ('  P50: ' + [math]::Round($ftP50, 1) + 'ms | P95: ' + [math]::Round($ftP95, 1) + 'ms | P99: ' + [math]::Round($ftP99, 1) + 'ms') -ForegroundColor Green
            Write-Host ('  Stutters: ' + $ftStutters.Count) -ForegroundColor Green
        } else {
            Write-Host '  Not enough valid frame deltas (need >10)' -ForegroundColor Yellow
        }
    } else {
        Write-Host '  Not enough timestamps in DXGI dump (need >10)' -ForegroundColor Yellow
    }
} else {
    Write-Host '  DXGI dump file not found — run with InputLatency profile' -ForegroundColor Yellow
}

$result['frameTiming'] = $dwmFrameTiming

# --- Stage 2C: DPC-to-stutter correlation ---
if ($null -ne $dwmFrameTiming -and $dwmFrameTiming.stutterCount -gt 0 -and $result.dpcHistogram.Count -gt 0) {
    Write-Host ''
    Write-Host '[2C/4] Correlating stutters with DPC drivers...' -ForegroundColor Yellow
    # Best-effort: blame the driver with the highest max DPC latency
    # (precise per-event correlation requires WPA-level analysis)
    $topDpcDriver = ($result.dpcHistogram | Select-Object -First 1)
    $correlations = @()
    foreach ($st in $dwmFrameTiming.stutters) {
        $blamed = 'unknown'
        $blamedUs = 0
        if ($null -ne $topDpcDriver) {
            $blamed = $topDpcDriver.module
            $blamedUs = $topDpcDriver.maxUs
        }
        $correlations += @{
            frameIndex   = $st.frameIndex
            frameTimeMs  = $st.frameTimeMs
            blamedDriver = $blamed
            dpcMaxUs     = $blamedUs
        }
    }
    $result['stutterCorrelation'] = $correlations
    Write-Host ('  ' + $correlations.Count + ' stutter(s) correlated (top DPC: ' + $topDpcDriver.module + ' ' + $topDpcDriver.maxUs + 'us)') -ForegroundColor Green
}

# --- Stage 3: Pipeline stage summary ---
Write-Host ''
Write-Host '[3/4] Pipeline stage summary...' -ForegroundColor Yellow

$hidEvents   = $result.providerEventCounts['HID Class']
$win32kEvents = $result.providerEventCounts['Win32k (Input)']
$dxgEvents   = $result.providerEventCounts['DxgKrnl (GPU)']
$dwmEvents   = $result.providerEventCounts['DWM Core']
$dxgiEvents  = $result.providerEventCounts['DXGI (Present)']

$result.stages = [ordered]@{
    usbToKernel = [ordered]@{
        description = 'USB HID -> Win32k input processing'
        hidEvents   = $hidEvents
        win32kEvents = $win32kEvents
        status      = 'measured'
    }
    kernelToGame = [ordered]@{
        description = 'Win32k -> Game thread pickup'
        note        = 'Requires per-event correlation in WPA for precise timing'
        status      = 'event-counts-only'
    }
    gameToGpu = [ordered]@{
        description = 'Game render -> GPU submit (Present)'
        dxgiEvents  = $dxgiEvents
        dxgEvents   = $dxgEvents
        status      = 'measured'
    }
    gpuToDwm = [ordered]@{
        description = 'GPU render -> DWM flip -> Display'
        dwmEvents   = $dwmEvents
        status      = 'measured'
    }
    dpcOverhead = [ordered]@{
        description = 'DPC/ISR overhead (system-wide)'
        topDrivers  = @($result.dpcHistogram | Select-Object -First 5)
        alerts      = $result.dpcAlerts
        status      = 'measured'
    }
}

# --- Stage 4: Output summary ---
Write-Host ''
Write-Host '[4/4] Results' -ForegroundColor Yellow
Write-Host ('  Total events analyzed: ' + $result.totalEventsAnalyzed)
Write-Host ('  DPC alerts: ' + $result.dpcAlerts.Count)
Write-Host ('  Providers with data: ' + @($result.providerEventCounts.Values | Where-Object { $_ -gt 0 }).Count + '/' + $providers.Count)

# Save analysis JSON
$jsonPath = Join-Path $OutDir 'input_latency_analysis.json'
($result | ConvertTo-Json -Depth 8) | Out-File -FilePath $jsonPath -Encoding UTF8
Write-Host ''
Write-Host ('JSON: ' + $jsonPath) -ForegroundColor Green
Write-Host ''
Write-Host 'Note: For precise per-event latency correlation, open trace.etl in WPA' -ForegroundColor Cyan
Write-Host '  and use Generic Events -> Microsoft.Windows.Win32kBase.Input -> MousePacketLatency' -ForegroundColor Cyan

Write-Host ''
Write-Host 'Done.' -ForegroundColor Cyan

return $result
