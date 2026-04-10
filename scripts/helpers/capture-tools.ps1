# helpers/capture-tools.ps1
# Optional tool integrations: ProcMon, PktMon, Defender recording.
# PowerShell 5.1 compatible.

function Invoke-ProcMonCapture {
    <#
    .SYNOPSIS
        Start ProcMon automated capture (non-blocking). Returns backing file path or $null.
    .DESCRIPTION
        Launches Procmon64.exe with /BackingFile, /Runtime, /Quiet, /Minimized.
        After capture completes, converts PML to CSV for analysis.
    #>
    param(
        [string]$OutDir,
        [int]$DurationSec,
        [switch]$SkipProcMon
    )

    if ($SkipProcMon) { return $null }

    $procmonPath = $script:ToolPaths.ProcMon
    if (-not $procmonPath -or -not (Test-Path $procmonPath)) {
        Log 'Procmon64.exe not found — skipping ProcMon capture' 'INFO'
        return $null
    }

    # Terminate any existing ProcMon instance
    & $procmonPath /AcceptEula /Terminate 2>&1 | Out-Null
    Start-Sleep -Seconds 1

    $pmlFile = Join-Path $OutDir 'procmon_capture.pml'
    Log 'Starting ProcMon capture...'

    try {
        # Use gaming config with Duration column if available
        $pmcFile = Join-Path $PSScriptRoot 'procmon_gaming.pmc'
        $pmArgs = '/AcceptEula /BackingFile "' + $pmlFile + '" /Runtime ' + $DurationSec + ' /Quiet /Minimized'
        if (Test-Path $pmcFile) {
            $pmArgs = '/AcceptEula /LoadConfig "' + $pmcFile + '" /BackingFile "' + $pmlFile + '" /Runtime ' + $DurationSec + ' /Quiet /Minimized'
            Log 'Using procmon_gaming.pmc (Duration column enabled)' 'INFO'
        }
        Start-Process -FilePath $procmonPath -ArgumentList $pmArgs -NoNewWindow -ErrorAction Stop
        Log ('ProcMon started: ' + $DurationSec + 's capture to ' + $pmlFile) 'PASS'
        return $pmlFile
    } catch {
        Log ('ProcMon failed to start: ' + $_.Exception.Message) 'WARN'
        return $null
    }
}

function Convert-ProcMonToCSV {
    <#
    .SYNOPSIS
        Convert ProcMon PML file to CSV after capture completes.
    .OUTPUTS
        [string] CSV file path, or $null if conversion failed.
    #>
    param(
        [string]$PmlFile,
        [string]$OutDir
    )

    if (-not (Test-Path $PmlFile)) { return $null }

    $procmonPath = $script:ToolPaths.ProcMon
    if (-not $procmonPath -or -not (Test-Path $procmonPath)) { return $null }

    $csvFile = Join-Path $OutDir 'procmon_capture.csv'
    Log 'Converting ProcMon PML to CSV...'

    try {
        & $procmonPath /AcceptEula /OpenLog $PmlFile /SaveAs $csvFile /SaveApplyFilter 2>&1 | Out-Null
        # ProcMon opens a GUI briefly during conversion — wait for it to close
        $waited = 0
        while ($waited -lt 30) {
            Start-Sleep -Seconds 2
            $waited += 2
            if (Test-Path $csvFile) {
                $csvSize = (Get-Item $csvFile).Length
                if ($csvSize -gt 100) {
                    # Wait a bit more for file to finish writing
                    Start-Sleep -Seconds 2
                    break
                }
            }
        }
        # Terminate ProcMon GUI
        & $procmonPath /Terminate 2>&1 | Out-Null

        if (Test-Path $csvFile) {
            $csvSizeMB = [math]::Round((Get-Item $csvFile).Length / 1MB, 1)
            Log ('ProcMon CSV: ' + $csvSizeMB + ' MB') 'PASS'
            return $csvFile
        } else {
            Log 'ProcMon CSV conversion failed' 'WARN'
            return $null
        }
    } catch {
        Log ('ProcMon conversion error: ' + $_.Exception.Message) 'WARN'
        return $null
    }
}

function Analyze-ProcMonCSV {
    <#
    .SYNOPSIS
        Analyze ProcMon CSV for latency-relevant activity.
    .DESCRIPTION
        Extracts: top processes by event count, high-duration operations (>1ms),
        file I/O hotspots, registry access patterns, and Defender/anti-cheat activity.
    .OUTPUTS
        [hashtable] with topProcesses, highDuration, defenderActivity, antiCheatActivity, ioHotspots
    #>
    param(
        [string]$CsvPath
    )

    if (-not (Test-Path $CsvPath)) { return $null }

    Log 'Analyzing ProcMon CSV...'
    $csv = @(Import-Csv $CsvPath -ErrorAction SilentlyContinue)
    if ($csv.Count -eq 0) { Log 'ProcMon CSV empty' 'WARN'; return $null }

    $total = $csv.Count
    Log ('  Total events: ' + $total) 'INFO'

    # Top processes by event count
    $topProcs = @($csv | Group-Object 'Process Name' |
        Sort-Object Count -Descending |
        Select-Object -First 15 |
        ForEach-Object {
            @{
                process = $_.Name
                count   = $_.Count
                pct     = [math]::Round($_.Count / $total * 100, 1)
            }
        })

    # High-duration operations (>1ms = potential stall)
    $highDuration = @()
    foreach ($row in $csv) {
        $durStr = $row.Duration
        if ($null -eq $durStr -or $durStr -eq '') { continue }
        $dur = 0
        try { $dur = [double]$durStr } catch { continue }
        if ($dur -gt 0.001) {
            $highDuration += @{
                time      = $row.'Time of Day'
                process   = $row.'Process Name'
                pid       = $row.PID
                operation = $row.Operation
                path      = $row.Path
                duration  = [math]::Round($dur * 1000, 2)
                result    = $row.Result
            }
        }
    }
    $highDuration = @($highDuration | Sort-Object { $_.duration } -Descending | Select-Object -First 50)
    Log ('  High-duration ops (>1ms): ' + $highDuration.Count) 'INFO'

    # Defender activity
    $defenderEvents = @($csv | Where-Object { $_.'Process Name' -eq 'MsMpEng.exe' })
    $defenderOps = @()
    if ($defenderEvents.Count -gt 0) {
        $defenderOps = @($defenderEvents | Group-Object Operation |
            Sort-Object Count -Descending |
            Select-Object -First 5 |
            ForEach-Object { @{ operation = $_.Name; count = $_.Count } })
    }

    # Anti-cheat activity
    $acPatterns  = @('EasyAntiCheat', 'BEService', 'vgc', 'vgk', 'EAC')
    $acEvents    = @($csv | Where-Object {
        $pname = $_.'Process Name'
        $match = $false
        foreach ($pat in $acPatterns) { if ($pname -like ('*' + $pat + '*')) { $match = $true; break } }
        $match
    })
    $acSummary = @()
    if ($acEvents.Count -gt 0) {
        $acSummary = @($acEvents | Group-Object 'Process Name' |
            Sort-Object Count -Descending |
            ForEach-Object { @{ process = $_.Name; count = $_.Count } })
    }

    # I/O hotspot directories
    $ioHotspots = @($csv | Where-Object { $_.Path -match '\\' -and ($_.Operation -match 'Read|Write|Create') } |
        ForEach-Object {
            $parts = $_.Path -split '\\'
            $dirEnd = [math]::Min(4, $parts.Count)
            $parts[0..($dirEnd - 1)] -join '\'
        } |
        Group-Object |
        Sort-Object Count -Descending |
        Select-Object -First 10 |
        ForEach-Object { @{ directory = $_.Name; count = $_.Count } })

    $result = @{
        totalEvents     = $total
        topProcesses    = $topProcs
        highDuration    = $highDuration
        defenderCount   = $defenderEvents.Count
        defenderOps     = $defenderOps
        antiCheatCount  = $acEvents.Count
        antiCheatDetail = $acSummary
        ioHotspots      = $ioHotspots
    }

    if ($highDuration.Count -gt 0) {
        $topOp = $highDuration[0]
        Log ('  Slowest op: ' + $topOp.process + ' ' + $topOp.operation + ' ' + $topOp.duration + 'ms') 'INFO'
    }

    return $result
}

function Start-PktMonCapture {
    <#
    .SYNOPSIS
        Start pktmon packet capture (built-in Windows 11, zero-install, <0.3% CPU).
    .OUTPUTS
        [string] ETL file path, or $null if failed.
    #>
    param(
        [string]$OutDir,
        [switch]$SkipPktMon
    )

    if ($SkipPktMon) { return $null }

    # Check pktmon is available
    $pktmon = Get-Command pktmon.exe -ErrorAction SilentlyContinue
    if ($null -eq $pktmon) {
        Log 'pktmon.exe not found (requires Windows 10 2004+)' 'INFO'
        return $null
    }

    # Stop any existing capture (ignore errors if not running)
    try { pktmon stop 2>&1 | Out-Null } catch {}

    $etlFile = Join-Path $OutDir 'pktmon_capture.etl'
    Log 'Starting pktmon network capture...'

    try {
        # Capture on all NICs, full packets, to ETL file
        $startResult = pktmon start -c --comp nics --pkt-size 128 --file-name $etlFile 2>&1
        if ($LASTEXITCODE -eq 0) {
            Log 'pktmon capture started' 'PASS'
            return $etlFile
        } else {
            Log ('pktmon start failed: ' + $startResult) 'WARN'
            return $null
        }
    } catch {
        Log ('pktmon exception: ' + $_.Exception.Message) 'WARN'
        return $null
    }
}

function Stop-PktMonCapture {
    <#
    .SYNOPSIS
        Stop pktmon capture and convert to pcapng if possible.
    .OUTPUTS
        [string] pcapng file path, or ETL path, or $null.
    #>
    param(
        [string]$EtlFile,
        [string]$OutDir
    )

    if ($null -eq $EtlFile -or -not (Test-Path $EtlFile)) { return $null }

    Log 'Stopping pktmon capture...'
    pktmon stop 2>&1 | Out-Null

    $etlSize = [math]::Round((Get-Item $EtlFile).Length / 1MB, 1)
    Log ('pktmon ETL: ' + $etlSize + ' MB') 'PASS'

    # Convert to pcapng for tshark/Wireshark analysis
    $pcapFile = Join-Path $OutDir 'pktmon_capture.pcapng'
    try {
        pktmon etl2pcap $EtlFile -o $pcapFile 2>&1 | Out-Null
        if (Test-Path $pcapFile) {
            $pcapSize = [math]::Round((Get-Item $pcapFile).Length / 1MB, 1)
            Log ('pktmon pcapng: ' + $pcapSize + ' MB') 'PASS'
            return $pcapFile
        }
    } catch {
        Log 'pktmon etl2pcap conversion failed' 'WARN'
    }

    return $EtlFile
}

function Analyze-PktMonCapture {
    <#
    .SYNOPSIS
        Analyze pktmon counters and optionally parse pcapng with tshark.
    .OUTPUTS
        [hashtable] with packetCount, etlSizeMB, tsharkAvailable, and optionally conversations/stats.
    #>
    param(
        [string]$CaptureFile,
        [string]$OutDir
    )

    if ($null -eq $CaptureFile) { return $null }

    $result = @{
        captureFile    = (Split-Path $CaptureFile -Leaf)
        captureType    = 'pktmon'
        tsharkAvailable = $false
        conversations  = @()
        stats          = @{}
    }

    if (Test-Path $CaptureFile) {
        $result['sizeMB'] = [math]::Round((Get-Item $CaptureFile).Length / 1MB, 1)
    }

    # Check for pktmon counters
    try {
        $counters = pktmon counters 2>&1 | Out-String
        if ($counters -match 'Packets:\s+(\d+)') {
            $result['packetCount'] = [int]$Matches[1]
            Log ('pktmon packets captured: ' + $Matches[1]) 'INFO'
        }
    } catch {}

    # Check if tshark is available for deeper analysis
    $tshark = Get-Command tshark.exe -ErrorAction SilentlyContinue
    if ($null -ne $tshark -and $CaptureFile -like '*.pcapng') {
        $result['tsharkAvailable'] = $true
        Log 'tshark found — running network analysis...' 'INFO'

        # TCP conversation stats (RTT, retransmissions)
        try {
            $convOutput = & tshark.exe -r $CaptureFile -q -z conv,tcp 2>&1 | Out-String
            $convLines = @()
            foreach ($line in ($convOutput -split "`n")) {
                if ($line -match '(\d+\.\d+\.\d+\.\d+):(\d+)\s+<->\s+(\d+\.\d+\.\d+\.\d+):(\d+)\s+(\d+)\s+(\d+)') {
                    $convLines += @{
                        srcIP   = $Matches[1]
                        srcPort = $Matches[2]
                        dstIP   = $Matches[3]
                        dstPort = $Matches[4]
                        frames  = [int]$Matches[5]
                        bytes   = [int]$Matches[6]
                    }
                }
            }
            $result['conversations'] = @($convLines | Sort-Object { $_.frames } -Descending | Select-Object -First 10)
        } catch {
            Log ('tshark conv analysis failed: ' + $_.Exception.Message) 'WARN'
        }

        # Retransmission count
        try {
            $retransOutput = & tshark.exe -r $CaptureFile -Y 'tcp.analysis.retransmission' -T fields -e frame.number 2>&1
            $retransCount = @($retransOutput | Where-Object { $_ -match '^\d+$' }).Count
            $result['retransmissions'] = $retransCount
            Log ('TCP retransmissions: ' + $retransCount) 'INFO'
        } catch {}

        # DNS slow queries
        try {
            $dnsOutput = & tshark.exe -r $CaptureFile -Y 'dns.time > 0.1' -T fields -e dns.qry.name -e dns.time 2>&1
            $dnsLines = @()
            foreach ($line in ($dnsOutput -split "`n")) {
                $parts = $line -split "`t"
                if ($parts.Count -ge 2) {
                    $dnsLines += @{ query = $parts[0]; timeMs = [math]::Round([double]$parts[1] * 1000, 1) }
                }
            }
            $result['slowDnsQueries'] = @($dnsLines | Select-Object -First 10)
            if ($dnsLines.Count -gt 0) { Log ('Slow DNS queries (>100ms): ' + $dnsLines.Count) 'WARN' }
        } catch {}
    } else {
        Log 'tshark not found — basic pktmon counters only. Install Wireshark for deep network analysis.' 'INFO'
    }

    return $result
}

function Start-DefenderRecording {
    <#
    .SYNOPSIS
        Start a Defender performance recording (New-MpPerformanceRecording).
        Runs as a background job so it doesn't block the pipeline.
    .OUTPUTS
        [hashtable] with job and etlPath, or $null if failed.
    #>
    param(
        [string]$OutDir,
        [switch]$SkipDefenderRecording
    )

    if ($SkipDefenderRecording) { return $null }

    # Check if cmdlet exists
    $cmd = Get-Command New-MpPerformanceRecording -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        Log 'New-MpPerformanceRecording not available (requires Defender platform 4.18.2108+)' 'INFO'
        return $null
    }

    $defEtl = Join-Path $OutDir 'defender_perf.etl'
    Log 'Starting Defender performance recording...'

    try {
        # Cancel any existing WPR recording from Defender (uses its own WPR instance)
        wpr -cancel -instancename MSFT_MpPerformanceRecording 2>&1 | Out-Null

        $job = Start-Job -ScriptBlock {
            param($etlPath)
            New-MpPerformanceRecording -RecordTo $etlPath
        } -ArgumentList $defEtl
        Log 'Defender recording started (background job)' 'PASS'
        return @{ job = $job; etlPath = $defEtl }
    } catch {
        Log ('Defender recording failed: ' + $_.Exception.Message) 'WARN'
        return $null
    }
}

function Stop-DefenderRecording {
    <#
    .SYNOPSIS
        Stop a Defender performance recording and analyze results.
    .OUTPUTS
        [hashtable] with topFiles, topProcesses, topExtensions, or $null.
    #>
    param(
        $RecordingInfo,
        [string]$OutDir
    )

    if ($null -eq $RecordingInfo) { return $null }

    Log 'Stopping Defender performance recording...'

    try {
        # The job is waiting for Enter key — stop it
        Stop-Job $RecordingInfo.job -ErrorAction SilentlyContinue
        Remove-Job $RecordingInfo.job -Force -ErrorAction SilentlyContinue
    } catch {}

    # Wait briefly for ETL to be written
    Start-Sleep -Seconds 2

    if (-not (Test-Path $RecordingInfo.etlPath)) {
        Log 'Defender ETL not generated' 'WARN'
        return $null
    }

    $etlSize = [math]::Round((Get-Item $RecordingInfo.etlPath).Length / 1MB, 1)
    Log ('Defender ETL: ' + $etlSize + ' MB') 'PASS'

    # Analyze
    $result = @{
        etlFile       = 'defender_perf.etl'
        etlSizeMB     = $etlSize
        topFiles      = @()
        topProcesses  = @()
        topExtensions = @()
    }

    try {
        $report = Get-MpPerformanceReport -Path $RecordingInfo.etlPath -TopFiles 10 -TopProcesses 5 -TopExtensions 5 -ErrorAction Stop

        if ($null -ne $report.TopFiles) {
            $result.topFiles = @($report.TopFiles | Select-Object -First 10 | ForEach-Object {
                @{ path = $_.Path; count = $_.Count; totalDurationMs = [math]::Round($_.Duration.TotalMilliseconds, 1) }
            })
        }
        if ($null -ne $report.TopProcesses) {
            $result.topProcesses = @($report.TopProcesses | Select-Object -First 5 | ForEach-Object {
                @{ process = $_.Process; count = $_.Count; totalDurationMs = [math]::Round($_.Duration.TotalMilliseconds, 1) }
            })
        }
        if ($null -ne $report.TopExtensions) {
            $result.topExtensions = @($report.TopExtensions | Select-Object -First 5 | ForEach-Object {
                @{ extension = $_.Extension; count = $_.Count; totalDurationMs = [math]::Round($_.Duration.TotalMilliseconds, 1) }
            })
        }

        Log ('Defender top file scans: ' + $result.topFiles.Count) 'INFO'
    } catch {
        Log ('Defender report analysis failed: ' + $_.Exception.Message) 'WARN'
    }

    return $result
}
