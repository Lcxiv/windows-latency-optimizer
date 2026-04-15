# Audio Diagnostic Script - Quick system scan for sound glitch causes
# Run as: powershell -ExecutionPolicy Bypass -File audio_diag.ps1

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  AUDIO DIAGNOSTIC SCAN" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# 1. Audio drivers
Write-Host "=== AUDIO DRIVERS ===" -ForegroundColor Yellow
Get-WmiObject Win32_PnPSignedDriver | Where-Object {
    $_.DeviceName -like '*Audio*' -or $_.DeviceName -like '*Sound*'
} | ForEach-Object {
    Write-Host ("  Device:  " + $_.DeviceName)
    Write-Host ("  Driver:  " + $_.DriverVersion)
    Write-Host ("  Date:    " + $_.DriverDate)
    Write-Host ("  Status:  " + $_.Status)
    Write-Host ""
}

# 2. Sound devices
Write-Host "=== SOUND DEVICES ===" -ForegroundColor Yellow
Get-WmiObject Win32_SoundDevice | ForEach-Object {
    Write-Host ("  Name:   " + $_.Name)
    Write-Host ("  Status: " + $_.Status)
    Write-Host ""
}

# 3. NVIDIA GPU status
Write-Host "=== NVIDIA GPU ===" -ForegroundColor Yellow
$nvSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($nvSmi) {
    $nvResult = & nvidia-smi --query-gpu=driver_version,name,temperature.gpu,power.draw,clocks.current.graphics,clocks.current.memory,utilization.gpu --format=csv 2>&1
    $nvResult | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host "  nvidia-smi not found in PATH"
}
Write-Host ""

# 4. MMCSS Settings
Write-Host "=== MMCSS (Multimedia Scheduler) ===" -ForegroundColor Yellow
$mmcssPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
if (Test-Path $mmcssPath) {
    $mmcss = Get-ItemProperty $mmcssPath
    Write-Host ("  SystemResponsiveness:   " + $mmcss.SystemResponsiveness)
    Write-Host ("  NetworkThrottlingIndex: " + $mmcss.NetworkThrottlingIndex)
    Write-Host ("  NoLazyMode:            " + $mmcss.NoLazyMode)
}
$audioTask = $mmcssPath + '\Tasks\Audio'
if (Test-Path $audioTask) {
    $at = Get-ItemProperty $audioTask
    Write-Host ("  Audio Priority:         " + $at.Priority)
    Write-Host ("  Audio Scheduling:       " + $at.'Scheduling Category')
    Write-Host ("  Audio SFIO Priority:    " + $at.'SFIO Priority')
}
Write-Host ""

# 5. Audio services
Write-Host "=== AUDIO SERVICES ===" -ForegroundColor Yellow
Get-Service -Name 'Audiosrv','AudioEndpointBuilder' | ForEach-Object {
    Write-Host ("  " + $_.Name + ": " + $_.Status + " (" + $_.StartType + ")")
}
Write-Host ""

# 6. Known DPC offenders
Write-Host "=== KNOWN DPC LATENCY OFFENDERS (Running) ===" -ForegroundColor Yellow
$offenders = @('Razer','Synapse','Cortex','rzdevice','GameManager',
               'NahimicSvc','NahimicOSD','A-Volute','SteelSeries',
               'iCUE','NZXT','SignalRgb','Armory','Sonic','DTS',
               'ExitLag','WallpaperEngine')
$found = $false
foreach ($name in $offenders) {
    $procs = Get-Process -Name "*$name*" -ErrorAction SilentlyContinue
    if ($procs) {
        foreach ($p in $procs) {
            Write-Host ("  FOUND: " + $p.ProcessName + " (PID: " + $p.Id + ")") -ForegroundColor Red
            $found = $true
        }
    }
}
if (-not $found) { Write-Host "  None detected" -ForegroundColor Green }
Write-Host ""

# 7. DPC/Interrupt counters (3 samples)
Write-Host "=== LIVE DPC/INTERRUPT COUNTERS (3 samples, 1s each) ===" -ForegroundColor Yellow
$counterPaths = @(
    '\Processor(_Total)\% DPC Time',
    '\Processor(_Total)\% Interrupt Time',
    '\Processor(_Total)\DPCs Queued/sec'
)
try {
    $samples = Get-Counter -Counter $counterPaths -SampleInterval 1 -MaxSamples 3 -ErrorAction Stop
    foreach ($sample in $samples) {
        $ts = $sample.Timestamp.ToString('HH:mm:ss')
        foreach ($cs in $sample.CounterSamples) {
            $name = $cs.Path.Split('\')[-1]
            $val = [math]::Round($cs.CookedValue, 2)
            Write-Host ("  " + $ts + " | " + $name + ": " + $val)
        }
        Write-Host "  ---"
    }
} catch {
    Write-Host ("  Error reading counters: " + $_.Exception.Message) -ForegroundColor Red
}
Write-Host ""

# 8. Check for high-DPC drivers via WMI
Write-Host "=== TOP INTERRUPT-GENERATING DEVICES ===" -ForegroundColor Yellow
# Check per-CPU interrupt distribution
try {
    $cpuCounters = @()
    for ($i = 0; $i -lt 16; $i++) {
        $cpuCounters += ('\Processor(' + $i + ')\% Interrupt Time')
        $cpuCounters += ('\Processor(' + $i + ')\% DPC Time')
    }
    $cpuSample = Get-Counter -Counter $cpuCounters -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
    Write-Host "  Per-CPU Interrupt + DPC load:"
    for ($i = 0; $i -lt 16; $i++) {
        $intrVal = 0
        $dpcVal = 0
        foreach ($cs in $cpuSample.CounterSamples) {
            if ($cs.Path -like "*($i)\% Interrupt Time") { $intrVal = [math]::Round($cs.CookedValue, 2) }
            if ($cs.Path -like "*($i)\% DPC Time") { $dpcVal = [math]::Round($cs.CookedValue, 2) }
        }
        $bar = ""
        $total = $intrVal + $dpcVal
        if ($total -gt 5) {
            $bar = " <<<< HIGH"
        }
        Write-Host ("  CPU " + $i.ToString().PadLeft(2) + ": Intr=" + $intrVal.ToString().PadLeft(6) + "%  DPC=" + $dpcVal.ToString().PadLeft(6) + "%" + $bar)
    }
} catch {
    Write-Host ("  Error: " + $_.Exception.Message) -ForegroundColor Red
}
Write-Host ""

# 9. Power plan
Write-Host "=== POWER PLAN ===" -ForegroundColor Yellow
$plan = powercfg /getactivescheme
Write-Host "  $plan"
Write-Host ""

# 10. Windows Defender real-time status
Write-Host "=== WINDOWS DEFENDER ===" -ForegroundColor Yellow
try {
    $mpPref = Get-MpPreference -ErrorAction Stop
    Write-Host ("  Real-time Protection: " + (-not $mpPref.DisableRealtimeMonitoring))
    $exCount = 0
    if ($mpPref.ExclusionPath) { $exCount = $mpPref.ExclusionPath.Count }
    Write-Host ("  Exclusion Paths:      " + $exCount)
} catch {
    Write-Host "  Cannot query Defender (need admin)" -ForegroundColor Red
}
Write-Host ""

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  SCAN COMPLETE" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
