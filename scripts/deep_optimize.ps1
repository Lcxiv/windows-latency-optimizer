#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deep system optimization — BIOS checklist + Windows registry + power plan.
.DESCRIPTION
    Applies latency/smoothness tweaks NOT covered by existing experiment scripts.
    Three tiers of confidence:
      Tier 1: High-confidence, evidence-based, low risk (CSRSS priority, GameDVR, Xbox, NTFS, power)
      Tier 2: Medium-confidence, worth measuring (MMCSS, timer resolution, paging executive, audio)
      Tier 3: Experimental, test individually (DPC kernel, dynamictick, Spectre mitigations)

    BIOS changes (Global C-State, CPPC, TSME, PBO, LLC, etc.) are output as a
    checklist document only — never auto-applied.

    Creates full backup + rollback script before any changes.

.PARAMETER Tier
    Which tiers to apply (cumulative). Tier 2 includes Tier 1. Default: 1.
.PARAMETER Audit
    Read-only mode: show what WOULD change without modifying anything.
.PARAMETER WhatIf
    Alias for -Audit.
.PARAMETER SkipXboxServices
    Keep Xbox services running (skip item 13).
.PARAMETER SkipIPv6
    Do not touch IPv6 settings (skip item 18).
.PARAMETER GameProcess
    Game EXE name for IFEO priority boost (default: FortniteClient-Win64-Shipping).
.EXAMPLE
    .\deep_optimize.ps1 -Audit
.EXAMPLE
    .\deep_optimize.ps1 -Tier 1
.EXAMPLE
    .\deep_optimize.ps1 -Tier 2 -GameProcess cs2
.EXAMPLE
    .\deep_optimize.ps1 -Tier 3 -SkipIPv6
#>
[CmdletBinding()]
param(
    [ValidateSet(1, 2, 3)]
    [int]$Tier = 1,
    [switch]$Audit,
    [switch]$WhatIf,
    [switch]$SkipXboxServices,
    [switch]$SkipIPv6,
    [string]$GameProcess = 'FortniteClient-Win64-Shipping'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent

if ($WhatIf) { $Audit = $true }

$isAudit = [bool]$Audit
$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
$changes = @()
$warnings = @()
$skipped = @()

Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host '  Deep System Optimization  (Tier ' -ForegroundColor Cyan -NoNewline
Write-Host $Tier -ForegroundColor White -NoNewline
Write-Host ')' -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan
if ($isAudit) { Write-Host '  MODE: AUDIT ONLY (no changes)' -ForegroundColor Yellow }
Write-Host ''

# ════════════════════════════════════════════════════════════════════════════
# HELPERS
# ════════════════════════════════════════════════════════════════════════════

function Get-RegValue {
    param([string]$Path, [string]$Name)
    try {
        $prop = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return $prop.$Name
    } catch {
        return $null
    }
}

function Ensure-RegKey {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
}

function Apply-RegSetting {
    param(
        [string]$Label,
        [string]$Path,
        [string]$Name,
        $Target,
        [string]$Type = 'DWord'
    )
    $current = Get-RegValue -Path $Path -Name $Name
    $currentStr = if ($null -eq $current) { '<not set>' } else { $current.ToString() }
    $targetStr = $Target.ToString()

    if ($currentStr -eq $targetStr) {
        Write-Host ('  [OK]   ' + $Label + ' = ' + $currentStr) -ForegroundColor Green
        return
    }
    if ($isAudit) {
        Write-Host ('  [TODO] ' + $Label + ': ' + $currentStr + ' -> ' + $targetStr) -ForegroundColor Yellow
    } else {
        try {
            Ensure-RegKey $Path
            Set-ItemProperty -Path $Path -Name $Name -Value $Target -Type $Type -Force
            $verify = Get-RegValue -Path $Path -Name $Name
            if ($null -ne $verify -and $verify.ToString() -eq $targetStr) {
                Write-Host ('  [SET]  ' + $Label + ': ' + $currentStr + ' -> ' + $targetStr) -ForegroundColor Cyan
                $script:changes += ($Label + ': ' + $currentStr + ' -> ' + $targetStr)
            } else {
                Write-Host ('  [FAIL] ' + $Label + ': verify returned ' + $verify) -ForegroundColor Red
                $script:warnings += ($Label + ': write did not stick')
            }
        } catch {
            Write-Host ('  [FAIL] ' + $Label + ': ' + $_.Exception.Message) -ForegroundColor Red
            $script:warnings += ($Label + ': ' + $_.Exception.Message)
        }
    }
}

function Apply-RegString {
    param(
        [string]$Label,
        [string]$Path,
        [string]$Name,
        [string]$Target
    )
    Apply-RegSetting -Label $Label -Path $Path -Name $Name -Target $Target -Type 'String'
}

function Apply-ServiceDisable {
    param([string]$ServiceName)
    $svcPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $ServiceName
    $current = Get-RegValue -Path $svcPath -Name 'Start'
    $currentStr = if ($null -eq $current) { '<not found>' } else { $current.ToString() }

    if ($currentStr -eq '4') {
        Write-Host ('  [OK]   ' + $ServiceName + ' = Disabled (4)') -ForegroundColor Green
        return
    }
    if ($isAudit) {
        Write-Host ('  [TODO] ' + $ServiceName + ': Start=' + $currentStr + ' -> 4 (Disabled)') -ForegroundColor Yellow
    } else {
        try {
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $svcPath -Name 'Start' -Value 4 -Type DWord -Force
            $verify = Get-RegValue -Path $svcPath -Name 'Start'
            if ($verify -eq 4) {
                Write-Host ('  [SET]  ' + $ServiceName + ': Start=' + $currentStr + ' -> 4') -ForegroundColor Cyan
                $script:changes += ($ServiceName + ': Start ' + $currentStr + ' -> 4')
            } else {
                Write-Host ('  [FAIL] ' + $ServiceName + ': verify returned ' + $verify) -ForegroundColor Red
                $script:warnings += ($ServiceName + ': disable did not stick')
            }
        } catch {
            Write-Host ('  [FAIL] ' + $ServiceName + ': ' + $_.Exception.Message) -ForegroundColor Red
            $script:warnings += ($ServiceName + ': ' + $_.Exception.Message)
        }
    }
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE 0: BACKUP
# ════════════════════════════════════════════════════════════════════════════

$outDir = Join-Path $projectRoot ('captures\deep_optimize_' + $ts)
if (-not $isAudit) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

$backupLines = @(
    '# Deep Optimize Backup',
    ('# Captured: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
    ('# Tier: ' + $Tier),
    ''
)

$rollbackReg = @()
$rollbackManual = @()

function Capture-PreState {
    param([string]$Label, [string]$Path, [string]$Name)
    $val = Get-RegValue -Path $Path -Name $Name
    $valStr = if ($null -eq $val) { '<null>' } else { $val.ToString() }
    $script:backupLines += ('# ' + $Label + ' = ' + $valStr)
    if ($null -ne $val) {
        if ($val -is [string]) {
            $escaped = $val -replace '"', '`"'
            $script:rollbackReg += ('Set-ItemProperty -Path "' + $Path + '" -Name "' + $Name + '" -Value "' + $escaped + '" -Type String -Force')
        } else {
            $script:rollbackReg += ('Set-ItemProperty -Path "' + $Path + '" -Name "' + $Name + '" -Value ' + $val + ' -Type DWord -Force')
        }
    } else {
        $script:rollbackReg += ('Remove-ItemProperty -Path "' + $Path + '" -Name "' + $Name + '" -ErrorAction SilentlyContinue')
    }
}

Write-Host '--- Phase 0: Capturing pre-state ---' -ForegroundColor Yellow

# Tier 1 pre-state
Capture-PreState 'CSRSS CpuPriorityClass' 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\csrss.exe\PerfOptions' 'CpuPriorityClass'
Capture-PreState 'CSRSS IoPriority' 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\csrss.exe\PerfOptions' 'IoPriority'
Capture-PreState 'GameDVR_Enabled' 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled'
Capture-PreState 'GameDVR_DXGIHonorFSEWindowsCompatible' 'HKCU:\System\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible'
Capture-PreState 'GameDVR_EFSEFeatureFlags' 'HKCU:\System\GameConfigStore' 'GameDVR_EFSEFeatureFlags'
Capture-PreState 'GameDVR_FSEBehavior' 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehavior'
Capture-PreState 'AllowGameDVR' 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR'
Capture-PreState 'AppCaptureEnabled' 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled'
foreach ($svc in @('XblAuthManager', 'XblGameSave', 'XboxGipSvc', 'XboxNetApiSvc')) {
    Capture-PreState ($svc + ' Start') ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $svc) 'Start'
}
Capture-PreState 'PowerThrottlingOff' 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff'
Capture-PreState 'HiberbootEnabled' 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled'
Capture-PreState 'HibernateEnabled' 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'
Capture-PreState 'Ipv6 DisabledComponents' 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' 'DisabledComponents'
Capture-PreState 'DisableTaggedEnergyLogging' 'HKLM:\SYSTEM\CurrentControlSet\Control\Diagnostics\Performance' 'DisableTaggedEnergyLogging'
Capture-PreState 'TimeStampInterval' 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Reliability' 'TimeStampInterval'

# Tier 2 pre-state
if ($Tier -ge 2) {
    Capture-PreState 'MMCSS NoLazyMode' 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NoLazyMode'
    Capture-PreState 'Games Latency Sensitive' 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Latency Sensitive'
    Capture-PreState 'GlobalTimerResolutionRequests' 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests'
    Capture-PreState 'DisablePagingExecutive' 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'DisablePagingExecutive'
    $ifeoPerfPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\' + $GameProcess + '.exe\PerfOptions'
    Capture-PreState ($GameProcess + ' CpuPriorityClass') $ifeoPerfPath 'CpuPriorityClass'
    Capture-PreState 'DisplayPostProcessing GPU Priority' 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\DisplayPostProcessing' 'GPU Priority'
    Capture-PreState 'DisplayPostProcessing Priority' 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\DisplayPostProcessing' 'Priority'
    Capture-PreState 'DisplayPostProcessing SchedulingCategory' 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\DisplayPostProcessing' 'Scheduling Category'
}

# Tier 3 pre-state
if ($Tier -ge 3) {
    Capture-PreState 'IdealDpcRate' 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'IdealDpcRate'
    Capture-PreState 'MaximumDpcQueueDepth' 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'MaximumDpcQueueDepth'
    Capture-PreState 'DpcWatchdogPeriod' 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'DpcWatchdogPeriod'
    Capture-PreState 'FeatureSettingsOverride' 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'FeatureSettingsOverride'
    Capture-PreState 'FeatureSettingsOverrideMask' 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'FeatureSettingsOverrideMask'
}

# Capture NTFS + power plan state
$ntfsLastAccess = 'unknown'
try { $ntfsLastAccess = (fsutil behavior query disablelastaccess 2>&1 | Out-String).Trim() } catch {}
$ntfs8dot3 = 'unknown'
try { $ntfs8dot3 = (fsutil 8dot3name query 2>&1 | Out-String).Trim() } catch {}
$powerPlan = 'unknown'
try {
    $ppOut = powercfg /getactivescheme 2>&1 | Out-String
    if ($ppOut -match 'GUID:\s+(\S+)\s+\((.+)\)') { $powerPlan = $Matches[2].Trim() }
} catch {}
$backupLines += ''
$backupLines += ('# NTFS LastAccess: ' + $ntfsLastAccess)
$backupLines += ('# NTFS 8.3: ' + $ntfs8dot3)
$backupLines += ('# Power Plan: ' + $powerPlan)

Write-Host ('  Pre-state captured (' + $rollbackReg.Count + ' registry values)') -ForegroundColor Green
Write-Host ''

# Write backup file
if (-not $isAudit) {
    $backupFile = Join-Path $outDir 'backup.txt'
    $backupLines += ''
    $backupLines += '=== Rollback Commands ==='
    $backupLines += $rollbackReg
    $backupLines | Out-File -FilePath $backupFile -Encoding UTF8
    Write-Host ('[BACKUP] ' + $backupFile) -ForegroundColor Green
    Write-Host ''
}

# ════════════════════════════════════════════════════════════════════════════
# TIER 1: HIGH CONFIDENCE
# ════════════════════════════════════════════════════════════════════════════

Write-Host '--- Tier 1: High Confidence ---' -ForegroundColor Yellow
Write-Host ''

# 11. CSRSS.exe IFEO priority (raw input handler)
Write-Host '  [1/11] CSRSS.exe priority boost' -ForegroundColor White
$csrssPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\csrss.exe\PerfOptions'
Apply-RegSetting 'CSRSS CpuPriorityClass' $csrssPath 'CpuPriorityClass' 3
Apply-RegSetting 'CSRSS IoPriority' $csrssPath 'IoPriority' 3
Write-Host ''

# 12. Game DVR fully disabled
Write-Host '  [2/11] Game DVR disabled' -ForegroundColor White
Apply-RegSetting 'GameDVR_Enabled' 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
Apply-RegSetting 'GameDVR_DXGIHonorFSEWindowsCompatible' 'HKCU:\System\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible' 0
Apply-RegSetting 'GameDVR_EFSEFeatureFlags' 'HKCU:\System\GameConfigStore' 'GameDVR_EFSEFeatureFlags' 0
Apply-RegSetting 'GameDVR_FSEBehavior' 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehavior' 2
Apply-RegSetting 'AllowGameDVR' 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
Apply-RegSetting 'AppCaptureEnabled' 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
Write-Host ''

# 13. Xbox services disabled
Write-Host '  [3/11] Xbox services' -ForegroundColor White
if ($SkipXboxServices) {
    Write-Host '  [SKIP] -SkipXboxServices flag set' -ForegroundColor DarkGray
    $skipped += 'Xbox services (flag)'
} else {
    foreach ($svc in @('XblAuthManager', 'XblGameSave', 'XboxGipSvc', 'XboxNetApiSvc')) {
        Apply-ServiceDisable $svc
    }
}
Write-Host ''

# 14. Power Throttling OFF
Write-Host '  [4/11] Power Throttling disabled' -ForegroundColor White
Apply-RegSetting 'PowerThrottlingOff' 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1
Write-Host ''

# 15. Hibernate / Fast Startup OFF
Write-Host '  [5/11] Hibernate & Fast Startup disabled' -ForegroundColor White
Apply-RegSetting 'HiberbootEnabled' 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0
Apply-RegSetting 'HibernateEnabled' 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled' 0
if (-not $isAudit) {
    try {
        $null = powercfg /h off 2>&1
        Write-Host '  [SET]  powercfg /h off' -ForegroundColor Cyan
        $rollbackManual += 'powercfg /h on'
    } catch {
        Write-Host ('  [FAIL] powercfg /h off: ' + $_.Exception.Message) -ForegroundColor Red
    }
}
Write-Host ''

# 16. NTFS last access time disabled
Write-Host '  [6/11] NTFS last access time' -ForegroundColor White
$lastAccessState = 'unknown'
try {
    $laOut = fsutil behavior query disablelastaccess 2>&1 | Out-String
    if ($laOut -match '= (\d)') { $lastAccessState = $Matches[1] }
} catch {}
if ($lastAccessState -eq '1') {
    Write-Host '  [OK]   DisableLastAccess = 1 (user-managed disabled)' -ForegroundColor Green
} elseif ($isAudit) {
    Write-Host ('  [TODO] DisableLastAccess: ' + $lastAccessState + ' -> 1') -ForegroundColor Yellow
} else {
    try {
        $null = fsutil behavior set disablelastaccess 1 2>&1
        Write-Host ('  [SET]  DisableLastAccess: ' + $lastAccessState + ' -> 1') -ForegroundColor Cyan
        $changes += ('DisableLastAccess: ' + $lastAccessState + ' -> 1')
        $rollbackManual += ('fsutil behavior set disablelastaccess ' + $lastAccessState)
    } catch {
        Write-Host ('  [FAIL] fsutil: ' + $_.Exception.Message) -ForegroundColor Red
        $warnings += ('DisableLastAccess: ' + $_.Exception.Message)
    }
}
Write-Host ''

# 17. NTFS 8.3 naming disabled
Write-Host '  [7/11] NTFS 8.3 naming' -ForegroundColor White
$dot3State = 'unknown'
try {
    $d3Out = fsutil 8dot3name query 2>&1 | Out-String
    if ($d3Out -match 'NtfsDisable8dot3NameCreation\s*=\s*(\d)') { $dot3State = $Matches[1] }
} catch {}
if ($dot3State -eq '1') {
    Write-Host '  [OK]   8dot3name = 1 (disabled on all volumes)' -ForegroundColor Green
} elseif ($isAudit) {
    Write-Host ('  [TODO] 8dot3name: ' + $dot3State + ' -> 1') -ForegroundColor Yellow
} else {
    try {
        $null = fsutil 8dot3name set 1 2>&1
        Write-Host ('  [SET]  8dot3name: ' + $dot3State + ' -> 1') -ForegroundColor Cyan
        $changes += ('8dot3name: ' + $dot3State + ' -> 1')
        $rollbackManual += ('fsutil 8dot3name set ' + $dot3State)
    } catch {
        Write-Host ('  [FAIL] fsutil 8dot3name: ' + $_.Exception.Message) -ForegroundColor Red
        $warnings += ('8dot3name: ' + $_.Exception.Message)
    }
}
Write-Host ''

# 18. IPv6 disabled
Write-Host '  [8/11] IPv6 disabled' -ForegroundColor White
if ($SkipIPv6) {
    Write-Host '  [SKIP] -SkipIPv6 flag set' -ForegroundColor DarkGray
    $skipped += 'IPv6 (flag)'
} else {
    Apply-RegSetting 'IPv6 DisabledComponents' 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' 'DisabledComponents' 255
}
Write-Host ''

# 19. Energy telemetry disabled
Write-Host '  [9/11] Energy telemetry disabled' -ForegroundColor White
Apply-RegSetting 'DisableTaggedEnergyLogging' 'HKLM:\SYSTEM\CurrentControlSet\Control\Diagnostics\Performance' 'DisableTaggedEnergyLogging' 1
Apply-RegSetting 'TimeStampInterval' 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Reliability' 'TimeStampInterval' 0
Write-Host ''

# 20. Ultimate Performance power plan
Write-Host '  [10/11] Ultimate Performance power plan' -ForegroundColor White
$ultPerfGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$currentPlan = ''
try {
    $ppOut = powercfg /getactivescheme 2>&1 | Out-String
    if ($ppOut -match 'GUID:\s+(\S+)') { $currentPlan = $Matches[1] }
} catch {}

if ($currentPlan -eq $ultPerfGuid) {
    Write-Host '  [OK]   Ultimate Performance already active' -ForegroundColor Green
} elseif ($isAudit) {
    Write-Host ('  [TODO] Active plan: ' + $powerPlan + ' -> Ultimate Performance') -ForegroundColor Yellow
} else {
    try {
        $existing = powercfg /list 2>&1 | Out-String
        if ($existing -notmatch $ultPerfGuid) {
            $null = powercfg -duplicatescheme $ultPerfGuid 2>&1
        }
        $null = powercfg /setactive $ultPerfGuid 2>&1
        Write-Host ('  [SET]  Power plan -> Ultimate Performance') -ForegroundColor Cyan
        $changes += ('Power plan: ' + $powerPlan + ' -> Ultimate Performance')
        $rollbackManual += ('powercfg /setactive ' + $currentPlan)
    } catch {
        Write-Host ('  [FAIL] powercfg: ' + $_.Exception.Message) -ForegroundColor Red
        $warnings += ('Power plan: ' + $_.Exception.Message)
    }
}
Write-Host '  [NOTE] X3D boost behavior may differ under Ultimate Performance' -ForegroundColor DarkYellow
Write-Host ''

# 21. Processor idle demote/promote thresholds
Write-Host '  [11/11] Idle demote/promote thresholds' -ForegroundColor White
if ($isAudit) {
    Write-Host '  [TODO] IdleDemote -> 5%, IdlePromote -> 5%' -ForegroundColor Yellow
} else {
    try {
        $null = powercfg -setacvalueindex scheme_current sub_processor IDLEDEMOTE 5 2>&1
        $null = powercfg -setacvalueindex scheme_current sub_processor IDLEPROMOTE 5 2>&1
        $null = powercfg -setactive scheme_current 2>&1
        Write-Host '  [SET]  IdleDemote=5%, IdlePromote=5%' -ForegroundColor Cyan
        $changes += 'Idle thresholds: Demote=5%, Promote=5%'
        $rollbackManual += 'powercfg -setacvalueindex scheme_current sub_processor IDLEDEMOTE 100'
        $rollbackManual += 'powercfg -setacvalueindex scheme_current sub_processor IDLEPROMOTE 100'
        $rollbackManual += 'powercfg -setactive scheme_current'
    } catch {
        Write-Host ('  [FAIL] powercfg idle: ' + $_.Exception.Message) -ForegroundColor Red
        $warnings += ('Idle thresholds: ' + $_.Exception.Message)
    }
}
Write-Host ''

# ════════════════════════════════════════════════════════════════════════════
# TIER 2: MEDIUM CONFIDENCE
# ════════════════════════════════════════════════════════════════════════════

if ($Tier -ge 2) {
    Write-Host '--- Tier 2: Medium Confidence ---' -ForegroundColor Yellow
    Write-Host ''

    # 22. MMCSS NoLazyMode
    Write-Host '  [1/8] MMCSS NoLazyMode' -ForegroundColor White
    Apply-RegSetting 'NoLazyMode' 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NoLazyMode' 1
    Write-Host ''

    # 23. MMCSS Games: Latency Sensitive
    Write-Host '  [2/8] MMCSS Games Latency Sensitive' -ForegroundColor White
    Apply-RegString 'Games Latency Sensitive' 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Latency Sensitive' 'True'
    Write-Host ''

    # 24. DwmEnableMMCSS hint
    Write-Host '  [3/8] DwmEnableMMCSS' -ForegroundColor White
    Write-Host '  [INFO] DwmEnableMMCSS requires runtime activation (not persistent registry).' -ForegroundColor DarkYellow
    Write-Host '  [INFO] For borderless windowed games, run in admin PowerShell:' -ForegroundColor DarkYellow
    Write-Host '         Import-Module GamingPCSetup\GameMode.ps1; GM-DwmEnableMMCSS 1' -ForegroundColor DarkGray
    Write-Host '  [INFO] Resets when launching fullscreen exclusive games.' -ForegroundColor DarkYellow
    $skipped += 'DwmEnableMMCSS (runtime only)'
    Write-Host ''

    # 25. GlobalTimerResolutionRequests
    Write-Host '  [4/8] GlobalTimerResolutionRequests' -ForegroundColor White
    Apply-RegSetting 'GlobalTimerResolutionRequests' 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 1
    Write-Host '  [INFO] Pair with ISLC (wagnardsoft.com) set to 0.50ms for best effect.' -ForegroundColor DarkYellow
    Write-Host ''

    # 26. DisablePagingExecutive
    Write-Host '  [5/8] DisablePagingExecutive' -ForegroundColor White
    Apply-RegSetting 'DisablePagingExecutive' 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'DisablePagingExecutive' 1
    Write-Host '  [NOTE] Marginal on 32GB systems. Measure before/after.' -ForegroundColor DarkYellow
    Write-Host ''

    # 27. Game process IFEO priority
    Write-Host ('  [6/8] ' + $GameProcess + ' IFEO priority') -ForegroundColor White
    $gamePath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\' + $GameProcess + '.exe\PerfOptions'
    Apply-RegSetting ($GameProcess + ' CpuPriorityClass') $gamePath 'CpuPriorityClass' 3
    Apply-RegSetting ($GameProcess + ' IoPriority') $gamePath 'IoPriority' 3
    Write-Host ''

    # 28. DisplayPostProcessing MMCSS task
    Write-Host '  [7/8] DisplayPostProcessing MMCSS task' -ForegroundColor White
    $dppPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\DisplayPostProcessing'
    Apply-RegSetting 'DPP GPU Priority' $dppPath 'GPU Priority' 18
    Apply-RegSetting 'DPP Priority' $dppPath 'Priority' 8
    Apply-RegString 'DPP Scheduling Category' $dppPath 'Scheduling Category' 'High'
    Apply-RegString 'DPP SFIO Priority' $dppPath 'SFIO Priority' 'High'
    Apply-RegString 'DPP Latency Sensitive' $dppPath 'Latency Sensitive' 'True'
    Write-Host ''

    # 29. Audio exclusive mode
    Write-Host '  [8/8] Audio exclusive mode' -ForegroundColor White
    Write-Host '  [INFO] Enable via: Sound Settings > Device Properties > Advanced' -ForegroundColor DarkYellow
    Write-Host '         Check "Allow applications exclusive use" + "Give exclusive priority"' -ForegroundColor DarkGray
    $skipped += 'Audio exclusive mode (per-device GUI setting)'
    Write-Host ''
}

# ════════════════════════════════════════════════════════════════════════════
# TIER 3: EXPERIMENTAL
# ════════════════════════════════════════════════════════════════════════════

if ($Tier -ge 3) {
    Write-Host '--- Tier 3: EXPERIMENTAL ---' -ForegroundColor Red
    Write-Host '  WARNING: Test each setting individually. Some may cause instability.' -ForegroundColor Red
    Write-Host ''

    # 30. DPC kernel tweaks
    Write-Host '  [1/3] DPC kernel tweaks' -ForegroundColor White
    $kernelPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'
    Apply-RegSetting 'IdealDpcRate' $kernelPath 'IdealDpcRate' 1
    Apply-RegSetting 'MaximumDpcQueueDepth' $kernelPath 'MaximumDpcQueueDepth' 1
    Apply-RegSetting 'DpcWatchdogPeriod' $kernelPath 'DpcWatchdogPeriod' 0
    Write-Host '  [WARN] DpcWatchdogPeriod=0 disables DPC watchdog. Stuck DPC = system freeze.' -ForegroundColor Red
    Write-Host ''

    # 31. disabledynamictick
    Write-Host '  [2/3] disabledynamictick' -ForegroundColor White
    Write-Host '  [WARN] Mixed results on Win11. May cause mouse acceleration artifacts.' -ForegroundColor Red
    if ($isAudit) {
        Write-Host '  [TODO] bcdedit /set disabledynamictick yes' -ForegroundColor Yellow
    } else {
        try {
            $null = bcdedit /set disabledynamictick yes 2>&1
            Write-Host '  [SET]  disabledynamictick = yes' -ForegroundColor Cyan
            $changes += 'bcdedit disabledynamictick = yes'
            $rollbackManual += 'bcdedit /deletevalue disabledynamictick'
        } catch {
            Write-Host ('  [FAIL] bcdedit: ' + $_.Exception.Message) -ForegroundColor Red
            $warnings += ('disabledynamictick: ' + $_.Exception.Message)
        }
    }
    Write-Host ''

    # 32. Spectre/Meltdown mitigations OFF
    Write-Host '  [3/3] Spectre/Meltdown mitigations' -ForegroundColor White
    Write-Host '  ************************************************************' -ForegroundColor Red
    Write-Host '  * SECURITY WARNING: Disabling CPU vulnerability mitigations *' -ForegroundColor Red
    Write-Host '  * reduces protection against speculative execution attacks. *' -ForegroundColor Red
    Write-Host '  * Minimal perf gain on Zen 5 (hardware-mitigated in silicon).*' -ForegroundColor Red
    Write-Host '  ************************************************************' -ForegroundColor Red
    $memMgmt = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    Apply-RegSetting 'FeatureSettingsOverride' $memMgmt 'FeatureSettingsOverride' 3
    Apply-RegSetting 'FeatureSettingsOverrideMask' $memMgmt 'FeatureSettingsOverrideMask' 3
    Write-Host ''
}

# ════════════════════════════════════════════════════════════════════════════
# PHASE 4: BIOS CHECKLIST
# ════════════════════════════════════════════════════════════════════════════

Write-Host '--- Phase 4: BIOS Checklist ---' -ForegroundColor Yellow

$biosChecklist = @(
    '# BIOS Optimization Checklist for 9800X3D',
    ('# Generated: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
    '',
    'Apply these settings manually in BIOS or via SCEWIN.',
    'Reboot required after BIOS changes.',
    '',
    '| # | Setting | Location | Target | Risk | Notes |',
    '|---|---------|----------|--------|------|-------|',
    '| 1 | Global C-State Control | AMD CBS > CPU Common | **Enabled** | Low | Frame pacing fix for X3D; allows CPPC to work |',
    '| 2 | CPPC Preferred Cores | AMD CBS > CPU Common | **Disabled** | Low | Eliminates 8kHz scheduling micro-stutter |',
    '| 3 | TSME (Transparent SME) | AMD CBS > CPU Common | **Disabled** | Low | Removes ~2-3ns memory encryption latency |',
    '| 4 | Data Scramble | AMD CBS > UMC Common | **Disabled** | Low | Removes memory bus encryption layer |',
    '| 5 | SMEE | AMD CBS > NBIO Common | **Disabled** | Low | Same family as TSME |',
    '| 6 | PBO | AMD CBS > PBO | **Enabled** | Low | Then set Curve Optimizer -10 all-core |',
    '| 7 | Curve Optimizer | AMD CBS > PBO > CO | **-10 All Core** | Medium | Start conservative; test with CoreCycler |',
    '| 8 | LLC (Load Line Calibration) | VRM/Power settings | **Level 2-3** | Low | Stabilize vcore under gaming load |',
    '| 9 | Spread Spectrum | Clock settings | **Disabled** | Low | Cleaner clock signal for PCIe/memory |',
    '| 10 | Fast Boot | Boot settings | **OFF** | None | Full POST ensures proper device enumeration |',
    '| 11 | Platform Power Management | ACPI settings | **Disabled** | Low | Prevents PCIe L-state wake-up latency |',
    '',
    '## Safety Notes',
    '- Change max 4 settings at a time (SCEWIN SMI freeze limit)',
    '- CMOS clear available: hold BIOS jumper 3 sec or remove battery 30 min',
    '- Safe VSOC floor for this rig: ~1.18V (NOT 1.05V JEDEC)',
    '- After CO changes, run CoreCycler for 1-2 hours per core to verify stability',
    '- Monitor for WHEA Event 19 errors after CO changes'
)

if (-not $isAudit) {
    $biosFile = Join-Path $outDir 'BIOS_CHECKLIST.md'
    $biosChecklist | Out-File -FilePath $biosFile -Encoding UTF8
    Write-Host ('  [SAVED] ' + $biosFile) -ForegroundColor Green
} else {
    Write-Host '  BIOS changes (apply manually):' -ForegroundColor DarkGray
    foreach ($line in $biosChecklist) {
        if ($line -match '^\| \d') { Write-Host ('  ' + $line) -ForegroundColor DarkGray }
    }
}
Write-Host ''

# ════════════════════════════════════════════════════════════════════════════
# PHASE 5: ROLLBACK SCRIPT + SUMMARY
# ════════════════════════════════════════════════════════════════════════════

if (-not $isAudit) {
    $rollbackScript = @(
        '#Requires -RunAsAdministrator',
        '# Auto-generated rollback for deep_optimize.ps1',
        ('# Run: ' + $ts),
        ('# Tier: ' + $Tier),
        '$ErrorActionPreference = ''Continue''',
        '',
        '# --- Registry rollbacks ---'
    )
    $rollbackScript += $rollbackReg
    if ($rollbackManual.Count -gt 0) {
        $rollbackScript += ''
        $rollbackScript += '# --- Manual rollbacks (fsutil, powercfg, bcdedit) ---'
        foreach ($cmd in $rollbackManual) {
            $rollbackScript += $cmd
        }
    }
    $rollbackFile = Join-Path $outDir 'rollback_deep.ps1'
    $rollbackScript | Out-File -FilePath $rollbackFile -Encoding UTF8
    Write-Host ('[ROLLBACK] ' + $rollbackFile) -ForegroundColor Green
}

Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host '  SUMMARY' -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ('  Applied:  ' + $changes.Count) -ForegroundColor Green
Write-Host ('  Skipped:  ' + $skipped.Count) -ForegroundColor DarkGray
Write-Host ('  Warnings: ' + $warnings.Count) -ForegroundColor $(if ($warnings.Count -gt 0) { 'Red' } else { 'Green' })
Write-Host ''

if ($warnings.Count -gt 0) {
    Write-Host '  Warnings:' -ForegroundColor Red
    foreach ($w in $warnings) { Write-Host ('    - ' + $w) -ForegroundColor Red }
    Write-Host ''
}

if ($skipped.Count -gt 0) {
    Write-Host '  Skipped items:' -ForegroundColor DarkGray
    foreach ($s in $skipped) { Write-Host ('    - ' + $s) -ForegroundColor DarkGray }
    Write-Host ''
}

# Reboot recommendation
$needsReboot = @()
if (-not $SkipIPv6) { $needsReboot += 'IPv6 disable' }
if ($Tier -ge 3) { $needsReboot += 'disabledynamictick'; $needsReboot += 'Spectre mitigations' }
if ($needsReboot.Count -gt 0 -and -not $isAudit) {
    Write-Host '  REBOOT REQUIRED for:' -ForegroundColor Yellow
    foreach ($r in $needsReboot) { Write-Host ('    - ' + $r) -ForegroundColor Yellow }
    Write-Host ''
}

if (-not $isAudit) {
    Write-Host '  Next steps:' -ForegroundColor White
    Write-Host '    1. Reboot if needed (see above)' -ForegroundColor DarkGray
    Write-Host '    2. Apply BIOS changes from checklist' -ForegroundColor DarkGray
    Write-Host '    3. Run capture: .\scripts\pipeline.ps1 -Label "DEEP_OPT_T' -NoNewline -ForegroundColor DarkGray
    Write-Host $Tier -NoNewline -ForegroundColor DarkGray
    Write-Host '" -SkipWPR -DurationSec 10' -ForegroundColor DarkGray
    Write-Host ''
}

Write-Host 'Done.' -ForegroundColor Cyan
