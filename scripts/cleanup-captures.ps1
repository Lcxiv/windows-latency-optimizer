<#
.SYNOPSIS
    Archive or compress old experiment capture data.
.DESCRIPTION
    Finds experiment directories older than the specified number of days,
    compresses large ETL trace files, and reports disk savings.
    Does NOT delete any data by default - use -RemoveOldEtl to delete
    compressed originals.
.EXAMPLE
    .\cleanup-captures.ps1
    .\cleanup-captures.ps1 -DaysOld 14 -WhatIf
    .\cleanup-captures.ps1 -DaysOld 30 -RemoveOldEtl
#>
param(
    [ValidateRange(1, 365)]
    [int]$DaysOld = 30,

    [switch]$RemoveOldEtl,

    [switch]$WhatIf
)

. "$PSScriptRoot\config.ps1"

$cutoff = (Get-Date).AddDays(-$DaysOld)

Write-Host "=== cleanup-captures.ps1 ==="
Write-Host "Cutoff:  $($cutoff.ToString('yyyy-MM-dd')) ($DaysOld days ago)"
Write-Host "Source:  $($script:ExperimentsDir)"
Write-Host "WhatIf:  $WhatIf"
Write-Host ""

if (-not (Test-Path $script:ExperimentsDir)) {
    Write-Host "No experiments directory found."
    exit 0
}

$dirs = Get-ChildItem $script:ExperimentsDir -Directory -ErrorAction SilentlyContinue
$totalSaved = 0
$etlCount = 0
$compressedCount = 0

foreach ($dir in $dirs) {
    if ($dir.CreationTime -gt $cutoff) { continue }

    # Find ETL files (largest capture artifacts, typically 1-4 GB each)
    $etlFiles = Get-ChildItem $dir.FullName -Filter '*.etl' -File -ErrorAction SilentlyContinue
    foreach ($etl in $etlFiles) {
        $etlCount++
        $zipPath = $etl.FullName + '.zip'

        if (Test-Path $zipPath) {
            Write-Host "  SKIP (already compressed): $($etl.Name) in $($dir.Name)"
            continue
        }

        $sizeMB = [math]::Round($etl.Length / 1MB, 1)
        Write-Host "  COMPRESS: $($dir.Name)\$($etl.Name) ($($sizeMB) MB)"

        if (-not $WhatIf) {
            try {
                Compress-Archive -Path $etl.FullName -DestinationPath $zipPath -CompressionLevel Optimal
                $zipSize = (Get-Item $zipPath).Length
                $saved = $etl.Length - $zipSize
                $totalSaved += $saved
                $compressedCount++
                Write-Host "    Saved: $([math]::Round($saved / 1MB, 1)) MB ($([math]::Round($zipSize / 1MB, 1)) MB compressed)"

                if ($RemoveOldEtl) {
                    Remove-Item $etl.FullName -Force
                    Write-Host "    Removed original ETL"
                }
            } catch {
                Write-Warning "Failed to compress $($etl.FullName): $($_.Exception.Message)"
            }
        }
    }

    # Report PML files (ProcMon captures, also large)
    $pmlFiles = Get-ChildItem $dir.FullName -Filter '*.pml' -File -ErrorAction SilentlyContinue
    foreach ($pml in $pmlFiles) {
        $sizeMB = [math]::Round($pml.Length / 1MB, 1)
        if ($sizeMB -gt 10) {
            Write-Host "  NOTE: Large PML file: $($dir.Name)\$($pml.Name) ($($sizeMB) MB)"
        }
    }
}

Write-Host ""
Write-Host "=== Summary ==="
Write-Host "ETL files found: $etlCount"
Write-Host "Compressed:      $compressedCount"
Write-Host "Space saved:     $([math]::Round($totalSaved / 1MB, 1)) MB"
if ($WhatIf) { Write-Host "(WhatIf mode - no changes made)" }
