<#
.SYNOPSIS
    Verify Razer Synapse is cleanly uninstalled and mouse is properly configured.
.DESCRIPTION
    Three modes:
    - Verify (default): Check for leftover Razer bloat and mouse config issues
    - Cleanup: Remove leftover folders, disable services, fix USB power management
    - PreUninstall: Checklist to run BEFORE uninstalling Synapse

    Focus areas:
    1. Razer processes, services, scheduled tasks, startup items
    2. Leftover folders (Program Files, AppData, ProgramData)
    3. USB EnhancedPowerManagement on mouse (latency killer)
    4. Mouse device health (PnP status)
    5. LWI Wizard / SYNAPSE_COMPONENT phantom devices
.PARAMETER Verify
    Show current state without changing anything (default).
.PARAMETER Cleanup
    Remove leftover Razer artifacts and fix USB power management.
.PARAMETER PreUninstall
    Show checklist before uninstalling Synapse.
.PARAMETER WhatIf
    Preview cleanup actions without executing.
.EXAMPLE
    .\verify_razer_cleanup.ps1
.EXAMPLE
    .\verify_razer_cleanup.ps1 -Cleanup
.EXAMPLE
    .\verify_razer_cleanup.ps1 -PreUninstall
#>
#Requires -RunAsAdministrator
param(
    [switch]$Verify,
    [switch]$Cleanup,
    [switch]$PreUninstall,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Continue'

# If no mode specified, default to Verify
if (-not $Verify -and -not $Cleanup -and -not $PreUninstall) { $Verify = $true }

$pass = 0
$warn = 0
$fail = 0

function Log-Check {
    param([string]$Status, [string]$Message)
    switch ($Status) {
        'PASS' { Write-Host ('  [PASS] ' + $Message) -ForegroundColor Green; $script:pass++ }
        'WARN' { Write-Host ('  [WARN] ' + $Message) -ForegroundColor Yellow; $script:warn++ }
        'FAIL' { Write-Host ('  [FAIL] ' + $Message) -ForegroundColor Red; $script:fail++ }
        'FIX'  { Write-Host ('  [FIX]  ' + $Message) -ForegroundColor Cyan }
        'INFO' { Write-Host ('  [INFO] ' + $Message) -ForegroundColor DarkGray }
    }
}

# ── Pre-Uninstall Checklist ───────────────────────────────────────────────────
if ($PreUninstall) {
    Write-Host '=== Pre-Uninstall Checklist ===' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Before uninstalling Razer Synapse, complete these steps:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  1. Open Razer Synapse' -ForegroundColor White
    Write-Host '  2. Go to your Viper V3 Pro device page' -ForegroundColor White
    Write-Host '  3. PERFORMANCE tab:' -ForegroundColor White
    Write-Host '     - Set Polling Rate to 4000Hz' -ForegroundColor White
    Write-Host '     - Enable Motion Sync' -ForegroundColor White
    Write-Host '     - Set DPI stages as desired' -ForegroundColor White
    Write-Host '  4. CALIBRATION tab:' -ForegroundColor White
    Write-Host '     - Set Lift-Off Distance to Low' -ForegroundColor White
    Write-Host '     - Enable Asymmetric Cut-Off (lower landing distance)' -ForegroundColor White
    Write-Host '  5. PROFILE tab:' -ForegroundColor White
    Write-Host '     - Click "Device Memory" (NOT cloud)' -ForegroundColor White
    Write-Host '     - Save current profile to Onboard Slot 1' -ForegroundColor White
    Write-Host '     - Verify profile saved (disconnect/reconnect mouse to test)' -ForegroundColor White
    Write-Host '  6. Close Synapse' -ForegroundColor White
    Write-Host '  7. Uninstall via Settings > Apps > Razer Synapse' -ForegroundColor White
    Write-Host '  8. Reboot' -ForegroundColor White
    Write-Host '  9. Run: .\verify_razer_cleanup.ps1 -Cleanup' -ForegroundColor White
    Write-Host ''
    Write-Host 'Settings saved to onboard memory persist after Synapse removal.' -ForegroundColor Green
    exit 0
}

# ── Verify / Cleanup ─────────────────────────────────────────────────────────
Write-Host '=== Razer Cleanup Verification ===' -ForegroundColor Cyan
Write-Host ''

# --- 1. Processes ---
Write-Host '--- Processes ---' -ForegroundColor White
$razerProcs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'Razer|Rz' })
if ($razerProcs.Count -eq 0) {
    Log-Check 'PASS' 'No Razer processes running'
} else {
    foreach ($p in $razerProcs) {
        $memMB = [math]::Round($p.WorkingSet64/1MB, 1)
        Log-Check 'FAIL' ('Process: ' + $p.ProcessName + ' (PID ' + $p.Id + ', ' + $memMB + ' MB)')
    }
    if ($Cleanup) {
        foreach ($p in $razerProcs) {
            if ($WhatIf) {
                Log-Check 'INFO' ('Would kill: ' + $p.ProcessName)
            } else {
                Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                Log-Check 'FIX' ('Killed: ' + $p.ProcessName)
            }
        }
    }
}

# --- 2. Services ---
Write-Host '--- Services ---' -ForegroundColor White
$razerSvcs = @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
    $_.DisplayName -match 'Razer|Rz' -or $_.Name -match 'Razer|Rz'
})
if ($razerSvcs.Count -eq 0) {
    Log-Check 'PASS' 'No Razer services found'
} else {
    foreach ($svc in $razerSvcs) {
        if ($svc.StartType -eq 'Disabled' -and $svc.Status -eq 'Stopped') {
            Log-Check 'WARN' ('Service: ' + $svc.Name + ' (' + $svc.DisplayName + ') — Disabled/Stopped (harmless but residual)')
        } else {
            Log-Check 'FAIL' ('Service: ' + $svc.Name + ' (' + $svc.DisplayName + ') — ' + $svc.Status + '/' + $svc.StartType)
        }
        if ($Cleanup) {
            if ($svc.Status -ne 'Stopped') {
                if ($WhatIf) {
                    Log-Check 'INFO' ('Would stop: ' + $svc.Name)
                } else {
                    Stop-Service $svc.Name -Force -ErrorAction SilentlyContinue
                    Log-Check 'FIX' ('Stopped: ' + $svc.Name)
                }
            }
            if ($svc.StartType -ne 'Disabled') {
                if ($WhatIf) {
                    Log-Check 'INFO' ('Would disable: ' + $svc.Name)
                } else {
                    Set-Service $svc.Name -StartupType Disabled -ErrorAction SilentlyContinue
                    Log-Check 'FIX' ('Disabled: ' + $svc.Name)
                }
            }
        }
    }
}

# --- 3. Scheduled Tasks ---
Write-Host '--- Scheduled Tasks ---' -ForegroundColor White
$razerTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
    $_.TaskName -match 'Razer|Rz' -or $_.TaskPath -match 'Razer|Rz'
})
if ($razerTasks.Count -eq 0) {
    Log-Check 'PASS' 'No Razer scheduled tasks'
} else {
    foreach ($task in $razerTasks) {
        Log-Check 'FAIL' ('Task: ' + $task.TaskName + ' (' + $task.State + ')')
        if ($Cleanup -and -not $WhatIf) {
            Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false -ErrorAction SilentlyContinue
            Log-Check 'FIX' ('Removed task: ' + $task.TaskName)
        }
    }
}

# --- 4. Startup / Run Keys ---
Write-Host '--- Startup & Run Keys ---' -ForegroundColor White
$runKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
)
$foundRun = $false
foreach ($key in $runKeys) {
    if (Test-Path $key) {
        $props = Get-ItemProperty $key -ErrorAction SilentlyContinue
        $props.PSObject.Properties | Where-Object { $_.Value -match 'Razer|Rz' } | ForEach-Object {
            Log-Check 'FAIL' ('Run key: ' + $key + ' -> ' + $_.Name)
            $foundRun = $true
            if ($Cleanup -and -not $WhatIf) {
                Remove-ItemProperty $key -Name $_.Name -ErrorAction SilentlyContinue
                Log-Check 'FIX' ('Removed: ' + $_.Name + ' from ' + $key)
            }
        }
    }
}
if (-not $foundRun) { Log-Check 'PASS' 'No Razer startup/run entries' }

# --- 5. Leftover Folders ---
Write-Host '--- Leftover Folders ---' -ForegroundColor White
$folders = @(
    'C:\Program Files\Razer',
    'C:\Program Files (x86)\Razer',
    'C:\ProgramData\Razer',
    ($env:LOCALAPPDATA + '\Razer'),
    ($env:APPDATA + '\Razer'),
    ($env:LOCALAPPDATA + '\Razer Game Manager')
)
$foundFolders = $false
foreach ($f in $folders) {
    if (Test-Path $f) {
        $size = (Get-ChildItem $f -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $sizeMB = [math]::Round($size/1MB, 1)
        Log-Check 'WARN' ($f + ' (' + $sizeMB + ' MB)')
        $foundFolders = $true
        if ($Cleanup) {
            if ($WhatIf) {
                Log-Check 'INFO' ('Would remove: ' + $f)
            } else {
                Remove-Item $f -Recurse -Force -ErrorAction SilentlyContinue
                if (Test-Path $f) {
                    Log-Check 'WARN' ('Partial removal (files in use): ' + $f)
                } else {
                    Log-Check 'FIX' ('Removed: ' + $f + ' (' + $sizeMB + ' MB freed)')
                }
            }
        }
    }
}
if (-not $foundFolders) { Log-Check 'PASS' 'No leftover Razer folders' }

# --- 6. USB EnhancedPowerManagement ---
Write-Host '--- USB Power Management (Mouse) ---' -ForegroundColor White
$mouseUsb = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
    $_.FriendlyName -match 'Viper V3' -and $_.InstanceId -match '^USB' -and $_.Status -eq 'OK'
})
if ($mouseUsb.Count -eq 0) {
    Log-Check 'WARN' 'No active Viper V3 USB devices found'
} else {
    foreach ($dev in $mouseUsb) {
        $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $dev.InstanceId + '\Device Parameters'
        if (Test-Path $regPath) {
            $epm = (Get-ItemProperty $regPath -Name 'EnhancedPowerManagementEnabled' -ErrorAction SilentlyContinue).EnhancedPowerManagementEnabled
            $ss = (Get-ItemProperty $regPath -Name 'SelectiveSuspendEnabled' -ErrorAction SilentlyContinue).SelectiveSuspendEnabled
            $shortId = $dev.InstanceId.Split('\')
            $shortId = $shortId[$shortId.Count - 1]

            if ($epm -eq 1) {
                Log-Check 'FAIL' ('EPM=1 on ' + $shortId + ' — adds USB wake-up latency on every input!')
                if ($Cleanup) {
                    if ($WhatIf) {
                        Log-Check 'INFO' ('Would set EPM=0 on ' + $shortId)
                    } else {
                        Set-ItemProperty $regPath -Name 'EnhancedPowerManagementEnabled' -Value 0 -Type DWord
                        Log-Check 'FIX' ('EPM=0 on ' + $shortId + ' — USB power management disabled')
                    }
                }
            } elseif ($null -eq $epm) {
                Log-Check 'PASS' ('EPM not set on ' + $shortId + ' (default off)')
            } else {
                Log-Check 'PASS' ('EPM=0 on ' + $shortId)
            }

            if ($ss -eq 1) {
                Log-Check 'FAIL' ('SelectiveSuspend=1 on ' + $shortId + ' — USB device may sleep')
                if ($Cleanup) {
                    if ($WhatIf) {
                        Log-Check 'INFO' ('Would set SelectiveSuspend=0 on ' + $shortId)
                    } else {
                        Set-ItemProperty $regPath -Name 'SelectiveSuspendEnabled' -Value 0 -Type DWord
                        Log-Check 'FIX' ('SelectiveSuspend=0 on ' + $shortId)
                    }
                }
            }
        }
    }
}

# --- 7. Mouse Device Health ---
Write-Host '--- Mouse Device Health ---' -ForegroundColor White
$allMouse = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
    $_.FriendlyName -match 'Viper V3' -and $_.InstanceId -match '^HID' -and $_.Status -eq 'OK'
})
if ($allMouse.Count -gt 0) {
    Log-Check 'PASS' ('Viper V3 Pro: ' + $allMouse.Count + ' HID interface(s) active')
} else {
    Log-Check 'FAIL' 'No active Viper V3 Pro HID devices — mouse may not be working!'
}

# --- 8. LWI Wizard / SYNAPSE phantom devices ---
Write-Host '--- Phantom Synapse Devices ---' -ForegroundColor White
$phantoms = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
    $_.FriendlyName -match 'LWI Wizard|SYNAPSE' -and $_.Status -ne 'OK'
})
if ($phantoms.Count -eq 0) {
    Log-Check 'PASS' 'No phantom Synapse devices'
} else {
    Log-Check 'WARN' ($phantoms.Count.ToString() + ' phantom Synapse device(s) (cosmetic, no performance impact)')
    if ($Cleanup) {
        foreach ($ph in $phantoms) {
            if ($WhatIf) {
                Log-Check 'INFO' ('Would remove phantom: ' + $ph.FriendlyName)
            } else {
                try {
                    $ph | Remove-PnpDevice -Confirm:$false -ErrorAction Stop
                    Log-Check 'FIX' ('Removed phantom: ' + $ph.FriendlyName)
                } catch {
                    Log-Check 'WARN' ('Cannot remove phantom (may need Device Manager): ' + $ph.FriendlyName)
                }
            }
        }
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '=== Summary ===' -ForegroundColor Cyan
Write-Host ('  PASS: ' + $pass + '  WARN: ' + $warn + '  FAIL: ' + $fail) -ForegroundColor White

if ($fail -gt 0 -and -not $Cleanup) {
    Write-Host ''
    Write-Host 'Issues found. Run with -Cleanup to fix:' -ForegroundColor Yellow
    Write-Host '  .\verify_razer_cleanup.ps1 -Cleanup' -ForegroundColor Cyan
    Write-Host '  .\verify_razer_cleanup.ps1 -Cleanup -WhatIf  (preview only)' -ForegroundColor DarkCyan
} elseif ($fail -eq 0 -and $warn -eq 0) {
    Write-Host ''
    Write-Host 'System is clean. No Razer bloat detected.' -ForegroundColor Green
} elseif ($Cleanup -and -not $WhatIf) {
    Write-Host ''
    Write-Host 'Cleanup complete. Reboot recommended.' -ForegroundColor Green
}
