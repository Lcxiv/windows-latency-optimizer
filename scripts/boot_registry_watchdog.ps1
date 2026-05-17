<#
.SYNOPSIS
    Boot-time registry watchdog. Snapshots latency-critical registry keys,
    compares against previous snapshot, alerts on drift.
.DESCRIPTION
    Run at every boot/logon via scheduled task. Captures ~50 registry values
    that affect gaming latency. Saves timestamped JSON snapshot. Diffs against
    most recent prior snapshot. Writes diff report if anything changed.

    Output dir: captures\registry_watchdog\
    Files per run:
      snapshot_<YYYYMMDD_HHMMSS>.json   — full registry state
      diff_<YYYYMMDD_HHMMSS>.json       — changes vs previous (only if diffs exist)
      diff_<YYYYMMDD_HHMMSS>.txt        — human-readable diff (only if diffs exist)
      latest.json                        — symlink/copy of most recent snapshot

    Exit codes: 0 = no changes, 1 = changes detected, 2 = first run (no prior)
.EXAMPLE
    .\boot_registry_watchdog.ps1
    .\boot_registry_watchdog.ps1 -AlertFile C:\Users\L\Desktop\REGISTRY_DRIFT.txt
#>
param(
    [string]$OutputDir = '',
    [string]$AlertFile = ''
)

$ErrorActionPreference = 'Continue'
$projectRoot = Split-Path $PSScriptRoot -Parent

if ($OutputDir -eq '') {
    $OutputDir = Join-Path $projectRoot 'captures\registry_watchdog'
}
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

# ============================================================================
# REGISTRY KEYS TO MONITOR
# ============================================================================

function Get-RegValue {
    param([string]$Path, [string]$Name)
    try {
        $prop = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return $prop.$Name
    } catch {
        return $null
    }
}

function Get-RegBinary {
    param([string]$Path, [string]$Name)
    $val = Get-RegValue -Path $Path -Name $Name
    if ($val -is [byte[]]) {
        return ($val | ForEach-Object { $_.ToString('X2') }) -join ' '
    }
    return $val
}

function Get-BcdeditValue {
    param([string]$Key)
    try {
        $out = bcdedit /enum '{current}' 2>&1
        $match = $out | Select-String -Pattern ('^' + $Key + '\s+(.+)$')
        if ($match) { return $match.Matches[0].Groups[1].Value.Trim() }
    } catch {}
    return $null
}

$snapshot = [ordered]@{
    _meta = [ordered]@{
        capturedAt = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        hostname = $env:COMPUTERNAME
        buildNumber = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'CurrentBuildNumber' -ErrorAction SilentlyContinue).CurrentBuildNumber
    }

    # --- DWM / Display ---
    dwm_OverlayTestMode = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode'
    dwm_ForceEffectMode = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'ForceEffectMode'
    dwm_EnableAeroPeek = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'EnableAeroPeek'

    # --- Graphics Drivers ---
    gfx_HwSchMode = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
    gfx_DisableDynamicPstate = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000' 'DisableDynamicPstate'

    # --- Priority / MMCSS ---
    prio_Win32PrioritySeparation = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation'
    mmcss_SystemResponsiveness = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness'
    mmcss_NetworkThrottlingIndex = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex'
    mmcss_Games_Priority = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Priority'
    mmcss_Games_SchedulingCategory = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Scheduling Category'
    mmcss_Games_SFIO_Priority = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'SFIO Priority'

    # --- GPU Interrupt Affinity ---
    gpu_affinity_DevicePolicy = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI\VEN_10DE*\*\Device Parameters\Interrupt Management\Affinity Policy' 'DevicePolicy'
    gpu_affinity_mask = $null
    nic_affinity_mask = $null

    # --- HVCI / VBS ---
    hvci_Enabled = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled'
    vbs_EnableVBS = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity'

    # --- Boot config ---
    bcd_hypervisorlaunchtype = Get-BcdeditValue 'hypervisorlaunchtype'
    bcd_nx = Get-BcdeditValue 'nx'

    # --- Defender ---
    defender_DisableRealtimeMonitoring = $null
    defender_ScanAvgCPULoadFactor = $null
    defender_ExclusionPathCount = $null

    # --- Power ---
    power_ActiveScheme = $null

    # --- NIC ---
    nic_InterruptModeration = $null
    nic_RSS = $null

    # --- Windows Update policy ---
    wu_AUOptions = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions'
    wu_NoAutoUpdate = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate'
    wu_NoAutoReboot = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers'

    # --- Timer / HPET ---
    hpet_UseHighPerfTimer = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'UseHighPerfTimer'

    # --- Deep Optimize keys (HKLM only — watchdog runs as SYSTEM) ---
    deep_csrss_CpuPriorityClass = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\csrss.exe\PerfOptions' 'CpuPriorityClass'
    deep_AllowGameDVR = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR'
    deep_PowerThrottlingOff = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff'
    deep_HiberbootEnabled = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled'
    deep_IPv6_DisabledComponents = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' 'DisabledComponents'
    deep_NoLazyMode = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NoLazyMode'
    deep_GlobalTimerRes = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests'
    deep_DisablePagingExec = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'DisablePagingExecutive'
    deep_EnergyTelemetry = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Diagnostics\Performance' 'DisableTaggedEnergyLogging'
    deep_TimeStampInterval = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Reliability' 'TimeStampInterval'

    # --- Nagle ---
    nagle_TcpAckFrequency = $null
    nagle_TCPNoDelay = $null
}

# --- GPU affinity (find actual NVIDIA device) ---
try {
    $gpuDev = Get-PnpDevice -Class Display -Status OK -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'NVIDIA' } | Select-Object -First 1
    if ($gpuDev) {
        $gpuAffinityKey = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $gpuDev.InstanceId + '\Device Parameters\Interrupt Management\Affinity Policy'
        $snapshot.gpu_affinity_DevicePolicy = Get-RegValue $gpuAffinityKey 'DevicePolicy'
        $snapshot.gpu_affinity_mask = Get-RegBinary $gpuAffinityKey 'AssignmentSetOverride'
    }
} catch {}

# --- NIC affinity ---
try {
    $nicDev = Get-PnpDevice -Class Net -Status OK -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'I226' } | Select-Object -First 1
    if ($nicDev) {
        $nicAffinityKey = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $nicDev.InstanceId + '\Device Parameters\Interrupt Management\Affinity Policy'
        $snapshot.nic_affinity_mask = Get-RegBinary $nicAffinityKey 'AssignmentSetOverride'

        # NIC advanced props
        $intMod = Get-NetAdapterAdvancedProperty -Name '*' -DisplayName 'Interrupt Moderation' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Ethernet' } | Select-Object -First 1
        if ($intMod) { $snapshot.nic_InterruptModeration = $intMod.DisplayValue }
        $rss = Get-NetAdapterAdvancedProperty -Name '*' -DisplayName '*RSS*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Ethernet' } | Select-Object -First 1
        if ($rss) { $snapshot.nic_RSS = $rss.DisplayValue }
    }
} catch {}

# --- Defender ---
try {
    $pref = Get-MpPreference -ErrorAction Stop
    $snapshot.defender_DisableRealtimeMonitoring = $pref.DisableRealtimeMonitoring
    $snapshot.defender_ScanAvgCPULoadFactor = $pref.ScanAvgCPULoadFactor
    $snapshot.defender_ExclusionPathCount = $pref.ExclusionPath.Count
} catch {}

# --- Power plan ---
try {
    $pp = powercfg /getactivescheme 2>&1 | Out-String
    if ($pp -match 'GUID:\s+(\S+)\s+\((.+)\)') {
        $snapshot.power_ActiveScheme = $Matches[2].Trim()
    }
} catch {}

# --- Nagle (find NIC interface GUID) ---
try {
    $nicAdapter = Get-NetAdapter -Physical | Where-Object { $_.InterfaceDescription -match 'I226' } | Select-Object -First 1
    if ($nicAdapter) {
        $tcpKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\' + $nicAdapter.InterfaceGuid
        $snapshot.nagle_TcpAckFrequency = Get-RegValue $tcpKey 'TcpAckFrequency'
        $snapshot.nagle_TCPNoDelay = Get-RegValue $tcpKey 'TCPNoDelay'
    }
} catch {}

# ============================================================================
# SAVE SNAPSHOT
# ============================================================================

$snapshotPath = Join-Path $OutputDir ('snapshot_' + $timestamp + '.json')
$snapshot | ConvertTo-Json -Depth 5 | Set-Content -Path $snapshotPath -Encoding UTF8
Copy-Item $snapshotPath (Join-Path $OutputDir 'latest.json') -Force

# ============================================================================
# DIFF AGAINST PREVIOUS
# ============================================================================

$allSnapshots = Get-ChildItem $OutputDir -Filter 'snapshot_*.json' | Sort-Object Name -Descending
$exitCode = 2  # first run

if ($allSnapshots.Count -ge 2) {
    $prevPath = $allSnapshots[1].FullName
    $prev = Get-Content $prevPath -Raw | ConvertFrom-Json

    $diffs = @()
    foreach ($key in $snapshot.Keys) {
        if ($key -eq '_meta') { continue }
        $curVal = $snapshot[$key]
        $prevVal = $prev.$key

        # Normalize for comparison
        $curStr = if ($null -eq $curVal) { '<null>' } else { $curVal.ToString() }
        $prevStr = if ($null -eq $prevVal) { '<null>' } else { $prevVal.ToString() }

        if ($curStr -ne $prevStr) {
            $diffs += [ordered]@{
                key = $key
                previous = $prevStr
                current = $curStr
                previousSnapshot = $allSnapshots[1].Name
            }
        }
    }

    if ($diffs.Count -gt 0) {
        $exitCode = 1  # changes detected

        # JSON diff
        $diffJsonPath = Join-Path $OutputDir ('diff_' + $timestamp + '.json')
        @{
            comparedAt = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
            previousSnapshot = $allSnapshots[1].Name
            currentSnapshot = ('snapshot_' + $timestamp + '.json')
            changeCount = $diffs.Count
            changes = $diffs
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $diffJsonPath -Encoding UTF8

        # Human-readable diff
        $diffTxtPath = Join-Path $OutputDir ('diff_' + $timestamp + '.txt')
        $lines = @()
        $lines += '=== REGISTRY DRIFT DETECTED ==='
        $lines += ('Time: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        $lines += ('Previous: ' + $allSnapshots[1].Name)
        $lines += ('Changes: ' + $diffs.Count)
        $lines += ''
        foreach ($d in $diffs) {
            $lines += ('  ' + $d.key)
            $lines += ('    was: ' + $d.previous)
            $lines += ('    now: ' + $d.current)
            $lines += ''
        }
        $lines | Set-Content -Path $diffTxtPath -Encoding UTF8

        # Console output
        Write-Host ''
        Write-Host ('!!! REGISTRY DRIFT: ' + $diffs.Count + ' change(s) since last boot !!!') -ForegroundColor Red
        Write-Host ''
        foreach ($d in $diffs) {
            Write-Host ('  ' + $d.key) -ForegroundColor Yellow
            Write-Host ('    was: ' + $d.previous) -ForegroundColor DarkGray
            Write-Host ('    now: ' + $d.current) -ForegroundColor White
        }
        Write-Host ''
        Write-Host ('Diff: ' + $diffTxtPath) -ForegroundColor Cyan

        # Optional desktop alert file
        if ($AlertFile -ne '') {
            $lines | Set-Content -Path $AlertFile -Encoding UTF8
            Write-Host ('Alert: ' + $AlertFile) -ForegroundColor Cyan
        }
    } else {
        $exitCode = 0
        Write-Host 'Registry watchdog: no changes since last boot.' -ForegroundColor Green
    }
} else {
    Write-Host 'Registry watchdog: first run — baseline snapshot saved.' -ForegroundColor Yellow
}

Write-Host ('Snapshot: ' + $snapshotPath) -ForegroundColor Cyan
exit $exitCode
