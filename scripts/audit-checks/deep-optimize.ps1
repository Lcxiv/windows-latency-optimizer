#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deep-tier optimization audit checks.
.DESCRIPTION
    Checks 11 deep-tier latency optimizations: CSRSS priority, Game DVR,
    Xbox services, Power Throttling, Fast Startup, IPv6, MMCSS NoLazyMode,
    Global Timer Resolution, Energy Telemetry, GameBar Policy, launcher procs.
    Restored from commit 6e57a68 after refactor 9eabc64 dropped them.
#>

function Get-DeepRegValue {
    param([string]$Path, [string]$Name)
    try {
        $prop = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return $prop.$Name
    } catch {
        return $null
    }
}

function Invoke-DeepOptimizeChecks {
    $results = @()

    # CSRSS IFEO priority
    $csrssPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\csrss.exe\PerfOptions'
    $csrssPrio = Get-DeepRegValue $csrssPath 'CpuPriorityClass'
    $csrssPrioStr = 'Not set'
    if ($null -ne $csrssPrio) { $csrssPrioStr = $csrssPrio.ToString() }
    $csrssStatus = 'WARN'
    if ($csrssPrio -eq 3) { $csrssStatus = 'PASS' }
    $results += New-CheckResult -Name 'CSRSS Priority Boost' -Category 'Deep' -Tier 'Deep' -Severity 'MEDIUM' `
        -Status $csrssStatus `
        -Current $csrssPrioStr -Expected '3 (High)' `
        -Message 'CSRSS handles raw mouse/keyboard input. High priority reduces input processing delay.' `
        -Fix '.\scripts\deep_optimize.ps1 -Tier 1' -FixNote 'Sets CpuPriorityClass=3 and IoPriority=3'

    # Game DVR
    $dvr = Get-DeepRegValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled'
    $dvrStr = 'Not set'
    if ($null -ne $dvr) { $dvrStr = $dvr.ToString() }
    $dvrStatus = 'WARN'
    if ($dvr -eq 0) { $dvrStatus = 'PASS' }
    $results += New-CheckResult -Name 'Game DVR Disabled' -Category 'Deep' -Tier 'Deep' -Severity 'MEDIUM' `
        -Status $dvrStatus `
        -Current $dvrStr -Expected '0 (Disabled)' `
        -Message 'Game DVR background recording hooks add DWM interception overhead.' `
        -Fix '.\scripts\deep_optimize.ps1 -Tier 1'

    # Xbox services
    $xboxRunning = 0
    foreach ($svc in @('XblAuthManager', 'XblGameSave', 'XboxGipSvc', 'XboxNetApiSvc')) {
        $start = Get-DeepRegValue ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $svc) 'Start'
        if ($null -ne $start -and $start -ne 4) { $xboxRunning++ }
    }
    $xboxStatus = 'WARN'
    if ($xboxRunning -eq 0) { $xboxStatus = 'PASS' }
    $results += New-CheckResult -Name 'Xbox Services Disabled' -Category 'Deep' -Tier 'Deep' -Severity 'LOW' `
        -Status $xboxStatus `
        -Current ([string]$xboxRunning + '/4 enabled') -Expected '0/4 enabled' `
        -Message 'Xbox services consume background resources without benefit for PC gaming.'

    # Power Throttling
    $ptOff = Get-DeepRegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff'
    $ptStr = 'Not set (enabled)'
    if ($null -ne $ptOff) { $ptStr = $ptOff.ToString() }
    $ptStatus = 'WARN'
    if ($ptOff -eq 1) { $ptStatus = 'PASS' }
    $results += New-CheckResult -Name 'Power Throttling Off' -Category 'Deep' -Tier 'Deep' -Severity 'MEDIUM' `
        -Status $ptStatus `
        -Current $ptStr -Expected '1 (Disabled)' `
        -Message 'Win11 silently throttles background processes. Disabling prevents game helper throttling.'

    # Hibernate / Fast Startup
    $hiberboot = Get-DeepRegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled'
    $hiberStr = 'Not set'
    if ($null -ne $hiberboot) { $hiberStr = $hiberboot.ToString() }
    $hiberStatus = 'WARN'
    if ($hiberboot -eq 0) { $hiberStatus = 'PASS' }
    $results += New-CheckResult -Name 'Fast Startup Disabled' -Category 'Deep' -Tier 'Deep' -Severity 'LOW' `
        -Status $hiberStatus `
        -Current $hiberStr -Expected '0 (Disabled)' `
        -Message 'Fast Startup preserves stale driver state across reboots. Full cold boot is cleaner.'

    # IPv6
    $ipv6 = Get-DeepRegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' 'DisabledComponents'
    $ipv6Str = 'Not set (enabled)'
    if ($null -ne $ipv6) { $ipv6Str = $ipv6.ToString() }
    $ipv6Status = 'INFO'
    if ($ipv6 -eq 255) { $ipv6Status = 'PASS' }
    $results += New-CheckResult -Name 'IPv6 Disabled' -Category 'Deep' -Tier 'Deep' -Severity 'LOW' `
        -Status $ipv6Status `
        -Current $ipv6Str -Expected '255 (All disabled)' `
        -Message 'IPv6 dual-stack adds processing overhead. Disable if not needed.'

    # MMCSS NoLazyMode
    $noLazy = Get-DeepRegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NoLazyMode'
    $noLazyStr = 'Not set (lazy)'
    if ($null -ne $noLazy) { $noLazyStr = $noLazy.ToString() }
    $noLazyStatus = 'INFO'
    if ($noLazy -eq 1) { $noLazyStatus = 'PASS' }
    $results += New-CheckResult -Name 'MMCSS NoLazyMode' -Category 'Deep' -Tier 'Deep' -Severity 'LOW' `
        -Status $noLazyStatus `
        -Current $noLazyStr -Expected '1 (Aggressive)' `
        -Message 'NoLazyMode prevents MMCSS from sleeping during idle detection periods.' `
        -Fix '.\scripts\deep_optimize.ps1 -Tier 2'

    # GlobalTimerResolutionRequests
    $timerRes = Get-DeepRegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests'
    $timerStr = 'Not set'
    if ($null -ne $timerRes) { $timerStr = $timerRes.ToString() }
    $timerStatus = 'INFO'
    if ($timerRes -eq 1) { $timerStatus = 'PASS' }
    $results += New-CheckResult -Name 'Global Timer Resolution' -Category 'Deep' -Tier 'Deep' -Severity 'LOW' `
        -Status $timerStatus `
        -Current $timerStr -Expected '1 (Enabled)' `
        -Message 'Allows sub-1ms timer resolution when paired with ISLC.' `
        -Fix '.\scripts\deep_optimize.ps1 -Tier 2'

    # Energy telemetry
    $energyLog = Get-DeepRegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Diagnostics\Performance' 'DisableTaggedEnergyLogging'
    $energyStr = 'Not set (logging)'
    if ($null -ne $energyLog) { $energyStr = $energyLog.ToString() }
    $energyStatus = 'WARN'
    if ($energyLog -eq 1) { $energyStatus = 'PASS' }
    $results += New-CheckResult -Name 'Energy Telemetry Off' -Category 'Deep' -Tier 'Deep' -Severity 'LOW' `
        -Status $energyStatus `
        -Current $energyStr -Expected '1 (Disabled)' `
        -Message 'Energy estimation background logging consumes CPU cycles.'

    # GameBar Policy (system-level disable prevents DCOM PresenceWriter timeouts)
    $gameDvrPolicy = Get-DeepRegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR'
    $gameDvrPolicyStr = 'Not set (allowed)'
    if ($null -ne $gameDvrPolicy) { $gameDvrPolicyStr = $gameDvrPolicy.ToString() }
    $gameDvrPolicyStatus = 'WARN'
    if ($gameDvrPolicy -eq 0) { $gameDvrPolicyStatus = 'PASS' }
    $results += New-CheckResult -Name 'GameBar Policy Disabled' -Category 'Deep' -Tier 'Deep' -Severity 'MEDIUM' `
        -Status $gameDvrPolicyStatus `
        -Current $gameDvrPolicyStr -Expected '0 (Disabled)' `
        -Message 'Without policy block, Windows activates GameBar PresenceWriter on game launch causing DCOM 10010 timeouts and input stalls.' `
        -Fix '.\scripts\deep_optimize.ps1 -Tier 1'

    # Game launcher background processes (resource hogs during gameplay)
    $launcherProcs = @(
        @{ Name='Ankama Launcher'; Exe='Ankama Launcher' },
        @{ Name='Epic Games';      Exe='EpicGamesLauncher' },
        @{ Name='EA App';          Exe='EADesktop' },
        @{ Name='Ubisoft Connect'; Exe='upc' },
        @{ Name='GOG Galaxy';      Exe='GalaxyClient' },
        @{ Name='Battle.net';      Exe='Battle.net' }
    )
    $foundLaunchers = @()
    foreach ($l in $launcherProcs) {
        if (Get-Process -Name $l.Exe -ErrorAction SilentlyContinue) {
            $foundLaunchers += $l.Name
        }
    }
    if ($foundLaunchers.Count -eq 0) {
        $results += New-CheckResult -Name 'Game Launcher Processes' -Category 'Deep' -Tier 'Deep' -Severity 'LOW' `
            -Status 'PASS' -Current 'No background launchers detected' -Expected 'None during gaming'
    } else {
        $results += New-CheckResult -Name 'Game Launcher Processes' -Category 'Deep' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ('Running: ' + ($foundLaunchers -join ', ')) -Expected 'None during gaming' `
            -Message 'Game launchers consume CPU, RAM, and disk I/O in background. Close after launching game.' `
            -Fix '' -FixNote 'Close listed launchers after game starts. Disable auto-start in each launcher settings.'
    }

    return $results
}
