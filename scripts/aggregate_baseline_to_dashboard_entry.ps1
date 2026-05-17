<#
.SYNOPSIS
    Aggregate a baseline capture directory into a dashboard v3 experiment entry.
.DESCRIPTION
    Reads the full suite outputs from a baseline capture directory and builds a
    single JSON object matching the dashboard data schema used by
    experiments.js / experiments_generated.js:

      { id, name, shortName, date, description, tags, systemInfo, registry,
        smiAnalysis, performance, cpuData, latencymon, frameTiming,
        gpuUtilization, dpcIsrAnalysis, interruptTopology }

    Missing sections fill with nulls/empties so the dashboard renders without
    errors. The output JSON is meant to be dropped into captures/experiments/
    so generate_dashboard_data.ps1 picks it up on next regen.
.EXAMPLE
    .\aggregate_baseline_to_dashboard_entry.ps1 -InputDir captures\baselines\BASELINE_POST_REBOOT_CLEAN_20260422-103000 -OutputPath 40_aggregate\experiment_entry.json
#>
param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$InputDir,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [string]$Label = ''
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $InputDir)) {
    throw "Input directory not found: $InputDir"
}

function Read-JsonOrEmpty {
    param([string]$Path, $Default = $null)
    if (-not (Test-Path $Path)) { return $Default }
    $raw = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    try { return ($raw | ConvertFrom-Json) } catch { return $Default }
}

function Get-RunLabelFromDir {
    param([string]$Dir)
    $leaf = Split-Path $Dir -Leaf
    # Strip trailing _YYYYMMDD-HHMMSS suffix if present
    if ($leaf -match '^(.+?)_\d{8}-\d{6}$') {
        return $Matches[1]
    }
    return $leaf
}

function Get-IsoDateFromDir {
    param([string]$Dir)
    $leaf = Split-Path $Dir -Leaf
    if ($leaf -match '_(\d{8})-(\d{6})$') {
        $d = $Matches[1]
        $t = $Matches[2]
        return ($d.Substring(0,4) + '-' + $d.Substring(4,2) + '-' + $d.Substring(6,2) + 'T' + $t.Substring(0,2) + ':' + $t.Substring(2,2) + ':' + $t.Substring(4,2))
    }
    return (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
}

function Build-SystemInfo {
    $cpu = try { (Get-CimInstance Win32_Processor -ErrorAction Stop).Name } catch { 'unknown' }
    $cs = try { Get-CimInstance Win32_ComputerSystem -ErrorAction Stop } catch { $null }
    $os = try { Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { $null }
    $gpu = try { (Get-CimInstance Win32_VideoController -ErrorAction Stop | Select-Object -First 1).Name } catch { 'unknown' }

    $ramGb = if ($cs) { [Math]::Round($cs.TotalPhysicalMemory / 1GB, 0) } else { 0 }
    $coreCount = if ($cs) { $cs.NumberOfProcessors.ToString() + 'C/' + $cs.NumberOfLogicalProcessors.ToString() + 'T' } else { 'unknown' }

    return @{
        hostname = if ($cs) { $cs.Name } else { '' }
        cpu = $cpu
        cores = $coreCount
        ram = ($ramGb.ToString() + ' GB')
        os = if ($os) { $os.Caption + ' Build ' + $os.BuildNumber } else { 'unknown' }
        gpu = $gpu
    }
}

# ── Assemble entry ──────────────────────────────────────────────────────────

if ($Label -eq '') { $Label = Get-RunLabelFromDir -Dir $InputDir }
$entryDate = Get-IsoDateFromDir -Dir $InputDir

$idleDir = Join-Path $InputDir '20_idle'
$loadedDir = Join-Path $InputDir '30_loaded'

$perfIdle = Read-JsonOrEmpty (Join-Path $idleDir 'pipeline_idle.json') @{}
$perfLoaded = Read-JsonOrEmpty (Join-Path $loadedDir 'pipeline_loaded.json') @{}
$xperfIdle = Read-JsonOrEmpty (Join-Path $idleDir 'xperf_idle.json') @{}
$procmonIdle = Read-JsonOrEmpty (Join-Path $idleDir 'procmon_idle_analyzed.json') @{}
$latmonIdlePath = Join-Path $idleDir 'latmon_idle_report.txt'
$latmonIdle = if (Test-Path $latmonIdlePath) { Get-Content $latmonIdlePath -Raw } else { $null }
$manifest = Read-JsonOrEmpty (Join-Path $InputDir 'manifest.json') @{}

# Performance block — pipeline.ps1 writes perf counter names verbatim under
# a `performance` sub-object: performance['% dpc time[_total]'].avg, etc.
function Get-PerfCounter {
    param($PerfData, [string]$CounterName)
    if (-not $PerfData) { return $null }
    if (-not $PerfData.performance) { return $null }
    $val = $PerfData.performance.$CounterName
    if (-not $val) { return $null }
    return @{
        avg = $val.avg
        min = $val.min
        max = $val.max
        stdev = $val.stdev
    }
}

$perfBlock = @{}
$dpcIdle = Get-PerfCounter -PerfData $perfIdle -CounterName '% dpc time[_total]'
if ($dpcIdle) { $perfBlock['DPCTimePct'] = $dpcIdle }
$intIdle = Get-PerfCounter -PerfData $perfIdle -CounterName '% interrupt time[_total]'
if ($intIdle) { $perfBlock['InterruptTimePct'] = $intIdle }
$intrPerSec = Get-PerfCounter -PerfData $perfIdle -CounterName 'interrupts/sec[_total]'
if ($intrPerSec) { $perfBlock['InterruptsPerSec'] = $intrPerSec }

# CPU data — passthrough from pipeline (nested under .performance typically, but
# generate_dashboard_data.ps1 outputs cpuData at top level in the entry. Try both.)
$cpuData = @()
if ($perfIdle -and $perfIdle.cpuData) {
    $cpuData = $perfIdle.cpuData
} elseif ($perfIdle -and $perfIdle.performance -and $perfIdle.performance.cpuData) {
    $cpuData = $perfIdle.performance.cpuData
}

# LatencyMon — pass raw text if present
$latencymonBlock = $null
if ($latmonIdle) {
    $latencymonBlock = @{
        capturedAt = $entryDate
        durationMin = 5
        raw = $latmonIdle
    }
}

# DPC/ISR analysis from xperf
$dpcIsrBlock = $null
if ($xperfIdle -and $xperfIdle.top_drivers) {
    $dpcIsrBlock = @{
        topDrivers = @($xperfIdle.top_drivers | Select-Object -First 10)
        totalDpcs = $xperfIdle.total_dpcs
        totalIsrs = $xperfIdle.total_isrs
    }
}

# Describe the run
$description = 'Full-suite baseline capture (idle + Prime95 SmallFFT load). '
if ($manifest -and $manifest.latmon_skipped) {
    $description += 'LatencyMon skipped (CLI preflight failed). '
}
if ($perfLoaded -and $perfLoaded.DPCTimePct) {
    $description += 'Loaded DPC% avg=' + $perfLoaded.DPCTimePct.avg + '.'
}

$entry = @{
    id = 'gen_' + ($entryDate -replace '[^0-9]', '').Substring(0, 14) + '_' + $Label
    name = $Label
    shortName = $Label
    date = $entryDate
    description = $description.Trim()
    tags = @('baseline', 'generated', 'full-suite')
    systemInfo = Build-SystemInfo
    registry = @{}
    smiAnalysis = @{
        source = 'baseline-full-capture'
        verdict = 'BASELINE'
        highLatencyDpcCount = 0
        maxBucketUs = 0
        driversWithHighDpc = 0
        correlationScore = 100
        captureDurationSec = 60
    }
    performance = $perfBlock
    cpuData = $cpuData
    latencymon = $latencymonBlock
    frameTiming = $null
    gpuUtilization = $null
    dpcIsrAnalysis = $dpcIsrBlock
    interruptTopology = $null
}

$outDir = Split-Path $OutputPath -Parent
if ($outDir -and -not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

$entry | ConvertTo-Json -Depth 20 | Set-Content -Path $OutputPath -Encoding UTF8
Write-Output ('Dashboard entry written: ' + $OutputPath)
