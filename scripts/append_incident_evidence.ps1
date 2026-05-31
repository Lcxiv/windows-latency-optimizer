<#
.SYNOPSIS
  Phase 4 — Idempotent append of one incident row to the evidence-bus jsonl.
  Skips if a row with the same incident_id AND signal already exists (DATA check).
.NOTES
  PowerShell 5.1, UTF-8 + BOM. [non-admin].
  Row schema matches existing bus rows (see captures/evidence/evidence_20260530.jsonl);
  adds value.verdict so the per-hypothesis result is queryable by the verdict UI.
#>
if (Get-Command 'Add-IncidentEvidence' -ErrorAction SilentlyContinue) { return }

function Add-IncidentEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Signal,        # tdr | display_reset | dwm_crash | driver_change | regression | near_miss
        [Parameter(Mandatory)] [string] $Verdict,       # e.g. TDR_CONFIRMED / LINK_ELIMINATED
        [string] $Jsonl = 'captures\evidence\evidence_20260530.jsonl',
        [string] $IncidentId = 'INC-20260530-1800',
        [string] $Ts = '2026-05-30T18:00:00.0000000-07:00',
        [string] $Source = 'winevent',                  # windbg | winevent
        [string] $Subsystem = 'gpu',                    # gpu | display
        [string] $Severity = 'critical',                # critical | warn | info
        [hashtable] $Value = @{},
        [string] $FaultingModule = '',
        [string] $EvidenceKind = 'observed',            # observed | absent
        [string] $RawRef = '',
        [string[]] $Links = @()
    )

    # Idempotency: DATA check on incident_id + signal (NOT a Get-Command guard).
    $existing = @(Get-Content $Jsonl -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch { $null }
    } | Where-Object { $_ -ne $null })
    $dup = $existing | Where-Object { $_.incident_id -eq $IncidentId -and $_.signal -eq $Signal }
    if (@($dup).Count -gt 0) {
        Write-Host ('Row already present (incident_id=' + $IncidentId + ', signal=' + $Signal + '), skipping')
        return $null
    }

    # row_id: 12-hex (PS 5.1 safe).
    $rowId = '{0:x12}' -f (Get-Random -Minimum 0 -Maximum 0xFFFFFFFFFFFF)

    $val = @{} + $Value
    $val['verdict'] = $Verdict

    $row = [ordered]@{
        row_id          = $rowId
        ts              = $Ts
        collected_ts    = (Get-Date).ToUniversalTime().ToString('o')
        source          = $Source
        subsystem       = $Subsystem
        signal          = $Signal
        severity        = $Severity
        value           = $val
        faulting_module = $FaultingModule
        cpu             = $null
        confidence      = 1
        evidence_kind   = $EvidenceKind
        raw_ref         = $RawRef
        incident_id     = $IncidentId
        links           = $Links
    }

    $dir = Split-Path $Jsonl -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $line = ($row | ConvertTo-Json -Depth 6 -Compress)
    Add-Content -Path $Jsonl -Value $line -Encoding UTF8
    Write-Host ('Appended row ' + $rowId + ' signal=' + $Signal + ' verdict=' + $Verdict)
    $row
}

# No auto-run: callers supply -Signal/-Verdict explicitly per hypothesis.
