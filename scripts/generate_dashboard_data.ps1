param(
    [string]$ExperimentsDir = "$PSScriptRoot\..\captures\experiments",
    [string]$OutFile        = "$PSScriptRoot\..\dashboard\data\experiments_generated.js"
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

    # Map run_experiment.ps1 counter names to experiments.js field names
    $fieldMap = @{
        '% processor time[_total]' = 'ProcessorTimePct'
        '% dpc time[_total]'       = 'DPCTimePct'
        '% interrupt time[_total]' = 'InterruptTimePct'
        'available mbytes'         = 'AvailableMemoryMB'
        'pages/sec'                = 'PagesSec'
        'page faults/sec'          = 'PageFaultsSec'
        'avg. disk sec/read'       = 'DiskSecRead'
        'avg. disk sec/write'      = 'DiskSecWrite'
        'current disk queue length'= 'DiskQueueLength'
        'context switches/sec'     = 'ContextSwitchesSec'
        'processor queue length'   = 'ProcessorQueueLength'
    }

    foreach ($rawKey in $perf.PSObject.Properties.Name) {
        $lk = $rawKey.ToLower()
        $mapped = $null
        foreach ($pattern in $fieldMap.Keys) {
            # Use .Contains() instead of -like to avoid [] wildcard interpretation
            if ($lk.Contains($pattern)) { $mapped = $fieldMap[$pattern]; break }
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
        $avg = if ($v.avg -ne $null) { $v.avg } else { 'null' }
        $min = if ($v.min -ne $null) { $v.min } else { 'null' }
        $max = if ($v.max -ne $null) { $v.max } else { 'null' }
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

    # Build interruptTopology block
    $topoJs = 'null'
    if ($raw.interruptTopology) {
        $t = $raw.interruptTopology
        $topoJs = "{ cpu0Share: $($t.cpu0Share), cpu23Share: $($t.cpu23Share), cpu47Share: $($t.cpu47Share) }"
    }

    $entry = @"
  {
    id: "$id",
    name: "$($raw.label -replace '"','\"')",
    shortName: "$($raw.label -replace '"','\"')",
    date: "$($raw.capturedAt)",
    description: "$($raw.description -replace '"','\"')",
    tags: ["generated"],
    registry: {},
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
