<#
.SYNOPSIS
    Lightweight experiment capture (perf counters + registry only, no WPR).
.DESCRIPTION
    Captures performance counters and registry snapshot without WPR/xperf traces.
    Faster than pipeline.ps1 for quick A/B comparisons.
    Uses shared functions from pipeline-helpers.ps1 (Get-RegistrySnapshot, Get-Stats,
    Invoke-PerfCounterCapture) to avoid code duplication.
.EXAMPLE
    .\run_experiment.ps1 -Label "QUICK_TEST" -Description "Quick idle check" -DurationSec 60
#>
#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$Label,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$Description,

    [ValidateRange(1, 3600)]
    [int]$DurationSec = 120,

    [string]$OutDir = ''
)

$ErrorActionPreference = "Stop"

# Load config and helpers
. "$PSScriptRoot\config.ps1"
$script:logLines = @()
. "$PSScriptRoot\pipeline-helpers.ps1"

# Resolve output directory from config if not specified
if ($OutDir -eq '') { $OutDir = $script:ExperimentsDir }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outFile   = Join-Path $OutDir ($timestamp + '_' + $Label + '.json')

Write-Host "=== run_experiment.ps1 ==="
Write-Host "Label:       $Label"
Write-Host "Description: $Description"
Write-Host ('Duration:    ' + $DurationSec + 's at 1s intervals')
Write-Host "Output:      $outFile"
Write-Host ""

# ---------------------------------------------------------------------------
# Prerequisites check
# ---------------------------------------------------------------------------
Test-SystemIdle | Out-Null

# ---------------------------------------------------------------------------
# Performance counter sampling (uses shared function)
# ---------------------------------------------------------------------------
$perfResult = Invoke-PerfCounterCapture -DurationSec $DurationSec

$cpuData       = $perfResult.cpuData
$cpuInterrupt  = $perfResult.cpuInterrupt
$cpuDpc        = $perfResult.cpuDpc
$cpuIntrPerSec = $perfResult.cpuIntrPerSec
$perf          = $perfResult.perf

# ---------------------------------------------------------------------------
# Registry state capture (uses shared function)
# ---------------------------------------------------------------------------
$reg = Get-RegistrySnapshot

# ---------------------------------------------------------------------------
# Assemble JSON
# ---------------------------------------------------------------------------
$totalIntr = $null; if ($cpuInterrupt.ContainsKey('_total')) { $totalIntr = $cpuInterrupt['_total'].avg }
$totalDpc  = $null; if ($cpuDpc.ContainsKey('_total'))       { $totalDpc  = $cpuDpc['_total'].avg }
$totalIps  = $null; if ($cpuIntrPerSec.ContainsKey('_total')){ $totalIps  = $cpuIntrPerSec['_total'].avg }

$result = [ordered]@{
    schemaVersion = 1
    label         = $Label
    description   = $Description
    capturedAt    = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    durationSec   = $DurationSec
    hostname      = $env:COMPUTERNAME
    registry      = $reg
    performance   = $perf
    cpuData       = $cpuData
    cpuTotal      = @{
        interruptPct = $totalIntr
        dpcPct       = $totalDpc
        intrPerSec   = $totalIps
    }
}

$json = $result | ConvertTo-Json -Depth 8
$json | Out-File $outFile -Encoding UTF8

Write-Host ""
Write-Host "=== Capture complete ==="
$cpu0Intr = ($cpuData | Where-Object { $_.cpu -eq 0 })
if ($cpu0Intr) { Write-Host ('  CPU 0 interrupt%: ' + $cpu0Intr.interruptPct) }
Write-Host ('  Total DPC%:       ' + $result.cpuTotal.dpcPct)
Write-Host ('  Total interrupt%: ' + $result.cpuTotal.interruptPct)
Write-Host ""
Write-Host "Saved: $outFile"
Write-Host ""
Write-Host "Next step: run .\scripts\generate_dashboard_data.ps1 to update the dashboard."
