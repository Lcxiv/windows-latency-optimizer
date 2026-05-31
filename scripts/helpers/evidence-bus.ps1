#requires -Version 5.1
<#
.SYNOPSIS
  Evidence Bus producer/reader — the shared substrate for LatencyGuard's move
  to the installed-sentinel (B) product. See docs\spec-evidence-bus.md.

  One row = one typed observation from one instrument at one instant, appended
  to a daily JSONL file. Correlation becomes a query over this timeline instead
  of a human holding it in their head.

.NOTES
  - PS 5.1 compatible. Dot-source idempotency guard (CLAUDE.md #9).
  - Uses StreamWriter for the append hot-path (CLAUDE.md #8), not Add-Content.
  - evidence_kind has THREE states: observed | inferred | absent.
    'absent' is first-class — the 6-min logging silence before the 05-30 freeze
    was the single most diagnostic fact in the case.
#>

# Dot-source idempotency guard — check by FUNCTION name, not Test-Path.
if (Get-Command 'Write-EvidenceRow' -ErrorAction SilentlyContinue) { return }

# Anchor to repo root. This helper lives in scripts\helpers\, so root is TWO levels up.
# (Self-sufficient — does not depend on config.ps1 being dot-sourced first, since
#  evidence_correlate.ps1 sources this helper directly.)
$script:EvidenceRepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:EvidenceDir = Join-Path $script:EvidenceRepoRoot 'captures'
$script:EvidenceDir = Join-Path $script:EvidenceDir 'evidence'

function Get-EvidenceFile {
  <#
  .SYNOPSIS Resolve today's JSONL path (daily rotation). Creates the dir.
  .PARAMETER Date  Override date (yyyyMMdd) for testing. Default = now.
  #>
  param([string]$Date)
  if (-not (Test-Path $script:EvidenceDir)) {
    New-Item -ItemType Directory -Path $script:EvidenceDir -Force | Out-Null
  }
  if (-not $Date) { $Date = (Get-Date).ToString('yyyyMMdd') }
  return (Join-Path $script:EvidenceDir ('evidence_' + $Date + '.jsonl'))
}

function New-EvidenceRowId {
  # Stable-ish unique id without Math.random/Date.now ban concerns in PS.
  return ([Guid]::NewGuid().ToString('N').Substring(0, 12))
}

function Write-EvidenceRow {
  <#
  .SYNOPSIS  Append one typed evidence row to today's JSONL (append hot-path).
  .PARAMETER Source     instrument: eventlog|windbg|perfcounter|nvidia-smi|wpr|xperf|capframex|presentmon|wireshark|pktmon|procmon|hwinfo|pnputil|scewin|audit
  .PARAMETER Subsystem  cpu_dpc|gpu|storage|network|power|memory|display|input|firmware
  .PARAMETER Signal     controlled-vocabulary signal name (e.g. cpu0_dpc_pct)
  .PARAMETER Value      hashtable payload (signal-specific)
  .PARAMETER Severity   info|warn|error|critical
  .PARAMETER EvidenceKind observed|inferred|absent
  .PARAMETER Confidence 0.0-1.0 (1.0 = observed fact)
  .PARAMETER FaultingModule attribution when known
  .PARAMETER Cpu        per-CPU index (CPU 0 is the whole game)
  .PARAMETER RawRef     pointer to raw artifact
  .PARAMETER IncidentId groups rows into one incident
  .PARAMETER Links      array of row_ids this references (cross-month joins)
  .OUTPUTS  the row_id written
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ValidateSet('eventlog','windbg','perfcounter','nvidia-smi','wpr','xperf','capframex','presentmon','wireshark','pktmon','procmon','hwinfo','pnputil','scewin','audit')]
      [string]$Source,
    [Parameter(Mandatory)][ValidateSet('cpu_dpc','gpu','storage','network','power','memory','display','input','firmware')]
      [string]$Subsystem,
    [Parameter(Mandatory)][string]$Signal,
    [hashtable]$Value = @{},
    [ValidateSet('info','warn','error','critical')][string]$Severity = 'info',
    [ValidateSet('observed','inferred','absent')][string]$EvidenceKind = 'observed',
    [ValidateRange(0.0, 1.0)][double]$Confidence = 1.0,
    [string]$FaultingModule = $null,
    [Nullable[int]]$Cpu = $null,
    [string]$RawRef = $null,
    [string]$IncidentId = $null,
    [string[]]$Links = @(),
    [string]$Ts = $null
  )
  $rowId = New-EvidenceRowId
  if (-not $Ts) { $Ts = (Get-Date).ToUniversalTime().ToString('o') }
  $row = [ordered]@{
    row_id          = $rowId
    ts              = $Ts
    collected_ts    = (Get-Date).ToUniversalTime().ToString('o')
    source          = $Source
    subsystem       = $Subsystem
    signal          = $Signal
    severity        = $Severity
    value           = $Value
    faulting_module = $FaultingModule
    cpu             = $Cpu
    confidence      = $Confidence
    evidence_kind   = $EvidenceKind
    raw_ref         = $RawRef
    incident_id     = $IncidentId
    links           = $Links
  }
  $json = ($row | ConvertTo-Json -Depth 10 -Compress)
  $file = Get-EvidenceFile
  # StreamWriter append (hot-path) — not Add-Content (30x slower at scale).
  $sw = New-Object System.IO.StreamWriter($file, $true, (New-Object System.Text.UTF8Encoding($false)))
  try { $sw.WriteLine($json) } finally { $sw.Dispose() }
  return $rowId
}

function Read-EvidenceRows {
  <#
  .SYNOPSIS  Read evidence rows back as objects (for queries / correlator).
  .PARAMETER Date        yyyyMMdd to read (default today)
  .PARAMETER Signal      filter by signal
  .PARAMETER Subsystem   filter by subsystem
  .PARAMETER IncidentId  filter by incident
  #>
  param([string]$Date, [string]$Signal, [string]$Subsystem, [string]$IncidentId)
  $file = Get-EvidenceFile -Date $Date
  if (-not (Test-Path $file)) { return @() }
  $rows = foreach ($line in [IO.File]::ReadLines($file)) {
    if ($line.Trim()) { $line | ConvertFrom-Json }
  }
  if ($Signal)     { $rows = $rows | Where-Object { $_.signal -eq $Signal } }
  if ($Subsystem)  { $rows = $rows | Where-Object { $_.subsystem -eq $Subsystem } }
  if ($IncidentId) { $rows = $rows | Where-Object { $_.incident_id -eq $IncidentId } }
  return $rows
}
