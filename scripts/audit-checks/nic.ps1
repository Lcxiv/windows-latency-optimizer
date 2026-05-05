#Requires -RunAsAdministrator
<#
.SYNOPSIS
    NIC audit checks (Quick Tier).
.DESCRIPTION
    Intel I226-V driver line, speed/duplex, EEE, interrupt moderation,
    Nagle algorithm, interrupt affinity.
#>

# ---------------------------------------------------------------------------
# Quick Tier: NIC Checks (11-16)
# ---------------------------------------------------------------------------
function Invoke-NicChecks {
    $results = @()

    # Detect primary wired NIC
    $nic = $null
    try {
        $nic = Get-NetAdapter -Physical -ErrorAction Stop |
            Where-Object { $_.Status -eq 'Up' -and $_.MediaType -ne 'Native 802.11' } |
            Select-Object -First 1
    } catch {}

    if ($null -eq $nic) {
        $skip = New-CheckResult -Name 'NIC (all checks)' -Category 'NIC' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'SKIP' -Current 'No active wired adapter found' -Expected 'Active wired NIC'
        $results += $skip
        return $results
    }

    $nicName   = $nic.Name
    $nicDesc   = $nic.InterfaceDescription
    $driverVer = $nic.DriverVersion
    $isIntelI226 = ($nicDesc -match 'I225' -or $nicDesc -match 'I226')

    # --- Check 11: NIC Driver Line (Intel I226 only) ---
    if ($isIntelI226) {
        $major = 0
        try { $major = [int]($driverVer.Split('.')[0]) } catch {}
        if ($major -ge 2) {
            $results += New-CheckResult -Name 'NIC Driver Line' -Category 'NIC' -Tier 'Quick' -Severity 'CRITICAL' `
                -Status 'PASS' -Current ('Driver ' + $driverVer + ' (Win11 line)') -Expected 'Win11 line (2.x)'
        } else {
            $results += New-CheckResult -Name 'NIC Driver Line' -Category 'NIC' -Tier 'Quick' -Severity 'CRITICAL' `
                -Status 'FAIL' -Current ('Driver ' + $driverVer + ' (Win10 line)') -Expected 'Win11 line (2.x)' `
                -Message 'Win10 driver (1.x) on Win11 causes I226-V disconnect/renegotiation hardware bug.' `
                -Source 'https://www.intel.com/content/www/us/en/download/727998/intel-network-adapter-driver-for-windows-11.html' `
                -Fix '' -FixNote 'Download Win11 driver (2.x) from Intel and install manually.'
        }
    } else {
        $results += New-CheckResult -Name 'NIC Driver Line' -Category 'NIC' -Tier 'Quick' -Severity 'CRITICAL' `
            -Status 'SKIP' -Current ($nicDesc + ' (not I225/I226)') -Expected 'Intel I225/I226 only' `
            -Message 'Driver line check only applies to Intel I225/I226 adapters.'
    }

    # --- Check 12: NIC Speed/Duplex (I226 only: avoid 2.5G auto-negotiate bug) ---
    if ($isIntelI226) {
        $speedDuplex = $null
        try {
            $speedDuplex = (Get-NetAdapterAdvancedProperty -Name $nicName -RegistryKeyword '*SpeedDuplex' -ErrorAction Stop).RegistryValue
        } catch {}
        # 0 = Auto, 6 = 1G Full Duplex
        if ($null -eq $speedDuplex) {
            $results += New-CheckResult -Name 'NIC Speed/Duplex' -Category 'NIC' -Tier 'Quick' -Severity 'HIGH' `
                -Status 'WARN' -Current 'Cannot read' -Expected '1G Full Duplex (value 6)' `
                -Message 'Auto-negotiate at 2.5G triggers I226-V hardware disconnect bug.'
        } elseif ($speedDuplex -eq 6) {
            $results += New-CheckResult -Name 'NIC Speed/Duplex' -Category 'NIC' -Tier 'Quick' -Severity 'HIGH' `
                -Status 'PASS' -Current '1.0 Gbps Full Duplex' -Expected '1G Full Duplex'
        } else {
            $label = 'Value ' + $speedDuplex
            if ($speedDuplex -eq 0) { $label = 'Auto Negotiate' }
            $results += New-CheckResult -Name 'NIC Speed/Duplex' -Category 'NIC' -Tier 'Quick' -Severity 'HIGH' `
                -Status 'WARN' -Current $label -Expected '1.0 Gbps Full Duplex' `
                -Message 'Auto-negotiate at 2.5G triggers I226-V random disconnect bug. Force 1G Full Duplex.' `
                -Fix ('Set-NetAdapterAdvancedProperty -Name "' + $nicName + '" -RegistryKeyword "*SpeedDuplex" -RegistryValue 6')
        }
    } else {
        $results += New-CheckResult -Name 'NIC Speed/Duplex' -Category 'NIC' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'SKIP' -Current $nicDesc -Expected 'Intel I225/I226 only'
    }

    # --- Check 13: NIC EEE ---
    $eeeVal = $null
    try {
        $eee    = Get-NetAdapterAdvancedProperty -Name $nicName -ErrorAction SilentlyContinue |
            Where-Object { $_.RegistryKeyword -match '\*EEE' -or $_.RegistryKeyword -match 'EEELinkAdvert' } |
            Select-Object -First 1
        if ($eee) { $eeeVal = $eee.RegistryValue }
    } catch {}
    if ($null -eq $eeeVal) {
        $results += New-CheckResult -Name 'NIC EEE' -Category 'NIC' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'SKIP' -Current 'Property not found' -Expected 'Disabled (0)'
    } elseif ($eeeVal -eq 0) {
        $results += New-CheckResult -Name 'NIC EEE' -Category 'NIC' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'PASS' -Current 'Disabled' -Expected 'Disabled'
    } else {
        $results += New-CheckResult -Name 'NIC EEE' -Category 'NIC' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'FAIL' -Current 'Enabled' -Expected 'Disabled' `
            -Message 'Energy Efficient Ethernet introduces variable latency as adapter enters/exits low-power state.' `
            -Fix ('Set-NetAdapterAdvancedProperty -Name "' + $nicName + '" -RegistryKeyword "*EEE" -RegistryValue 0')
    }

    # --- Check 14: NIC Interrupt Moderation ---
    $imVal = $null
    try {
        $im    = Get-NetAdapterAdvancedProperty -Name $nicName -RegistryKeyword '*InterruptModeration' -ErrorAction Stop
        $imVal = $im.RegistryValue
    } catch {}
    if ($null -eq $imVal) {
        $results += New-CheckResult -Name 'NIC Interrupt Moderation' -Category 'NIC' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'SKIP' -Current 'Property not found' -Expected 'Disabled (0)'
    } elseif ($imVal -eq 0) {
        $results += New-CheckResult -Name 'NIC Interrupt Moderation' -Category 'NIC' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'Disabled' -Expected 'Disabled'
    } else {
        $results += New-CheckResult -Name 'NIC Interrupt Moderation' -Category 'NIC' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'WARN' -Current 'Enabled' -Expected 'Disabled' `
            -Message 'Interrupt moderation batches interrupts to reduce CPU load at the cost of increased latency.' `
            -Fix ('Set-NetAdapterAdvancedProperty -Name "' + $nicName + '" -RegistryKeyword "*InterruptModeration" -RegistryValue 0')
    }

    # --- Check 15: Nagle Disabled ---
    $nagleStatus = 'UNKNOWN'
    try {
        $guid    = $nic.InterfaceGuid
        $ifPath  = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\' + $guid
        $ifProps = Get-ItemProperty $ifPath -ErrorAction Stop
        $ackFreq = $ifProps.TcpAckFrequency
        $noDelay = $ifProps.TCPNoDelay
        if ($ackFreq -eq 1 -and $noDelay -eq 1) {
            $nagleStatus = 'PASS'
        } else {
            $nagleStatus = 'FAIL:' + [string]$ackFreq + '/' + [string]$noDelay
        }
    } catch { $nagleStatus = 'MISSING' }

    if ($nagleStatus -eq 'PASS') {
        $results += New-CheckResult -Name 'Nagle Disabled' -Category 'NIC' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'TcpAckFrequency=1, TCPNoDelay=1' -Expected 'Both 1'
    } else {
        $guid    = $nic.InterfaceGuid
        $ifPath  = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\' + $guid
        $results += New-CheckResult -Name 'Nagle Disabled' -Category 'NIC' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'FAIL' -Current $nagleStatus -Expected 'TcpAckFrequency=1, TCPNoDelay=1' `
            -Message 'Nagle algorithm batches small TCP packets, adding 10-200ms latency to game state updates.' `
            -Fix ('Set-ItemProperty -Path "' + $ifPath + '" -Name TcpAckFrequency -Value 1 -Type DWord; Set-ItemProperty -Path "' + $ifPath + '" -Name TCPNoDelay -Value 1 -Type DWord') `
            -FixNote 'Settings are per-interface GUID and must be re-applied after NIC driver updates.'
    }

    # --- Check 16: NIC Interrupt Affinity ---
    $affinityStatus = 'UNKNOWN'
    $affinityDetail = ''
    try {
        $pnpId      = $nic.PnPDeviceID
        $affPath    = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $pnpId + '\Device Parameters\Interrupt Management\Affinity Policy'
        $affProps   = Get-ItemProperty $affPath -ErrorAction Stop
        $devPolicy  = $affProps.DevicePolicy
        $affSet     = $affProps.AssignmentSetOverride
        if ($null -ne $affSet -and $affSet.Count -ge 2) {
            $maskHex        = '0x' + (($affSet[1..0] | ForEach-Object { $_.ToString('X2') }) -join '')
            $affinityDetail = 'DevicePolicy=' + $devPolicy + ', Mask=' + $maskHex
            if ($devPolicy -eq 3 -or $devPolicy -eq 4) { $affinityStatus = 'PASS' } else { $affinityStatus = 'WARN' }
        } else {
            $affinityStatus = 'WARN'
            $affinityDetail = 'No affinity policy set (default: CPU 0 handles all NIC interrupts)'
        }
    } catch {
        $affinityStatus = 'WARN'
        $affinityDetail = 'Affinity key not found - default CPU 0 handling'
    }
    if ($affinityStatus -eq 'PASS') {
        $results += New-CheckResult -Name 'NIC Interrupt Affinity' -Category 'NIC' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'PASS' -Current $affinityDetail -Expected 'DevicePolicy=3 or 4 with affinity mask'
    } else {
        $pnpId   = $nic.PnPDeviceID
        $affPath = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $pnpId + '\Device Parameters\Interrupt Management\Affinity Policy'
        $results += New-CheckResult -Name 'NIC Interrupt Affinity' -Category 'NIC' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'WARN' -Current $affinityDetail -Expected 'DevicePolicy=4, CPUs 4-7 (mask 0xF0)' `
            -Message 'Default: all NIC interrupts handled by CPU 0, competing with game thread. Pin to non-game CPUs.' `
            -Fix ('New-Item -Path "' + $affPath + '" -Force | Out-Null; Set-ItemProperty -Path "' + $affPath + '" -Name DevicePolicy -Value 4 -Type DWord; Set-ItemProperty -Path "' + $affPath + '" -Name AssignmentSetOverride -Value ([byte[]](0xF0,0x00)) -Type Binary') `
            -FixNote 'Reboot required. Mask 0xF0 = CPUs 4-7 (adjust for your CPU topology).'
    }

    return $results
}
