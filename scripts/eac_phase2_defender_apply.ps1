<#
.SYNOPSIS
    Phase 2: Apply Defender exclusions for Fortnite + EAC paths to stop double-scan.
.DESCRIPTION
    Adds process, path, and extension exclusions so Defender does not race EAC's
    minifilter on game files. Backs up current MpPreference state to JSON before
    applying. Idempotent — re-running is no-op for already-excluded items.

    SECURITY TRADE-OFF: excluded paths receive no Defender real-time scanning.
    EAC still scans those paths. Net result = single scan instead of double scan.

    Pair with: eac_phase2_defender_rollback.ps1

.PARAMETER WhatIf
    Show what would be added; make no changes.

.EXAMPLE
    .\eac_phase2_defender_apply.ps1 -WhatIf
    .\eac_phase2_defender_apply.ps1
#>
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess=$true)]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$backupDir = Join-Path $repoRoot 'captures\backups\defender'
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupFile = Join-Path $backupDir ('mppref_' + $timestamp + '.json')

# ---- Backup current state ----
Write-Host '=== Phase 2: Defender Exclusion Apply ===' -ForegroundColor Cyan
Write-Host ('Backup: ' + $backupFile)
$pre = Get-MpPreference
$preSnapshot = [ordered]@{
    timestamp         = $timestamp
    ExclusionProcess  = $pre.ExclusionProcess
    ExclusionPath     = $pre.ExclusionPath
    ExclusionExtension = $pre.ExclusionExtension
}
$preSnapshot | ConvertTo-Json -Depth 4 | Out-File -FilePath $backupFile -Encoding utf8

# ---- Targets ----
$processes = @(
    'FortniteClient-Win64-Shipping.exe',
    'FortniteClient-Win64-Shipping_EAC_EOS.exe',
    'FortniteLauncher.exe',
    'EasyAntiCheat_EOS.exe',
    'EpicGamesLauncher.exe',
    'EpicWebHelper.exe'
)

$paths = @(
    'C:\Program Files\Epic Games\Fortnite',
    'C:\Program Files (x86)\EasyAntiCheat_EOS',
    (Join-Path $env:LOCALAPPDATA 'FortniteGame'),
    (Join-Path $env:LOCALAPPDATA 'EasyAntiCheat_EOS')
)

$extensions = @('.pak', '.utoc', '.ucas', '.sig')

# ---- Apply ----
$preProcess = @($pre.ExclusionProcess)
$prePath    = @($pre.ExclusionPath)
$preExt     = @($pre.ExclusionExtension)

$added = [ordered]@{
    processes  = @()
    paths      = @()
    extensions = @()
}
$skipped = [ordered]@{
    processes  = @()
    paths      = @()
    extensions = @()
}

foreach ($p in $processes) {
    if ($preProcess -contains $p) {
        $skipped.processes += $p
        Write-Host ('SKIP (already): ' + $p) -ForegroundColor DarkGray
        continue
    }
    if ($PSCmdlet.ShouldProcess($p, 'Add-MpPreference -ExclusionProcess')) {
        Add-MpPreference -ExclusionProcess $p
        $added.processes += $p
        Write-Host ('ADD process: ' + $p) -ForegroundColor Green
    }
}

foreach ($p in $paths) {
    if ($prePath -contains $p) {
        $skipped.paths += $p
        Write-Host ('SKIP (already): ' + $p) -ForegroundColor DarkGray
        continue
    }
    if ($PSCmdlet.ShouldProcess($p, 'Add-MpPreference -ExclusionPath')) {
        Add-MpPreference -ExclusionPath $p
        $added.paths += $p
        Write-Host ('ADD path: ' + $p) -ForegroundColor Green
    }
}

foreach ($e in $extensions) {
    if ($preExt -contains $e) {
        $skipped.extensions += $e
        Write-Host ('SKIP (already): ' + $e) -ForegroundColor DarkGray
        continue
    }
    if ($PSCmdlet.ShouldProcess($e, 'Add-MpPreference -ExclusionExtension')) {
        Add-MpPreference -ExclusionExtension $e
        $added.extensions += $e
        Write-Host ('ADD ext: ' + $e) -ForegroundColor Green
    }
}

# ---- Persist apply manifest (for rollback) ----
$manifest = [ordered]@{
    appliedAt   = $timestamp
    backupFile  = $backupFile
    added       = $added
    skipped     = $skipped
}
$manifestFile = Join-Path $backupDir ('apply_manifest_' + $timestamp + '.json')
$manifest | ConvertTo-Json -Depth 5 | Out-File -FilePath $manifestFile -Encoding utf8

Write-Host ''
Write-Host '=== Apply Complete ===' -ForegroundColor Green
Write-Host ('Manifest: ' + $manifestFile)
Write-Host ''
Write-Host 'Verify:'
Write-Host '  Get-MpPreference | Select Exclusion*'
Write-Host ''
Write-Host 'Rollback:'
Write-Host ('  .\scripts\eac_phase2_defender_rollback.ps1 -ManifestFile "' + $manifestFile + '"')
