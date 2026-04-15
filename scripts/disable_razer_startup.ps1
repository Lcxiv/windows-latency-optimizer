#Requires -RunAsAdministrator
# Permanently disable Razer startup services and scheduled tasks
# Razer hardware still works with basic HID drivers

Write-Output "============================================"
Write-Output "  RAZER STARTUP DISABLE"
Write-Output "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Output "============================================"
Write-Output ""

# 1. Document current state
Write-Output "=== CURRENT RAZER PROCESSES ==="
$razerProcs = Get-Process | Where-Object { $_.ProcessName -match 'Razer|Synapse|rzdevice|GameManager' }
if ($razerProcs) {
    $count = ($razerProcs | Measure-Object).Count
    Write-Output "  Found $count Razer processes:"
    foreach ($p in $razerProcs) {
        Write-Output "    $($p.ProcessName) (PID: $($p.Id))"
    }
} else {
    Write-Output "  No Razer processes running"
}
Write-Output ""

# 2. Disable Razer services
Write-Output "=== DISABLING RAZER SERVICES ==="
$razerServices = @(
    'Razer Elevation Service',
    'Razer Game Manager Service 3',
    'Razer Synapse Service',
    'RzActionSvc',
    'Razer Chroma SDK Server',
    'Razer Chroma SDK Service',
    'Razer Chroma Stream Server'
)

foreach ($svcName in $razerServices) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) {
        # Try display name match
        $svc = Get-Service | Where-Object { $_.DisplayName -eq $svcName } | Select-Object -First 1
    }
    if ($svc) {
        $oldStart = $svc.StartType
        try {
            Set-Service -Name $svc.Name -StartupType Disabled -ErrorAction Stop
            Write-Output "  DISABLED: $($svc.DisplayName) (was: $oldStart)"
        } catch {
            Write-Output "  FAILED:   $($svc.DisplayName) - $($_.Exception.Message)"
        }

        # Stop if running
        if ($svc.Status -eq 'Running') {
            try {
                Stop-Service -Name $svc.Name -Force -ErrorAction Stop
                Write-Output "    Stopped service"
            } catch {
                Write-Output "    Failed to stop: $($_.Exception.Message)"
            }
        }
    } else {
        Write-Output "  NOT FOUND: $svcName (skipped)"
    }
}
Write-Output ""

# 3. Disable Razer scheduled tasks
Write-Output "=== DISABLING RAZER SCHEDULED TASKS ==="
$razerTasks = Get-ScheduledTask | Where-Object { $_.TaskName -match 'Razer' -or $_.TaskPath -match 'Razer' }
if ($razerTasks) {
    foreach ($task in $razerTasks) {
        $oldState = $task.State
        try {
            Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop | Out-Null
            Write-Output "  DISABLED: $($task.TaskPath)$($task.TaskName) (was: $oldState)"
        } catch {
            Write-Output "  FAILED:   $($task.TaskPath)$($task.TaskName) - $($_.Exception.Message)"
        }
    }
} else {
    Write-Output "  No Razer scheduled tasks found"
}
Write-Output ""

# 4. Disable Razer startup registry entries
Write-Output "=== DISABLING RAZER STARTUP REGISTRY ==="
$startupPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
)

foreach ($regPath in $startupPaths) {
    if (Test-Path $regPath) {
        $props = Get-ItemProperty $regPath -ErrorAction SilentlyContinue
        if ($props) {
            $propNames = $props.PSObject.Properties | Where-Object { $_.Value -match 'Razer|Synapse' }
            foreach ($prop in $propNames) {
                $backupName = $prop.Name + '_DISABLED'
                try {
                    # Backup the value before removing
                    New-ItemProperty -Path $regPath -Name $backupName -Value $prop.Value -PropertyType String -Force -ErrorAction Stop | Out-Null
                    Remove-ItemProperty -Path $regPath -Name $prop.Name -Force -ErrorAction Stop
                    Write-Output "  REMOVED: $regPath\$($prop.Name)"
                    Write-Output "    Backup: $backupName = $($prop.Value)"
                } catch {
                    Write-Output "  FAILED:  $regPath\$($prop.Name) - $($_.Exception.Message)"
                }
            }
        }
    }
}
Write-Output ""

# 5. Check Startup folder
Write-Output "=== CHECKING STARTUP FOLDERS ==="
$startupFolders = @(
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
)
foreach ($folder in $startupFolders) {
    if (Test-Path $folder) {
        $razerLinks = Get-ChildItem $folder -Filter '*Razer*' -ErrorAction SilentlyContinue
        if ($razerLinks) {
            foreach ($link in $razerLinks) {
                $backupPath = $link.FullName + '.disabled'
                try {
                    Rename-Item -Path $link.FullName -NewName $link.Name'.disabled' -Force -ErrorAction Stop
                    Write-Output "  DISABLED: $($link.FullName) -> .disabled"
                } catch {
                    Write-Output "  FAILED:  $($link.FullName) - $($_.Exception.Message)"
                }
            }
        } else {
            Write-Output "  No Razer shortcuts in: $folder"
        }
    }
}
Write-Output ""

# 6. Kill all remaining Razer processes
Write-Output "=== KILLING RAZER PROCESSES ==="
$razerProcs = Get-Process | Where-Object { $_.ProcessName -match 'Razer|Synapse|rzdevice|GameManager' }
if ($razerProcs) {
    foreach ($p in $razerProcs) {
        try {
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
            Write-Output "  Killed: $($p.ProcessName) (PID: $($p.Id))"
        } catch {
            Write-Output "  Failed to kill: $($p.ProcessName) (PID: $($p.Id)) - $($_.Exception.Message)"
        }
    }
} else {
    Write-Output "  No Razer processes to kill"
}
Write-Output ""

# 7. Verify
Start-Sleep -Seconds 2
Write-Output "=== VERIFICATION ==="
$remaining = Get-Process | Where-Object { $_.ProcessName -match 'Razer|Synapse|rzdevice|GameManager' }
if ($remaining) {
    $remCount = ($remaining | Measure-Object).Count
    Write-Output "  WARNING: $remCount Razer processes still running"
    foreach ($p in $remaining) {
        Write-Output "    $($p.ProcessName) (PID: $($p.Id))"
    }
} else {
    Write-Output "  All Razer processes: DEAD"
}

$svcCheck = Get-Service | Where-Object { $_.DisplayName -match 'Razer' -and $_.StartType -ne 'Disabled' }
if ($svcCheck) {
    Write-Output "  WARNING: Some Razer services not disabled:"
    foreach ($s in $svcCheck) {
        Write-Output "    $($s.DisplayName): $($s.StartType)"
    }
} else {
    Write-Output "  All Razer services: DISABLED"
}

Write-Output ""
Write-Output "============================================"
Write-Output "  RAZER STARTUP DISABLED"
Write-Output "  To re-enable: set services back to Automatic"
Write-Output "  and re-run Razer Synapse installer"
Write-Output "============================================"
