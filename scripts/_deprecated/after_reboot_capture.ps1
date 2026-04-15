#Requires -RunAsAdministrator
# After-Reboot Capture: Affinity applied, Razer status checked
# Compare against before_reboot_capture results

$outDir = "C:\Users\L\Desktop\windows-latency-optimizer\captures"
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$resultFile = "$outDir\after_reboot_capture_$timestamp.txt"

Write-Output "============================================"
Write-Output "  AFTER-REBOOT CAPTURE"
Write-Output "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Output "  State: Affinity APPLIED, post-reboot"
Write-Output "============================================"
Write-Output ""

# 1. Verify affinity is applied
Write-Output "=== AFFINITY VERIFICATION ==="
$gpu = Get-WmiObject Win32_PnPEntity | Where-Object { $_.Name -match 'NVIDIA GeForce' } | Select-Object -First 1
if ($gpu) {
    $devId = $gpu.DeviceID -replace '\\', '\\'
    $regPaths = @(
        "HKLM:\SYSTEM\CurrentControlSet\Enum\$($gpu.DeviceID)\Device Parameters\Interrupt Management\Affinity Policy"
    )
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\" + $gpu.DeviceID + "\Device Parameters\Interrupt Management\Affinity Policy"
    if (Test-Path $regPath) {
        $policy = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).DevicePolicy
        $mask = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).AssignmentSetOverride
        if ($mask) {
            $maskHex = '0x' + [System.BitConverter]::ToString($mask).Replace('-','')
            Write-Output "  GPU Affinity: Policy=$policy, Mask=$maskHex"
            Write-Output "  STATUS: AFFINITY IS SET"
        } else {
            Write-Output "  GPU Affinity: Policy=$policy, Mask=NOT SET"
            Write-Output "  WARNING: Affinity mask missing!"
        }
    } else {
        Write-Output "  GPU Affinity: Registry path not found"
        Write-Output "  WARNING: Affinity not configured!"
    }
} else {
    Write-Output "  GPU not found via WMI"
}
Write-Output ""

# 2. Razer status
Write-Output "=== RAZER STATUS ==="
$razerProcs = Get-Process | Where-Object { $_.ProcessName -match 'Razer|Synapse|rzdevice|GameManager' }
if ($razerProcs) {
    $razerCount = ($razerProcs | Measure-Object).Count
    Write-Output "  Razer processes: $razerCount RUNNING"
    foreach ($p in $razerProcs) {
        Write-Output "    $($p.ProcessName) (PID: $($p.Id))"
    }
} else {
    Write-Output "  All Razer processes: DEAD"
}
Write-Output ""

# 3. GPU status
Write-Output "=== GPU STATUS ==="
$nvOut = & nvidia-smi --query-gpu=driver_version,name,temperature.gpu,power.draw,clocks.current.graphics,clocks.current.memory,utilization.gpu --format=csv 2>&1
$nvOut | ForEach-Object { Write-Output "  $_" }
Write-Output ""

# 4. Extended per-CPU counter capture (10 seconds)
Write-Output "=== PER-CPU DPC/INTERRUPT CAPTURE (10 seconds) ==="
Write-Output "  Keep your game running for accurate results..."

$cpuCounters = @()
for ($i = 0; $i -lt 16; $i++) {
    $cpuCounters += ('\Processor(' + $i + ')\% DPC Time')
    $cpuCounters += ('\Processor(' + $i + ')\% Interrupt Time')
    $cpuCounters += ('\Processor(' + $i + ')\Interrupts/sec')
}

try {
    $allSamples = Get-Counter -Counter $cpuCounters -SampleInterval 1 -MaxSamples 10 -ErrorAction Stop

    $cpuStats = @{}
    for ($i = 0; $i -lt 16; $i++) {
        $cpuStats[$i] = @{
            DpcSum = 0; IntrPctSum = 0; IntrSecSum = 0; Count = 0
            DpcMax = 0; IntrPctMax = 0; IntrSecMax = 0
        }
    }

    foreach ($sample in $allSamples) {
        for ($i = 0; $i -lt 16; $i++) {
            foreach ($cs in $sample.CounterSamples) {
                if ($cs.Path -like "*($i)\% DPC Time") {
                    $val = $cs.CookedValue
                    $cpuStats[$i].DpcSum += $val
                    $cpuStats[$i].Count++
                    if ($val -gt $cpuStats[$i].DpcMax) { $cpuStats[$i].DpcMax = $val }
                }
                if ($cs.Path -like "*($i)\% Interrupt Time") {
                    $val = $cs.CookedValue
                    $cpuStats[$i].IntrPctSum += $val
                    if ($val -gt $cpuStats[$i].IntrPctMax) { $cpuStats[$i].IntrPctMax = $val }
                }
                if ($cs.Path -like "*($i)\Interrupts/sec") {
                    $val = $cs.CookedValue
                    $cpuStats[$i].IntrSecSum += $val
                    if ($val -gt $cpuStats[$i].IntrSecMax) { $cpuStats[$i].IntrSecMax = $val }
                }
            }
        }
    }

    Write-Output ""
    Write-Output "  CPU  | Avg DPC% | Max DPC% | Avg Intr% | Max Intr% | Avg Intr/s | Total Avg% | Flag"
    Write-Output "  -----|----------|----------|-----------|-----------|------------|------------|------"

    for ($i = 0; $i -lt 16; $i++) {
        $s = $cpuStats[$i]
        $cnt = $s.Count
        if ($cnt -eq 0) { $cnt = 1 }
        $avgDpc = [math]::Round($s.DpcSum / $cnt, 2)
        $maxDpc = [math]::Round($s.DpcMax, 2)
        $avgIntr = [math]::Round($s.IntrPctSum / $cnt, 2)
        $maxIntr = [math]::Round($s.IntrPctMax, 2)
        $avgIntrSec = [math]::Round($s.IntrSecSum / $cnt, 0)
        $totalAvg = [math]::Round($avgDpc + $avgIntr, 2)

        $flag = ""
        if ($totalAvg -gt 10) { $flag = "!!! HIGH" }
        elseif ($totalAvg -gt 5) { $flag = "! ELEVATED" }
        elseif ($maxDpc -gt 20 -or $maxIntr -gt 20) { $flag = "! SPIKE" }

        $line = "  " + $i.ToString().PadLeft(3) + "  | "
        $line += $avgDpc.ToString().PadLeft(7) + "% | "
        $line += $maxDpc.ToString().PadLeft(7) + "% | "
        $line += $avgIntr.ToString().PadLeft(8) + "% | "
        $line += $maxIntr.ToString().PadLeft(8) + "% | "
        $line += $avgIntrSec.ToString().PadLeft(9) + "  | "
        $line += $totalAvg.ToString().PadLeft(9) + "% | "
        $line += $flag
        Write-Output $line
    }
} catch {
    Write-Output "  Error: $($_.Exception.Message)"
}
Write-Output ""

# 5. xperf DPC/ISR trace
Write-Output "=== XPERF DPC/ISR TRACE (10 seconds) ==="

$xperf = $null
$tryPaths = @(
    "${env:ProgramFiles(x86)}\Windows Kits\10\Windows Performance Toolkit\xperf.exe",
    "$env:ProgramFiles\Windows Kits\10\Windows Performance Toolkit\xperf.exe"
)
foreach ($tp in $tryPaths) {
    if (Test-Path $tp) { $xperf = $tp; break }
}
if (-not $xperf) {
    $cmd = Get-Command xperf -ErrorAction SilentlyContinue
    if ($cmd) { $xperf = $cmd.Source }
}

if ($xperf) {
    $traceFile = "$outDir\after_reboot_trace_$timestamp.etl"

    Write-Output "  Starting 10-second trace..."
    & $xperf -on PROC_THREAD+LOADER+DPC+INTERRUPT+PROFILE -stackwalk Profile -buffersize 1024 -minbuffers 256 -maxbuffers 512 2>&1 | Out-Null
    Start-Sleep -Seconds 10
    & $xperf -d $traceFile 2>&1 | Out-Null

    if (Test-Path $traceFile) {
        $sizeMB = [math]::Round((Get-Item $traceFile).Length / 1MB, 1)
        Write-Output "  Trace saved: $traceFile ($sizeMB MB)"

        Write-Output ""
        Write-Output "  --- DPC CPU Usage by Module ---"
        $dpcOut = & $xperf -i $traceFile -a dpcisr 2>&1
        $inUsage = $false
        $lineCount = 0
        foreach ($line in $dpcOut) {
            if ($line -match 'usec\s+%.*Module') {
                $inUsage = $true
                Write-Output "  $line"
                continue
            }
            if ($inUsage) {
                if ($line.Trim().Length -eq 0) { break }
                Write-Output "  $line"
                $lineCount++
            }
        }

        Write-Output ""
        Write-Output "  --- ISR CPU Usage by Module ---"
        $inIsr = $false
        $pastDpc = $false
        $lineCount = 0
        foreach ($line in $dpcOut) {
            if ($line -match 'Interrupt Info') { $pastDpc = $true; continue }
            if ($pastDpc -and $line -match 'usec\s+%.*Module') {
                $inIsr = $true
                Write-Output "  $line"
                continue
            }
            if ($inIsr) {
                if ($line.Trim().Length -eq 0) { break }
                Write-Output "  $line"
                $lineCount++
            }
        }
    } else {
        Write-Output "  Trace file not created!"
    }
} else {
    Write-Output "  xperf not available"
}

# 6. Quick comparison summary
Write-Output ""
Write-Output "=== COMPARISON NOTES ==="
Write-Output "  Before-reboot baseline: captures\before_reboot_results.txt"
Write-Output "  Key metric: CPU 0 Total Avg% (was 17.49% with !!! HIGH flag)"
Write-Output "  Goal: CPU 0 should be < 3% with GPU load on CPUs 4-7"

Write-Output ""
Write-Output "============================================"
Write-Output "  CAPTURE COMPLETE"
Write-Output "  Results: $resultFile"
Write-Output "============================================"
