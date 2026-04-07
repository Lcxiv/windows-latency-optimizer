#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Quick mouse stutter diagnostic — 10-second capture with HID gap analysis.
.DESCRIPTION
    Runs a short ETW trace focusing on HID input events and DPC/ISR activity,
    then analyzes inter-event timing to detect input gaps (mouse freezes).
    Prints a summary with gap count, duration, and likely culprit driver.
.EXAMPLE
    .\diagnose-mouse.ps1
    .\diagnose-mouse.ps1 -DurationSec 30
#>
param(
    [int]$DurationSec = 10
)

$ErrorActionPreference = 'Stop'
$scriptsDir = Split-Path $MyInvocation.MyCommand.Path -Parent

# --- Load helpers ---
. (Join-Path $scriptsDir 'pipeline-helpers.ps1')

Write-Host ''
Write-Host '=== Mouse Stutter Diagnostic ===' -ForegroundColor Cyan
Write-Host ('Duration: ' + $DurationSec + 's')
Write-Host ''

# --- Step 1: Detect mouse ---
Write-Host '[1/4] Detecting mouse...' -ForegroundColor Yellow
$mouseDesc = 'Unknown'
$razerMice = @{
    '00C1' = 'Viper V3 Pro (Wireless)'; '00C0' = 'Viper V3 Pro (Wired)'
    '00B6' = 'Viper V3 HyperSpeed';     '00AA' = 'Basilisk V3 Pro'
    '009C' = 'DeathAdder V3';            '00B2' = 'DeathAdder V3 Pro'
}
$hidDevices = @(Get-WmiObject Win32_PnPEntity -ErrorAction SilentlyContinue |
    Where-Object { $_.DeviceID -like '*VID_1532*' -or $_.DeviceID -like '*VID_046D*' -or $_.DeviceID -like '*VID_1038*' })
foreach ($dev in $hidDevices) {
    if ($dev.DeviceID -like '*VID_1532*') {
        if ($dev.DeviceID -match 'PID_([0-9A-F]+)') {
            $mousePid = $Matches[1]
            if ($razerMice.ContainsKey($mousePid)) { $mouseDesc = 'Razer ' + $razerMice[$mousePid] }
            else { $mouseDesc = 'Razer (PID ' + $mousePid + ')' }
        } else { $mouseDesc = 'Razer Mouse' }
        break
    }
    if ($dev.DeviceID -like '*VID_046D*') { $mouseDesc = 'Logitech ' + $dev.Description; break }
    if ($dev.DeviceID -like '*VID_1038*') { $mouseDesc = 'SteelSeries ' + $dev.Description; break }
}
Write-Host ('  Found: ' + $mouseDesc) -ForegroundColor Green

# --- Step 2: Capture ---
Write-Host ''
Write-Host '[2/4] Capturing ETW trace (' + $DurationSec + 's)...' -ForegroundColor Yellow
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outDir = Join-Path (Split-Path $scriptsDir -Parent) ('captures\experiments\' + $timestamp + '_MOUSE_DIAG')
if (-not (Test-Path $outDir)) { New-Item -Path $outDir -ItemType Directory -Force | Out-Null }

$wprpPath = Join-Path $scriptsDir 'input-latency.wprp'
$etlFile = Join-Path $outDir 'trace.etl'

# Start WPR with InputLatency profile
$profileArg = $wprpPath + '!InputLatency.Verbose'
try {
    & wpr.exe -start $profileArg 2>&1 | Out-Null
    Write-Host '  WPR started. Move your mouse continuously...' -ForegroundColor Cyan
    Start-Sleep -Seconds $DurationSec
    Write-Host '  Stopping capture...'
    & wpr.exe -stop $etlFile 2>&1 | Out-Null
    Write-Host ('  Trace saved: ' + $etlFile) -ForegroundColor Green
} catch {
    Write-Host ('  WPR failed: ' + $_.Exception.Message) -ForegroundColor Red
    return
}

# --- Step 3: Analyze ---
Write-Host ''
Write-Host '[3/4] Analyzing HID input gaps...' -ForegroundColor Yellow
$analysisScript = Join-Path $scriptsDir 'analyze-input-latency.ps1'
$analysis = & $analysisScript -EtlFile $etlFile -OutDir $outDir

# --- Step 4: Summary ---
Write-Host ''
Write-Host '=== RESULTS ===' -ForegroundColor Cyan
Write-Host ('  Mouse: ' + $mouseDesc)

if ($null -ne $analysis -and $null -ne $analysis['mouseInputGaps']) {
    $gaps = $analysis['mouseInputGaps']
    Write-Host ('  HID events captured: ' + $gaps.totalEvents)
    Write-Host ('  Median input interval: ' + $gaps.medianIntervalMs + 'ms')

    if ($gaps.gapCount -gt 0) {
        Write-Host ''
        Write-Host ('  MOUSE INPUT GAPS: ' + $gaps.gapCount + ' detected') -ForegroundColor Red
        Write-Host ('  Longest gap: ' + $gaps.maxGapMs + 'ms') -ForegroundColor Red
        Write-Host ('  Average gap: ' + $gaps.avgGapMs + 'ms') -ForegroundColor Yellow

        if ($gaps.gaps.Count -gt 0) {
            $topDriver = $gaps.gaps[0].blamedDriver
            Write-Host ('  Likely cause: ' + $topDriver + ' DPC latency') -ForegroundColor Yellow
        }

        Write-Host ''
        Write-Host '  Recommendations:' -ForegroundColor Cyan
        Write-Host '    1. Move mouse dongle to a USB 2.0 port (not blue/USB 3.0)'
        Write-Host '    2. Check if companion software is configured (Razer Synapse/G Hub)'
        Write-Host ('    3. Investigate ' + $topDriver + ' driver updates')
    } else {
        Write-Host ''
        Write-Host '  No input gaps detected during capture period' -ForegroundColor Green
        Write-Host '  Mouse input appears healthy'
    }
} else {
    Write-Host '  Analysis incomplete — HID gap data not available' -ForegroundColor Yellow
    Write-Host '  DPC/ISR analysis may still provide useful data in:' -ForegroundColor Yellow
    Write-Host ('    ' + $outDir) -ForegroundColor Yellow
}

# Save summary JSON
$summaryJson = @{
    mouse       = $mouseDesc
    capturedAt  = (Get-Date).ToString('o')
    durationSec = $DurationSec
    outputDir   = $outDir
}
if ($null -ne $analysis -and $null -ne $analysis['mouseInputGaps']) {
    $summaryJson['mouseInputGaps'] = $analysis['mouseInputGaps']
}
if ($null -ne $analysis -and $null -ne $analysis['dpcHistogram']) {
    $summaryJson['dpcDrivers'] = @($analysis['dpcHistogram'] | Select-Object -First 5)
}
$jsonPath = Join-Path $outDir 'mouse_diagnostic.json'
($summaryJson | ConvertTo-Json -Depth 6) | Out-File -FilePath $jsonPath -Encoding UTF8
Write-Host ''
Write-Host ('  Results: ' + $jsonPath) -ForegroundColor Green
Write-Host ''
Write-Host 'Done.' -ForegroundColor Cyan
