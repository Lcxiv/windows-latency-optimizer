<#
.SYNOPSIS
    Phase 5: Empirical bench — measure storage controller DPC + read latency under load.
.DESCRIPTION
    Read-only measurement script. Runs under 60s of disk I/O while sampling:
      - \PhysicalDisk(*)\Avg. Disk sec/Read
      - \PhysicalDisk(*)\Disk Reads/sec
      - Storage controller driver from PnP (stornvme.sys vs vendor)
      - DPC time attributable to storage stack via xperf summary

    Run once per driver candidate. Compare results before deciding to swap drivers.
    Does NOT mutate driver state. Pure measurement.

    Workload: read 1GB of random offsets from C:\ to thrash NVMe queue.
    Auto-detects Fortnite install path; falls back to Windows dir if missing.

.PARAMETER DriverLabel
    Tag for this run (e.g. "stornvme-inbox", "samsung-vendor"). Used in output filename.

.PARAMETER DurationSec
    Bench window seconds. Default 60.

.EXAMPLE
    .\eac_phase5_storage_path_bench.ps1 -DriverLabel stornvme-inbox -DurationSec 60
#>
#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$DriverLabel,

    [ValidateRange(15, 300)]
    [int]$DurationSec = 60
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outDir = Join-Path $repoRoot ('captures\experiments\exp-storage-bench-' + $DriverLabel + '_' + $timestamp)
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Write-Host '=== Phase 5: Storage Path Bench ===' -ForegroundColor Cyan
Write-Host ('Driver label: ' + $DriverLabel)
Write-Host ('Duration: ' + $DurationSec + 's')
Write-Host ('Output: ' + $outDir)

# ---- Detect storage controller driver ----
$storageDrivers = Get-PnpDevice -Class SCSIAdapter, NVMe -ErrorAction SilentlyContinue
$driverInfo = @()
foreach ($d in $storageDrivers) {
    $svc = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName DEVPKEY_Device_Service -ErrorAction SilentlyContinue).Data
    $loc = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName DEVPKEY_Device_LocationInfo -ErrorAction SilentlyContinue).Data
    $driverInfo += [pscustomobject]@{
        FriendlyName = $d.FriendlyName
        Service      = $svc
        Location     = $loc
        Status       = $d.Status
    }
}
$driverInfo | Format-Table -AutoSize | Out-String | Out-File -FilePath (Join-Path $outDir 'storage_drivers.txt') -Encoding utf8
$driverInfo | ConvertTo-Json -Depth 3 | Out-File -FilePath (Join-Path $outDir 'storage_drivers.json') -Encoding utf8

# ---- Pick workload target ----
$fortnitePak = 'C:\Program Files\Epic Games\Fortnite\FortniteGame\Content\Paks'
$workloadDir = if (Test-Path $fortnitePak) { $fortnitePak } else { 'C:\Windows\WinSxS' }
Write-Host ('Workload dir: ' + $workloadDir)

# Pick large files for read-bench
$bigFiles = Get-ChildItem -Path $workloadDir -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Length -gt 50MB } |
    Sort-Object Length -Descending |
    Select-Object -First 20

if ($bigFiles.Count -eq 0) {
    Write-Warning 'No large files found for workload. Falling back to small files.'
    $bigFiles = Get-ChildItem -Path $workloadDir -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending |
        Select-Object -First 50
}

# ---- Start xperf for storage DPC ----
$wptRoot = 'C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit'
$xperfExe = Join-Path $wptRoot 'xperf.exe'
$xperfEtl = Join-Path $outDir 'storage_xperf.etl'

if (Test-Path $xperfExe) {
    Write-Host 'Starting xperf trace...'
    & $xperfExe -on PROC_THREAD+LOADER+DPC+INTERRUPT+CSWITCH+FILE_IO+DISK_IO -BufferSize 1024 -MinBuffers 64 -MaxBuffers 128 -f $xperfEtl 2>&1 | Out-File -FilePath (Join-Path $outDir 'xperf_start.log') -Encoding utf8
}

# ---- Start perf counter sampling in background job ----
$counters = @(
    '\PhysicalDisk(_Total)\Avg. Disk sec/Read',
    '\PhysicalDisk(_Total)\Avg. Disk sec/Write',
    '\PhysicalDisk(_Total)\Disk Reads/sec',
    '\PhysicalDisk(_Total)\Disk Writes/sec',
    '\PhysicalDisk(_Total)\Current Disk Queue Length',
    '\Processor(_Total)\% DPC Time'
)

# Launch workload as background job: random reads
$workloadJob = Start-Job -ScriptBlock {
    param($files, $duration)
    $deadline = (Get-Date).AddSeconds($duration)
    $rand = New-Object System.Random
    $buf = New-Object byte[] (1MB)
    while ((Get-Date) -lt $deadline) {
        $f = $files[$rand.Next(0, $files.Count)]
        try {
            $fs = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
            $maxOffset = [Math]::Max(0, $f.Length - 1MB)
            $offset = [int64]($rand.NextDouble() * $maxOffset)
            $fs.Seek($offset, 'Begin') | Out-Null
            [void]$fs.Read($buf, 0, 1MB)
            $fs.Close()
        } catch {
            # Ignore file lock errors
        }
    }
} -ArgumentList @(,$bigFiles), $DurationSec

Write-Host ('Workload running for ' + $DurationSec + 's...')
$samples = Get-Counter -Counter $counters -SampleInterval 1 -MaxSamples $DurationSec -ErrorAction SilentlyContinue

# Wait for workload to finish
Wait-Job $workloadJob | Out-Null
Remove-Job $workloadJob

# Stop xperf
if (Test-Path $xperfExe) {
    & $xperfExe -stop -d $xperfEtl 2>&1 | Out-File -FilePath (Join-Path $outDir 'xperf_stop.log') -Encoding utf8
    & $xperfExe -i $xperfEtl -o (Join-Path $outDir 'storage_dpc_summary.csv') -a dpcisr 2>&1 | Out-File -FilePath (Join-Path $outDir 'xperf_dpc_action.log') -Encoding utf8
}

# ---- Aggregate counter samples ----
$rows = New-Object System.Collections.Generic.List[object]
foreach ($s in $samples) {
    foreach ($cs in $s.CounterSamples) {
        $rows.Add([pscustomobject]@{
            Timestamp = $s.Timestamp
            Counter   = $cs.Path
            Value     = $cs.CookedValue
        })
    }
}
$rows | Export-Csv -Path (Join-Path $outDir 'storage_counters.csv') -NoTypeInformation -Encoding utf8

# Summary stats
$summary = [ordered]@{}
foreach ($g in ($rows | Group-Object Counter)) {
    $vals = @($g.Group | ForEach-Object { [double]$_.Value })
    if ($vals.Count -gt 0) {
        $avg = ($vals | Measure-Object -Average).Average
        $max = ($vals | Measure-Object -Maximum).Maximum
        $min = ($vals | Measure-Object -Minimum).Minimum
        # Manual stddev (PS 5.1 lacks -StandardDeviation)
        $sumSq = 0
        foreach ($v in $vals) { $sumSq += [Math]::Pow($v - $avg, 2) }
        $stddev = [Math]::Sqrt($sumSq / $vals.Count)
        $summary[$g.Name] = [pscustomobject]@{
            Avg    = [math]::Round($avg, 6)
            Min    = [math]::Round($min, 6)
            Max    = [math]::Round($max, 6)
            StdDev = [math]::Round($stddev, 6)
            N      = $vals.Count
        }
    }
}

$result = [ordered]@{
    driverLabel = $DriverLabel
    timestamp   = $timestamp
    durationSec = $DurationSec
    drivers     = $driverInfo
    workloadDir = $workloadDir
    fileCount   = $bigFiles.Count
    summary     = $summary
}
$result | ConvertTo-Json -Depth 6 | Out-File -FilePath (Join-Path $outDir 'bench_summary.json') -Encoding utf8

# Console output
Write-Host ''
Write-Host '=== Bench Complete ===' -ForegroundColor Green
Write-Host ('Output: ' + $outDir)
Write-Host ''
Write-Host '--- Summary ---'
foreach ($k in $summary.Keys) {
    $s = $summary[$k]
    Write-Host ('{0,-60} avg={1} min={2} max={3} stddev={4}' -f $k, $s.Avg, $s.Min, $s.Max, $s.StdDev)
}
Write-Host ''
Write-Host 'Compare with another driver: re-run with -DriverLabel <other-label> after switching.'
