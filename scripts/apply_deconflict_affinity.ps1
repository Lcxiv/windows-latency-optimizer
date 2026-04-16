<#
.SYNOPSIS
    Deconflict GPU / NIC / HDMI audio interrupts across CPUs 4-7.

.DESCRIPTION
    Target topology (per CLAUDE.md + audio warble root cause analysis):
      CPUs 4-5 : GPU exclusive   (mask 0x30) - heavy DPC work
      CPUs 6-7 : NIC + HDMI audio (mask 0xC0) - light interrupt work
      CPUs 2-3 : Input devices   (unchanged)
      CPU 0    : Preferred (idle)
      CPUs 8-15: Game threads    (unchanged)

    Changes applied:
      A. NVIDIA HDMI Audio : set DevicePolicy=3 + mask 0xC0 (CPUs 6-7)
      B. I226-V NIC        : change from mask 0x30 -> mask 0xC0
      C. AMD HD Audio      : disable device (unused legacy-IRQ contender)

    All prior values backed up to captures/backup_deconflict_<ts>.txt.
    HDMI audio + NIC changes take effect after reboot (affinity policy
    re-reads on device init). AMD Audio disable is immediate.

.PARAMETER WhatIf
    Preview without applying.

.PARAMETER SkipAmd
    Skip AMD HD Audio device disable.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [switch]$SkipAmd
)

$ErrorActionPreference = 'Stop'
$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
$repoRoot = Split-Path $PSScriptRoot -Parent
$backupFile = Join-Path $repoRoot ('captures\backup_deconflict_' + $ts + '.txt')
New-Item -ItemType Directory -Path (Split-Path $backupFile -Parent) -Force | Out-Null

# Admin check
$current = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '[FATAL] Run as Administrator' -ForegroundColor Red; exit 1
}

function Write-Section { param($t) Write-Host ''; Write-Host ('=' * 70) -ForegroundColor DarkCyan; Write-Host $t -ForegroundColor Cyan; Write-Host ('=' * 70) -ForegroundColor DarkCyan }

function Get-MaskBytes {
    param([uint64]$mask)
    return [BitConverter]::GetBytes($mask)
}

function Get-CurrentAffinity {
    param([string]$InstanceId)
    $k = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $InstanceId + '\Device Parameters\Interrupt Management\Affinity Policy'
    if (Test-Path $k) {
        $a = Get-ItemProperty $k -ErrorAction SilentlyContinue
        return @{ Policy = $a.DevicePolicy; Bytes = $a.AssignmentSetOverride; Exists = $true }
    }
    return @{ Policy = $null; Bytes = $null; Exists = $false }
}

function Set-DeviceAffinity {
    param(
        [string]$InstanceId,
        [string]$Label,
        [int]$Policy = 3,          # 3 = Specified Processors
        [uint64]$Mask
    )
    $imBase = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $InstanceId + '\Device Parameters\Interrupt Management'
    $k = Join-Path $imBase 'Affinity Policy'
    if (-not (Test-Path $imBase)) { New-Item -Path $imBase -Force | Out-Null }
    if (-not (Test-Path $k))      { New-Item -Path $k -Force | Out-Null }
    $bytes = Get-MaskBytes $Mask
    Set-ItemProperty -Path $k -Name 'DevicePolicy' -Value $Policy -Type DWord
    Set-ItemProperty -Path $k -Name 'AssignmentSetOverride' -Value $bytes -Type Binary
    Write-Host ('[OK] ' + $Label + ' -> Policy=' + $Policy + ', mask 0x' + ('{0:X}' -f $Mask)) -ForegroundColor Green
}

# ---------- Header ----------
Write-Section 'Apply Deconflict Affinity (target: GPU on 4-5, NIC+HDMI audio on 6-7)'
@"
# Deconflict Affinity Backup
# Timestamp: $ts
# Target:
#   NVIDIA HDMI Audio : DevicePolicy=3, mask 0xC0 (CPUs 6-7)
#   I226-V NIC        : DevicePolicy=3, mask 0xC0 (CPUs 6-7)
#   AMD HD Audio      : device disabled

"@ | Set-Content -Path $backupFile -Encoding UTF8

Write-Host ('Backup: ' + $backupFile) -ForegroundColor Gray

# ====================================================================
# CHANGE A: NVIDIA HDMI Audio -> CPUs 6-7
# ====================================================================
Write-Section '[A/3] NVIDIA HDMI Audio -> CPUs 6-7 (mask 0xC0)'
$nvAudio = Get-PnpDevice -Class MEDIA -Status OK -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match 'VEN_10DE' -and $_.InstanceId -match 'HDAUDIO' } |
    Select-Object -First 1
if ($nvAudio) {
    $prev = Get-CurrentAffinity $nvAudio.InstanceId
    $prevMask = if ($prev.Bytes) {
        $padded = New-Object byte[] 8
        [Array]::Copy($prev.Bytes, 0, $padded, 0, [Math]::Min($prev.Bytes.Length, 8))
        [BitConverter]::ToUInt64($padded, 0)
    } else { 0 }
    $prevStr = if ($prev.Exists) { 'Policy=' + $prev.Policy + ', mask 0x' + ('{0:X}' -f $prevMask) } else { '(no policy)' }

    Add-Content -Path $backupFile -Value "# CHANGE A: NVIDIA HDMI Audio`n# InstanceId: $($nvAudio.InstanceId)`n# Previous: $prevStr`n# To rollback: see backup_pre_affinity backups or re-apply original mask" -Encoding UTF8

    Write-Host ('Device: ' + $nvAudio.FriendlyName) -ForegroundColor Yellow
    Write-Host ('Previous: ' + $prevStr) -ForegroundColor Gray
    if ($PSCmdlet.ShouldProcess($nvAudio.InstanceId, 'Set HDMI audio affinity to mask 0xC0')) {
        Set-DeviceAffinity -InstanceId $nvAudio.InstanceId -Label 'NVIDIA HDMI Audio' -Policy 3 -Mask 0xC0
    }
} else {
    Write-Host '[SKIP] NVIDIA HDMI Audio not found' -ForegroundColor Yellow
}

# ====================================================================
# CHANGE B: I226-V NIC -> CPUs 6-7
# ====================================================================
Write-Section '[B/3] I226-V NIC -> CPUs 6-7 (mask 0xC0)'
$wmi = Get-CimInstance Win32_NetworkAdapter -Filter "NetEnabled=True" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'I226' } | Select-Object -First 1
if ($wmi -and $wmi.PNPDeviceID) {
    $prev = Get-CurrentAffinity $wmi.PNPDeviceID
    $prevMask = if ($prev.Bytes) {
        $padded = New-Object byte[] 8
        [Array]::Copy($prev.Bytes, 0, $padded, 0, [Math]::Min($prev.Bytes.Length, 8))
        [BitConverter]::ToUInt64($padded, 0)
    } else { 0 }
    $prevStr = if ($prev.Exists) { 'Policy=' + $prev.Policy + ', mask 0x' + ('{0:X}' -f $prevMask) } else { '(no policy)' }

    Add-Content -Path $backupFile -Value "`n# CHANGE B: I226-V NIC`n# InstanceId: $($wmi.PNPDeviceID)`n# Previous: $prevStr`n# To rollback: re-run fix_gpu_affinity.ps1 or edit registry" -Encoding UTF8

    Write-Host ('Device: ' + $wmi.Name) -ForegroundColor Yellow
    Write-Host ('Previous: ' + $prevStr) -ForegroundColor Gray
    if ($PSCmdlet.ShouldProcess($wmi.PNPDeviceID, 'Set NIC affinity to mask 0xC0')) {
        Set-DeviceAffinity -InstanceId $wmi.PNPDeviceID -Label 'I226-V NIC' -Policy 3 -Mask 0xC0
    }
} else {
    Write-Host '[SKIP] I226-V NIC not found' -ForegroundColor Yellow
}

# ====================================================================
# CHANGE C: Disable AMD HD Audio device
# ====================================================================
if (-not $SkipAmd) {
    Write-Section '[C/3] Disable Unused AMD HD Audio Device'
    $amdAudio = Get-PnpDevice -Class MEDIA -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match 'VEN_1002' -and $_.InstanceId -match 'HDAUDIO' -and $_.Status -eq 'OK' } |
        Select-Object -First 1
    if ($amdAudio) {
        Write-Host ('Device: ' + $amdAudio.FriendlyName) -ForegroundColor Yellow
        Write-Host ('InstanceId: ' + $amdAudio.InstanceId)
        Write-Host ('Status: ' + $amdAudio.Status + ' (will be disabled)')

        Add-Content -Path $backupFile -Value "`n# CHANGE C: AMD HD Audio`n# InstanceId: $($amdAudio.InstanceId)`n# To rollback: Enable-PnpDevice -InstanceId '$($amdAudio.InstanceId)' -Confirm:`$false" -Encoding UTF8

        if ($PSCmdlet.ShouldProcess($amdAudio.InstanceId, 'Disable-PnpDevice')) {
            try {
                Disable-PnpDevice -InstanceId $amdAudio.InstanceId -Confirm:$false -ErrorAction Stop
                Write-Host '[OK] AMD HD Audio disabled' -ForegroundColor Green
            } catch {
                Write-Host ('[WARN] Disable failed: ' + $_.Exception.Message) -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host '[SKIP] AMD HD Audio not found or already disabled' -ForegroundColor Green
    }
}

# ====================================================================
# Verification
# ====================================================================
Write-Section 'Verification'
function Show-After {
    param([string]$InstanceId, [string]$Label)
    $k = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $InstanceId + '\Device Parameters\Interrupt Management\Affinity Policy'
    if (Test-Path $k) {
        $a = Get-ItemProperty $k
        $mask = 0
        if ($a.AssignmentSetOverride) {
            $padded = New-Object byte[] 8
            [Array]::Copy($a.AssignmentSetOverride, 0, $padded, 0, [Math]::Min($a.AssignmentSetOverride.Length, 8))
            $mask = [BitConverter]::ToUInt64($padded, 0)
        }
        Write-Host ('  ' + $Label.PadRight(22) + ': Policy=' + $a.DevicePolicy + ', mask 0x' + ('{0:X}' -f $mask))
    } else {
        Write-Host ('  ' + $Label.PadRight(22) + ': (no affinity policy)') -ForegroundColor Yellow
    }
}
if ($nvAudio) { Show-After $nvAudio.InstanceId 'NVIDIA HDMI Audio' }
if ($wmi)     { Show-After $wmi.PNPDeviceID 'I226-V NIC' }

Write-Host ''
Write-Host 'Backup: ' $backupFile -ForegroundColor Cyan
Write-Host 'Affinity changes take effect at next reboot.' -ForegroundColor Magenta
