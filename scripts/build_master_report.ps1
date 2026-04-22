<#
.SYNOPSIS
    Build single-file MASTER.html report from a baseline capture directory.
.DESCRIPTION
    Reads all outputs from a baseline run directory (audit, perf, xperf, procmon,
    latmon, presentmon, delta) and stitches them into one self-contained HTML
    file. Inlines CSS from dashboard/app.css for visual consistency.

    Sections: Pre-freeze audit, Idle baseline, Under-load baseline, Delta
    idle-vs-loaded, Manifest. Missing data sections render "Skipped" badges
    rather than blank cells.
.EXAMPLE
    .\build_master_report.ps1 -InputDir captures\baselines\BASELINE_POST_REBOOT_CLEAN_20260422-103000 -OutputPath MASTER.html
#>
param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$InputDir,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $InputDir)) {
    throw "Input directory not found: $InputDir"
}

$projectRoot = Split-Path $PSScriptRoot -Parent

function Read-JsonOrNull {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $raw = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Read-TextOrNull {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return (Get-Content $Path -Raw -ErrorAction SilentlyContinue)
}

function HtmlEscape {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return ($Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
}

function Build-PhaseSection {
    param(
        [string]$Title,
        [string]$PhaseDir,
        [string]$PhaseName  # 'idle' or 'loaded'
    )

    $perf = Read-JsonOrNull (Join-Path $PhaseDir ('pipeline_' + $PhaseName + '.json'))
    $xperf = Read-JsonOrNull (Join-Path $PhaseDir ('xperf_' + $PhaseName + '.json'))
    $procmon = Read-JsonOrNull (Join-Path $PhaseDir ('procmon_' + $PhaseName + '_analyzed.json'))
    $latmon = Read-TextOrNull (Join-Path $PhaseDir ('latmon_' + $PhaseName + '_report.txt'))
    $presentmon = Read-TextOrNull (Join-Path $PhaseDir ('presentmon_' + $PhaseName + '.csv'))

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<section class="phase"><h2>' + (HtmlEscape $Title) + '</h2>')

    # Perf summary — pipeline.ps1 shape: perf.performance['% dpc time[_total]']
    if ($perf -and $perf.performance) {
        [void]$sb.AppendLine('<h3>Perf counters</h3><table class="perf">')
        [void]$sb.AppendLine('<tr><th>Counter</th><th>Avg</th><th>Min</th><th>Max</th><th>Stdev</th></tr>')
        $counters = @(
            @{ label = 'DPC Time %'; key = '% dpc time[_total]' },
            @{ label = 'Interrupt Time %'; key = '% interrupt time[_total]' },
            @{ label = 'Interrupts/sec total'; key = 'interrupts/sec[_total]' }
        )
        foreach ($c in $counters) {
            $val = $perf.performance.($c.key)
            if ($val) {
                [void]$sb.AppendLine('<tr><td>' + $c.label + '</td><td>' + $val.avg + '</td><td>' + $val.min + '</td><td>' + $val.max + '</td><td>' + $val.stdev + '</td></tr>')
            }
        }
        [void]$sb.AppendLine('</table>')
    } else {
        [void]$sb.AppendLine('<p class="skipped">Perf counters: missing</p>')
    }

    # xperf top CPU-consumer modules (from CPU Usage By Module)
    if ($xperf -and $xperf.top_drivers -and $xperf.top_drivers.Count -gt 0) {
        [void]$sb.AppendLine('<h3>Top 15 modules by total CPU usec</h3><table class="drivers">')
        [void]$sb.AppendLine('<tr><th>Module</th><th>Total usec (sum 16 CPUs)</th><th>Total %</th></tr>')
        $top = @($xperf.top_drivers) | Select-Object -First 15
        foreach ($d in $top) {
            [void]$sb.AppendLine('<tr><td>' + (HtmlEscape $d.driver) + '</td><td>' + $d.total_usec + '</td><td>' + $d.total_pct + '</td></tr>')
        }
        [void]$sb.AppendLine('</table>')
    }

    # LatencyMon summary or skipped
    if ($latmon) {
        $preview = if ($latmon.Length -gt 2000) { $latmon.Substring(0, 2000) + '...' } else { $latmon }
        [void]$sb.AppendLine('<h3>LatencyMon report</h3><pre class="latmon">' + (HtmlEscape $preview) + '</pre>')
    } else {
        [void]$sb.AppendLine('<p class="skipped"><span class="badge">LatencyMon skipped</span> (CLI preflight failed or disabled)</p>')
    }

    # ProcMon event rate
    if ($procmon) {
        [void]$sb.AppendLine('<h3>ProcMon event rate</h3>')
        [void]$sb.AppendLine('<p>Total events: <strong>' + $procmon.total_events + '</strong> over ' + $procmon.duration_sec + 's = ' + $procmon.events_per_sec + ' events/sec</p>')
    }

    # PresentMon frame stats
    if ($presentmon) {
        $lines = $presentmon -split "`n"
        $count = ($lines | Where-Object { $_ -ne '' }).Count
        [void]$sb.AppendLine('<h3>PresentMon frame samples</h3>')
        [void]$sb.AppendLine('<p>Samples captured: ' + $count + '</p>')
    }

    [void]$sb.AppendLine('</section>')
    return $sb.ToString()
}

function Build-DeltaSection {
    param([string]$AggregateDir)

    $delta = Read-JsonOrNull (Join-Path $AggregateDir 'delta_idle_vs_loaded.json')
    if (-not $delta) {
        return '<section class="phase"><h2>Delta idle vs loaded</h2><p class="skipped">Delta data not available</p></section>'
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<section class="phase"><h2>Delta: Idle vs Loaded</h2>')
    [void]$sb.AppendLine('<table class="delta"><tr><th>Metric</th><th>Idle</th><th>Loaded</th><th>Delta</th></tr>')

    if ($delta.PSObject.Properties['dpc_pct']) {
        $row = $delta.dpc_pct
        [void]$sb.AppendLine('<tr><td>DPC %</td><td>' + $row.idle + '</td><td>' + $row.loaded + '</td><td>' + $row.delta + '</td></tr>')
    }
    if ($delta.PSObject.Properties['interrupt_pct']) {
        $row = $delta.interrupt_pct
        [void]$sb.AppendLine('<tr><td>Interrupt %</td><td>' + $row.idle + '</td><td>' + $row.loaded + '</td><td>' + $row.delta + '</td></tr>')
    }
    if ($delta.PSObject.Properties['interrupts_per_sec']) {
        $row = $delta.interrupts_per_sec
        [void]$sb.AppendLine('<tr><td>Interrupts/sec</td><td>' + $row.idle + '</td><td>' + $row.loaded + '</td><td>' + $row.delta + '</td></tr>')
    }

    [void]$sb.AppendLine('</table></section>')
    return $sb.ToString()
}

function Build-ManifestSection {
    param([string]$RunDir)

    $manifest = Read-JsonOrNull (Join-Path $RunDir 'manifest.json')
    if (-not $manifest) {
        return '<section class="phase"><h2>Manifest</h2><p class="skipped">manifest.json missing</p></section>'
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<section class="phase"><h2>Manifest</h2>')
    [void]$sb.AppendLine('<pre class="manifest">' + (HtmlEscape (($manifest | ConvertTo-Json -Depth 10))) + '</pre>')
    [void]$sb.AppendLine('</section>')
    return $sb.ToString()
}

function Build-PrefreezeSection {
    param([string]$PrefreezeDir)

    $auditHtmlPath = Join-Path $PrefreezeDir 'audit_deep.html'
    if (Test-Path $auditHtmlPath) {
        # Inline the audit HTML via iframe to sandbox CSS
        $relPath = [IO.Path]::GetFileName($auditHtmlPath)
        return '<section class="phase"><h2>Pre-freeze audit</h2><iframe src="10_prefreeze/' + $relPath + '" style="width:100%;height:600px;border:1px solid #ccc;"></iframe></section>'
    }
    return '<section class="phase"><h2>Pre-freeze audit</h2><p class="skipped">audit_deep.html missing</p></section>'
}

# ── Build document ───────────────────────────────────────────────────────────

$cssPath = Join-Path $projectRoot 'dashboard\app.css'
$inlineCss = ''
if (Test-Path $cssPath) {
    $inlineCss = Get-Content $cssPath -Raw
}

$extraCss = @'
body { font-family: -apple-system, Segoe UI, sans-serif; margin: 2rem; max-width: 1200px; }
section.phase { border: 1px solid #ddd; border-radius: 6px; padding: 1rem 1.5rem; margin: 1rem 0; }
section.phase h2 { margin-top: 0; border-bottom: 2px solid #333; padding-bottom: 0.5rem; }
table { border-collapse: collapse; margin: 0.5rem 0; }
table th, table td { border: 1px solid #ccc; padding: 0.25rem 0.75rem; text-align: left; }
table th { background: #f5f5f5; }
.skipped { color: #888; font-style: italic; }
.badge { display: inline-block; background: #fa3; color: white; padding: 0.1rem 0.5rem; border-radius: 3px; font-size: 0.85em; }
pre.manifest, pre.latmon { background: #f8f8f8; padding: 1rem; border-radius: 4px; overflow-x: auto; font-size: 0.85em; max-height: 400px; overflow-y: auto; }
'@

$runLabel = Split-Path $InputDir -Leaf

$html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8">
<title>Baseline Report — $(HtmlEscape $runLabel)</title>
<style>$inlineCss
$extraCss</style>
</head><body>
<h1>Baseline Capture Report</h1>
<p><strong>Run:</strong> $(HtmlEscape $runLabel)<br/>
<strong>Generated:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
$(Build-PrefreezeSection -PrefreezeDir (Join-Path $InputDir '10_prefreeze'))
$(Build-PhaseSection -Title 'Idle baseline' -PhaseDir (Join-Path $InputDir '20_idle') -PhaseName 'idle')
$(Build-PhaseSection -Title 'Under-load baseline' -PhaseDir (Join-Path $InputDir '30_loaded') -PhaseName 'loaded')
$(Build-DeltaSection -AggregateDir (Join-Path $InputDir '40_aggregate'))
$(Build-ManifestSection -RunDir $InputDir)
</body></html>
"@

$outDir = Split-Path $OutputPath -Parent
if ($outDir -and -not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

Set-Content -Path $OutputPath -Value $html -Encoding UTF8
Write-Output ('MASTER.html written: ' + $OutputPath + ' (' + ([Math]::Round(((Get-Item $OutputPath).Length / 1KB), 1)) + ' KB)')
