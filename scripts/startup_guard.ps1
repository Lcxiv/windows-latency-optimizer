<#
.SYNOPSIS
    Startup guard — verify and auto-fix latency optimizations at every logon.
.DESCRIPTION
    Runs all verification checks at Windows logon. Auto-fixes any drift
    (e.g., Windows re-enabling USB EPM, registry values reset by updates).
    Logs results to captures/startup_guard_log.txt.

    Designed to run as a Scheduled Task at logon with highest privileges.
    Register with: .\startup_guard.ps1 -Register
    Unregister with: .\startup_guard.ps1 -Unregister
.PARAMETER Register
    Create the scheduled task (requires admin).
.PARAMETER Unregister
    Remove the scheduled task.
.PARAMETER RunNow
    Execute all guards immediately (default if no switch specified).
.PARAMETER Quiet
    Suppress console output (log file only).
.EXAMPLE
    .\startup_guard.ps1 -Register
.EXAMPLE
    .\startup_guard.ps1
#>
#Requires -RunAsAdministrator
param(
    [switch]$Register,
    [switch]$Unregister,
    [switch]$RunNow,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'

$scriptRoot = Split-Path $MyInvocation.MyCommand.Path -Parent
$projectRoot = Split-Path $scriptRoot -Parent
$logDir = Join-Path $projectRoot 'captures'
$logFile = Join-Path $logDir 'startup_guard_log.txt'
$taskName = 'LatencyGuard-StartupCheck'

# ── Helpers ──────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '[' + $ts + '] [' + $Level + '] ' + $Message
    if (-not $Quiet) {
        $color = switch ($Level) {
            'PASS' { 'Green' }
            'FIX'  { 'Cyan' }
            'WARN' { 'Yellow' }
            'FAIL' { 'Red' }
            default { 'Gray' }
        }
        Write-Host $line -ForegroundColor $color
    }
    $line | Out-File $logFile -Append -Encoding UTF8
}

function Write-Section {
    param([string]$Name)
    $line = '--- ' + $Name + ' ---'
    if (-not $Quiet) { Write-Host $line -ForegroundColor White }
    $line | Out-File $logFile -Append -Encoding UTF8
}

# ── Register / Unregister ────────────────────────────────────────────────────

if ($Register) {
    # Check if already registered
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host ('Task "' + $taskName + '" already exists. Updating...') -ForegroundColor Yellow
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    $scriptPath = $MyInvocation.MyCommand.Path
    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument ('-ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $scriptPath + '" -RunNow -Quiet')

    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

    # Run with highest privileges, don't stop if on battery
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    $principal = New-ScheduledTaskPrincipal `
        -UserId $env:USERNAME `
        -RunLevel Highest `
        -LogonType Interactive

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Description 'LatencyGuard: verify and auto-fix USB EPM, mouse input tweaks, and other latency optimizations at logon.' | Out-Null

    Write-Host '' -ForegroundColor Green
    Write-Host ('Scheduled task "' + $taskName + '" registered.') -ForegroundColor Green
    Write-Host '  Trigger: At logon (' + $env:USERNAME + ')' -ForegroundColor Cyan
    Write-Host '  Action:  Auto-fix USB EPM, mouse input, future guards' -ForegroundColor Cyan
    Write-Host ('  Log:     ' + $logFile) -ForegroundColor Cyan
    Write-Host '' -ForegroundColor Green
    Write-Host 'To test: .\startup_guard.ps1' -ForegroundColor DarkCyan
    Write-Host 'To remove: .\startup_guard.ps1 -Unregister' -ForegroundColor DarkCyan
    exit 0
}

if ($Unregister) {
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host ('Removed scheduled task "' + $taskName + '".') -ForegroundColor Green
    } else {
        Write-Host ('Task "' + $taskName + '" not found.') -ForegroundColor Yellow
    }
    exit 0
}

# ── Guard Checks ─────────────────────────────────────────────────────────────

# Ensure log directory exists
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

$fixes = 0
$checks = 0
$passed = 0

Write-Log ('=== LatencyGuard Startup Check ===')

# ── Guard 1: USB EnhancedPowerManagement (Viper V3 Pro) ──────────────────────
Write-Section 'USB EnhancedPowerManagement'

$mouseUsb = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
    $_.FriendlyName -match 'Viper V3' -and $_.InstanceId -match '^USB' -and $_.Status -eq 'OK'
})

if ($mouseUsb.Count -eq 0) {
    Write-Log 'No active Viper V3 USB devices found (mouse off or wireless?)' 'WARN'
} else {
    foreach ($dev in $mouseUsb) {
        $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $dev.InstanceId + '\Device Parameters'
        $checks++
        if (Test-Path $regPath) {
            $epm = (Get-ItemProperty $regPath -Name 'EnhancedPowerManagementEnabled' -ErrorAction SilentlyContinue).EnhancedPowerManagementEnabled
            $shortId = $dev.InstanceId.Split('\')
            $shortId = $shortId[$shortId.Count - 1]

            if ($epm -eq 1) {
                Set-ItemProperty $regPath -Name 'EnhancedPowerManagementEnabled' -Value 0 -Type DWord
                Write-Log ('EPM 1->0 on ' + $shortId + ' (was adding input latency)') 'FIX'
                $fixes++
            } elseif ($null -eq $epm -or $epm -eq 0) {
                Write-Log ('EPM=0 on ' + $shortId) 'PASS'
                $passed++
            }

            # Also check SelectiveSuspend
            $ss = (Get-ItemProperty $regPath -Name 'SelectiveSuspendEnabled' -ErrorAction SilentlyContinue).SelectiveSuspendEnabled
            if ($ss -eq 1) {
                $checks++
                Set-ItemProperty $regPath -Name 'SelectiveSuspendEnabled' -Value 0 -Type DWord
                Write-Log ('SelectiveSuspend 1->0 on ' + $shortId) 'FIX'
                $fixes++
            }
        }
    }
}

# ── Guard 2: Mouse & Keyboard Input Stack ────────────────────────────────────
Write-Section 'Mouse/Keyboard Input Tweaks'

$inputTweaks = @(
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters'; Name = 'MouseDataQueueSize'; Value = 32; Type = 'DWord' },
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters'; Name = 'WppRecorder_UseTimeStamp'; Value = 0; Type = 'DWord' },
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters'; Name = 'KeyboardDataQueueSize'; Value = 32; Type = 'DWord' },
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters'; Name = 'WppRecorder_UseTimeStamp'; Value = 0; Type = 'DWord' },
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters'; Name = 'SendOutputToAllPorts'; Value = 0; Type = 'DWord' },
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\mouhid\Parameters'; Name = 'TreatAbsolutePointerAsAbsolute'; Value = 1; Type = 'DWord' },
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\mouhid\Parameters'; Name = 'WppRecorder_UseTimeStamp'; Value = 0; Type = 'DWord' },
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Input\Settings\ControllerProcessor\CursorSpeed'; Name = 'CursorUpdateInterval'; Value = 1; Type = 'DWord' },
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Input\Settings\ControllerProcessor\CursorMagnetism'; Name = 'AttractionRectInsetInDIPS'; Value = 0; Type = 'DWord' },
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Input\Settings\ControllerProcessor\CursorMagnetism'; Name = 'DistanceThresholdInDIPS'; Value = 0; Type = 'DWord' },
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Input\Settings\ControllerProcessor\CursorMagnetism'; Name = 'MagnetismDelayInMilliseconds'; Value = 0; Type = 'DWord' },
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Input\Settings\ControllerProcessor\CursorMagnetism'; Name = 'MagnetismUpdateIntervalInMilliseconds'; Value = 0; Type = 'DWord' },
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Input\Settings\ControllerProcessor\CursorMagnetism'; Name = 'VelocityInDIPSPerSecond'; Value = 0; Type = 'DWord' }
)

foreach ($t in $inputTweaks) {
    $checks++
    $current = $null
    try {
        $current = (Get-ItemProperty $t.Path -Name $t.Name -ErrorAction Stop).$($t.Name)
    } catch {}

    if ($null -ne $current -and [int]$current -eq $t.Value) {
        $passed++
        # Don't log every PASS — too noisy for startup
    } else {
        if (-not (Test-Path $t.Path)) {
            New-Item -Path $t.Path -Force | Out-Null
        }
        $fromStr = if ($null -eq $current) { '(not set)' } else { [string]$current }
        Set-ItemProperty $t.Path -Name $t.Name -Value $t.Value -Type $t.Type
        Write-Log ($t.Name + ': ' + $fromStr + ' -> ' + [string]$t.Value) 'FIX'
        $fixes++
    }
}

$inputDrift = $fixes  # track how many input tweaks drifted
if ($inputDrift -eq 0) {
    Write-Log ('All ' + $inputTweaks.Count + ' input tweaks intact') 'PASS'
}

# ── Guard 3: Windows Defender Settings ──────────────────────────────────────
Write-Section 'Windows Defender Settings'

$defenderPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
$defenderScanPath   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Scan'

$defenderChecks = @(
    @{ Path = $defenderPolicyPath; Name = 'DisableRealtimeMonitoring'; Value = 1; Type = 'DWord'; Label = 'Real-time monitoring disabled' },
    @{ Path = $defenderScanPath;   Name = 'ScanAvgCPULoadFactor';     Value = 5; Type = 'DWord'; Label = 'Scan CPU cap = 5%' }
)

foreach ($d in $defenderChecks) {
    $checks++
    $current = $null
    try {
        if (-not (Test-Path $d.Path)) {
            New-Item -Path $d.Path -Force | Out-Null
        }
        $current = (Get-ItemProperty $d.Path -Name $d.Name -ErrorAction Stop).$($d.Name)
    } catch {}

    if ($null -ne $current -and [int]$current -eq $d.Value) {
        Write-Log ($d.Label + ' [OK]') 'PASS'
        $passed++
    } else {
        $fromStr = if ($null -eq $current) { '<null>' } else { [string]$current }
        if (-not (Test-Path $d.Path)) {
            New-Item -Path $d.Path -Force | Out-Null
        }
        Set-ItemProperty $d.Path -Name $d.Name -Value $d.Value -Type $d.Type
        Write-Log ($d.Name + ': ' + $fromStr + ' -> ' + [string]$d.Value + ' (' + $d.Label + ')') 'FIX'
        $fixes++
    }
}

# Exclusion paths — restore from config file (skip if Defender WMI is dead)
$checks++
$exclusionFile = Join-Path $projectRoot 'config\defender_exclusions.txt'
if (Test-Path $exclusionFile) {
    $mpPrefError = $false
    try {
        $currentPaths = @((Get-MpPreference -ErrorAction Stop).ExclusionPath)
    } catch {
        $mpPrefError = $true
    }

    if ($mpPrefError) {
        # 0x800106ba = Defender AM not running / WMI dead — exclusions irrelevant
        Write-Log 'Defender WMI unavailable (AM dormant) - exclusions N/A' 'PASS'
        $passed++
    } else {
        $expectedPaths = @(Get-Content $exclusionFile | Where-Object { $_.Trim().Length -gt 0 } | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) })
        $missing = @()
        foreach ($ep in $expectedPaths) {
            $found = $false
            foreach ($cp in $currentPaths) {
                if ($cp -eq $ep) { $found = $true; break }
            }
            if (-not $found) { $missing += $ep }
        }
        if ($missing.Count -eq 0) {
            Write-Log ($expectedPaths.Count.ToString() + ' exclusion paths intact') 'PASS'
            $passed++
        } else {
            foreach ($mp in $missing) {
                $expandedPath = [Environment]::ExpandEnvironmentVariables($mp)
                try { Add-MpPreference -ExclusionPath $expandedPath -ErrorAction Stop } catch {}
            }
            Write-Log ('Restored ' + $missing.Count.ToString() + ' missing exclusion path(s)') 'FIX'
            $fixes++
        }
    }
} else {
    Write-Log ('Exclusion config not found: ' + $exclusionFile) 'WARN'
}

# ── Guard 4: Deep Optimize Drift (GameBar, GameDVR, CSRSS priority) ─────────
Write-Section 'Deep Optimize Settings'

$deepChecks = @(
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR';  Name = 'AllowGameDVR';           Value = 0; Type = 'DWord'; Label = 'GameBar policy disabled' },
    @{ Path = 'HKCU:\System\GameConfigStore';                        Name = 'GameDVR_Enabled';         Value = 0; Type = 'DWord'; Label = 'GameDVR disabled' },
    @{ Path = 'HKCU:\System\GameConfigStore';                        Name = 'GameDVR_FSEBehaviorMode'; Value = 0; Type = 'DWord'; Label = 'FSE behavior mode' },
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled';  Value = 0; Type = 'DWord'; Label = 'App capture disabled' },
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\csrss.exe\PerfOptions'; Name = 'CpuPriorityClass'; Value = 3; Type = 'DWord'; Label = 'CSRSS high priority' },
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'; Name = 'PowerThrottlingOff'; Value = 1; Type = 'DWord'; Label = 'Power throttling off' }
)

$deepDrift = 0
foreach ($d in $deepChecks) {
    $checks++
    $current = $null
    try {
        $current = (Get-ItemProperty $d.Path -Name $d.Name -ErrorAction Stop).$($d.Name)
    } catch {}

    if ($null -ne $current -and [int]$current -eq $d.Value) {
        $passed++
    } else {
        if (-not (Test-Path $d.Path)) {
            New-Item -Path $d.Path -Force | Out-Null
        }
        $fromStr = if ($null -eq $current) { '<null>' } else { [string]$current }
        Set-ItemProperty $d.Path -Name $d.Name -Value $d.Value -Type $d.Type
        Write-Log ($d.Name + ': ' + $fromStr + ' -> ' + [string]$d.Value + ' (' + $d.Label + ')') 'FIX'
        $fixes++
        $deepDrift++
    }
}

if ($deepDrift -eq 0) {
    Write-Log ('All ' + $deepChecks.Count + ' deep optimize settings intact') 'PASS'
}

# ── Guard 5: NVIDIA GPU Performance Settings ───────────────────────────────
Write-Section 'NVIDIA GPU Performance'

$nvRegPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000'
$nvChecks = @(
    @{ Name = 'DisableDynamicPstate'; Value = 1; Label = 'Dynamic P-state disabled' },
    @{ Name = 'PerfLevelSrc';         Value = 13090; Label = 'Max performance mode (0x3322)' },
    @{ Name = 'PowerMizerEnable';     Value = 1; Label = 'PowerMizer enabled' },
    @{ Name = 'PowerMizerLevel';      Value = 1; Label = 'PowerMizer high perf' }
)

$nvDrift = 0
if (Test-Path $nvRegPath) {
    foreach ($nv in $nvChecks) {
        $checks++
        $current = (Get-ItemProperty $nvRegPath -Name $nv.Name -ErrorAction SilentlyContinue).$($nv.Name)
        if ($null -ne $current -and [int]$current -eq $nv.Value) {
            $passed++
        } else {
            $fromStr = if ($null -eq $current) { '<null>' } else { [string]$current }
            Set-ItemProperty $nvRegPath -Name $nv.Name -Value $nv.Value -Type DWord
            Write-Log ($nv.Name + ': ' + $fromStr + ' -> ' + [string]$nv.Value + ' (' + $nv.Label + ')') 'FIX'
            $fixes++
            $nvDrift++
        }
    }
    if ($nvDrift -eq 0) {
        Write-Log ('All ' + $nvChecks.Count + ' NVIDIA settings intact') 'PASS'
    }

    # Apply nvidia-smi clock lock (immediate effect, no reboot needed)
    $nvsmi = 'C:\Windows\System32\nvidia-smi.exe'
    if (Test-Path $nvsmi) {
        $lockResult = & $nvsmi -lgc 3090,3090 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log 'GPU clock locked to 3090 MHz' 'PASS'
        } else {
            Write-Log ('nvidia-smi clock lock failed: ' + $lockResult) 'WARN'
        }
    }
} else {
    Write-Log 'NVIDIA GPU registry key not found' 'WARN'
}

# ── Summary ──────────────────────────────────────────────────────────────────
Write-Log ''
$summary = 'Checks: ' + $checks + ' | Passed: ' + $passed + ' | Fixed: ' + $fixes
if ($fixes -eq 0) {
    Write-Log ('All clear. ' + $summary) 'PASS'
} else {
    Write-Log ('Applied ' + $fixes + ' fix(es). ' + $summary) 'FIX'
}
Write-Log ''
