# helpers/capture-core.ps1
# Core capture functions: WPR, perf counters, GPU, PresentMon, xperf analysis.
# PowerShell 5.1 compatible.

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
        # Support custom .wprp profiles: InputLatency -> scripts/input-latency.wprp
        $profileArg = $WPRProfile + '.' + $WPRDetail
        if ($WPRProfile -eq 'InputLatency') {
            $wprpPath = Join-Path $PSScriptRoot 'input-latency.wprp'
            if (Test-Path $wprpPath) {
                $profileArg = $wprpPath + '!InputLatency.Verbose'
                Log ('Using custom WPR profile: ' + $wprpPath) 'INFO'
            } else {
                Log ('Custom .wprp not found: ' + $wprpPath + ' — falling back to GeneralProfile') 'WARN'
                $profileArg = 'GeneralProfile.' + $WPRDetail
            }
        }
        $wprArgs = @('-start', $profileArg, '-filemode')
        if ($WPRProfile -ne 'CPU' -and $WPRProfile -ne 'InputLatency') {
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

    $samples = Get-Counter -Counter $script:PerfCounters -SampleInterval 1 -MaxSamples $DurationSec

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

function Find-ForegroundGame {
    <#
    .SYNOPSIS
        Detect a running game process by name or memory footprint.
    .OUTPUTS
        [string] Process name, or $null if no game found.
    #>
    foreach ($name in $script:KnownGameProcesses) {
        $proc = Get-Process -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $proc) {
            Log ('Game detected: ' + $proc.ProcessName + ' (PID ' + $proc.Id + ', ' + [math]::Round($proc.WorkingSet64 / 1MB) + ' MB)') 'PASS'
            return $proc.ProcessName
        }
    }
    # Fallback: process using >500MB with game-like name
    $heavy = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.WorkingSet64 -gt 500MB } |
        Where-Object { $_.ProcessName -match 'game|shipping|client|unreal|unity' } |
        Sort-Object WorkingSet64 -Descending |
        Select-Object -First 1
    if ($null -ne $heavy) {
        Log ('Possible game: ' + $heavy.ProcessName + ' (' + [math]::Round($heavy.WorkingSet64 / 1MB) + ' MB)') 'INFO'
        return $heavy.ProcessName
    }
    return $null
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

    $presentMonPath = $script:ToolPaths.PresentMon
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
        [string]$Description,
        [string]$WPRProfile = ''
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
        $xperfPath = $script:ToolPaths.Xperf

        if ($xperfPath -and (Test-Path $xperfPath)) {
            Log 'Running xperf DPC/ISR analysis...'
            $dpcIsrReport = Join-Path $OutDir 'dpcisr_report.txt'
            try {
                & $xperfPath -i $EtlFile -o $dpcIsrReport -a dpcisr 2>&1 | Out-Null
                if (Test-Path $dpcIsrReport) {
                    $reportSize = [math]::Round((Get-Item $dpcIsrReport).Length / 1KB, 1)
                    Log ('xperf DPC/ISR report: ' + $reportSize + ' KB') 'PASS'
                    $dpcIsrData = @{ hasReport = $true; reportFile = 'dpcisr_report.txt' }

                    # Parse per-module DPC histograms
                    # Format: "Total = N for module X.sys" followed by bucket lines
                    # Bucket: "Elapsed Time, > N usecs AND <= M usecs, count, or pct%"
                    $dpcDrivers    = @()
                    $currentModule = ''
                    $currentTotal  = 0
                    $currentMaxUs  = 0
                    $highLatCount  = 0

                    foreach ($rline in (Get-Content $dpcIsrReport)) {
                        if ($rline -match 'Total = (\d+) for module (\S+)') {
                            # Save previous module
                            if ($currentModule -ne '' -and $currentTotal -gt 0) {
                                $dpcDrivers += @{
                                    Module       = $currentModule
                                    Count        = $currentTotal
                                    MaxUs        = $currentMaxUs
                                    HighLatCount = $highLatCount
                                }
                            }
                            $currentModule = $Matches[2]
                            $currentTotal  = [int]$Matches[1]
                            $currentMaxUs  = 0
                            $highLatCount  = 0
                        }
                        if ($rline -match 'Elapsed Time.*<=\s+(\d+) usecs,\s+(\d+),') {
                            $bucket = [int]$Matches[1]
                            $count  = [int]$Matches[2]
                            if ($count -gt 0 -and $bucket -gt $currentMaxUs) {
                                $currentMaxUs = $bucket
                            }
                            if ($bucket -ge 512 -and $count -gt 0) {
                                $highLatCount += $count
                            }
                        }
                    }
                    # Save last module
                    if ($currentModule -ne '' -and $currentTotal -gt 0) {
                        $dpcDrivers += @{
                            Module       = $currentModule
                            Count        = $currentTotal
                            MaxUs        = $currentMaxUs
                            HighLatCount = $highLatCount
                        }
                    }

                    if ($dpcDrivers.Count -gt 0) {
                        $dpcIsrData['dpcDrivers'] = $dpcDrivers | Sort-Object MaxUs -Descending | Select-Object -First 10
                        $topD = ($dpcDrivers | Sort-Object MaxUs -Descending)[0]
                        Log ('Top DPC: ' + $topD.Module + ' max ' + $topD.MaxUs + 'us, ' + $topD.Count + ' calls') 'INFO'
                    }

                    # DPC alerts: flag high-latency drivers
                    $dpcAlerts = @()
                    foreach ($d in $dpcDrivers) {
                        if ($d.Module -eq 'nvlddmkm.sys' -and $d.HighLatCount -gt 0) {
                            $dpcAlerts += @{
                                driver   = 'nvlddmkm.sys'
                                severity = 'HIGH'
                                message  = 'NVIDIA driver DPC spikes >500us (' + $d.HighLatCount + ' occurrences, max bucket ' + $d.MaxUs + 'us)'
                                maxUs    = $d.MaxUs
                                count    = $d.HighLatCount
                            }
                            Log ('ALERT: nvlddmkm.sys ' + $d.HighLatCount + ' DPC calls >500us') 'WARN'
                        }
                        if ($d.Module -match 'EasyAntiCheat|BEService|vgk\.sys') {
                            $dpcAlerts += @{
                                driver   = $d.Module
                                severity = 'INFO'
                                message  = 'Anti-cheat driver in DPC trace: ' + $d.Module + ' (' + $d.Count + ' DPCs, max ' + $d.MaxUs + 'us)'
                                maxUs    = $d.MaxUs
                                count    = $d.Count
                            }
                            Log ('Anti-cheat DPC: ' + $d.Module + ' count=' + $d.Count) 'INFO'
                        }
                    }
                    if ($dpcAlerts.Count -gt 0) {
                        $dpcIsrData['dpcAlerts'] = $dpcAlerts
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
