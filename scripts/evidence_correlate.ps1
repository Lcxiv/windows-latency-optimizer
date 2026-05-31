#requires -Version 5.1
<#
.SYNOPSIS
  Correlator (query layer) over the evidence bus — proves the recurrence +
  misdirection queries from docs\evidence-bus-schema.md run on real rows.
  This is consumer-side: read-only over the JSONL timeline.
.PARAMETER Date  yyyyMMdd to query (default today)
.EXAMPLE
  .\scripts\evidence_correlate.ps1
#>
param([string]$Date)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\helpers\evidence-bus.ps1"

$rows = Read-EvidenceRows -Date $Date
Write-Host ("Evidence rows loaded: " + (@($rows).Count))
if (@($rows).Count -eq 0) { Write-Host "No rows. Run the flight recorder first."; return }

Write-Host ''
Write-Host '=== Recurrence: faulting_module across DPC-watchdog events ==='
$rows | Where-Object { $_.signal -match 'dpc_watchdog' -and $_.faulting_module } |
  Group-Object faulting_module |
  Sort-Object Count -Descending |
  ForEach-Object { "  {0,-14} x{1}" -f $_.Name, $_.Count }

Write-Host ''
Write-Host '=== Misdirection: perceived subsystem vs actual (misdiagnosis_correction) ==='
$rows | Where-Object { $_.signal -eq 'misdiagnosis_correction' } |
  ForEach-Object { "  felt={0} -> truth={1}  (conf {2})" -f $_.value.perceived, $_.value.actual, $_.confidence }

Write-Host ''
Write-Host '=== Signal histogram (vocabulary in use) ==='
$rows | Group-Object signal | Sort-Object Count -Descending |
  ForEach-Object { "  {0,-22} {1}" -f $_.Name, $_.Count }

Write-Host ''
Write-Host '=== Severity rollup ==='
$rows | Group-Object severity | Sort-Object Count -Descending |
  ForEach-Object { "  {0,-10} {1}" -f $_.Name, $_.Count }

Write-Host ''
Write-Host '=== CPU0 DPC events (the canonical hidden cause) ==='
$cpu0 = $rows | Where-Object { $_.subsystem -eq 'cpu_dpc' -and $_.cpu -eq 0 }
Write-Host ("  CPU0 cpu_dpc rows: " + (@($cpu0).Count))
