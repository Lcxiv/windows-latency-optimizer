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
param([string]$Date, [switch]$Today)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\helpers\evidence-bus.ps1"

# Default: full cross-time timeline (all buckets). -Today or -Date narrows it.
if ($Today -or $Date) {
  $rows = Read-EvidenceRows -Date $Date
} else {
  $rows = Read-AllEvidenceRows
}
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

# ── Emit verdict-UI data file (file:// compatible window.* object) ─────────────
# Powers monitor\views\verdict.js. No fetch — same pattern as snapshot.js.
$recurrence = @()
$rows | Where-Object { $_.signal -match 'dpc_watchdog' -and $_.faulting_module } |
  Group-Object faulting_module | Sort-Object Count -Descending |
  ForEach-Object { $recurrence += @{ module = $_.Name; count = $_.Count } }

$misdir = @()
$rows | Where-Object { $_.signal -eq 'misdiagnosis_correction' } |
  ForEach-Object { $misdir += @{ felt = $_.value.perceived; truth = $_.value.actual; confidence = $_.confidence } }

# Group rows into incidents (incident_id), newest first; rows within incident chronological.
$incidents = @()
$rows | Where-Object { $_.incident_id } | Group-Object incident_id |
  Sort-Object { ($_.Group | Sort-Object ts | Select-Object -First 1).ts } -Descending |
  ForEach-Object {
    $incRows = @()
    $_.Group | Sort-Object ts | ForEach-Object {
      $incRows += @{
        ts = $_.ts; signal = $_.signal; subsystem = $_.subsystem; cpu = $_.cpu
        faulting_module = $_.faulting_module; evidence_kind = $_.evidence_kind; severity = $_.severity
      }
    }
    $incidents += @{ id = $_.Name; rows = $incRows }
  }

$flatRows = @()
$rows | ForEach-Object {
  $flatRows += @{
    ts = $_.ts; signal = $_.signal; subsystem = $_.subsystem; cpu = $_.cpu
    faulting_module = $_.faulting_module; evidence_kind = $_.evidence_kind; severity = $_.severity
  }
}

$summary = @{
  generated   = (Get-Date).ToString('yyyy-MM-dd HH:mm')
  rows        = $flatRows
  recurrence  = $recurrence
  misdirection = $misdir
  incidents   = $incidents
}
$json = $summary | ConvertTo-Json -Depth 10 -Compress
$dataDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'monitor'
$dataDir = Join-Path $dataDir 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
$outFile = Join-Path $dataDir 'evidence_latest.js'
[IO.File]::WriteAllText($outFile, ('window.EVIDENCE_LATEST = ' + $json + ';'), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ''
Write-Host ("Verdict-UI data written: " + $outFile)
