<#
.SYNOPSIS
    Fully disable Windows Defender — services, scanning, and safety-net exclusion.
.DESCRIPTION
    Requires admin + Tamper Protection OFF.
    1. Disables WinDefend and WdNisSvc services via registry (Start=4)
    2. Adds C:\ drive exclusion as safety net
    3. Verifies current state
.NOTES
    Reversible: Set Start=2 (WinDefend) / Start=3 (WdNisSvc), remove C:\ exclusion.
#>
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

Write-Host '=== Defender Full Kill ===' -ForegroundColor Red
Write-Host ''

# ── Step 1: Verify Tamper Protection is OFF ─────────────────────────────────
$tpPath = 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features'
$tpValue = (Get-ItemProperty $tpPath -Name 'TamperProtection' -ErrorAction SilentlyContinue).TamperProtection
if ($tpValue -ne 4 -and $tpValue -ne 0) {
    Write-Host ('ABORT: Tamper Protection is ON (value=' + $tpValue + ')') -ForegroundColor Red
    Write-Host 'Disable TP first: Windows Security > Virus & threat protection > Manage settings > Tamper Protection OFF' -ForegroundColor Yellow
    exit 1
}
Write-Host ('Tamper Protection: OFF (value=' + $tpValue + ')') -ForegroundColor Green

# ── Step 2: Disable services via registry ───────────────────────────────────
$services = @(
    @{ Name = 'WinDefend'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\WinDefend'; Target = 4 },
    @{ Name = 'WdNisSvc';  Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\WdNisSvc';  Target = 4 }
)

foreach ($svc in $services) {
    $current = (Get-ItemProperty $svc.Path -Name 'Start' -ErrorAction SilentlyContinue).Start
    if ($current -eq $svc.Target) {
        Write-Host ($svc.Name + ': already disabled (Start=' + $current + ')') -ForegroundColor Green
    } else {
        try {
            Set-ItemProperty $svc.Path -Name 'Start' -Value $svc.Target -Type DWord
            Write-Host ($svc.Name + ': Start ' + $current + ' -> ' + $svc.Target + ' (Disabled)') -ForegroundColor Cyan
        } catch {
            Write-Host ($svc.Name + ': FAILED — ' + $_.Exception.Message) -ForegroundColor Red
            Write-Host 'Service registry key protected by TrustedInstaller ACL.' -ForegroundColor Yellow
            Write-Host 'Workaround: Use PsExec -s or take ownership of the registry key.' -ForegroundColor Yellow
        }
    }
}

# ── Step 3: Add C:\ drive exclusion ────────────────────────────────────────
$currentExclusions = @((Get-MpPreference).ExclusionPath)
$hasDriveExclusion = $false
foreach ($ex in $currentExclusions) {
    if ($ex -eq 'C:\') { $hasDriveExclusion = $true; break }
}

if ($hasDriveExclusion) {
    Write-Host 'C:\ exclusion: already present' -ForegroundColor Green
} else {
    Add-MpPreference -ExclusionPath 'C:\'
    Write-Host 'C:\ exclusion: ADDED (safety net)' -ForegroundColor Cyan
}

# ── Step 4: Ensure GP policy keys are set ───────────────────────────────────
$gpKeys = @(
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'; Name = 'DisableAntiSpyware'; Value = 1 },
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'; Name = 'DisableAntiVirus'; Value = 1 },
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'; Name = 'DisableRealtimeMonitoring'; Value = 1 },
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Scan'; Name = 'ScanAvgCPULoadFactor'; Value = 5 }
)

foreach ($gp in $gpKeys) {
    if (-not (Test-Path $gp.Path)) {
        New-Item -Path $gp.Path -Force | Out-Null
    }
    $current = (Get-ItemProperty $gp.Path -Name $gp.Name -ErrorAction SilentlyContinue).$($gp.Name)
    if ($null -ne $current -and [int]$current -eq $gp.Value) {
        Write-Host ($gp.Name + ': OK (' + $gp.Value + ')') -ForegroundColor Green
    } else {
        Set-ItemProperty $gp.Path -Name $gp.Name -Value $gp.Value -Type DWord
        $fromStr = if ($null -eq $current) { '<null>' } else { [string]$current }
        Write-Host ($gp.Name + ': ' + $fromStr + ' -> ' + $gp.Value) -ForegroundColor Cyan
    }
}

# ── Step 5: Final state report ──────────────────────────────────────────────
Write-Host ''
Write-Host '=== Final State ===' -ForegroundColor White
$status = Get-MpComputerStatus
Write-Host ('  RealTimeProtection:  ' + $status.RealTimeProtectionEnabled) -ForegroundColor White
Write-Host ('  AntivirusEnabled:    ' + $status.AntivirusEnabled) -ForegroundColor White
Write-Host ('  AntispywareEnabled:  ' + $status.AntispywareEnabled) -ForegroundColor White
Write-Host ('  TamperProtected:     ' + $status.IsTamperProtected) -ForegroundColor White
Write-Host ('  BehaviorMonitor:     ' + $status.BehaviorMonitorEnabled) -ForegroundColor White
Write-Host ('  AMRunningMode:       ' + $status.AMRunningMode) -ForegroundColor White

$winDefStart = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\WinDefend' -Name 'Start').Start
$wdNisStart  = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\WdNisSvc' -Name 'Start').Start
Write-Host ('  WinDefend Start:     ' + $winDefStart) -ForegroundColor White
Write-Host ('  WdNisSvc Start:      ' + $wdNisStart) -ForegroundColor White

$exCount = (Get-MpPreference).ExclusionPath.Count
Write-Host ('  Exclusion paths:     ' + $exCount) -ForegroundColor White
Write-Host ''

if ($winDefStart -ne 4) {
    Write-Host 'NOTE: WinDefend service registry key is ACL-protected by TrustedInstaller.' -ForegroundColor Yellow
    Write-Host 'Service will stop scanning (GP keys enforce that) but MsMpEng.exe still loads.' -ForegroundColor Yellow
    Write-Host 'To fully prevent loading, take ownership of the registry key or use PsExec -s.' -ForegroundColor Yellow
}

Write-Host 'Done. Reboot to apply service changes.' -ForegroundColor Green
