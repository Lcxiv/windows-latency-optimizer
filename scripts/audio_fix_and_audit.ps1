#Requires -RunAsAdministrator
# Audio Fix + Audit Script
# Fixes MMCSS, checks interrupt affinity, runs DPC/ISR analysis
# Must be run as Administrator

param(
    [switch]$FixMMCSS,
    [switch]$CheckAffinity,
    [switch]$RunCapture,
    [int]$CaptureDurationSec = 10,
    [switch]$All
)

if ($All) {
    $FixMMCSS = $true
    $CheckAffinity = $true
    $RunCapture = $true
}

$ErrorActionPreference = 'Continue'

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  AUDIO FIX + AUDIT" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "  Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# PHASE 1: Check and fix MMCSS
# ============================================================
if ($FixMMCSS) {
    Write-Host "=== PHASE 1: MMCSS AUDIO PRIORITY FIX ===" -ForegroundColor Yellow

    $mmcssPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    $audioPath = $mmcssPath + '\Tasks\Audio'
    $gamePath  = $mmcssPath + '\Tasks\Games'

    # Backup current values
    Write-Host "  [Backup] Current MMCSS values:" -ForegroundColor Gray
    if (Test-Path $audioPath) {
        $current = Get-ItemProperty $audioPath
        Write-Host ("    Audio Priority:      " + $current.Priority)
        Write-Host ("    Audio Scheduling:    " + $current.'Scheduling Category')
        Write-Host ("    Audio SFIO:          " + $current.'SFIO Priority')
        Write-Host ("    Audio Background:    " + $current.'Background Only')
    }

    # Apply fixes
    Write-Host ""
    Write-Host "  [Fix] Applying optimized MMCSS settings..." -ForegroundColor Green

    # System profile
    Set-ItemProperty -Path $mmcssPath -Name 'SystemResponsiveness' -Value 0 -Type DWord
    Write-Host "    SystemResponsiveness -> 0 (minimum system reserve)"

    Set-ItemProperty -Path $mmcssPath -Name 'NetworkThrottlingIndex' -Value 0xFFFFFFFF -Type DWord
    Write-Host "    NetworkThrottlingIndex -> 0xFFFFFFFF (disabled)"

    # Audio task - boost priority
    if (Test-Path $audioPath) {
        Set-ItemProperty -Path $audioPath -Name 'Priority' -Value 1 -Type DWord
        Write-Host "    Audio Priority -> 1 (highest)"

        Set-ItemProperty -Path $audioPath -Name 'Scheduling Category' -Value 'High' -Type String
        Write-Host "    Audio Scheduling -> High"

        Set-ItemProperty -Path $audioPath -Name 'SFIO Priority' -Value 'High' -Type String
        Write-Host "    Audio SFIO -> High"

        Set-ItemProperty -Path $audioPath -Name 'Background Only' -Value 'False' -Type String
        Write-Host "    Audio Background Only -> False"
    }

    # Games task - ensure it doesn't starve audio
    if (Test-Path $gamePath) {
        $gameCurrent = Get-ItemProperty $gamePath
        Write-Host ""
        Write-Host "  [Info] Games task settings:" -ForegroundColor Gray
        Write-Host ("    Games Priority:      " + $gameCurrent.Priority)
        Write-Host ("    Games Scheduling:    " + $gameCurrent.'Scheduling Category')
    }

    Write-Host ""
    Write-Host "  [Verify] New MMCSS values:" -ForegroundColor Green
    $after = Get-ItemProperty $audioPath
    Write-Host ("    Audio Priority:      " + $after.Priority)
    Write-Host ("    Audio Scheduling:    " + $after.'Scheduling Category')
    Write-Host ("    Audio SFIO:          " + $after.'SFIO Priority')
    Write-Host ("    Audio Background:    " + $after.'Background Only')
    Write-Host ""
    Write-Host "  NOTE: Changes take effect immediately for new audio sessions." -ForegroundColor Cyan
    Write-Host "  Restart your audio player/game to pick up the new priority." -ForegroundColor Cyan
    Write-Host ""
}

# ============================================================
# PHASE 2: Check interrupt affinity
# ============================================================
if ($CheckAffinity) {
    Write-Host "=== PHASE 2: INTERRUPT AFFINITY CHECK ===" -ForegroundColor Yellow

    # Check MSI-X / interrupt policy for key devices
    $devices = @(
        @{ Name = 'NVIDIA GPU'; Pattern = '*NVIDIA*GeForce*' },
        @{ Name = 'NVIDIA Audio'; Pattern = '*NVIDIA*Audio*' },
        @{ Name = 'Intel NIC'; Pattern = '*I226*' },
        @{ Name = 'USB Controllers'; Pattern = '*USB*Host*Controller*' },
        @{ Name = 'HD Audio Controller'; Pattern = '*High Definition Audio Controller*' }
    )

    foreach ($dev in $devices) {
        Write-Host ("  --- " + $dev.Name + " ---") -ForegroundColor Cyan

        $pnpDevices = Get-WmiObject Win32_PnPEntity | Where-Object {
            $_.Name -like $dev.Pattern
        }

        if ($pnpDevices) {
            foreach ($pnp in $pnpDevices) {
                Write-Host ("    Device: " + $pnp.Name)
                Write-Host ("    DeviceID: " + $pnp.DeviceID)

                # Check for interrupt policy in registry
                $devId = $pnp.DeviceID -replace '\\', '\\'
                $regPaths = @(
                    "HKLM:\SYSTEM\CurrentControlSet\Enum\" + ($pnp.DeviceID -replace '\\\\', '\') + "\Device Parameters\Interrupt Management\Affinity Policy",
                    "HKLM:\SYSTEM\CurrentControlSet\Enum\" + ($pnp.DeviceID -replace '\\\\', '\') + "\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
                )

                foreach ($rp in $regPaths) {
                    if (Test-Path $rp) {
                        $props = Get-ItemProperty $rp -ErrorAction SilentlyContinue
                        if ($props.DevicePolicy) {
                            Write-Host ("    Affinity Policy: " + $props.DevicePolicy)
                        }
                        if ($props.AssignmentSetOverride) {
                            $mask = [BitConverter]::ToString($props.AssignmentSetOverride)
                            Write-Host ("    Affinity Mask: " + $mask)
                        }
                        if ($null -ne $props.MSISupported) {
                            Write-Host ("    MSI Supported: " + $props.MSISupported)
                        }
                        if ($null -ne $props.MessageNumberLimit) {
                            Write-Host ("    Message Limit: " + $props.MessageNumberLimit)
                        }
                    }
                }
                Write-Host ""
            }
        } else {
            Write-Host "    Not found" -ForegroundColor Gray
            Write-Host ""
        }
    }

    # Also check per-CPU interrupt stats in real-time
    Write-Host "  --- Per-CPU Interrupt Distribution (2s sample) ---" -ForegroundColor Cyan
    $cpuCounters = @()
    for ($i = 0; $i -lt 16; $i++) {
        $cpuCounters += ('\Processor(' + $i + ')\Interrupts/sec')
        $cpuCounters += ('\Processor(' + $i + ')\% Interrupt Time')
        $cpuCounters += ('\Processor(' + $i + ')\% DPC Time')
    }

    try {
        $sample = Get-Counter -Counter $cpuCounters -SampleInterval 2 -MaxSamples 1 -ErrorAction Stop

        Write-Host "  CPU  | Intr/sec  | Intr%   | DPC%    | Notes"
        Write-Host "  -----|-----------|---------|---------|------"

        for ($i = 0; $i -lt 16; $i++) {
            $intrSec = 0; $intrPct = 0; $dpcPct = 0
            foreach ($cs in $sample.CounterSamples) {
                if ($cs.Path -like "*($i)\Interrupts/sec") { $intrSec = [math]::Round($cs.CookedValue, 0) }
                if ($cs.Path -like "*($i)\% Interrupt Time") { $intrPct = [math]::Round($cs.CookedValue, 2) }
                if ($cs.Path -like "*($i)\% DPC Time") { $dpcPct = [math]::Round($cs.CookedValue, 2) }
            }

            $notes = ""
            $total = $intrPct + $dpcPct
            if ($total -gt 10) { $notes = "!!! HIGH" }
            elseif ($total -gt 5) { $notes = "! ELEVATED" }

            $line = "  " + $i.ToString().PadLeft(3) + "  | "
            $line += $intrSec.ToString().PadLeft(8) + "  | "
            $line += ($intrPct.ToString() + "%").PadLeft(7) + " | "
            $line += ($dpcPct.ToString() + "%").PadLeft(7) + " | "
            $line += $notes
            Write-Host $line
        }
    } catch {
        Write-Host ("  Error: " + $_.Exception.Message) -ForegroundColor Red
    }
    Write-Host ""
}

# ============================================================
# PHASE 3: Run DPC/ISR capture with xperf
# ============================================================
if ($RunCapture) {
    Write-Host "=== PHASE 3: DPC/ISR TRACE CAPTURE ===" -ForegroundColor Yellow

    $xperfPath = Get-Command xperf -ErrorAction SilentlyContinue
    if (-not $xperfPath) {
        # Try common locations
        $tryPaths = @(
            "${env:ProgramFiles(x86)}\Windows Kits\10\Windows Performance Toolkit\xperf.exe",
            "$env:ProgramFiles\Windows Kits\10\Windows Performance Toolkit\xperf.exe"
        )
        foreach ($tp in $tryPaths) {
            if (Test-Path $tp) {
                $xperfPath = $tp
                break
            }
        }
    }

    if ($xperfPath) {
        $traceFile = "$env:TEMP\audio_dpc_trace.etl"

        Write-Host "  Starting $CaptureDurationSec-second DPC/ISR trace..." -ForegroundColor Green
        Write-Host "  (Keep your game running during capture for accurate results)" -ForegroundColor Cyan

        # Start trace
        $xperfExe = if ($xperfPath -is [string]) { $xperfPath } else { $xperfPath.Source }
        & $xperfExe -on PROC_THREAD+LOADER+DPC+INTERRUPT+PROFILE -stackwalk Profile -buffersize 1024 -minbuffers 256 -maxbuffers 512 2>&1 | Out-Null

        Write-Host "  Capturing for $CaptureDurationSec seconds..."
        Start-Sleep -Seconds $CaptureDurationSec

        # Stop trace
        & $xperfExe -d $traceFile 2>&1 | Out-Null

        if (Test-Path $traceFile) {
            $sizeMB = [math]::Round((Get-Item $traceFile).Length / 1MB, 1)
            Write-Host "  Trace saved: $traceFile ($sizeMB MB)" -ForegroundColor Green

            # Analyze DPC by module
            Write-Host ""
            Write-Host "  --- Top DPC Contributors (by module) ---" -ForegroundColor Cyan
            $dpcReport = & $xperfExe -i $traceFile -a dpcisr -dpc -summary 2>&1

            $inTable = $false
            $lineCount = 0
            foreach ($line in $dpcReport) {
                if ($line -match 'Module\s+Count') {
                    $inTable = $true
                    Write-Host "  $line"
                    continue
                }
                if ($inTable -and $line.Trim().Length -gt 0) {
                    Write-Host "  $line"
                    $lineCount++
                    if ($lineCount -gt 15) { break }
                }
            }

            # Analyze ISR by module
            Write-Host ""
            Write-Host "  --- Top ISR Contributors (by module) ---" -ForegroundColor Cyan
            $isrReport = & $xperfExe -i $traceFile -a dpcisr -isr -summary 2>&1

            $inTable = $false
            $lineCount = 0
            foreach ($line in $isrReport) {
                if ($line -match 'Module\s+Count') {
                    $inTable = $true
                    Write-Host "  $line"
                    continue
                }
                if ($inTable -and $line.Trim().Length -gt 0) {
                    Write-Host "  $line"
                    $lineCount++
                    if ($lineCount -gt 15) { break }
                }
            }

            Write-Host ""
            Write-Host "  Full trace at: $traceFile" -ForegroundColor Gray
            Write-Host "  Open with WPA for detailed analysis: wpa.exe $traceFile" -ForegroundColor Gray
        } else {
            Write-Host "  Trace file not created - xperf may have failed" -ForegroundColor Red
        }
    } else {
        Write-Host "  xperf not found! Install Windows ADK or use LatencyMon instead." -ForegroundColor Red
        Write-Host "  Falling back to perf counter analysis..." -ForegroundColor Yellow

        # Fallback: longer perf counter capture
        Write-Host ""
        Write-Host "  --- Extended DPC Counter Capture (${CaptureDurationSec}s) ---" -ForegroundColor Cyan

        $cpuCounters = @()
        for ($i = 0; $i -lt 16; $i++) {
            $cpuCounters += ('\Processor(' + $i + ')\% DPC Time')
            $cpuCounters += ('\Processor(' + $i + ')\% Interrupt Time')
        }

        try {
            $allSamples = Get-Counter -Counter $cpuCounters -SampleInterval 1 -MaxSamples $CaptureDurationSec -ErrorAction Stop

            # Aggregate per-CPU
            $cpuStats = @{}
            for ($i = 0; $i -lt 16; $i++) {
                $cpuStats[$i] = @{ DpcSum = 0; IntrSum = 0; Count = 0; DpcMax = 0; IntrMax = 0 }
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
                            $cpuStats[$i].IntrSum += $val
                            if ($val -gt $cpuStats[$i].IntrMax) { $cpuStats[$i].IntrMax = $val }
                        }
                    }
                }
            }

            Write-Host "  CPU  | Avg DPC% | Max DPC% | Avg Intr% | Max Intr% | Total Avg | Flag"
            Write-Host "  -----|----------|----------|-----------|-----------|-----------|-----"

            for ($i = 0; $i -lt 16; $i++) {
                $s = $cpuStats[$i]
                $cnt = $s.Count
                if ($cnt -eq 0) { $cnt = 1 }
                $avgDpc = [math]::Round($s.DpcSum / $cnt, 2)
                $maxDpc = [math]::Round($s.DpcMax, 2)
                $avgIntr = [math]::Round($s.IntrSum / $cnt, 2)
                $maxIntr = [math]::Round($s.IntrMax, 2)
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
                $line += $totalAvg.ToString().PadLeft(8) + "% | "
                $line += $flag
                Write-Host $line
            }
        } catch {
            Write-Host ("  Error: " + $_.Exception.Message) -ForegroundColor Red
        }
    }
    Write-Host ""
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  AUDIT COMPLETE" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
