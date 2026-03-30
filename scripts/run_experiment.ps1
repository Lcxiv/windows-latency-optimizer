<#
.SYNOPSIS
    Lightweight experiment capture (perf counters + registry only, no WPR).
.DESCRIPTION
    Captures performance counters and registry snapshot without WPR/xperf traces.
    Faster than pipeline.ps1 for quick A/B comparisons.
.EXAMPLE
    .\run_experiment.ps1 -Label "QUICK_TEST" -Description "Quick idle check" -DurationSec 60
#>
#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory=$true)]
    [string]$Label,

    [Parameter(Mandatory=$true)]
    [string]$Description,

    [int]$DurationSec = 120,

    [string]$OutDir = "$PSScriptRoot\..\captures\experiments"
)

# =============================================================================
# run_experiment.ps1
# Capture a timestamped experiment JSON snapshot:
#   - System performance counters (DurationSec samples at 1s intervals)
#   - Per-CPU interrupt/DPC distribution
#   - Registry state (MMCSS, Defender, device affinities)
#
# Usage:
#   .\run_experiment.ps1 -Label "EXP07_HPET_OFF" -Description "Disabled HPET via bcdedit"
#   .\run_experiment.ps1 -Label "EXP07_HPET_OFF" -Description "..." -DurationSec 60
#
# Output: captures/experiments/YYYYMMDD_HHMMSS_EXP07_HPET_OFF.json
# =============================================================================

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outFile   = Join-Path $OutDir "${timestamp}_${Label}.json"

Write-Host "=== run_experiment.ps1 ==="
Write-Host "Label:       $Label"
Write-Host "Description: $Description"
Write-Host "Duration:    $($DurationSec)s at 1s intervals"
Write-Host "Output:      $outFile"
Write-Host ""

# ---------------------------------------------------------------------------
# Prerequisites check: warn if system is not sufficiently idle
# ---------------------------------------------------------------------------
Write-Host "Checking system idle state..."
$quickCpu = (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 3).CounterSamples |
    Measure-Object CookedValue -Average
if ($quickCpu.Average -gt 15) {
    Write-Warning ('CPU usage is ' + [math]::Round($quickCpu.Average,1) + '% - consider closing background apps before capturing.')
    Write-Host "Waiting 5s then proceeding..."
    Start-Sleep 5
}

# ---------------------------------------------------------------------------
# Performance counter sampling
# ---------------------------------------------------------------------------
Write-Host "Sampling performance counters for $($DurationSec)s..."

$counters = @(
    '\Processor(*)\% Interrupt Time',
    '\Processor(*)\% DPC Time',
    '\Processor(*)\Interrupts/sec',
    '\Processor(_Total)\% Processor Time',
    '\Processor(_Total)\% DPC Time',
    '\Processor(_Total)\% Interrupt Time',
    '\Memory\Available MBytes',
    '\Memory\Pages/sec',
    '\Memory\Page Faults/sec',
    '\PhysicalDisk(_Total)\Avg. Disk sec/Read',
    '\PhysicalDisk(_Total)\Avg. Disk sec/Write',
    '\PhysicalDisk(_Total)\Current Disk Queue Length',
    '\System\Context Switches/sec',
    '\System\Processor Queue Length'
)

$samples = Get-Counter -Counter $counters -SampleInterval 1 -MaxSamples $DurationSec

# Aggregate
$data = @{}
foreach ($sample in $samples) {
    foreach ($cs in $sample.CounterSamples) {
        $key = "$($cs.Path)|$($cs.InstanceName)"
        if (-not $data.ContainsKey($key)) {
            $data[$key] = @{ path=$cs.Path; instance=$cs.InstanceName; values=@() }
        }
        $data[$key].values += $cs.CookedValue
    }
}

function Get-Stats($vals) {
    $m = $vals | Measure-Object -Average -Minimum -Maximum
    return @{ avg=[math]::Round($m.Average,4); min=[math]::Round($m.Minimum,4); max=[math]::Round($m.Maximum,4) }
}

# Build perf counters object
$perf = @{}
foreach ($key in $data.Keys) {
    $entry  = $data[$key]
    $name   = $entry.path.TrimStart('\').Split('\') | Select-Object -Last 1
    $inst   = $entry.instance
    $stats  = Get-Stats $entry.values
    $mapKey = $name
    if ($inst -and $inst -ne '') { $mapKey = $name + '[' + $inst + ']' }
    $perf[$mapKey] = $stats
}

# Build per-CPU summary
$cpuInterrupt  = @{}
$cpuDpc        = @{}
$cpuIntrPerSec = @{}
foreach ($key in $data.Keys) {
    $entry = $data[$key]
    $inst  = $entry.instance
    if ($entry.path -match '% interrupt time') { $cpuInterrupt[$inst]  = Get-Stats $entry.values }
    if ($entry.path -match '% dpc time')       { $cpuDpc[$inst]        = Get-Stats $entry.values }
    if ($entry.path -match 'interrupts/sec')   { $cpuIntrPerSec[$inst] = Get-Stats $entry.values }
}

$cpuData = @()
$cpuNums = $cpuInterrupt.Keys | Where-Object { $_ -ne '_total' } | Sort-Object { [int]$_ }
foreach ($cpu in $cpuNums) {
    $dpc = 0
    if ($cpuDpc.ContainsKey($cpu)) { $dpc = $cpuDpc[$cpu].avg }
    $ips = 0
    if ($cpuIntrPerSec.ContainsKey($cpu)) { $ips = $cpuIntrPerSec[$cpu].avg }
    $cpuData += @{
        cpu          = [int]$cpu
        interruptPct = $cpuInterrupt[$cpu].avg
        dpcPct       = $dpc
        intrPerSec   = $ips
    }
}

# ---------------------------------------------------------------------------
# Registry state capture
# ---------------------------------------------------------------------------
Write-Host "Capturing registry state..."

$reg = @{}

# MMCSS
try {
    $mmcss  = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -ErrorAction Stop
    $games  = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' -ErrorAction Stop
    $reg['SystemResponsiveness']      = $mmcss.SystemResponsiveness
    $reg['NetworkThrottlingIndex']    = $mmcss.NetworkThrottlingIndex
    $reg['GamesSchedulingCategory']   = $games.'Scheduling Category'
    $reg['GamesPriority']             = $games.Priority
    $reg['GamesSFIOPriority']         = $games.'SFIO Priority'
} catch { $reg['MMCSS'] = "error: $($_.Exception.Message)" }

# Defender
try {
    $mp = Get-MpPreference -ErrorAction Stop
    $reg['ScanAvgCPULoadFactor']   = $mp.ScanAvgCPULoadFactor
    $reg['EnableLowCpuPriority']   = [string]$mp.EnableLowCpuPriority
    $epCount = 0; if ($mp.ExclusionPath) { $epCount = $mp.ExclusionPath.Count }
    $reg['ExclusionPathCount']     = $epCount
    $eprCount = 0; if ($mp.ExclusionProcess) { $eprCount = $mp.ExclusionProcess.Count }
    $reg['ExclusionProcessCount']  = $eprCount
} catch { $reg['Defender'] = "error: $($_.Exception.Message)" }

# NVIDIA MSI + PerfLevelSrc
$nvGpuKeys = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -like 'VEN_10DE*' }
if ($nvGpuKeys) {
    $nvKey = $nvGpuKeys | Select-Object -First 1
    $msiPath = "$($nvKey.PSPath)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
    if (Test-Path $msiPath) {
        $msi = Get-ItemProperty $msiPath -ErrorAction SilentlyContinue
        $reg['NvidiaMSISupported']        = $msi.MSISupported
        $reg['NvidiaMessageNumberLimit']  = $msi.MessageNumberLimit
    }
    $reg['PerfLevelSrc'] = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\NVTweak' -ErrorAction SilentlyContinue).PerfLevelSrc
}

# HAGS
$hags = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction SilentlyContinue).HwSchMode
$reg['HwSchMode'] = $hags

# Interrupt affinities for known devices (spot-check)
$affinityChecks = @(
    @{ Name='GPU';    Id='PCI\VEN_10DE' },
    @{ Name='NIC';    Id='PCI\VEN_8086&DEV_125C' },
    @{ Name='USB15B6';Id='PCI\VEN_1022&DEV_15B6' },
    @{ Name='USB15B7';Id='PCI\VEN_1022&DEV_15B7' },
    @{ Name='USB43F7';Id='PCI\VEN_1022&DEV_43F7' }
)
$affinities = @{}
foreach ($check in $affinityChecks) {
    $devKeys = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Enum\PCI" -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like "$($check.Id)*" }
    if ($devKeys) {
        $devKey  = $devKeys | Select-Object -First 1
        $affPath = "$($devKey.PSPath)\Device Parameters\Interrupt Management\Affinity Policy"
        if (Test-Path $affPath) {
            $v = Get-ItemProperty $affPath -ErrorAction SilentlyContinue
            if ($v.AssignmentSetOverride) {
                $hex = '0x' + (($v.AssignmentSetOverride[1..0] | ForEach-Object { $_.ToString('X2') }) -join '')
                $affinities[$check.Name] = @{ DevicePolicy=$v.DevicePolicy; MaskHex=$hex }
            }
        }
    }
}
$reg['InterruptAffinities'] = $affinities

# ---------------------------------------------------------------------------
# Assemble JSON
# ---------------------------------------------------------------------------
$result = [ordered]@{
    schemaVersion = 1
    label         = $Label
    description   = $Description
    capturedAt    = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    durationSec   = $DurationSec
    hostname      = $env:COMPUTERNAME
    registry      = $reg
    performance   = $perf
    cpuData       = $cpuData
    cpuTotal      = $null
}
$totalIntr = $null; if ($cpuInterrupt.ContainsKey('_total')) { $totalIntr = $cpuInterrupt['_total'].avg }
$totalDpc  = $null; if ($cpuDpc.ContainsKey('_total'))       { $totalDpc  = $cpuDpc['_total'].avg }
$totalIps  = $null; if ($cpuIntrPerSec.ContainsKey('_total')){ $totalIps  = $cpuIntrPerSec['_total'].avg }
$result['cpuTotal'] = @{
    interruptPct = $totalIntr
    dpcPct       = $totalDpc
    intrPerSec   = $totalIps
}

$json = $result | ConvertTo-Json -Depth 8
$json | Out-File $outFile -Encoding UTF8

Write-Host ""
Write-Host "=== Capture complete ==="
Write-Host "  CPU 0 interrupt%: $($cpuData | Where-Object { $_.cpu -eq 0 } | Select-Object -ExpandProperty interruptPct)"
Write-Host "  Total DPC%:       $($result.cpuTotal.dpcPct)"
Write-Host "  Total interrupt%: $($result.cpuTotal.interruptPct)"
Write-Host ""
Write-Host "Saved: $outFile"
Write-Host ""
Write-Host "Next step: run .\scripts\generate_dashboard_data.ps1 to update the dashboard."
