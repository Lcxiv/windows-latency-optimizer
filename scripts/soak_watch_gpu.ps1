<#
.SYNOPSIS
  GPU fix soak-watch. Scans all GPU/display/power fault classes since the
  post-DDU reinstall marker and tracks consecutive clean days. When N days
  elapse with zero faults, the nvlddmkm DPC-watchdog fix (INC-20260530-1800)
  is durably confirmed. READ-ONLY scan; writes only a status JSON (+ an
  evidence row IF a fault is found).
.DESCRIPTION
  Reuses Invoke-CollectDisplayEvents (4101 TDR / 4097-117 reset / 41 power /
  DWM crash) and adds BugCheck 1001 + WHEA. Designed to run after each gaming
  session or on a daily schedule. Exit 0 = clean, 1 = fault detected.
.PARAMETER SoakStartUtc
  Start of the soak window — the moment the healthy 610.47 driver came up.
.PARAMETER TargetDays
  Consecutive clean days required to declare the fix durably confirmed.
.NOTES
  PowerShell 5.1, UTF-8 + BOM. [non-admin] — event-log reads need no elevation.
#>
[CmdletBinding()]
param(
    [datetime] $SoakStartUtc = (Get-Date '2026-06-03T20:00:00Z'),
    [int]      $TargetDays   = 7,
    [string]   $StatusFile   = 'captures\soak_watch_gpu.json',
    [switch]   $Quiet
)

$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

# Reuse the canonical display-event scanner + the evidence appender.
. (Join-Path $PSScriptRoot 'collect_display_events.ps1')
. (Join-Path $PSScriptRoot 'append_incident_evidence.ps1')

$nowUtc = (Get-Date).ToUniversalTime()

# 1. Core display/power fault classes (reused scanner), soak-start -> now.
$scan = Invoke-CollectDisplayEvents -StartUtc $SoakStartUtc -EndUtc $nowUtc `
    -OutFile 'captures\soak_display_events.json'

# 2. BugCheck (1001) + WHEA — same window, same shape.
$startLocal = $SoakStartUtc.ToLocalTime()
$bugcheck = @(Get-WinEvent -FilterHashtable @{ LogName='System'; Id=1001; StartTime=$startLocal } -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -match 'BugCheck' }).Count
$whea = @(Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=$startLocal } -ErrorAction SilentlyContinue).Count

$totalFaults = [int]$scan.tdr_4101 + [int]$scan.display_reset + [int]$scan.kernel_power_41 + [int]$scan.dwm_crash + [int]$bugcheck + [int]$whea

$daysElapsed = [math]::Round(($nowUtc - $SoakStartUtc).TotalDays, 2)
$verdict = if ($totalFaults -gt 0) { 'SOAK_FAULT_DETECTED' }
           elseif ($daysElapsed -ge $TargetDays) { 'FIX_DURABLY_CONFIRMED' }
           else { 'SOAK_CLEAN_IN_PROGRESS' }

$status = [ordered]@{
    incident_id    = 'INC-20260530-1800'
    soak_start_utc = $SoakStartUtc.ToString('o')
    last_check_utc = $nowUtc.ToString('o')
    days_elapsed   = $daysElapsed
    target_days    = $TargetDays
    total_faults   = $totalFaults
    breakdown      = [ordered]@{
        tdr_4101        = [int]$scan.tdr_4101
        display_reset   = [int]$scan.display_reset
        kernel_power_41 = [int]$scan.kernel_power_41
        dwm_crash       = [int]$scan.dwm_crash
        bugcheck_1001   = [int]$bugcheck
        whea            = [int]$whea
    }
    verdict        = $verdict
}

$dir = Split-Path $StatusFile -Parent
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$status | ConvertTo-Json -Depth 5 | Set-Content $StatusFile -Encoding UTF8

# 3. On fault: log an evidence row so the verdict UI surfaces the regression.
if ($totalFaults -gt 0) {
    $jsonl = 'captures\evidence\evidence_' + (Get-Date).ToString('yyyyMMdd') + '.jsonl'
    Add-IncidentEvidence -Signal 'tdr' -Verdict 'SOAK_FAULT_DETECTED' -Jsonl $jsonl `
        -IncidentId 'INC-20260530-1800' -Ts ($nowUtc.ToLocalTime().ToString('yyyy-MM-ddTHH:mm:ss.0000000zzz')) `
        -Source 'winevent' -Subsystem 'gpu' -Severity 'critical' -FaultingModule 'nvlddmkm' `
        -EvidenceKind 'observed' -Value @{ note='soak-watch caught a new GPU fault after reinstall'; days_into_soak=$daysElapsed; breakdown=$status.breakdown } | Out-Null
}

if (-not $Quiet) {
    Write-Host ''
    Write-Host ('=== GPU soak-watch  (' + $daysElapsed + ' / ' + $TargetDays + ' days) ===')
    Write-Host ('  TDR 4101        : ' + $status.breakdown.tdr_4101)
    Write-Host ('  display reset   : ' + $status.breakdown.display_reset)
    Write-Host ('  Kernel-Power 41 : ' + $status.breakdown.kernel_power_41)
    Write-Host ('  DWM crash       : ' + $status.breakdown.dwm_crash)
    Write-Host ('  BugCheck 1001   : ' + $status.breakdown.bugcheck_1001)
    Write-Host ('  WHEA            : ' + $status.breakdown.whea)
    Write-Host ('  VERDICT         : ' + $verdict)
    Write-Host ('  status -> ' + $StatusFile)
}

if ($totalFaults -gt 0) { exit 1 } else { exit 0 }
