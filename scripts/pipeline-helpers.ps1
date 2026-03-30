# pipeline-helpers.ps1
# Helper functions for pipeline.ps1 — dot-sourced at runtime.
# Do NOT run this file directly. It is loaded by pipeline.ps1 via:
#   . "$PSScriptRoot\pipeline-helpers.ps1"
#
# All functions here expect $script:logLines to be initialized by the caller.
# PowerShell 5.1 compatible — no ternary, no null-coalescing, no Join-String.

function Log {
    param([string]$msg, [string]$level = 'INFO')
    $ts = Get-Date -Format 'HH:mm:ss'
    $line = '[' + $ts + '] [' + $level + '] ' + $msg
    $script:logLines += $line
    switch ($level) {
        'PASS' { Write-Host $line -ForegroundColor Green }
        'FAIL' { Write-Host $line -ForegroundColor Red }
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'INFO' { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line }
    }
}

function Get-Stats($vals) {
    $m = $vals | Measure-Object -Average -Minimum -Maximum
    # Compute stdev manually (PS 5.1 lacks -StandardDeviation)
    $avg = $m.Average
    $sumSq = 0; foreach ($v in $vals) { $sumSq += ($v - $avg) * ($v - $avg) }
    $sd = [math]::Sqrt($sumSq / [math]::Max(1, $vals.Count - 1))
    return @{
        avg   = [math]::Round($m.Average, 4)
        min   = [math]::Round($m.Minimum, 4)
        max   = [math]::Round($m.Maximum, 4)
        stdev = [math]::Round($sd, 4)
    }
}

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

    return @{
        processName  = $GameProcess
        totalFrames  = $count
        droppedFrames = $dropped
        droppedPct   = [math]::Round($dropped / [math]::Max(1, $count) * 100, 2)
        frameTimeMs  = @{
            avg  = [math]::Round($avg, 2)
            p50  = [math]::Round($p50, 2)
            p95  = [math]::Round($p95, 2)
            p99  = [math]::Round($p99, 2)
            max  = [math]::Round($maxFt, 2)
            min  = [math]::Round($minFt, 2)
        }
        fps = @{
            avg   = [math]::Round($fpsAvg, 1)
            p1Low = [math]::Round($fps1Low, 1)
            min   = [math]::Round(1000.0 / $maxFt, 1)
        }
    }
}

function Test-SystemIdle {
    <#
    .SYNOPSIS
        Check CPU idle state, cancel any stale WPR sessions.
    .OUTPUTS
        [double] CPU average percentage.
    #>
    try {
        $wprStatus = (wpr -status 2>&1) -join ' '
        if ($wprStatus -notmatch 'not recording') {
            Log 'WPR is already recording - cancelling previous session' 'WARN'
            wpr -cancel 2>&1 | Out-Null
            Start-Sleep 2
        }
    } catch { Log ('WPR status check failed: ' + $_.Exception.Message) 'WARN' }

    Log 'Checking system idle state...'
    $cpuCheck = (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 3).CounterSamples |
        Measure-Object CookedValue -Average
    $cpuAvg = [math]::Round($cpuCheck.Average, 1)
    if ($cpuAvg -gt 15) {
        Log ('CPU at ' + $cpuAvg + '% - system may not be idle enough') 'WARN'
        Start-Sleep 5
    } else {
        Log ('CPU at ' + $cpuAvg + '% - idle check passed') 'PASS'
    }
    return $cpuAvg
}

function Start-WprCapture {
    <#
    .SYNOPSIS
        Start a WPR recording session.
    .OUTPUTS
        [bool] Whether WPR was successfully started.
    #>
    param(
        [string]$WPRProfile,
        [string]$WPRDetail
    )
    Log ''
    Log '=== Phase 2: Starting WPR trace ==='
    try {
        $wprArgs = @('-start', ($WPRProfile + '.' + $WPRDetail), '-filemode')
        if ($WPRProfile -ne 'CPU') {
            $wprArgs += @('-start', ('CPU.' + $WPRDetail))
        }
        $wprResult = & wpr @wprArgs 2>&1
        if ($LASTEXITCODE -eq 0) {
            Log 'WPR recording started' 'PASS'
            return $true
        } else {
            Log ('WPR start failed: ' + $wprResult) 'WARN'
            return $false
        }
    } catch {
        Log ('WPR exception: ' + $_.Exception.Message) 'WARN'
        return $false
    }
}

function Invoke-PerfCounterCapture {
    <#
    .SYNOPSIS
        Capture performance counters for the given duration.
    .OUTPUTS
        [hashtable] Keys: counterData, cpuData, cpuInterrupt, cpuDpc, cpuIntrPerSec, perf, samples.
    #>
    param([int]$DurationSec)

    Log ''
    Log ('=== Phase 3: Perf counter capture ' + $DurationSec + 's ===')

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

    $counterData = @{}
    foreach ($sample in $samples) {
        foreach ($cs in $sample.CounterSamples) {
            $key = $cs.Path + '|' + $cs.InstanceName
            if (-not $counterData.ContainsKey($key)) {
                $counterData[$key] = @{ path = $cs.Path; instance = $cs.InstanceName; values = @() }
            }
            $counterData[$key].values += $cs.CookedValue
        }
    }

    $cpuInterrupt  = @{}
    $cpuDpc        = @{}
    $cpuIntrPerSec = @{}
    foreach ($key in $counterData.Keys) {
        $e = $counterData[$key]
        if ($e.path -like '*interrupt time*') { $cpuInterrupt[$e.instance] = Get-Stats $e.values }
        if ($e.path -like '*dpc time*') { $cpuDpc[$e.instance] = Get-Stats $e.values }
        if ($e.path -like '*interrupts/sec*') { $cpuIntrPerSec[$e.instance] = Get-Stats $e.values }
    }

    $cpuData = @()
    $cpuNums = $cpuInterrupt.Keys | Where-Object { $_ -ne '_total' } | Sort-Object { [int]$_ }
    foreach ($cpu in $cpuNums) {
        $dpcVal = 0; if ($cpuDpc.ContainsKey($cpu)) { $dpcVal = $cpuDpc[$cpu].avg }
        $ipsVal = 0; if ($cpuIntrPerSec.ContainsKey($cpu)) { $ipsVal = $cpuIntrPerSec[$cpu].avg }
        $dpcSd  = 0; if ($cpuDpc.ContainsKey($cpu)) { $dpcSd = $cpuDpc[$cpu].stdev }
        $cpuData += @{
            cpu            = [int]$cpu
            interruptPct   = $cpuInterrupt[$cpu].avg
            dpcPct         = $dpcVal
            intrPerSec     = $ipsVal
            interruptStdev = $cpuInterrupt[$cpu].stdev
            dpcStdev       = $dpcSd
        }
    }

    $perf = @{}
    foreach ($key in $counterData.Keys) {
        $e    = $counterData[$key]
        $name = $e.path.TrimStart('\').Split('\') | Select-Object -Last 1
        $inst = $e.instance
        $stats = Get-Stats $e.values
        $mk = $name
        if ($inst) { $mk = $name + '[' + $inst + ']' }
        $perf[$mk] = $stats
    }

    Log ('Perf capture done: ' + $samples.Count + ' samples') 'PASS'

    return @{
        counterData  = $counterData
        cpuData      = $cpuData
        cpuInterrupt = $cpuInterrupt
        cpuDpc       = $cpuDpc
        cpuIntrPerSec = $cpuIntrPerSec
        perf         = $perf
        samples      = $samples
    }
}

function Invoke-PresentMonCapture {
    <#
    .SYNOPSIS
        Start PresentMon frame capture (non-blocking). Returns the process object or $null.
    #>
    param(
        [string]$GameProcess,
        [string]$OutDir,
        [int]$DurationSec,
        [switch]$SkipPresentMon
    )

    $presentMonPath = 'C:\Program Files\NVIDIA Corporation\FrameView\bin\PresentMon_x64.exe'
    if ($SkipPresentMon -or $GameProcess -eq '' -or -not (Test-Path $presentMonPath)) {
        return $null
    }

    Log 'Starting PresentMon frame capture...'
    $pmCsv = Join-Path $OutDir 'frames.csv'
    $pmProc = Start-Process -FilePath $presentMonPath -ArgumentList ('-process_name ' + $GameProcess + ' -output_file ' + $pmCsv + ' -timed ' + $DurationSec + ' -no_top') -PassThru -NoNewWindow -ErrorAction SilentlyContinue
    if ($pmProc) { Log 'PresentMon started' 'PASS' } else { Log 'PresentMon failed to start' 'WARN' }
    return $pmProc
}

function Invoke-GpuCapture {
    <#
    .SYNOPSIS
        Capture GPU utilization counters.
    .OUTPUTS
        [hashtable] GPU engine utilization data, or $null on failure.
    #>
    $gpuUtilData = $null
    try {
        Log 'Capturing GPU utilization...'
        $gpuSamples = Get-Counter '\GPU Engine(*)\Utilization Percentage' -SampleInterval 1 -MaxSamples 5 -ErrorAction Stop
        $gpuEngines = @{}
        foreach ($gs in $gpuSamples) {
            foreach ($cs in $gs.CounterSamples) {
                $engMatch = [regex]::Match($cs.InstanceName, 'engtype_(\w+)')
                if ($engMatch.Success) {
                    $eng = $engMatch.Groups[1].Value
                    if (-not $gpuEngines.ContainsKey($eng)) { $gpuEngines[$eng] = @() }
                    $gpuEngines[$eng] += $cs.CookedValue
                }
            }
        }
        $gpuUtilData = @{}
        foreach ($eng in $gpuEngines.Keys) {
            $vals = $gpuEngines[$eng]
            $gpuUtilData[$eng] = @{
                avg = [math]::Round(($vals | Measure-Object -Average).Average, 2)
                max = [math]::Round(($vals | Measure-Object -Maximum).Maximum, 2)
            }
        }
        if ($gpuUtilData.ContainsKey('3D')) {
            Log ('GPU 3D utilization: ' + $gpuUtilData['3D'].avg + '% avg, ' + $gpuUtilData['3D'].max + '% max') 'PASS'
        }
    } catch {
        Log ('GPU utilization counters not available: ' + $_.Exception.Message) 'WARN'
    }
    return $gpuUtilData
}

function Stop-WprAndAnalyze {
    <#
    .SYNOPSIS
        Stop WPR recording, save ETL, run xperf DPC/ISR + cswitch analysis.
    .OUTPUTS
        [hashtable] DPC/ISR analysis data, or $null.
    #>
    param(
        [string]$EtlFile,
        [string]$OutDir,
        [string]$Description
    )

    $dpcIsrData = $null

    Log ''
    Log '=== Phase 4: Stopping WPR trace ==='
    try {
        $stopResult = wpr -stop $EtlFile $Description 2>&1
        if ($LASTEXITCODE -eq 0) {
            $etlSize = [math]::Round((Get-Item $EtlFile).Length / 1MB, 1)
            Log ('WPR trace saved: trace.etl ' + $etlSize + ' MB') 'PASS'
        } else {
            Log ('WPR stop returned: ' + $stopResult) 'WARN'
        }
    } catch {
        Log ('WPR stop exception: ' + $_.Exception.Message) 'WARN'
    }

    # Extract DPC/ISR via xperf
    if (Test-Path $EtlFile) {
        $xperfPath = 'C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\xperf.exe'

        if (Test-Path $xperfPath) {
            Log 'Running xperf DPC/ISR analysis...'
            $dpcIsrReport = Join-Path $OutDir 'dpcisr_report.txt'
            try {
                & $xperfPath -i $EtlFile -o $dpcIsrReport -a dpcisr 2>&1 | Out-Null
                if (Test-Path $dpcIsrReport) {
                    $reportSize = [math]::Round((Get-Item $dpcIsrReport).Length / 1KB, 1)
                    Log ('xperf DPC/ISR report: ' + $reportSize + ' KB') 'PASS'
                    $dpcIsrData = @{ hasReport = $true; reportFile = 'dpcisr_report.txt' }

                    # Parse DPC summary
                    $dpcDrivers = @()
                    $inDpc = $false
                    foreach ($rline in (Get-Content $dpcIsrReport)) {
                        if ($rline -match 'DPC Module Summary') { $inDpc = $true; continue }
                        if ($rline -match 'ISR Module Summary' -and $inDpc) { $inDpc = $false; continue }
                        if ($rline.Trim() -eq '' -and $inDpc -and $dpcDrivers.Count -gt 0) { $inDpc = $false; continue }
                        if ($inDpc -and $rline -match '(\S+\.sys)\s+(\d+)\s+[\d.]+\s+[\d.]+\s+([\d.]+)') {
                            $dpcDrivers += @{
                                Module = $Matches[1]
                                Count  = [int]$Matches[2]
                                MaxUs  = [double]$Matches[3]
                            }
                        }
                    }
                    if ($dpcDrivers.Count -gt 0) {
                        $dpcIsrData['dpcDrivers'] = $dpcDrivers | Sort-Object MaxUs -Descending | Select-Object -First 10
                        $topD = $dpcDrivers[0]
                        Log ('Top DPC: ' + $topD.Module + ' max ' + $topD.MaxUs + 'us, ' + $topD.Count + ' calls') 'INFO'
                    }

                    # Parse ISR summary
                    $isrDrivers = @()
                    $inIsr = $false
                    foreach ($rline in (Get-Content $dpcIsrReport)) {
                        if ($rline -match 'ISR Module Summary') { $inIsr = $true; continue }
                        if ($rline.Trim() -eq '' -and $inIsr -and $isrDrivers.Count -gt 0) { $inIsr = $false; continue }
                        if ($inIsr -and $rline -match '(\S+\.sys)\s+(\d+)\s+[\d.]+\s+[\d.]+\s+([\d.]+)') {
                            $isrDrivers += @{
                                Module = $Matches[1]
                                Count  = [int]$Matches[2]
                                MaxUs  = [double]$Matches[3]
                            }
                        }
                    }
                    if ($isrDrivers.Count -gt 0) {
                        $dpcIsrData['isrDrivers'] = $isrDrivers | Sort-Object MaxUs -Descending | Select-Object -First 10
                    }

                    # Context switch analysis
                    Log 'Running xperf context switch analysis...'
                    $cswitchReport = Join-Path $OutDir 'cswitch_report.txt'
                    try {
                        & $xperfPath -i $EtlFile -o $cswitchReport -a cswitch 2>&1 | Out-Null
                        if (Test-Path $cswitchReport) {
                            Log 'xperf cswitch report generated' 'PASS'
                            $dpcIsrData['cswitchFile'] = 'cswitch_report.txt'
                        }
                    } catch {
                        Log ('xperf cswitch failed: ' + $_.Exception.Message) 'WARN'
                    }
                } else {
                    Log 'xperf DPC/ISR report not generated' 'WARN'
                }
            } catch {
                Log ('xperf analysis failed: ' + $_.Exception.Message) 'WARN'
            }
        } else {
            Log 'xperf.exe not found - install Windows ADK' 'WARN'
        }
    }

    return $dpcIsrData
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

    $nvKeys = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like 'VEN_10DE*' }
    if ($nvKeys) {
        $nvKey = $nvKeys | Select-Object -First 1
        $msiPath = Join-Path $nvKey.PSPath 'Device Parameters\Interrupt Management\MessageSignaledInterruptProperties'
        if (Test-Path $msiPath) {
            $msi = Get-ItemProperty $msiPath -ErrorAction SilentlyContinue
            $reg['GPU_MSISupported'] = $msi.MSISupported
            $reg['GPU_MessageNumberLimit'] = $msi.MessageNumberLimit
        }
        $reg['GPU_PerfLevelSrc'] = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\NVTweak' -ErrorAction SilentlyContinue).PerfLevelSrc
    }
    $reg['HAGS_HwSchMode'] = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction SilentlyContinue).HwSchMode

    $affinities = @{}
    $devChecks = @(
        @{ Name = 'GPU';      Pattern = 'VEN_10DE' },
        @{ Name = 'NIC';      Pattern = 'VEN_8086&DEV_125C' },
        @{ Name = 'USB_15B6'; Pattern = 'VEN_1022&DEV_15B6' },
        @{ Name = 'USB_15B7'; Pattern = 'VEN_1022&DEV_15B7' },
        @{ Name = 'USB_43F7'; Pattern = 'VEN_1022&DEV_43F7' },
        @{ Name = 'USB_15B8'; Pattern = 'VEN_1022&DEV_15B8' }
    )
    foreach ($dc in $devChecks) {
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

    $cpu0Share = 0; $cpu23Share = 0; $cpu47Share = 0
    $totalIntr = 0
    foreach ($c in $CpuData) { $totalIntr += $c.interruptPct }
    if ($totalIntr -gt 0) {
        $c0val = ($CpuData | Where-Object { $_.cpu -eq 0 }).interruptPct
        $cpu0Share = [math]::Round($c0val / $totalIntr * 100, 1)
        $c23val = 0; foreach ($c in ($CpuData | Where-Object { $_.cpu -in @(2,3) })) { $c23val += $c.interruptPct }
        $cpu23Share = [math]::Round($c23val / $totalIntr * 100, 1)
        $c47val = 0; foreach ($c in ($CpuData | Where-Object { $_.cpu -in @(4,5,6,7) })) { $c47val += $c.interruptPct }
        $cpu47Share = [math]::Round($c47val / $totalIntr * 100, 1)
    }

    $analysis += '--- Interrupt Distribution ---'
    $analysis += 'CPU 0  preferred:    ' + $cpu0Share + '%'
    $analysis += 'CPUs 2-3 input:      ' + $cpu23Share + '%'
    $analysis += 'CPUs 4-7 GPU/NIC:    ' + $cpu47Share + '%'
    $restShare = [math]::Round(100 - $cpu0Share - $cpu23Share - $cpu47Share, 1)
    $analysis += 'CPUs 8-15 game:      ' + $restShare + '%'
    $analysis += ''

    $analysis += '--- Targets ---'
    $totalDpcAvg = 0; if ($CpuDpc.ContainsKey('_total') -and $CpuDpc['_total']) { $totalDpcAvg = $CpuDpc['_total'].avg }
    $totalIntrAvg = 0; if ($CpuInterrupt.ContainsKey('_total') -and $CpuInterrupt['_total']) { $totalIntrAvg = $CpuInterrupt['_total'].avg }

    $chk1 = if ($cpu0Share -lt 10) { 'PASS' } else { 'REVIEW' }
    $chk2 = if ($totalDpcAvg -lt 0.5) { 'PASS' } else { 'REVIEW' }
    $chk3 = if ($totalIntrAvg -lt 1.0) { 'PASS' } else { 'REVIEW' }

    $analysis += '[' + $chk1 + '] CPU 0 share <10%: ' + $cpu0Share + '%'
    $analysis += '[' + $chk2 + '] Total DPC <0.5%: ' + $totalDpcAvg + '%'
    $analysis += '[' + $chk3 + '] Total Interrupt <1.0%: ' + $totalIntrAvg + '%'

    Log ('CPU 0 share: ' + $cpu0Share + '%') $chk1
    Log ('Total DPC: ' + $totalDpcAvg + '%') $chk2
    Log ('Total Interrupt: ' + $totalIntrAvg + '%') $chk3

    $analysis += ''
    $analysis += '--- Per-CPU ---'
    foreach ($c in ($CpuData | Sort-Object cpu)) {
        $role = ''
        switch ($c.cpu) { 0 { $role = ' <-preferred' }; 2 { $role = ' <-input' }; 3 { $role = ' <-input' }; 4 { $role = ' <-GPU/NIC' }; 5 { $role = ' <-GPU/NIC' }; 6 { $role = ' <-GPU/NIC' }; 7 { $role = ' <-GPU/NIC' } }
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

    if ($WprStarted -and (Test-Path $EtlFile)) {
        $analysis += ''
        $analysis += 'For deeper analysis open trace.etl in WPA'
    }

    return @{
        analysisLines = $analysis
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
        [double]$Cpu0Share,
        [double]$Cpu23Share,
        [double]$Cpu47Share,
        $DpcIsrData,
        $FrameTimingData,
        $GpuUtilData
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
        $dpcIsrJson = @{ source = $src; dpcDrivers = $dpcD; isrDrivers = $isrD }
    }

    $result = [ordered]@{
        schemaVersion     = 3
        label             = $Label
        description       = $Description
        capturedAt        = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        durationSec       = $DurationSec
        hostname          = $env:COMPUTERNAME
        wprProfile        = $wprProf
        wprEtlFile        = $wprEtl
        registry          = $Registry
        performance       = $Perf
        cpuData           = $CpuData
        cpuTotal          = @{ interruptPct = $CpuInterrupt['_total'].avg; dpcPct = $CpuDpc['_total'].avg; intrPerSec = $CpuIntrPerSec['_total'].avg }
        interruptTopology = @{ cpu0Share = $Cpu0Share; cpu23Share = $Cpu23Share; cpu47Share = $Cpu47Share }
        dpcIsrAnalysis    = $dpcIsrJson
        analysisFile      = 'analysis.txt'
        frameTiming       = $FrameTimingData
        gpuUtilization    = $GpuUtilData
        cswitchAnalysis   = $null
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
