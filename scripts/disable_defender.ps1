#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Fully disable Windows Defender real-time protection + WdFilter minifilter.
.DESCRIPTION
    Disables Defender via Group Policy registry keys, MpPreference, and
    service configuration. Creates a scheduled task to re-apply on boot
    (Windows Update can re-enable Defender).

    PREREQUISITE: Tamper Protection must be disabled MANUALLY first:
      Settings > Windows Security > Virus & threat protection >
      Manage settings > Tamper Protection = OFF

    Measured impact: 454K page faults/sec from WdFilter.sys during Chrome
    page loads (2026-04-27 diagnostic). DPC overhead negligible — the
    bottleneck is the minifilter intercepting every file operation.

.NOTES
    Reboot: REQUIRED for full effect (WdFilter.sys unload)
    Rollback: Run .\enable_defender.ps1 or rollback.ps1 -BackupFile <backup>
    Security: This removes ALL real-time malware protection.
#>

param(
    [switch]$WhatIf,
    [switch]$SkipScheduledTask,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent

Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Red
Write-Host '║  DISABLE WINDOWS DEFENDER — FULL REAL-TIME PROTECTION OFF  ║' -ForegroundColor Red
Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Red
Write-Host ''

# ─── Safety: Check Tamper Protection ────────────────────────────────────────
$tamperProtection = $null
try {
    $mpStatus = Get-MpComputerStatus -ErrorAction Stop
    $tamperProtection = $mpStatus.IsTamperProtected
} catch {
    Write-Host 'WARNING: Cannot read Defender status. Defender service may already be stopped.' -ForegroundColor Yellow
}

if ($tamperProtection -eq $true -and -not $Force) {
    Write-Host 'ERROR: Tamper Protection is ON. Registry changes will be reverted by Defender.' -ForegroundColor Red
    Write-Host ''
    Write-Host 'Disable it manually first:' -ForegroundColor Yellow
    Write-Host '  Settings > Windows Security > Virus & threat protection >' -ForegroundColor Yellow
    Write-Host '  Manage settings > Tamper Protection = OFF' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Then re-run this script.' -ForegroundColor Yellow
    Write-Host '(Use -Force to skip this check if you know Tamper Protection is off)' -ForegroundColor Gray
    exit 1
}

# ─── Backup current state ──────────────────────────────────────────────────
$timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupFile = Join-Path $projectRoot ('captures\backup_pre_defender_disable_' + $timestamp + '.txt')
$backupLines = @()
$backupLines += '# Defender Disable Backup: pre-change state'
$backupLines += ('# Captured: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$backupLines += ''

# Capture current registry state for rollback
$gpoPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
$rtpPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'

# Record existing values (or absence) for rollback
$existingKeys = @(
    @{ Path = $gpoPath; Name = 'DisableAntiSpyware' },
    @{ Path = $gpoPath; Name = 'DisableAntiVirus' },
    @{ Path = $rtpPath; Name = 'DisableRealtimeMonitoring' },
    @{ Path = $rtpPath; Name = 'DisableBehaviorMonitoring' },
    @{ Path = $rtpPath; Name = 'DisableOnAccessProtection' },
    @{ Path = $rtpPath; Name = 'DisableScanOnRealtimeEnable' },
    @{ Path = $rtpPath; Name = 'DisableIOAVProtection' }
)

$backupLines += '=== Pre-Change State ==='
foreach ($k in $existingKeys) {
    $val = Get-ItemProperty -Path $k.Path -Name $k.Name -ErrorAction SilentlyContinue
    if ($null -ne $val) {
        $backupLines += ($k.Path + '\' + $k.Name + ' = ' + $val.($k.Name))
    } else {
        $backupLines += ($k.Path + '\' + $k.Name + ' = [NOT SET]')
    }
}

# Capture MpPreference state
try {
    $mpPref = Get-MpPreference -ErrorAction Stop
    $backupLines += ''
    $backupLines += 'DisableRealtimeMonitoring = ' + $mpPref.DisableRealtimeMonitoring
    $backupLines += 'DisableBehaviorMonitoring = ' + $mpPref.DisableBehaviorMonitoring
    $backupLines += 'DisableIOAVProtection = ' + $mpPref.DisableIOAVProtection
    $backupLines += 'DisableIntrusionPreventionSystem = ' + $mpPref.DisableIntrusionPreventionSystem
    $backupLines += 'ExclusionPath count = ' + $mpPref.ExclusionPath.Count
    $backupLines += 'ExclusionProcess count = ' + $mpPref.ExclusionProcess.Count
} catch {
    $backupLines += 'Get-MpPreference failed: ' + $_.Exception.Message
}

$backupLines += ''
$backupLines += '=== Rollback Commands ==='
$backupLines += 'Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -Name "DisableAntiSpyware" -ErrorAction SilentlyContinue'
$backupLines += 'Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -Name "DisableAntiVirus" -ErrorAction SilentlyContinue'
$backupLines += 'Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" -Name "DisableRealtimeMonitoring" -ErrorAction SilentlyContinue'
$backupLines += 'Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" -Name "DisableBehaviorMonitoring" -ErrorAction SilentlyContinue'
$backupLines += 'Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" -Name "DisableOnAccessProtection" -ErrorAction SilentlyContinue'
$backupLines += 'Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" -Name "DisableScanOnRealtimeEnable" -ErrorAction SilentlyContinue'
$backupLines += 'Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" -Name "DisableIOAVProtection" -ErrorAction SilentlyContinue'
$backupLines += 'Set-MpPreference -DisableRealtimeMonitoring $false'
$backupLines += 'Set-MpPreference -DisableBehaviorMonitoring $false'
$backupLines += 'Set-MpPreference -DisableIOAVProtection $false'

if ($WhatIf) {
    Write-Host '[WhatIf] Would write backup to: ' -NoNewline
    Write-Host $backupFile -ForegroundColor Cyan
} else {
    $backupLines | Out-File $backupFile -Encoding UTF8
    Write-Host ('Backup: ' + $backupFile) -ForegroundColor Green
}
Write-Host ''

# ─── Step 1: Group Policy registry keys ────────────────────────────────────
Write-Host '[1/4] Setting Group Policy registry keys...' -ForegroundColor Yellow

$regChanges = @(
    @{ Path = $gpoPath;  Name = 'DisableAntiSpyware';          Value = 1; Type = 'DWord' },
    @{ Path = $gpoPath;  Name = 'DisableAntiVirus';            Value = 1; Type = 'DWord' },
    @{ Path = $rtpPath;  Name = 'DisableRealtimeMonitoring';    Value = 1; Type = 'DWord' },
    @{ Path = $rtpPath;  Name = 'DisableBehaviorMonitoring';    Value = 1; Type = 'DWord' },
    @{ Path = $rtpPath;  Name = 'DisableOnAccessProtection';    Value = 1; Type = 'DWord' },
    @{ Path = $rtpPath;  Name = 'DisableScanOnRealtimeEnable';  Value = 1; Type = 'DWord' },
    @{ Path = $rtpPath;  Name = 'DisableIOAVProtection';        Value = 1; Type = 'DWord' }
)

foreach ($r in $regChanges) {
    if (-not (Test-Path $r.Path)) {
        if ($WhatIf) {
            Write-Host ('  [WhatIf] Would create key: ' + $r.Path) -ForegroundColor Gray
        } else {
            New-Item -Path $r.Path -Force | Out-Null
        }
    }
    if ($WhatIf) {
        Write-Host ('  [WhatIf] Would set ' + $r.Name + ' = ' + $r.Value) -ForegroundColor Gray
    } else {
        Set-ItemProperty -Path $r.Path -Name $r.Name -Value $r.Value -Type $r.Type
        Write-Host ('  SET ' + $r.Name + ' = ' + $r.Value) -ForegroundColor Green
    }
}

# ─── Step 2: MpPreference direct disable ───────────────────────────────────
Write-Host ''
Write-Host '[2/4] Disabling via MpPreference...' -ForegroundColor Yellow

$mpChanges = @(
    @{ Name = 'DisableRealtimeMonitoring';       Value = $true },
    @{ Name = 'DisableBehaviorMonitoring';       Value = $true },
    @{ Name = 'DisableIOAVProtection';           Value = $true },
    @{ Name = 'DisableIntrusionPreventionSystem'; Value = $true },
    @{ Name = 'SubmitSamplesConsent';             Value = 2 },
    @{ Name = 'MAPSReporting';                    Value = 0 },
    @{ Name = 'PUAProtection';                    Value = 0 },
    @{ Name = 'ScanAvgCPULoadFactor';             Value = 5 }
)

foreach ($mp in $mpChanges) {
    if ($WhatIf) {
        Write-Host ('  [WhatIf] Would set ' + $mp.Name + ' = ' + $mp.Value) -ForegroundColor Gray
    } else {
        try {
            $params = @{ $mp.Name = $mp.Value }
            Set-MpPreference @params -ErrorAction Stop
            Write-Host ('  SET ' + $mp.Name + ' = ' + $mp.Value) -ForegroundColor Green
        } catch {
            Write-Host ('  SKIP ' + $mp.Name + ': ' + $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}

# ─── Step 3: Disable Defender scheduled tasks ──────────────────────────────
Write-Host ''
Write-Host '[3/4] Disabling Defender scheduled tasks...' -ForegroundColor Yellow

$defenderTasks = @(
    'Microsoft\Windows\Windows Defender\Windows Defender Cache Maintenance',
    'Microsoft\Windows\Windows Defender\Windows Defender Cleanup',
    'Microsoft\Windows\Windows Defender\Windows Defender Scheduled Scan',
    'Microsoft\Windows\Windows Defender\Windows Defender Verification'
)

foreach ($task in $defenderTasks) {
    $taskObj = Get-ScheduledTask -TaskPath ('\' + ($task -replace '\\[^\\]+$', '\')) -TaskName ($task -split '\\' | Select-Object -Last 1) -ErrorAction SilentlyContinue
    if ($null -ne $taskObj -and $taskObj.State -ne 'Disabled') {
        if ($WhatIf) {
            Write-Host ('  [WhatIf] Would disable: ' + $task) -ForegroundColor Gray
        } else {
            try {
                Disable-ScheduledTask -TaskPath ('\' + ($task -replace '\\[^\\]+$', '\')) -TaskName ($task -split '\\' | Select-Object -Last 1) -ErrorAction Stop | Out-Null
                Write-Host ('  DISABLED ' + ($task -split '\\' | Select-Object -Last 1)) -ForegroundColor Green
            } catch {
                Write-Host ('  SKIP ' + ($task -split '\\' | Select-Object -Last 1) + ': ' + $_.Exception.Message) -ForegroundColor Yellow
            }
        }
    } else {
        $state = 'not found'
        if ($null -ne $taskObj) { $state = $taskObj.State }
        Write-Host ('  SKIP ' + ($task -split '\\' | Select-Object -Last 1) + ' (' + $state + ')') -ForegroundColor Gray
    }
}

# ─── Step 4: Create boot persistence task ──────────────────────────────────
if (-not $SkipScheduledTask) {
    Write-Host ''
    Write-Host '[4/4] Creating boot persistence scheduled task...' -ForegroundColor Yellow

    $taskName = 'LatencyGuard-DefenderDisable'
    $taskPath = '\LatencyGuard\'

    # Inline script that re-applies Defender disable on boot
    $bootScript = @'
# LatencyGuard: Re-apply Defender disable after Windows Update
$gpo = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
$rtp = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'
if (-not (Test-Path $gpo)) { New-Item -Path $gpo -Force | Out-Null }
if (-not (Test-Path $rtp)) { New-Item -Path $rtp -Force | Out-Null }
Set-ItemProperty -Path $gpo -Name 'DisableAntiSpyware' -Value 1 -Type DWord
Set-ItemProperty -Path $gpo -Name 'DisableAntiVirus' -Value 1 -Type DWord
Set-ItemProperty -Path $rtp -Name 'DisableRealtimeMonitoring' -Value 1 -Type DWord
Set-ItemProperty -Path $rtp -Name 'DisableBehaviorMonitoring' -Value 1 -Type DWord
Set-ItemProperty -Path $rtp -Name 'DisableOnAccessProtection' -Value 1 -Type DWord
Set-ItemProperty -Path $rtp -Name 'DisableScanOnRealtimeEnable' -Value 1 -Type DWord
Set-ItemProperty -Path $rtp -Name 'DisableIOAVProtection' -Value 1 -Type DWord
try {
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
    Set-MpPreference -DisableBehaviorMonitoring $true -ErrorAction SilentlyContinue
    Set-MpPreference -DisableIOAVProtection $true -ErrorAction SilentlyContinue
} catch {}
'@

    $bootScriptPath = Join-Path $PSScriptRoot 'defender_disable_boot.ps1'

    if ($WhatIf) {
        Write-Host ('  [WhatIf] Would create boot script: ' + $bootScriptPath) -ForegroundColor Gray
        Write-Host ('  [WhatIf] Would register task: ' + $taskPath + $taskName) -ForegroundColor Gray
    } else {
        $bootScript | Out-File $bootScriptPath -Encoding UTF8
        Write-Host ('  Boot script: ' + $bootScriptPath) -ForegroundColor Green

        # Remove existing task if present
        $existing = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false
        }

        $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $bootScriptPath + '"')
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

        Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'LatencyGuard: Re-apply Defender disable after Windows Update' | Out-Null
        Write-Host ('  Registered: ' + $taskPath + $taskName + ' (runs at boot as SYSTEM)') -ForegroundColor Green
    }
} else {
    Write-Host ''
    Write-Host '[4/4] Skipped scheduled task (use without -SkipScheduledTask for persistence)' -ForegroundColor Gray
}

# ─── Verify ────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '=== Verification ===' -ForegroundColor Cyan

try {
    $mpStatus = Get-MpComputerStatus -ErrorAction Stop
    $rtEnabled = $mpStatus.RealTimeProtectionEnabled
    $amRunning = $mpStatus.AMServiceEnabled
    $tamper    = $mpStatus.IsTamperProtected

    $rtColor = 'Green'; if ($rtEnabled) { $rtColor = 'Red' }
    $amColor = 'Green'; if ($amRunning) { $amColor = 'Yellow' }

    Write-Host ('  RealTimeProtection: ' + $rtEnabled) -ForegroundColor $rtColor
    Write-Host ('  AMService:          ' + $amRunning) -ForegroundColor $amColor
    Write-Host ('  TamperProtection:   ' + $tamper) -ForegroundColor $(if ($tamper) { 'Red' } else { 'Green' })

    if ($rtEnabled) {
        Write-Host ''
        Write-Host '  WARNING: Real-time protection is still ON.' -ForegroundColor Red
        Write-Host '  This usually means Tamper Protection blocked the changes.' -ForegroundColor Red
        Write-Host '  Disable Tamper Protection manually, then re-run.' -ForegroundColor Yellow
    }
} catch {
    Write-Host '  Defender status unavailable (service may be stopped)' -ForegroundColor Green
}

# ─── Summary ───────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '=== Summary ===' -ForegroundColor Cyan
Write-Host ('  Backup:    ' + $backupFile) -ForegroundColor White
Write-Host ('  Rollback:  .\enable_defender.ps1  OR  .\rollback.ps1 -BackupFile "' + $backupFile + '"') -ForegroundColor White
Write-Host ''
Write-Host '  A REBOOT is required for WdFilter.sys to fully unload.' -ForegroundColor Yellow
Write-Host '  After reboot, verify with: Get-MpComputerStatus | Select RealTimeProtectionEnabled' -ForegroundColor Gray
