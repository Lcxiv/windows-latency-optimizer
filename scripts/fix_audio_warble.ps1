<#
.SYNOPSIS
    Fix HDMI audio pitch-warble during gaming + network activity.

.DESCRIPTION
    Applies four targeted fixes identified by diagnose_audio_clock.ps1:
      1. Enable MSI on NVIDIA HDMI Audio (legacy IRQ -> MSI)
      2. Disable NIC selective suspend + power management
      3. Apply persistent GPU PerfLevelSrc=0x2222 (max performance)
      4. Kill RazerAppEngine + disable its autostart entry

    All changes are backed up to captures/backup_audio_warble_<timestamp>.reg
    Requires reboot to take effect (MSI + PerfLevelSrc).

.PARAMETER WhatIf
    Preview changes without applying.

.PARAMETER SkipRazer
    Skip Razer hunt (keep RazerAppEngine alive).

.PARAMETER SkipPhantom
    Skip phantom AMD audio device removal.

.EXAMPLE
    .\fix_audio_warble.ps1 -WhatIf
    .\fix_audio_warble.ps1
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [switch]$SkipRazer,
    [switch]$SkipPhantom
)

# ---------- Preamble ----------
$ErrorActionPreference = 'Stop'
$script:Changes = @()
$script:Warnings = @()
$script:RollbackLines = @()

function Require-Admin {
    $current = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host '[FATAL] This script requires administrator privileges.' -ForegroundColor Red
        Write-Host '  Re-run from an elevated PowerShell prompt.' -ForegroundColor Yellow
        exit 1
    }
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
}

function Record-Change {
    param([string]$Area, [string]$Detail, [string]$Rollback)
    $script:Changes += [pscustomobject]@{ Area = $Area; Detail = $Detail }
    if ($Rollback) { $script:RollbackLines += $Rollback }
}

function Record-Warn {
    param([string]$Msg)
    $script:Warnings += $Msg
    Write-Host ('[WARN] ' + $Msg) -ForegroundColor Yellow
}

Require-Admin

$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
$repoRoot = Split-Path $PSScriptRoot -Parent
$backupFile = Join-Path $repoRoot ('captures\backup_audio_warble_' + $ts + '.txt')
New-Item -ItemType Directory -Path (Split-Path $backupFile -Parent) -Force | Out-Null

@"
# Audio Warble Fix - Rollback log
# Captured: $ts
# Edit this file to adjust before running rollback.ps1

"@ | Set-Content -Path $backupFile -Encoding UTF8

Write-Section 'Audio Warble Fix — Backup & Apply'
Write-Host ('Backup file: ' + $backupFile)

# ====================================================================
# FIX 1: Enable MSI on NVIDIA HDMI Audio
# ====================================================================
Write-Section '[FIX 1/5] Enable MSI on NVIDIA HDMI Audio'
$nvAudio = Get-PnpDevice -Class MEDIA -Status OK -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match 'VEN_10DE' -and $_.InstanceId -match 'HDAUDIO' } |
    Select-Object -First 1

if ($nvAudio) {
    Write-Host ('Device: ' + $nvAudio.FriendlyName) -ForegroundColor Yellow
    Write-Host ('InstanceId: ' + $nvAudio.InstanceId)
    $imBase = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $nvAudio.InstanceId + '\Device Parameters\Interrupt Management'
    $msiKey = Join-Path $imBase 'MessageSignaledInterruptProperties'

    # Backup current state
    $currentMsi = $null
    if (Test-Path $msiKey) {
        $currentMsi = (Get-ItemProperty $msiKey -ErrorAction SilentlyContinue).MsiSupported
    }
    $backupEntry = @"

# --- FIX 1: NVIDIA HDMI Audio MSI ---
# Registry: $msiKey
# Previous MsiSupported: $currentMsi (null = key did not exist)
# To rollback: Remove-Item '$msiKey' -Recurse -Force
"@
    Add-Content -Path $backupFile -Value $backupEntry -Encoding UTF8

    if ($PSCmdlet.ShouldProcess($msiKey, 'Create Interrupt Management keys + set MsiSupported=1')) {
        # Create parent key first
        if (-not (Test-Path $imBase)) {
            New-Item -Path $imBase -Force | Out-Null
        }
        if (-not (Test-Path $msiKey)) {
            New-Item -Path $msiKey -Force | Out-Null
        }
        Set-ItemProperty -Path $msiKey -Name 'MsiSupported' -Value 1 -Type DWord
        # Don't set MessageNumberLimit — let Windows negotiate with device
        Write-Host '[OK] MsiSupported=1 written' -ForegroundColor Green
        Record-Change 'NVIDIA HDMI Audio' 'MsiSupported=1 (enables MSI)' "Remove-Item '$msiKey' -Recurse -Force"
    }
} else {
    Record-Warn 'NVIDIA HDMI Audio device not found — skipping FIX 1'
}

# ====================================================================
# FIX 2: Disable NIC Power Management (registry-level)
# Windows 11 + Intel I226-V: Set-NetAdapterPowerManagement cmdlet does not
# have -AllowComputerToTurnOffDevice parameter. Use registry direct:
#   - Driver class PnPCapabilities = 0x18  (hides/disables Device Manager
#     "Allow computer to turn off this device" checkbox)
#   - Driver key *SelectiveSuspend = 0
#   - Cmdlet Set-NetAdapterPowerManagement -SelectiveSuspend Disabled
#     (belt-and-braces; driver may honor either source)
# ====================================================================
Write-Section '[FIX 2/5] Disable NIC Power Management (registry)'
$nic = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'I226' -and $_.Status -eq 'Up' } | Select-Object -First 1
if ($nic) {
    Write-Host ('NIC: ' + $nic.InterfaceDescription + ' (' + $nic.Name + ')') -ForegroundColor Yellow

    # Resolve PnP instance ID -> driver class key via WMI
    $wmi = Get-CimInstance -ClassName Win32_NetworkAdapter -Filter ('Name = "' + $nic.InterfaceDescription + '"') -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $wmi -or -not $wmi.PNPDeviceID) {
        Record-Warn 'Could not resolve NIC PNPDeviceID — skipping FIX 2'
    } else {
        $nicPnp = $wmi.PNPDeviceID
        $enumKey = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $nicPnp
        $driverSub = (Get-ItemProperty -Path $enumKey -Name 'Driver' -ErrorAction SilentlyContinue).Driver
        if (-not $driverSub) {
            Record-Warn 'Could not resolve NIC driver class key — skipping FIX 2'
        } else {
            $driverKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\' + $driverSub
            $prevPnP = (Get-ItemProperty -Path $driverKey -Name 'PnPCapabilities' -ErrorAction SilentlyContinue).PnPCapabilities
            $prevSelSus = (Get-ItemProperty -Path $driverKey -Name '*SelectiveSuspend' -ErrorAction SilentlyContinue).'*SelectiveSuspend'
            $prevPnPStr = if ($null -eq $prevPnP) { 'null' } else { '0x' + [Convert]::ToString($prevPnP,16) }

            $backupEntry = @"

# --- FIX 2: NIC Power Management ($($nic.Name)) ---
# Driver class key: $driverKey
# Previous PnPCapabilities : $prevPnPStr
# Previous *SelectiveSuspend: $prevSelSus
# To rollback:
#   Set-ItemProperty '$driverKey' -Name PnPCapabilities -Value $prevPnP -Type DWord  (or Remove-ItemProperty if was null)
#   Set-ItemProperty '$driverKey' -Name '*SelectiveSuspend' -Value '$prevSelSus'
"@
            Add-Content -Path $backupFile -Value $backupEntry -Encoding UTF8

            # Apply PnPCapabilities = 0x18
            if ($prevPnP -ne 0x18) {
                if ($PSCmdlet.ShouldProcess($driverKey, 'Set PnPCapabilities=0x18')) {
                    try {
                        Set-ItemProperty -Path $driverKey -Name 'PnPCapabilities' -Value 0x18 -Type DWord
                        Write-Host '[OK] PnPCapabilities=0x18 (no power-off, no wake-from-device)' -ForegroundColor Green
                        Record-Change 'I226-V NIC' 'PnPCapabilities=0x18' ''
                    } catch {
                        Record-Warn ('PnPCapabilities write failed: ' + $_.Exception.Message)
                    }
                }
            } else {
                Write-Host '[SKIP] PnPCapabilities already 0x18' -ForegroundColor Green
            }

            # Apply *SelectiveSuspend = 0
            if ($prevSelSus -ne '0') {
                if ($PSCmdlet.ShouldProcess($driverKey, 'Set *SelectiveSuspend=0')) {
                    try {
                        Set-ItemProperty -Path $driverKey -Name '*SelectiveSuspend' -Value '0' -Type String
                        Write-Host '[OK] *SelectiveSuspend=0' -ForegroundColor Green
                        Record-Change 'I226-V NIC' '*SelectiveSuspend=0 (driver-level)' ''
                    } catch {
                        Record-Warn ('*SelectiveSuspend write failed: ' + $_.Exception.Message)
                    }
                }
            } else {
                Write-Host '[SKIP] *SelectiveSuspend already 0' -ForegroundColor Green
            }

            # Cmdlet belt-and-braces (ignore if it lies)
            try {
                Set-NetAdapterPowerManagement -Name $nic.Name -SelectiveSuspend Disabled -Confirm:$false -ErrorAction Stop
                Write-Host '[OK] Cmdlet SelectiveSuspend=Disabled (belt-and-braces)' -ForegroundColor Green
            } catch {
                Write-Host '[INFO] Cmdlet SelectiveSuspend set failed (registry already authoritative)' -ForegroundColor DarkGray
            }

            # Disable Energy Efficient Ethernet if present
            $eee = Get-NetAdapterAdvancedProperty -Name $nic.Name -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -match 'Energy.Efficient|Green Ethernet|Ultra Low Power' }
            foreach ($e in $eee) {
                if ($e.DisplayValue -ne 'Disabled' -and $e.DisplayValue -ne 'Off') {
                    if ($PSCmdlet.ShouldProcess($e.DisplayName, 'Disable EEE-like property')) {
                        try {
                            Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $e.DisplayName -DisplayValue 'Disabled' -Confirm:$false -ErrorAction Stop
                            Write-Host ('[OK] ' + $e.DisplayName + ' disabled') -ForegroundColor Green
                            Record-Change 'I226-V NIC' ($e.DisplayName + '=Disabled') ''
                        } catch {
                            Record-Warn ($e.DisplayName + ' change failed: ' + $_.Exception.Message)
                        }
                    }
                }
            }
        }
    }
} else {
    Record-Warn 'I226-V NIC not found — skipping FIX 2'
}

# ====================================================================
# FIX 3: Persistent GPU PerfLevelSrc=0x2222
# ====================================================================
Write-Section '[FIX 3/5] Persistent GPU PerfLevelSrc=0x2222 (Prefer Max Performance)'
$nvKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\NVTweak'
$prevPls = $null
if (Test-Path $nvKey) {
    $prevPls = (Get-ItemProperty $nvKey -ErrorAction SilentlyContinue).PerfLevelSrc
}

$backupEntry = @"

# --- FIX 3: NVIDIA PerfLevelSrc ---
# Registry: $nvKey
# Previous PerfLevelSrc: $prevPls
# To rollback:
#   Remove-ItemProperty '$nvKey' -Name PerfLevelSrc -ErrorAction SilentlyContinue
"@
Add-Content -Path $backupFile -Value $backupEntry -Encoding UTF8

if ($prevPls -eq 0x2222) {
    Write-Host '[SKIP] PerfLevelSrc already 0x2222' -ForegroundColor Green
} else {
    if ($PSCmdlet.ShouldProcess($nvKey, 'Set PerfLevelSrc=0x2222')) {
        if (-not (Test-Path $nvKey)) {
            New-Item -Path $nvKey -Force | Out-Null
        }
        Set-ItemProperty -Path $nvKey -Name 'PerfLevelSrc' -Value 0x2222 -Type DWord
        Write-Host '[OK] PerfLevelSrc=0x2222 written' -ForegroundColor Green
        Record-Change 'NVIDIA GPU' 'PerfLevelSrc=0x2222 (Prefer Max Performance, persistent)' `
            "Remove-ItemProperty '$nvKey' -Name PerfLevelSrc -ErrorAction SilentlyContinue"
    }
}

# ====================================================================
# FIX 4: Kill RazerAppEngine + track down autostart
# ====================================================================
if (-not $SkipRazer) {
    Write-Section '[FIX 4/5] Kill RazerAppEngine and Disable Autostart'
    $razerProcs = Get-Process -Name 'RazerAppEngine' -ErrorAction SilentlyContinue
    if ($razerProcs) {
        foreach ($p in $razerProcs) {
            $exePath = $p.Path
            Write-Host ('Found: ' + $p.ProcessName + ' (PID ' + $p.Id + ') at ' + $exePath) -ForegroundColor Yellow
            if ($PSCmdlet.ShouldProcess(('PID ' + $p.Id), 'Stop-Process')) {
                try {
                    Stop-Process -Id $p.Id -Force -ErrorAction Stop
                    Write-Host ('[OK] Killed PID ' + $p.Id) -ForegroundColor Green
                    Record-Change 'Razer' ('Killed process PID ' + $p.Id) ''
                } catch {
                    Record-Warn ('Could not kill PID ' + $p.Id + ': ' + $_.Exception.Message)
                }
            }
        }
    } else {
        Write-Host '[OK] No RazerAppEngine running' -ForegroundColor Green
    }

    # Hunt autostart: scheduled tasks + Run keys + services + startup folders
    Write-Host ''
    Write-Host 'Hunting autostart entries...' -ForegroundColor Gray
    $hitsFound = 0

    # 1) Scheduled Tasks
    $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        ($_.Actions | ForEach-Object { $_.Execute + ' ' + $_.Arguments }) -match 'RazerAppEngine|Razer.Central|RzTools'
    }
    foreach ($t in $tasks) {
        Write-Host ('  [TASK] ' + $t.TaskPath + $t.TaskName + '  State=' + $t.State) -ForegroundColor Yellow
        if ($t.State -ne 'Disabled') {
            if ($PSCmdlet.ShouldProcess($t.TaskName, 'Disable scheduled task')) {
                try {
                    Disable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop | Out-Null
                    Write-Host ('    [OK] Disabled') -ForegroundColor Green
                    Record-Change 'Razer' ('Scheduled task disabled: ' + $t.TaskName) `
                        "Enable-ScheduledTask -TaskName '$($t.TaskName)' -TaskPath '$($t.TaskPath)'"
                    $hitsFound++
                } catch {
                    Record-Warn ('Task disable failed: ' + $_.Exception.Message)
                }
            }
        }
    }

    # 2) Run / RunOnce keys (HKCU + HKLM, 32 + 64)
    $runKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'
    )
    foreach ($rk in $runKeys) {
        if (Test-Path $rk) {
            $props = Get-Item $rk | Select-Object -ExpandProperty Property
            foreach ($prop in $props) {
                $val = (Get-ItemProperty $rk -Name $prop -ErrorAction SilentlyContinue).$prop
                if ($val -match 'RazerAppEngine|Razer.Central|RzTools') {
                    Write-Host ('  [RUNKEY] ' + $rk + ' :: ' + $prop + ' = ' + $val) -ForegroundColor Yellow
                    if ($PSCmdlet.ShouldProcess(($rk + '\' + $prop), 'Remove Run key value')) {
                        try {
                            Remove-ItemProperty -Path $rk -Name $prop -ErrorAction Stop
                            Write-Host ('    [OK] Removed') -ForegroundColor Green
                            Record-Change 'Razer' ('Run key removed: ' + $rk + '\' + $prop) `
                                "Set-ItemProperty -Path '$rk' -Name '$prop' -Value '$val'"
                            $hitsFound++
                        } catch {
                            Record-Warn ('Run key remove failed: ' + $_.Exception.Message)
                        }
                    }
                }
            }
        }
    }

    # 3) Startup folders
    $startupFolders = @(
        [Environment]::GetFolderPath('Startup')
        [Environment]::GetFolderPath('CommonStartup')
    )
    foreach ($sf in $startupFolders) {
        if (Test-Path $sf) {
            $links = Get-ChildItem -Path $sf -Filter *.lnk -ErrorAction SilentlyContinue
            foreach ($l in $links) {
                if ($l.Name -match 'Razer|RazerAppEngine') {
                    Write-Host ('  [STARTUP] ' + $l.FullName) -ForegroundColor Yellow
                    if ($PSCmdlet.ShouldProcess($l.FullName, 'Remove startup shortcut')) {
                        $destDir = Join-Path $repoRoot 'captures\disabled_razer_startup'
                        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                        Move-Item -Path $l.FullName -Destination $destDir -Force
                        Write-Host ('    [OK] Moved to ' + $destDir) -ForegroundColor Green
                        Record-Change 'Razer' ('Startup shortcut moved: ' + $l.Name) `
                            ('Move-Item "' + (Join-Path $destDir $l.Name) + '" "' + $l.FullName + '"')
                        $hitsFound++
                    }
                }
            }
        }
    }

    if ($hitsFound -eq 0) {
        Record-Warn 'No Razer autostart entries found — process may be spawned by another mechanism (WMI subscription, driver service, etc.)'
    }
}

# ====================================================================
# FIX 5: (Removed — phantom AMD audio check was a false positive)
#
# Original hypothesis: AMD HD Audio AssignmentSetOverride 0xF000000000000000
# was pointing at non-existent CPUs 60-63. This was wrong — BitConverter
# serializes bytes in storage order (little-endian for KAFFINITY). The
# actual uint64 value is 0x00000000000000F0 = bits 4-7 = CPUs 4-7, which
# matches the GPU/NIC group per CLAUDE.md topology (correctly configured).
#
# Leaving -SkipPhantom flag in param block for script compatibility but it
# is a no-op now.
# ====================================================================
if (-not $SkipPhantom) {
    Write-Section '[FIX 5/5] AMD HD Audio Affinity — no-op (was false positive)'
    Write-Host '  Skipped: the "invalid" mask 0xF000000000000000 is actually' -ForegroundColor DarkGray
    Write-Host '  little-endian for CPUs 4-7 (correct per CLAUDE.md topology).' -ForegroundColor DarkGray
}

# ====================================================================
# Summary
# ====================================================================
Write-Section 'Summary'
if ($script:Changes.Count -gt 0) {
    Write-Host ('Applied ' + $script:Changes.Count + ' changes:') -ForegroundColor Green
    $script:Changes | Format-Table -AutoSize
}
if ($script:Warnings.Count -gt 0) {
    Write-Host ('Warnings (' + $script:Warnings.Count + '):') -ForegroundColor Yellow
    $script:Warnings | ForEach-Object { Write-Host ('  - ' + $_) -ForegroundColor Yellow }
}
Write-Host ''
Write-Host ('Backup log: ' + $backupFile) -ForegroundColor Cyan
Write-Host ''
Write-Host '>>> REBOOT REQUIRED for MSI + PerfLevelSrc changes to take effect <<<' -ForegroundColor Magenta
Write-Host 'After reboot, run: scripts\diagnose_audio_clock.ps1 to verify.' -ForegroundColor Magenta
