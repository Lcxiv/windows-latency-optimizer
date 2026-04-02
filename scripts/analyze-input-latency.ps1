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
