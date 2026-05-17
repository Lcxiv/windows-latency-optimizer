#Requires -RunAsAdministrator
<#
.SYNOPSIS
    GPU audit checks (Quick + Deep Tier).
.DESCRIPTION
    NVIDIA MSI mode, GPU interrupt affinity, HAGS, DPC health from experiment data.
#>

# ---------------------------------------------------------------------------
# Quick Tier: GPU Checks (17-19)
# ---------------------------------------------------------------------------
function Invoke-GpuChecks {
    $results = @()

    # Detect NVIDIA GPU — match PCI device to display adapter (not USB controller)
    $nvKey = $null
    try {
        $gpuPnp = Get-WmiObject Win32_VideoController -ErrorAction Stop |
            Where-Object { $_.PNPDeviceID -like 'PCI\VEN_10DE*' -and $_.Status -eq 'OK' } |
            Select-Object -First 1
        if ($null -ne $gpuPnp) {
            # Extract VEN&DEV portion to match registry key
            $pnpParts = $gpuPnp.PNPDeviceID.Split('\')
            $venDev   = $pnpParts[1]  # e.g. VEN_10DE&DEV_2C05&SUBSYS_...
            $nvKey    = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -ErrorAction Stop |
                Where-Object { $_.PSChildName -eq $venDev } | Select-Object -First 1
        }
    } catch {}
    # Fallback: if WMI didn't find it, try first VEN_10DE PCI entry with a display class
    if ($null -eq $nvKey) {
        try {
            $nvKey = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -ErrorAction Stop |
                Where-Object { $_.PSChildName -like 'VEN_10DE*DEV_2*' -or $_.PSChildName -like 'VEN_10DE*DEV_1*' } |
                Select-Object -First 1
        } catch {}
    }

    if ($null -eq $nvKey) {
        $nv = New-CheckResult -Name 'GPU (all checks)' -Category 'GPU' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'SKIP' -Current 'No NVIDIA GPU found' -Expected 'NVIDIA GPU'
        $results += $nv
        return $results
    }

    # Get instance sub-key (VEN&DEV key has one child = the instance ID)
    $nvInstance = Get-ChildItem $nvKey.PSPath -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $nvInstance) { $nvInstance = $nvKey }

    # --- Check 17: GPU MSI Mode ---
    $msiPath = $nvInstance.PSPath + '\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties'
    $msiVal  = $null
    try { $msiVal = (Get-ItemProperty $msiPath -ErrorAction Stop).MSISupported } catch {}
    if ($null -eq $msiVal) {
        $results += New-CheckResult -Name 'GPU MSI Mode' -Category 'GPU' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'WARN' -Current 'Key not found' -Expected 'MSISupported = 1' `
            -Message 'Cannot verify GPU MSI mode.'
    } elseif ($msiVal -eq 1) {
        $results += New-CheckResult -Name 'GPU MSI Mode' -Category 'GPU' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'MSISupported = 1' -Expected 'MSISupported = 1'
    } else {
        $results += New-CheckResult -Name 'GPU MSI Mode' -Category 'GPU' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'FAIL' -Current ('MSISupported = ' + $msiVal) -Expected 'MSISupported = 1' `
            -Message 'Line-based interrupts cause shared IRQ contention and higher DPC latency. NVIDIA driver updates silently reset this to 0.' `
            -Fix '.\scripts\exp21_msi_gpu_clocks.ps1' `
            -FixNote 'Reboot required. Re-apply after every NVIDIA driver update — the installer resets MSISupported to 0.'
    }

    # --- Check 18: GPU Interrupt Affinity ---
    $gpuAffPath    = $nvInstance.PSPath + '\Device Parameters\Interrupt Management\Affinity Policy'
    $gpuAffDetail  = 'Not set (default CPU 0)'
    $gpuAffStatus  = 'WARN'
    try {
        $gpuAff    = Get-ItemProperty $gpuAffPath -ErrorAction Stop
        $gpuPolicy = $gpuAff.DevicePolicy
        $gpuSet    = $gpuAff.AssignmentSetOverride
        if ($null -ne $gpuSet -and $gpuSet.Count -ge 2 -and ($gpuPolicy -eq 3 -or $gpuPolicy -eq 4)) {
            $maskHex      = '0x' + (($gpuSet[1..0] | ForEach-Object { $_.ToString('X2') }) -join '')
            $gpuAffDetail = 'DevicePolicy=' + $gpuPolicy + ', Mask=' + $maskHex
            $gpuAffStatus = 'PASS'
        } elseif ($null -ne $gpuPolicy) {
            $gpuAffDetail = 'DevicePolicy=' + $gpuPolicy + ' (no affinity mask set)'
        }
    } catch {}

    if ($gpuAffStatus -eq 'PASS') {
        $results += New-CheckResult -Name 'GPU Interrupt Affinity' -Category 'GPU' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'PASS' -Current $gpuAffDetail -Expected 'DevicePolicy=3 or 4 with affinity mask'
    } else {
        $results += New-CheckResult -Name 'GPU Interrupt Affinity' -Category 'GPU' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'WARN' -Current $gpuAffDetail -Expected 'DevicePolicy=4, CPUs 4-7 (mask 0xF0)' `
            -Message 'Default: GPU DPC work lands on CPU 0, competing with game threads.' `
            -Fix ('New-Item -Path "' + $gpuAffPath + '" -Force | Out-Null; Set-ItemProperty -Path "' + $gpuAffPath + '" -Name DevicePolicy -Value 4 -Type DWord; Set-ItemProperty -Path "' + $gpuAffPath + '" -Name AssignmentSetOverride -Value ([byte[]](0xF0,0x00)) -Type Binary') `
            -FixNote 'Reboot required. Adjust mask for your CPU topology.'
    }

    # --- Check 19: HAGS Enabled ---
    $hagsVal = $null
    try { $hagsVal = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction Stop).HwSchMode } catch {}
    if ($null -eq $hagsVal) {
        $results += New-CheckResult -Name 'HAGS Enabled' -Category 'GPU' -Tier 'Quick' -Severity 'LOW' `
            -Status 'WARN' -Current 'Not set' -Expected 'HwSchMode = 2 (for RTX 40/50)' `
            -Fix 'Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name HwSchMode -Value 2 -Type DWord' `
            -FixNote 'Reboot required. Only beneficial on RTX 30+ or RDNA3+.'
    } elseif ($hagsVal -eq 2) {
        $results += New-CheckResult -Name 'HAGS Enabled' -Category 'GPU' -Tier 'Quick' -Severity 'LOW' `
            -Status 'PASS' -Current 'HwSchMode = 2' -Expected 'HwSchMode = 2'
    } else {
        $results += New-CheckResult -Name 'HAGS Enabled' -Category 'GPU' -Tier 'Quick' -Severity 'LOW' `
            -Status 'WARN' -Current ('HwSchMode = ' + $hagsVal) -Expected '2' `
            -Fix 'Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name HwSchMode -Value 2 -Type DWord' `
            -FixNote 'Reboot required.'
    }

    return $results
}

# ---------------------------------------------------------------------------
# Deep Tier: NVIDIA DPC Health (from last experiment)
# ---------------------------------------------------------------------------
function Invoke-NvidiaDpcHealthCheck {
    $results = @()

    $expRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'captures\experiments'
    if (-not (Test-Path $expRoot)) { return $results }

    $dirs = @(Get-ChildItem $expRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($dirs.Count -eq 0) { return $results }

    $lastExpDir = $dirs[0].FullName
    $expJson    = Join-Path $lastExpDir 'experiment.json'
    if (-not (Test-Path $expJson)) { return $results }

    $expData = $null
    try { $expData = Get-Content $expJson -Raw | ConvertFrom-Json -ErrorAction Stop } catch { return $results }

    # Check for DPC alerts
    $nvAlerts = @()
    if ($expData.dpcIsrAnalysis -and $expData.dpcIsrAnalysis.dpcAlerts) {
        $nvAlerts = @($expData.dpcIsrAnalysis.dpcAlerts | Where-Object { $_.driver -eq 'nvlddmkm.sys' })
    }

    # Check for nvlddmkm in dpcDrivers
    $nvDpc = $null
    if ($expData.dpcIsrAnalysis -and $expData.dpcIsrAnalysis.dpcDrivers) {
        $nvDpc = $expData.dpcIsrAnalysis.dpcDrivers | Where-Object { $_.Module -eq 'nvlddmkm.sys' } | Select-Object -First 1
    }

    if ($nvAlerts.Count -gt 0) {
        $alertMsg = $nvAlerts[0].message
        $results += New-CheckResult -Name 'NVIDIA DPC Health' -Category 'GPU' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'WARN' -Current $alertMsg -Expected 'No DPC spikes >500us' `
            -Message 'High nvlddmkm.sys DPC latency causes frame hitches and audio crackling. Consider driver rollback, disabling NVIDIA HD Audio, or pinning GPU to P0 state.' `
            -Fix '' -FixNote 'Try clean driver install via DDU. Check BIOS for C-state settings.'
    } elseif ($null -ne $nvDpc) {
        $nvDetail = 'nvlddmkm.sys: ' + $nvDpc.Count + ' DPCs, max ' + $nvDpc.MaxUs + 'us (from ' + $dirs[0].Name + ')'
        $results += New-CheckResult -Name 'NVIDIA DPC Health' -Category 'GPU' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'PASS' -Current $nvDetail -Expected 'Max DPC < 500us'
    } else {
        $results += New-CheckResult -Name 'NVIDIA DPC Health' -Category 'GPU' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'SKIP' -Current 'No DPC data in last experiment' -Expected 'Run pipeline.ps1 first' `
            -Message 'Run pipeline.ps1 to capture DPC/ISR data for this check.'
    }

    return $results
}
