#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Chrome rendering diagnostic for Twitch/YouTube slow page loads.
.DESCRIPTION
    Multi-phase capture: pre-flight baseline, instrumented Chrome launch,
    post-capture analysis (DPC, ProcMon, Defender, GPU, network).
    Outputs JSON + timing log for correlation.
.EXAMPLE
    .\diagnose_chrome_render.ps1 -Label "CHROME_FULL"
    .\diagnose_chrome_render.ps1 -Label "CHROME_TEST" -DurationSec 30 -SkipWPR -SkipProcMon
#>
param(
    [Parameter(Mandatory)]
    [string]$Label,

    [int]$DurationSec = 60,
    [int]$StreamWaitSec = 15,

    [switch]$SkipWPR,
    [switch]$SkipProcMon,
    [switch]$SkipDefenderRecording,
    [switch]$SkipExtensionTest,
    [switch]$SkipNetworkCapture,

    [string]$TwitchUrl = 'https://www.twitch.tv',
    [string]$YouTubeUrl = 'https://www.youtube.com',
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'

# ─── Load project modules ────────────────────────────────────────────────────
. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\helpers\logging.ps1"
. "$PSScriptRoot\helpers\capture-core.ps1"
. "$PSScriptRoot\helpers\capture-tools.ps1"
. "$PSScriptRoot\helpers\chrome.ps1"

$script:logLines = @()
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

if ($OutDir -eq '') {
    $OutDir = Join-Path $script:ExperimentsDir ($timestamp + '_CHROME_RENDER_' + $Label)
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$timingLog = Join-Path $OutDir 'timing_log.txt'
function LogTiming([string]$msg) {
    $line = (Get-Date -Format 'HH:mm:ss.fff') + ' ' + $msg
    Add-Content -Path $timingLog -Value $line
    Log $msg
}

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 0: Pre-flight
# ═══════════════════════════════════════════════════════════════════════════════
Log '╔══════════════════════════════════════════════════════════════╗'
Log '║  Chrome Rendering Diagnostic                                ║'
Log '╚══════════════════════════════════════════════════════════════╝'
Log ('Label:      ' + $Label)
Log ('Timestamp:  ' + $timestamp)
Log ('Duration:   ' + $DurationSec + 's')
Log ('Output:     ' + $OutDir)
Log ''

# P0a: Kill all Chrome
Log '=== Phase 0: Pre-flight ==='
$existingChrome = @(Get-Process -Name 'chrome' -ErrorAction SilentlyContinue)
if ($existingChrome.Count -gt 0) {
    Log ('Killing ' + $existingChrome.Count + ' Chrome processes...')
    $existingChrome | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}
Log 'Chrome killed' 'PASS'

# P0b: GPU idle state
$nvSmi = 'C:\Windows\System32\nvidia-smi.exe'
$gpuIdleState = $null
if (Test-Path $nvSmi) {
    $gpuRaw = & $nvSmi --query-gpu=pstate,clocks.current.graphics,clocks.current.memory,power.draw,temperature.gpu,utilization.gpu,utilization.memory --format=csv,noheader,nounits 2>&1
    $gpuParts = ($gpuRaw.Trim()) -split ',\s*'
    if ($gpuParts.Count -ge 7) {
        $gpuIdleState = @{
            pstate     = $gpuParts[0].Trim()
            clockGr    = $gpuParts[1].Trim()
            clockMem   = $gpuParts[2].Trim()
            powerW     = $gpuParts[3].Trim()
            tempC      = $gpuParts[4].Trim()
            gpuUtil    = $gpuParts[5].Trim()
            memUtil    = $gpuParts[6].Trim()
        }
        Log ('GPU idle: ' + $gpuIdleState.pstate + ' gr=' + $gpuIdleState.clockGr + 'MHz mem=' + $gpuIdleState.clockMem + 'MHz ' + $gpuIdleState.powerW + 'W ' + $gpuIdleState.tempC + 'C') 'INFO'
    }
}

# P0c: Defender Chrome exclusion audit
Log 'Checking Defender Chrome exclusions...'
$defenderAudit = Test-DefenderChromeExclusions
$defenderAudit | ConvertTo-Json -Depth 3 | Out-File (Join-Path $OutDir 'defender_chrome_state.json') -Encoding UTF8
if ($defenderAudit.notExcluded.Count -gt 0) {
    Log ('Defender: ' + $defenderAudit.notExcluded.Count + ' Chrome paths NOT excluded') 'WARN'
    foreach ($p in $defenderAudit.notExcluded) { Log ('  MISS: ' + $p) 'WARN' }
} else {
    Log 'All Chrome paths excluded from Defender' 'PASS'
}
if (-not $defenderAudit.chromeExeExcluded) {
    Log 'chrome.exe process NOT excluded from Defender' 'WARN'
}

# P0d: Chrome cache inventory
Log 'Measuring Chrome cache sizes...'
$cacheStats = Get-ChromeCacheStats
$cacheStats | ConvertTo-Json -Depth 3 | Out-File (Join-Path $OutDir 'chrome_cache_stats.json') -Encoding UTF8
foreach ($name in $cacheStats.Keys) {
    $c = $cacheStats[$name]
    Log ('  ' + $name + ': ' + $c.sizeMb + ' MB (' + $c.fileCount + ' files)')
}

# P0e: DWM/MPO/HAGS check
$dwmState = Get-DwmCompositorState
$dwmState | ConvertTo-Json -Depth 3 | Out-File (Join-Path $OutDir 'dwm_compositor_state.json') -Encoding UTF8
$mpoStr = 'disabled'
if ($dwmState.mpoEnabled) { $mpoStr = 'ENABLED' }
$hagsStr = 'unknown'
if ($null -ne $dwmState.hagsMode) {
    if ($dwmState.hagsMode -eq 1) { $hagsStr = 'Off' }
    elseif ($dwmState.hagsMode -eq 2) { $hagsStr = 'On' }
    else { $hagsStr = $dwmState.hagsMode.ToString() }
}
Log ('DWM: MPO=' + $mpoStr + ' HAGS=' + $hagsStr)

# P0f: System idle check
$cpuIdle = Test-SystemIdle

# P0g: Process snapshot before Chrome
$preProcs = @(Get-Process | Where-Object { $_.WorkingSet64 -gt 1MB } |
    Select-Object ProcessName, Id,
    @{N='WSMb'; E={[math]::Round($_.WorkingSet64/1MB, 1)}},
    @{N='CPU_s'; E={[math]::Round($_.TotalProcessorTime.TotalSeconds, 1)}} |
    Sort-Object WSMb -Descending |
    Select-Object -First 30)

LogTiming 'Phase 0 complete'

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 1: Start capture instruments
# ═══════════════════════════════════════════════════════════════════════════════
Log ''
Log '=== Phase 1: Starting capture instruments ==='

# P1a: WPR
$wprActive = $false
if (-not $SkipWPR) {
    $wprActive = Start-WprCapture -WPRProfile 'GeneralProfile' -WPRDetail 'Verbose'
}

# P1b: ProcMon
$procMonPml = Invoke-ProcMonCapture -OutDir $OutDir -DurationSec $DurationSec -SkipProcMon:$SkipProcMon

# P1c: Defender recording
$defenderRecInfo = Start-DefenderRecording -OutDir $OutDir -SkipDefenderRecording:$SkipDefenderRecording

# P1d: GPU clock polling (background job, 500ms intervals)
$gpuPollJob = $null
if (Test-Path $nvSmi) {
    $gpuCsvPath = Join-Path $OutDir 'gpu_clocks_timeline.csv'
    $pollDuration = $DurationSec + 10
    $gpuPollJob = Start-Job -ScriptBlock {
        param($nvSmiPath, $outPath, $dur)
        $lines = @('timestamp,pstate,clocks_gr,clocks_mem,power_draw,gpu_util,mem_util')
        for ($i = 0; $i -lt ($dur * 2); $i++) {
            $ts = Get-Date -Format 'HH:mm:ss.fff'
            $row = & $nvSmiPath --query-gpu=pstate,clocks.current.graphics,clocks.current.memory,power.draw,utilization.gpu,utilization.memory --format=csv,noheader,nounits 2>&1
            $lines += ($ts + ',' + $row.Trim())
            Start-Sleep -Milliseconds 500
        }
        $lines | Out-File $outPath -Encoding UTF8
    } -ArgumentList $nvSmi, $gpuCsvPath, $pollDuration
    Log 'GPU clock polling started (500ms intervals)' 'PASS'
}

# P1e: Perf counter polling (background job, 1s intervals)
$perfCounters = @(
    '\Processor(_Total)\% Processor Time',
    '\Processor(_Total)\% DPC Time',
    '\Processor(_Total)\% Interrupt Time',
    '\Processor(0)\% DPC Time',
    '\Processor(0)\% Interrupt Time',
    '\Memory\Available MBytes',
    '\Memory\Page Faults/sec',
    '\PhysicalDisk(_Total)\Current Disk Queue Length',
    '\PhysicalDisk(_Total)\Avg. Disk sec/Read',
    '\System\Context Switches/sec'
)
$perfJsonPath = Join-Path $OutDir 'perf_timeline.json'
$perfPollJob = Start-Job -ScriptBlock {
    param($counters, $outPath, $dur)
    $samples = @()
    try {
        $raw = Get-Counter -Counter $counters -SampleInterval 1 -MaxSamples $dur -ErrorAction Stop
        foreach ($s in $raw) {
            $ts = $s.Timestamp.ToString('HH:mm:ss.fff')
            $entry = @{ ts = $ts }
            foreach ($cs in $s.CounterSamples) {
                $key = ($cs.Path -replace '^\\\\[^\\]+', '') -replace '\\\\', '\'
                $entry[$key] = [math]::Round($cs.CookedValue, 4)
            }
            $samples += $entry
        }
    } catch {}
    $samples | ConvertTo-Json -Depth 3 | Out-File $outPath -Encoding UTF8
} -ArgumentList $perfCounters, $perfJsonPath, $DurationSec
Log 'Perf counter polling started (1s intervals)' 'PASS'

Start-Sleep -Seconds 3
LogTiming 'All instruments running'

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 2: Chrome launch + navigation
# ═══════════════════════════════════════════════════════════════════════════════
Log ''
Log '=== Phase 2: Chrome launch + navigation ==='

# P2a: Launch Chrome to about:blank
LogTiming 'Launching Chrome to about:blank'
$launchSw = [System.Diagnostics.Stopwatch]::StartNew()
Start-Process $script:ChromePath -ArgumentList 'about:blank'

# Poll for GPU process
$gpuReadyMs = $null
$maxPollMs = 15000
while ($launchSw.ElapsedMilliseconds -lt $maxPollMs) {
    $gpuProc = Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '--type=gpu-process' }
    if ($null -ne $gpuProc) {
        $gpuReadyMs = $launchSw.ElapsedMilliseconds
        LogTiming ('GPU process ready: ' + $gpuReadyMs + 'ms')
        break
    }
    Start-Sleep -Milliseconds 150
}
if ($null -eq $gpuReadyMs) {
    LogTiming 'GPU process NOT detected within 15s'
}

# Wait for Chrome to stabilize
Start-Sleep -Seconds 3
$launchSw.Stop()

# Snapshot Chrome tree after launch
$treeAfterLaunch = Get-ChromeProcessTree
$treeAfterLaunch | ConvertTo-Json -Depth 3 | Out-File (Join-Path $OutDir 'chrome_tree_launch.json') -Encoding UTF8
$launchWs = 0
foreach ($p in $treeAfterLaunch) { $launchWs += $p.wsMb }
LogTiming ('Chrome launched: ' + $treeAfterLaunch.Count + ' processes, ' + [math]::Round($launchWs) + ' MB')

# P2b: Navigate to Twitch
LogTiming ('Navigating to Twitch: ' + $TwitchUrl)
$twitchSw = [System.Diagnostics.Stopwatch]::StartNew()
Start-Process $script:ChromePath -ArgumentList $TwitchUrl
Start-Sleep -Seconds $StreamWaitSec
$twitchSw.Stop()

$treeAfterTwitch = Get-ChromeProcessTree
$treeAfterTwitch | ConvertTo-Json -Depth 3 | Out-File (Join-Path $OutDir 'chrome_tree_twitch.json') -Encoding UTF8
$twitchWs = 0
foreach ($p in $treeAfterTwitch) { $twitchWs += $p.wsMb }
LogTiming ('Twitch loaded: ' + $treeAfterTwitch.Count + ' processes, ' + [math]::Round($twitchWs) + ' MB (waited ' + $twitchSw.ElapsedMilliseconds + 'ms)')

# P2c: Navigate to YouTube
LogTiming ('Navigating to YouTube: ' + $YouTubeUrl)
$ytSw = [System.Diagnostics.Stopwatch]::StartNew()
Start-Process $script:ChromePath -ArgumentList $YouTubeUrl
Start-Sleep -Seconds $StreamWaitSec
$ytSw.Stop()

$treeAfterYt = Get-ChromeProcessTree
$treeAfterYt | ConvertTo-Json -Depth 3 | Out-File (Join-Path $OutDir 'chrome_tree_youtube.json') -Encoding UTF8
$ytWs = 0
foreach ($p in $treeAfterYt) { $ytWs += $p.wsMb }
LogTiming ('YouTube loaded: ' + $treeAfterYt.Count + ' processes, ' + [math]::Round($ytWs) + ' MB (waited ' + $ytSw.ElapsedMilliseconds + 'ms)')

# P2d: GPU state during active Chrome
$gpuActiveState = $null
if (Test-Path $nvSmi) {
    $gpuRaw2 = & $nvSmi --query-gpu=pstate,clocks.current.graphics,clocks.current.memory,power.draw,temperature.gpu,utilization.gpu,utilization.memory,utilization.decoder --format=csv,noheader,nounits 2>&1
    $gpuParts2 = ($gpuRaw2.Trim()) -split ',\s*'
    if ($gpuParts2.Count -ge 8) {
        $gpuActiveState = @{
            pstate     = $gpuParts2[0].Trim()
            clockGr    = $gpuParts2[1].Trim()
            clockMem   = $gpuParts2[2].Trim()
            powerW     = $gpuParts2[3].Trim()
            tempC      = $gpuParts2[4].Trim()
            gpuUtil    = $gpuParts2[5].Trim()
            memUtil    = $gpuParts2[6].Trim()
            decoderUtil = $gpuParts2[7].Trim()
        }
        Log ('GPU active: ' + $gpuActiveState.pstate + ' gr=' + $gpuActiveState.clockGr + 'MHz decoder=' + $gpuActiveState.decoderUtil + '%')
    }
}

LogTiming 'Phase 2 complete'

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 3: Stop instruments + collect artifacts
# ═══════════════════════════════════════════════════════════════════════════════
Log ''
Log '=== Phase 3: Stopping instruments ==='

# P3a: Stop WPR
$etlPath = $null
if ($wprActive) {
    $etlPath = Join-Path $OutDir 'wpr_chrome_launch.etl'
    Log 'Stopping WPR trace...'
    try {
        $wprResult = wpr -stop $etlPath 2>&1
        if ($LASTEXITCODE -eq 0) {
            $etlSize = [math]::Round((Get-Item $etlPath).Length / 1MB, 1)
            Log ('WPR trace saved: ' + $etlSize + ' MB') 'PASS'
        } else {
            Log ('WPR stop failed: ' + $wprResult) 'WARN'
            $etlPath = $null
        }
    } catch {
        Log ('WPR stop error: ' + $_.Exception.Message) 'WARN'
        $etlPath = $null
    }
}

# P3b: Stop Defender recording
$defenderReport = Stop-DefenderRecording -RecordingInfo $defenderRecInfo -OutDir $OutDir

# P3c: Wait for GPU poll job
if ($null -ne $gpuPollJob) {
    $gpuPollJob | Wait-Job -Timeout 30 | Out-Null
    Receive-Job $gpuPollJob -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $gpuPollJob -Force -ErrorAction SilentlyContinue
    if (Test-Path $gpuCsvPath) {
        $gpuLines = @(Get-Content $gpuCsvPath)
        Log ('GPU timeline: ' + ($gpuLines.Count - 1) + ' samples') 'PASS'
    }
}

# P3d: Wait for perf poll job
if ($null -ne $perfPollJob) {
    $perfPollJob | Wait-Job -Timeout 30 | Out-Null
    Receive-Job $perfPollJob -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $perfPollJob -Force -ErrorAction SilentlyContinue
    if (Test-Path $perfJsonPath) {
        Log 'Perf timeline saved' 'PASS'
    }
}

# P3e: Convert ProcMon PML to CSV
$procMonCsv = $null
if ($null -ne $procMonPml) {
    $procMonCsv = Convert-ProcMonToCSV -PmlFile $procMonPml -OutDir $OutDir
}

LogTiming 'Phase 3 complete'

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 4: Analysis
# ═══════════════════════════════════════════════════════════════════════════════
Log ''
Log '=== Phase 4: Analysis ==='

# P4a: xperf DPC/ISR analysis
$dpcAnalysis = $null
if ($null -ne $etlPath -and (Test-Path $etlPath)) {
    $xperf = $script:ToolPaths.Xperf
    if ($null -ne $xperf -and (Test-Path $xperf)) {
        $dpcReport = Join-Path $OutDir 'dpcisr_report.txt'
        Log 'Running xperf DPC/ISR analysis...'
        try {
            & $xperf -i $etlPath -o $dpcReport -a dpcisr 2>&1 | Out-Null
            if (Test-Path $dpcReport) {
                Log ('DPC/ISR report: ' + [math]::Round((Get-Item $dpcReport).Length / 1KB, 1) + ' KB') 'PASS'
            }
        } catch {
            Log ('xperf analysis failed: ' + $_.Exception.Message) 'WARN'
        }
    }
}

# P4b: ProcMon Chrome-specific analysis
$chromeIoAnalysis = $null
if ($null -ne $procMonCsv -and (Test-Path $procMonCsv)) {
    Log 'Analyzing ProcMon data for Chrome patterns...'
    $csv = @(Import-Csv $procMonCsv -ErrorAction SilentlyContinue)
    $total = $csv.Count

    if ($total -gt 0) {
        # Chrome events
        $chromeEvents = @($csv | Where-Object { $_.'Process Name' -like 'chrome*' })

        # Defender events touching Chrome paths
        $defenderOnChrome = @($csv | Where-Object {
            $_.'Process Name' -eq 'MsMpEng.exe' -and $_.Path -like '*Google\Chrome*'
        })

        # Defender total events
        $defenderTotal = @($csv | Where-Object { $_.'Process Name' -eq 'MsMpEng.exe' })

        # Chrome I/O hotspot directories
        $chromeIoDirs = @($chromeEvents |
            Where-Object { $_.Path -match '\\' -and ($_.Operation -match 'Read|Write|Create|Query') } |
            ForEach-Object {
                $parts = $_.Path -split '\\'
                $dirEnd = [math]::Min(6, $parts.Count)
                $parts[0..($dirEnd - 1)] -join '\'
            } |
            Group-Object |
            Sort-Object Count -Descending |
            Select-Object -First 15 |
            ForEach-Object { @{ directory = $_.Name; count = $_.Count } })

        # Chrome operations breakdown
        $chromeOps = @($chromeEvents | Group-Object Operation |
            Sort-Object Count -Descending |
            Select-Object -First 10 |
            ForEach-Object { @{ operation = $_.Name; count = $_.Count } })

        # High-duration Chrome operations
        $slowOps = @()
        foreach ($row in $chromeEvents) {
            $durStr = $row.Duration
            if ($null -eq $durStr -or $durStr -eq '') { continue }
            $dur = 0
            try { $dur = [double]$durStr } catch { continue }
            if ($dur -gt 0.001) {
                $slowOps += @{
                    time      = $row.'Time of Day'
                    operation = $row.Operation
                    path      = $row.Path
                    durationMs = [math]::Round($dur * 1000, 2)
                    result    = $row.Result
                }
            }
        }
        $slowOps = @($slowOps | Sort-Object { $_.durationMs } -Descending | Select-Object -First 30)

        $chromeIoAnalysis = @{
            totalEvents          = $total
            chromeEventCount     = $chromeEvents.Count
            chromeEventPct       = [math]::Round($chromeEvents.Count / $total * 100, 1)
            defenderTotalEvents  = $defenderTotal.Count
            defenderChromeEvents = $defenderOnChrome.Count
            defenderChromePct    = 0
            chromeIoHotspots     = $chromeIoDirs
            chromeOperations     = $chromeOps
            slowOperations       = $slowOps
        }
        if ($defenderTotal.Count -gt 0) {
            $chromeIoAnalysis.defenderChromePct = [math]::Round($defenderOnChrome.Count / $defenderTotal.Count * 100, 1)
        }

        Log ('ProcMon: ' + $chromeEvents.Count + ' Chrome events (' + $chromeIoAnalysis.chromeEventPct + '% of total)')
        Log ('ProcMon: ' + $defenderOnChrome.Count + ' Defender events on Chrome paths')
        Log ('ProcMon: ' + $slowOps.Count + ' slow Chrome ops (>1ms)')

        $chromeIoAnalysis | ConvertTo-Json -Depth 4 | Out-File (Join-Path $OutDir 'chrome_io_analysis.json') -Encoding UTF8
    }
}

# P4c: Defender performance report
if ($null -ne $defenderReport) {
    $defenderReport | ConvertTo-Json -Depth 5 | Out-File (Join-Path $OutDir 'defender_report.json') -Encoding UTF8
    Log 'Defender performance report saved' 'PASS'
}

# P4d: GPU P-state transition analysis
if (Test-Path $gpuCsvPath) {
    Log 'Analyzing GPU P-state transitions...'
    $gpuData = @(Import-Csv $gpuCsvPath -ErrorAction SilentlyContinue)
    $transitions = @()
    for ($i = 1; $i -lt $gpuData.Count; $i++) {
        if ($gpuData[$i].pstate -ne $gpuData[$i - 1].pstate) {
            $transitions += @{
                time        = $gpuData[$i].timestamp
                fromPstate  = $gpuData[$i - 1].pstate
                toPstate    = $gpuData[$i].pstate
                clockBefore = $gpuData[$i - 1].clocks_gr
                clockAfter  = $gpuData[$i].clocks_gr
            }
        }
    }
    if ($transitions.Count -gt 0) {
        Log ($transitions.Count + ' GPU P-state transitions detected') 'WARN'
        foreach ($t in $transitions) {
            Log ('  ' + $t.time + ': ' + $t.fromPstate + ' -> ' + $t.toPstate + ' (' + $t.clockBefore + ' -> ' + $t.clockAfter + ' MHz)')
        }
    } else {
        Log 'No GPU P-state transitions (stable)' 'PASS'
    }
    $transitions | ConvertTo-Json -Depth 3 | Out-File (Join-Path $OutDir 'gpu_pstate_transitions.json') -Encoding UTF8
}

# P4e: Network timing
if (-not $SkipNetworkCapture) {
    Log ''
    Log '--- Network timing ---'
    $dnsResults = Invoke-DnsTimingCapture
    foreach ($domain in $dnsResults.Keys) {
        $s = $dnsResults[$domain]
        Log ('  DNS ' + $domain + ': avg=' + $s.avg + 'ms min=' + $s.min + 'ms max=' + $s.max + 'ms')
    }
    $dnsResults | ConvertTo-Json -Depth 3 | Out-File (Join-Path $OutDir 'dns_timing.json') -Encoding UTF8

    $tlsResults = Invoke-TlsTimingCapture
    foreach ($host_ in $tlsResults.Keys) {
        $t = $tlsResults[$host_]
        if ($null -ne $t.tcpMs) {
            Log ('  TLS ' + $host_ + ': tcp=' + $t.tcpMs + 'ms handshake=' + $t.tlsHandshakeMs + 'ms (' + $t.protocol + ')')
        } else {
            Log ('  TLS ' + $host_ + ': FAILED - ' + $t.error) 'WARN'
        }
    }
    $tlsResults | ConvertTo-Json -Depth 3 | Out-File (Join-Path $OutDir 'tls_timing.json') -Encoding UTF8
}

LogTiming 'Phase 4 complete'

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 5: JSON export + summary
# ═══════════════════════════════════════════════════════════════════════════════
Log ''
Log '=== Phase 5: Summary ==='

$findings = @()

# Finding: Defender exclusions
if ($defenderAudit.notExcluded.Count -gt 0) {
    $findings += @{
        id       = 'DEFENDER_CHROME_NOT_EXCLUDED'
        severity = 'HIGH'
        detail   = $defenderAudit.notExcluded.Count.ToString() + ' Chrome paths not in Defender exclusions'
        fix      = 'Add-MpPreference -ExclusionPath "$env:LOCALAPPDATA\Google\Chrome\User Data"; Add-MpPreference -ExclusionProcess "chrome.exe"'
    }
}

# Finding: ShaderCache too small
$shaderSize = 0
if ($cacheStats.ContainsKey('ShaderCache')) { $shaderSize = $cacheStats['ShaderCache'].sizeMb }
if ($shaderSize -lt 1.0) {
    $findings += @{
        id       = 'SHADER_CACHE_SMALL'
        severity = 'MEDIUM'
        detail   = 'ShaderCache is ' + $shaderSize + ' MB (expected >1 MB)'
        fix      = 'Add --gpu-shader-disk-cache-size-kb=1048576 to Chrome shortcut'
    }
}

# Finding: GPU P-state transitions
if ($null -ne $gpuIdleState -and $gpuIdleState.pstate -match 'P[5-8]') {
    $findings += @{
        id       = 'GPU_DEEP_IDLE'
        severity = 'MEDIUM'
        detail   = 'GPU at ' + $gpuIdleState.pstate + ' (' + $gpuIdleState.clockGr + ' MHz) before Chrome launch'
        fix      = 'nvidia-smi -lgc 210,2820 to prevent deep P-state'
    }
}

# Finding: MPO enabled with multi-monitor
if ($dwmState.mpoEnabled) {
    $findings += @{
        id       = 'MPO_ENABLED'
        severity = 'LOW'
        detail   = 'MPO enabled — may cause DWM compositor stalls on mixed-refresh multi-monitor'
        fix      = 'Set-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\Dwm -Name OverlayTestMode -Value 5'
    }
}

# Finding: Defender events on Chrome paths from ProcMon
if ($null -ne $chromeIoAnalysis -and $chromeIoAnalysis.defenderChromeEvents -gt 100) {
    $findings += @{
        id       = 'DEFENDER_CHROME_IO_HEAVY'
        severity = 'HIGH'
        detail   = $chromeIoAnalysis.defenderChromeEvents.ToString() + ' Defender scan events on Chrome paths during capture'
        fix      = 'Add Chrome User Data to Defender exclusions'
    }
}

# Finding: Slow GPU process init
if ($null -ne $gpuReadyMs -and $gpuReadyMs -gt 1500) {
    $findings += @{
        id       = 'SLOW_GPU_PROCESS'
        severity = 'MEDIUM'
        detail   = 'Chrome GPU process took ' + $gpuReadyMs + 'ms to start (>1500ms threshold)'
        fix      = 'Check chrome://gpu for software fallback; ensure hardware acceleration enabled'
    }
}

# Build results JSON
$results = @{
    label              = $Label
    timestamp          = $timestamp
    durationSec        = $DurationSec
    system             = @{
        gpuIdle        = $gpuIdleState
        gpuActive      = $gpuActiveState
        cpuIdlePct     = $cpuIdle
        dwm            = $dwmState
    }
    defender           = @{
        exclusionAudit = $defenderAudit
        report         = $defenderReport
    }
    chrome             = @{
        cacheStats     = $cacheStats
        gpuReadyMs     = $gpuReadyMs
        treeAfterLaunch = $treeAfterLaunch
        processCountFinal = $treeAfterYt.Count
        memoryMbFinal  = [math]::Round($ytWs, 1)
    }
    analysis           = @{
        procMonChrome  = $chromeIoAnalysis
    }
    findings           = $findings
}

$jsonPath = Join-Path $OutDir 'chrome_render_diagnostic.json'
$results | ConvertTo-Json -Depth 6 | Out-File $jsonPath -Encoding UTF8
Log ('Results JSON: ' + $jsonPath) 'PASS'

# Print findings summary
Log ''
if ($findings.Count -eq 0) {
    Log 'No issues found' 'PASS'
} else {
    Log ($findings.Count.ToString() + ' findings:')
    foreach ($f in $findings) {
        $lvl = 'INFO'
        if ($f.severity -eq 'HIGH') { $lvl = 'WARN' }
        Log ('  [' + $f.severity + '] ' + $f.id + ': ' + $f.detail) $lvl
    }
}

# Print timing summary
Log ''
Log '--- Timing Summary ---'
Log ('GPU process ready:     ' + $gpuReadyMs + ' ms')
Log ('Chrome processes:      ' + $treeAfterYt.Count)
Log ('Chrome memory (final): ' + [math]::Round($ytWs) + ' MB')
Log ''
Log ('Output directory: ' + $OutDir)

# Save log
$script:logLines | Out-File (Join-Path $OutDir 'diagnostic.log') -Encoding UTF8

LogTiming 'Diagnostic complete'
