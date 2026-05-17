<#
.SYNOPSIS
    Walk a hwdiag run directory, compare every captured rail/metric against
    reference_hardware_diagnostic_voltages.json, emit manifest + HTML rollup.
.DESCRIPTION
    Reads the reference JSON's "rails" array. For each rail, looks up the
    corresponding measurement in the run's *_summary.json + *.json files.
    Classifies green / yellow / red per rail. Aggregates flags. Writes:
      manifest.json   — structured comparison results
      anomalies.json  — only the red/critical findings
      hwdiag_rollup.html — single-page user-facing summary
.OUTPUTS
    <RunDir>\manifest.json
    <RunDir>\anomalies.json
    <RunDir>\hwdiag_rollup.html
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$RunDir,
    [string]$ReferenceJson = ''
)

$ErrorActionPreference = 'Continue'
$projectRoot = Split-Path $PSScriptRoot -Parent
if ($ReferenceJson -eq '') {
    $ReferenceJson = Join-Path $projectRoot 'docs\reference_hardware_diagnostic_voltages.json'
}
if (-not (Test-Path $ReferenceJson)) {
    Write-Error ('Reference JSON not found: ' + $ReferenceJson)
    exit 1
}
if (-not (Test-Path $RunDir)) {
    Write-Error ('RunDir not found: ' + $RunDir)
    exit 1
}

$ref = Get-Content $ReferenceJson -Raw | ConvertFrom-Json
$manifest = [ordered]@{
    schemaVersion = 1
    runDir = $RunDir
    referenceJson = $ReferenceJson
    comparedAt = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    findings = @()
    summary = [ordered]@{ total = 0; ok = 0; info = 0; warn = 0; critical = 0; missing = 0 }
}

# --- Helper: load a JSON file from RunDir if exists ---
function Get-JsonOrNull {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { return Get-Content $Path -Raw | ConvertFrom-Json } catch { return $null }
}

# Load all relevant captures up-front
$pcie = Get-JsonOrNull (Join-Path $RunDir 'preflight\pcie_state.json')
$smart = Get-JsonOrNull (Join-Path $RunDir 'preflight\smart.json')
$whea = Get-JsonOrNull (Join-Path $RunDir 'preflight\whea.json')
$nicIdle = Get-JsonOrNull (Join-Path $RunDir 'idle\nic_errors_idle.json')
$nicLoad = Get-JsonOrNull (Join-Path $RunDir 'loaded\nic_errors_loaded.json')
$voltIdle = Get-JsonOrNull (Join-Path $RunDir 'idle\voltages_idle.summary.json')
$voltLoad = Get-JsonOrNull (Join-Path $RunDir 'loaded\voltages_load.summary.json')
$gpuIdle = Get-JsonOrNull (Join-Path $RunDir 'idle\gpu_ecc_idle.summary.json')
$gpuLoad = Get-JsonOrNull (Join-Path $RunDir 'loaded\gpu_ecc_loaded.summary.json')
$killDec = Get-JsonOrNull (Join-Path $RunDir 'kill_test\kill_decision.json')

# --- Rail value resolver: map rail.id -> actual measured value ---
function Resolve-RailValue {
    param($rail)
    $id = $rail.id
    switch ($id) {
        'cpu_vcore_idle'        { if ($voltIdle -and $voltIdle.hwinfo64.rails.cpu_core_vid -and $voltIdle.hwinfo64.rails.cpu_core_vid.found) { return $voltIdle.hwinfo64.rails.cpu_core_vid.p50 } }
        'cpu_vcore_load'        { if ($voltLoad -and $voltLoad.hwinfo64.rails.cpu_core_vid -and $voltLoad.hwinfo64.rails.cpu_core_vid.found) { return $voltLoad.hwinfo64.rails.cpu_core_vid.p50 } }
        'cpu_vcore_critical_max' { if ($voltLoad -and $voltLoad.hwinfo64.rails.cpu_core_vid -and $voltLoad.hwinfo64.rails.cpu_core_vid.found) { return $voltLoad.hwinfo64.rails.cpu_core_vid.max } }
        'cpu_vsoc'              { if ($voltLoad -and $voltLoad.hwinfo64.rails.cpu_vsoc -and $voltLoad.hwinfo64.rails.cpu_vsoc.found) { return $voltLoad.hwinfo64.rails.cpu_vsoc.max } elseif ($voltIdle -and $voltIdle.hwinfo64.rails.cpu_vsoc -and $voltIdle.hwinfo64.rails.cpu_vsoc.found) { return $voltIdle.hwinfo64.rails.cpu_vsoc.max } }
        'cpu_vddio_mem'         { if ($voltIdle -and $voltIdle.hwinfo64.rails.cpu_vddio_mem -and $voltIdle.hwinfo64.rails.cpu_vddio_mem.found) { return $voltIdle.hwinfo64.rails.cpu_vddio_mem.avg } }
        'cpu_vddp'              { if ($voltIdle -and $voltIdle.hwinfo64.rails.cpu_vddp -and $voltIdle.hwinfo64.rails.cpu_vddp.found) { return $voltIdle.hwinfo64.rails.cpu_vddp.avg } }
        'cpu_tdie_idle'         { if ($voltIdle -and $voltIdle.hwinfo64.rails.cpu_tdie -and $voltIdle.hwinfo64.rails.cpu_tdie.found) { return $voltIdle.hwinfo64.rails.cpu_tdie.avg } }
        'cpu_tdie_load'         { if ($voltLoad -and $voltLoad.hwinfo64.rails.cpu_tdie -and $voltLoad.hwinfo64.rails.cpu_tdie.found) { return $voltLoad.hwinfo64.rails.cpu_tdie.max } }
        'cpu_iod_temp'          { if ($voltLoad -and $voltLoad.hwinfo64.rails.cpu_iod -and $voltLoad.hwinfo64.rails.cpu_iod.found) { return $voltLoad.hwinfo64.rails.cpu_iod.max } }
        'vrm_temp'              { if ($voltLoad -and $voltLoad.hwinfo64.rails.vrm_temp -and $voltLoad.hwinfo64.rails.vrm_temp.found) { return $voltLoad.hwinfo64.rails.vrm_temp.max } }
        'gpu_vram_clock_idle'   { if ($gpuIdle -and $gpuIdle.metrics.mem_clock_mhz) { return $gpuIdle.metrics.mem_clock_mhz.min } }
        'gpu_temp_idle'         { if ($gpuIdle -and $gpuIdle.metrics.gpu_temp_c) { return $gpuIdle.metrics.gpu_temp_c.max } }
        'gpu_temp_load'         { if ($gpuLoad -and $gpuLoad.metrics.gpu_temp_c) { return $gpuLoad.metrics.gpu_temp_c.max } }
        'gpu_temp_critical'     { if ($gpuLoad -and $gpuLoad.metrics.gpu_temp_c) { return $gpuLoad.metrics.gpu_temp_c.max } }
        'gpu_memory_temp'       { if ($gpuLoad -and $gpuLoad.metrics.mem_temp_c) { return $gpuLoad.metrics.mem_temp_c.max } }
        'gpu_pcie_link_gen'     { if ($pcie -and $pcie.gpu) { return $pcie.gpu.pcie_gen_current } }
        'gpu_pcie_link_width'   { if ($pcie -and $pcie.gpu) { return $pcie.gpu.pcie_width_current } }
        'gpu_powerlimit_clamp_pct' { if ($gpuLoad -and $gpuLoad.metrics.powerlimit_clamp_pct) { return $gpuLoad.metrics.powerlimit_clamp_pct } }
        'gpu_ecc_uncorrected'   { if ($gpuLoad -and $gpuLoad.metrics.ecc_uncorrected_aggregate_last) { return $gpuLoad.metrics.ecc_uncorrected_aggregate_last } else { return 0 } }
        'nic_link_speed_gbps'   {
            if ($nicIdle -and $nicIdle.adapters) {
                $i226 = $nicIdle.adapters | Where-Object { $_.interfaceDescription -match 'I226' } | Select-Object -First 1
                if ($i226) {
                    $bps = $i226.linkSpeedBps
                    if ($bps -is [string]) {
                        # Parse "2.5 Gbps" / "1 Gbps" textual form
                        if ($bps -match '([\d\.]+)\s*Gbps') { return [math]::Round([double]$Matches[1], 2) }
                        if ($bps -match '([\d\.]+)\s*Mbps') { return [math]::Round([double]$Matches[1] / 1000, 3) }
                        $num = 0.0
                        if ([double]::TryParse($bps, [ref]$num)) { return [math]::Round($num / 1e9, 2) }
                        return $null
                    }
                    return [math]::Round([double]$bps / 1e9, 2)
                }
            }
        }
        'nic_rx_crc_errors'     {
            if ($nicLoad -and $nicLoad.adapters) {
                $sum = 0
                foreach ($a in $nicLoad.adapters) { if ($a.deltas -and $a.deltas.receivedPacketErrors) { $sum += [int]$a.deltas.receivedPacketErrors } }
                return $sum
            }
        }
        'nic_rx_errors_total'   {
            if ($nicLoad -and $nicLoad.adapters) {
                $sum = 0
                foreach ($a in $nicLoad.adapters) { if ($a.deltas -and $a.deltas.receivedPacketErrors) { $sum += [int]$a.deltas.receivedPacketErrors } }
                return $sum
            }
        }
        'smart_nvme_temp'       {
            if ($smart -and $smart.drives) {
                $maxT = 0
                foreach ($d in $smart.drives) {
                    if ($d.busType -eq 'NVMe' -and $d.reliability -and $d.reliability.temperature_c -and ($d.reliability.temperature_c -gt $maxT)) {
                        $maxT = $d.reliability.temperature_c
                    }
                }
                return $maxT
            }
        }
        'smart_wear_pct'        {
            if ($smart -and $smart.drives) {
                $maxW = 0
                foreach ($d in $smart.drives) {
                    if ($d.reliability -and $d.reliability.wear_pct -and ($d.reliability.wear_pct -gt $maxW)) { $maxW = $d.reliability.wear_pct }
                }
                return $maxW
            }
        }
        'smart_read_errors'     {
            if ($smart -and $smart.drives) {
                $sum = 0
                foreach ($d in $smart.drives) { if ($d.reliability -and $d.reliability.readErrorsUncorrected) { $sum += [int]$d.reliability.readErrorsUncorrected } }
                return $sum
            }
        }
        'smart_write_errors'    {
            if ($smart -and $smart.drives) {
                $sum = 0
                foreach ($d in $smart.drives) { if ($d.reliability -and $d.reliability.writeErrorsUncorrected) { $sum += [int]$d.reliability.writeErrorsUncorrected } }
                return $sum
            }
        }
        'whea_critical_7d'      { if ($whea -and $whea.bySeverity) { return [int]$whea.bySeverity.Critical } }
        'whea_error_7d'         { if ($whea -and $whea.bySeverity) { return [int]$whea.bySeverity.Error } }
        'whea_warning_per_day'  {
            if ($whea -and $whea.byEventId -and $whea.daysBack) {
                $id19 = 0
                if ($whea.byEventId.PSObject.Properties.Name -contains '19') { $id19 = [int]$whea.byEventId.'19' }
                return [math]::Round($id19 / [math]::Max(1, $whea.daysBack), 2)
            }
        }
        'kill_test_cores_6_9_pct' { if ($killDec) { return $killDec.cores69_post_avg_pct } }
    }
    return $null
}

# --- Classify a value against a rail spec ---
function Classify-Rail {
    param($rail, $value)
    if ($null -eq $value) {
        return @{ status = 'missing'; severity = 'info'; message = 'no measurement found' }
    }
    $belowSev = if ($rail.severity_below) { $rail.severity_below } else { 'info' }
    $aboveSev = if ($rail.severity_above) { $rail.severity_above } else { 'info' }

    $isBelow = $false
    $isAbove = $false
    if ($null -ne $rail.min) { $isBelow = ($value -lt $rail.min) }
    if ($null -ne $rail.max) { $isAbove = ($value -gt $rail.max) }

    if ($isBelow) {
        return @{ status = 'fail_below'; severity = $belowSev; message = ('value ' + $value + ' < min ' + $rail.min + ' ' + $rail.unit) }
    }
    if ($isAbove) {
        return @{ status = 'fail_above'; severity = $aboveSev; message = ('value ' + $value + ' > max ' + $rail.max + ' ' + $rail.unit) }
    }
    return @{ status = 'ok'; severity = 'ok'; message = 'within range' }
}

# --- Walk every rail in the reference ---
foreach ($rail in $ref.rails) {
    $val = Resolve-RailValue $rail
    $cls = Classify-Rail -rail $rail -value $val
    $finding = [ordered]@{
        id = $rail.id
        component = $rail.component
        metric = $rail.metric
        phase = $rail.phase
        unit = $rail.unit
        min = $rail.min
        max = $rail.max
        observed = $val
        status = $cls.status
        severity = $cls.severity
        message = $cls.message
        source = $rail.source
    }
    $manifest.findings += $finding
    $manifest.summary.total++
    if ($cls.status -eq 'missing') {
        $manifest.summary.missing++
    } else {
        switch ($cls.severity) {
            'ok'       { $manifest.summary.ok++ }
            'info'     { $manifest.summary.info++ }
            'warn'     { $manifest.summary.warn++ }
            'critical' { $manifest.summary.critical++ }
        }
    }
}

# --- Anomalies subset (warn or critical) ---
$anomalies = @($manifest.findings | Where-Object { $_.severity -eq 'warn' -or $_.severity -eq 'critical' })

$manifestPath = Join-Path $RunDir 'manifest.json'
$anomaliesPath = Join-Path $RunDir 'anomalies.json'
$manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding UTF8
@{ schemaVersion = 1; count = $anomalies.Count; findings = $anomalies } | ConvertTo-Json -Depth 8 | Set-Content -Path $anomaliesPath -Encoding UTF8

# --- HTML rollup ---
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

function Get-StatusBadge { param($severity)
    $color = '#10b981'; $label = 'OK'
    switch ($severity) {
        'info'     { $color = '#64748b'; $label = 'INFO' }
        'warn'     { $color = '#f59e0b'; $label = 'WARN' }
        'critical' { $color = '#ef4444'; $label = 'CRITICAL' }
        'missing'  { $color = '#374151'; $label = 'NO DATA' }
    }
    return '<span class="badge" style="background:' + $color + '">' + $label + '</span>'
}

$rows = ''
foreach ($f in $manifest.findings) {
    $badge = Get-StatusBadge $f.severity
    $obs = if ($null -eq $f.observed) { '—' } else { $f.observed }
    $range = ''
    if ($null -ne $f.min) { $range += '≥' + $f.min }
    if ($null -ne $f.min -and $null -ne $f.max) { $range += ' / ' }
    if ($null -ne $f.max) { $range += '≤' + $f.max }
    if ($range -eq '') { $range = '—' }
    $rows += '<tr><td>' + $badge + '</td><td>' + [System.Web.HttpUtility]::HtmlEncode($f.component) + '</td><td>' + [System.Web.HttpUtility]::HtmlEncode($f.metric) + '</td><td>' + [System.Web.HttpUtility]::HtmlEncode($f.phase) + '</td><td>' + $obs + ' ' + [System.Web.HttpUtility]::HtmlEncode($f.unit) + '</td><td class="muted">' + $range + ' ' + [System.Web.HttpUtility]::HtmlEncode($f.unit) + '</td><td class="muted small">' + [System.Web.HttpUtility]::HtmlEncode($f.message) + '</td></tr>'
}

$bannerColor = '#10b981'; $bannerText = 'PASS'
if ($manifest.summary.critical -gt 0) { $bannerColor = '#ef4444'; $bannerText = ($manifest.summary.critical.ToString() + ' CRITICAL') }
elseif ($manifest.summary.warn -gt 0) { $bannerColor = '#f59e0b'; $bannerText = ($manifest.summary.warn.ToString() + ' WARN') }

$html = @"
<!DOCTYPE html>
<html><head><meta charset="utf-8">
<title>HW Diag Rollup — $((Get-Date -Format 'yyyy-MM-dd HH:mm'))</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,'Segoe UI',sans-serif;padding:32px;max-width:1200px;margin:0 auto}
h1{font-size:22px;margin-bottom:4px}
.subtitle{color:#94a3b8;font-size:13px;margin-bottom:24px}
.banner{display:flex;align-items:center;gap:24px;background:#1e293b;border-radius:12px;padding:20px;margin-bottom:24px;border-left:6px solid $bannerColor}
.banner-text{font-size:24px;font-weight:600;color:$bannerColor}
.banner-stats{font-size:13px;color:#94a3b8}
table{width:100%;border-collapse:collapse;background:#1e293b;border-radius:8px;overflow:hidden}
th,td{padding:8px 12px;text-align:left;border-bottom:1px solid #334155;font-size:13px}
th{background:#0f172a;font-weight:600;color:#94a3b8}
tr:hover{background:#1c2740}
.muted{color:#64748b}
.small{font-size:12px}
.badge{display:inline-block;padding:2px 8px;border-radius:4px;color:#0f172a;font-size:11px;font-weight:600}
.section{margin-bottom:24px}
.section h3{font-size:15px;margin-bottom:8px;border-bottom:1px solid #334155;padding-bottom:4px}
.foot{color:#475569;font-size:11px;margin-top:32px;text-align:center}
</style></head>
<body>
<h1>Hardware Diagnostic Rollup</h1>
<div class="subtitle">$RunDir &middot; $((Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))</div>
<div class="banner">
  <div class="banner-text">$bannerText</div>
  <div class="banner-stats">
    Total: $($manifest.summary.total) &middot;
    OK: $($manifest.summary.ok) &middot;
    WARN: $($manifest.summary.warn) &middot;
    CRIT: $($manifest.summary.critical) &middot;
    Missing: $($manifest.summary.missing)
  </div>
</div>
<div class="section">
<h3>Findings</h3>
<table>
<thead><tr><th>Status</th><th>Component</th><th>Metric</th><th>Phase</th><th>Observed</th><th>Range</th><th>Note</th></tr></thead>
<tbody>$rows</tbody>
</table>
</div>
<div class="foot">windows-latency-optimizer / hwdiag &middot; manifest.json &middot; anomalies.json</div>
</body></html>
"@

$htmlPath = Join-Path $RunDir 'hwdiag_rollup.html'
$html | Out-File -FilePath $htmlPath -Encoding UTF8

Write-Host ''
Write-Host ('[compare_to_reference] manifest:  ' + $manifestPath) -ForegroundColor Cyan
Write-Host ('[compare_to_reference] anomalies: ' + $anomaliesPath) -ForegroundColor Cyan
Write-Host ('[compare_to_reference] rollup:    ' + $htmlPath) -ForegroundColor Cyan
$verdictColor = 'Red'
if ($bannerColor -eq '#10b981') { $verdictColor = 'Green' }
elseif ($bannerColor -eq '#f59e0b') { $verdictColor = 'Yellow' }
Write-Host ('[compare_to_reference] verdict:   ' + $bannerText) -ForegroundColor $verdictColor
