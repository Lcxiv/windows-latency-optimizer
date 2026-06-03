<#
.SYNOPSIS
    GPU Interrupt Affinity Guard — runs at startup to ensure GPU DPC stays off CPU 0.

.DESCRIPTION
    NVIDIA drivers can reset interrupt affinity during driver updates, power transitions,
    and device re-enumeration. This script re-applies the optimal affinity configuration
    to the correct Device Parameters registry path on every boot.

    Targets: RTX 5070 Ti (VEN_10DE&DEV_2C05)
    Affinity: CPUs 4-7 (mask 0xF0) — keeps CPU 0 free for game threads

.NOTES
    Registered as scheduled task 'GPU_Affinity_Guard' running as SYSTEM at startup.
    Log output: C:\Users\L\Desktop\windows-latency-optimizer\captures\affinity_guard.log
#>

$ErrorActionPreference = 'Stop'
$logPath = 'C:\Users\L\Desktop\windows-latency-optimizer\captures\affinity_guard.log'

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] $Message"
    Add-Content -Path $logPath -Value $line -ErrorAction SilentlyContinue
    Write-Output $line
}

try {
    Write-Log '=== GPU Affinity Guard starting ==='

    # Find RTX 5070 Ti
    $gpuEnum = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like 'VEN_10DE&DEV_2C05*' }

    if (-not $gpuEnum) {
        Write-Log 'ERROR: No VEN_10DE&DEV_2C05 device found'
        exit 1
    }

    $gpuInst = Get-ChildItem $gpuEnum.PSPath -ErrorAction SilentlyContinue | Select-Object -First 1
    $affPolicy = Join-Path $gpuInst.PSPath 'Device Parameters\Interrupt Management\Affinity Policy'
    $msiPath = Join-Path $gpuInst.PSPath 'Device Parameters\Interrupt Management\MessageSignaledInterruptProperties'

    # --- Affinity Policy ---
    if (-not (Test-Path $affPolicy)) {
        New-Item -Path $affPolicy -Force | Out-Null
        Write-Log 'Created Affinity Policy key (was missing)'
    }

    $currentPolicy = $null
    $currentMask = $null
    try { $currentPolicy = (Get-ItemProperty $affPolicy -Name DevicePolicy -ErrorAction Stop).DevicePolicy } catch {}
    try { $currentMask = (Get-ItemProperty $affPolicy -Name AssignmentSetOverride -ErrorAction Stop).AssignmentSetOverride } catch {}

    $needsUpdate = $false
    if ($currentPolicy -ne 4) {
        Write-Log ('DevicePolicy is ' + $currentPolicy + ' (want 4) - fixing')
        $needsUpdate = $true
    }
    if (-not $currentMask -or $currentMask[0] -ne 0xF0) {
        $maskStr = if ($currentMask) { '0x' + [BitConverter]::ToString($currentMask).Replace('-','') } else { 'NULL' }
        Write-Log ('AssignmentSetOverride is ' + $maskStr + ' (want 0xF0) - fixing')
        $needsUpdate = $true
    }

    if ($needsUpdate) {
        Set-ItemProperty -Path $affPolicy -Name DevicePolicy -Value 4 -Type DWord
        Set-ItemProperty -Path $affPolicy -Name AssignmentSetOverride -Value ([byte[]](0xF0,0,0,0,0,0,0,0)) -Type Binary
        Write-Log 'Affinity FIXED: DevicePolicy=4, Mask=0xF0 (CPUs 4-7)'
    } else {
        Write-Log 'Affinity OK: DevicePolicy=4, Mask=0xF0'
    }

    # --- MSI Properties ---
    if (Test-Path $msiPath) {
        $msiSupported = $null
        $msgLimit = $null
        try { $msiSupported = (Get-ItemProperty $msiPath -Name MSISupported -ErrorAction Stop).MSISupported } catch {}
        try { $msgLimit = (Get-ItemProperty $msiPath -Name MessageNumberLimit -ErrorAction Stop).MessageNumberLimit } catch {}

        if ($msiSupported -ne 1) {
            Set-ItemProperty -Path $msiPath -Name MSISupported -Value 1 -Type DWord
            Write-Log 'MSI FIXED: MSISupported set to 1'
        } else {
            Write-Log 'MSI OK: MSISupported=1'
        }

        # Remove MessageNumberLimit if NVIDIA driver re-added it
        if ($null -ne $msgLimit) {
            Remove-ItemProperty -Path $msiPath -Name MessageNumberLimit -ErrorAction SilentlyContinue
            Write-Log ('MSI FIXED: Removed MessageNumberLimit=' + $msgLimit + ' (device supports 9 vectors)')
        } else {
            Write-Log 'MSI OK: MessageNumberLimit not capped'
        }
    }

    # --- HAGS ---
    $classPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000'
    $hwSch = $null
    try { $hwSch = (Get-ItemProperty $classPath -Name HwSchMode -ErrorAction Stop).HwSchMode } catch {}
    if ($hwSch -ne 2) {
        Set-ItemProperty -Path $classPath -Name HwSchMode -Value 2 -Type DWord
        Write-Log ('HAGS FIXED: HwSchMode ' + $hwSch + ' -> 2')
    } else {
        Write-Log 'HAGS OK: HwSchMode=2'
    }

    # --- PerfLevelSrc ---
    $pls = $null
    try { $pls = (Get-ItemProperty $classPath -Name PerfLevelSrc -ErrorAction Stop).PerfLevelSrc } catch {}
    if ($pls -ne 0x2222) {
        Set-ItemProperty -Path $classPath -Name PerfLevelSrc -Value 0x2222 -Type DWord
        Write-Log ('PerfLevelSrc FIXED: 0x{0:X4} -> 0x2222' -f $pls)
    } else {
        Write-Log 'PerfLevelSrc OK: 0x2222'
    }

    Write-Log '=== GPU Affinity Guard complete ==='

} catch {
    Write-Log ('EXCEPTION: ' + $_.Exception.Message)
    exit 1
}
