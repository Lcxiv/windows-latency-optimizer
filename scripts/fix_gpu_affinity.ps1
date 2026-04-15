#Requires -RunAsAdministrator
# Fix GPU Interrupt Affinity - Route GPU interrupts off CPU 0
# Targets: NVIDIA GPU (dxgkrnl.sys/nvlddmkm.sys) and Intel NIC
# Based on 9800X3D topology: CPUs 4-7 = DPC worker cores

param(
    [switch]$Apply,
    [switch]$CheckOnly,
    [switch]$KillRazer,
    [switch]$Revert
)

$ErrorActionPreference = 'Continue'

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  GPU INTERRUPT AFFINITY FIX" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# CPU Topology reminder:
# CPU 0:     Preferred core - KEEP IDLE (currently 13.6% GPU load!)
# CPUs 2-3:  Input devices (keyboard/mouse USB)
# CPUs 4-7:  GPU/NIC/USB bulk DPC work
# CPUs 8-15: Game threads

# Target affinity mask for CPUs 4-7 = 0xF0 (binary: 11110000)
$gpuAffinityMask = [byte[]]@(0xF0, 0x00) # CPUs 4-7
# For NIC: CPUs 4-5 = 0x30
$nicAffinityMask = [byte[]]@(0x30, 0x00) # CPUs 4-5
# For USB controllers: CPUs 2-3 = 0x0C
$usbAffinityMask = [byte[]]@(0x0C, 0x00) # CPUs 2-3
# For HD Audio: CPU 6 = 0x40
$audioAffinityMask = [byte[]]@(0x40, 0x00) # CPU 6

# ============================================================
# Find target devices
# ============================================================

Write-Host "=== FINDING DEVICES ===" -ForegroundColor Yellow

# NVIDIA GPU
$gpuDevices = Get-WmiObject Win32_PnPEntity | Where-Object {
    $_.Name -like '*NVIDIA*GeForce*' -or $_.Name -like '*NVIDIA*RTX*'
}

# Intel NIC
$nicDevices = Get-WmiObject Win32_PnPEntity | Where-Object {
    $_.Name -like '*I226*'
}

# NVIDIA HD Audio (HDMI audio)
$nvidiaAudioDevices = Get-WmiObject Win32_PnPEntity | Where-Object {
    $_.DeviceID -like 'HDAUDIO*' -and $_.Name -like '*NVIDIA*Audio*'
}

# HD Audio Controllers (PCI level)
$audioControllers = Get-WmiObject Win32_PnPEntity | Where-Object {
    $_.DeviceID -like 'PCI*' -and $_.Name -like '*High Definition Audio Controller*'
}

# USB Controllers
$usbControllers = Get-WmiObject Win32_PnPEntity | Where-Object {
    $_.DeviceID -like 'PCI*' -and $_.Name -like '*USB*Host*Controller*'
}

$allDevices = @()

foreach ($dev in $gpuDevices) {
    Write-Host "  GPU:       $($dev.Name)" -ForegroundColor Green
    Write-Host "             $($dev.DeviceID)"
    $allDevices += @{ Device = $dev; Mask = $gpuAffinityMask; Type = 'GPU'; Policy = 4 }
}

foreach ($dev in $nicDevices) {
    Write-Host "  NIC:       $($dev.Name)" -ForegroundColor Green
    Write-Host "             $($dev.DeviceID)"
    $allDevices += @{ Device = $dev; Mask = $nicAffinityMask; Type = 'NIC'; Policy = 4 }
}

foreach ($dev in $audioControllers) {
    Write-Host "  Audio Ctrl: $($dev.Name)" -ForegroundColor Green
    Write-Host "             $($dev.DeviceID)"
    # Only target the NVIDIA audio controller (10DE vendor)
    if ($dev.DeviceID -like '*VEN_10DE*') {
        $allDevices += @{ Device = $dev; Mask = $audioAffinityMask; Type = 'NVIDIA Audio Controller'; Policy = 4 }
    }
}

foreach ($dev in $usbControllers) {
    Write-Host "  USB:       $($dev.Name)" -ForegroundColor Green
    Write-Host "             $($dev.DeviceID)"
    $allDevices += @{ Device = $dev; Mask = $usbAffinityMask; Type = 'USB'; Policy = 4 }
}

Write-Host ""

# ============================================================
# Check current affinity state
# ============================================================

Write-Host "=== CURRENT AFFINITY STATE ===" -ForegroundColor Yellow

foreach ($entry in $allDevices) {
    $dev = $entry.Device
    $regBase = "HKLM:\SYSTEM\CurrentControlSet\Enum\" + $dev.DeviceID

    $affinityPath = "$regBase\Device Parameters\Interrupt Management\Affinity Policy"
    $msiPath = "$regBase\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"

    Write-Host "  $($entry.Type): $($dev.Name)" -ForegroundColor Cyan

    if (Test-Path $affinityPath) {
        $props = Get-ItemProperty $affinityPath -ErrorAction SilentlyContinue
        $policyVal = $props.DevicePolicy
        $maskVal = $props.AssignmentSetOverride

        $policyName = switch ($policyVal) {
            0 { "Default" }
            1 { "All Close Processors" }
            2 { "All Processors In Machine" }
            3 { "Specified Processors" }
            4 { "Spread Messages Across All Processors" }
            default { "Unknown ($policyVal)" }
        }

        Write-Host "    Policy: $policyName"
        if ($maskVal) {
            $maskHex = [BitConverter]::ToString($maskVal) -replace '-',''
            Write-Host "    Affinity Mask: 0x$maskHex"

            # Decode which CPUs
            $cpuList = @()
            for ($byte = 0; $byte -lt $maskVal.Length; $byte++) {
                for ($bit = 0; $bit -lt 8; $bit++) {
                    if ($maskVal[$byte] -band (1 -shl $bit)) {
                        $cpuList += ($byte * 8 + $bit)
                    }
                }
            }
            if ($cpuList.Count -gt 0) {
                Write-Host "    CPUs: $($cpuList -join ', ')"
            }
        } else {
            Write-Host "    Affinity Mask: Not set (OS default)" -ForegroundColor Red
        }
    } else {
        Write-Host "    Affinity Policy: NOT CONFIGURED (OS default)" -ForegroundColor Red
    }

    if (Test-Path $msiPath) {
        $msiProps = Get-ItemProperty $msiPath -ErrorAction SilentlyContinue
        Write-Host "    MSI Supported: $($msiProps.MSISupported)"
        if ($msiProps.MessageNumberLimit) {
            Write-Host "    Message Limit: $($msiProps.MessageNumberLimit)"
        }
    }
    Write-Host ""
}

# ============================================================
# Apply affinity fixes
# ============================================================

if ($Apply) {
    Write-Host "=== APPLYING AFFINITY FIXES ===" -ForegroundColor Yellow

    # Backup first
    $backupFile = "C:\Users\L\Desktop\windows-latency-optimizer\captures\backup_pre_affinity_$(Get-Date -Format 'yyyyMMdd_HHmmss').reg"
    Write-Host "  Creating backup..." -ForegroundColor Gray

    $backupCommands = @()

    foreach ($entry in $allDevices) {
        $dev = $entry.Device
        $mask = $entry.Mask
        $policy = $entry.Policy
        $regBase = "HKLM:\SYSTEM\CurrentControlSet\Enum\" + $dev.DeviceID

        $affinityPath = "$regBase\Device Parameters\Interrupt Management\Affinity Policy"
        $msiPath = "$regBase\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"

        Write-Host ""
        Write-Host "  Configuring $($entry.Type): $($dev.Name)" -ForegroundColor Green

        # Create registry paths if they don't exist
        $intMgmtPath = "$regBase\Device Parameters\Interrupt Management"
        if (-not (Test-Path $intMgmtPath)) {
            New-Item -Path $intMgmtPath -Force | Out-Null
            Write-Host "    Created: Interrupt Management key"
        }

        if (-not (Test-Path $affinityPath)) {
            New-Item -Path $affinityPath -Force | Out-Null
            Write-Host "    Created: Affinity Policy key"
        }

        # Set DevicePolicy = 4 (IrqPolicySpreadMessagesAcrossAllProcessors with mask override)
        # Actually, for specific CPU targeting, use DevicePolicy = 3 (Specified Processors)
        # with AssignmentSetOverride = the CPU mask
        Set-ItemProperty -Path $affinityPath -Name 'DevicePolicy' -Value 3 -Type DWord
        Write-Host "    DevicePolicy -> 3 (Specified Processors)"

        # Set the CPU affinity mask
        Set-ItemProperty -Path $affinityPath -Name 'AssignmentSetOverride' -Value $mask -Type Binary
        $maskHex = [BitConverter]::ToString($mask) -replace '-',''
        Write-Host "    AssignmentSetOverride -> 0x$maskHex"

        # Decode target CPUs for display
        $cpuList = @()
        for ($byte = 0; $byte -lt $mask.Length; $byte++) {
            for ($bit = 0; $bit -lt 8; $bit++) {
                if ($mask[$byte] -band (1 -shl $bit)) {
                    $cpuList += ($byte * 8 + $bit)
                }
            }
        }
        Write-Host "    Target CPUs: $($cpuList -join ', ')" -ForegroundColor Cyan

        # Enable MSI mode if available
        if (Test-Path $msiPath) {
            Set-ItemProperty -Path $msiPath -Name 'MSISupported' -Value 1 -Type DWord
            Write-Host "    MSI Mode -> Enabled"
        }

        $backupCommands += "# Revert $($entry.Type): Remove-ItemProperty -Path '$affinityPath' -Name 'DevicePolicy'; Remove-ItemProperty -Path '$affinityPath' -Name 'AssignmentSetOverride'"
    }

    # Save backup/rollback commands
    $backupContent = @"
# Interrupt Affinity Rollback Commands
# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# Run as Administrator to revert all affinity changes

$($backupCommands -join "`n")

# After reverting, reboot to apply changes.
"@
    $backupContent | Out-File -FilePath $backupFile -Encoding UTF8
    Write-Host ""
    Write-Host "  Rollback saved to: $backupFile" -ForegroundColor Gray

    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Green
    Write-Host "  AFFINITY CHANGES APPLIED!" -ForegroundColor Green
    Write-Host "  A REBOOT is required for changes to take effect." -ForegroundColor Yellow
    Write-Host "  ============================================" -ForegroundColor Green
}

# ============================================================
# Kill Razer (optional)
# ============================================================

if ($KillRazer) {
    Write-Host ""
    Write-Host "=== KILLING RAZER PROCESSES ===" -ForegroundColor Yellow

    $razerProcs = Get-Process | Where-Object {
        $_.ProcessName -match 'Razer|Synapse|rzdevice|GameManager'
    }

    if ($razerProcs) {
        foreach ($p in $razerProcs) {
            try {
                Stop-Process -Id $p.Id -Force -ErrorAction Stop
                Write-Host "  Killed: $($p.ProcessName) (PID: $($p.Id))" -ForegroundColor Green
            } catch {
                Write-Host "  Failed to kill: $($p.ProcessName) (PID: $($p.Id)) - $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    } else {
        Write-Host "  No Razer processes found." -ForegroundColor Gray
    }

    # Also stop the Razer services
    $razerServices = Get-Service | Where-Object {
        $_.Name -match 'Razer|rzdevice'
    }
    foreach ($svc in $razerServices) {
        try {
            Stop-Service -Name $svc.Name -Force -ErrorAction Stop
            Write-Host "  Stopped service: $($svc.Name)" -ForegroundColor Green
        } catch {
            Write-Host "  Failed to stop: $($svc.Name) - $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    Write-Host ""
}

# ============================================================
# Revert
# ============================================================

if ($Revert) {
    Write-Host "=== REVERTING AFFINITY CHANGES ===" -ForegroundColor Yellow

    foreach ($entry in $allDevices) {
        $dev = $entry.Device
        $regBase = "HKLM:\SYSTEM\CurrentControlSet\Enum\" + $dev.DeviceID
        $affinityPath = "$regBase\Device Parameters\Interrupt Management\Affinity Policy"

        if (Test-Path $affinityPath) {
            Remove-ItemProperty -Path $affinityPath -Name 'DevicePolicy' -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $affinityPath -Name 'AssignmentSetOverride' -ErrorAction SilentlyContinue
            Write-Host "  Reverted: $($entry.Type) - $($dev.Name)" -ForegroundColor Green
        }
    }

    Write-Host ""
    Write-Host "  Reboot required to apply revert." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  COMPLETE" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
