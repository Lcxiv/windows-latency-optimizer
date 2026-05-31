#requires -Version 5.1
<#
.SYNOPSIS
  Flight-recorder adapter — converts a monitor_collector counter sample into
  typed evidence-bus rows. Additive: the dashboard snapshot.js path is untouched.
  See docs\spec-evidence-bus.md step 2.
#>
if (Get-Command 'Add-CounterEvidence' -ErrorAction SilentlyContinue) { return }
. "$PSScriptRoot\evidence-bus.ps1"

function Add-CounterEvidence {
  <#
  .SYNOPSIS  Emit evidence rows from one Get-MonitorCounterSample result.
             Records per-CPU DPC (CPU 0 first-class), total DPC, and — when a
             cycle produces NO spike — an 'absent' baseline marker so quiet
             periods are still on the timeline (absence is evidence).
  .PARAMETER CounterData  the hashtable from Get-MonitorCounterSample
  .PARAMETER NetworkData  optional network sample (for verdict rows)
  .OUTPUTS  count of rows written
  #>
  param([hashtable]$CounterData, $NetworkData = $null)
  if ($null -eq $CounterData) { return 0 }
  $n = 0
  $ts = $CounterData.timestamp

  # --- total DPC (warn if elevated) ---
  $dpc = [double]$CounterData.system.dpcPct
  $sev = 'info'; if ($dpc -ge 5) { $sev = 'warn' }; if ($dpc -ge 10) { $sev = 'error' }
  Write-EvidenceRow -Source perfcounter -Subsystem cpu_dpc -Signal 'total_dpc_pct' `
    -Value @{ pct = [math]::Round($dpc, 2) } -Severity $sev -Ts $ts | Out-Null
  $n++

  # --- per-CPU DPC for any flagged high-DPC CPU (CPU 0 is the whole game) ---
  $highCpus = @()
  if ($CounterData.spikes -and $CounterData.spikes.highDpcCpus) {
    $highCpus = @($CounterData.spikes.highDpcCpus)
  }
  foreach ($c in $highCpus) {
    $rowSev = 'warn'; if ([int]$c -eq 0) { $rowSev = 'error' }  # CPU0 saturation = the canonical hidden cause
    Write-EvidenceRow -Source perfcounter -Subsystem cpu_dpc -Signal 'cpu_dpc_high' `
      -Value @{ note = 'per-CPU DPC spike (not _Total)' } -Cpu ([int]$c) -Severity $rowSev -Ts $ts | Out-Null
    $n++
  }

  # --- network verdict (cross-subsystem: a network row that may later be overturned by a cpu_dpc cause) ---
  if ($null -ne $NetworkData -and $NetworkData.verdict) {
    $nsev = 'info'; if ($NetworkData.verdict -ne 'ok' -and $NetworkData.verdict) { $nsev = 'warn' }
    Write-EvidenceRow -Source perfcounter -Subsystem network -Signal 'network_verdict' `
      -Value @{ verdict = $NetworkData.verdict } -Severity $nsev -Ts $ts | Out-Null
    $n++
  }

  # --- absence-as-evidence: a fully quiet cycle is still a recorded fact ---
  $anySpike = $false
  if ($CounterData.spikes) {
    if ($CounterData.spikes.totalDpcSpike -or $CounterData.spikes.totalInterruptSpike -or
        $CounterData.spikes.contextSwitchSpike -or $highCpus.Count -gt 0) { $anySpike = $true }
  }
  if (-not $anySpike) {
    Write-EvidenceRow -Source perfcounter -Subsystem cpu_dpc -Signal 'baseline_quiet' `
      -Value @{ dpc_pct = [math]::Round($dpc, 2) } -EvidenceKind 'absent' -Severity 'info' -Ts $ts | Out-Null
    $n++
  }
  return $n
}
