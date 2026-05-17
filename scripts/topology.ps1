# topology.ps1
# CPU topology discovery for the windows-latency-optimizer toolkit.
# Detects CPU model, core count, hybrid architecture, and generates
# recommended interrupt affinity groups for gaming latency optimization.
#
# Dot-sourced by config.ps1. Do not run directly.
# PowerShell 5.1 compatible.

if (-not (Get-Variable -Name CpuTopologyCache -Scope Script -ErrorAction SilentlyContinue)) {
    $script:CpuTopologyCache = $null
}

function ConvertTo-AffinityMask {
    <#
    .SYNOPSIS
        Convert a list of CPU indices to a registry-format affinity mask byte array.
    .PARAMETER Cpus
        Array of CPU indices (e.g., @(4,5,6,7)).
    .PARAMETER TotalLogical
        Total logical processor count (for sizing the byte array).
    .OUTPUTS
        [byte[]] Affinity mask suitable for AssignmentSetOverride registry value.
    .EXAMPLE
        ConvertTo-AffinityMask @(4,5,6,7) 16  # Returns [byte[]](0xF0, 0x00)
    #>
    param(
        [int[]]$Cpus,
        [int]$TotalLogical = 16
    )

    $byteCount = [math]::Ceiling($TotalLogical / 8)
    if ($byteCount -lt 2) { $byteCount = 2 }
    $mask = New-Object byte[] $byteCount

    foreach ($cpu in $Cpus) {
        if ($cpu -lt 0 -or $cpu -ge $TotalLogical) { continue }
        $byteIndex = [math]::Floor($cpu / 8)
        $bitIndex  = $cpu % 8
        $mask[$byteIndex] = $mask[$byteIndex] -bor (1 -shl $bitIndex)
    }

    return $mask
}

function Get-GroupShareFromCpuData {
    <#
    .SYNOPSIS
        Compute interrupt share percentage for a topology group from cpuData array.
    .PARAMETER CpuData
        Array of per-CPU hashtables with interruptPct field.
    .PARAMETER GroupCpus
        Array of CPU indices belonging to the group.
    .OUTPUTS
        [double] Percentage of total interrupts handled by this group.
    #>
    param(
        [array]$CpuData,
        [int[]]$GroupCpus
    )

    if (-not $CpuData -or $CpuData.Count -eq 0) { return 0 }

    $totalIntr = 0
    foreach ($c in $CpuData) { $totalIntr += $c.interruptPct }
    if ($totalIntr -le 0) { return 0 }

    $groupIntr = 0
    foreach ($c in $CpuData) {
        if ($c.cpu -in $GroupCpus) { $groupIntr += $c.interruptPct }
    }
    return [math]::Round($groupIntr / $totalIntr * 100, 1)
}

function Get-CpuTopology {
    <#
    .SYNOPSIS
        Discover CPU topology and generate recommended affinity groups.
    .DESCRIPTION
        Detects CPU model, core count, Intel hybrid (P/E-core) layout,
        preferred core, and generates 4 groups: preferred, input, bulk, game.
        Results are cached; use -Force to re-discover.
    .PARAMETER Force
        Skip cache and re-discover topology.
    .OUTPUTS
        [hashtable] Keys: cpuModel, manufacturer, totalLogical, totalCores,
        isHybrid, preferredCore, groups, affinityMasks.
    #>
    param([switch]$Force)

    if ($script:CpuTopologyCache -and -not $Force) {
        return $script:CpuTopologyCache
    }

    # ── CPU Detection ────────────────────────────────────────────────────────
    $cpuModel    = 'Unknown'
    $manufacturer = 'Unknown'
    $totalLogical = [int]$env:NUMBER_OF_PROCESSORS
    $totalCores   = $totalLogical

    try {
        $wmi = Get-WmiObject Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $cpuModel    = $wmi.Name.Trim()
        $totalCores  = [int]$wmi.NumberOfCores
        $wmiLogical  = [int]$wmi.NumberOfLogicalProcessors
        if ($wmiLogical -gt 0) { $totalLogical = $wmiLogical }

        if ($cpuModel -match 'AMD') {
            $manufacturer = 'AMD'
        } elseif ($cpuModel -match 'Intel') {
            $manufacturer = 'Intel'
        }
    } catch {
        # Fallback: env var already set above
    }

    # ── Hybrid Detection (Intel 12th+ gen) ───────────────────────────────────
    $isHybrid  = $false
    $eCores    = @()
    $pCores    = @()

    if ($manufacturer -eq 'Intel' -and $totalLogical -gt 4) {
        try {
            $cpuRegs = Get-ChildItem 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor' -ErrorAction Stop
            $speeds = @()
            foreach ($reg in $cpuRegs) {
                $props = Get-ItemProperty $reg.PSPath -ErrorAction SilentlyContinue
                if ($props.'~MHz') { $speeds += @{ cpu = [int]$reg.PSChildName; mhz = [int]$props.'~MHz' } }
            }

            if ($speeds.Count -gt 1) {
                $maxMhz = ($speeds | Measure-Object -Property mhz -Maximum).Maximum
                $minMhz = ($speeds | Measure-Object -Property mhz -Minimum).Minimum

                # If max is >30% faster than min, we have a hybrid layout
                if ($minMhz -gt 0 -and ($maxMhz / $minMhz) -gt 1.3) {
                    $isHybrid = $true
                    $threshold = ($maxMhz + $minMhz) / 2
                    foreach ($s in $speeds) {
                        if ($s.mhz -ge $threshold) {
                            $pCores += $s.cpu
                        } else {
                            $eCores += $s.cpu
                        }
                    }
                }
            }
        } catch {
            # Hybrid detection failed; treat as symmetric
        }
    }

    # ── Preferred Core ───────────────────────────────────────────────────────
    $preferredCore = 0  # Safe default: Windows initializes on CPU 0

    # ── Group Assignment ─────────────────────────────────────────────────────
    $groups = @()
    $allCpus = @(0..($totalLogical - 1))

    if ($isHybrid -and $pCores.Count -gt 0 -and $eCores.Count -gt 0) {
        # Intel hybrid: E-cores do bulk work, P-cores get input + game
        $prefCpus  = @($pCores[0])
        $remaining = @($pCores | Where-Object { $_ -ne $pCores[0] })

        $inputCount = [math]::Min(2, $remaining.Count)
        $inputCpus  = @($remaining[0..($inputCount - 1)])
        $gameCpus   = @($remaining | Where-Object { $_ -notin $inputCpus })

        $groups += @{ name = 'preferred'; cpus = $prefCpus;  label = 'Preferred'; description = 'P-core kept idle for OS scheduler' }
        $groups += @{ name = 'input';     cpus = $inputCpus; label = 'Input';     description = 'P-cores for keyboard/mouse' }
        $groups += @{ name = 'bulk';      cpus = $eCores;    label = 'Bulk';      description = 'E-cores for GPU/NIC DPC work' }
        $groups += @{ name = 'game';      cpus = $gameCpus;  label = 'Game';      description = 'Remaining P-cores for game threads' }
    } else {
        # Symmetric layout (AMD, Intel non-hybrid, or detection failed)
        $prefCpus = @($preferredCore)
        $available = @($allCpus | Where-Object { $_ -ne $preferredCore })

        # Input: 2 CPUs
        $inputCount = [math]::Min(2, $available.Count)
        if ($inputCount -gt 0) {
            $inputCpus = @($available[0..($inputCount - 1)])
        } else {
            $inputCpus = @()
        }
        $remaining = @($available | Where-Object { $_ -notin $inputCpus })

        # Bulk: ~40% of remaining CPUs, minimum 1, maximum totalLogical/4
        $bulkCount = [math]::Max(1, [math]::Min([math]::Floor($remaining.Count * 0.4), [math]::Floor($totalLogical / 4)))
        $bulkCount = [math]::Min($bulkCount, $remaining.Count - 1)  # Leave at least 1 for game
        if ($bulkCount -gt 0) {
            $bulkCpus = @($remaining[0..($bulkCount - 1)])
        } else {
            $bulkCpus = @()
        }

        # Game: everything else
        $gameCpus = @($remaining | Where-Object { $_ -notin $bulkCpus })

        $groups += @{ name = 'preferred'; cpus = $prefCpus;  label = 'Preferred'; description = 'Keep idle for OS scheduler' }
        $groups += @{ name = 'input';     cpus = $inputCpus; label = 'Input';     description = 'Keyboard/mouse USB controllers' }
        $groups += @{ name = 'bulk';      cpus = $bulkCpus;  label = 'GPU/NIC';   description = 'GPU/NIC DPC work' }
        $groups += @{ name = 'game';      cpus = $gameCpus;  label = 'Game';      description = 'Game threads' }
    }

    # ── Affinity Masks ───────────────────────────────────────────────────────
    $affinityMasks = @{}
    foreach ($g in $groups) {
        if ($g.cpus.Count -gt 0) {
            $affinityMasks[$g.name] = ConvertTo-AffinityMask -Cpus $g.cpus -TotalLogical $totalLogical
        }
    }

    # ── Build Result ─────────────────────────────────────────────────────────
    $result = @{
        cpuModel      = $cpuModel
        manufacturer  = $manufacturer
        totalLogical  = $totalLogical
        totalCores    = $totalCores
        isHybrid      = $isHybrid
        preferredCore = $preferredCore
        groups        = $groups
        affinityMasks = $affinityMasks
    }

    $script:CpuTopologyCache = $result
    return $result
}
