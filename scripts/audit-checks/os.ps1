#Requires -RunAsAdministrator
<#
.SYNOPSIS
    OS-level audit checks (Quick Tier).
.DESCRIPTION
    MPO, Hyper-V, VBS, MMCSS, Power Plan, Win32PrioritySeparation,
    GameInput duplicates, KB5077181 stutter bug.
#>

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
                'C:\Program Files\Riot Games'
            )
            $gameExes = @(
                'FortniteClient-Win64-Shipping.exe', 'FPSAimTrainer.exe', 'cs2.exe',
                'VALORANT-Win64-Shipping.exe', 'r5apex.exe', 'OverwatchOW.exe',
                'RocketLeague.exe', 'PUBG-Win64-Shipping.exe'
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
