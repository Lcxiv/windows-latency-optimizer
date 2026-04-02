#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Audit check functions for audit.ps1.
.DESCRIPTION
    Dot-sourced by audit.ps1. Contains all check functions and New-CheckResult helper.
    Each check function returns a hashtable matching the check result schema.
    Read-only — no system modifications.
#>

# ---------------------------------------------------------------------------
# Helper: Build a check result hashtable
# ---------------------------------------------------------------------------
function New-CheckResult {
    param(
        [string]$Name,
        [string]$Category,
        [string]$Tier,
        [string]$Severity,
        [string]$Status,
        [string]$Current  = '',
        [string]$Expected = '',
        [string]$Message  = '',
        [string]$Source   = '',
        [string]$Fix      = '',
        [string]$FixNote  = ''
    )
    return [ordered]@{
        name     = $Name
        category = $Category
        tier     = $Tier
        severity = $Severity
        status   = $Status
        current  = $Current
        expected = $Expected
        message  = $Message
        source   = $Source
        fix      = $Fix
        fixNote  = $FixNote
    }
}

# ---------------------------------------------------------------------------
# System information (called once by audit.ps1 before running checks)
# ---------------------------------------------------------------------------
function Get-SystemInfo {
    $info = [ordered]@{
        os        = ''
        build     = ''
        cpu       = ''
        gpu       = ''
        gpuDriver = ''
        ram       = ''
        nic       = ''
        nicDriver = ''
    }

    # OS
    $os = Get-WmiObject Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) {
        $info.os    = $os.Caption + ' Build ' + $os.BuildNumber
        $info.build = $os.BuildNumber
    }

    # CPU
    $cpu = Get-WmiObject Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cpu) { $info.cpu = $cpu.Name.Trim() }

    # GPU
    $gpu = Get-WmiObject Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gpu) {
        $info.gpu       = $gpu.Name
        $info.gpuDriver = $gpu.DriverVersion
    }

    # RAM — total + configured speed
    $dimms = Get-WmiObject Win32_PhysicalMemory -ErrorAction SilentlyContinue
    if ($dimms) {
        $totalMB = ($dimms | Measure-Object -Property Capacity -Sum).Sum / 1MB
        $speed   = ($dimms | Select-Object -First 1).ConfiguredClockSpeed
        $info.ram = [string][math]::Round($totalMB / 1024) + ' GB @ ' + $speed + ' MT/s'
    }

    # NIC
    $nic = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    if ($nic) {
        $info.nic       = $nic.InterfaceDescription
        $info.nicDriver = $nic.DriverVersion
    }

    return $info
}

# ---------------------------------------------------------------------------
# Quick Tier: OS Checks (1-10)
# ---------------------------------------------------------------------------
function Invoke-OsChecks {
    $results = @()

    # --- Check 1: MPO Disabled ---
    $mpoKey  = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    $mpoVal  = $null
    try { $mpoVal = (Get-ItemProperty $mpoKey -ErrorAction Stop).DisableOverlays } catch {}
    if ($null -eq $mpoVal) {
        $results += New-CheckResult -Name 'MPO Disabled' -Category 'OS' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'FAIL' -Current 'Not set (MPO enabled)' -Expected 'DisableOverlays = 1' `
            -Message 'MPO causes periodic frame-time spikes on NVIDIA GPUs (Win11 25H2 path).' `
            -Source 'https://www.ordoh.com/disable-mpo-windows-11-stutter-fix/' `
            -Fix 'reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v DisableOverlays /t REG_DWORD /d 1 /f' `
            -FixNote 'Reboot required'
    } elseif ($mpoVal -eq 1) {
        $results += New-CheckResult -Name 'MPO Disabled' -Category 'OS' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'PASS' -Current 'DisableOverlays = 1' -Expected 'DisableOverlays = 1' `
            -Message 'MPO correctly disabled.'
    } else {
        $results += New-CheckResult -Name 'MPO Disabled' -Category 'OS' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'FAIL' -Current ('DisableOverlays = ' + $mpoVal) -Expected 'DisableOverlays = 1' `
            -Message 'MPO is not disabled.' `
            -Fix 'reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v DisableOverlays /t REG_DWORD /d 1 /f' `
            -FixNote 'Reboot required'
    }

    # --- Check 2: Hyper-V Off ---
    $hvStatus = 'UNKNOWN'
    try {
        $bcd = bcdedit /enum '{current}' 2>&1 | Out-String
        $m   = [regex]::Match($bcd, 'hypervisorlaunchtype\s+(\S+)')
        if ($m.Success) { $hvStatus = $m.Groups[1].Value.ToLower() }
    } catch {}
    if ($hvStatus -eq 'off') {
        $results += New-CheckResult -Name 'Hyper-V Off' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'hypervisorlaunchtype = off' -Expected 'off'
    } elseif ($hvStatus -eq 'unknown') {
        $results += New-CheckResult -Name 'Hyper-V Off' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'ERROR' -Current 'bcdedit failed' -Expected 'off' -Message 'Could not read bcdedit output.'
    } else {
        $results += New-CheckResult -Name 'Hyper-V Off' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'FAIL' -Current ('hypervisorlaunchtype = ' + $hvStatus) -Expected 'off' `
            -Message 'Hyper-V adds 5-15ns latency to all memory operations and interrupts.' `
            -Fix 'bcdedit /set hypervisorlaunchtype off' -FixNote 'Reboot required. Disables WSL2/Docker Hyper-V backend.'
    }

    # --- Check 3: VBS/Core Isolation Off ---
    $vbsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
    $vbsVal = $null
    try { $vbsVal = (Get-ItemProperty $vbsKey -ErrorAction Stop).Enabled } catch {}
    if ($null -eq $vbsVal -or $vbsVal -eq 0) {
        $results += New-CheckResult -Name 'VBS/Core Isolation Off' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'Disabled' -Expected 'Disabled'
    } else {
        $results += New-CheckResult -Name 'VBS/Core Isolation Off' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'FAIL' -Current ('Enabled = ' + $vbsVal) -Expected '0 (Disabled)' `
            -Message 'VBS adds overhead to system calls and memory access.' `
            -Fix 'Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" -Name Enabled -Value 0 -Type DWord' `
            -FixNote 'Reboot required'
    }

    # --- Check 4: MMCSS SystemResponsiveness ---
    $mmcssKey  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    $sysResp   = $null
    try { $sysResp = (Get-ItemProperty $mmcssKey -ErrorAction Stop).SystemResponsiveness } catch {}
    if ($null -eq $sysResp) {
        $results += New-CheckResult -Name 'MMCSS SystemResponsiveness' -Category 'OS' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'WARN' -Current 'Not set (default 20)' -Expected '0' `
            -Message 'Default 20 reserves CPU time for background tasks during gaming.' `
            -Fix 'Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name SystemResponsiveness -Value 0 -Type DWord'
    } elseif ($sysResp -eq 0) {
        $results += New-CheckResult -Name 'MMCSS SystemResponsiveness' -Category 'OS' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'PASS' -Current '0' -Expected '0'
    } else {
        $results += New-CheckResult -Name 'MMCSS SystemResponsiveness' -Category 'OS' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'FAIL' -Current ([string]$sysResp) -Expected '0' `
            -Message 'Non-zero value throttles foreground apps in favor of background tasks.' `
            -Fix 'Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name SystemResponsiveness -Value 0 -Type DWord'
    }

    # --- Check 5: MMCSS NetworkThrottlingIndex ---
    $ntIdx = $null
    try { $ntIdx = (Get-ItemProperty $mmcssKey -ErrorAction Stop).NetworkThrottlingIndex } catch {}
    $ntExpected = 4294967295
    if ($null -eq $ntIdx) {
        $results += New-CheckResult -Name 'MMCSS NetworkThrottling' -Category 'OS' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'WARN' -Current 'Not set (throttled)' -Expected '0xFFFFFFFF (disabled)' `
            -Message 'Default network throttling limits packet rate during multimedia playback.' `
            -Fix 'Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name NetworkThrottlingIndex -Value 0xFFFFFFFF -Type DWord'
    } elseif ($ntIdx -eq $ntExpected -or $ntIdx -eq -1) {
        $results += New-CheckResult -Name 'MMCSS NetworkThrottling' -Category 'OS' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'PASS' -Current '0xFFFFFFFF' -Expected '0xFFFFFFFF'
    } else {
        $results += New-CheckResult -Name 'MMCSS NetworkThrottling' -Category 'OS' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'FAIL' -Current ([string]$ntIdx) -Expected '0xFFFFFFFF' `
            -Fix 'Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name NetworkThrottlingIndex -Value 0xFFFFFFFF -Type DWord'
    }

    # --- Check 6: MMCSS Games Priority ---
    $gamesKey  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'
    $gPriority = $null
    $gSFIO     = $null
    try {
        $gProps    = Get-ItemProperty $gamesKey -ErrorAction Stop
        $gPriority = $gProps.Priority
        $gSFIO     = $gProps.'SFIO Priority'
    } catch {}
    if ($null -eq $gPriority) {
        $results += New-CheckResult -Name 'MMCSS Games Priority' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'ERROR' -Current 'Key not found' -Expected 'Priority=6, SFIO Priority=High' `
            -Message 'MMCSS Games key missing.'
    } elseif ($gPriority -eq 6 -and $gSFIO -eq 'High') {
        $results += New-CheckResult -Name 'MMCSS Games Priority' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'PASS' -Current ('Priority=' + $gPriority + ', SFIO=' + $gSFIO) -Expected 'Priority=6, SFIO=High'
    } else {
        $results += New-CheckResult -Name 'MMCSS Games Priority' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ('Priority=' + $gPriority + ', SFIO=' + $gSFIO) -Expected 'Priority=6, SFIO=High' `
            -Fix 'Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" -Name Priority -Value 6 -Type DWord; Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" -Name ''SFIO Priority'' -Value ''High'''
    }

    # --- Check 7: Power Plan ---
    $powerOutput = powercfg /getactivescheme 2>&1 | Out-String
    $isHP        = $powerOutput -match '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'  # High Performance
    $isUP        = $powerOutput -match 'e9a42b02-d5df-448d-aa00-03f14749eb61'  # Ultimate Performance
    # Fallback: custom schemes get unique GUIDs — match by name
    if (-not $isHP -and -not $isUP) {
        $isHP = $powerOutput -match 'High Performance'
        $isUP = $powerOutput -match 'Ultimate Performance'
    }
    if ($isHP -or $isUP) {
        $schemeName = 'High Performance'
        if ($isUP) { $schemeName = 'Ultimate Performance' }
        $results += New-CheckResult -Name 'Power Plan' -Category 'OS' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'PASS' -Current $schemeName -Expected 'High/Ultimate Performance'
    } else {
        $m = [regex]::Match($powerOutput, '\((.+)\)')
        $currentName = 'Unknown'
        if ($m.Success) { $currentName = $m.Groups[1].Value.Trim() }
        $results += New-CheckResult -Name 'Power Plan' -Category 'OS' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'FAIL' -Current $currentName -Expected 'High or Ultimate Performance' `
            -Message 'Balanced/Power Saver plans throttle CPU frequency and increase latency.' `
            -Fix 'powercfg /setactive SCHEME_MIN' -FixNote 'SCHEME_MIN = High Performance. For Ultimate, requires creation first.'
    }

    # --- Check 8: Win32PrioritySeparation ---
    $priKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl'
    $priVal = $null
    try { $priVal = (Get-ItemProperty $priKey -ErrorAction Stop).Win32PrioritySeparation } catch {}
    if ($null -eq $priVal) {
        $results += New-CheckResult -Name 'Win32PrioritySeparation' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'ERROR' -Current 'Key not found' -Expected '0x26 (38) or 0x16 (22)'
    } elseif ($priVal -eq 38 -or $priVal -eq 22) {
        $results += New-CheckResult -Name 'Win32PrioritySeparation' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'PASS' -Current ('0x' + $priVal.ToString('X') + ' (' + $priVal + ')') -Expected '0x26 or 0x16'
    } else {
        $results += New-CheckResult -Name 'Win32PrioritySeparation' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ('0x' + $priVal.ToString('X') + ' (' + $priVal + ')') -Expected '0x26 (38) or 0x16 (22)' `
            -Message '0x26 = short, fixed-length, foreground-boosted quantum. Reduces context switch latency.' `
            -Fix 'Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" -Name Win32PrioritySeparation -Value 38 -Type DWord'
    }

    # --- Check 9: GameInput Duplicates ---
    $giPackages = @()
    try { $giPackages = @(Get-AppxPackage -Name '*GameInput*' -ErrorAction Stop) } catch {}
    if ($giPackages.Count -le 1) {
        $results += New-CheckResult -Name 'GameInput Duplicates' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'PASS' -Current ($giPackages.Count.ToString() + ' package(s)') -Expected '<= 1'
    } else {
        $versions = ($giPackages | ForEach-Object { $_.Version }) -join ', '
        $results += New-CheckResult -Name 'GameInput Duplicates' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'FAIL' -Current ($giPackages.Count.ToString() + ' packages: ' + $versions) -Expected '1 package' `
            -Message 'Duplicate GameInput packages compete for mouse/controller polling, causing system-wide hitches every few seconds.' `
            -Fix '' -FixNote 'Settings -> Apps -> search GameInput -> uninstall older version'
    }

    # --- Check 10: KB5077181 Stutter Bug ---
    $build = 0
    try { $build = [int](Get-WmiObject Win32_OperatingSystem -ErrorAction Stop).BuildNumber } catch {}
    if ($build -eq 26200) {
        $kbs    = Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.HotFixID -eq 'KB5077181' -or $_.HotFixID -eq 'KB5079473' }
        $kbList = ''
        if ($kbs) { $kbList = ($kbs | ForEach-Object { $_.HotFixID }) -join ', ' }
        if ($kbList -ne '') {
            $results += New-CheckResult -Name 'KB5077181 Stutter Bug' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
                -Status 'WARN' -Current ('Installed: ' + $kbList) -Expected 'FSO disabled as mitigation' `
                -Message 'KB5077181 introduced rhythmic gaming stutter on Build 26200 via FSO/DWM scheduling change.' `
                -Source 'https://www.notebookcheck.net/Reddit-erupts-over-KB5077181-New-update-triggers-rhythmic-gaming-stutter.1228602.0.html' `
                -Fix 'reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers" /v "C:\Program Files\Epic Games\Fortnite\FortniteGame\Binaries\Win64\FortniteClient-Win64-Shipping.exe" /t REG_SZ /d DISABLEDXMAXIMIZEDWINDOWEDMODE /f' `
                -FixNote 'Disables FSO for Fortnite as mitigation. No reboot required.'
        } else {
            $results += New-CheckResult -Name 'KB5077181 Stutter Bug' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
                -Status 'PASS' -Current 'KB5077181/KB5079473 not installed' -Expected 'Not installed or FSO disabled'
        }
    } else {
        $results += New-CheckResult -Name 'KB5077181 Stutter Bug' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'SKIP' -Current ('Build ' + $build) -Expected 'Build 26200 only' `
            -Message 'Check only applies to Windows 11 Build 26200.'
    }

    return $results
}

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
            if ($devPolicy -eq 4) { $affinityStatus = 'PASS' } else { $affinityStatus = 'WARN' }
        } else {
            $affinityStatus = 'WARN'
            $affinityDetail = 'No affinity policy set (default: CPU 0 handles all NIC interrupts)'
        }
    } catch {
        $affinityStatus = 'WARN'
        $affinityDetail = 'Affinity key not found — default CPU 0 handling'
    }
    if ($affinityStatus -eq 'PASS') {
        $results += New-CheckResult -Name 'NIC Interrupt Affinity' -Category 'NIC' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'PASS' -Current $affinityDetail -Expected 'DevicePolicy=4 (SpecifiedProcessors)'
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

# ---------------------------------------------------------------------------
# Quick Tier: GPU Checks (17-19)
# ---------------------------------------------------------------------------
function Invoke-GpuChecks {
    $results = @()

    # Detect NVIDIA GPU
    $nvKey = $null
    try {
        $nvKey = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -ErrorAction Stop |
            Where-Object { $_.PSChildName -like 'VEN_10DE*' } | Select-Object -First 1
    } catch {}

    if ($null -eq $nvKey) {
        $nv = New-CheckResult -Name 'GPU (all checks)' -Category 'GPU' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'SKIP' -Current 'No NVIDIA GPU found' -Expected 'NVIDIA GPU'
        $results += $nv
        return $results
    }

    # --- Check 17: GPU MSI Mode ---
    $msiPath = $nvKey.PSPath + '\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties'
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
            -Message 'Line-based interrupts are less efficient than MSI and can cause DPC spikes.' `
            -Fix ('Set-ItemProperty -Path "' + $msiPath + '" -Name MSISupported -Value 1 -Type DWord') `
            -FixNote 'Reboot required.'
    }

    # --- Check 18: GPU Interrupt Affinity ---
    $gpuAffPath    = $nvKey.PSPath + '\Device Parameters\Interrupt Management\Affinity Policy'
    $gpuAffDetail  = 'Not set (default CPU 0)'
    $gpuAffStatus  = 'WARN'
    try {
        $gpuAff    = Get-ItemProperty $gpuAffPath -ErrorAction Stop
        $gpuPolicy = $gpuAff.DevicePolicy
        $gpuSet    = $gpuAff.AssignmentSetOverride
        if ($null -ne $gpuSet -and $gpuSet.Count -ge 2 -and $gpuPolicy -eq 4) {
            $maskHex      = '0x' + (($gpuSet[1..0] | ForEach-Object { $_.ToString('X2') }) -join '')
            $gpuAffDetail = 'DevicePolicy=4, Mask=' + $maskHex
            $gpuAffStatus = 'PASS'
        } elseif ($null -ne $gpuPolicy) {
            $gpuAffDetail = 'DevicePolicy=' + $gpuPolicy + ' (not SpecifiedProcessors)'
        }
    } catch {}

    if ($gpuAffStatus -eq 'PASS') {
        $results += New-CheckResult -Name 'GPU Interrupt Affinity' -Category 'GPU' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'PASS' -Current $gpuAffDetail -Expected 'DevicePolicy=4 (SpecifiedProcessors)'
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
# Deep Tier: Memory Checks (20)
# ---------------------------------------------------------------------------
function Invoke-MemoryChecks {
    $results = @()

    # --- Check 20: RAM Speed vs Rated ---
    $dimms = @()
    try { $dimms = @(Get-WmiObject Win32_PhysicalMemory -ErrorAction Stop) } catch {}
    if ($dimms.Count -eq 0) {
        $results += New-CheckResult -Name 'RAM Speed vs Rated' -Category 'Memory' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'ERROR' -Current 'WMI query failed' -Expected 'Configured >= JEDEC Speed'
    } else {
        $configured = $dimms[0].ConfiguredClockSpeed
        $jedec      = $dimms[0].Speed
        $totalGB    = [math]::Round(($dimms | Measure-Object -Property Capacity -Sum).Sum / 1GB)
        if ($configured -ge $jedec -and $configured -gt 4800) {
            $results += New-CheckResult -Name 'RAM Speed vs Rated' -Category 'Memory' -Tier 'Deep' -Severity 'HIGH' `
                -Status 'PASS' -Current ($configured.ToString() + ' MT/s') -Expected 'XMP/EXPO profile active'
        } elseif ($configured -eq $jedec -or $configured -le 4800) {
            $results += New-CheckResult -Name 'RAM Speed vs Rated' -Category 'Memory' -Tier 'Deep' -Severity 'HIGH' `
                -Status 'WARN' -Current ($configured.ToString() + ' MT/s (JEDEC default)') -Expected 'XMP/EXPO rated speed' `
                -Message 'RAM running at JEDEC default. Enable XMP/EXPO in BIOS to reach rated speed.' `
                -Fix '' -FixNote 'BIOS setting: EXPO/XMP Profile 1. No OS change needed.'
        } else {
            $results += New-CheckResult -Name 'RAM Speed vs Rated' -Category 'Memory' -Tier 'Deep' -Severity 'HIGH' `
                -Status 'PASS' -Current ($configured.ToString() + ' MT/s') -Expected 'XMP/EXPO active'
        }
    }

    return $results
}

# ---------------------------------------------------------------------------
# Deep Tier: Peripheral Checks (21-23)
# ---------------------------------------------------------------------------
function Invoke-PeripheralChecks {
    $results = @()

    # --- Check 21: Mouse Polling Rate Risk ---
    $knownMouseVIDs = @('VID_1532', 'VID_046D', 'VID_1038', 'VID_093A', 'VID_258A')
    $mouseFound     = $false
    $mouseDesc      = ''
    try {
        $hidDevices = Get-WmiObject Win32_PnPEntity -Filter "Service='HidUsb' OR Service='mouhid'" -ErrorAction Stop
        foreach ($dev in $hidDevices) {
            foreach ($vid in $knownMouseVIDs) {
                if ($dev.DeviceID -like ('*' + $vid + '*')) {
                    $mouseFound = $true
                    $mouseDesc  = $dev.Description
                    break
                }
            }
            if ($mouseFound) { break }
        }
    } catch {}

    if (-not $mouseFound) {
        $results += New-CheckResult -Name 'Mouse Polling Rate' -Category 'Peripheral' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'SKIP' -Current 'No known gaming mouse VID detected' -Expected 'Razer/Logitech/SteelSeries/etc.'
    } else {
        # Check if companion software is running
        $companionProcs = @('RazerCentralService','Razer Synapse','LGHUB','SteelSeriesEngine','GHub','iCUE','GHUB')
        $running        = $false
        foreach ($proc in $companionProcs) {
            if (Get-Process -Name $proc -ErrorAction SilentlyContinue) { $running = $true; break }
        }
        if ($running) {
            $results += New-CheckResult -Name 'Mouse Polling Rate' -Category 'Peripheral' -Tier 'Deep' -Severity 'HIGH' `
                -Status 'PASS' -Current ($mouseDesc + ' + companion software running') -Expected 'Companion software running'
        } else {
            $results += New-CheckResult -Name 'Mouse Polling Rate' -Category 'Peripheral' -Tier 'Deep' -Severity 'HIGH' `
                -Status 'WARN' -Current ($mouseDesc + ' — no companion software detected') -Expected 'Companion software running for polling config' `
                -Message 'Without companion software, most gaming mice default to 125Hz (8ms update interval vs 1ms at 1000Hz). Razer mice without Synapse default to 125Hz.' `
                -Fix '' -FixNote 'Install companion software, set polling to 1000Hz, save to onboard memory, then uninstall if desired.'
        }
    }

    # --- Check 22: Capture Card Present ---
    $captureVIDs = @('VID_07CA', 'VID_0FD9', 'VID_1CEA')  # AVerMedia, Elgato, Magewell
    $captureFound = $false
    $captureDesc  = ''
    try {
        $usbDevs = Get-WmiObject Win32_PnPEntity -ErrorAction Stop
        foreach ($dev in $usbDevs) {
            foreach ($vid in $captureVIDs) {
                if ($dev.DeviceID -like ('*' + $vid + '*')) {
                    $captureFound = $true
                    $captureDesc  = $dev.Description
                    break
                }
            }
            if ($captureFound) { break }
        }
    } catch {}

    if ($captureFound) {
        $results += New-CheckResult -Name 'Capture Card Present' -Category 'Peripheral' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ('Found: ' + $captureDesc) -Expected 'Disconnected when not streaming' `
            -Message 'Active capture cards add DPC overhead from continuous frame processing. Disconnect when not streaming.' `
            -Fix '' -FixNote 'Physically disconnect USB capture card when gaming without streaming.'
    } else {
        $results += New-CheckResult -Name 'Capture Card Present' -Category 'Peripheral' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'No capture card detected' -Expected 'Not present'
    }

    # --- Check 23: Overlay Processes ---
    $overlayProcs = @(
        @{ Name='Discord';        Exe='Discord' },
        @{ Name='GeForce Overlay';Exe='NVTMRMON' },
        @{ Name='Xbox Game Bar';  Exe='GameBar' },
        @{ Name='Steam Overlay';  Exe='GameOverlayUI' },
        @{ Name='NZXT CAM';       Exe='NZXT CAM' }
    )
    $foundOverlays = @()
    foreach ($o in $overlayProcs) {
        if (Get-Process -Name $o.Exe -ErrorAction SilentlyContinue) {
            $foundOverlays += $o.Name
        }
    }
    if ($foundOverlays.Count -eq 0) {
        $results += New-CheckResult -Name 'Overlay Processes' -Category 'Peripheral' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'No overlay processes detected' -Expected 'None running'
    } else {
        $results += New-CheckResult -Name 'Overlay Processes' -Category 'Peripheral' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ('Running: ' + ($foundOverlays -join ', ')) -Expected 'None during gaming' `
            -Message 'Overlay processes hook into the graphics pipeline and can cause frame-time spikes.' `
            -Fix '' -FixNote 'Close listed processes before gaming. Disable auto-start in each app settings.'
    }

    return $results
}

# ---------------------------------------------------------------------------
# Deep Tier: Network Checks (24-32)
# ---------------------------------------------------------------------------
function Invoke-NetworkChecks {
    $results = @()

    # Read netsh tcp globals once
    $tcpGlobal = netsh int tcp show global 2>&1 | Out-String

    # --- Check 24: TCP Auto-Tuning ---
    $atMatch = [regex]::Match($tcpGlobal, 'Receive Window Auto-Tuning Level\s*:\s*(\S+)')
    $atVal   = ''
    if ($atMatch.Success) { $atVal = $atMatch.Groups[1].Value.ToLower() }
    if ($atVal -eq 'restricted') {
        $results += New-CheckResult -Name 'TCP Auto-Tuning' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'restricted' -Expected 'restricted'
    } elseif ($atVal -eq '') {
        $results += New-CheckResult -Name 'TCP Auto-Tuning' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'ERROR' -Current 'Could not parse netsh output' -Expected 'restricted'
    } else {
        $results += New-CheckResult -Name 'TCP Auto-Tuning' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current $atVal -Expected 'restricted' `
            -Message 'Normal auto-tuning can over-allocate receive buffers, increasing bufferbloat.' `
            -Fix 'netsh int tcp set global autotuninglevel=restricted'
    }

    # --- Check 25: TCP Timestamps ---
    $tsMatch = [regex]::Match($tcpGlobal, 'Timestamps\s*:\s*(\S+)')
    $tsVal   = ''
    if ($tsMatch.Success) { $tsVal = $tsMatch.Groups[1].Value.ToLower() }
    if ($tsVal -eq 'disabled') {
        $results += New-CheckResult -Name 'TCP Timestamps' -Category 'Network' -Tier 'Deep' -Severity 'LOW' `
            -Status 'PASS' -Current 'disabled' -Expected 'disabled'
    } else {
        $tsCurrent = $tsVal
        if ($tsCurrent -eq '') { $tsCurrent = 'unknown' }
        $results += New-CheckResult -Name 'TCP Timestamps' -Category 'Network' -Tier 'Deep' -Severity 'LOW' `
            -Status 'WARN' -Current $tsCurrent -Expected 'disabled' `
            -Fix 'netsh int tcp set global timestamps=disabled'
    }

    # --- Check 26: TCP RSC ---
    $rscMatch = [regex]::Match($tcpGlobal, 'Receive Segment Coalescing State\s*:\s*(\S+)')
    $rscVal   = ''
    if ($rscMatch.Success) { $rscVal = $rscMatch.Groups[1].Value.ToLower() }
    if ($rscVal -eq 'disabled') {
        $results += New-CheckResult -Name 'TCP RSC' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'disabled' -Expected 'disabled'
    } else {
        $rscCurrent = $rscVal
        if ($rscCurrent -eq '') { $rscCurrent = 'unknown' }
        $results += New-CheckResult -Name 'TCP RSC' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current $rscCurrent -Expected 'disabled' `
            -Message 'RSC coalesces received segments, adding latency in exchange for CPU savings.' `
            -Fix 'netsh int tcp set global rsc=disabled'
    }

    # --- Check 27: TCP InitialRTO ---
    $rtoMatch = [regex]::Match($tcpGlobal, 'Initial RTO\s*:\s*(\d+)')
    $rtoVal   = -1
    if ($rtoMatch.Success) { $rtoVal = [int]$rtoMatch.Groups[1].Value }
    if ($rtoVal -eq 300) {
        $results += New-CheckResult -Name 'TCP InitialRTO' -Category 'Network' -Tier 'Deep' -Severity 'LOW' `
            -Status 'PASS' -Current '300' -Expected '300'
    } elseif ($rtoVal -eq -1) {
        $results += New-CheckResult -Name 'TCP InitialRTO' -Category 'Network' -Tier 'Deep' -Severity 'LOW' `
            -Status 'ERROR' -Current 'Could not parse' -Expected '300'
    } else {
        $results += New-CheckResult -Name 'TCP InitialRTO' -Category 'Network' -Tier 'Deep' -Severity 'LOW' `
            -Status 'WARN' -Current ([string]$rtoVal) -Expected '300' `
            -Message 'Default 3000ms initial retransmit timeout causes 3-second freeze on first packet loss.' `
            -Fix 'netsh int tcp set global initialRto=300'
    }

    # --- Check 28: NIC IPv6 ---
    $nic = $null
    try {
        $nic = Get-NetAdapter -Physical -ErrorAction Stop |
            Where-Object { $_.Status -eq 'Up' -and $_.MediaType -ne 'Native 802.11' } |
            Select-Object -First 1
    } catch {}
    if ($null -eq $nic) {
        $results += New-CheckResult -Name 'NIC IPv6 Disabled' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'SKIP' -Current 'No active wired NIC' -Expected 'Active NIC'
    } else {
        $ipv6Binding = $null
        try { $ipv6Binding = Get-NetAdapterBinding -Name $nic.Name -ComponentID 'ms_tcpip6' -ErrorAction Stop } catch {}
        if ($null -eq $ipv6Binding) {
            $results += New-CheckResult -Name 'NIC IPv6 Disabled' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
                -Status 'SKIP' -Current 'Could not read binding' -Expected 'Disabled'
        } elseif (-not $ipv6Binding.Enabled) {
            $results += New-CheckResult -Name 'NIC IPv6 Disabled' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
                -Status 'PASS' -Current 'IPv6 disabled' -Expected 'Disabled'
        } else {
            $results += New-CheckResult -Name 'NIC IPv6 Disabled' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
                -Status 'WARN' -Current 'IPv6 enabled' -Expected 'Disabled' `
                -Message 'IPv6 on I226-V can cause dual-stack resolution delays and additional interrupt overhead.' `
                -Fix ('Disable-NetAdapterBinding -Name "' + $nic.Name + '" -ComponentID ms_tcpip6')
        }
    }

    # --- Check 29: NIC Flow Control ---
    $fcResult = 'SKIP'
    $fcDetail = ''
    if ($null -ne $nic) {
        $fc = $null
        try {
            $fc = Get-NetAdapterAdvancedProperty -Name $nic.Name -ErrorAction SilentlyContinue |
                Where-Object { $_.RegistryKeyword -eq '*FlowControl' } | Select-Object -First 1
        } catch {}
        if ($null -ne $fc) {
            $fcDetail = [string]$fc.RegistryValue
            if ($fc.RegistryValue -eq 0) { $fcResult = 'PASS' } else { $fcResult = 'WARN' }
        }
    }
    if ($fcResult -eq 'PASS') {
        $results += New-CheckResult -Name 'NIC Flow Control' -Category 'Network' -Tier 'Deep' -Severity 'LOW' `
            -Status 'PASS' -Current 'Disabled (0)' -Expected 'Disabled'
    } elseif ($fcResult -eq 'WARN') {
        $results += New-CheckResult -Name 'NIC Flow Control' -Category 'Network' -Tier 'Deep' -Severity 'LOW' `
            -Status 'WARN' -Current ('Value ' + $fcDetail) -Expected 'Disabled (0)' `
            -Message 'Flow control pauses can add variable latency spikes.' `
            -Fix ('Set-NetAdapterAdvancedProperty -Name "' + $nic.Name + '" -RegistryKeyword "*FlowControl" -RegistryValue 0')
    } else {
        $results += New-CheckResult -Name 'NIC Flow Control' -Category 'Network' -Tier 'Deep' -Severity 'LOW' `
            -Status 'SKIP' -Current 'No active NIC or property not found' -Expected 'Disabled'
    }

    # --- Check 30: Defender CPU Limit ---
    $defCPU = $null
    try {
        $mp     = Get-MpPreference -ErrorAction Stop
        $defCPU = $mp.ScanAvgCPULoadFactor
    } catch {}
    if ($null -eq $defCPU) {
        $results += New-CheckResult -Name 'Defender CPU Limit' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'ERROR' -Current 'Could not read MpPreference' -Expected '<= 10'
    } elseif ($defCPU -le 10) {
        $results += New-CheckResult -Name 'Defender CPU Limit' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'PASS' -Current ([string]$defCPU + '%') -Expected '<= 10%'
    } else {
        $results += New-CheckResult -Name 'Defender CPU Limit' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ([string]$defCPU + '%') -Expected '<= 10%' `
            -Message 'High Defender CPU limit allows scans to steal CPU time during gaming.' `
            -Fix 'Set-MpPreference -ScanAvgCPULoadFactor 10'
    }

    # --- Check 32: Network Latency Probe ---
    $targets = @(
        @{ Host='8.8.8.8';          Name='Cloudflare DNS' },
        @{ Host='epicgames.com';     Name='Epic Games' }
    )
    $probeLines = @()
    $worstP99   = 0
    foreach ($t in $targets) {
        $pings = @()
        try {
            1..10 | ForEach-Object {
                $r = Test-Connection -ComputerName $t.Host -Count 1 -ErrorAction Stop
                $pings += $r.ResponseTime
            }
        } catch {}
        if ($pings.Count -gt 0) {
            $sorted = $pings | Sort-Object
            $p50    = $sorted[[math]::Floor($sorted.Count * 0.50)]
            $p99    = $sorted[$sorted.Count - 1]
            if ($p99 -gt $worstP99) { $worstP99 = $p99 }
            $probeLines += ($t.Name + ': p50=' + $p50 + 'ms p99=' + $p99 + 'ms')
        } else {
            $probeLines += ($t.Name + ': unreachable')
        }
    }
    $probeSummary = $probeLines -join '; '
    if ($worstP99 -lt 50) {
        $results += New-CheckResult -Name 'Network Latency Probe' -Category 'Network' -Tier 'Deep' -Severity 'INFO' `
            -Status 'PASS' -Current $probeSummary -Expected 'p99 < 50ms'
    } elseif ($worstP99 -lt 100) {
        $results += New-CheckResult -Name 'Network Latency Probe' -Category 'Network' -Tier 'Deep' -Severity 'INFO' `
            -Status 'WARN' -Current $probeSummary -Expected 'p99 < 50ms' `
            -Message 'High p99 latency. Check for background downloads, ISP throttling, or bufferbloat.'
    } else {
        $results += New-CheckResult -Name 'Network Latency Probe' -Category 'Network' -Tier 'Deep' -Severity 'INFO' `
            -Status 'FAIL' -Current $probeSummary -Expected 'p99 < 50ms' `
            -Message 'Very high p99 latency. Likely bufferbloat or ISP congestion. Run a bufferbloat test at waveform.com/tools/bufferbloat'
    }

    return $results
}
