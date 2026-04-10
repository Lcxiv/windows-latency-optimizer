# gpu-vendor.ps1
# GPU vendor detection and abstraction layer.
# Detects NVIDIA, AMD, or Intel GPU and provides vendor-specific
# registry paths, driver module names, and DPC alert rules.
#
# Dot-sourced by config.ps1. Do not run directly.
# PowerShell 5.1 compatible.

if (-not (Get-Variable -Name GpuInfoCache -Scope Script -ErrorAction SilentlyContinue)) {
    $script:GpuInfoCache = $null
}

# Vendor configuration table
$script:GpuVendorTable = @{
    'NVIDIA' = @{
        VenId       = 'VEN_10DE'
        DriverModule = 'nvlddmkm.sys'
        PowerRegPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\NVTweak'
        PowerRegKey  = 'PerfLevelSrc'
        SmiCommand   = 'nvidia-smi'
    }
    'AMD' = @{
        VenId       = 'VEN_1002'
        DriverModule = 'amdkmdag.sys'
        PowerRegPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\amdkmdag'
        PowerRegKey  = 'EnableUlps'
        SmiCommand   = $null
    }
    'Intel' = @{
        VenId       = 'VEN_8086'
        DriverModule = 'igdkmd64.sys'
        PowerRegPath = $null
        PowerRegKey  = $null
        SmiCommand   = $null
    }
}

function Get-GpuInfo {
    <#
    .SYNOPSIS
        Detect GPU vendor, model, driver, and PCI info.
    .OUTPUTS
        [hashtable] Keys: vendor, name, venId, driverModule, pnpId, driverVersion, vendorConfig.
    #>
    param([switch]$Force)

    if ($script:GpuInfoCache -and -not $Force) {
        return $script:GpuInfoCache
    }

    $result = @{
        vendor       = 'Unknown'
        name         = 'Unknown GPU'
        venId        = ''
        driverModule = ''
        pnpId        = ''
        driverVersion = ''
        vendorConfig = @{}
    }

    try {
        $gpus = Get-WmiObject Win32_VideoController -ErrorAction Stop |
            Where-Object { $_.Name -notmatch 'Basic Display' -and $_.Name -notmatch 'Remote Desktop' }
        $gpu = $gpus | Select-Object -First 1

        if ($gpu) {
            $result.name = $gpu.Name.Trim()
            if ($gpu.DriverVersion) { $result.driverVersion = $gpu.DriverVersion }
            if ($gpu.PNPDeviceID) { $result.pnpId = $gpu.PNPDeviceID }

            # Detect vendor from name or PNP ID
            if ($gpu.Name -match 'NVIDIA' -or $gpu.PNPDeviceID -match 'VEN_10DE') {
                $result.vendor = 'NVIDIA'
            } elseif ($gpu.Name -match 'AMD|Radeon' -or $gpu.PNPDeviceID -match 'VEN_1002') {
                $result.vendor = 'AMD'
            } elseif ($gpu.Name -match 'Intel.*Arc|Intel.*Iris|Intel.*UHD|Intel.*HD Graphics' -or $gpu.PNPDeviceID -match 'VEN_8086') {
                $result.vendor = 'Intel'
            }

            if ($script:GpuVendorTable.ContainsKey($result.vendor)) {
                $vc = $script:GpuVendorTable[$result.vendor]
                $result.venId        = $vc.VenId
                $result.driverModule = $vc.DriverModule
                $result.vendorConfig = $vc
            }
        }
    } catch {
        # WMI failed; return defaults
    }

    $script:GpuInfoCache = $result
    return $result
}

function Get-GpuRegistrySnapshot {
    <#
    .SYNOPSIS
        Read GPU-specific registry values (MSI mode, power settings) for the detected vendor.
    .OUTPUTS
        [hashtable] GPU registry key/value pairs.
    #>
    $gpuInfo = Get-GpuInfo
    $reg = @{}

    if ($gpuInfo.vendor -eq 'Unknown') { return $reg }

    $venPattern = $gpuInfo.venId
    $reg['GPU_Vendor'] = $gpuInfo.vendor
    $reg['GPU_Name']   = $gpuInfo.name
    $reg['GPU_Driver'] = $gpuInfo.driverVersion

    # MSI mode (vendor-agnostic PCI check)
    $nvKeys = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like ('*' + $venPattern + '*') }
    if ($nvKeys) {
        $nvKey = $nvKeys | Select-Object -First 1
        $msiPath = Join-Path $nvKey.PSPath 'Device Parameters\Interrupt Management\MessageSignaledInterruptProperties'
        if (Test-Path $msiPath) {
            $msi = Get-ItemProperty $msiPath -ErrorAction SilentlyContinue
            $reg['GPU_MSISupported'] = $msi.MSISupported
            $reg['GPU_MessageNumberLimit'] = $msi.MessageNumberLimit
        }
    }

    # Vendor-specific power settings
    $vc = $gpuInfo.vendorConfig
    if ($vc.PowerRegPath -and (Test-Path $vc.PowerRegPath)) {
        $val = (Get-ItemProperty $vc.PowerRegPath -ErrorAction SilentlyContinue)
        if ($vc.PowerRegKey -and $val.$($vc.PowerRegKey) -ne $null) {
            $reg['GPU_PowerSetting'] = $val.$($vc.PowerRegKey)
        }
    }

    # HAGS (vendor-agnostic)
    $reg['HAGS_HwSchMode'] = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction SilentlyContinue).HwSchMode

    return $reg
}

function Get-GpuDpcAlertDrivers {
    <#
    .SYNOPSIS
        Return driver module names to watch for DPC/ISR alerts based on detected GPU vendor.
    .OUTPUTS
        [string[]] Array of driver module filenames.
    #>
    $gpuInfo = Get-GpuInfo
    $drivers = @()

    # Always include the detected GPU driver
    if ($gpuInfo.driverModule -ne '') {
        $drivers += $gpuInfo.driverModule
    }

    # Add common DPC offender drivers regardless of GPU vendor
    $drivers += @('ndis.sys', 'tcpip.sys', 'storport.sys', 'dxgkrnl.sys')

    return $drivers
}
