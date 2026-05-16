<#
.SYNOPSIS
    Snapshot PCIe link state for GPU and NVMe drives.
.DESCRIPTION
    Captures current/max PCIe gen + width per device. GPU via nvidia-smi.
    NVMe via Get-PnpDevice + DEVPKEY_PciDevice properties.
    Flags any device below max (degraded link).
.OUTPUTS
    JSON to <OutDir>\pcie_state.json
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$OutDir,
    [string]$Phase = 'preflight'
)

$ErrorActionPreference = 'Continue'
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$result = [ordered]@{
    schemaVersion = 1
    capturedAt = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    phase = $Phase
    gpu = $null
    nvme = @()
    flags = @()
}

# --- GPU via nvidia-smi ---
$nvSmi = 'C:\Windows\System32\nvidia-smi.exe'
if (Test-Path $nvSmi) {
    try {
        $csv = & $nvSmi --query-gpu=name,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max --format=csv,noheader,nounits 2>&1
        $line = ($csv | Select-Object -First 1).ToString().Trim()
        $parts = $line -split ',\s*'
        if ($parts.Count -ge 5) {
            $genCur = [int]$parts[1]
            $genMax = [int]$parts[2]
            $widCur = [int]$parts[3]
            $widMax = [int]$parts[4]
            $result.gpu = [ordered]@{
                name = $parts[0].Trim()
                pcie_gen_current = $genCur
                pcie_gen_max = $genMax
                pcie_width_current = $widCur
                pcie_width_max = $widMax
                degraded = ($genCur -lt $genMax) -or ($widCur -lt $widMax)
            }
            if ($genCur -lt $genMax) {
                $result.flags += ('GPU PCIe gen downgraded: ' + $genCur + ' < max ' + $genMax)
            }
            if ($widCur -lt $widMax) {
                $result.flags += ('GPU PCIe width downgraded: x' + $widCur + ' < max x' + $widMax)
            }
        }
    } catch {
        $result.gpu = @{ error = $_.Exception.Message }
    }
} else {
    $result.gpu = @{ error = 'nvidia-smi.exe not found' }
}

# --- NVMe drives via Get-PhysicalDisk + Get-PnpDevice ---
try {
    $disks = Get-PhysicalDisk | Where-Object { $_.BusType -eq 'NVMe' }
    foreach ($d in $disks) {
        $entry = [ordered]@{
            friendlyName = $d.FriendlyName
            mediaType = $d.MediaType
            sizeGB = [math]::Round($d.Size / 1GB, 1)
            healthStatus = $d.HealthStatus
            operationalStatus = $d.OperationalStatus
            pcie_link = $null
        }
        # Try to find matching PnP device for PCIe link info
        try {
            $pnp = Get-PnpDevice -Class DiskDrive -Status OK -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -eq $d.FriendlyName } | Select-Object -First 1
            if ($pnp) {
                # Walk up the device tree to find the PCIe parent
                $parentId = (Get-PnpDeviceProperty -InstanceId $pnp.InstanceId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data
                if ($parentId) {
                    $linkSpeed = (Get-PnpDeviceProperty -InstanceId $parentId -KeyName 'DEVPKEY_PciDevice_CurrentLinkSpeed' -ErrorAction SilentlyContinue).Data
                    $linkWidth = (Get-PnpDeviceProperty -InstanceId $parentId -KeyName 'DEVPKEY_PciDevice_CurrentLinkWidth' -ErrorAction SilentlyContinue).Data
                    $maxLinkSpeed = (Get-PnpDeviceProperty -InstanceId $parentId -KeyName 'DEVPKEY_PciDevice_MaxLinkSpeed' -ErrorAction SilentlyContinue).Data
                    $maxLinkWidth = (Get-PnpDeviceProperty -InstanceId $parentId -KeyName 'DEVPKEY_PciDevice_MaxLinkWidth' -ErrorAction SilentlyContinue).Data
                    $entry.pcie_link = [ordered]@{
                        current_speed_code = $linkSpeed
                        current_width = $linkWidth
                        max_speed_code = $maxLinkSpeed
                        max_width = $maxLinkWidth
                    }
                    if ($linkSpeed -and $maxLinkSpeed -and ($linkSpeed -lt $maxLinkSpeed)) {
                        $result.flags += ('NVMe PCIe speed downgraded on ' + $d.FriendlyName)
                    }
                    if ($linkWidth -and $maxLinkWidth -and ($linkWidth -lt $maxLinkWidth)) {
                        $result.flags += ('NVMe PCIe width downgraded on ' + $d.FriendlyName)
                    }
                }
            }
        } catch {
            $entry.pcie_link = @{ error = $_.Exception.Message }
        }
        $result.nvme += $entry
    }
} catch {
    $result.nvme = @(@{ error = $_.Exception.Message })
}

if ($result.flags.Count -eq 0) {
    $result.flags = @('PASS: All PCIe links at max gen/width')
}

$outPath = Join-Path $OutDir 'pcie_state.json'
$result | ConvertTo-Json -Depth 6 | Set-Content -Path $outPath -Encoding UTF8
Write-Host ('[hw_pcie_state] wrote: ' + $outPath) -ForegroundColor Cyan
foreach ($f in $result.flags) { Write-Host ('  -> ' + $f) }
