#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Re-enable Windows Defender real-time protection.
.DESCRIPTION
    Reverses all changes from disable_defender.ps1:
    removes Group Policy overrides, re-enables MpPreference settings,
    re-enables scheduled tasks, removes boot persistence task.
.NOTES
    Reboot: RECOMMENDED for full effect
    Tamper Protection: Re-enable manually after reboot:
      Settings > Windows Security > Virus & threat protection >
      Manage settings > Tamper Protection = ON
#>

$ErrorActionPreference = 'Stop'

Write-Host '=== RE-ENABLE WINDOWS DEFENDER ===' -ForegroundColor Green
Write-Host ''

# ─── Step 1: Remove Group Policy overrides ─────────────────────────────────
Write-Host '[1/4] Removing Group Policy registry keys...' -ForegroundColor Yellow

$gpoPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
$rtpPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'

$keys = @(
    @{ Path = $gpoPath; Name = 'DisableAntiSpyware' },
    @{ Path = $gpoPath; Name = 'DisableAntiVirus' },
    @{ Path = $rtpPath; Name = 'DisableRealtimeMonitoring' },
    @{ Path = $rtpPath; Name = 'DisableBehaviorMonitoring' },
    @{ Path = $rtpPath; Name = 'DisableOnAccessProtection' },
    @{ Path = $rtpPath; Name = 'DisableScanOnRealtimeEnable' },
    @{ Path = $rtpPath; Name = 'DisableIOAVProtection' }
)

foreach ($k in $keys) {
    try {
        Remove-ItemProperty -Path $k.Path -Name $k.Name -ErrorAction SilentlyContinue
        Write-Host ('  REMOVED ' + $k.Name) -ForegroundColor Green
    } catch {
        Write-Host ('  SKIP ' + $k.Name + ': ' + $_.Exception.Message) -ForegroundColor Gray
    }
}

# ─── Step 2: Re-enable via MpPreference ────────────────────────────────────
Write-Host ''
Write-Host '[2/4] Re-enabling via MpPreference...' -ForegroundColor Yellow

$reEnableParams = @(
    @{ Name = 'DisableRealtimeMonitoring';       Value = $false },
    @{ Name = 'DisableBehaviorMonitoring';       Value = $false },
    @{ Name = 'DisableIOAVProtection';           Value = $false },
    @{ Name = 'DisableIntrusionPreventionSystem'; Value = $false },
    @{ Name = 'SubmitSamplesConsent';             Value = 1 },
    @{ Name = 'MAPSReporting';                    Value = 2 }
)

foreach ($mp in $reEnableParams) {
    try {
        $params = @{ $mp.Name = $mp.Value }
        Set-MpPreference @params -ErrorAction Stop
        Write-Host ('  SET ' + $mp.Name + ' = ' + $mp.Value) -ForegroundColor Green
    } catch {
        Write-Host ('  SKIP ' + $mp.Name + ': ' + $_.Exception.Message) -ForegroundColor Yellow
    }
}

# ─── Step 3: Re-enable Defender scheduled tasks ────────────────────────────
Write-Host ''
Write-Host '[3/4] Re-enabling Defender scheduled tasks...' -ForegroundColor Yellow

$defenderTasks = @(
    @{ Path = '\Microsoft\Windows\Windows Defender\'; Name = 'Windows Defender Cache Maintenance' },
    @{ Path = '\Microsoft\Windows\Windows Defender\'; Name = 'Windows Defender Cleanup' },
    @{ Path = '\Microsoft\Windows\Windows Defender\'; Name = 'Windows Defender Scheduled Scan' },
    @{ Path = '\Microsoft\Windows\Windows Defender\'; Name = 'Windows Defender Verification' }
)

foreach ($task in $defenderTasks) {
    try {
        Enable-ScheduledTask -TaskPath $task.Path -TaskName $task.Name -ErrorAction Stop | Out-Null
        Write-Host ('  ENABLED ' + $task.Name) -ForegroundColor Green
    } catch {
        Write-Host ('  SKIP ' + $task.Name + ': ' + $_.Exception.Message) -ForegroundColor Yellow
    }
}

# ─── Step 4: Remove boot persistence task ──────────────────────────────────
Write-Host ''
Write-Host '[4/4] Removing boot persistence task...' -ForegroundColor Yellow

$taskName = 'LatencyGuard-DefenderDisable'
$taskPath = '\LatencyGuard\'
$existing = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
if ($null -ne $existing) {
    Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false
    Write-Host ('  REMOVED ' + $taskPath + $taskName) -ForegroundColor Green
} else {
    Write-Host '  Task not found (already removed)' -ForegroundColor Gray
}

# Remove boot script
$bootScript = Join-Path $PSScriptRoot 'defender_disable_boot.ps1'
if (Test-Path $bootScript) {
    Remove-Item $bootScript -Force
    Write-Host '  REMOVED defender_disable_boot.ps1' -ForegroundColor Green
}

# ─── Verify ────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '=== Verification ===' -ForegroundColor Cyan
try {
    $mpStatus = Get-MpComputerStatus -ErrorAction Stop
    Write-Host ('  RealTimeProtection: ' + $mpStatus.RealTimeProtectionEnabled) -ForegroundColor $(if ($mpStatus.RealTimeProtectionEnabled) { 'Green' } else { 'Yellow' })
    Write-Host ('  AMService:          ' + $mpStatus.AMServiceEnabled) -ForegroundColor $(if ($mpStatus.AMServiceEnabled) { 'Green' } else { 'Yellow' })
} catch {
    Write-Host '  Defender service not responding yet — reboot may be needed' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Defender re-enabled. Reboot recommended.' -ForegroundColor Green
Write-Host 'Also re-enable Tamper Protection manually in Windows Security settings.' -ForegroundColor Yellow
