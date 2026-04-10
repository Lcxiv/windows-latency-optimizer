# helpers/experiment.ps1
# Data assembly and output: frame parsing, registry snapshot, analysis,
# experiment JSON generation, and dashboard data update.
# PowerShell 5.1 compatible.

function Parse-FrameCSV {
    param([string]$CsvPath, [string]$GameProcess = '')
    if (-not (Test-Path $CsvPath)) { return $null }
    $csv = @(Import-Csv $CsvPath)
    if ($csv.Count -eq 0) { return $null }

    # Find the frame time column (varies by PresentMon version)
    $ftCol = $null
    foreach ($col in @('MsBetweenPresents', 'msBetweenPresents', 'ms_between_presents')) {
        if ($csv[0].PSObject.Properties.Name -contains $col) { $ftCol = $col; break }
    }
    if (-not $ftCol) { return $null }

    $frameTimes = @($csv | ForEach-Object { [double]$_.$ftCol } | Where-Object { $_ -gt 0 -and $_ -lt 1000 })
    if ($frameTimes.Count -eq 0) { return $null }

    $sorted = $frameTimes | Sort-Object
    $count = $sorted.Count

    $avg = ($sorted | Measure-Object -Average).Average
    $p50 = $sorted[[math]::Floor($count * 0.50)]
    $p95 = $sorted[[math]::Floor($count * 0.95)]
    $p99 = $sorted[[math]::Floor($count * 0.99)]
    $maxFt = $sorted[-1]
    $minFt = $sorted[0]

    # FPS
    $fpsAvg = 1000.0 / $avg
    $fps1Low = 1000.0 / $p99

    # Dropped frames (if column exists)
    $dropped = 0
    foreach ($col in @('Dropped', 'dropped', 'WasBatched')) {
        if ($csv[0].PSObject.Properties.Name -contains $col) {
            $dropped = @($csv | Where-Object { $_.$col -eq '1' -or $_.$col -eq 'True' }).Count
            break
        }
    }

    # Variance (coefficient of variation)
    $sumSqDiff = 0
    foreach ($ft in $frameTimes) { $sumSqDiff += ($ft - $avg) * ($ft - $avg) }
    $stdev = [math]::Sqrt($sumSqDiff / [math]::Max(1, $count))
    $cv = 0
    if ($avg -gt 0) { $cv = [math]::Round($stdev / $avg * 100, 1) }

    # Stutter detection: frame time > 2× rolling median (window=30)
    $stutters    = @()
    $windowSize  = 30
    $halfWindow  = [math]::Floor($windowSize / 2)
    for ($i = 0; $i -lt $frameTimes.Count; $i++) {
        $wStart = [math]::Max(0, $i - $halfWindow)
        $wEnd   = [math]::Min($frameTimes.Count - 1, $i + $halfWindow)
        $window = @($frameTimes[$wStart..$wEnd] | Sort-Object)
        $median = $window[[math]::Floor($window.Count / 2)]
        if ($frameTimes[$i] -gt ($median * 2) -and $frameTimes[$i] -lt 50 -and $median -gt 0) {
            $stutters += @{
                frameIndex  = $i
                frameTimeMs = [math]::Round($frameTimes[$i], 2)
                medianMs    = [math]::Round($median, 2)
            }
        }
    }

    return @{
        processName   = $GameProcess
        totalFrames   = $count
        droppedFrames = $dropped
        droppedPct    = [math]::Round($dropped / [math]::Max(1, $count) * 100, 2)
        stutterCount  = $stutters.Count
        stutters      = $stutters
        frameTimeMs   = @{
            avg    = [math]::Round($avg, 2)
            p50    = [math]::Round($p50, 2)
            p95    = [math]::Round($p95, 2)
            p99    = [math]::Round($p99, 2)
            max    = [math]::Round($maxFt, 2)
            min    = [math]::Round($minFt, 2)
            stdev  = [math]::Round($stdev, 2)
            cv     = $cv
        }
        fps = @{
            avg   = [math]::Round($fpsAvg, 1)
            p1Low = [math]::Round($fps1Low, 1)
            min   = [math]::Round(1000.0 / $maxFt, 1)
        }
    }
}


function Get-RegistrySnapshot {
    <#
    .SYNOPSIS
        Capture registry state for MMCSS, Defender, GPU, and interrupt affinities.
    .OUTPUTS
        [hashtable] Registry key/value pairs.
    #>
    Log ''
    Log '=== Phase 5: Registry snapshot ==='

    $reg = @{}
    try {
        $mmcss = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -ErrorAction Stop
        $games = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' -ErrorAction Stop
        $reg['SystemResponsiveness']    = $mmcss.SystemResponsiveness
        $reg['NetworkThrottlingIndex']  = $mmcss.NetworkThrottlingIndex
        $reg['GamesSchedulingCategory'] = $games.'Scheduling Category'
        $reg['GamesPriority']           = $games.Priority
        $reg['GamesSFIOPriority']       = $games.'SFIO Priority'
    } catch { $reg['MMCSS_Error'] = $_.Exception.Message }

    try {
        $mp = Get-MpPreference -ErrorAction Stop
        $reg['ScanAvgCPULoadFactor'] = $mp.ScanAvgCPULoadFactor
        $reg['EnableLowCpuPriority'] = [string]$mp.EnableLowCpuPriority
        $excPaths = 0; if ($mp.ExclusionPath) { $excPaths = $mp.ExclusionPath.Count }
        $excProcs = 0; if ($mp.ExclusionProcess) { $excProcs = $mp.ExclusionProcess.Count }
        $reg['ExclusionPathCount']    = $excPaths
        $reg['ExclusionProcessCount'] = $excProcs
    } catch { $reg['Defender_Error'] = $_.Exception.Message }

    # GPU registry snapshot (vendor-agnostic via gpu-vendor.ps1)
    $gpuReg = Get-GpuRegistrySnapshot
    foreach ($k in $gpuReg.Keys) { $reg[$k] = $gpuReg[$k] }

    $affinities = @{}
    foreach ($dc in $script:AffinityDeviceChecks) {
        $dk = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like ('*' + $dc.Pattern + '*') } | Select-Object -First 1
        if ($dk) {
            $affPath = Join-Path $dk.PSPath 'Device Parameters\Interrupt Management\Affinity Policy'
            if (Test-Path $affPath) {
                $v = Get-ItemProperty $affPath -ErrorAction SilentlyContinue
                if ($v.AssignmentSetOverride) {
                    $hex = '0x' + $v.AssignmentSetOverride[0].ToString('X2')
                    $affinities[$dc.Name] = @{ DevicePolicy = $v.DevicePolicy; MaskByte0 = $hex }
                }
            }
        }
    }
    $reg['InterruptAffinities'] = $affinities
    Log 'Registry snapshot captured' 'PASS'

    return $reg
}

function New-ExperimentAnalysis {
    <#
    .SYNOPSIS
        Build the human-readable analysis text and compute topology shares.
    .OUTPUTS
        [hashtable] Keys: analysisLines, cpu0Share, cpu23Share, cpu47Share.
    #>
    param(
        [string]$Label,
        [string]$Description,
        [int]$DurationSec,
        [array]$CpuData,
        [hashtable]$CpuInterrupt,
        [hashtable]$CpuDpc,
        $DpcIsrData,
        $FrameTimingData,
        $GpuUtilData,
        $NetworkLatencyData,
        [bool]$WprStarted,
        [string]$EtlFile
    )

    Log ''
    Log '=== Phase 6: Analysis ==='

    $analysis = @()
    $analysis += '=== Experiment Analysis: ' + $Label + ' ==='
    $analysis += 'Description: ' + $Description
    $analysis += 'Captured: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $analysis += 'Duration: ' + $DurationSec + 's'
    $analysis += ''

    # ── Dynamic topology-based interrupt distribution ──
    $topo = Get-CpuTopology
    $groupShares = @()
    $cpu0Share = 0; $cpu23Share = 0; $cpu47Share = 0
    foreach ($g in $topo.groups) {
        $share = Get-GroupShareFromCpuData -CpuData $CpuData -GroupCpus $g.cpus
        $groupShares += @{ name = $g.name; cpus = $g.cpus; label = $g.label; share = $share }
        if ($g.name -eq 'preferred') { $cpu0Share  = $share }
        if ($g.name -eq 'input')     { $cpu23Share = $share }
        if ($g.name -eq 'bulk')      { $cpu47Share = $share }
    }

    $analysis += '--- Interrupt Distribution (' + $topo.cpuModel + ') ---'
    foreach ($gs in $groupShares) {
        $cpuRange = ($gs.cpus | Sort-Object | ForEach-Object { $_.ToString() }) -join ','
        $padLabel = ($gs.label + ':').PadRight(16)
        $analysis += 'CPUs ' + $cpuRange + '  ' + $padLabel + $gs.share + '%'
    }
    $analysis += ''

    $analysis += '--- Targets ---'
    $totalDpcAvg = 0; if ($CpuDpc.ContainsKey('_total') -and $CpuDpc['_total']) { $totalDpcAvg = $CpuDpc['_total'].avg }
    $totalIntrAvg = 0; if ($CpuInterrupt.ContainsKey('_total') -and $CpuInterrupt['_total']) { $totalIntrAvg = $CpuInterrupt['_total'].avg }

    $chk1 = if ($cpu0Share -lt 10) { 'PASS' } else { 'REVIEW' }
    $chk2 = if ($totalDpcAvg -lt 0.5) { 'PASS' } else { 'REVIEW' }
    $chk3 = if ($totalIntrAvg -lt 1.0) { 'PASS' } else { 'REVIEW' }

    $prefCpus = (($topo.groups | Where-Object { $_.name -eq 'preferred' }).cpus -join ',')
    $analysis += '[' + $chk1 + '] Preferred (CPU ' + $prefCpus + ') share <10%: ' + $cpu0Share + '%'
    $analysis += '[' + $chk2 + '] Total DPC <0.5%: ' + $totalDpcAvg + '%'
    $analysis += '[' + $chk3 + '] Total Interrupt <1.0%: ' + $totalIntrAvg + '%'

    Log ('Preferred share: ' + $cpu0Share + '%') $chk1
    Log ('Total DPC: ' + $totalDpcAvg + '%') $chk2
    Log ('Total Interrupt: ' + $totalIntrAvg + '%') $chk3

    # Build CPU-to-role lookup from topology groups
    $cpuRoles = @{}
    foreach ($g in $topo.groups) {
        foreach ($cpuIdx in $g.cpus) { $cpuRoles[$cpuIdx] = ' <-' + $g.label }
    }

    $analysis += ''
    $analysis += '--- Per-CPU ---'
    foreach ($c in ($CpuData | Sort-Object cpu)) {
        $role = ''
        if ($cpuRoles.ContainsKey($c.cpu)) { $role = $cpuRoles[$c.cpu] }
        $analysis += ('{0,-6} {1,10:N4} {2,10:N4} {3,12:N1}{4}' -f ('CPU' + $c.cpu), $c.interruptPct, $c.dpcPct, $c.intrPerSec, $role)
    }

    # xperf results in analysis
    if ($DpcIsrData -and $DpcIsrData.hasReport) {
        $analysis += ''
        $analysis += '--- xperf DPC/ISR Analysis ---'
        if ($DpcIsrData.dpcDrivers) {
            $analysis += ''
            $analysis += 'Top DPC offenders:'
            foreach ($d in $DpcIsrData.dpcDrivers) {
                $analysis += ('  ' + $d.Module + '  count=' + $d.Count + '  max=' + $d.MaxUs + 'us')
            }
        }
        if ($DpcIsrData.isrDrivers) {
            $analysis += ''
            $analysis += 'Top ISR offenders:'
            foreach ($d in $DpcIsrData.isrDrivers) {
                $analysis += ('  ' + $d.Module + '  count=' + $d.Count + '  max=' + $d.MaxUs + 'us')
            }
        }
    }

    if ($FrameTimingData) {
        $analysis += ''
        $analysis += '--- Frame Timing ---'
        $analysis += 'Process: ' + $FrameTimingData.processName
        $analysis += 'Frames: ' + $FrameTimingData.totalFrames + ' total, ' + $FrameTimingData.droppedFrames + ' dropped'
        $analysis += 'Frame time: ' + $FrameTimingData.frameTimeMs.avg + 'ms avg, ' + $FrameTimingData.frameTimeMs.p99 + 'ms p99, ' + $FrameTimingData.frameTimeMs.max + 'ms max'
        $analysis += 'FPS: ' + $FrameTimingData.fps.avg + ' avg, ' + $FrameTimingData.fps.p1Low + ' 1% low, ' + $FrameTimingData.fps.min + ' min'
    }

    if ($GpuUtilData) {
        $analysis += ''
        $analysis += '--- GPU Utilization ---'
        foreach ($eng in ($GpuUtilData.Keys | Sort-Object)) {
            $analysis += ('  ' + $eng + ': ' + $GpuUtilData[$eng].avg + '% avg, ' + $GpuUtilData[$eng].max + '% max')
        }
    }

    if ($NetworkLatencyData) {
        $analysis += ''
        $analysis += '--- Network Latency ---'
        foreach ($host_ in ($NetworkLatencyData.Keys | Sort-Object)) {
            $h = $NetworkLatencyData[$host_]
            if ($null -ne $h.avg) {
                $analysis += ('  ' + $host_ + ': ' + $h.avg + 'ms avg, ' + $h.p99 + 'ms p99, jitter=' + $h.jitter + 'ms, loss=' + $h.packetLoss + '%')
            } else {
                $analysis += ('  ' + $host_ + ': FAILED (' + $h.error + ')')
            }
        }
    }

    if ($WprStarted -and (Test-Path $EtlFile)) {
        $analysis += ''
        $analysis += 'For deeper analysis open trace.etl in WPA'
    }

    return @{
        analysisLines = $analysis
        groupShares   = $groupShares
        topology      = $topo
        # Backwards-compat keys
        cpu0Share     = $cpu0Share
        cpu23Share    = $cpu23Share
        cpu47Share    = $cpu47Share
    }
}


function Save-ExperimentJson {
    <#
    .SYNOPSIS
        Assemble and save the experiment JSON file.
    .OUTPUTS
        [string] Path to the saved JSON file.
    #>
    param(
        [string]$OutDir,
        [string]$Label,
        [string]$Description,
        [int]$DurationSec,
        [switch]$SkipWPR,
        [string]$WPRProfile,
        [string]$WPRDetail,
        [bool]$WprStarted,
        [string]$EtlFile,
        [hashtable]$Registry,
        [hashtable]$Perf,
        [array]$CpuData,
        [hashtable]$CpuInterrupt,
        [hashtable]$CpuDpc,
        [hashtable]$CpuIntrPerSec,
        [array]$GroupShares = @(),
        $Topology = $null,
        [double]$Cpu0Share = -1,
        [double]$Cpu23Share = -1,
        [double]$Cpu47Share = -1,
        $DpcIsrData,
        $FrameTimingData,
        $GpuUtilData,
        $NetworkLatencyData,
        $ProcMonData = $null,
        $DefenderData = $null,
        $PktMonData = $null,
        $BufferbloatData = $null
    )

    Log ''
    Log '=== Phase 7: Saving experiment JSON ==='

    $wprProf = $null; if (-not $SkipWPR) { $wprProf = $WPRProfile + '.' + $WPRDetail }
    $wprEtl = $null; if ($WprStarted -and (Test-Path $EtlFile)) { $wprEtl = 'trace.etl' }

    $dpcIsrJson = $null
    if ($DpcIsrData) {
        $src = 'unknown'; if ($DpcIsrData.hasReport) { $src = 'xperf' }
        $dpcD = @(); if ($DpcIsrData.dpcDrivers) { $dpcD = $DpcIsrData.dpcDrivers }
        $isrD = @(); if ($DpcIsrData.isrDrivers) { $isrD = $DpcIsrData.isrDrivers }
        $alerts = @(); if ($DpcIsrData.dpcAlerts) { $alerts = $DpcIsrData.dpcAlerts }
        $dpcIsrJson = @{ source = $src; dpcDrivers = $dpcD; isrDrivers = $isrD; dpcAlerts = $alerts }
    }

    # Build interruptTopology with new groups format + backwards-compat keys
    $topoData = [ordered]@{}
    if ($GroupShares.Count -gt 0) {
        $groupsArray = @()
        foreach ($gs in $GroupShares) {
            $groupsArray += [ordered]@{ name = $gs.name; cpus = $gs.cpus; share = $gs.share }
        }
        $topoData['cpu0Share']  = ($GroupShares | Where-Object { $_.name -eq 'preferred' }).share
        $topoData['cpu23Share'] = ($GroupShares | Where-Object { $_.name -eq 'input' }).share
        $topoData['cpu47Share'] = ($GroupShares | Where-Object { $_.name -eq 'bulk' }).share
        $topoData['groups']     = $groupsArray
        $topoModel = ''
        $topoLogical = [int]$env:NUMBER_OF_PROCESSORS
        if ($Topology) {
            $topoModel   = $Topology.cpuModel
            $topoLogical = $Topology.totalLogical
        }
        $topoData['totalLogicalCpus'] = $topoLogical
        $topoData['cpuModel']         = $topoModel
    } elseif ($Cpu0Share -ge 0) {
        $topoData = @{ cpu0Share = $Cpu0Share; cpu23Share = $Cpu23Share; cpu47Share = $Cpu47Share }
    }

    # Build systemInfo from WMI + topology
    $sysInfo = [ordered]@{
        hostname = $env:COMPUTERNAME
    }
    try {
        $topo = Get-CpuTopology
        $sysInfo['cpu'] = $topo.cpuModel
        $sysInfo['cores'] = $topo.totalCores.ToString() + 'C/' + $topo.totalLogical.ToString() + 'T'
    } catch {
        $sysInfo['cpu'] = 'Unknown'
        $sysInfo['cores'] = $env:NUMBER_OF_PROCESSORS + 'T'
    }
    try {
        $ramBytes = (Get-WmiObject Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
        $sysInfo['ram'] = [math]::Round($ramBytes / 1GB).ToString() + ' GB'
    } catch { $sysInfo['ram'] = 'Unknown' }
    try {
        $osInfo = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop
        $sysInfo['os'] = $osInfo.Caption.Trim() + ' Build ' + $osInfo.BuildNumber
    } catch { $sysInfo['os'] = 'Windows' }
    try {
        $gpu = Get-WmiObject Win32_VideoController -ErrorAction Stop | Where-Object { $_.Name -notmatch 'Basic Display' } | Select-Object -First 1
        if ($gpu) { $sysInfo['gpu'] = $gpu.Name }
    } catch { }

    $result = [ordered]@{
        schemaVersion     = 4
        label             = $Label
        description       = $Description
        capturedAt        = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        durationSec       = $DurationSec
        hostname          = $env:COMPUTERNAME
        systemInfo        = $sysInfo
        wprProfile        = $wprProf
        wprEtlFile        = $wprEtl
        registry          = $Registry
        performance       = $Perf
        cpuData           = $CpuData
        cpuTotal          = @{ interruptPct = $CpuInterrupt['_total'].avg; dpcPct = $CpuDpc['_total'].avg; intrPerSec = $CpuIntrPerSec['_total'].avg }
        interruptTopology = $topoData
        dpcIsrAnalysis    = $dpcIsrJson
        analysisFile      = 'analysis.txt'
        frameTiming       = $FrameTimingData
        gpuUtilization    = $GpuUtilData
        networkLatency    = $NetworkLatencyData
        cswitchAnalysis   = $null
        procmonAnalysis   = $ProcMonData
        defenderAnalysis  = $DefenderData
        networkCapture    = $PktMonData
        bufferbloat       = $BufferbloatData
        connectionQuality = (Get-ConnectionQualityScore -NetworkLatency $NetworkLatencyData -Bufferbloat $BufferbloatData)
    }

    $jsonFile = Join-Path $OutDir 'experiment.json'
    $result | ConvertTo-Json -Depth 8 | Out-File $jsonFile -Encoding UTF8
    Log 'Saved experiment.json' 'PASS'

    return $jsonFile
}

function Update-DashboardData {
    <#
    .SYNOPSIS
        Regenerate dashboard data by calling generate_dashboard_data.ps1.
    #>
    param(
        [string]$ScriptRoot,
        [switch]$SkipDashboardUpdate
    )

    if ($SkipDashboardUpdate) { return }

    Log ''
    Log '=== Phase 8: Updating dashboard ==='
    $genScript = Join-Path $ScriptRoot 'generate_dashboard_data.ps1'
    if (Test-Path $genScript) {
        try {
            & $genScript
            Log 'Dashboard data regenerated' 'PASS'
        } catch {
            Log ('Dashboard update failed: ' + $_.Exception.Message) 'WARN'
        }
    }
}
