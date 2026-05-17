<#
.SYNOPSIS
    Unified gaming session capture — ALL monitoring in one command.
.DESCRIPTION
    Starts all data sources simultaneously with synchronized timestamps:
      - Per-CPU perf counters (DPC%, ISR%, DPCs/sec, Interrupts/sec, Pages/sec, Disk, CPU%, Memory)
      - nvidia-smi dmon (GPU clocks, power, temp, SM%, VRAM, PCIe bandwidth)
      - Ping monitor (gateway + 8.8.8.8 + 1.1.1.1 every ~1s)
      - Process samples (top 10 CPU consumers every 5s)
      - xperf ETL trace (DPC/ISR/CSWITCH/FILE_IO)
      - Minifilter snapshots (fltmc)

    Output: captures/sessions/{Tag}_{timestamp}/
    Pair with CapFrameX (start manually) for frame-level data.
    Analyze with: .\scripts\analyze_session.ps1 -SessionDir <path> [-CapFrameXFile <path>]

.PARAMETER Tag
    Session label (e.g., "fortnite-reload", "warmup-dx12").
.PARAMETER DurationSec
    Capture window in seconds. Default 600 (10 min).
.PARAMETER SkipXperf
    Skip xperf ETL trace.
.PARAMETER SkipGpu
    Skip nvidia-smi GPU monitoring.
.PARAMETER SkipPing
    Skip network ping monitoring.
.PARAMETER SkipProcesses
    Skip process CPU sampling.
.EXAMPLE
    .\capture_session.ps1 -Tag fortnite-reload -DurationSec 600
    .\capture_session.ps1 -Tag quick-test -DurationSec 30 -SkipXperf
#>
#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$Tag,

    [ValidateRange(10, 7200)]
    [int]$DurationSec = 600,

    [switch]$SkipXperf,
    [switch]$SkipGpu,
    [switch]$SkipPing,
    [switch]$SkipProcesses
)

$ErrorActionPreference = 'Stop'

# ---- Setup ----
$repoRoot = Split-Path -Parent $PSScriptRoot
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$sessDir = Join-Path $repoRoot ('captures\sessions\' + $Tag + '_' + $timestamp)
New-Item -ItemType Directory -Force -Path $sessDir | Out-Null

$epochMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$epochIso = Get-Date -Format 'o'

$wptRoot = 'C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit'
$xperfExe = Join-Path $wptRoot 'xperf.exe'
$cpuCount = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors

Write-Host '========================================' -ForegroundColor Cyan
Write-Host '  Unified Session Capture' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ('  Tag:      ' + $Tag)
Write-Host ('  Duration: ' + $DurationSec + 's (' + [math]::Round($DurationSec/60,1) + ' min)')
Write-Host ('  Output:   ' + $sessDir)
Write-Host ('  CPUs:     ' + $cpuCount)
Write-Host ''

# ---- Run metadata ----
$meta = [ordered]@{
    tag         = $Tag
    epochMs     = $epochMs
    epochIso    = $epochIso
    durationSec = $DurationSec
    osBuild     = (Get-CimInstance Win32_OperatingSystem).BuildNumber
    cpu         = (Get-CimInstance Win32_Processor).Name
    gpu         = (Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic Display' } | Select-Object -First 1).Name
    machineName = $env:COMPUTERNAME
    cpuCount    = $cpuCount
    skipXperf   = [bool]$SkipXperf
    skipGpu     = [bool]$SkipGpu
    skipPing    = [bool]$SkipPing
    skipProcs   = [bool]$SkipProcesses
}
$meta | ConvertTo-Json -Depth 3 | Out-File -FilePath (Join-Path $sessDir 'run_meta.json') -Encoding utf8

# ---- Pre-flight: minifilter snapshot ----
Write-Host '[1/6] Minifilter snapshot...' -ForegroundColor Gray
fltmc instances 2>&1 | Out-File -FilePath (Join-Path $sessDir 'fltmc_instances.txt') -Encoding utf8
fltmc filters 2>&1 | Out-File -FilePath (Join-Path $sessDir 'fltmc_filters.txt') -Encoding utf8

# ---- Detect gateway for ping ----
$gwIp = '192.168.4.1'
$gwRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($gwRoute) { $gwIp = $gwRoute.NextHop }

# ---- Start xperf ----
if (-not $SkipXperf) {
    Write-Host '[2/6] Starting xperf trace...' -ForegroundColor Gray
    $xperfEtl = Join-Path $sessDir 'xperf_trace.etl'
    if (Test-Path $xperfExe) {
        & $xperfExe -on PROC_THREAD+LOADER+DPC+INTERRUPT+CSWITCH+FILE_IO -BufferSize 1024 -MinBuffers 64 -MaxBuffers 256 -f $xperfEtl 2>&1 | Out-File -FilePath (Join-Path $sessDir 'xperf_start.log') -Encoding utf8
    } else {
        Write-Host '  xperf.exe not found — skipping' -ForegroundColor Yellow
    }
} else {
    Write-Host '[2/6] xperf skipped' -ForegroundColor DarkGray
}

# ---- Background job: perf counters ----
Write-Host '[3/6] Starting perf counter sampling...' -ForegroundColor Gray
$jobCounters = Start-Job -ScriptBlock {
    param($outPath, $dur, $cpuN)
    $csvPath = Join-Path $outPath 'percpu_counters.csv'
    $counters = @()
    for ($i = 0; $i -lt $cpuN; $i++) {
        $counters += '\Processor(' + $i + ')\% DPC Time'
        $counters += '\Processor(' + $i + ')\% Interrupt Time'
        $counters += '\Processor(' + $i + ')\DPCs Queued/sec'
        $counters += '\Processor(' + $i + ')\Interrupts/sec'
    }
    $counters += '\Processor(_Total)\% Processor Time'
    $counters += '\Memory\Available MBytes'
    $counters += '\Memory\Pages/sec'
    $counters += '\PhysicalDisk(_Total)\Avg. Disk sec/Read'
    $counters += '\PhysicalDisk(_Total)\Current Disk Queue Length'

    $rows = New-Object System.Collections.ArrayList
    try {
        $samples = Get-Counter -Counter $counters -SampleInterval 1 -MaxSamples $dur -ErrorAction Stop
        foreach ($s in $samples) {
            $em = [DateTimeOffset]::new($s.Timestamp).ToUnixTimeMilliseconds()
            $ts = $s.Timestamp.ToString('o')
            $cpuPct = ''; $memMB = ''; $pagesSec = ''; $diskLat = ''; $diskQ = ''
            $perCpu = @{}
            foreach ($cs in $s.CounterSamples) {
                $p = $cs.Path.ToLower()
                $v = $cs.CookedValue
                if ($p.Contains('processor(_total)') -and $p.Contains('% processor time')) { $cpuPct = [math]::Round($v, 2) }
                elseif ($p.Contains('available mbytes')) { $memMB = [math]::Round($v, 0) }
                elseif ($p.Contains('pages/sec')) { $pagesSec = [math]::Round($v, 0) }
                elseif ($p.Contains('avg. disk sec/read')) { $diskLat = [math]::Round($v * 1000, 3) }
                elseif ($p.Contains('current disk queue')) { $diskQ = [math]::Round($v, 0) }
                else {
                    $m = [regex]::Match($p, 'processor\((\d+)\)')
                    if ($m.Success) {
                        $cpuIdx = $m.Groups[1].Value
                        if (-not $perCpu.ContainsKey($cpuIdx)) {
                            $perCpu[$cpuIdx] = @{ dpc = 0; isr = 0; dpcsQ = 0; intrs = 0 }
                        }
                        if ($p.Contains('% dpc time')) { $perCpu[$cpuIdx].dpc = [math]::Round($v, 3) }
                        elseif ($p.Contains('% interrupt time')) { $perCpu[$cpuIdx].isr = [math]::Round($v, 3) }
                        elseif ($p.Contains('dpcs queued')) { $perCpu[$cpuIdx].dpcsQ = [math]::Round($v, 1) }
                        elseif ($p.Contains('interrupts/sec')) { $perCpu[$cpuIdx].intrs = [math]::Round($v, 1) }
                    }
                }
            }
            foreach ($cpuIdx in ($perCpu.Keys | Sort-Object { [int]$_ })) {
                $d = $perCpu[$cpuIdx]
                [void]$rows.Add([pscustomobject]@{
                    EpochMs=$em; Timestamp=$ts; Cpu=[int]$cpuIdx
                    DpcPct=$d.dpc; IsrPct=$d.isr; DpcsQueuedSec=$d.dpcsQ; InterruptsSec=$d.intrs
                    TotalCpuPct=''; AvailMemMB=''; PagesSec=''; DiskReadLatMs=''; DiskQueueLen=''
                })
            }
            [void]$rows.Add([pscustomobject]@{
                EpochMs=$em; Timestamp=$ts; Cpu=-1
                DpcPct=''; IsrPct=''; DpcsQueuedSec=''; InterruptsSec=''
                TotalCpuPct=$cpuPct; AvailMemMB=$memMB; PagesSec=$pagesSec
                DiskReadLatMs=$diskLat; DiskQueueLen=$diskQ
            })
        }
    } catch {
        # Write whatever we have
    }
    $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8
} -ArgumentList @($sessDir, $DurationSec, $cpuCount)

# ---- Background job: GPU dmon ----
if (-not $SkipGpu) {
    Write-Host '[4/6] Starting GPU monitoring...' -ForegroundColor Gray
    $jobGpu = Start-Job -ScriptBlock {
        param($outPath, $dur)
        $csvPath = Join-Path $outPath 'gpu_dmon.csv'
        $header = 'EpochMs,Timestamp,PwrW,GpuTempC,SmPct,MemBwPct,MemClkMHz,GfxClkMHz,FbUsedMB,PcieRxMBs,PcieTxMBs'
        $header | Out-File -FilePath $csvPath -Encoding utf8
        $smiPath = Get-Command 'nvidia-smi' -ErrorAction SilentlyContinue
        if (-not $smiPath) { return }
        $proc = Start-Process -FilePath $smiPath.Source -ArgumentList ('dmon -s pucvmet -d 1 -c ' + $dur) -NoNewWindow -RedirectStandardOutput (Join-Path $outPath 'gpu_dmon_raw.txt') -PassThru
        $proc.WaitForExit(($dur + 30) * 1000)
        $lines = Get-Content (Join-Path $outPath 'gpu_dmon_raw.txt') | Where-Object { $_ -notmatch '^#' -and $_.Trim() -ne '' }
        $rows = @()
        $startMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $idx = 0
        foreach ($line in $lines) {
            $p = $line -split '\s+' | Where-Object { $_ -ne '' }
            if ($p.Count -ge 16) {
                $em = $startMs - (($lines.Count - 1 - $idx) * 1000)
                $row = $em.ToString() + ',' + (Get-Date).ToString('o') + ',' + $p[1] + ',' + $p[2] + ',' + $p[4] + ',' + $p[5] + ',' + $p[10] + ',' + $p[11] + ',' + $p[14] + ',' + $p[20] + ',' + $p[21]
                $rows += $row
            }
            $idx++
        }
        $rows | Out-File -FilePath $csvPath -Append -Encoding utf8
    } -ArgumentList @($sessDir, $DurationSec)
} else {
    Write-Host '[4/6] GPU monitoring skipped' -ForegroundColor DarkGray
    $jobGpu = $null
}

# ---- Background job: ping monitor ----
if (-not $SkipPing) {
    Write-Host '[5/6] Starting ping monitor...' -ForegroundColor Gray
    $jobPing = Start-Job -ScriptBlock {
        param($outPath, $dur, $gateway)
        $csvPath = Join-Path $outPath 'ping_monitor.csv'
        $targets = @($gateway, '8.8.8.8', '1.1.1.1')
        $pinger = New-Object System.Net.NetworkInformation.Ping
        $rows = New-Object System.Collections.ArrayList
        $endTime = (Get-Date).AddSeconds($dur)
        while ((Get-Date) -lt $endTime) {
            $em = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $ts = Get-Date -Format 'o'
            foreach ($t in $targets) {
                $rtt = -1
                $ok = $false
                try {
                    $reply = $pinger.Send($t, 1000)
                    if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                        $rtt = $reply.RoundtripTime
                        $ok = $true
                    }
                } catch {}
                [void]$rows.Add([pscustomobject]@{
                    EpochMs=$em; Timestamp=$ts; Target=$t; RttMs=$rtt; Reachable=$ok
                })
            }
            Start-Sleep -Milliseconds 800
        }
        $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8
    } -ArgumentList @($sessDir, $DurationSec, $gwIp)
} else {
    Write-Host '[5/6] Ping monitor skipped' -ForegroundColor DarkGray
    $jobPing = $null
}

# ---- Background job: process samples ----
if (-not $SkipProcesses) {
    Write-Host '[6/6] Starting process sampler...' -ForegroundColor Gray
    $jobProcs = Start-Job -ScriptBlock {
        param($outPath, $dur)
        $csvPath = Join-Path $outPath 'process_samples.csv'
        $rows = New-Object System.Collections.ArrayList
        $endTime = (Get-Date).AddSeconds($dur)
        while ((Get-Date) -lt $endTime) {
            $em = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $ts = Get-Date -Format 'o'
            $procs = Get-Process -ErrorAction SilentlyContinue |
                Where-Object { $_.CPU -gt 0 } |
                Sort-Object CPU -Descending |
                Select-Object -First 10
            $rank = 1
            foreach ($pr in $procs) {
                $cpuSec = 0
                try { $cpuSec = [math]::Round($pr.TotalProcessorTime.TotalSeconds, 2) } catch {}
                $wsMB = [math]::Round($pr.WorkingSet64 / 1MB, 1)
                [void]$rows.Add([pscustomobject]@{
                    EpochMs=$em; Timestamp=$ts; Rank=$rank; Name=$pr.Name
                    Pid=$pr.Id; CpuSec=$cpuSec; WorkingSetMB=$wsMB; Threads=$pr.Threads.Count
                })
                $rank++
            }
            Start-Sleep -Seconds 5
        }
        $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8
    } -ArgumentList @($sessDir, $DurationSec)
} else {
    Write-Host '[6/6] Process sampler skipped' -ForegroundColor DarkGray
    $jobProcs = $null
}

# ---- Countdown ----
Write-Host ''
Write-Host ('Capturing for ' + $DurationSec + 's... PLAY NOW.') -ForegroundColor Yellow
Write-Host '(Start CapFrameX recording for frame-level data)' -ForegroundColor Yellow
Write-Host ''

$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt $DurationSec) {
    $remaining = $DurationSec - [int]$sw.Elapsed.TotalSeconds
    $min = [math]::Floor($remaining / 60)
    $sec = $remaining % 60
    $bar = '[' + ('=' * [math]::Min(40, [int](40 * $sw.Elapsed.TotalSeconds / $DurationSec))) + (' ' * [math]::Max(0, 40 - [int](40 * $sw.Elapsed.TotalSeconds / $DurationSec))) + ']'
    Write-Host ("`r  " + $bar + ' ' + $min + 'm ' + $sec + 's remaining   ') -NoNewline
    Start-Sleep -Seconds 5
}
Write-Host ''
Write-Host ''

# ---- Stop xperf ----
if (-not $SkipXperf -and (Test-Path $xperfExe)) {
    Write-Host 'Stopping xperf...' -ForegroundColor Gray
    $xperfEtl = Join-Path $sessDir 'xperf_trace.etl'
    & $xperfExe -stop -d $xperfEtl 2>&1 | Out-File -FilePath (Join-Path $sessDir 'xperf_stop.log') -Encoding utf8
    Write-Host 'Generating xperf DPC/ISR summary...' -ForegroundColor Gray
    & $xperfExe -i $xperfEtl -o (Join-Path $sessDir 'xperf_dpc_summary.csv') -a dpcisr 2>&1 | Out-File -FilePath (Join-Path $sessDir 'xperf_dpc_action.log') -Encoding utf8
}

# ---- Collect jobs ----
Write-Host 'Collecting background jobs...' -ForegroundColor Gray
$allJobs = @($jobCounters)
if ($jobGpu) { $allJobs += $jobGpu }
if ($jobPing) { $allJobs += $jobPing }
if ($jobProcs) { $allJobs += $jobProcs }

foreach ($j in $allJobs) {
    $j | Wait-Job -Timeout 60 | Out-Null
    $jobErr = Receive-Job -Job $j -ErrorAction SilentlyContinue 2>&1
    if ($j.State -eq 'Failed') {
        Write-Host ('  Job failed: ' + $j.Name) -ForegroundColor Red
    }
    Remove-Job -Job $j -Force -ErrorAction SilentlyContinue
}

# ---- Summary ----
Write-Host ''
Write-Host '========================================' -ForegroundColor Green
Write-Host '  Capture Complete' -ForegroundColor Green
Write-Host '========================================' -ForegroundColor Green
Write-Host ('  Output: ' + $sessDir)
Write-Host ''
Write-Host '  Files:' -ForegroundColor Gray
$files = Get-ChildItem -Path $sessDir -File
$totalSize = 0
foreach ($f in $files) {
    $sizeMB = [math]::Round($f.Length / 1MB, 2)
    $sizeStr = $sizeMB.ToString() + ' MB'
    if ($f.Length -lt 1MB) {
        $sizeStr = [math]::Round($f.Length / 1KB, 1).ToString() + ' KB'
    }
    Write-Host ('    ' + $f.Name.PadRight(35) + $sizeStr)
    $totalSize += $f.Length
}
Write-Host ('    ' + ('-' * 45))
Write-Host ('    Total: ' + [math]::Round($totalSize / 1MB, 1) + ' MB')
Write-Host ''
Write-Host 'Next:' -ForegroundColor Cyan
Write-Host ('  .\scripts\analyze_session.ps1 -SessionDir "' + $sessDir + '"')
Write-Host '  Add -CapFrameXFile <path> for frame-level correlation'
Write-Host ''
