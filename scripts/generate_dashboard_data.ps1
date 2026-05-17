<#
.SYNOPSIS
    Regenerate experiments_generated.js from captured experiment.json files.
.DESCRIPTION
    Scans captures/experiments/ for experiment.json files, normalizes performance
    data field names, and writes window.EXPERIMENTS_GENERATED array for the dashboard.
.EXAMPLE
    .\generate_dashboard_data.ps1
#>
param(
    [string]$ExperimentsDir = '',
    [string]$OutFile        = ''
)

# =============================================================================
# generate_dashboard_data.ps1
# Reads all JSON files from captures/experiments/ and converts them into
# dashboard/data/experiments_generated.js (window.EXPERIMENTS_GENERATED format).
#
# Usage:
#   .\generate_dashboard_data.ps1
#   .\generate_dashboard_data.ps1 -ExperimentsDir ..\captures\experiments -OutFile ..\dashboard\data\experiments_generated.js
#
# The generated file is separate from experiments.js (which contains the
# hand-curated baseline and early experiments). To merge both sources,
# experiments_generated.js can be loaded alongside experiments.js.
# =============================================================================

$ErrorActionPreference = "Stop"

# Load central config for paths and counter name map
. "$PSScriptRoot\config.ps1"

if ($ExperimentsDir -eq '') { $ExperimentsDir = $script:ExperimentsDir }
if ($OutFile -eq '')        { $OutFile = Join-Path $script:DashboardData 'experiments_generated.js' }

if (-not (Test-Path $ExperimentsDir)) {
    Write-Warning "No experiments directory found at: $ExperimentsDir"
    Write-Host "Run .\scripts\run_experiment.ps1 to create your first experiment JSON."
    exit 0
}

# Find JSON files: both flat files (from run_experiment.ps1) and
# subdirectory experiment.json files (from pipeline.ps1)
$jsonFiles = @()
$jsonFiles += Get-ChildItem $ExperimentsDir -Filter '*.json' -File -ErrorAction SilentlyContinue
$jsonFiles += Get-ChildItem $ExperimentsDir -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Get-ChildItem $_.FullName -Filter 'experiment.json' -File -ErrorAction SilentlyContinue }
$jsonFiles = $jsonFiles | Sort-Object FullName

if ($jsonFiles.Count -eq 0) {
    Write-Warning "No JSON files found in: $ExperimentsDir"
    exit 0
}

Write-Host "=== generate_dashboard_data.ps1 ==="
Write-Host "Source: $ExperimentsDir ($($jsonFiles.Count) file(s))"
Write-Host "Output: $OutFile"
Write-Host ""

# ---------------------------------------------------------------------------
# Helper: convert perf counter map from run_experiment.ps1 JSON to the
# normalized shape expected by experiments.js
# ---------------------------------------------------------------------------
function Normalize-Performance($perf) {
    $out = @{}

    foreach ($rawKey in $perf.PSObject.Properties.Name) {
        $lk = $rawKey.ToLower()
        $mapped = $null
        foreach ($pattern in $script:CounterNameMap.Keys) {
            # Use .Contains() instead of -like to avoid [] wildcard interpretation
            if ($lk.Contains($pattern)) { $mapped = $script:CounterNameMap[$pattern]; break }
        }
        if ($mapped) {
            $v = $perf.$rawKey
            $out[$mapped] = @{ avg=$v.avg; min=$v.min; max=$v.max }
        }
    }
    return $out
}

# ---------------------------------------------------------------------------
# Build JS entries
# ---------------------------------------------------------------------------
$entries = @()

foreach ($file in $jsonFiles) {
    Write-Host "  Processing: $($file.Name)"

    try {
        $raw = Get-Content $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        Write-Warning "Skipping unreadable file $($file.Name): $($_.Exception.Message)"
        continue
    }
    $label = $raw.label -replace '[^a-zA-Z0-9_]', '_'

    # Build cpuData array
    $cpuDataJs = @()
    if ($raw.cpuData) {
        foreach ($cpu in $raw.cpuData) {
            $cpuDataJs += "      { cpu: $($cpu.cpu), interruptPct: $($cpu.interruptPct), dpcPct: $($cpu.dpcPct), intrPerSec: $($cpu.intrPerSec) }"
        }
    }

    # Build performance block
    $perfNorm = Normalize-Performance $raw.performance
    $perfLines = @()
    foreach ($k in ($perfNorm.Keys | Sort-Object)) {
        $v = $perfNorm[$k]
        $avg = 'null'; if ($null -ne $v.avg) { $avg = $v.avg }
        $min = 'null'; if ($null -ne $v.min) { $min = $v.min }
        $max = 'null'; if ($null -ne $v.max) { $max = $v.max }
        $perfLines += "      $k`: { avg: $avg, min: $min, max: $max }"
    }

    $id = "gen_$($raw.capturedAt -replace '[^0-9]','' )_$label"

    # Build frameTiming block (from pipeline v3)
    $frameTimingJs = 'null'
    if ($raw.frameTiming) {
        $ft = $raw.frameTiming
        $ftm = $ft.frameTimeMs
        $fps = $ft.fps
        $frameTimingJs = @"
{
      processName: "$($ft.processName)",
      totalFrames: $($ft.totalFrames),
      droppedFrames: $($ft.droppedFrames),
      droppedPct: $($ft.droppedPct),
      frameTimeMs: { avg: $($ftm.avg), p50: $($ftm.p50), p95: $($ftm.p95), p99: $($ftm.p99), max: $($ftm.max), min: $($ftm.min) },
      fps: { avg: $($fps.avg), p1Low: $($fps.p1Low), min: $($fps.min) }
    }
"@
    }

    # Build gpuUtilization block
    $gpuUtilJs = 'null'
    if ($raw.gpuUtilization) {
        $gpuLines = @()
        foreach ($eng in $raw.gpuUtilization.PSObject.Properties) {
            $gpuLines += "      `"$($eng.Name)`": { avg: $($eng.Value.avg), max: $($eng.Value.max) }"
        }
        $gpuUtilJs = "{`n" + ($gpuLines -join ",`n") + "`n    }"
    }

    # Build interruptTopology block (handles both v3 flat and v4 groups format)
    $topoJs = 'null'
    if ($raw.interruptTopology) {
        $t = $raw.interruptTopology
        # Always emit backwards-compat flat keys
        $c0 = 0; $c23 = 0; $c47 = 0
        if ($null -ne $t.cpu0Share) { $c0 = $t.cpu0Share }
        if ($null -ne $t.cpu23Share) { $c23 = $t.cpu23Share }
        if ($null -ne $t.cpu47Share) { $c47 = $t.cpu47Share }
        $topoJs = '{ cpu0Share: ' + $c0 + ', cpu23Share: ' + $c23 + ', cpu47Share: ' + $c47

        # Emit new groups array if present (schema v4+)
        if ($t.groups) {
            $groupEntries = @()
            foreach ($g in $t.groups) {
                $cpuList = ($g.cpus -join ',')
                $groupEntries += '{ name: "' + $g.name + '", cpus: [' + $cpuList + '], share: ' + $g.share + ' }'
            }
            $topoJs += ', groups: [' + ($groupEntries -join ', ') + ']'
            if ($t.totalLogicalCpus) { $topoJs += ', totalLogicalCpus: ' + $t.totalLogicalCpus }
            if ($t.cpuModel) { $topoJs += ', cpuModel: "' + ($t.cpuModel -replace '"','\"') + '"' }
        }
        $topoJs += ' }'
    }

    # Build smiAnalysis block
    $smiAnalysisJs = 'null'
    if ($raw.smiAnalysis) {
        $s = $raw.smiAnalysis
        $sParts = @()
        if ($s.source)              { $sParts += 'source: "' + $s.source + '"' }
        if ($null -ne $s.verdict)   { $sParts += 'verdict: "' + $s.verdict + '"' }
        if ($null -ne $s.highLatencyDpcCount) { $sParts += 'highLatencyDpcCount: ' + $s.highLatencyDpcCount }
        if ($null -ne $s.maxBucketUs)         { $sParts += 'maxBucketUs: ' + $s.maxBucketUs }
        if ($null -ne $s.driversWithHighDpc)  { $sParts += 'driversWithHighDpc: ' + $s.driversWithHighDpc }
        if ($null -ne $s.correlationScore)    { $sParts += 'correlationScore: ' + $s.correlationScore }
        if ($null -ne $s.captureDurationSec)  { $sParts += 'captureDurationSec: ' + $s.captureDurationSec }
        $smiAnalysisJs = '{ ' + ($sParts -join ', ') + ' }'
    }

    # Build systemInfo block
    $sysInfoJs = 'null'
    if ($raw.systemInfo) {
        $si = $raw.systemInfo
        $siParts = @()
        if ($si.hostname) { $siParts += 'hostname: "' + ($si.hostname -replace '"','\"') + '"' }
        if ($si.cpu)      { $siParts += 'cpu: "' + ($si.cpu -replace '"','\"') + '"' }
        if ($si.cores)    { $siParts += 'cores: "' + $si.cores + '"' }
        if ($si.ram)      { $siParts += 'ram: "' + $si.ram + '"' }
        if ($si.os)       { $siParts += 'os: "' + ($si.os -replace '"','\"') + '"' }
        if ($si.gpu)      { $siParts += 'gpu: "' + ($si.gpu -replace '"','\"') + '"' }
        $sysInfoJs = '{ ' + ($siParts -join ', ') + ' }'
    }

    $entry = @"
  {
    id: "$id",
    name: "$($raw.label -replace '"','\"')",
    shortName: "$($raw.label -replace '"','\"')",
    date: "$($raw.capturedAt)",
    description: "$($raw.description -replace '"','\"')",
    tags: ["generated"],
    systemInfo: $sysInfoJs,
    registry: {},
    smiAnalysis: $smiAnalysisJs,
    performance: {
$($perfLines -join ",`n")
    },
    latencymon: null,
    cpuData: [
$($cpuDataJs -join ",`n")
    ],
    frameTiming: $frameTimingJs,
    gpuUtilization: $gpuUtilJs,
    interruptTopology: $topoJs
  }
"@
    $entries += $entry
}

# ---------------------------------------------------------------------------
# Write output file
# ---------------------------------------------------------------------------
$body = $entries -join ",`n"

$output = @"
// AUTO-GENERATED by scripts/generate_dashboard_data.ps1
// Do not edit manually — re-run the script to regenerate.
// Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
// Source: $ExperimentsDir ($($jsonFiles.Count) experiments)

window.EXPERIMENTS_GENERATED = [
$body
];
"@

$output | Out-File $OutFile -Encoding UTF8

Write-Host ""
Write-Host "Done. Written $($entries.Count) experiment(s) to:"
Write-Host "  $OutFile"
Write-Host ""
Write-Host "To use in the dashboard, add a <script> tag for experiments_generated.js"
Write-Host "before the main experiments.js in dashboard/index.html."
