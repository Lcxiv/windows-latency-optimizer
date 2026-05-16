<#
.SYNOPSIS
    Phase 2 rollback: remove Defender exclusions added by eac_phase2_defender_apply.ps1.
.DESCRIPTION
    Reads apply manifest JSON, removes only the items that apply added (skipped items
    untouched). Triggers Defender QuickScan after rollback. If user reports suspected
    compromise, run Start-MpScan -ScanType FullScan separately.

    Pair with: eac_phase2_defender_apply.ps1

.PARAMETER ManifestFile
    Path to apply_manifest_<timestamp>.json from the apply step.

.PARAMETER SkipScan
    Skip the post-rollback QuickScan (not recommended).

.EXAMPLE
    .\eac_phase2_defender_rollback.ps1 -ManifestFile "captures\backups\defender\apply_manifest_20260507_120000.json"
#>
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$ManifestFile,

    [switch]$SkipScan
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ManifestFile)) {
    Write-Error ('Manifest not found: ' + $ManifestFile)
    exit 1
}

Write-Host '=== Phase 2: Defender Exclusion Rollback ===' -ForegroundColor Cyan
$manifest = Get-Content $ManifestFile -Raw | ConvertFrom-Json

$removed = [ordered]@{
    processes  = @()
    paths      = @()
    extensions = @()
}

foreach ($p in $manifest.added.processes) {
    if ($PSCmdlet.ShouldProcess($p, 'Remove-MpPreference -ExclusionProcess')) {
        try {
            Remove-MpPreference -ExclusionProcess $p
            $removed.processes += $p
            Write-Host ('REMOVED process: ' + $p) -ForegroundColor Yellow
        } catch {
            Write-Warning ('Failed to remove process ' + $p + ': ' + $_.Exception.Message)
        }
    }
}

foreach ($p in $manifest.added.paths) {
    if ($PSCmdlet.ShouldProcess($p, 'Remove-MpPreference -ExclusionPath')) {
        try {
            Remove-MpPreference -ExclusionPath $p
            $removed.paths += $p
            Write-Host ('REMOVED path: ' + $p) -ForegroundColor Yellow
        } catch {
            Write-Warning ('Failed to remove path ' + $p + ': ' + $_.Exception.Message)
        }
    }
}

foreach ($e in $manifest.added.extensions) {
    if ($PSCmdlet.ShouldProcess($e, 'Remove-MpPreference -ExclusionExtension')) {
        try {
            Remove-MpPreference -ExclusionExtension $e
            $removed.extensions += $e
            Write-Host ('REMOVED ext: ' + $e) -ForegroundColor Yellow
        } catch {
            Write-Warning ('Failed to remove ext ' + $e + ': ' + $_.Exception.Message)
        }
    }
}

# ---- Post-rollback QuickScan ----
if (-not $SkipScan) {
    Write-Host ''
    Write-Host 'Starting Defender QuickScan...' -ForegroundColor Cyan
    Start-MpScan -ScanType QuickScan -AsJob | Out-Null
    Write-Host '(QuickScan running in background — check Get-MpComputerStatus for progress)'
}

# ---- Rollback receipt ----
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$receiptFile = Join-Path (Split-Path $ManifestFile -Parent) ('rollback_receipt_' + $timestamp + '.json')
$receipt = [ordered]@{
    rolledBackAt    = $timestamp
    sourceManifest  = $ManifestFile
    removed         = $removed
    quickScanStarted = (-not $SkipScan)
}
$receipt | ConvertTo-Json -Depth 5 | Out-File -FilePath $receiptFile -Encoding utf8

Write-Host ''
Write-Host '=== Rollback Complete ===' -ForegroundColor Green
Write-Host ('Receipt: ' + $receiptFile)
Write-Host ''
Write-Host 'If you suspect compromise of excluded paths:'
Write-Host '  Start-MpScan -ScanType FullScan'
