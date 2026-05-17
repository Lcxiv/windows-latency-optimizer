<#
.SYNOPSIS
    End-to-end experiment capture pipeline.
.DESCRIPTION
    Orchestrates: WPR trace, perf counters, GPU utilization, xperf DPC/ISR
    analysis, registry snapshot, and dashboard data regeneration.
    Outputs experiment.json + analysis.txt to captures/experiments/.

    Use -Mode to select a preset:
      Quick    (30s)  - Perf counters + registry + GPU only. Under 1 minute.
      Standard (120s) - WPR + perf + GPU + network. Recommended first run.
      Deep     (300s) - Everything enabled. Full diagnostic.

    Individual -Skip* flags override the preset.
.EXAMPLE
    .\pipeline.ps1 -Label "FIRST_RUN" -Description "Initial capture" -Mode Quick
.EXAMPLE
    .\pipeline.ps1 -Label "EXP01_TEST" -Description "Test capture" -DurationSec 120 -SkipWPR
.EXAMPLE
    .\pipeline.ps1 -Label "GAMING" -Description "Fortnite session" -Mode Deep -GameProcess "FortniteClient-Win64-Shipping"
#>
#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$Label,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$Description,

    [ValidateSet('Quick','Standard','Deep')]
    [string]$Mode = '',

    [ValidateRange(1, 3600)]
    [int]$DurationSec = 120,

    [switch]$SkipWPR,

    [switch]$SkipDashboardUpdate,

    [string]$WPRProfile = 'GeneralProfile',

    [ValidateSet('Verbose','Light')]
    [string]$WPRDetail = 'Verbose',

    [string]$GameProcess = '',
    [switch]$SkipPresentMon,
    [switch]$SkipProcMon,
    [switch]$SkipDefenderRecording,
    [switch]$SkipPktMon,
    [switch]$SkipBufferbloat,
    [switch]$SkipNetworkLatency
)

# pipeline.ps1 - End-to-end experiment capture and analysis (orchestrator)
# Helper functions are in pipeline-helpers.ps1, dot-sourced below.

$ErrorActionPreference = 'Stop'

# ── Apply mode presets (explicit -Skip* flags always override) ───────────────
if ($Mode -ne '') {
    # Only set flags the user did NOT explicitly specify
    if ($Mode -eq 'Quick') {
        if (-not $PSBoundParameters.ContainsKey('DurationSec'))            { $DurationSec = 30 }
        if (-not $PSBoundParameters.ContainsKey('SkipWPR'))                { $SkipWPR = [switch]$true }
        if (-not $PSBoundParameters.ContainsKey('SkipProcMon'))            { $SkipProcMon = [switch]$true }
        if (-not $PSBoundParameters.ContainsKey('SkipDefenderRecording'))  { $SkipDefenderRecording = [switch]$true }
        if (-not $PSBoundParameters.ContainsKey('SkipPktMon'))             { $SkipPktMon = [switch]$true }
        if (-not $PSBoundParameters.ContainsKey('SkipBufferbloat'))        { $SkipBufferbloat = [switch]$true }
    }
    elseif ($Mode -eq 'Standard') {
        if (-not $PSBoundParameters.ContainsKey('DurationSec'))            { $DurationSec = 120 }
        if (-not $PSBoundParameters.ContainsKey('SkipProcMon'))            { $SkipProcMon = [switch]$true }
        if (-not $PSBoundParameters.ContainsKey('SkipPktMon'))             { $SkipPktMon = [switch]$true }
    }
    elseif ($Mode -eq 'Deep') {
        if (-not $PSBoundParameters.ContainsKey('DurationSec'))            { $DurationSec = 300 }
        # Deep enables everything - no skips applied
    }
}
$scriptRoot = $PSScriptRoot
$projectRoot = (Resolve-Path (Join-Path $scriptRoot '..')).Path

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outDir = Join-Path $projectRoot ('captures\experiments\' + $timestamp + '_' + $Label)
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

# Shared log buffer — helpers append via $script:logLines
$logLines = @()

# Load helper functions
. "$PSScriptRoot\pipeline-helpers.ps1"

# ── PHASE 1: Pre-flight ──────────────────────────────────────────────────────
$modeLabel = 'Custom'
if ($Mode -ne '') { $modeLabel = $Mode }
Log ('=== Pipeline Start: ' + $Label + ' [' + $modeLabel + '] ===')
Log ('Description: ' + $Description)
Log ('Mode: ' + $modeLabel + ' | Duration: ' + $DurationSec + 's | WPR: ' + (-not $SkipWPR) + ' | ProcMon: ' + (-not $SkipProcMon) + ' | Network: ' + (-not $SkipNetworkLatency))
Log ('Output: ' + $outDir)

Test-SystemIdle | Out-Null

# ── PHASE 2: WPR trace ───────────────────────────────────────────────────────
$etlFile = Join-Path $outDir 'trace.etl'
$wprStarted = $false

if (-not $SkipWPR) {
    $wprStarted = Start-WprCapture -WPRProfile $WPRProfile -WPRDetail $WPRDetail
} else {
    Log ''
    Log '=== Phase 2: WPR skipped ==='
}

# ── PHASE 3: Perf counters + PresentMon (started before blocking capture) ────
# Auto-detect game if not specified
if ($GameProcess -eq '' -and -not $SkipPresentMon) {
    $detectedGame = Find-ForegroundGame
    if ($null -ne $detectedGame) {
        $GameProcess = $detectedGame
    } else {
        Log 'No game detected — PresentMon skipped (DWM fallback available from ETL)' 'INFO'
    }
}
$pmProc = Invoke-PresentMonCapture -GameProcess $GameProcess -OutDir $outDir -DurationSec $DurationSec -SkipPresentMon:$SkipPresentMon

# Start ProcMon + Defender recording (all run concurrently with perf counters)
$procmonPml = Invoke-ProcMonCapture -OutDir $outDir -DurationSec $DurationSec -SkipProcMon:$SkipProcMon
$defenderRec = Start-DefenderRecording -OutDir $outDir -SkipDefenderRecording:$SkipDefenderRecording
$pktmonEtl = Start-PktMonCapture -OutDir $outDir -SkipPktMon:$SkipPktMon

$perfResult = Invoke-PerfCounterCapture -DurationSec $DurationSec

$cpuData       = $perfResult.cpuData
$cpuInterrupt  = $perfResult.cpuInterrupt
$cpuDpc        = $perfResult.cpuDpc
$cpuIntrPerSec = $perfResult.cpuIntrPerSec
$perf          = $perfResult.perf

# ── PHASE 3B: PresentMon frame timing ────────────────────────────────────────
$frameTimingData = $null
if ($pmProc -and -not $pmProc.HasExited) {
    Log 'Waiting for PresentMon to finish...'
    $pmProc.WaitForExit(30000) | Out-Null
}
if ($pmProc) {
    $pmCsv = Join-Path $outDir 'frames.csv'
    $frameTimingData = Parse-FrameCSV -CsvPath $pmCsv -GameProcess $GameProcess
    if ($frameTimingData) {
        $ftAvg = $frameTimingData.frameTimeMs.avg
        $fpsAvg = $frameTimingData.fps.avg
        Log ('Frame timing: ' + $ftAvg + 'ms avg, ' + $fpsAvg + ' FPS, ' + $frameTimingData.totalFrames + ' frames') 'PASS'
    } else {
        Log 'PresentMon CSV parsing failed or no data' 'WARN'
    }
}

# ── PHASE 3C: GPU counters ───────────────────────────────────────────────────
$gpuUtilData = Invoke-GpuCapture

# ── PHASE 3D: Network latency ───────────────────────────────────────────────
$networkData = Invoke-NetworkLatencyCapture -SkipNetworkLatency:$SkipNetworkLatency

# ── PHASE 3E: Bufferbloat test ──────────────────────────────────────────────
$bufferbloatData = $null
if (-not $SkipBufferbloat -and -not $SkipNetworkLatency) {
    $bufferbloatData = Test-Bufferbloat
}

# ── PHASE 3F: SMI health check ──────────────────────────────────────────────
$smiData = $null
if (-not $SkipWPR -and $wprStarted) {
    # WPR holds the kernel logger - cannot run separate xperf session
    Log 'SMI check skipped (WPR active)' 'INFO'
} elseif ($script:ToolPaths.Xperf -and (Test-Path $script:ToolPaths.Xperf)) {
    $smiData = Invoke-SmiGapCapture -OutDir $outDir -DurationSec 10
}

# ── PHASE 4: Stop WPR + xperf analysis ───────────────────────────────────────
$dpcIsrData = $null
if ($wprStarted) {
    $dpcIsrData = Stop-WprAndAnalyze -EtlFile $etlFile -OutDir $outDir -Description $Description -WPRProfile $WPRProfile
} else {
    Log ''
    Log '=== Phase 4: Skipped - no WPR trace ==='
}

# ── PHASE 4B: ProcMon conversion + analysis ──────────────────────────────────
$procmonData = $null
if ($null -ne $procmonPml) {
    Log ''
    Log '=== Phase 4B: ProcMon analysis ==='
    # Wait for ProcMon to finish (it auto-terminates after /Runtime seconds)
    $pmWait = 0
    while ($pmWait -lt ($DurationSec + 10)) {
        Start-Sleep -Seconds 2
        $pmWait += 2
        if (Test-Path $procmonPml) {
            $pmRunning = Get-Process -Name 'Procmon64' -ErrorAction SilentlyContinue
            if ($null -eq $pmRunning) { break }
        }
    }
    $procmonCsv = Convert-ProcMonToCSV -PmlFile $procmonPml -OutDir $outDir
    if ($null -ne $procmonCsv) {
        $procmonData = Analyze-ProcMonCSV -CsvPath $procmonCsv
    }
}

# ── PHASE 4C: Stop Defender recording ────────────────────────────────────────
$defenderData = Stop-DefenderRecording -RecordingInfo $defenderRec -OutDir $outDir

# ── PHASE 4D: Stop pktmon + analysis ─────────────────────────────────────────
$pktmonData = $null
if ($null -ne $pktmonEtl) {
    Log ''
    Log '=== Phase 4D: Network capture analysis ==='
    $pktmonFile = Stop-PktMonCapture -EtlFile $pktmonEtl -OutDir $outDir
    $pktmonData = Analyze-PktMonCapture -CaptureFile $pktmonFile -OutDir $outDir
}

# ── PHASE 5: Registry snapshot ───────────────────────────────────────────────
$reg = Get-RegistrySnapshot

# ── PHASE 6: Analysis ────────────────────────────────────────────────────────
$analysisResult = New-ExperimentAnalysis `
    -Label $Label -Description $Description -DurationSec $DurationSec `
    -CpuData $cpuData -CpuInterrupt $cpuInterrupt -CpuDpc $cpuDpc `
    -DpcIsrData $dpcIsrData -FrameTimingData $frameTimingData `
    -GpuUtilData $gpuUtilData -NetworkLatencyData $networkData `
    -WprStarted $wprStarted -EtlFile $etlFile

$groupShares = $analysisResult.groupShares
$topology    = $analysisResult.topology
$cpu0Share   = $analysisResult.cpu0Share
$cpu23Share  = $analysisResult.cpu23Share
$cpu47Share  = $analysisResult.cpu47Share

$analysisFile = Join-Path $outDir 'analysis.txt'
$analysisResult.analysisLines | Out-File $analysisFile -Encoding UTF8

# Add SMI correlation from perf counter data
if ($smiData -and $cpuData) {
    $smiData['correlationScore'] = Get-SmiCorrelation -CpuData $cpuData
}

# ── PHASE 7: Save JSON ───────────────────────────────────────────────────────
Save-ExperimentJson `
    -OutDir $outDir -Label $Label -Description $Description -DurationSec $DurationSec `
    -SkipWPR:$SkipWPR -WPRProfile $WPRProfile -WPRDetail $WPRDetail `
    -WprStarted $wprStarted -EtlFile $etlFile `
    -Registry $reg -Perf $perf -CpuData $cpuData `
    -CpuInterrupt $cpuInterrupt -CpuDpc $cpuDpc -CpuIntrPerSec $cpuIntrPerSec `
    -GroupShares $groupShares -Topology $topology `
    -DpcIsrData $dpcIsrData -FrameTimingData $frameTimingData -GpuUtilData $gpuUtilData `
    -NetworkLatencyData $networkData -ProcMonData $procmonData -DefenderData $defenderData -PktMonData $pktmonData -BufferbloatData $bufferbloatData `
    -SmiData $smiData

# ── PHASE 8: Dashboard update ────────────────────────────────────────────────
Update-DashboardData -ScriptRoot $scriptRoot -SkipDashboardUpdate:$SkipDashboardUpdate

# ── SUMMARY ──────────────────────────────────────────────────────────────────
Log ''
Log '========================================'
Log '=== Pipeline Complete ==='
Log '========================================'
Log ''
Log ('Output: ' + $outDir)
Log '  experiment.json - perf counters + registry + per-CPU'
if ($wprStarted -and (Test-Path $etlFile)) {
    Log '  trace.etl       - open in WPA for DPC/ISR drill-down'
    Log '  dpcisr_report   - xperf DPC/ISR summary'
}
Log '  analysis.txt    - human-readable report'
Log ''
$topoSummary = ''
foreach ($gs in $groupShares) {
    if ($topoSummary -ne '') { $topoSummary += ' | ' }
    $topoSummary += $gs.label + '=' + $gs.share + '%'
}
Log ('Topology: ' + $topoSummary)
if ($frameTimingData) {
    Log ('  FPS: ' + $frameTimingData.fps.avg + ' avg, ' + $frameTimingData.fps.p1Low + ' 1% low')
}
if ($networkData) {
    foreach ($h in ($networkData.Keys | Sort-Object)) {
        $nd = $networkData[$h]
        if ($null -ne $nd.avg) {
            Log ('  Ping ' + $h + ': ' + $nd.avg + 'ms avg, ' + $nd.p99 + 'ms p99')
        }
    }
}

$logLines | Out-File (Join-Path $outDir 'pipeline.log') -Encoding UTF8
