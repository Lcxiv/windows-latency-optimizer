#requires -Version 5.1
<#
.SYNOPSIS
  Backfill DOCUMENTED historical incidents into the evidence bus.
  These are real, recorded incidents from project memory that predate the bus —
  not synthetic. Backfilling known history is a legitimate product function:
  the cross-time correlator is only useful if past incidents are on the timeline.

  Idempotent: tags every row with source incident_id; re-running overwrites the
  backfill file rather than duplicating (writes to a dedicated dated bucket).

.NOTES
  Sources: docs\boot-freeze-rca-findings.md, project memory 2026-04-23/05-11/05-20.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param()
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\helpers\evidence-bus.ps1"

# Write historical rows into a dedicated backfill-dated file so they don't mix
# with live daily capture but are still read by Read-EvidenceRows -Date.
$backfillDate = '20000101'   # sentinel "history" bucket
$file = Get-EvidenceFile -Date $backfillDate
if (Test-Path $file) { Remove-Item $file -Force }   # idempotent: rewrite clean

# Helper to force rows into the history bucket regardless of today's date.
function Write-HistRow {
  param([hashtable]$P)
  # temporarily point the module's file resolver at the history bucket by
  # passing an explicit Ts but writing via a local StreamWriter (same format).
  $row = [ordered]@{
    row_id = ([Guid]::NewGuid().ToString('N').Substring(0,12))
    ts = $P.Ts; collected_ts = $P.Ts
    source = $P.Source; subsystem = $P.Subsystem; signal = $P.Signal
    severity = $P.Severity; value = $P.Value
    faulting_module = $P.FaultingModule; cpu = $P.Cpu
    confidence = $P.Confidence; evidence_kind = $P.EvidenceKind
    raw_ref = $P.RawRef; incident_id = $P.IncidentId; links = $P.Links
  }
  $json = ($row | ConvertTo-Json -Depth 10 -Compress)
  $sw = New-Object System.IO.StreamWriter($file, $true, (New-Object System.Text.UTF8Encoding($false)))
  try { $sw.WriteLine($json) } finally { $sw.Dispose() }
  return $row.row_id
}

if (-not $PSCmdlet.ShouldProcess('evidence bus', 'backfill documented historical incidents')) { return }

# ── 2026-04-11 — WATCHDOG live-kernel dumps (nvlddmkm family) ──
Write-HistRow @{ Ts='2026-04-11T23:51:30Z'; Source='windbg'; Subsystem='gpu'; Signal='dpc_watchdog';
  Severity='critical'; EvidenceKind='observed'; Confidence=1.0; FaultingModule='nvlddmkm'; Cpu=$null;
  Value=@{ src='LiveKernelReports/WATCHDOG' }; RawRef='C:\Windows\LiveKernelReports\WATCHDOG'; IncidentId='INC-20260411-1651'; Links=@() } | Out-Null

# ── 2026-04-23 — mouse stutter = GPU saturation felt as input (misdirection) ──
$g1 = Write-HistRow @{ Ts='2026-04-23T23:09:00Z'; Source='audit'; Subsystem='input'; Signal='user_reported_symptom';
  Severity='warn'; EvidenceKind='observed'; Confidence=1.0; FaultingModule=$null; Cpu=$null;
  Value=@{ complaint='mouse stutter'; perceived_subsystem='input' }; RawRef=$null; IncidentId='INC-20260423-1609'; Links=@() }
Write-HistRow @{ Ts='2026-04-23T23:09:00Z'; Source='perfcounter'; Subsystem='cpu_dpc'; Signal='cpu0_dpc_pct';
  Severity='error'; EvidenceKind='observed'; Confidence=1.0; FaultingModule='nvlddmkm'; Cpu=0;
  Value=@{ pct=46.8; note='Remotion GPU saturation' }; RawRef=$null; IncidentId='INC-20260423-1609'; Links=@() } | Out-Null
Write-HistRow @{ Ts='2026-04-23T23:09:00Z'; Source='audit'; Subsystem='gpu'; Signal='misdiagnosis_correction';
  Severity='critical'; EvidenceKind='inferred'; Confidence=0.85; FaultingModule='nvlddmkm'; Cpu=$null;
  Value=@{ perceived='input'; actual='gpu' }; RawRef=$null; IncidentId='INC-20260423-1609'; Links=@($g1) } | Out-Null

# ── 2026-05-11 — 0x133 DPC_WATCHDOG, decoded dump (nvlddmkm) ──
Write-HistRow @{ Ts='2026-05-11T16:14:42Z'; Source='windbg'; Subsystem='gpu'; Signal='dpc_watchdog';
  Severity='critical'; EvidenceKind='observed'; Confidence=1.0; FaultingModule='nvlddmkm'; Cpu=$null;
  Value=@{ bugcheck='0x133'; bucket='0x133_DPC_nvlddmkm!unknown_function' };
  RawRef='captures/dump_0x133_051126_analyze.txt'; IncidentId='INC-20260511-0915'; Links=@() } | Out-Null

# ── 2026-05-20 — "network lag" = Hyper-V/VBS interrupt tax (cross-subsystem misdirection) ──
$n1 = Write-HistRow @{ Ts='2026-05-20T01:00:00Z'; Source='audit'; Subsystem='network'; Signal='user_reported_symptom';
  Severity='warn'; EvidenceKind='observed'; Confidence=1.0; FaultingModule=$null; Cpu=$null;
  Value=@{ complaint='network lag during FNCS'; perceived_subsystem='network' }; RawRef=$null; IncidentId='INC-20260519-1600'; Links=@() }
Write-HistRow @{ Ts='2026-05-20T01:00:00Z'; Source='perfcounter'; Subsystem='network'; Signal='ping_rtt';
  Severity='info'; EvidenceKind='observed'; Confidence=1.0; FaultingModule=$null; Cpu=$null;
  Value=@{ target='aws-us-east-1'; rtt_ms=68; jitter_ms=1; note='clean' }; RawRef=$null; IncidentId='INC-20260519-1600'; Links=@() } | Out-Null
Write-HistRow @{ Ts='2026-05-20T01:00:00Z'; Source='perfcounter'; Subsystem='cpu_dpc'; Signal='cpu0_dpc_pct';
  Severity='warn'; EvidenceKind='observed'; Confidence=1.0; FaultingModule=$null; Cpu=0;
  Value=@{ pct=4.5; baseline_pct=0.5 }; RawRef=$null; IncidentId='INC-20260519-1600'; Links=@() } | Out-Null
Write-HistRow @{ Ts='2026-05-20T01:00:00Z'; Source='audit'; Subsystem='cpu_dpc'; Signal='misdiagnosis_correction';
  Severity='critical'; EvidenceKind='inferred'; Confidence=0.85; FaultingModule=$null; Cpu=$null;
  Value=@{ perceived='network'; actual='cpu_dpc' }; RawRef=$null; IncidentId='INC-20260519-1600'; Links=@($n1) } | Out-Null

# ── 2026-05-30 — idle hard-hang, NO dump, inferred from sibling (absence + inference) ──
Write-HistRow @{ Ts='2026-05-30T17:14:06Z'; Source='eventlog'; Subsystem='power'; Signal='log_silence';
  Severity='critical'; EvidenceKind='absent'; Confidence=1.0; FaultingModule=$null; Cpu=$null;
  Value=@{ duration_s=349; note='scheduler stop' }; RawRef=$null; IncidentId='INC-20260530-1019'; Links=@() } | Out-Null
Write-HistRow @{ Ts='2026-05-30T17:19:55Z'; Source='eventlog'; Subsystem='power'; Signal='dirty_shutdown';
  Severity='critical'; EvidenceKind='observed'; Confidence=1.0; FaultingModule=$null; Cpu=$null;
  Value=@{ event_id=6008; kp41_bugcheck=0 }; RawRef=$null; IncidentId='INC-20260530-1019'; Links=@() } | Out-Null
Write-HistRow @{ Ts='2026-05-30T17:19:55Z'; Source='audit'; Subsystem='gpu'; Signal='dpc_watchdog_hang';
  Severity='critical'; EvidenceKind='inferred'; Confidence=0.7; FaultingModule='nvlddmkm'; Cpu=$null;
  Value=@{ attribution='by-association to 05-11 sibling' }; RawRef=$null; IncidentId='INC-20260530-1019'; Links=@() } | Out-Null

$n = @(Read-EvidenceRows -Date $backfillDate).Count
Write-Host ("Backfilled " + $n + " historical evidence rows into " + $file)
Write-Host "Run evidence_correlate.ps1 -Date 20000101 to fold history into the verdict view,"
Write-Host "or merge buckets in the correlator for a full cross-time picture."
