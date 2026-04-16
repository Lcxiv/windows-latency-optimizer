<#
.SYNOPSIS
    Analyze current IRQ affinity assignments for GPU, NIC, audio, and input
    devices to identify CPU overlap and recommend deconfliction.
#>
[CmdletBinding()]
param()

function Decode-Mask {
    param([byte[]]$bytes)
    if (-not $bytes) { return '(null)' }
    # Pad to 8 bytes then read as uint64
    $padded = New-Object byte[] 8
    [Array]::Copy($bytes, 0, $padded, 0, [Math]::Min($bytes.Length, 8))
    $u64 = [BitConverter]::ToUInt64($padded, 0)
    $cpus = @()
    $one = [uint64]1
    for ($i = 0; $i -lt 64; $i++) {
        $bit = $one -shl $i
        if (($u64 -band $bit) -ne 0) { $cpus += $i }
    }
    if ($cpus.Count -eq 0) { return '(none)' }
    return 'CPUs ' + ($cpus -join ',') + ' (mask 0x' + ('{0:X}' -f $u64) + ')'
}

function Get-DeviceAffinity {
    param([string]$InstanceId, [string]$Label)
    $k = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $InstanceId + '\Device Parameters\Interrupt Management\Affinity Policy'
    $msiK = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $InstanceId + '\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties'
    $affInfo = '(no policy)'
    $msiInfo = '(no MSI key)'
    if (Test-Path $k) {
        $a = Get-ItemProperty $k -ErrorAction SilentlyContinue
        $affInfo = 'Policy=' + $a.DevicePolicy + ' -> ' + (Decode-Mask $a.AssignmentSetOverride)
    }
    if (Test-Path $msiK) {
        $m = Get-ItemProperty $msiK -ErrorAction SilentlyContinue
        if ($null -ne $m.MsiSupported) {
            $msiInfo = 'MSI=' + $m.MsiSupported + ', vectors=' + $m.MessageNumberLimit
        }
    }
    Write-Host ('  ' + $Label.PadRight(25) + ' : ' + $affInfo) -ForegroundColor Yellow
    Write-Host ('  ' + ''.PadRight(25) + '   ' + $msiInfo) -ForegroundColor DarkGray
}

Write-Host '=== Affinity Map: GPU, NIC, Audio, Input ===' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Topology per CLAUDE.md:' -ForegroundColor Gray
Write-Host '  CPU 0       : Preferred (keep idle)'
Write-Host '  CPUs 1      : Free'
Write-Host '  CPUs 2-3    : Input devices      (mask 0x0C)'
Write-Host '  CPUs 4-7    : GPU/NIC/USB DPC    (mask 0xF0)'
Write-Host '  CPUs 8-15   : Game threads       (free)'
Write-Host ''

# GPU
$gpu = Get-PnpDevice -Class Display -Status OK | Where-Object { $_.InstanceId -match 'VEN_10DE' } | Select-Object -First 1
if ($gpu) { Get-DeviceAffinity $gpu.InstanceId 'GPU (nvlddmkm)' }

# NIC
$wmi = Get-CimInstance Win32_NetworkAdapter -Filter "NetEnabled=True" | Where-Object { $_.Name -match 'I226' } | Select-Object -First 1
if ($wmi) { Get-DeviceAffinity $wmi.PNPDeviceID 'NIC (I226-V)' }

# NVIDIA HDMI Audio
$nvAudio = Get-PnpDevice -Class MEDIA -Status OK | Where-Object { $_.InstanceId -match 'VEN_10DE' -and $_.InstanceId -match 'HDAUDIO' } | Select-Object -First 1
if ($nvAudio) { Get-DeviceAffinity $nvAudio.InstanceId 'NVIDIA HDMI Audio' }

# Other HD Audio (AMD etc.)
$otherAudio = Get-PnpDevice -Class MEDIA -Status OK | Where-Object { $_.InstanceId -match 'HDAUDIO' -and $_.InstanceId -notmatch 'VEN_10DE' }
foreach ($a in $otherAudio) {
    $vendor = if ($a.InstanceId -match 'VEN_1002') { 'AMD Audio' } elseif ($a.InstanceId -match 'VEN_10EC') { 'Realtek' } else { 'Other HD Audio' }
    Get-DeviceAffinity $a.InstanceId $vendor
}

# USB root hubs (for keyboard/mouse input path)
$usbHubs = Get-PnpDevice -Class USB -Status OK | Where-Object { $_.FriendlyName -match 'Root Hub|USB 3\.' } | Select-Object -First 3
foreach ($h in $usbHubs) {
    Get-DeviceAffinity $h.InstanceId ('USB: ' + ($h.FriendlyName -replace '\(.*\)',''))
}

# Summary: who overlaps with whom
Write-Host ''
Write-Host '=== Overlap Analysis ===' -ForegroundColor Cyan
function Get-MaskFromDevice {
    param([string]$InstanceId)
    $k = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $InstanceId + '\Device Parameters\Interrupt Management\Affinity Policy'
    if (Test-Path $k) {
        $bytes = (Get-ItemProperty $k -ErrorAction SilentlyContinue).AssignmentSetOverride
        if ($bytes) {
            $padded = New-Object byte[] 8
            [Array]::Copy($bytes, 0, $padded, 0, [Math]::Min($bytes.Length, 8))
            return [BitConverter]::ToUInt64($padded, 0)
        }
    }
    return 0
}

$gpuMask = if ($gpu) { Get-MaskFromDevice $gpu.InstanceId } else { 0 }
$nicMask = if ($wmi) { Get-MaskFromDevice $wmi.PNPDeviceID } else { 0 }
$overlap = $gpuMask -band $nicMask
Write-Host ('GPU mask    : 0x' + ('{0:X}' -f $gpuMask))
Write-Host ('NIC mask    : 0x' + ('{0:X}' -f $nicMask))
Write-Host ('Overlap     : 0x' + ('{0:X}' -f $overlap) + ' -> ' + (Decode-Mask ([BitConverter]::GetBytes([uint64]$overlap))))

if ($overlap -ne 0) {
    Write-Host ''
    Write-Host '[CONCERN] GPU and NIC share CPUs.' -ForegroundColor Yellow
    Write-Host 'Under combined gaming + network load, those CPUs process BOTH GPU DPCs' -ForegroundColor Gray
    Write-Host 'AND NIC ISRs concurrently, which can queue up DPCs and add latency.' -ForegroundColor Gray
}

# Per-CPU load from latest capture
Write-Host ''
Write-Host '=== Per-CPU DPC/Interrupt Load (latest capture) ===' -ForegroundColor Cyan
$latest = Get-ChildItem 'captures\experiments' -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latest) {
    Write-Host ('Source: ' + $latest.Name) -ForegroundColor Gray
    $analysis = Join-Path $latest.FullName 'analysis.txt'
    if (Test-Path $analysis) {
        $lines = Get-Content $analysis
        $inPerCpu = $false
        foreach ($l in $lines) {
            if ($l -match '^--- Per-CPU') { $inPerCpu = $true; Write-Host $l -ForegroundColor DarkGray; continue }
            if ($inPerCpu -and $l -match '^---') { break }
            if ($inPerCpu -and $l -match 'CPU\d+') { Write-Host $l }
        }
    }
}
