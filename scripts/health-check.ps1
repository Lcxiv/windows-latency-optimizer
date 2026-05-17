#Requires -RunAsAdministrator
<#
.SYNOPSIS
    60-second system health check with scored HTML report.
.DESCRIPTION
    Runs a quick system audit covering: DPC/interrupt overhead, process bloat,
    SMI blackout detection, VRAM state, BIOS alignment, and Defender config.
    Produces a weighted score (0-100) and a self-contained HTML report.
.OUTPUTS
    Opens HTML report in browser. Returns score to caller.
#>

$ErrorActionPreference = 'Continue'
$projectRoot = Split-Path $PSScriptRoot -Parent

# Load helpers
. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\helpers\logging.ps1"
. "$PSScriptRoot\topology.ps1"
. "$PSScriptRoot\helpers\smi-detect.ps1"
$script:logLines = @()

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outDir = Join-Path $projectRoot ('captures\health_' + $timestamp)
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

Write-Host ''
Write-Host '=== Windows Latency Optimizer — Health Check ===' -ForegroundColor Cyan
Write-Host ''

# ============================================================================
# COLLECT DATA (targeting ~30 seconds total)
# ============================================================================

# --- System Info ---
Write-Host '[1/7] System info...' -ForegroundColor Yellow
$sysInfo = [ordered]@{ hostname = $env:COMPUTERNAME }
try {
    $topo = Get-CpuTopology
    $sysInfo['cpu'] = $topo.cpuModel
    $sysInfo['cores'] = $topo.totalCores.ToString() + 'C/' + $topo.totalLogical.ToString() + 'T'
} catch { $sysInfo['cpu'] = 'Unknown'; $sysInfo['cores'] = $env:NUMBER_OF_PROCESSORS + 'T' }
try {
    $gpu = Get-WmiObject Win32_VideoController -ErrorAction Stop | Where-Object { $_.Name -notmatch 'Basic Display' } | Select-Object -First 1
    if ($gpu) { $sysInfo['gpu'] = $gpu.Name }
} catch {}
try {
    $ramBytes = (Get-WmiObject Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
    $sysInfo['ram'] = [math]::Round($ramBytes / 1GB).ToString() + ' GB'
} catch {}

# --- Perf Counters (10 seconds) ---
Write-Host '[2/7] Perf counters (10s)...' -ForegroundColor Yellow
$counters = @(
    '\Processor(_Total)\% Processor Time',
    '\Processor(_Total)\% DPC Time',
    '\Processor(_Total)\% Interrupt Time',
    '\Processor(0)\% Interrupt Time',
    '\Processor(0)\% DPC Time',
    '\System\Context Switches/sec',
    '\Memory\Page Faults/sec',
    '\Memory\Available MBytes'
)
$samples = @()
try {
    $raw = Get-Counter -Counter $counters -SampleInterval 1 -MaxSamples 10 -ErrorAction Stop
    foreach ($s in $raw) {
        $vals = @{}
        foreach ($cv in $s.CounterSamples) {
            $key = $cv.Path -replace '^\\\\[^\\]+\\', '\'
            $vals[$key] = $cv.CookedValue
        }
        $samples += $vals
    }
} catch {
    Write-Host ('  Perf counter error: ' + $_.Exception.Message) -ForegroundColor Red
}

# Compute averages
$perfData = @{}
if ($samples.Count -gt 0) {
    $keys = $samples[0].Keys
    foreach ($k in $keys) {
        $values = @()
        foreach ($s in $samples) { if ($null -ne $s[$k]) { $values += $s[$k] } }
        if ($values.Count -gt 0) {
            $perfData[$k] = @{
                avg = [math]::Round(($values | Measure-Object -Average).Average, 4)
                max = [math]::Round(($values | Measure-Object -Maximum).Maximum, 4)
            }
        }
    }
}

# --- Process Bloat ---
Write-Host '[3/7] Process audit...' -ForegroundColor Yellow
$totalThreads = 0
Get-Process | ForEach-Object { $totalThreads += $_.Threads.Count }

$razerCount = 0; $razerMB = 0
Get-Process | Where-Object { $_.Name -match 'Razer' } | ForEach-Object { $razerCount++; $razerMB += [math]::Round($_.WorkingSet64 / 1MB) }

$epicCount = 0; $epicMB = 0
Get-Process | Where-Object { $_.Name -match 'Epic' } | ForEach-Object { $epicCount++; $epicMB += [math]::Round($_.WorkingSet64 / 1MB) }

$realtimeProcs = @(Get-Process | Where-Object { $_.PriorityClass -match 'RealTime' })

$bloatData = @{
    totalThreads  = $totalThreads
    razerCount    = $razerCount
    razerMB       = $razerMB
    epicCount     = $epicCount
    epicMB        = $epicMB
    realtimeProcs = $realtimeProcs.Count
    realtimeNames = ($realtimeProcs | ForEach-Object { $_.Name }) -join ', '
}

# --- VRAM State ---
Write-Host '[4/7] GPU/VRAM state...' -ForegroundColor Yellow
$vramData = @{ available = $false }
$nvSmi = 'C:\Windows\System32\nvidia-smi.exe'
if (Test-Path $nvSmi) {
    $gpuCsv = & $nvSmi --query-gpu=pstate,clocks.current.memory,clocks.max.memory,power.draw --format=csv,noheader 2>&1
    if ($gpuCsv -match '(P\d+),\s*(\d+)\s*MHz,\s*(\d+)\s*MHz,\s*([\d.]+)\s*W') {
        $vramData = @{
            available  = $true
            pstate     = $Matches[1]
            currentMHz = [int]$Matches[2]
            maxMHz     = [int]$Matches[3]
            powerW     = [double]$Matches[4]
            isLowest   = ([int]$Matches[2] -le 405)
        }
    }
}

# --- SMI Check (10 seconds) ---
Write-Host '[5/7] SMI blackout check (10s)...' -ForegroundColor Yellow
$smiData = $null
if ($script:ToolPaths.Xperf -and (Test-Path $script:ToolPaths.Xperf)) {
    $smiData = Invoke-SmiGapCapture -OutDir $outDir -DurationSec 10
}

# --- WHEA Errors ---
Write-Host '[6/7] WHEA error check...' -ForegroundColor Yellow
$wheaCount = 0
try {
    $wheaEvents = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=(Get-Date).AddHours(-24)} -MaxEvents 100 -ErrorAction SilentlyContinue
    if ($wheaEvents) { $wheaCount = $wheaEvents.Count }
} catch {}

# --- Defender Config ---
Write-Host '[7/7] Defender config...' -ForegroundColor Yellow
$defenderData = @{ available = $false }
try {
    $pref = Get-MpPreference -ErrorAction Stop
    $defenderData = @{
        available         = $true
        rtEnabled         = -not $pref.DisableRealtimeMonitoring
        exclusionPaths    = $pref.ExclusionPath.Count
        exclusionProcs    = $pref.ExclusionProcess.Count
        scanCpuFactor     = $pref.ScanAvgCPULoadFactor
        lowCpuPriority    = $pref.EnableLowCpuPriority
    }
} catch {}

Write-Host ''

# ============================================================================
# COMPUTE HEALTH SCORE
# ============================================================================

$findings = @()
$scoreComponents = @()

# --- 1. DPC/Interrupt Overhead (25 points) ---
$dpcScore = 25
$dpcPct = 0; $intrPct = 0; $cpu0Intr = 0; $cpu0Dpc = 0
if ($perfData.Count -gt 0) {
    $dpcPct   = $perfData['\Processor(_Total)\% DPC Time'].avg
    $intrPct  = $perfData['\Processor(_Total)\% Interrupt Time'].avg
    $cpu0Intr = $perfData['\Processor(0)\% Interrupt Time'].avg
    $cpu0Dpc  = $perfData['\Processor(0)\% DPC Time'].avg

    if ($dpcPct -gt 2)       { $dpcScore -= 15; $findings += @{ severity = 'CRITICAL'; text = 'Total DPC% at ' + [math]::Round($dpcPct, 2) + '% (should be <1%)'; fix = 'Run: winlatopt.ps1 capture -Mode Standard for driver attribution' } }
    elseif ($dpcPct -gt 1)   { $dpcScore -= 8;  $findings += @{ severity = 'WARNING';  text = 'Total DPC% elevated at ' + [math]::Round($dpcPct, 2) + '%' } }

    $cpu0Total = $cpu0Intr + $cpu0Dpc
    if ($cpu0Total -gt 25)   { $dpcScore -= 10; $findings += @{ severity = 'CRITICAL'; text = 'CPU 0 overhead at ' + [math]::Round($cpu0Total, 1) + '% (interrupt + DPC)'; fix = 'Set game affinity away from CPU 0' } }
    elseif ($cpu0Total -gt 15) { $dpcScore -= 5; $findings += @{ severity = 'WARNING'; text = 'CPU 0 overhead at ' + [math]::Round($cpu0Total, 1) + '%' } }
}
$dpcScore = [math]::Max(0, $dpcScore)
$scoreComponents += @{ name = 'DPC/Interrupt'; score = $dpcScore; max = 25 }

# --- 2. Process Bloat (20 points) ---
$bloatScore = 20
if ($bloatData.realtimeProcs -gt 0) { $bloatScore -= 15; $findings += @{ severity = 'CRITICAL'; text = $bloatData.realtimeProcs.ToString() + ' process(es) at RealTime priority: ' + $bloatData.realtimeNames; fix = 'Kill or reconfigure RealTime processes' } }
if ($bloatData.razerCount -gt 5)    { $bloatScore -= 5;  $findings += @{ severity = 'WARNING';  text = $bloatData.razerCount.ToString() + ' Razer processes using ' + $bloatData.razerMB + 'MB'; fix = 'Run: winlatopt.ps1 fix' } }
if ($bloatData.totalThreads -gt 3000) { $bloatScore -= 5; $findings += @{ severity = 'WARNING'; text = $bloatData.totalThreads.ToString() + ' total threads (target: <2000)' } }
if ($bloatData.epicCount -gt 0) {
    $gameRunning = Get-Process 'FortniteClient-Win64-Shipping','cs2','VALORANT-Win64-Shipping' -ErrorAction SilentlyContinue
    if ($gameRunning -and $bloatData.epicCount -gt 3) { $bloatScore -= 3; $findings += @{ severity = 'INFO'; text = 'Epic Launcher running (' + $bloatData.epicCount + ' procs, ' + $bloatData.epicMB + 'MB) while gaming'; fix = 'Run: winlatopt.ps1 fix' } }
}
$bloatScore = [math]::Max(0, $bloatScore)
$scoreComponents += @{ name = 'Process Bloat'; score = $bloatScore; max = 20 }

# --- 3. SMI Health (15 points) ---
$smiScore = 15
if ($smiData) {
    if ($smiData.verdict -eq 'FAIL')   { $smiScore = 0;  $findings += @{ severity = 'CRITICAL'; text = 'SMI blackouts detected! ' + $smiData.driversWithHighDpc + ' driver(s) with DPCs >1ms'; fix = 'Check for UEFI/firmware updates, reduce BIOS write operations' } }
    elseif ($smiData.verdict -eq 'REVIEW') { $smiScore = 8; $findings += @{ severity = 'WARNING'; text = $smiData.highLatencyDpcCount.ToString() + ' high-latency DPCs detected (possible SMI)' } }
    else { $findings += @{ severity = 'PASS'; text = 'No SMI blackouts detected' } }
} else {
    $smiScore = 10  # Partial credit if xperf unavailable
    $findings += @{ severity = 'INFO'; text = 'SMI check skipped (xperf not available)' }
}
$scoreComponents += @{ name = 'SMI Health'; score = $smiScore; max = 15 }

# --- 4. Memory Config (15 points) ---
$memScore = 15
if ($wheaCount -gt 0)   { $memScore -= 10; $findings += @{ severity = 'CRITICAL'; text = $wheaCount.ToString() + ' WHEA errors in last 24h (memory/FCLK instability)'; fix = 'Reduce Curve Optimizer offset or FCLK speed' } }
if ($perfData.Count -gt 0) {
    $availMB = $perfData['\Memory\Available MBytes'].avg
    if ($availMB -lt 4096) { $memScore -= 10; $findings += @{ severity = 'CRITICAL'; text = 'Only ' + [math]::Round($availMB) + 'MB available RAM' } }
    elseif ($availMB -lt 8192) { $memScore -= 5; $findings += @{ severity = 'WARNING'; text = [math]::Round($availMB) + 'MB available RAM (low for gaming)' } }

    $pgFaults = $perfData['\Memory\Page Faults/sec'].max
    if ($pgFaults -gt 500000) { $memScore -= 5; $findings += @{ severity = 'WARNING'; text = 'Page fault spike: ' + [math]::Round($pgFaults/1000) + 'K/sec (memory pressure)' } }
}
$memScore = [math]::Max(0, $memScore)
$scoreComponents += @{ name = 'Memory Config'; score = $memScore; max = 15 }

# --- 5. VRAM State (10 points) ---
$vramScore = 10
if ($vramData.available) {
    if ($vramData.isLowest) { $vramScore -= 8; $findings += @{ severity = 'WARNING'; text = 'VRAM at lowest P-state (' + $vramData.currentMHz + ' MHz) - wake-up stutter risk'; fix = 'Run: winlatopt.ps1 fix (locks VRAM floor)' } }
    else { $findings += @{ severity = 'PASS'; text = 'VRAM at ' + $vramData.currentMHz + ' MHz (' + $vramData.pstate + ')' } }
} else {
    $vramScore = 7
    $findings += @{ severity = 'INFO'; text = 'nvidia-smi not available for VRAM check' }
}
$scoreComponents += @{ name = 'VRAM State'; score = $vramScore; max = 10 }

# --- 6. BIOS Alignment (10 points) ---
$biosScore = 10
# Check key registry indicators
$mpo = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' -Name 'OverlayTestMode' -ErrorAction SilentlyContinue
if (-not $mpo -or $mpo.OverlayTestMode -ne 5) { $biosScore -= 3; $findings += @{ severity = 'WARNING'; text = 'MPO (Multi-Plane Overlay) is enabled'; fix = 'Set HKLM\SOFTWARE\Microsoft\Windows\Dwm\OverlayTestMode = 5' } }

$hags = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -ErrorAction SilentlyContinue
if ($hags -and $hags.HwSchMode -ne 2) { $biosScore -= 2; $findings += @{ severity = 'INFO'; text = 'HAGS not enabled (HwSchMode != 2)' } }

$powerPlan = powercfg /getactivescheme 2>&1 | Out-String
if ($powerPlan -notmatch 'Ultimate|High Performance') { $biosScore -= 3; $findings += @{ severity = 'WARNING'; text = 'Not using High/Ultimate Performance power plan'; fix = 'powercfg /setactive 99999999-9999-9999-9999-999999999999' } }
$biosScore = [math]::Max(0, $biosScore)
$scoreComponents += @{ name = 'BIOS/OS Config'; score = $biosScore; max = 10 }

# --- 7. Defender Config (5 points) ---
$defScore = 5
if ($defenderData.available) {
    if ($defenderData.exclusionPaths -lt 3) { $defScore -= 3; $findings += @{ severity = 'WARNING'; text = 'Only ' + $defenderData.exclusionPaths + ' Defender exclusion paths (add game directories)'; fix = 'Add-MpPreference -ExclusionPath "C:\Program Files\Epic Games"' } }
    if ($defenderData.scanCpuFactor -gt 20) { $defScore -= 2; $findings += @{ severity = 'INFO'; text = 'Defender CPU load factor at ' + $defenderData.scanCpuFactor + '% (recommend 5%)' } }
}
$defScore = [math]::Max(0, $defScore)
$scoreComponents += @{ name = 'Defender'; score = $defScore; max = 5 }

# --- Total Score ---
$totalScore = 0
$maxScore = 0
foreach ($c in $scoreComponents) {
    $totalScore += $c.score
    $maxScore += $c.max
}

# ============================================================================
# GENERATE HTML REPORT
# ============================================================================

$scoreColor = '#ef4444'
if ($totalScore -ge 80) { $scoreColor = '#10b981' }
elseif ($totalScore -ge 60) { $scoreColor = '#f59e0b' }

$verdict = 'Needs Attention'
if ($totalScore -ge 90) { $verdict = 'Excellent' }
elseif ($totalScore -ge 80) { $verdict = 'Good' }
elseif ($totalScore -ge 60) { $verdict = 'Fair' }

# Build findings HTML
$findingsHtml = ''
$criticals = @($findings | Where-Object { $_.severity -eq 'CRITICAL' })
$warnings  = @($findings | Where-Object { $_.severity -eq 'WARNING' })
$passes    = @($findings | Where-Object { $_.severity -eq 'PASS' })
$infos     = @($findings | Where-Object { $_.severity -eq 'INFO' })

foreach ($f in $criticals) {
    $fixHtml = ''
    if ($f.fix) { $fixHtml = '<div class="fix">Fix: <code>' + $f.fix + '</code></div>' }
    $findingsHtml += '<div class="finding critical"><span class="dot red"></span>' + $f.text + $fixHtml + '</div>'
}
foreach ($f in $warnings) {
    $fixHtml = ''
    if ($f.fix) { $fixHtml = '<div class="fix">Fix: <code>' + $f.fix + '</code></div>' }
    $findingsHtml += '<div class="finding warning"><span class="dot amber"></span>' + $f.text + $fixHtml + '</div>'
}
foreach ($f in $passes) {
    $findingsHtml += '<div class="finding pass"><span class="dot green"></span>' + $f.text + '</div>'
}
foreach ($f in $infos) {
    $findingsHtml += '<div class="finding info"><span class="dot gray"></span>' + $f.text + '</div>'
}

# Build score breakdown HTML
$breakdownHtml = ''
foreach ($c in $scoreComponents) {
    $pct = [math]::Round($c.score / $c.max * 100)
    $barColor = '#ef4444'
    if ($pct -ge 80) { $barColor = '#10b981' }
    elseif ($pct -ge 50) { $barColor = '#f59e0b' }
    $breakdownHtml += '<div class="score-row"><span class="score-label">' + $c.name + '</span><div class="score-bar-bg"><div class="score-bar" style="width:' + $pct + '%;background:' + $barColor + '"></div></div><span class="score-val">' + $c.score + '/' + $c.max + '</span></div>'
}

# System info HTML
$sysInfoHtml = ''
if ($sysInfo.cpu) { $sysInfoHtml += '<span>' + $sysInfo.cpu + '</span>' }
if ($sysInfo.cores) { $sysInfoHtml += '<span>' + $sysInfo.cores + '</span>' }
if ($sysInfo.ram) { $sysInfoHtml += '<span>' + $sysInfo.ram + '</span>' }
if ($sysInfo.gpu) { $sysInfoHtml += '<span>' + $sysInfo.gpu + '</span>' }

# Quick stats HTML
$ctxSw = 0; $pgFlt = 0
if ($perfData.Count -gt 0) {
    $ctxSw = [math]::Round($perfData['\System\Context Switches/sec'].avg)
    $pgFlt = [math]::Round($perfData['\Memory\Page Faults/sec'].avg)
}

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Windows Latency Optimizer - Health Report</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;padding:32px;max-width:800px;margin:0 auto}
h1{font-size:22px;font-weight:600;margin-bottom:4px}
.subtitle{color:#94a3b8;font-size:13px;margin-bottom:24px}
.sys-info{display:flex;gap:16px;flex-wrap:wrap;margin-bottom:24px;font-size:12px;color:#94a3b8}
.sys-info span{background:#1e293b;padding:4px 10px;border-radius:6px}
.hero{display:flex;align-items:center;gap:32px;background:#1e293b;border-radius:12px;padding:24px;margin-bottom:24px}
.score-ring{position:relative;width:120px;height:120px;flex-shrink:0}
.score-ring svg{transform:rotate(-90deg)}
.score-ring .value{position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);font-size:36px;font-weight:700}
.score-ring .label{position:absolute;top:50%;left:50%;transform:translate(-50%,16px);font-size:12px;color:#94a3b8}
.hero-right{flex:1}
.hero-right h2{font-size:20px;margin-bottom:8px}
.hero-right .verdict{font-size:14px;color:#94a3b8}
.stats{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin-bottom:24px}
.stat{background:#1e293b;border-radius:8px;padding:12px;text-align:center}
.stat .val{font-size:20px;font-weight:600}
.stat .lbl{font-size:11px;color:#94a3b8;margin-top:2px}
.section{margin-bottom:24px}
.section h3{font-size:15px;font-weight:600;margin-bottom:12px;padding-bottom:6px;border-bottom:1px solid #334155}
.finding{padding:10px 14px;margin-bottom:6px;border-radius:8px;font-size:13px;line-height:1.5}
.finding.critical{background:#1c1017;border-left:3px solid #ef4444}
.finding.warning{background:#1c1a0f;border-left:3px solid #f59e0b}
.finding.pass{background:#0f1c16;border-left:3px solid #10b981}
.finding.info{background:#1e293b;border-left:3px solid #64748b}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:8px;vertical-align:middle}
.dot.red{background:#ef4444}.dot.amber{background:#f59e0b}.dot.green{background:#10b981}.dot.gray{background:#64748b}
.fix{margin-top:4px;font-size:12px;color:#94a3b8}
.fix code{background:#0f172a;padding:2px 6px;border-radius:4px;font-size:11px;color:#e2e8f0}
.score-row{display:flex;align-items:center;gap:10px;margin-bottom:8px;font-size:13px}
.score-label{width:120px;color:#94a3b8}
.score-bar-bg{flex:1;height:8px;background:#334155;border-radius:4px;overflow:hidden}
.score-bar{height:100%;border-radius:4px;transition:width 0.5s}
.score-val{width:50px;text-align:right;font-weight:600;font-size:12px}
.footer{text-align:center;color:#475569;font-size:11px;margin-top:32px;padding-top:16px;border-top:1px solid #1e293b}
@media print{body{background:#fff;color:#1e293b}.hero,.stat,.finding{border:1px solid #e2e8f0}}
</style>
</head>
<body>
<h1>Windows Latency Optimizer</h1>
<div class="subtitle">Health Report - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $($sysInfo.hostname)</div>
<div class="sys-info">$sysInfoHtml</div>

<div class="hero">
  <div class="score-ring">
    <svg width="120" height="120" viewBox="0 0 120 120">
      <circle cx="60" cy="60" r="50" fill="none" stroke="#334155" stroke-width="10"/>
      <circle cx="60" cy="60" r="50" fill="none" stroke="$scoreColor" stroke-width="10"
        stroke-dasharray="$([math]::Round(314 * $totalScore / 100)) 314" stroke-linecap="round"/>
    </svg>
    <div class="value" style="color:$scoreColor">$totalScore</div>
    <div class="label">/ 100</div>
  </div>
  <div class="hero-right">
    <h2 style="color:$scoreColor">$verdict</h2>
    <div class="verdict">$($criticals.Count) critical, $($warnings.Count) warnings, $($passes.Count) passing</div>
  </div>
</div>

<div class="stats">
  <div class="stat"><div class="val">$([math]::Round($dpcPct, 2))%</div><div class="lbl">DPC Time</div></div>
  <div class="stat"><div class="val">$([math]::Round($cpu0Intr + $cpu0Dpc, 1))%</div><div class="lbl">CPU 0 Load</div></div>
  <div class="stat"><div class="val">$([math]::Round($ctxSw/1000))K</div><div class="lbl">Ctx Switches/s</div></div>
  <div class="stat"><div class="val">$totalThreads</div><div class="lbl">Threads</div></div>
</div>

<div class="section">
  <h3>Findings</h3>
  $findingsHtml
</div>

<div class="section">
  <h3>Score Breakdown</h3>
  $breakdownHtml
</div>

<div class="footer">
  Generated by Windows Latency Optimizer (winlatopt.ps1)<br>
  github.com/your-repo/windows-latency-optimizer
</div>
</body>
</html>
"@

$reportPath = Join-Path $outDir 'health-report.html'
$html | Out-File $reportPath -Encoding UTF8

# ============================================================================
# OUTPUT
# ============================================================================

Write-Host '=== Health Score: ' -NoNewline
$scoreColorConsole = 'Red'
if ($totalScore -ge 80) { $scoreColorConsole = 'Green' }
elseif ($totalScore -ge 60) { $scoreColorConsole = 'Yellow' }
Write-Host ("$totalScore / 100 ($verdict)") -ForegroundColor $scoreColorConsole
Write-Host ''

Write-Host 'Score Breakdown:' -ForegroundColor Yellow
foreach ($c in $scoreComponents) {
    $pct = [math]::Round($c.score / $c.max * 100)
    $color = 'Red'
    if ($pct -ge 80) { $color = 'Green' } elseif ($pct -ge 50) { $color = 'Yellow' }
    Write-Host ('  {0,-18} {1,3}/{2,-3} ({3}%)' -f $c.name, $c.score, $c.max, $pct) -ForegroundColor $color
}

if ($criticals.Count -gt 0) {
    Write-Host ''
    Write-Host 'Critical Issues:' -ForegroundColor Red
    foreach ($f in $criticals) { Write-Host ('  - ' + $f.text) -ForegroundColor Red }
}

Write-Host ''
Write-Host ('Report: ' + $reportPath) -ForegroundColor Cyan

# Open in browser
Start-Process $reportPath

return $totalScore
