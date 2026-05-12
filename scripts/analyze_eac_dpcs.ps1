<#
.SYNOPSIS
    Parse xperf DPC/ISR summary, compute EAC contribution metrics for Phase 0 gate.
.DESCRIPTION
    Reads xperf_dpc_summary.csv from a capture directory. Computes:
      - Total DPC time per driver
      - EAC's share (eac_dpc_pct + eac_dpc_total_ms)
      - Top-10 DPC drivers by total time
      - Per-CPU DPC distribution from percpu_counters.csv

    Output: eac_analysis.json + eac_analysis.txt (human-readable).

.PARAMETER CaptureDir
    Path to exp-eac-baseline-fortnite-* directory.

.EXAMPLE
    .\analyze_eac_dpcs.ps1 -CaptureDir "captures\experiments\exp-eac-baseline-fortnite-pre-exclusion_20260507_113000"
#>
param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$CaptureDir
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $CaptureDir)) {
    Write-Error ('Capture directory not found: ' + $CaptureDir)
    exit 1
}

$xperfCsv = Join-Path $CaptureDir 'xperf_dpc_summary.csv'
$percpuCsv = Join-Path $CaptureDir 'percpu_counters.csv'
$metaJson = Join-Path $CaptureDir 'run_meta.json'

if (-not (Test-Path $xperfCsv)) {
    Write-Error ('xperf summary missing: ' + $xperfCsv)
    exit 1
}

Write-Host '=== EAC DPC Analysis ===' -ForegroundColor Cyan
Write-Host ('Capture: ' + $CaptureDir)
Write-Host ''

# ---- Parse xperf DPC summary ----
# xperf -a dpcisr CSV format: Type, Module, Function, Count, ElapsedTime(us), AvgTime(us), MaxTime(us), CPU
# Column layout varies — auto-detect headers

$rawLines = Get-Content $xperfCsv
$headerIdx = -1
for ($i = 0; $i -lt $rawLines.Count; $i++) {
    if ($rawLines[$i] -match 'DPC' -and $rawLines[$i] -match 'Module') {
        $headerIdx = $i
        break
    }
}

if ($headerIdx -eq -1) {
    Write-Warning 'xperf summary has unexpected format. Falling back to raw extraction.'
    $rawDump = Get-Content $xperfCsv | Select-Object -First 200
    $rawDump | Out-File -FilePath (Join-Path $CaptureDir 'xperf_raw_dump.txt') -Encoding utf8
    $eacDpcTotalUs = 0
    $totalDpcUs = 1
} else {
    $dpcRows = $rawLines | Select-Object -Skip ($headerIdx + 1) | ConvertFrom-Csv -Header (($rawLines[$headerIdx]) -split ',')
    # Try common column names
    $moduleCol = $null
    $elapsedCol = $null
    foreach ($cn in @('Module', 'Image', 'Driver', ' Module', 'ModuleName')) {
        if ($dpcRows[0].PSObject.Properties.Name -contains $cn) { $moduleCol = $cn; break }
    }
    foreach ($cn in @('ElapsedTime(us)', 'TotalTime(us)', ' ElapsedTime(us)', 'Elapsed(us)', 'Time(us)')) {
        if ($dpcRows[0].PSObject.Properties.Name -contains $cn) { $elapsedCol = $cn; break }
    }

    if (-not $moduleCol -or -not $elapsedCol) {
        Write-Warning 'Could not auto-detect xperf CSV columns. Run xperf manually for inspection.'
        $eacDpcTotalUs = 0
        $totalDpcUs = 1
    } else {
        # Sum total + EAC
        $totalDpcUs = 0
        $eacDpcTotalUs = 0
        $byDriver = @{}
        foreach ($row in $dpcRows) {
            $mod = ($row.$moduleCol).ToString().Trim()
            $elapsed = 0
            [void][int64]::TryParse(($row.$elapsedCol).ToString().Trim(), [ref]$elapsed)
            if ($mod) {
                if (-not $byDriver.ContainsKey($mod)) { $byDriver[$mod] = 0 }
                $byDriver[$mod] += $elapsed
                $totalDpcUs += $elapsed
                # Match EAC drivers by name
                if ($mod -match '(?i)EasyAntiCheat|EAC') {
                    $eacDpcTotalUs += $elapsed
                }
            }
        }
        if ($totalDpcUs -lt 1) { $totalDpcUs = 1 }
    }
}

$eacPct = [math]::Round(($eacDpcTotalUs / $totalDpcUs), 4)
$eacMs = [math]::Round(($eacDpcTotalUs / 1000.0), 2)
$totalMs = [math]::Round(($totalDpcUs / 1000.0), 2)

# ---- Top-10 drivers by DPC time ----
$top10 = @()
if ($byDriver) {
    $top10 = $byDriver.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10 | ForEach-Object {
        [pscustomobject]@{
            Driver        = $_.Key
            DpcTotalMs    = [math]::Round(($_.Value / 1000.0), 2)
            ShareOfTotal  = [math]::Round(($_.Value / $totalDpcUs), 4)
        }
    }
}

# ---- Per-CPU summary ----
$perCpuSummary = @{}
if (Test-Path $percpuCsv) {
    $perCpu = Import-Csv $percpuCsv
    # Group by counter, compute avg DPC% per CPU
    $byCounter = $perCpu | Group-Object Counter
    foreach ($g in $byCounter) {
        if ($g.Name -match 'Processor\((\d+)\)\\% DPC Time') {
            $cpuId = [int]$matches[1]
            $vals = $g.Group | ForEach-Object { [double]$_.Value }
            $avg = ($vals | Measure-Object -Average).Average
            $max = ($vals | Measure-Object -Maximum).Maximum
            $perCpuSummary[$cpuId] = [pscustomobject]@{
                CPU      = $cpuId
                AvgDpcPct = [math]::Round($avg, 2)
                MaxDpcPct = [math]::Round($max, 2)
            }
        }
    }
}

# ---- Phase 0 verdict ----
$verdict = 'unknown'
$verdictReason = ''

if ($eacPct -ge 0.50 -and $eacMs -ge 100) {
    $verdict = 'PROCEED'
    $verdictReason = ('EAC dominant: ' + ($eacPct * 100) + '% share, ' + $eacMs + 'ms absolute. Plan justified.')
} elseif ($eacPct -ge 0.30 -or $eacMs -ge 50) {
    $verdict = 'PROCEED_LOW_CONFIDENCE'
    $verdictReason = ('EAC partial: ' + ($eacPct * 100) + '% share, ' + $eacMs + 'ms. Below high-confidence threshold but mitigation may help.')
} else {
    $verdict = 'HALT_INVESTIGATE_ALTERNATE'
    $verdictReason = ('EAC NOT dominant: ' + ($eacPct * 100) + '% share, ' + $eacMs + 'ms. Branch to network/GPU/driver investigation.')
}

# ---- Output JSON ----
$result = [ordered]@{
    captureDir       = $CaptureDir
    timestamp        = Get-Date -Format 'o'
    eacDpcTotalMs    = $eacMs
    totalDpcMs       = $totalMs
    eacDpcPct        = $eacPct
    verdict          = $verdict
    verdictReason    = $verdictReason
    top10Drivers     = $top10
    perCpuDpcSummary = ($perCpuSummary.Values | Sort-Object CPU)
}

$jsonPath = Join-Path $CaptureDir 'eac_analysis.json'
$result | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonPath -Encoding utf8

# ---- Output human-readable ----
$lines = @()
$lines += '=== EAC DPC Analysis ==='
$lines += ('Capture: ' + $CaptureDir)
$lines += ('Total DPC time: ' + $totalMs + ' ms')
$lines += ('EAC DPC time:   ' + $eacMs + ' ms')
$lines += ('EAC share:      ' + ($eacPct * 100) + ' %')
$lines += ''
$lines += '--- Phase 0 Verdict ---'
$lines += ('VERDICT: ' + $verdict)
$lines += ('REASON:  ' + $verdictReason)
$lines += ''
$lines += '--- Top 10 DPC Drivers ---'
$lines += ('{0,-40} {1,12} {2,10}' -f 'Driver', 'DPC ms', 'Share %')
$lines += ('-' * 65)
foreach ($d in $top10) {
    $lines += ('{0,-40} {1,12} {2,10}' -f $d.Driver, $d.DpcTotalMs, ([math]::Round($d.ShareOfTotal * 100, 2)))
}
$lines += ''
$lines += '--- Per-CPU DPC Distribution ---'
$lines += ('{0,-5} {1,12} {2,12}' -f 'CPU', 'Avg DPC%', 'Max DPC%')
$lines += ('-' * 32)
foreach ($c in ($perCpuSummary.Values | Sort-Object CPU)) {
    $lines += ('{0,-5} {1,12} {2,12}' -f $c.CPU, $c.AvgDpcPct, $c.MaxDpcPct)
}

$txtPath = Join-Path $CaptureDir 'eac_analysis.txt'
$lines | Out-File -FilePath $txtPath -Encoding utf8

# ---- Console output ----
$lines | ForEach-Object { Write-Host $_ }
Write-Host ''
Write-Host ('JSON: ' + $jsonPath) -ForegroundColor Green
Write-Host ('TXT:  ' + $txtPath) -ForegroundColor Green

# Exit code reflects verdict (for orchestrator / CI)
switch ($verdict) {
    'PROCEED'                     { exit 0 }
    'PROCEED_LOW_CONFIDENCE'      { exit 2 }
    'HALT_INVESTIGATE_ALTERNATE'  { exit 3 }
    default                        { exit 1 }
}
