#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory=$true)]
    [string]$Label,

    [Parameter(Mandatory=$true)]
    [string]$Description,

    [int]$DurationSec = 120,

    [switch]$SkipWPR,

    [switch]$SkipDashboardUpdate,

    [string]$WPRProfile = "GeneralProfile",

    [ValidateSet("Verbose","Light")]
    [string]$WPRDetail = "Verbose"
)

# =============================================================================
# pipeline.ps1 — End-to-end experiment capture and analysis
#
# Orchestrates:
#   1. Pre-flight checks (admin, idle, previous state)
#   2. WPR ETL trace (DPC/ISR/interrupt/context switch profiling)
#   3. Perf counter capture (per-CPU interrupt distribution)
#   4. Registry state snapshot
#   5. ETL → CSV extraction (DPC/ISR events via tracerpt)
#   6. Analysis report generation
#   7. Dashboard data update
#
# Usage:
#   .\pipeline.ps1 -Label "EXP08_HPET" -Description "Disabled HPET timer"
#   .\pipeline.ps1 -Label "EXP08_HPET" -Description "..." -DurationSec 60 -SkipWPR
#   .\pipeline.ps1 -Label "BASELINE_LOAD" -Description "Under Fortnite load" -WPRProfile CPU
#
# Output:
#   captures/experiments/YYYYMMDD_HHMMSS_LABEL/
#     ├── experiment.json          # Perf counters + registry + per-CPU data
#     ├── trace.etl                # WPR ETL trace (if captured)
#     ├── dpc_isr_summary.csv      # DPC/ISR events extracted from ETL
#     └── analysis.txt             # Human-readable analysis report
# =============================================================================

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot
$projectRoot = (Resolve-Path "$scriptRoot\..").Path

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outDir = Join-Path $projectRoot "captures\experiments\${timestamp}_${Label}"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

# ─── Logging helper ───
$logLines = @()
function Log($msg, $level = "INFO") {
    $ts = Get-Date -Format 'HH:mm:ss'
    $line = "[$ts] [$level] $msg"
    $script:logLines += $line
    switch ($level) {
        "PASS"  { Write-Host $line -ForegroundColor Green }
        "FAIL"  { Write-Host $line -ForegroundColor Red }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
}

# ═══════════════════════════════════════════════════════════════
# PHASE 1: Pre-flight
# ═══════════════════════════════════════════════════════════════
Log "=== Pipeline Start: $Label ==="
Log "Description: $Description"
Log "Duration: ${DurationSec}s | WPR: $(-not $SkipWPR) ($WPRProfile.$WPRDetail)"
Log "Output: $outDir"
Log ""

# Check for running WPR session
$wprStatus = wpr -status 2>&1
if ($wprStatus -notmatch 'WPR is not recording') {
    Log "WPR is already recording — cancelling previous session" "WARN"
    wpr -cancel 2>&1 | Out-Null
    Start-Sleep 2
}

# CPU idle check
Log "Checking system idle state..."
$cpuCheck = (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 3).CounterSamples |
    Measure-Object CookedValue -Average
$cpuAvg = [math]::Round($cpuCheck.Average, 1)
if ($cpuAvg -gt 15) {
    Log "CPU at ${cpuAvg}% — system may not be idle enough for clean capture" "WARN"
    Log "Consider closing background apps. Continuing in 5s..."
    Start-Sleep 5
} else {
    Log "CPU at ${cpuAvg}% — idle check passed" "PASS"
}

# ═══════════════════════════════════════════════════════════════
# PHASE 2: Start WPR trace
# ═══════════════════════════════════════════════════════════════
$etlFile = Join-Path $outDir "trace.etl"
$wprStarted = $false

if (-not $SkipWPR) {
    Log ""
    Log "=== Phase 2: Starting WPR trace ==="
    Log "Profile: $WPRProfile.$WPRDetail | File mode"

    try {
        $wprArgs = @("-start", "$WPRProfile.$WPRDetail", "-filemode")

        # Add CPU profile for detailed scheduling analysis
        if ($WPRProfile -ne "CPU") {
            $wprArgs += @("-start", "CPU.$WPRDetail")
        }

        $wprResult = & wpr @wprArgs 2>&1
        if ($LASTEXITCODE -eq 0) {
            Log "WPR recording started" "PASS"
            $wprStarted = $true
        } else {
            Log "WPR start failed: $wprResult" "WARN"
            Log "Continuing without WPR trace"
        }
    } catch {
        Log "WPR exception: $($_.Exception.Message)" "WARN"
    }
} else {
    Log ""
    Log "=== Phase 2: WPR skipped (use -SkipWPR:$false to enable) ==="
}

# ═══════════════════════════════════════════════════════════════
# PHASE 3: Performance counter capture
# ═══════════════════════════════════════════════════════════════
Log ""
Log "=== Phase 3: Perf counter capture (${DurationSec}s) ==="

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

# Aggregate all counter data
$counterData = @{}
foreach ($sample in $samples) {
    foreach ($cs in $sample.CounterSamples) {
        $key = "$($cs.Path)|$($cs.InstanceName)"
        if (-not $counterData.ContainsKey($key)) {
            $counterData[$key] = @{ path=$cs.Path; instance=$cs.InstanceName; values=@() }
        }
        $counterData[$key].values += $cs.CookedValue
    }
}

function Get-Stats($vals) {
    $m = $vals | Measure-Object -Average -Minimum -Maximum -StandardDeviation
    return @{
        avg   = [math]::Round($m.Average, 4)
        min   = [math]::Round($m.Minimum, 4)
        max   = [math]::Round($m.Maximum, 4)
        stdev = [math]::Round($m.StandardDeviation, 4)
    }
}

# Build per-CPU data
$cpuInterrupt  = @{}
$cpuDpc        = @{}
$cpuIntrPerSec = @{}
foreach ($key in $counterData.Keys) {
    $e = $counterData[$key]
    if ($e.path -like '*interrupt time*') { $cpuInterrupt[$e.instance]  = Get-Stats $e.values }
    if ($e.path -like '*dpc time*')       { $cpuDpc[$e.instance]        = Get-Stats $e.values }
    if ($e.path -like '*interrupts/sec*') { $cpuIntrPerSec[$e.instance] = Get-Stats $e.values }
}

$cpuData = @()
$cpuNums = $cpuInterrupt.Keys | Where-Object { $_ -ne '_total' } | Sort-Object { [int]$_ }
foreach ($cpu in $cpuNums) {
    $cpuData += @{
        cpu          = [int]$cpu
        interruptPct = $cpuInterrupt[$cpu].avg
        dpcPct       = if ($cpuDpc.ContainsKey($cpu)) { $cpuDpc[$cpu].avg } else { 0 }
        intrPerSec   = if ($cpuIntrPerSec.ContainsKey($cpu)) { $cpuIntrPerSec[$cpu].avg } else { 0 }
        interruptStdev = $cpuInterrupt[$cpu].stdev
        dpcStdev       = if ($cpuDpc.ContainsKey($cpu)) { $cpuDpc[$cpu].stdev } else { 0 }
    }
}

# Build overall perf summary
$perf = @{}
foreach ($key in $counterData.Keys) {
    $e     = $counterData[$key]
    $name  = ($e.path.TrimStart('\').Split('\') | Select-Object -Last 1)
    $inst  = $e.instance
    $stats = Get-Stats $e.values
    $mk    = if ($inst) { "${name}[$inst]" } else { $name }
    $perf[$mk] = $stats
}

Log "Perf capture done: $($samples.Count) samples collected" "PASS"

# ═══════════════════════════════════════════════════════════════
# PHASE 4: Stop WPR and extract ETL
# ═══════════════════════════════════════════════════════════════
$dpcIsrData = $null

if ($wprStarted) {
    Log ""
    Log "=== Phase 4: Stopping WPR trace ==="

    try {
        $stopResult = wpr -stop $etlFile "$Description" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $etlSize = [math]::Round((Get-Item $etlFile).Length / 1MB, 1)
            Log "WPR trace saved: trace.etl (${etlSize} MB)" "PASS"
        } else {
            Log "WPR stop returned: $stopResult" "WARN"
        }
    } catch {
        Log "WPR stop exception: $($_.Exception.Message)" "WARN"
    }

    # Try to extract DPC/ISR events via tracerpt
    if (Test-Path $etlFile) {
        Log "Extracting DPC/ISR events via tracerpt..."
        $csvOut = Join-Path $outDir "tracerpt_output"
        try {
            $trResult = tracerpt $etlFile -o (Join-Path $outDir "events.csv") -of CSV -summary (Join-Path $outDir "summary.txt") -report (Join-Path $outDir "report.xml") -y 2>&1
            if (Test-Path (Join-Path $outDir "summary.txt")) {
                Log "tracerpt extraction complete" "PASS"
                # Parse summary for DPC/ISR counts
                $summaryContent = Get-Content (Join-Path $outDir "summary.txt") -Raw -ErrorAction SilentlyContinue
                if ($summaryContent) {
                    $dpcIsrData = @{ hasSummary = $true; summaryFile = "summary.txt" }
                }
            }
        } catch {
            Log "tracerpt extraction failed: $($_.Exception.Message)" "WARN"
        }
    }
} else {
    Log ""
    Log "=== Phase 4: Skipped (no WPR trace) ==="
}

# ═══════════════════════════════════════════════════════════════
# PHASE 5: Registry state capture
# ═══════════════════════════════════════════════════════════════
Log ""
Log "=== Phase 5: Registry snapshot ==="

$reg = @{}

# MMCSS
try {
    $mmcss = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -ErrorAction Stop
    $games = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' -ErrorAction Stop
    $reg['SystemResponsiveness']    = $mmcss.SystemResponsiveness
    $reg['NetworkThrottlingIndex']  = $mmcss.NetworkThrottlingIndex
    $reg['GamesSchedulingCategory'] = $games.'Scheduling Category'
    $reg['GamesPriority']           = $games.Priority
    $reg['GamesSFIOPriority']       = $games.'SFIO Priority'
} catch { $reg['MMCSS_Error'] = $_.Exception.Message }

# Defender
try {
    $mp = Get-MpPreference -ErrorAction Stop
    $reg['ScanAvgCPULoadFactor']  = $mp.ScanAvgCPULoadFactor
    $reg['EnableLowCpuPriority']  = [string]$mp.EnableLowCpuPriority
    $reg['ExclusionPathCount']    = if ($mp.ExclusionPath) { $mp.ExclusionPath.Count } else { 0 }
    $reg['ExclusionProcessCount'] = if ($mp.ExclusionProcess) { $mp.ExclusionProcess.Count } else { 0 }
} catch { $reg['Defender_Error'] = $_.Exception.Message }

# GPU MSI + PerfLevelSrc
$nvKeys = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -like 'VEN_10DE*' }
if ($nvKeys) {
    $nvKey = $nvKeys | Select-Object -First 1
    $msiPath = "$($nvKey.PSPath)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
    if (Test-Path $msiPath) {
        $msi = Get-ItemProperty $msiPath -ErrorAction SilentlyContinue
        $reg['GPU_MSISupported']       = $msi.MSISupported
        $reg['GPU_MessageNumberLimit'] = $msi.MessageNumberLimit
    }
    $reg['GPU_PerfLevelSrc'] = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\NVTweak' -ErrorAction SilentlyContinue).PerfLevelSrc
}
$reg['HAGS_HwSchMode'] = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction SilentlyContinue).HwSchMode

# Interrupt affinities (spot-check key devices)
$affinities = @{}
$deviceChecks = @(
    @{ Name='GPU';     Pattern='VEN_10DE' },
    @{ Name='NIC';     Pattern='VEN_8086&DEV_125C' },
    @{ Name='USB_15B6';Pattern='VEN_1022&DEV_15B6' },
    @{ Name='USB_15B7';Pattern='VEN_1022&DEV_15B7' },
    @{ Name='USB_43F7';Pattern='VEN_1022&DEV_43F7' },
    @{ Name='USB_15B8';Pattern='VEN_1022&DEV_15B8' }
)
foreach ($dc in $deviceChecks) {
    $dkeys = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Enum\PCI" -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like "*$($dc.Pattern)*" }
    if ($dkeys) {
        foreach ($dk in $dkeys) {
            $affPath = "$($dk.PSPath)\Device Parameters\Interrupt Management\Affinity Policy"
            if (Test-Path $affPath) {
                $v = Get-ItemProperty $affPath -ErrorAction SilentlyContinue
                if ($v.AssignmentSetOverride) {
                    $hex = '0x' + ($v.AssignmentSetOverride[0].ToString('X2'))
                    $affinities["$($dc.Name)"] = @{
                        DevicePolicy = $v.DevicePolicy
                        MaskByte0    = $hex
                        InstanceId   = $dk.PSChildName
                    }
                }
            }
        }
    }
}
$reg['InterruptAffinities'] = $affinities

Log "Registry snapshot captured" "PASS"

# ═══════════════════════════════════════════════════════════════
# PHASE 6: Analysis
# ═══════════════════════════════════════════════════════════════
Log ""
Log "=== Phase 6: Analysis ==="

$analysis = @()
$analysis += "=== Experiment Analysis: $Label ==="
$analysis += "Description: $Description"
$analysis += "Captured: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$analysis += "Duration: ${DurationSec}s | WPR: $(-not $SkipWPR)"
$analysis += ""

# CPU interrupt distribution analysis
$analysis += "--- Interrupt Distribution ---"
$cpu0Share = 0
$cpu23Share = 0
$cpu47Share = 0
$totalIntr = 0
foreach ($c in $cpuData) { $totalIntr += $c.interruptPct }
if ($totalIntr -gt 0) {
    $c0 = ($cpuData | Where-Object { $_.cpu -eq 0 }).interruptPct
    $cpu0Share = [math]::Round($c0 / $totalIntr * 100, 1)
    $c23 = ($cpuData | Where-Object { $_.cpu -in @(2,3) } | Measure-Object interruptPct -Sum).Sum
    $cpu23Share = [math]::Round($c23 / $totalIntr * 100, 1)
    $c47 = ($cpuData | Where-Object { $_.cpu -in @(4,5,6,7) } | Measure-Object interruptPct -Sum).Sum
    $cpu47Share = [math]::Round($c47 / $totalIntr * 100, 1)
}

$analysis += "CPU 0 (preferred core):       $cpu0Share% of total interrupt time"
$analysis += "CPUs 2-3 (input devices):     $cpu23Share% of total interrupt time"
$analysis += "CPUs 4-7 (GPU/NIC/USB):       $cpu47Share% of total interrupt time"
$analysis += "CPUs 8-15 (game threads):     $([math]::Round(100 - $cpu0Share - $cpu23Share - $cpu47Share, 1))% of total interrupt time"
$analysis += ""

# Target checks
$analysis += "--- Target Verification ---"
$targets = @(
    @{ Name="CPU 0 share <10%";      Value=$cpu0Share;     Target=10;   Op="lt" },
    @{ Name="Total DPC% <0.5%";      Value=$cpuDpc['_total'].avg; Target=0.5; Op="lt" },
    @{ Name="Total Interrupt% <1.0%"; Value=$cpuInterrupt['_total'].avg; Target=1.0; Op="lt" }
)

foreach ($t in $targets) {
    $pass = switch ($t.Op) {
        "lt" { $t.Value -lt $t.Target }
        "gt" { $t.Value -gt $t.Target }
    }
    $status = if ($pass) { "PASS" } else { "REVIEW" }
    $analysis += "[$status] $($t.Name): $($t.Value) (target: <$($t.Target))"
    Log "$($t.Name): $($t.Value)" $(if ($pass) { "PASS" } else { "WARN" })
}

$analysis += ""

# Jitter analysis (stdev of interrupt time per CPU)
$analysis += "--- Jitter Analysis (interrupt% standard deviation) ---"
$highJitter = $cpuData | Where-Object { $_.interruptStdev -gt 0.5 } | Sort-Object interruptStdev -Descending
if ($highJitter) {
    foreach ($hj in $highJitter) {
        $analysis += "[WARN] CPU $($hj.cpu): interrupt stdev = $($hj.interruptStdev)%"
    }
} else {
    $analysis += "[PASS] No CPUs with interrupt jitter >0.5% stdev"
}

$analysis += ""
$analysis += "--- Per-CPU Detail ---"
$analysis += "{0,-6} {1,10} {2,10} {3,12} {4,12}" -f "CPU", "Intr%", "DPC%", "Intr/sec", "IntrStdev"
foreach ($c in ($cpuData | Sort-Object cpu)) {
    $role = switch ($c.cpu) {
        0 { " <-preferred" }
        2 { " <-input" }
        3 { " <-input" }
        4 { " <-GPU/NIC" }
        5 { " <-GPU/NIC" }
        6 { " <-GPU/NIC" }
        7 { " <-GPU/NIC" }
        default { "" }
    }
    $analysis += ("{0,-6} {1,10:N4} {2,10:N4} {3,12:N1} {4,12:N4}{5}" -f
        "CPU$($c.cpu)", $c.interruptPct, $c.dpcPct, $c.intrPerSec, $c.interruptStdev, $role)
}

# WPR trace info
if ($wprStarted -and (Test-Path $etlFile)) {
    $analysis += ""
    $analysis += "--- WPR Trace ---"
    $analysis += "ETL file: trace.etl ($([math]::Round((Get-Item $etlFile).Length / 1MB, 1)) MB)"
    $analysis += "Profile: $WPRProfile.$WPRDetail + CPU.$WPRDetail"
    $analysis += "Open in Windows Performance Analyzer (WPA) for:"
    $analysis += "  - DPC/ISR duration breakdown by driver (Computation → DPC/ISR)"
    $analysis += "  - Context switch analysis (Computation → CPU Usage (Precise))"
    $analysis += "  - Interrupt-to-thread latency"
    $analysis += "  - Memory hard fault stacks"
}

$analysisFile = Join-Path $outDir "analysis.txt"
$analysis | Out-File $analysisFile -Encoding UTF8

# ═══════════════════════════════════════════════════════════════
# PHASE 7: Save JSON
# ═══════════════════════════════════════════════════════════════
Log ""
Log "=== Phase 7: Saving experiment JSON ==="

$result = [ordered]@{
    schemaVersion = 2
    label         = $Label
    description   = $Description
    capturedAt    = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    durationSec   = $DurationSec
    hostname      = $env:COMPUTERNAME
    wprProfile    = if (-not $SkipWPR) { "$WPRProfile.$WPRDetail" } else { $null }
    wprEtlFile    = if ($wprStarted -and (Test-Path $etlFile)) { "trace.etl" } else { $null }
    registry      = $reg
    performance   = $perf
    cpuData       = $cpuData
    cpuTotal      = @{
        interruptPct = $cpuInterrupt['_total'].avg
        dpcPct       = $cpuDpc['_total'].avg
        intrPerSec   = $cpuIntrPerSec['_total'].avg
    }
    interruptTopology = @{
        cpu0Share  = $cpu0Share
        cpu23Share = $cpu23Share
        cpu47Share = $cpu47Share
    }
    analysisFile  = "analysis.txt"
}

$jsonFile = Join-Path $outDir "experiment.json"
$result | ConvertTo-Json -Depth 8 | Out-File $jsonFile -Encoding UTF8
Log "Saved experiment.json" "PASS"

# ═══════════════════════════════════════════════════════════════
# PHASE 8: Update dashboard
# ═══════════════════════════════════════════════════════════════
if (-not $SkipDashboardUpdate) {
    Log ""
    Log "=== Phase 8: Updating dashboard ==="
    $genScript = Join-Path $scriptRoot "generate_dashboard_data.ps1"
    if (Test-Path $genScript) {
        try {
            & $genScript
            Log "Dashboard data regenerated" "PASS"
        } catch {
            Log "Dashboard update failed: $($_.Exception.Message)" "WARN"
        }
    } else {
        Log "generate_dashboard_data.ps1 not found" "WARN"
    }
}

# ═══════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════
Log ""
Log "═══════════════════════════════════════════════════"
Log "=== Pipeline Complete ==="
Log "═══════════════════════════════════════════════════"
Log ""
Log "Output directory: $outDir"
Log "  experiment.json    — Perf counters + registry + per-CPU data"
if ($wprStarted -and (Test-Path $etlFile)) {
    Log "  trace.etl          — Open in WPA for DPC/ISR driver analysis"
}
Log "  analysis.txt       — Human-readable analysis report"
Log ""
Log "Interrupt topology: CPU0=$cpu0Share% | Input(2-3)=$cpu23Share% | GPU/NIC(4-7)=$cpu47Share%"
Log ""
Log "Next steps:"
Log "  1. Open dashboard/index.html to see updated charts"
if ($wprStarted) {
    Log "  2. Open trace.etl in Windows Performance Analyzer for DPC/ISR drill-down"
}
Log "  3. Commit: git add -A && git commit -m 'exp: $Label'"

# Save log
$logLines | Out-File (Join-Path $outDir "pipeline.log") -Encoding UTF8
