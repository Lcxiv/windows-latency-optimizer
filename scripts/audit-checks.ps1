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

    # GPU — prefer dedicated adapter over Basic Display Adapter
    $gpus = @(Get-WmiObject Win32_VideoController -ErrorAction SilentlyContinue)
    $gpu  = $gpus | Where-Object { $_.Name -notlike '*Basic*' -and $_.Status -eq 'OK' } | Select-Object -First 1
    if ($null -eq $gpu) { $gpu = $gpus | Select-Object -First 1 }
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

    # --- Check 10: KB5077181 Stutter Bug (with multi-game FSO scan) ---
    $build = 0
    try { $build = [int](Get-WmiObject Win32_OperatingSystem -ErrorAction Stop).BuildNumber } catch {}
    if ($build -eq 26200) {
        $kbs    = Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.HotFixID -eq 'KB5077181' -or $_.HotFixID -eq 'KB5079473' }
        $kbList = ''
        if ($kbs) { $kbList = ($kbs | ForEach-Object { $_.HotFixID }) -join ', ' }
        if ($kbList -ne '') {
            # Scan for game executables missing FSO mitigation
            $gameDirs = @(
                'C:\Program Files\Epic Games',
                'C:\Program Files (x86)\Steam\steamapps\common',
                'D:\SteamLibrary\steamapps\common',
                'E:\SteamLibrary\steamapps\common',
                'C:\Program Files\Riot Games'
            )
            # Auto-discover from Epic manifests
            $mfPath = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
            if (Test-Path $mfPath) {
                Get-ChildItem $mfPath -Filter '*.item' -ErrorAction SilentlyContinue | ForEach-Object {
                    $mf = Get-Content $_.FullName -Raw | ConvertFrom-Json
                    if ($mf.InstallLocation -and (Test-Path $mf.InstallLocation)) {
                        $gameDirs += $mf.InstallLocation
                    }
                }
            }
            $gameDirs = @($gameDirs | Select-Object -Unique)
            $gameExes = @(
                'FortniteClient-Win64-Shipping.exe', 'FPSAimTrainer.exe', 'cs2.exe',
                'VALORANT-Win64-Shipping.exe', 'r5apex.exe', 'OverwatchOW.exe',
                'RocketLeague.exe', 'PUBG-Win64-Shipping.exe', 'warhammer3.exe',
                'destiny2.exe', 'eldenring.exe', 'GTA5.exe'
            )
            $foundGames  = @()
            $missingFso  = @()
            $layersKey   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
            $layerProps  = $null
            if (Test-Path $layersKey) { $layerProps = Get-ItemProperty $layersKey -ErrorAction SilentlyContinue }

            foreach ($dir in $gameDirs) {
                if (-not (Test-Path $dir)) { continue }
                foreach ($exe in $gameExes) {
                    $f = @(Get-ChildItem $dir -Filter $exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
                    if ($f.Count -gt 0) {
                        $foundGames += $f[0].FullName
                        $hasFso = $false
                        if ($null -ne $layerProps) {
                            $val = $layerProps.($f[0].FullName)
                            if ($val -eq 'DISABLEDXMAXIMIZEDWINDOWEDMODE') { $hasFso = $true }
                        }
                        if (-not $hasFso) { $missingFso += $f[0].FullName }
                    }
                }
            }

            $fsoStatus = $foundGames.Count.ToString() + ' games found, ' + $missingFso.Count + ' missing FSO disable'
            if ($missingFso.Count -eq 0 -and $foundGames.Count -gt 0) {
                $results += New-CheckResult -Name 'KB5077181 Stutter Bug' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
                    -Status 'PASS' -Current ('Installed: ' + $kbList + ' | FSO mitigated for all ' + $foundGames.Count + ' games') -Expected 'FSO disabled for all games'
            } else {
                $fixCmd = '.\scripts\exp13_fso_mitigation_apply.ps1'
                $fixNote = 'Run exp13_fso_mitigation_apply.ps1 to apply FSO disable to all detected games. No reboot required.'
                if ($missingFso.Count -gt 0) {
                    $fixNote = 'Missing FSO: ' + ($missingFso -join ', ') + '. Run exp13_fso_mitigation_apply.ps1'
                }
                $results += New-CheckResult -Name 'KB5077181 Stutter Bug' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
                    -Status 'WARN' -Current ('Installed: ' + $kbList + ' | ' + $fsoStatus) -Expected 'FSO disabled for all games' `
                    -Message 'KB5077181 introduced rhythmic gaming stutter on Build 26200 via FSO/DWM scheduling change.' `
                    -Source 'https://www.notebookcheck.net/Reddit-erupts-over-KB5077181-New-update-triggers-rhythmic-gaming-stutter.1228602.0.html' `
                    -Fix $fixCmd -FixNote $fixNote
            }
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
    # Known Razer PIDs for model detection
    $razerMice = @{
        '00C1' = 'Viper V3 Pro (Wireless)'; '00C0' = 'Viper V3 Pro (Wired)'
        '00B6' = 'Viper V3 HyperSpeed';     '00AA' = 'Basilisk V3 Pro'
        '008A' = 'Viper Ultimate';           '007A' = 'Viper'
        '0078' = 'DeathAdder V2';            '0084' = 'DeathAdder V2 Pro'
        '009C' = 'DeathAdder V3';            '00B2' = 'DeathAdder V3 Pro'
        '0098' = 'Basilisk V3';              '00A5' = 'Cobra Pro'
    }
    $knownMouseVIDs = @('VID_1532', 'VID_046D', 'VID_1038', 'VID_093A', 'VID_258A')
    $mouseFound  = $false
    $mouseDesc   = ''
    $mouseBrand  = ''
    $mouseModel  = ''
    try {
        $hidDevices = Get-WmiObject Win32_PnPEntity -Filter "Service='HidUsb' OR Service='mouhid'" -ErrorAction Stop
        foreach ($dev in $hidDevices) {
            if ($dev.DeviceID -like '*VID_1532*') {
                $mouseFound = $true
                $mouseBrand = 'Razer'
                $mouseDesc  = $dev.Description
                if ($dev.DeviceID -match 'PID_([0-9A-F]+)') {
                    $mousePid = $Matches[1]
                    if ($razerMice.ContainsKey($mousePid)) { $mouseModel = 'Razer ' + $razerMice[$mousePid] }
                    else { $mouseModel = 'Razer Mouse (PID ' + $mousePid + ')' }
                }
                break
            }
            foreach ($vid in $knownMouseVIDs) {
                if ($dev.DeviceID -like ('*' + $vid + '*')) {
                    $mouseFound = $true
                    $mouseDesc  = $dev.Description
                    if ($vid -eq 'VID_046D') { $mouseBrand = 'Logitech' }
                    elseif ($vid -eq 'VID_1038') { $mouseBrand = 'SteelSeries' }
                    else { $mouseBrand = 'Gaming mouse' }
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
        $displayName = $mouseModel
        if ($displayName -eq '') { $displayName = $mouseBrand + ' ' + $mouseDesc }

        # Check if companion software is installed or running
        $companionProcs = @('RazerCentralService','Razer Synapse','LGHUB','SteelSeriesEngine','GHub','iCUE','GHUB')
        $running = $false
        foreach ($proc in $companionProcs) {
            if (Get-Process -Name $proc -ErrorAction SilentlyContinue) { $running = $true; break }
        }

        # Also check if Synapse/GHUB is installed (even if not running — polling saved to firmware)
        $companionInstalled = $false
        $installedApps = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
        $installedApps += Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
        foreach ($app in $installedApps) {
            if ($app.DisplayName -like '*Razer*Synapse*' -or $app.DisplayName -like '*Logitech*G*HUB*' -or $app.DisplayName -like '*SteelSeries*') {
                $companionInstalled = $true
                break
            }
        }

        if ($running -or $companionInstalled) {
            $status = 'configured'
            if ($running) { $status = 'running' }
            $results += New-CheckResult -Name 'Mouse Polling Rate' -Category 'Peripheral' -Tier 'Deep' -Severity 'HIGH' `
                -Status 'PASS' -Current ($displayName + ' — companion software ' + $status) -Expected 'Polling rate configured'
        } else {
            $fixCmd = '.\scripts\fix_razer_polling.ps1'
            $fixNote = 'Downloads Razer Synapse, set polling to 1000Hz+, save to onboard memory, then uninstall Synapse.'
            if ($mouseBrand -eq 'Logitech') {
                $fixCmd = ''
                $fixNote = 'Install Logitech G Hub from https://www.logitechg.com/en-us/innovation/g-hub.html, set 1000Hz, save to onboard.'
            } elseif ($mouseBrand -eq 'SteelSeries') {
                $fixCmd = ''
                $fixNote = 'Install SteelSeries GG from https://steelseries.com/gg, set 1000Hz, save to onboard.'
            }
            $results += New-CheckResult -Name 'Mouse Polling Rate' -Category 'Peripheral' -Tier 'Deep' -Severity 'HIGH' `
                -Status 'WARN' -Current ($displayName + ' — no companion software') -Expected 'Polling rate set to 1000Hz+' `
                -Message ('Without companion software, ' + $mouseBrand + ' mice default to 125Hz (8ms input delay vs 1ms at 1000Hz).') `
                -Fix $fixCmd -FixNote $fixNote
        }
    }

    # --- Check 21b: Mouse USB Controller Topology ---
    if ($mouseFound) {
        $mouseControllerStatus = 'SKIP'
        $mouseControllerCurrent = 'Could not determine USB controller'
        $mouseControllerMsg = ''
        $mouseControllerFix = ''
        $mouseControllerFixNote = ''
        try {
            # Find the mouse's USB device entry and trace its parent controller
            $mouseDevId = ''
            foreach ($dev in $hidDevices) {
                if ($dev.DeviceID -like '*VID_1532*' -or ($mouseBrand -ne '' -and $dev.DeviceID -like ('*' + $dev.DeviceID.Substring(0,17) + '*'))) {
                    $mouseDevId = $dev.DeviceID
                    break
                }
            }

            # Walk up the PnP device tree to find the USB host controller
            $controllerName = ''
            $controllerShared = $false
            $sharedWith = ''
            if ($mouseDevId -ne '') {
                # Get all USB host controllers
                $usbControllers = Get-WmiObject Win32_PnPEntity -ErrorAction SilentlyContinue |
                    Where-Object { $_.DeviceID -like 'PCI\VEN_1022&DEV_15B*' -or $_.DeviceID -like 'PCI\VEN_1022&DEV_43F*' }

                # Check which USB controller tree contains the mouse device
                $usbChildren = Get-WmiObject Win32_PnPEntity -ErrorAction SilentlyContinue |
                    Where-Object { $_.DeviceID -like 'USB\*VID_1532*' }
                if ($usbChildren) {
                    $usbChild = $usbChildren | Select-Object -First 1
                    $usbPath = $usbChild.DeviceID

                    # Determine USB version from controller PCI ID
                    $isUsb3 = $false
                    foreach ($ctrl in $usbControllers) {
                        # Check if device is a descendant by matching root hub pattern
                        if ($ctrl.DeviceID -like '*DEV_15B6*') { $controllerName = 'USB 3.1 xHCI (DEV_15B6)' }
                        elseif ($ctrl.DeviceID -like '*DEV_15B7*') { $controllerName = 'USB 3.1 xHCI (DEV_15B7)' }
                        elseif ($ctrl.DeviceID -like '*DEV_43F7*') { $controllerName = 'USB 3.2 xHCI (DEV_43F7)'; $isUsb3 = $true }
                        elseif ($ctrl.DeviceID -like '*DEV_15B8*') { $controllerName = 'USB 3.1 xHCI (DEV_15B8)' }
                    }

                    # Check if GPU or NIC uses same controller affinity CPUs
                    # Read interrupt affinities from registry to detect sharing
                    $mouseOnCpus = ''
                    $gpuOnCpus = ''
                    $nicOnCpus = ''
                    $usbAffKeys = @('USB_15B6','USB_15B7','USB_43F7','USB_15B8')
                    foreach ($uKey in $usbAffKeys) {
                        $uPat = $uKey.Replace('USB_','VEN_1022&DEV_')
                        $dk = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -ErrorAction SilentlyContinue |
                            Where-Object { $_.PSChildName -like ('*' + $uPat + '*') } | Select-Object -First 1
                        if ($dk) {
                            $affPath = Join-Path $dk.PSPath 'Device Parameters\Interrupt Management\Affinity Policy'
                            if (Test-Path $affPath) {
                                $v = Get-ItemProperty $affPath -ErrorAction SilentlyContinue
                                if ($v.AssignmentSetOverride) {
                                    $mask = '0x' + $v.AssignmentSetOverride[0].ToString('X2')
                                    $mouseOnCpus = $mask
                                }
                            }
                        }
                    }
                    # Get GPU affinity
                    $gpuKey = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -ErrorAction SilentlyContinue |
                        Where-Object { $_.PSChildName -like '*VEN_10DE*' } | Select-Object -First 1
                    if ($gpuKey) {
                        $affPath = Join-Path $gpuKey.PSPath 'Device Parameters\Interrupt Management\Affinity Policy'
                        if (Test-Path $affPath) {
                            $v = Get-ItemProperty $affPath -ErrorAction SilentlyContinue
                            if ($v.AssignmentSetOverride) { $gpuOnCpus = '0x' + $v.AssignmentSetOverride[0].ToString('X2') }
                        }
                    }
                    # Get NIC affinity
                    $nicKey = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -ErrorAction SilentlyContinue |
                        Where-Object { $_.PSChildName -like '*VEN_8086&DEV_125C*' } | Select-Object -First 1
                    if ($nicKey) {
                        $affPath = Join-Path $nicKey.PSPath 'Device Parameters\Interrupt Management\Affinity Policy'
                        if (Test-Path $affPath) {
                            $v = Get-ItemProperty $affPath -ErrorAction SilentlyContinue
                            if ($v.AssignmentSetOverride) { $nicOnCpus = '0x' + $v.AssignmentSetOverride[0].ToString('X2') }
                        }
                    }

                    if ($mouseOnCpus -ne '' -and ($mouseOnCpus -eq $gpuOnCpus -or $mouseOnCpus -eq $nicOnCpus)) {
                        $controllerShared = $true
                        if ($mouseOnCpus -eq $gpuOnCpus) { $sharedWith = 'GPU' }
                        if ($mouseOnCpus -eq $nicOnCpus) {
                            if ($sharedWith -ne '') { $sharedWith = $sharedWith + ' and NIC' }
                            else { $sharedWith = 'NIC' }
                        }
                    }

                    if ($controllerShared) {
                        $mouseControllerStatus = 'WARN'
                        $mouseControllerCurrent = 'Mouse shares interrupt CPUs (' + $mouseOnCpus + ') with ' + $sharedWith
                        $mouseControllerMsg = 'Mouse USB controller shares CPUs with ' + $sharedWith + '. High DPC load from ' + $sharedWith + ' can stall mouse input processing.'
                        $mouseControllerFixNote = 'Move the mouse dongle to a USB port on a different controller, or reassign interrupt affinity so mouse and ' + $sharedWith + ' use separate CPUs.'
                    } else {
                        $mouseControllerStatus = 'PASS'
                        $detail = 'dedicated controller'
                        if ($mouseOnCpus -ne '') { $detail = $detail + ' (CPUs ' + $mouseOnCpus + ')' }
                        $mouseControllerCurrent = $displayName + ' on ' + $detail
                    }
                } else {
                    $mouseControllerCurrent = 'Mouse USB device not found in PnP tree'
                }
            }
        } catch {
            $mouseControllerCurrent = 'Detection failed: ' + $_.Exception.Message
        }

        $results += New-CheckResult -Name 'Mouse USB Controller' -Category 'Peripheral' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status $mouseControllerStatus -Current $mouseControllerCurrent -Expected 'Mouse on dedicated USB controller, not shared with GPU/NIC' `
            -Message $mouseControllerMsg -Fix $mouseControllerFix -FixNote $mouseControllerFixNote
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

# ---------------------------------------------------------------------------
# Deep Tier: Anti-Cheat Driver Detection
# ---------------------------------------------------------------------------
function Invoke-AntiCheatChecks {
    $results = @()

    $acDrivers = @(
        @{ Name = 'EasyAntiCheat';  ServiceName = 'EasyAntiCheat' },
        @{ Name = 'EAC EOS';        ServiceName = 'EasyAntiCheat_EOSSys' },
        @{ Name = 'BattlEye';       ServiceName = 'BEService' },
        @{ Name = 'Vanguard';       ServiceName = 'vgk' },
        @{ Name = 'Vanguard (vgc)'; ServiceName = 'vgc' }
    )

    $detected = @()
    foreach ($ac in $acDrivers) {
        $svc = Get-Service -Name $ac.ServiceName -ErrorAction SilentlyContinue
        if ($null -ne $svc) {
            $detected += ($ac.Name + ' (' + $svc.Status + ')')
        }
    }

    # Check fltmc for minifilter instances
    $fltOutput = ''
    try { $fltOutput = (fltmc instances 2>&1) -join ' ' } catch {}
    if ($fltOutput -match 'EasyAntiCheat' -and $detected.Count -eq 0) {
        $detected += 'EasyAntiCheat (minifilter active)'
    }

    if ($detected.Count -eq 0) {
        $results += New-CheckResult -Name 'Anti-Cheat Drivers' -Category 'OS' -Tier 'Deep' -Severity 'INFO' `
            -Status 'PASS' -Current 'No anti-cheat kernel drivers detected' -Expected 'None or known drivers'
    } else {
        $detectedStr = $detected -join ', '
        $results += New-CheckResult -Name 'Anti-Cheat Drivers' -Category 'OS' -Tier 'Deep' -Severity 'INFO' `
            -Status 'WARN' -Current $detectedStr -Expected 'Awareness only' `
            -Message 'Anti-cheat drivers operate at kernel level. EAC uses PASSIVE_LEVEL callbacks (not visible in DPC/ISR but adds CPU overhead). Vanguard loads at boot.' `
            -Fix '' -FixNote 'Not fixable — informational. Use WPR InputLatency profile to measure actual CPU impact during gameplay.'
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

# ---------------------------------------------------------------------------
# Deep Tier: Latency Mitigation Checks (from EXP15 research)
# ---------------------------------------------------------------------------
function Invoke-LatencyMitigationChecks {
    $results = @()

    # --- Check: NVIDIA Power Management ---
    $nvClasses = @(
        'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0001'
    )
    $nvPerfFound = $false
    foreach ($nvKey in $nvClasses) {
        if (-not (Test-Path $nvKey)) { continue }
        $desc = (Get-ItemProperty $nvKey -ErrorAction SilentlyContinue).DriverDesc
        if ($null -eq $desc -or $desc -notmatch 'NVIDIA') { continue }
        $perfSrc = (Get-ItemProperty $nvKey -ErrorAction SilentlyContinue).PerfLevelSrc
        $nvPerfFound = $true
        if ($perfSrc -eq 0x2222) {
            $results += New-CheckResult -Name 'NVIDIA Power Max Perf' -Category 'GPU' -Tier 'Deep' -Severity 'HIGH' `
                -Status 'PASS' -Current 'PerfLevelSrc = 0x2222' -Expected '0x2222 (Max Performance)'
        } else {
            $currentVal = 'Not set'
            if ($null -ne $perfSrc) { $currentVal = '0x' + $perfSrc.ToString('X') }
            $results += New-CheckResult -Name 'NVIDIA Power Max Perf' -Category 'GPU' -Tier 'Deep' -Severity 'HIGH' `
                -Status 'WARN' -Current $currentVal -Expected '0x2222 (Max Performance)' `
                -Message 'RTX 5070 Ti shows 20% bus interface load at idle without max performance. Causes desktop micro-stutter.' `
                -Fix ('Set-ItemProperty -Path "' + $nvKey + '" -Name PerfLevelSrc -Value 0x2222 -Type DWord') `
                -FixNote 'Or run exp15_latency_mitigations_apply.ps1. Higher idle power (~10-15W).'
        }
        break
    }
    if (-not $nvPerfFound) {
        $results += New-CheckResult -Name 'NVIDIA Power Max Perf' -Category 'GPU' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'SKIP' -Current 'No NVIDIA adapter found' -Expected 'NVIDIA GPU'
    }

    # --- Check: LwtNetLog Autologger ---
    $lwtKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\LwtNetLog'
    $lwtStart = $null
    if (Test-Path $lwtKey) { $lwtStart = (Get-ItemProperty $lwtKey -ErrorAction SilentlyContinue).Start }
    if ($null -eq $lwtStart -or $lwtStart -eq 0) {
        $results += New-CheckResult -Name 'LwtNetLog Disabled' -Category 'OS' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'Disabled (Start=0)' -Expected 'Disabled'
    } else {
        $results += New-CheckResult -Name 'LwtNetLog Disabled' -Category 'OS' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ('Enabled (Start=' + $lwtStart + ')') -Expected 'Disabled (Start=0)' `
            -Message 'LwtNetLog ETW autologger adds DPC latency (5-15% CPU reduction reported when disabled).' `
            -Fix ('Set-ItemProperty -Path "' + $lwtKey + '" -Name Start -Value 0 -Type DWord') `
            -FixNote 'Reboot required. Or run exp15_latency_mitigations_apply.ps1.'
    }

    # --- Check: DiagTrack Autologger ---
    $diagKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\Diagtrack-Listener'
    $diagStart = $null
    if (Test-Path $diagKey) { $diagStart = (Get-ItemProperty $diagKey -ErrorAction SilentlyContinue).Start }
    if ($null -eq $diagStart -or $diagStart -eq 0) {
        $results += New-CheckResult -Name 'DiagTrack Disabled' -Category 'OS' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'Disabled (Start=0)' -Expected 'Disabled'
    } else {
        $results += New-CheckResult -Name 'DiagTrack Disabled' -Category 'OS' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ('Enabled (Start=' + $diagStart + ')') -Expected 'Disabled (Start=0)' `
            -Message 'DiagTrack telemetry autologger consumes background CPU and respawns constantly.' `
            -Fix ('Set-ItemProperty -Path "' + $diagKey + '" -Name Start -Value 0 -Type DWord') `
            -FixNote 'Reboot required. Or run exp15_latency_mitigations_apply.ps1.'
    }

    # --- Check: Defender Shader Cache Exclusion ---
    $dxCache  = $env:LOCALAPPDATA + '\NVIDIA\DXCache'
    $d3dCache = $env:LOCALAPPDATA + '\D3DSCache'
    $existingPaths = @()
    try { $existingPaths = @((Get-MpPreference -ErrorAction Stop).ExclusionPath) } catch {}
    $hasDx  = $existingPaths -contains $dxCache
    $hasD3d = $existingPaths -contains $d3dCache
    if ($hasDx -and $hasD3d) {
        $results += New-CheckResult -Name 'Defender Shader Exclusion' -Category 'OS' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'DXCache + D3DSCache excluded' -Expected 'Both excluded'
    } else {
        $missing = @()
        if (-not $hasDx)  { $missing += 'NVIDIA DXCache' }
        if (-not $hasD3d) { $missing += 'D3DSCache' }
        $missingStr = $missing -join ', '
        $results += New-CheckResult -Name 'Defender Shader Exclusion' -Category 'OS' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ('Missing: ' + $missingStr) -Expected 'DXCache + D3DSCache excluded' `
            -Message 'Defender scans shader cache files during gameplay, causing micro-stutter on shader compilation.' `
            -Fix ('Add-MpPreference -ExclusionPath "' + $dxCache + '"; Add-MpPreference -ExclusionPath "' + $d3dCache + '"') `
            -FixNote 'Or run exp15_latency_mitigations_apply.ps1.'
    }

    # --- Check: Defender Gaming Exclusion ---
    # Verify Fortnite / Epic Games paths and processes are excluded from Defender.
    # EXP18 showed 186K Defender I/O ops during 2min Fortnite gameplay.
    $epicPath = 'C:\Program Files\Epic Games'
    $fnProcess = 'FortniteClient-Win64-Shipping.exe'
    $existingProcesses = @()
    try { $existingProcesses = @((Get-MpPreference -ErrorAction Stop).ExclusionProcess) } catch {}
    $hasEpicPath = $existingPaths -contains $epicPath
    $hasFnProc  = $existingProcesses -contains $fnProcess
    if ($hasEpicPath -and $hasFnProc) {
        $results += New-CheckResult -Name 'Defender Gaming Exclusion' -Category 'OS' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'PASS' -Current 'Epic Games path + Fortnite process excluded' -Expected 'Game dirs + processes excluded'
    } else {
        $gameMissing = @()
        if (-not $hasEpicPath) { $gameMissing += 'Epic Games path' }
        if (-not $hasFnProc)   { $gameMissing += 'Fortnite process' }
        $gameMissingStr = $gameMissing -join ', '
        $results += New-CheckResult -Name 'Defender Gaming Exclusion' -Category 'OS' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'WARN' -Current ('Missing: ' + $gameMissingStr) -Expected 'Game dirs + processes excluded' `
            -Message 'Defender scans game files on every asset load, causing input lag during build-switching.' `
            -Fix '' `
            -FixNote 'Run exp19_defender_gaming_exclusions.ps1 to add all gaming exclusions.'
    }

    # --- Check: Bufferbloat (read from pipeline data) ---
    $expRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'captures\experiments'
    $bloatChecked = $false
    if (Test-Path $expRoot) {
        $expDirs = @(Get-ChildItem $expRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
        if ($expDirs.Count -gt 0) {
            $expJson = Join-Path $expDirs[0].FullName 'experiment.json'
            if (Test-Path $expJson) {
                try {
                    $bloatExp = Get-Content $expJson -Raw | ConvertFrom-Json -ErrorAction Stop
                    if ($null -ne $bloatExp.bufferbloat -and $null -ne $bloatExp.bufferbloat.bloatFactor) {
                        $bf = $bloatExp.bufferbloat.bloatFactor
                        $br = $bloatExp.bufferbloat.bloatRating
                        $bloatChecked = $true
                        $bloatDetail = 'Bloat: ' + $bf + 'x (' + $br + ') idle=' + $bloatExp.bufferbloat.idleP50 + 'ms loaded=' + $bloatExp.bufferbloat.loadedP50 + 'ms'
                        if ($bf -lt 2) {
                            $results += New-CheckResult -Name 'Bufferbloat' -Category 'Network' -Tier 'Deep' -Severity 'HIGH' `
                                -Status 'PASS' -Current $bloatDetail -Expected 'Bloat factor < 2x'
                        } elseif ($bf -lt 10) {
                            $results += New-CheckResult -Name 'Bufferbloat' -Category 'Network' -Tier 'Deep' -Severity 'HIGH' `
                                -Status 'WARN' -Current $bloatDetail -Expected 'Bloat factor < 2x' `
                                -Message 'Mild bufferbloat. RTT inflates under load, causing latency spikes during downloads + gaming.' `
                                -Fix '' -FixNote 'Enable SQM/fq_codel on your router. See bufferbloat.net/projects/'
                        } else {
                            $results += New-CheckResult -Name 'Bufferbloat' -Category 'Network' -Tier 'Deep' -Severity 'HIGH' `
                                -Status 'FAIL' -Current $bloatDetail -Expected 'Bloat factor < 2x' `
                                -Message 'Severe bufferbloat detected. Connection adds significant latency under load.' `
                                -Fix '' -FixNote 'Enable SQM/fq_codel on your router or replace router. See bufferbloat.net/projects/'
                        }
                    }
                } catch {}
            }
        }
    }
    if (-not $bloatChecked) {
        $results += New-CheckResult -Name 'Bufferbloat' -Category 'Network' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'SKIP' -Current 'No bufferbloat data' -Expected 'Run pipeline.ps1 first' `
            -Message 'Run pipeline.ps1 to capture bufferbloat data (idle vs loaded RTT test).'
    }

    # --- Check: Platform Clock (HPET) ---
    # If useplatformclock is forced to Yes, Windows uses legacy HPET instead of TSC,
    # adding ~1ms timer resolution overhead.
    $platformClockChecked = $false
    try {
        $bcdOutput = & bcdedit /enum '{current}' 2>&1
        if ($LASTEXITCODE -eq 0) {
            $platformClockChecked = $true
            $upcLine = $bcdOutput | Where-Object { $_ -match 'useplatformclock' }
            if ($null -ne $upcLine) {
                $upcValue = ($upcLine -replace '.*\s+(Yes|No)\s*$', '$1').Trim()
                if ($upcValue -eq 'Yes') {
                    $results += New-CheckResult -Name 'Platform Clock (HPET)' -Category 'OS' -Tier 'Deep' -Severity 'MEDIUM' `
                        -Status 'FAIL' -Current 'useplatformclock = Yes' -Expected 'Not set (TSC default)' `
                        -Message 'Legacy HPET forced on. Adds ~1ms timer latency vs TSC. Games see higher input lag.' `
                        -Fix 'bcdedit /deletevalue useplatformclock' `
                        -FixNote 'Reboot required. Lets Windows use TSC instead of legacy HPET.'
                } else {
                    $results += New-CheckResult -Name 'Platform Clock (HPET)' -Category 'OS' -Tier 'Deep' -Severity 'MEDIUM' `
                        -Status 'PASS' -Current 'useplatformclock = No' -Expected 'Not set (TSC default)' `
                        -Message 'Platform clock explicitly disabled. TSC is active.'
                }
            } else {
                $results += New-CheckResult -Name 'Platform Clock (HPET)' -Category 'OS' -Tier 'Deep' -Severity 'MEDIUM' `
                    -Status 'PASS' -Current 'Not set (TSC default)' -Expected 'Not set (TSC default)' `
                    -Message 'Windows using default TSC timer. Optimal for low latency.'
            }
        }
    } catch {}
    if (-not $platformClockChecked) {
        $results += New-CheckResult -Name 'Platform Clock (HPET)' -Category 'OS' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'ERROR' -Current 'bcdedit failed (run as admin)' -Expected 'Not set (TSC default)' `
            -Message 'Cannot read boot configuration. Run audit as Administrator.'
    }

    # --- Check: GPU ReBAR (Resizable BAR) ---
    # ReBAR lets the CPU access full GPU VRAM directly instead of a 256MB window.
    # ~3-5% FPS uplift in most games when enabled.
    $rebarChecked = $false
    $nvSmiPath = Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe'
    if (-not (Test-Path $nvSmiPath)) {
        # Try PATH fallback
        $nvSmiCmd = Get-Command 'nvidia-smi' -ErrorAction SilentlyContinue
        if ($null -ne $nvSmiCmd) { $nvSmiPath = $nvSmiCmd.Source }
    }
    if (Test-Path $nvSmiPath) {
        try {
            # bar1.total not available via --query-gpu, parse -q output instead
            $smiOutput = & $nvSmiPath -q 2>&1
            $vramRaw = & $nvSmiPath --query-gpu=memory.total --format=csv,noheader,nounits 2>&1
            $bar1Line = $smiOutput | Select-String 'BAR1 Memory Usage' -Context 0,1
            $bar1MB = 0
            if ($null -ne $bar1Line) {
                $totalLine = $bar1Line.Context.PostContext[0]
                if ($totalLine -match '(\d+)\s*MiB') { $bar1MB = [int]$Matches[1] }
            }
            $vramMB = [int]($vramRaw.ToString().Trim())
            if ($bar1MB -gt 0 -and $vramMB -gt 0) {
                $rebarChecked = $true
                if ($bar1MB -ge $vramMB) {
                    $barDetail = 'BAR1 = ' + $bar1MB + ' MB (VRAM = ' + $vramMB + ' MB)'
                    $results += New-CheckResult -Name 'GPU ReBAR (Resizable BAR)' -Category 'GPU' -Tier 'Deep' -Severity 'MEDIUM' `
                        -Status 'PASS' -Current $barDetail -Expected 'BAR1 >= VRAM (full access)' `
                        -Message 'ReBAR enabled. CPU can access full GPU VRAM directly.'
                } else {
                    $barDetail = 'BAR1 = ' + $bar1MB + ' MB (VRAM = ' + $vramMB + ' MB)'
                    $results += New-CheckResult -Name 'GPU ReBAR (Resizable BAR)' -Category 'GPU' -Tier 'Deep' -Severity 'MEDIUM' `
                        -Status 'WARN' -Current $barDetail -Expected 'BAR1 >= VRAM (full access)' `
                        -Message 'ReBAR not enabled. CPU limited to 256MB VRAM window. ~3-5% FPS loss in most games.' `
                        -Fix '' `
                        -FixNote 'Enable in BIOS: AMD CBS > NBIO > BAR Support > Enable. Also requires IOMMU enabled.'
                }
            }
        } catch {}
    }
    if (-not $rebarChecked) {
        $results += New-CheckResult -Name 'GPU ReBAR (Resizable BAR)' -Category 'GPU' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'SKIP' -Current 'nvidia-smi not found' -Expected 'BAR1 >= VRAM (full access)' `
            -Message 'Install NVIDIA drivers with nvidia-smi to check ReBAR status.'
    }

    return $results
}

# ---------------------------------------------------------------------------
# Deep Tier: DWM Health / UE Launcher Compatibility
# ---------------------------------------------------------------------------
# Rationale: EXP11/EXP13 mitigations + legacy Aero-disable keys + TDR disable
# can break UE-based launchers (Epic Games Launcher hard-asserts on
# DwmExtendFrameIntoClientArea at WindowsWindow.cpp:363).
# See: memory/project_dwm_mpo_ue_crash.md, exp11_stutter_fixes_apply.ps1:16
# ---------------------------------------------------------------------------
function Invoke-DWMHealthChecks {
    $results = @()

    # --- Check A: DWM Composition Enabled (live state via P/Invoke) ---
    $comp = $false
    $compChecked = $false
    try {
        if (-not ('DwmCheck.Api' -as [type])) {
            Add-Type -Namespace DwmCheck -Name Api -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmIsCompositionEnabled(out bool pfEnabled);
'@ -ErrorAction Stop
        }
        [DwmCheck.Api]::DwmIsCompositionEnabled([ref]$comp) | Out-Null
        $compChecked = $true
    } catch {}
    if (-not $compChecked) {
        $results += New-CheckResult -Name 'DWM Composition Enabled' -Category 'DWM' -Tier 'Deep' -Severity 'CRITICAL' `
            -Status 'ERROR' -Current 'P/Invoke failed' -Expected 'Enabled' `
            -Message 'Could not query DwmIsCompositionEnabled.'
    } elseif ($comp) {
        $results += New-CheckResult -Name 'DWM Composition Enabled' -Category 'DWM' -Tier 'Deep' -Severity 'CRITICAL' `
            -Status 'PASS' -Current 'Enabled' -Expected 'Enabled' `
            -Message 'DWM composition active. UE-based launchers initialize cleanly.'
    } else {
        $results += New-CheckResult -Name 'DWM Composition Enabled' -Category 'DWM' -Tier 'Deep' -Severity 'CRITICAL' `
            -Status 'FAIL' -Current 'Disabled' -Expected 'Enabled' `
            -Message 'DWM composition is off. Every UE-based launcher will assert on DwmExtendFrameIntoClientArea (WindowsWindow.cpp:363).' `
            -Fix 'Start-Service Themes; Stop-Process -Name dwm -Force' `
            -FixNote 'DWM auto-restarts after kill. No reboot required.'
    }

    # --- Check B: Themes Service Running + Automatic ---
    $themes = $null
    try { $themes = Get-Service Themes -ErrorAction Stop } catch {}
    if ($null -eq $themes) {
        $results += New-CheckResult -Name 'Themes Service' -Category 'DWM' -Tier 'Deep' -Severity 'CRITICAL' `
            -Status 'ERROR' -Current 'Service not found' -Expected 'Running/Automatic' `
            -Message 'Themes service missing. DWM composition will not start.'
    } elseif ($themes.Status -eq 'Running' -and $themes.StartType -eq 'Automatic') {
        $results += New-CheckResult -Name 'Themes Service' -Category 'DWM' -Tier 'Deep' -Severity 'CRITICAL' `
            -Status 'PASS' -Current 'Running/Automatic' -Expected 'Running/Automatic'
    } elseif ($themes.Status -ne 'Running') {
        $currentState = [string]$themes.Status + '/' + [string]$themes.StartType
        $results += New-CheckResult -Name 'Themes Service' -Category 'DWM' -Tier 'Deep' -Severity 'CRITICAL' `
            -Status 'FAIL' -Current $currentState -Expected 'Running/Automatic' `
            -Message 'Themes service stopped. DWM composition fails. UE apps assert on window init.' `
            -Fix 'Set-Service Themes -StartupType Automatic; Start-Service Themes'
    } else {
        $currentState = 'Running/' + [string]$themes.StartType
        $results += New-CheckResult -Name 'Themes Service' -Category 'DWM' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'WARN' -Current $currentState -Expected 'Running/Automatic' `
            -Message 'Themes running but not set to Automatic. Will fail to start after next reboot.' `
            -Fix 'Set-Service Themes -StartupType Automatic'
    }

    # --- Check C: TdrLevel Sanity ---
    $gdKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    $tdr = $null
    try { $tdr = (Get-ItemProperty $gdKey -ErrorAction Stop).TdrLevel } catch {}
    $tdrDisplay = 'Not set (default=3)'
    if ($null -ne $tdr) { $tdrDisplay = [string]$tdr }
    if ($null -eq $tdr -or $tdr -ge 2) {
        $results += New-CheckResult -Name 'TdrLevel Sanity' -Category 'DWM' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'PASS' -Current $tdrDisplay -Expected '>= 2 or absent' `
            -Message 'GPU TDR recovery enabled. DWM can recover from transient GPU hangs.'
    } elseif ($tdr -eq 0) {
        $results += New-CheckResult -Name 'TdrLevel Sanity' -Category 'DWM' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'FAIL' -Current '0 (detection off)' -Expected '>= 2 or absent' `
            -Message 'TdrLevel=0 disables GPU TDR recovery. Any GPU hang permanently wedges DWM.' `
            -Fix 'Remove-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name TdrLevel -ErrorAction SilentlyContinue' `
            -FixNote 'Reboot required'
    } else {
        $results += New-CheckResult -Name 'TdrLevel Sanity' -Category 'DWM' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current $tdrDisplay -Expected '>= 2 or absent' `
            -Message 'TdrLevel=1 detects hangs but does not recover. DWM may stay wedged after GPU hang.'
    }

    # --- Check D: Legacy Aero-Disable Registry (HKCU) ---
    # FAIL only if value=0 (actual Aero-disable). WARN on presence with non-zero value
    # (suspicious — usually set by debloat scripts — but not actively breaking).
    $dwmUser = 'HKCU:\Software\Microsoft\Windows\DWM'
    $legacyDisabled = @()
    $legacyPresent = @()
    try {
        $props = Get-ItemProperty $dwmUser -ErrorAction Stop
        foreach ($k in 'CompositionPolicy','Composition','ForceEffectMode') {
            $v = $props.$k
            if ($null -ne $v) {
                $legacyPresent += ($k + '=' + [string]$v)
                if ($v -eq 0) { $legacyDisabled += ($k + '=0') }
            }
        }
    } catch {}
    if ($legacyDisabled.Count -gt 0) {
        $results += New-CheckResult -Name 'Legacy Aero-Disable' -Category 'DWM' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'FAIL' -Current ($legacyDisabled -join '; ') -Expected 'None or enabled (=1)' `
            -Message 'Win7-era Aero-disable keys present under HKCU\...\DWM with value=0. UE honors these — WindowsWindow.cpp:363 will hard-assert on launch.' `
            -Fix 'Remove-ItemProperty "HKCU:\Software\Microsoft\Windows\DWM" -Name CompositionPolicy,Composition,ForceEffectMode -ErrorAction SilentlyContinue' `
            -FixNote 'Sign out / sign in required for HKCU policy to take effect.'
    } elseif ($legacyPresent.Count -gt 0) {
        $results += New-CheckResult -Name 'Legacy Aero-Disable' -Category 'DWM' -Tier 'Deep' -Severity 'LOW' `
            -Status 'WARN' -Current ($legacyPresent -join '; ') -Expected 'None present' `
            -Message 'Legacy HKCU DWM policy keys present but enabled (=1). Not actively breaking but suggests debloat-script residue. Safe to remove.' `
            -Fix 'Remove-ItemProperty "HKCU:\Software\Microsoft\Windows\DWM" -Name CompositionPolicy,Composition,ForceEffectMode -ErrorAction SilentlyContinue'
    } else {
        $results += New-CheckResult -Name 'Legacy Aero-Disable' -Category 'DWM' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'PASS' -Current 'None present' -Expected 'None present' `
            -Message 'No Win7-era Aero-disable keys found.'
    }

    # --- Check E: Legacy OverlayTestMode (UE-Compat Warning on 24H2/25H2) ---
    $dwmSys = 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm'
    $otm = $null
    try { $otm = (Get-ItemProperty $dwmSys -ErrorAction Stop).OverlayTestMode } catch {}
    if ($null -eq $otm) {
        $results += New-CheckResult -Name 'OverlayTestMode (Legacy)' -Category 'DWM' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'Absent' -Expected 'Absent on 24H2/25H2' `
            -Message 'No legacy OverlayTestMode value present. Modern DisableOverlays controls MPO.'
    } elseif ($otm -eq 5) {
        $results += New-CheckResult -Name 'OverlayTestMode (Legacy)' -Category 'DWM' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current 'OverlayTestMode=5' -Expected 'Absent on 24H2/25H2' `
            -Message 'Legacy MPO-disable key set. Does not control MPO on 24H2/25H2 (use DisableOverlays instead). Residual value may trigger UE launcher asserts on fullscreen-exclusive game launch.' `
            -Source 'exp11_stutter_fixes_apply.ps1:16' `
            -Fix 'Remove-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\Dwm" -Name OverlayTestMode -ErrorAction SilentlyContinue' `
            -FixNote 'Reboot required. Safe — MPO still controlled via GraphicsDrivers\DisableOverlays (EXP11 modern path).'
    } else {
        $results += New-CheckResult -Name 'OverlayTestMode (Legacy)' -Category 'DWM' -Tier 'Deep' -Severity 'LOW' `
            -Status 'WARN' -Current ('OverlayTestMode=' + [string]$otm) -Expected 'Absent on 24H2/25H2' `
            -Message 'Legacy key present with non-standard value.'
    }

    # --- Check F: UE Launcher Compatibility Cross-Check ---
    $compatRisks = @()
    if ($compChecked -and -not $comp) { $compatRisks += 'composition off' }
    if ($null -ne $themes -and $themes.Status -ne 'Running') { $compatRisks += 'Themes stopped' }
    if ($legacyDisabled.Count -gt 0) { $compatRisks += 'legacy Aero disable' }
    if ($null -ne $otm -and $otm -eq 5) { $compatRisks += 'OverlayTestMode=5' }

    if ($compatRisks.Count -eq 0) {
        $results += New-CheckResult -Name 'UE Launcher Compatibility' -Category 'DWM' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'PASS' -Current 'OK' -Expected 'OK' `
            -Message 'Epic Games Launcher / UE-based apps should initialize cleanly.'
    } else {
        $compatCurrent = $compatRisks -join '; '
        $results += New-CheckResult -Name 'UE Launcher Compatibility' -Category 'DWM' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'FAIL' -Current $compatCurrent -Expected 'OK' `
            -Message 'Epic Games Launcher will likely hard-assert at DwmExtendFrameIntoClientArea (WindowsWindow.cpp:363) on fullscreen-exclusive game launch (GRB, older AnvilNext, pre-UE5 titles). Workaround: Epic Settings -> "Exit after launch" = ON, or set games to Borderless Windowed.' `
            -Source 'memory/project_dwm_mpo_ue_crash.md' `
            -FixNote 'Address each listed risk via checks A-E above.'
    }

    return $results
}

# ---------------------------------------------------------------------------
# Driver Health Checks (chipset, NVMe, event log, scheduled tasks)
# ---------------------------------------------------------------------------
function Invoke-DriverHealthChecks {
    $results = @()

    # --- Check A: AMD Chipset Package ---
    $amdPpmPath = Join-Path $env:SystemRoot 'System32\drivers\amdppm.sys'
    $amdPpmExists = Test-Path $amdPpmPath

    $errorDevCount = 0
    try {
        $errorDevs = @(Get-WmiObject Win32_PnPEntity -ErrorAction SilentlyContinue |
            Where-Object { $_.ConfigManagerErrorCode -eq 28 })
        $errorDevCount = $errorDevs.Count
    } catch { }

    if ($amdPpmExists -and $errorDevCount -eq 0) {
        $results += New-CheckResult -Name 'AMD Chipset Package' -Category 'Drivers' -Tier 'Quick' -Severity 'CRITICAL' `
            -Status 'PASS' -Current 'Installed (amdppm.sys present, 0 Code-28 devices)' -Expected 'Installed' `
            -Message 'AMD Chipset Software present. PPM, GPIO, I2C, SFH, CCP/PSP all functional.'
    } else {
        $currentStr = 'amdppm.sys=' + $(if ($amdPpmExists) { 'Yes' } else { 'No' }) + ', Code-28 devices=' + $errorDevCount
        $results += New-CheckResult -Name 'AMD Chipset Package' -Category 'Drivers' -Tier 'Quick' -Severity 'CRITICAL' `
            -Status 'FAIL' -Current $currentStr -Expected 'Installed, 0 Code-28 devices' `
            -Message ('AMD Chipset Software missing. ' + $errorDevCount + ' devices without drivers (GPIO, I2C, SFH, CCP/PSP). P-state management uses generic cpu.inf.') `
            -Fix '.\fix_chipset_drivers.ps1 -OpenDownload' `
            -FixNote 'Download AMD Chipset Software and install. Reboot required.'
    }

    # --- Check B: NVMe Vendor Drivers ---
    $nvmeGeneric = 0
    $nvmeTotal = 0
    try {
        $nvmeDisks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.BusType -eq 'NVMe' })
        $nvmeTotal = $nvmeDisks.Count
        $nvmePnp = @(Get-WmiObject Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
            Where-Object { $_.Description -and $_.Description -like '*NVMe*' -and $_.DriverProviderName -eq 'Microsoft' })
        $nvmeGeneric = $nvmePnp.Count
    } catch { }

    if ($nvmeTotal -eq 0) {
        $results += New-CheckResult -Name 'NVMe Vendor Drivers' -Category 'Drivers' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'No NVMe drives' -Expected 'Vendor driver'
    } elseif ($nvmeGeneric -eq 0) {
        $results += New-CheckResult -Name 'NVMe Vendor Drivers' -Category 'Drivers' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'PASS' -Current ('All ' + $nvmeTotal + ' NVMe drive(s) use vendor drivers') -Expected 'Vendor driver'
    } else {
        $results += New-CheckResult -Name 'NVMe Vendor Drivers' -Category 'Drivers' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ([string]$nvmeGeneric + '/' + [string]$nvmeTotal + ' NVMe drive(s) use generic Microsoft driver') -Expected 'Vendor driver' `
            -Message 'Generic stornvme.sys lacks vendor APST tuning and optimized queue depth. Samsung and WD provide native NVMe drivers.' `
            -Fix '.\audit-drivers.ps1 -Html' `
            -FixNote 'Check audit report for specific drive recommendations.'
    }

    # --- Check C: Event Viewer Driver Errors (7 days) ---
    $driverErrors = 0
    try {
        $startDate = (Get-Date).AddDays(-7)
        $scmErrs = @(Get-WinEvent -FilterHashtable @{
            LogName      = 'System'
            ProviderName = 'Service Control Manager'
            Level        = @(1,2)
            StartTime    = $startDate
        } -MaxEvents 200 -ErrorAction SilentlyContinue)
        $driverErrors = $scmErrs.Count
    } catch { }

    if ($driverErrors -eq 0) {
        $results += New-CheckResult -Name 'Event Log Driver Errors' -Category 'Drivers' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'PASS' -Current '0 driver errors (7d)' -Expected '0'
    } elseif ($driverErrors -le 5) {
        $results += New-CheckResult -Name 'Event Log Driver Errors' -Category 'Drivers' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ([string]$driverErrors + ' driver errors (7d)') -Expected '0' `
            -Message 'Minor driver/service errors in event log. Run audit-drivers.ps1 for details.'
    } else {
        $results += New-CheckResult -Name 'Event Log Driver Errors' -Category 'Drivers' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'FAIL' -Current ([string]$driverErrors + ' driver errors (7d)') -Expected '0' `
            -Message 'Significant driver/service errors in event log.' `
            -Fix '.\audit-drivers.ps1 -Html' `
            -FixNote 'Run driver audit for full breakdown.'
    }

    # --- Check D: Scheduled Task Hygiene ---
    $hourlyEnabled = 0
    try {
        $allTasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Disabled' }
        foreach ($task in $allTasks) {
            foreach ($trig in $task.Triggers) {
                $rep = $trig.Repetition
                if ($rep -and $rep.Interval) {
                    $interval = $rep.Interval
                    if ($interval -match '^PT(\d+)M$' -and [int]$Matches[1] -le 60) {
                        $hourlyEnabled++
                        break
                    } elseif ($interval -eq 'PT1H') {
                        $hourlyEnabled++
                        break
                    }
                }
            }
        }
    } catch { }

    if ($hourlyEnabled -eq 0) {
        $results += New-CheckResult -Name 'Scheduled Task Hygiene' -Category 'Drivers' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'No hourly tasks enabled' -Expected '0 hourly tasks' `
            -Message 'No high-frequency scheduled tasks that could interrupt gaming.'
    } else {
        $results += New-CheckResult -Name 'Scheduled Task Hygiene' -Category 'Drivers' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ([string]$hourlyEnabled + ' hourly task(s) enabled') -Expected '0 hourly tasks' `
            -Message 'Tasks with hourly or more frequent intervals can cause CPU/disk spikes during gaming.' `
            -Fix '.\fix_scheduled_tasks.ps1' `
            -FixNote 'Disable non-essential hourly tasks. Rollback: -Restore flag.'
    }

    return $results
}
