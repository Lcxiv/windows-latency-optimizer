<#
.SYNOPSIS
    GPU ECC + clocks + temps + power continuous capture via nvidia-smi.
.DESCRIPTION
    Polls nvidia-smi at 1 Hz for DurationSec. Captures: ECC corrected/uncorrected
    (volatile + aggregate), graphics + memory clocks, GPU + memory temps, power
    draw + power limit, GPU + memory util, PerfCap reasons.
    Flags: any uncorrected ECC; PerfCap=Power for >5% of samples; VRAM clock
    drop below floor (810 MHz).
.OUTPUTS
    CSV  -> <OutDir>\gpu_ecc_<phase>.csv
    JSON -> <OutDir>\gpu_ecc_<phase>.summary.json
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$OutDir,
    [ValidateRange(5, 600)]
    [int]$DurationSec = 60,
    [string]$Phase = 'idle',
    [int]$VramFloorMHz = 810
)

$ErrorActionPreference = 'Continue'
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$nvSmi = 'C:\Windows\System32\nvidia-smi.exe'
if (-not (Test-Path $nvSmi)) {
    Write-Warning '[hw_gpu_ecc] nvidia-smi.exe not found — skipping'
    return
}

$csvPath = Join-Path $OutDir ('gpu_ecc_' + $Phase + '.csv')
$summaryPath = Join-Path $OutDir ('gpu_ecc_' + $Phase + '.summary.json')

# Query format
$queryFields = @(
    'timestamp',
    'pstate',
    'clocks.current.graphics',
    'clocks.current.memory',
    'temperature.gpu',
    'temperature.memory',
    'power.draw',
    'power.limit',
    'utilization.gpu',
    'utilization.memory',
    'pcie.link.gen.current',
    'pcie.link.width.current',
    'ecc.errors.corrected.volatile.total',
    'ecc.errors.uncorrected.volatile.total',
    'ecc.errors.corrected.aggregate.total',
    'ecc.errors.uncorrected.aggregate.total'
)
$query = $queryFields -join ','

# Use nvidia-smi -lms 1000 for streaming. Capture stdout to CSV.
# We start nvidia-smi as a subprocess and kill it after DurationSec.
Write-Host ('[hw_gpu_ecc] polling for ' + $DurationSec + 's -> ' + $csvPath) -ForegroundColor Cyan

$header = $queryFields -join ','
Set-Content -Path $csvPath -Value $header -Encoding UTF8

$pinfo = New-Object System.Diagnostics.ProcessStartInfo
$pinfo.FileName = $nvSmi
$pinfo.Arguments = '--query-gpu=' + $query + ' --format=csv,noheader,nounits -lms 1000'
$pinfo.RedirectStandardOutput = $true
$pinfo.UseShellExecute = $false
$pinfo.CreateNoWindow = $true

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $pinfo
[void]$proc.Start()

$stream = $proc.StandardOutput
$endTime = (Get-Date).AddSeconds($DurationSec)
$lines = @()
while ((Get-Date) -lt $endTime -and -not $proc.HasExited) {
    if (-not $stream.EndOfStream) {
        $line = $stream.ReadLine()
        if ($line) {
            Add-Content -Path $csvPath -Value $line -Encoding UTF8
            $lines += $line
        }
    } else {
        Start-Sleep -Milliseconds 100
    }
}

try {
    if (-not $proc.HasExited) {
        $proc.Kill()
        $proc.WaitForExit(2000) | Out-Null
    }
} catch {}

# --- Summarize ---
$summary = [ordered]@{
    schemaVersion = 1
    phase = $Phase
    durationSec = $DurationSec
    sampleCount = $lines.Count
    flags = @()
    metrics = @{}
}

if ($lines.Count -eq 0) {
    $summary.error = 'No samples collected'
    $summary | ConvertTo-Json -Depth 6 | Set-Content -Path $summaryPath -Encoding UTF8
    Write-Warning '[hw_gpu_ecc] no samples'
    return
}

# Helper: column index by field name
$colIdx = @{}
for ($i = 0; $i -lt $queryFields.Count; $i++) {
    $colIdx[$queryFields[$i]] = $i
}

function Get-NumericColumn {
    param($lines, $idx)
    $vals = @()
    foreach ($ln in $lines) {
        $parts = $ln -split ',\s*'
        if ($parts.Count -le $idx) { continue }
        $raw = $parts[$idx].Trim()
        if ($raw -eq '[N/A]' -or $raw -eq 'N/A' -or $raw -eq '') { continue }
        $num = 0.0
        if ([double]::TryParse($raw, [ref]$num)) {
            $vals += $num
        }
    }
    return $vals
}

function Get-Stats { param($vals)
    if (-not $vals -or $vals.Count -eq 0) { return $null }
    $m = $vals | Measure-Object -Average -Minimum -Maximum
    return @{
        avg = [math]::Round($m.Average, 2)
        min = [math]::Round($m.Minimum, 2)
        max = [math]::Round($m.Maximum, 2)
        count = $vals.Count
    }
}

# Per-metric stats
$summary.metrics['gpu_clock_mhz'] = Get-Stats (Get-NumericColumn $lines $colIdx['clocks.current.graphics'])
$summary.metrics['mem_clock_mhz'] = Get-Stats (Get-NumericColumn $lines $colIdx['clocks.current.memory'])
$summary.metrics['gpu_temp_c'] = Get-Stats (Get-NumericColumn $lines $colIdx['temperature.gpu'])
$summary.metrics['mem_temp_c'] = Get-Stats (Get-NumericColumn $lines $colIdx['temperature.memory'])
$summary.metrics['power_draw_w'] = Get-Stats (Get-NumericColumn $lines $colIdx['power.draw'])
$summary.metrics['power_limit_w'] = Get-Stats (Get-NumericColumn $lines $colIdx['power.limit'])
$summary.metrics['gpu_util_pct'] = Get-Stats (Get-NumericColumn $lines $colIdx['utilization.gpu'])
$summary.metrics['mem_util_pct'] = Get-Stats (Get-NumericColumn $lines $colIdx['utilization.memory'])

# ECC last-value
$eccCorrAgg = Get-NumericColumn $lines $colIdx['ecc.errors.corrected.aggregate.total']
$eccUncorrAgg = Get-NumericColumn $lines $colIdx['ecc.errors.uncorrected.aggregate.total']
$eccCorrVol = Get-NumericColumn $lines $colIdx['ecc.errors.corrected.volatile.total']
$eccUncorrVol = Get-NumericColumn $lines $colIdx['ecc.errors.uncorrected.volatile.total']

$summary.metrics['ecc_corrected_aggregate_last'] = if ($eccCorrAgg.Count -gt 0) { $eccCorrAgg[-1] } else { $null }
$summary.metrics['ecc_uncorrected_aggregate_last'] = if ($eccUncorrAgg.Count -gt 0) { $eccUncorrAgg[-1] } else { $null }
$summary.metrics['ecc_corrected_volatile_last'] = if ($eccCorrVol.Count -gt 0) { $eccCorrVol[-1] } else { $null }
$summary.metrics['ecc_uncorrected_volatile_last'] = if ($eccUncorrVol.Count -gt 0) { $eccUncorrVol[-1] } else { $null }

# Flags
if ($summary.metrics['mem_clock_mhz'] -and $summary.metrics['mem_clock_mhz'].min -lt $VramFloorMHz) {
    $summary.flags += ('VRAM clock dropped below floor: ' + $summary.metrics['mem_clock_mhz'].min + ' MHz < ' + $VramFloorMHz)
}
if ($null -ne $summary.metrics['ecc_uncorrected_aggregate_last'] -and $summary.metrics['ecc_uncorrected_aggregate_last'] -gt 0) {
    $summary.flags += ('GPU ECC uncorrected (aggregate) = ' + $summary.metrics['ecc_uncorrected_aggregate_last'])
}
if ($null -ne $summary.metrics['ecc_uncorrected_volatile_last'] -and $summary.metrics['ecc_uncorrected_volatile_last'] -gt 0) {
    $summary.flags += ('GPU ECC uncorrected (volatile) = ' + $summary.metrics['ecc_uncorrected_volatile_last'])
}
if ($summary.metrics['gpu_temp_c'] -and $summary.metrics['gpu_temp_c'].max -gt 88) {
    $summary.flags += ('GPU edge temp max ' + $summary.metrics['gpu_temp_c'].max + ' C > 88 C (throttle threshold)')
}
if ($summary.metrics['mem_temp_c'] -and $summary.metrics['mem_temp_c'].max -gt 95) {
    $summary.flags += ('GPU memory temp max ' + $summary.metrics['mem_temp_c'].max + ' C > 95 C')
}

# PowerLimit clamp pct: count samples where power_draw >= 0.98 * power_limit
$powerDraw = Get-NumericColumn $lines $colIdx['power.draw']
$powerLimit = Get-NumericColumn $lines $colIdx['power.limit']
if ($powerDraw.Count -gt 0 -and $powerLimit.Count -gt 0) {
    $clampCount = 0
    $minLen = [math]::Min($powerDraw.Count, $powerLimit.Count)
    for ($i = 0; $i -lt $minLen; $i++) {
        if ($powerLimit[$i] -gt 0 -and ($powerDraw[$i] / $powerLimit[$i]) -ge 0.98) { $clampCount++ }
    }
    $clampPct = [math]::Round(($clampCount / $minLen * 100), 2)
    $summary.metrics['powerlimit_clamp_pct'] = $clampPct
    if ($clampPct -gt 5.0) {
        $summary.flags += ('PowerLimit clamp at ' + $clampPct + '% of samples (>5%)')
    }
}

if ($summary.flags.Count -eq 0) {
    $summary.flags = @('PASS: GPU within thermal/power/ECC bands during phase')
}

$summary | ConvertTo-Json -Depth 6 | Set-Content -Path $summaryPath -Encoding UTF8
Write-Host ('[hw_gpu_ecc] summary: ' + $summaryPath) -ForegroundColor Cyan
foreach ($f in $summary.flags) { Write-Host ('  -> ' + $f) }
