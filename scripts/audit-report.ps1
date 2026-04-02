<#
.SYNOPSIS
    HTML report generation for audit.ps1 — Unified Latency Report v2.
.DESCRIPTION
    Dot-sourced by audit.ps1. Exposes New-AuditHtmlReport function.
    Adaptive rendering: audit-only = checklist, pipeline = full latency diagnostics.
    Output is fully self-contained (inline CSS + JS, no CDN, no fetch).
#>

Add-Type -AssemblyName System.Web

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Esc($text) { return [System.Web.HttpUtility]::HtmlEncode($text) }

function Get-ScoreColor($score) {
    if ($score -ge 80) { return '#10b981' }
    if ($score -ge 50) { return '#f59e0b' }
    return '#ef4444'
}

function Get-StatusColor($status) {
    if ($status -eq 'PASS')  { return '#10b981' }
    if ($status -eq 'FAIL')  { return '#ef4444' }
    if ($status -eq 'WARN')  { return '#f59e0b' }
    return '#64748b'
}

function Get-BarColor($valueUs) {
    if ($valueUs -lt 128)  { return '#10b981' }
    if ($valueUs -lt 512)  { return '#f59e0b' }
    return '#ef4444'
}

function Build-Placeholder($title, $message) {
    $h  = '<div class="panel placeholder-panel">'
    $h += '<div class="panel-title">' + (Esc $title) + '</div>'
    $h += '<div class="placeholder-msg">' + (Esc $message) + '</div>'
    $h += '</div>'
    return $h
}

# ---------------------------------------------------------------------------
# Panel Builders
# ---------------------------------------------------------------------------
function Build-HeroSection($PipelineData, $Summary) {
    $h = '<div class="hero">'

    # Check for frame timing data (from pipeline or input latency analysis)
    $ft = $null
    if ($null -ne $PipelineData) {
        if ($null -ne $PipelineData.frameTiming) { $ft = $PipelineData.frameTiming }
        if ($null -eq $ft -and $null -ne $PipelineData.inputLatency -and $null -ne $PipelineData.inputLatency.frameTiming) {
            $ft = $PipelineData.inputLatency.frameTiming
        }
    }

    if ($null -ne $ft -and $null -ne $ft.frameTimeMs) {
        # Hero P95 number
        $p95 = $ft.frameTimeMs.p95
        $p95Color = '#10b981'
        if ($p95 -gt 16) { $p95Color = '#ef4444' }
        elseif ($p95 -gt 8) { $p95Color = '#f59e0b' }
        $h += '<div class="hero-number" style="color:' + $p95Color + '">' + $p95 + '<span class="hero-unit">ms</span></div>'
        $h += '<div class="hero-label">P95 FRAME TIME</div>'
        $h += '<div class="hero-sub">P50: ' + $ft.frameTimeMs.p50 + 'ms &middot; P99: ' + $ft.frameTimeMs.p99 + 'ms'
        if ($null -ne $ft.fps) { $h += ' &middot; ' + $ft.fps.avg + ' FPS avg' }
        $h += '</div>'
        # Stutter count
        $stutterCount = 0
        if ($null -ne $ft.stutterCount) { $stutterCount = $ft.stutterCount }
        if ($stutterCount -gt 0) {
            $h += '<div class="hero-stutter">' + $stutterCount + ' stutter event(s) detected</div>'
        }
    } else {
        # Fallback: SVG score ring
        $scoreColor = Get-ScoreColor $Summary.score
        $circum = 339.29
        $dashLen = [math]::Round($circum * $Summary.score / 100, 1)
        $dashGap = [math]::Round($circum - $dashLen, 1)
        $h += '<div class="score-ring"><svg width="120" height="120" viewBox="0 0 120 120" style="transform:rotate(-90deg)">'
        $h += '<circle cx="60" cy="60" r="54" fill="none" stroke="var(--surface2)" stroke-width="8"/>'
        $h += '<circle cx="60" cy="60" r="54" fill="none" stroke="' + $scoreColor + '" stroke-width="8" stroke-linecap="round" stroke-dasharray="' + $dashLen + ' ' + $dashGap + '"/>'
        $h += '</svg><div class="score-num" style="color:' + $scoreColor + '">' + $Summary.score + '</div><div class="score-lbl">SCORE</div></div>'
    }

    # Summary pills
    $h += '<div class="pills">'
    $h += '<span class="pill pill-pass">' + $Summary.pass + ' pass</span>'
    if ($Summary.warn -gt 0) { $h += '<span class="pill pill-warn">' + $Summary.warn + ' warn</span>' }
    if ($Summary.fail -gt 0) { $h += '<span class="pill pill-fail">' + $Summary.fail + ' fail</span>' }
    if ($Summary.skip -gt 0) { $h += '<span class="pill pill-skip">' + $Summary.skip + ' skip</span>' }
    $h += '</div>'
    $h += '</div>'
    return $h
}

function Build-FrameDistPanel($FrameTiming) {
    if ($null -eq $FrameTiming -or $null -eq $FrameTiming.frameTimeMs) {
        return (Build-Placeholder 'Frame Time Distribution' 'Run pipeline.ps1 with -WPRProfile InputLatency to capture frame data')
    }
    $h = '<div class="panel">'
    $h += '<div class="panel-title">FRAME TIME DISTRIBUTION</div>'
    # Build histogram buckets: 0-4, 4-8, 8-12, 12-16, 16-20, 20+ ms
    $h += '<div class="panel-sub">P50: <span style="color:#10b981">' + $FrameTiming.frameTimeMs.p50 + 'ms</span>'
    $h += ' &middot; P95: <span style="color:#f59e0b">' + $FrameTiming.frameTimeMs.p95 + 'ms</span>'
    $h += ' &middot; P99: <span style="color:#ef4444">' + $FrameTiming.frameTimeMs.p99 + 'ms</span>'
    $h += ' &middot; Max: ' + $FrameTiming.frameTimeMs.max + 'ms</div>'
    if ($null -ne $FrameTiming.fps) {
        $h += '<div class="panel-sub">Avg FPS: ' + $FrameTiming.fps.avg
        if ($null -ne $FrameTiming.fps.p1Low) { $h += ' &middot; 1% Low: ' + $FrameTiming.fps.p1Low }
        $h += '</div>'
    }
    $h += '</div>'
    return $h
}

function Build-StutterPanel($FrameTiming) {
    if ($null -eq $FrameTiming) {
        return (Build-Placeholder 'Stutter Detection' 'Run pipeline.ps1 to capture frame timing data')
    }
    $stutterCount = 0
    if ($null -ne $FrameTiming.stutterCount) { $stutterCount = $FrameTiming.stutterCount }
    $h = '<div class="panel">'
    $h += '<div class="panel-title">STUTTER DETECTION</div>'
    if ($stutterCount -eq 0) {
        $h += '<div class="stutter-ok">No stutters detected</div>'
    } else {
        $h += '<div class="stutter-bad">' + $stutterCount + ' stutter event(s)</div>'
        $h += '<div class="panel-sub" style="color:#94a3b8">Frames exceeding 2x rolling median frame time</div>'
    }
    $h += '</div>'
    return $h
}

function Build-DpcBlamePanel($DpcDrivers) {
    if ($null -eq $DpcDrivers -or $DpcDrivers.Count -eq 0) {
        return (Build-Placeholder 'DPC Driver Blame' 'Run pipeline.ps1 to capture DPC/ISR data')
    }
    $h = '<div class="panel">'
    $h += '<div class="panel-title">DPC DRIVER BLAME</div>'
    # Take top 5 by MaxUs
    $top = @($DpcDrivers | Sort-Object { $_.MaxUs } -Descending | Select-Object -First 5)
    $maxVal = 1
    if ($top.Count -gt 0 -and $null -ne $top[0].MaxUs -and $top[0].MaxUs -gt 0) { $maxVal = $top[0].MaxUs }
    foreach ($d in $top) {
        $modName = $d.Module
        if ($null -eq $modName) { $modName = $d.module }
        $maxUs = 0
        if ($null -ne $d.MaxUs) { $maxUs = $d.MaxUs }
        if ($null -ne $d.maxUs) { $maxUs = $d.maxUs }
        $dpcCount = 0
        if ($null -ne $d.Count) { $dpcCount = $d.Count }
        if ($null -ne $d.count) { $dpcCount = $d.count }
        $barPct = [math]::Min(100, [math]::Round($maxUs / $maxVal * 100))
        $barColor = Get-BarColor $maxUs
        $h += '<div class="dpc-row">'
        $h += '<div class="dpc-bar-wrap"><div class="dpc-bar" style="width:' + $barPct + '%;background:' + $barColor + '"><span class="dpc-label">' + (Esc $modName) + '</span></div></div>'
        $h += '<span class="dpc-val">' + $maxUs + '&#181;s</span>'
        $h += '</div>'
    }
    # Alert line
    $anyHigh = $false
    foreach ($d in $DpcDrivers) {
        $mu = 0
        if ($null -ne $d.MaxUs) { $mu = $d.MaxUs }
        if ($null -ne $d.maxUs) { $mu = $d.maxUs }
        if ($mu -ge 512) { $anyHigh = $true }
    }
    if ($anyHigh) {
        $h += '<div class="dpc-alert">Driver DPC spikes detected (&gt;512&#181;s)</div>'
    } else {
        $h += '<div class="dpc-ok">All drivers under 512&#181;s threshold</div>'
    }
    $h += '</div>'
    return $h
}

function Build-SystemHealthPanel($Summary, $PipelineData) {
    $h = '<div class="panel">'
    $h += '<div class="panel-title">SYSTEM HEALTH</div>'
    $h += '<div class="health-grid">'
    # Audit score
    $sc = Get-ScoreColor $Summary.score
    $h += '<div class="health-item"><span class="health-dot" style="background:' + $sc + '"></span><span class="health-label">Audit Score</span><span class="health-val" style="color:' + $sc + '">' + $Summary.score + '%</span></div>'
    if ($null -ne $PipelineData -and $null -ne $PipelineData.cpuTotal) {
        $ct = $PipelineData.cpuTotal
        # DPC %
        $dpcPct = 0
        if ($null -ne $ct.dpcPct) { $dpcPct = [math]::Round($ct.dpcPct, 2) }
        $dpcColor = '#10b981'
        if ($dpcPct -gt 0.5) { $dpcColor = '#ef4444' }
        elseif ($dpcPct -gt 0.3) { $dpcColor = '#f59e0b' }
        $h += '<div class="health-item"><span class="health-dot" style="background:' + $dpcColor + '"></span><span class="health-label">Total DPC</span><span class="health-val">' + $dpcPct + '%</span></div>'
        # Interrupt %
        $intPct = 0
        if ($null -ne $ct.interruptPct) { $intPct = [math]::Round($ct.interruptPct, 2) }
        $intColor = '#10b981'
        if ($intPct -gt 1.0) { $intColor = '#ef4444' }
        elseif ($intPct -gt 0.5) { $intColor = '#f59e0b' }
        $h += '<div class="health-item"><span class="health-dot" style="background:' + $intColor + '"></span><span class="health-label">Total Interrupt</span><span class="health-val">' + $intPct + '%</span></div>'
        # CPU0 share
        $cpu0 = 0
        if ($null -ne $PipelineData.interruptTopology -and $null -ne $PipelineData.interruptTopology.cpu0Share) {
            $cpu0 = [math]::Round($PipelineData.interruptTopology.cpu0Share, 1)
        }
        $c0Color = '#10b981'
        if ($cpu0 -gt 10) { $c0Color = '#ef4444' }
        elseif ($cpu0 -gt 5) { $c0Color = '#f59e0b' }
        $h += '<div class="health-item"><span class="health-dot" style="background:' + $c0Color + '"></span><span class="health-label">CPU 0 Share</span><span class="health-val">' + $cpu0 + '%</span></div>'
    }
    $h += '</div></div>'
    return $h
}

function Build-AdvancedTab($PipelineData) {
    if ($null -eq $PipelineData) {
        return '<div class="adv-placeholder">Run pipeline.ps1 to populate the Advanced tab with ETW event counts, per-CPU interrupt data, and full DPC histograms.</div>'
    }
    $h = ''
    # ETW Provider Events
    if ($null -ne $PipelineData.inputLatency -and $null -ne $PipelineData.inputLatency.providerEventCounts) {
        $h += '<div class="adv-section"><div class="adv-title">ETW PROVIDER EVENTS</div><table class="adv-table"><thead><tr><th>Provider</th><th>Events</th></tr></thead><tbody>'
        $pec = $PipelineData.inputLatency.providerEventCounts
        foreach ($prop in $pec.PSObject.Properties) {
            $h += '<tr><td>' + (Esc $prop.Name) + '</td><td class="mono">' + $prop.Value + '</td></tr>'
        }
        $h += '</tbody></table></div>'
    }
    # Per-CPU data
    if ($null -ne $PipelineData.cpuData) {
        $h += '<div class="adv-section"><div class="adv-title">PER-CPU INTERRUPT / DPC</div><table class="adv-table"><thead><tr><th>CPU</th><th>Intr %</th><th>DPC %</th><th>Intr/s</th></tr></thead><tbody>'
        foreach ($cpu in $PipelineData.cpuData) {
            $cpuNum = $cpu.cpu
            $intP = 0; $dpcP = 0; $ips = 0
            if ($null -ne $cpu.interruptPct) { $intP = [math]::Round($cpu.interruptPct, 3) }
            if ($null -ne $cpu.dpcPct) { $dpcP = [math]::Round($cpu.dpcPct, 3) }
            if ($null -ne $cpu.intrPerSec) { $ips = [math]::Round($cpu.intrPerSec, 0) }
            $h += '<tr><td>CPU ' + $cpuNum + '</td><td class="mono">' + $intP + '</td><td class="mono">' + $dpcP + '</td><td class="mono">' + $ips + '</td></tr>'
        }
        $h += '</tbody></table></div>'
    }
    # DPC histogram
    if ($null -ne $PipelineData.dpcIsrAnalysis -and $null -ne $PipelineData.dpcIsrAnalysis.dpcDrivers) {
        $h += '<div class="adv-section"><div class="adv-title">DPC DRIVERS (TOP 10)</div><table class="adv-table"><thead><tr><th>Module</th><th>Count</th><th>Max &#181;s</th></tr></thead><tbody>'
        foreach ($d in $PipelineData.dpcIsrAnalysis.dpcDrivers) {
            $modName = $d.Module
            if ($null -eq $modName) { $modName = $d.module }
            $maxUs = 0
            if ($null -ne $d.MaxUs) { $maxUs = $d.MaxUs }
            if ($null -ne $d.maxUs) { $maxUs = $d.maxUs }
            $cnt = 0
            if ($null -ne $d.Count) { $cnt = $d.Count }
            if ($null -ne $d.count) { $cnt = $d.count }
            $rowColor = Get-BarColor $maxUs
            $h += '<tr><td style="color:' + $rowColor + '">' + (Esc $modName) + '</td><td class="mono">' + $cnt + '</td><td class="mono" style="color:' + $rowColor + '">' + $maxUs + '</td></tr>'
        }
        $h += '</tbody></table></div>'
    }
    return $h
}

function Build-CompareTab($History) {
    if ($null -eq $History -or $History.Count -lt 2) {
        return '<div class="adv-placeholder">Run the audit at least twice to compare results. Each run appends to the score history.</div>'
    }
    $latest = $History[$History.Count - 1]
    $prev   = $History[$History.Count - 2]
    $latestColor = Get-ScoreColor $latest.score
    $prevColor   = Get-ScoreColor $prev.score
    $delta = $latest.score - $prev.score
    $deltaSign = '+'
    $deltaColor = '#10b981'
    if ($delta -lt 0) { $deltaSign = ''; $deltaColor = '#ef4444' }
    elseif ($delta -eq 0) { $deltaSign = ''; $deltaColor = '#64748b' }

    $h  = '<div class="compare-grid">'
    $h += '<div class="compare-card"><div class="compare-label">PREVIOUS</div>'
    $h += '<div class="compare-score" style="color:' + $prevColor + '">' + $prev.score + '%</div>'
    $h += '<div class="compare-date">' + $prev.timestamp + '</div></div>'
    $h += '<div class="compare-card"><div class="compare-label">LATEST</div>'
    $h += '<div class="compare-score" style="color:' + $latestColor + '">' + $latest.score + '%</div>'
    $h += '<div class="compare-date">' + $latest.timestamp + '</div></div>'
    $h += '</div>'
    $h += '<div class="compare-delta" style="color:' + $deltaColor + '">' + $deltaSign + $delta + ' points</div>'
    return $h
}

function Build-ChecklistSection($Checks, $Summary) {
    $sortOrder = @{ 'FAIL'=0; 'WARN'=1; 'ERROR'=2; 'SKIP'=3; 'PASS'=4 }
    $sorted = $Checks | Sort-Object { $sortOrder[$_.status] }

    # Filter bar
    $h = '<div class="filter-bar">'
    $h += '<button class="filter-btn active" data-filter="all" onclick="filterRows(''all'')">All (' + $Summary.total + ')</button>'
    if ($Summary.fail -gt 0) { $h += '<button class="filter-btn" data-filter="fail" onclick="filterRows(''fail'')">Fail (' + $Summary.fail + ')</button>' }
    if ($Summary.warn -gt 0) { $h += '<button class="filter-btn" data-filter="warn" onclick="filterRows(''warn'')">Warn (' + $Summary.warn + ')</button>' }
    $h += '<button class="filter-btn" data-filter="pass" onclick="filterRows(''pass'')">Pass (' + $Summary.pass + ')</button>'
    $h += '</div>'

    # Table
    $h += '<div class="results"><table><thead><tr>'
    $h += '<th style="width:56px">Status</th><th>Check</th><th>Category</th><th>Severity</th><th>Current Value</th>'
    $h += '</tr></thead><tbody>'

    $rowIdx = 0
    foreach ($check in $sorted) {
        $rowIdx++
        $color = Get-StatusColor $check.status
        $detailId = 'detail-' + $rowIdx
        $dataStatus = $check.status.ToLower()

        $sevClass = 'sev-info'
        if ($check.severity -eq 'CRITICAL') { $sevClass = 'sev-critical' }
        elseif ($check.severity -eq 'HIGH')  { $sevClass = 'sev-high' }
        elseif ($check.severity -eq 'MEDIUM') { $sevClass = 'sev-medium' }
        elseif ($check.severity -eq 'LOW')   { $sevClass = 'sev-low' }

        $h += '<tr class="check-row" data-status="' + $dataStatus + '" onclick="toggleDetail(''' + $detailId + ''')">'
        $h += '<td class="status-cell" style="color:' + $color + '">' + $check.status + '</td>'
        $h += '<td class="name-cell">' + (Esc $check.name) + '</td>'
        $h += '<td class="cat-cell">' + $check.category + '</td>'
        $h += '<td><span class="sev-badge ' + $sevClass + '">' + $check.severity + '</span></td>'
        $h += '<td class="val-cell">' + (Esc $check.current) + '</td></tr>'

        $h += '<tr id="' + $detailId + '" class="detail-row" data-status="' + $dataStatus + '">'
        $h += '<td colspan="5"><div class="detail-inner">'
        if ($check.message -ne '') { $h += '<p class="detail-msg">' + (Esc $check.message) + '</p>' }
        $h += '<div class="detail-meta"><span class="meta-label">Expected:</span> <span class="meta-val">' + (Esc $check.expected) + '</span></div>'
        if ($check.fix -ne '' -and $null -ne $check.fix) {
            $escapedFix = (Esc $check.fix)
            $h += '<div class="fix-block"><pre class="fix-code">' + $escapedFix + '</pre>'
            $h += '<button class="copy-btn" onclick="event.stopPropagation();copyFix(this)" data-fix="' + $escapedFix.Replace('"','&quot;') + '">Copy</button></div>'
        }
        if ($check.fixNote -ne '' -and $null -ne $check.fixNote) { $h += '<p class="fix-note">&#9888; ' + (Esc $check.fixNote) + '</p>' }
        if ($check.source -ne '' -and $null -ne $check.source) { $h += '<a class="source-link" href="' + $check.source + '" target="_blank" onclick="event.stopPropagation()">Source &#8599;</a>' }
        $h += '</div></td></tr>'
    }
    $h += '</tbody></table></div>'
    return $h
}

# ---------------------------------------------------------------------------
# Main Report Function
# ---------------------------------------------------------------------------
function New-AuditHtmlReport {
    param(
        [hashtable]$Summary,
        [array]$Checks,
        [hashtable]$SystemInfo,
        [string]$AuditedAt,
        [string]$Mode,
        [string]$FixScriptPath = '',
        [array]$History = @(),
        $PipelineData = $null
    )

    # Resolve DPC drivers from pipeline data
    $dpcDrivers = $null
    if ($null -ne $PipelineData -and $null -ne $PipelineData.dpcIsrAnalysis -and $null -ne $PipelineData.dpcIsrAnalysis.dpcDrivers) {
        $dpcDrivers = $PipelineData.dpcIsrAnalysis.dpcDrivers
    }

    # Resolve frame timing
    $ft = $null
    if ($null -ne $PipelineData) {
        if ($null -ne $PipelineData.frameTiming) { $ft = $PipelineData.frameTiming }
        if ($null -eq $ft -and $null -ne $PipelineData.inputLatency -and $null -ne $PipelineData.inputLatency.frameTiming) {
            $ft = $PipelineData.inputLatency.frameTiming
        }
    }

    # Build all sections
    $heroHtml      = Build-HeroSection $PipelineData $Summary
    $frameDistHtml = Build-FrameDistPanel $ft
    $stutterHtml   = Build-StutterPanel $ft
    $dpcBlameHtml  = Build-DpcBlamePanel $dpcDrivers
    $healthHtml    = Build-SystemHealthPanel $Summary $PipelineData
    $advancedHtml  = Build-AdvancedTab $PipelineData
    $compareHtml   = Build-CompareTab $History
    $checklistHtml = Build-ChecklistSection $Checks $Summary

    # Pipeline source label
    $pipelineLabel = ''
    if ($null -ne $PipelineData -and $null -ne $PipelineData.label) {
        $pipelineLabel = ' &middot; Pipeline: ' + (Esc $PipelineData.label)
    }

    # --- Assemble HTML ---
    $html = '<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">'
    $html += '<meta name="viewport" content="width=device-width,initial-scale=1">'
    $html += '<title>Latency Audit ' + $Summary.score + '% — ' + $AuditedAt + '</title>'
    $html += '<style>'
    $html += ':root{--bg:#0b1120;--surface:#111827;--surface2:#1c2840;--border:#1e3a5f;--text:#e2e8f0;--muted:#7a8fa8;--green:#10b981;--amber:#f59e0b;--red:#ef4444;--blue:#3b82f6}'
    $html += '*{box-sizing:border-box;margin:0;padding:0}'
    $html += 'body{font-family:"Segoe UI",system-ui,sans-serif;background:var(--bg);color:var(--text);padding:24px 16px;line-height:1.5}'
    $html += '.wrap{max-width:1100px;margin:0 auto}'
    # Hero
    $html += '.hero{text-align:center;padding:24px 0 20px}'
    $html += '.hero-number{font-size:64px;font-weight:900;letter-spacing:-2px}'
    $html += '.hero-unit{font-size:24px;color:var(--muted)}'
    $html += '.hero-label{font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:1.5px}'
    $html += '.hero-sub{font-size:13px;color:var(--muted);margin-top:6px}'
    $html += '.hero-stutter{font-size:12px;color:var(--red);margin-top:6px}'
    $html += '.score-ring{position:relative;width:120px;height:120px;margin:0 auto}'
    $html += '.score-num{position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);font-size:32px;font-weight:800}'
    $html += '.score-lbl{position:absolute;top:50%;left:50%;transform:translate(-50%,16px);font-size:10px;color:var(--muted);text-transform:uppercase;letter-spacing:1px}'
    # Pills
    $html += '.pills{display:flex;gap:8px;justify-content:center;margin-top:12px;flex-wrap:wrap}'
    $html += '.pill{padding:3px 10px;border-radius:10px;font-size:11px;font-weight:600}'
    $html += '.pill-pass{background:rgba(16,185,129,.12);color:var(--green)}'
    $html += '.pill-warn{background:rgba(245,158,11,.12);color:var(--amber)}'
    $html += '.pill-fail{background:rgba(239,68,68,.12);color:var(--red)}'
    $html += '.pill-skip{background:rgba(100,116,139,.12);color:var(--muted)}'
    # System info bar
    $html += '.sys-bar{display:flex;gap:16px;flex-wrap:wrap;padding:10px 16px;background:var(--surface);border:1px solid var(--border);border-radius:8px;margin-bottom:16px;font-size:12px}'
    $html += '.sys-item{display:flex;gap:6px;align-items:center}'
    $html += '.sys-label{color:var(--muted);font-size:10px;text-transform:uppercase;letter-spacing:.5px}'
    $html += '.sys-val{color:var(--text);font-family:Consolas,monospace;font-size:11px}'
    # Tabs
    $html += '.tab-bar{display:flex;border-bottom:2px solid var(--border);margin-bottom:16px}'
    $html += '.tab-btn{padding:10px 24px;font-size:13px;font-weight:600;color:var(--muted);cursor:pointer;border:none;background:none;border-bottom:2px solid transparent;margin-bottom:-2px}'
    $html += '.tab-btn:hover{color:var(--text)}'
    $html += '.tab-btn.active{color:var(--blue);border-bottom-color:var(--blue)}'
    $html += '.tab-content{display:none}.tab-content.active{display:block}'
    # Panels
    $html += '.panel-grid{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:16px}'
    $html += '.panel{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:14px 16px}'
    $html += '.panel-title{font-size:10px;color:var(--muted);text-transform:uppercase;letter-spacing:1px;margin-bottom:10px;font-weight:600}'
    $html += '.panel-sub{font-size:12px;color:var(--muted);margin-top:6px}'
    $html += '.placeholder-panel{display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:100px}'
    $html += '.placeholder-msg{font-size:12px;color:var(--muted);text-align:center;margin-top:8px}'
    # DPC bars
    $html += '.dpc-row{display:flex;align-items:center;gap:8px;margin-bottom:6px}'
    $html += '.dpc-bar-wrap{flex:1;background:var(--surface2);border-radius:3px;overflow:hidden;height:20px}'
    $html += '.dpc-bar{height:100%;display:flex;align-items:center;padding-left:6px;border-radius:3px;min-width:40px}'
    $html += '.dpc-label{font-size:10px;color:var(--text);white-space:nowrap}'
    $html += '.dpc-val{font-size:11px;color:var(--muted);min-width:55px;text-align:right}'
    $html += '.dpc-ok{font-size:10px;color:var(--green);margin-top:8px}'
    $html += '.dpc-alert{font-size:10px;color:var(--red);margin-top:8px}'
    # Health
    $html += '.health-grid{display:grid;grid-template-columns:1fr 1fr;gap:8px}'
    $html += '.health-item{display:flex;align-items:center;gap:6px;font-size:12px}'
    $html += '.health-dot{width:8px;height:8px;border-radius:50%;flex-shrink:0}'
    $html += '.health-label{color:var(--muted);flex:1}'
    $html += '.health-val{font-family:Consolas,monospace;font-weight:600}'
    # Stutter
    $html += '.stutter-ok{font-size:16px;color:var(--green);font-weight:600}'
    $html += '.stutter-bad{font-size:16px;color:var(--red);font-weight:600}'
    # Filter + table
    $html += '.filter-bar{display:flex;gap:6px;margin-bottom:12px;flex-wrap:wrap}'
    $html += '.filter-btn{padding:5px 14px;border-radius:16px;border:1px solid var(--border);background:transparent;color:var(--muted);font-size:11px;font-weight:600;cursor:pointer;transition:all .15s}'
    $html += '.filter-btn:hover{border-color:var(--blue);color:#93c5fd}'
    $html += '.filter-btn.active{background:rgba(59,130,246,.15);border-color:var(--blue);color:#93c5fd}'
    $html += '.results{background:var(--surface);border:1px solid var(--border);border-radius:10px;overflow:hidden}'
    $html += 'table{width:100%;border-collapse:collapse}'
    $html += 'th{text-align:left;padding:10px 12px;font-size:10px;font-weight:600;color:var(--muted);text-transform:uppercase;letter-spacing:.8px;border-bottom:1px solid var(--border);background:var(--surface);position:sticky;top:0;z-index:1}'
    $html += '.check-row{cursor:pointer;border-bottom:1px solid rgba(30,58,95,.4);transition:background .1s}'
    $html += '.check-row:hover{background:rgba(59,130,246,.04)}'
    $html += '.status-cell{padding:10px 12px;font-size:11px;font-weight:700;width:56px}'
    $html += '.name-cell{padding:10px 12px;font-size:13px;font-weight:500}'
    $html += '.cat-cell{padding:10px 12px;font-size:11px;color:var(--muted)}'
    $html += '.val-cell{padding:10px 12px;font-size:11px;color:var(--muted);max-width:240px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}'
    $html += '.sev-badge{padding:2px 8px;border-radius:10px;font-size:10px;font-weight:600}'
    $html += '.sev-critical{background:#7f1d1d;color:#fca5a5}.sev-high{background:#7c2d12;color:#fdba74}.sev-medium{background:#713f12;color:#fde68a}.sev-low{background:#1e3a5f;color:#93c5fd}.sev-info{background:#374151;color:#9ca3af}'
    $html += '.detail-row{display:none;background:var(--bg)}.detail-row.open{display:table-row}'
    $html += '.detail-inner{padding:14px 16px 14px 70px}'
    $html += '.detail-msg{color:#d1d5db;font-size:13px;margin-bottom:10px}'
    $html += '.detail-meta{font-size:11px;margin-bottom:10px;color:var(--muted)}'
    $html += '.meta-label{color:var(--muted)}.meta-val{color:var(--text)}'
    $html += '.fix-block{position:relative;margin:8px 0}'
    $html += '.fix-code{background:#0c1222;color:#86efac;padding:10px 14px;border-radius:6px;font-size:11px;font-family:Consolas,monospace;overflow-x:auto;white-space:pre-wrap;word-break:break-all;border:1px solid var(--border)}'
    $html += '.copy-btn{position:absolute;top:6px;right:6px;padding:3px 10px;border-radius:4px;border:1px solid var(--border);background:var(--surface2);color:var(--muted);font-size:10px;cursor:pointer}'
    $html += '.copy-btn:hover{color:var(--text);border-color:var(--blue)}'
    $html += '.fix-note{color:var(--amber);font-size:11px;margin:6px 0}'
    $html += '.source-link{color:var(--blue);font-size:11px;text-decoration:none}'
    # Advanced
    $html += '.adv-section{margin-bottom:20px}'
    $html += '.adv-title{font-size:10px;color:var(--muted);text-transform:uppercase;letter-spacing:1px;font-weight:600;margin-bottom:8px}'
    $html += '.adv-table{width:100%;border-collapse:collapse;background:var(--surface);border:1px solid var(--border);border-radius:8px;overflow:hidden}'
    $html += '.adv-table th{text-align:left;padding:8px 12px;font-size:10px;color:var(--muted);border-bottom:1px solid var(--border)}'
    $html += '.adv-table td{padding:6px 12px;font-size:12px;border-bottom:1px solid rgba(30,58,95,.3)}'
    $html += '.adv-placeholder{text-align:center;padding:40px;color:var(--muted);font-size:13px}'
    $html += '.mono{font-family:Consolas,monospace}'
    # Compare
    $html += '.compare-grid{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-bottom:16px}'
    $html += '.compare-card{text-align:center;padding:20px;background:var(--surface);border:1px solid var(--border);border-radius:8px}'
    $html += '.compare-label{font-size:10px;color:var(--muted);text-transform:uppercase;letter-spacing:1px}'
    $html += '.compare-score{font-size:40px;font-weight:800;margin:8px 0}'
    $html += '.compare-date{font-size:11px;color:var(--muted)}'
    $html += '.compare-delta{text-align:center;font-size:14px;font-weight:600}'
    # Footer
    $html += '.footer{margin-top:24px;padding-top:16px;border-top:1px solid var(--border);display:flex;justify-content:space-between;flex-wrap:wrap;gap:8px;font-size:11px;color:var(--muted)}'
    # Responsive
    $html += '@media(max-width:700px){.panel-grid{grid-template-columns:1fr}.compare-grid{grid-template-columns:1fr}.detail-inner{padding:12px}}'
    $html += '</style>'

    # JavaScript
    $html += '<script>'
    $html += 'function switchTab(name){document.querySelectorAll(".tab-btn").forEach(function(b){b.classList.toggle("active",b.dataset.tab===name)});document.querySelectorAll(".tab-content").forEach(function(c){c.classList.toggle("active",c.id==="tab-"+name)});}'
    $html += 'function toggleDetail(id){document.getElementById(id).classList.toggle("open");}'
    $html += 'function filterRows(status){document.querySelectorAll(".filter-btn").forEach(function(b){b.classList.toggle("active",b.dataset.filter===status)});document.querySelectorAll(".check-row").forEach(function(r){var s=r.dataset.status;var show=(status==="all"||s===status);r.style.display=show?"":"none";var next=r.nextElementSibling;if(next&&next.classList.contains("detail-row")){if(!show){next.classList.remove("open")}next.style.display=show?"":"none";}});}'
    $html += 'function copyFix(btn){var t=btn.dataset.fix;var ta=document.createElement("textarea");ta.value=t.replace(/&amp;/g,"&").replace(/&lt;/g,"<").replace(/&gt;/g,">").replace(/&quot;/g,''"'');document.body.appendChild(ta);ta.select();document.execCommand("copy");document.body.removeChild(ta);btn.textContent="Copied!";setTimeout(function(){btn.textContent="Copy"},1500);}'
    $html += '</script>'
    $html += '</head><body><div class="wrap">'

    # System info bar
    $html += '<div class="sys-bar">'
    $html += '<div class="sys-item"><span class="sys-label">CPU</span><span class="sys-val">' + (Esc $SystemInfo.cpu) + '</span></div>'
    $html += '<div class="sys-item"><span class="sys-label">GPU</span><span class="sys-val">' + (Esc $SystemInfo.gpu) + '</span></div>'
    $html += '<div class="sys-item"><span class="sys-label">RAM</span><span class="sys-val">' + (Esc $SystemInfo.ram) + '</span></div>'
    $html += '<div class="sys-item"><span class="sys-label">NIC</span><span class="sys-val">' + (Esc $SystemInfo.nic) + '</span></div>'
    $html += '</div>'

    # Hero
    $html += $heroHtml

    # Tab bar
    $html += '<div class="tab-bar">'
    $html += '<button class="tab-btn active" data-tab="overview" onclick="switchTab(''overview'')">Overview</button>'
    $html += '<button class="tab-btn" data-tab="advanced" onclick="switchTab(''advanced'')">Advanced</button>'
    $html += '<button class="tab-btn" data-tab="compare" onclick="switchTab(''compare'')">Compare</button>'
    $html += '</div>'

    # Overview tab
    $html += '<div id="tab-overview" class="tab-content active">'
    $html += '<div class="panel-grid">'
    $html += $frameDistHtml
    $html += $stutterHtml
    $html += $dpcBlameHtml
    $html += $healthHtml
    $html += '</div>'
    $html += '<div style="margin-top:8px">' + $checklistHtml + '</div>'
    $html += '</div>'

    # Advanced tab
    $html += '<div id="tab-advanced" class="tab-content">' + $advancedHtml + '</div>'

    # Compare tab
    $html += '<div id="tab-compare" class="tab-content">' + $compareHtml + '</div>'

    # Footer
    $html += '<div class="footer">'
    $html += '<span>windows-latency-optimizer &bull; Read-only audit &mdash; no system changes made</span>'
    $html += '<span>Mode: ' + $Mode + ' &bull; ' + $AuditedAt + $pipelineLabel + '</span>'
    $html += '</div>'

    $html += '</div></body></html>'
    return $html
}
