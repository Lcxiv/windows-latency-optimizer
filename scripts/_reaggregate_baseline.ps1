# One-shot re-aggregation utility — re-parses xperf raw + rebuilds entry + MASTER.html
# from an existing baseline capture directory. Used to apply aggregator-layer bug fixes
# without recapturing the ~12 GB of raw data.
param(
    [Parameter(Mandatory=$true)]
    [string]$RunDir
)

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot
$projectRoot = Split-Path $scriptRoot -Parent

function Rebuild-XperfJson {
    param([string]$RawPath, [string]$JsonPath, [string]$Phase)

    if (-not (Test-Path $RawPath)) {
        Write-Warning ('Raw xperf file missing: ' + $RawPath)
        return
    }

    $topDrivers = @()
    $inTable = $false
    foreach ($ln in Get-Content $RawPath) {
        if ($ln -match 'CPU Usage Summing By Module') { $inTable = $true; continue }
        if ($inTable -and ($ln -match '^Total\s*=')) { $inTable = $false; continue }
        if (-not $inTable) { continue }
        if ($ln -match ',\s*([A-Za-z0-9_\-\.]+\.(sys|exe|dll))\s*$') {
            $drv = $Matches[1]
            $cpuMatches = [regex]::Matches($ln, '(\d+)\s+(\d+\.\d+),')
            $usecSum = 0
            $pctSum = 0.0
            foreach ($m in $cpuMatches) {
                $usecSum += [int64]$m.Groups[1].Value
                $pctSum += [double]$m.Groups[2].Value
            }
            $topDrivers += [PSCustomObject]@{ driver = $drv; total_usec = $usecSum; total_pct = [Math]::Round($pctSum, 3) }
        }
    }
    @{
        phase = $Phase
        top_drivers = @($topDrivers | Sort-Object -Property total_usec -Descending | Select-Object -First 15)
        total_dpcs = $null
        total_isrs = $null
        parse_source = 'CPU Usage Summing By Module'
    } | ConvertTo-Json -Depth 10 | Set-Content -Path $JsonPath -Encoding UTF8
    Write-Output ('xperf re-parsed: ' + $JsonPath + ' (' + $topDrivers.Count + ' modules)')
}

# 1. Re-parse xperf raw -> JSON for both phases
$idleXperfRaw = Join-Path $RunDir '20_idle\xperf_idle_raw.txt'
$idleXperfJson = Join-Path $RunDir '20_idle\xperf_idle.json'
$loadedXperfRaw = Join-Path $RunDir '30_loaded\xperf_loaded_raw.txt'
$loadedXperfJson = Join-Path $RunDir '30_loaded\xperf_loaded.json'

Rebuild-XperfJson -RawPath $idleXperfRaw -JsonPath $idleXperfJson -Phase 'idle'
Rebuild-XperfJson -RawPath $loadedXperfRaw -JsonPath $loadedXperfJson -Phase 'loaded'

# 2. Recompute delta
$deltaPath = Join-Path $RunDir '40_aggregate\delta_idle_vs_loaded.json'
$idlePerfPath = Join-Path $RunDir '20_idle\pipeline_idle.json'
$loadedPerfPath = Join-Path $RunDir '30_loaded\pipeline_loaded.json'
$idlePerf = Get-Content $idlePerfPath -Raw | ConvertFrom-Json
$loadedPerf = Get-Content $loadedPerfPath -Raw | ConvertFrom-Json

$delta = @{}
if ($idlePerf.performance -and $loadedPerf.performance) {
    $dpcIdleVal = $idlePerf.performance.'% dpc time[_total]'
    $dpcLoadedVal = $loadedPerf.performance.'% dpc time[_total]'
    if ($dpcIdleVal -and $dpcLoadedVal) {
        $delta['dpc_pct'] = @{
            idle = $dpcIdleVal.avg
            loaded = $dpcLoadedVal.avg
            delta = [Math]::Round(($dpcLoadedVal.avg - $dpcIdleVal.avg), 3)
        }
    }
    $intIdleVal = $idlePerf.performance.'% interrupt time[_total]'
    $intLoadedVal = $loadedPerf.performance.'% interrupt time[_total]'
    if ($intIdleVal -and $intLoadedVal) {
        $delta['interrupt_pct'] = @{
            idle = $intIdleVal.avg
            loaded = $intLoadedVal.avg
            delta = [Math]::Round(($intLoadedVal.avg - $intIdleVal.avg), 3)
        }
    }
    $ipsIdleVal = $idlePerf.performance.'interrupts/sec[_total]'
    $ipsLoadedVal = $loadedPerf.performance.'interrupts/sec[_total]'
    if ($ipsIdleVal -and $ipsLoadedVal) {
        $delta['interrupts_per_sec'] = @{
            idle = $ipsIdleVal.avg
            loaded = $ipsLoadedVal.avg
            delta = [Math]::Round(($ipsLoadedVal.avg - $ipsIdleVal.avg), 1)
        }
    }
}
$delta | ConvertTo-Json -Depth 10 | Set-Content -Path $deltaPath -Encoding UTF8
Write-Output ('Delta rebuilt: ' + $deltaPath)

# 3. Re-run aggregator for dashboard entry
$entryPath = Join-Path $RunDir '40_aggregate\experiment_entry.json'
$label = 'BASELINE_POST_REBOOT_CLEAN'
& (Join-Path $scriptRoot 'aggregate_baseline_to_dashboard_entry.ps1') -InputDir $RunDir -OutputPath $entryPath -Label $label

# Also copy into captures/experiments/ for dashboard regen
$expDir = Join-Path $projectRoot ('captures\experiments\' + (Split-Path $RunDir -Leaf))
if (-not (Test-Path $expDir)) { New-Item -ItemType Directory -Path $expDir -Force | Out-Null }
Copy-Item -Path $entryPath -Destination (Join-Path $expDir 'experiment.json') -Force

# 4. Rebuild MASTER.html
$masterPath = Join-Path $RunDir 'MASTER.html'
& (Join-Path $scriptRoot 'build_master_report.ps1') -InputDir $RunDir -OutputPath $masterPath

# 5. Regen dashboard data
& (Join-Path $scriptRoot 'generate_dashboard_data.ps1')

Write-Output ''
Write-Output '==================================================='
Write-Output 'Re-aggregation complete.'
Write-Output ('MASTER:  ' + $masterPath)
Write-Output ('Entry:   ' + $entryPath)
Write-Output ('Delta:   ' + $deltaPath)
Write-Output '==================================================='
