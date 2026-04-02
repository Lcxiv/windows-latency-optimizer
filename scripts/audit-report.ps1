<#
.SYNOPSIS
    HTML report generation for audit.ps1.
.DESCRIPTION
    Dot-sourced by audit.ps1. Exposes New-AuditHtmlReport function.
    Output is fully self-contained (inline CSS + JS, no CDN, no fetch).
#>

Add-Type -AssemblyName System.Web

function New-AuditHtmlReport {
    param(
        [hashtable]$Summary,
        [array]$Checks,
        [hashtable]$SystemInfo,
        [string]$AuditedAt,
        [string]$Mode,
        [string]$FixScriptPath = '',
        [array]$History = @()
    )

    # --- Helpers ---
    function Get-StatusColor($status) {
        if ($status -eq 'PASS')  { return '#10b981' }
        if ($status -eq 'FAIL')  { return '#ef4444' }
        if ($status -eq 'WARN')  { return '#f59e0b' }
        if ($status -eq 'SKIP')  { return '#64748b' }
        if ($status -eq 'ERROR') { return '#64748b' }
        return '#64748b'
    }
    function Get-ScoreColor($score) {
        if ($score -ge 80) { return '#10b981' }
        if ($score -ge 50) { return '#f59e0b' }
        return '#ef4444'
    }
    function Esc($text) {
        return [System.Web.HttpUtility]::HtmlEncode($text)
    }

    $scoreColor = Get-ScoreColor $Summary.score

    # SVG score ring: circumference = 2 * pi * 54 = 339.29
    $circum    = 339.29
    $dashLen   = [math]::Round($circum * $Summary.score / 100, 1)
    $dashGap   = [math]::Round($circum - $dashLen, 1)

    # Sort checks: FAIL first, then WARN, ERROR, SKIP, PASS
    $sortOrder = @{ 'FAIL'=0; 'WARN'=1; 'ERROR'=2; 'SKIP'=3; 'PASS'=4 }
    $sorted    = $Checks | Sort-Object { $sortOrder[$_.status] }

    # --- Category cards ---
    $cats = @('OS','NIC','GPU','Memory','Peripheral','Network')
    $catHtml = ''
    foreach ($cat in $cats) {
        $catChecks = @($Checks | Where-Object { $_.category -eq $cat })
        $catPass   = @($catChecks | Where-Object { $_.status -eq 'PASS' }).Count
        $catTotal  = @($catChecks | Where-Object { $_.status -ne 'SKIP' -and $_.status -ne 'ERROR' }).Count
        $catFail   = @($catChecks | Where-Object { $_.status -eq 'FAIL' }).Count
        $catWarn   = @($catChecks | Where-Object { $_.status -eq 'WARN' }).Count
        $catScore  = 0
        if ($catTotal -gt 0) { $catScore = [math]::Round(($catPass / $catTotal) * 100) }
        $catColor  = Get-ScoreColor $catScore
        $catHtml += '<div class="cat-card" style="border-top:3px solid ' + $catColor + '">'
        $catHtml += '<div class="cat-score" style="color:' + $catColor + '">' + $catScore + '%</div>'
        $catHtml += '<div class="cat-name">' + $cat + '</div>'
        $catHtml += '<div class="cat-detail">' + $catPass + '/' + $catTotal + ' pass'
        if ($catFail -gt 0) { $catHtml += ' &middot; <span style="color:#ef4444">' + $catFail + ' fail</span>' }
        if ($catWarn -gt 0) { $catHtml += ' &middot; <span style="color:#f59e0b">' + $catWarn + ' warn</span>' }
        $catHtml += '</div></div>'
    }

    # --- Results table rows ---
    $rowHtml = ''
    $rowIdx  = 0
    foreach ($check in $sorted) {
        $rowIdx++
        $color    = Get-StatusColor $check.status
        $detailId = 'detail-' + $rowIdx
        $dataStatus = $check.status.ToLower()

        # Severity badge class
        $sevClass = 'sev-info'
        if ($check.severity -eq 'CRITICAL') { $sevClass = 'sev-critical' }
        elseif ($check.severity -eq 'HIGH')  { $sevClass = 'sev-high' }
        elseif ($check.severity -eq 'MEDIUM') { $sevClass = 'sev-medium' }
        elseif ($check.severity -eq 'LOW')   { $sevClass = 'sev-low' }

        $rowHtml += '<tr class="check-row" data-status="' + $dataStatus + '" onclick="toggleDetail(''' + $detailId + ''')">'
        $rowHtml += '<td class="status-cell" style="color:' + $color + '">' + $check.status + '</td>'
        $rowHtml += '<td class="name-cell">' + (Esc $check.name) + '</td>'
        $rowHtml += '<td class="cat-cell">' + $check.category + '</td>'
        $rowHtml += '<td><span class="sev-badge ' + $sevClass + '">' + $check.severity + '</span></td>'
        $rowHtml += '<td class="val-cell">' + (Esc $check.current) + '</td>'
        $rowHtml += '</tr>'

        # Expandable detail row
        $rowHtml += '<tr id="' + $detailId + '" class="detail-row" data-status="' + $dataStatus + '">'
        $rowHtml += '<td colspan="5"><div class="detail-inner">'
        if ($check.message -ne '') {
            $rowHtml += '<p class="detail-msg">' + (Esc $check.message) + '</p>'
        }
        $rowHtml += '<div class="detail-meta">'
        $rowHtml += '<span class="meta-label">Current:</span> <span class="meta-val">' + (Esc $check.current) + '</span>'
        $rowHtml += '<span class="meta-sep">|</span>'
        $rowHtml += '<span class="meta-label">Expected:</span> <span class="meta-val">' + (Esc $check.expected) + '</span>'
        $rowHtml += '</div>'
        if ($check.fix -ne '' -and $null -ne $check.fix) {
            $escapedFix = (Esc $check.fix)
            $rowHtml += '<div class="fix-block">'
            $rowHtml += '<pre class="fix-code">' + $escapedFix + '</pre>'
            $rowHtml += '<button class="copy-btn" onclick="event.stopPropagation();copyFix(this)" data-fix="' + $escapedFix.Replace('"','&quot;') + '">Copy</button>'
            $rowHtml += '</div>'
        }
        if ($check.fixNote -ne '' -and $null -ne $check.fixNote) {
            $rowHtml += '<p class="fix-note">&#9888; ' + (Esc $check.fixNote) + '</p>'
        }
        if ($check.source -ne '' -and $null -ne $check.source) {
            $rowHtml += '<a class="source-link" href="' + $check.source + '" target="_blank" onclick="event.stopPropagation()">Source &#8599;</a>'
        }
        $rowHtml += '</div></td></tr>'
    }

    # --- Sparkline from history ---
    $sparkHtml = ''
    if ($History.Count -gt 1) {
        $sparkW   = 200
        $sparkH   = 40
        $maxPts   = 20
        $pts      = $History
        if ($pts.Count -gt $maxPts) { $pts = $pts[($pts.Count - $maxPts)..($pts.Count - 1)] }
        $step     = $sparkW / ([math]::Max($pts.Count - 1, 1))
        $pathParts = @()
        for ($i = 0; $i -lt $pts.Count; $i++) {
            $x = [math]::Round($i * $step, 1)
            $y = [math]::Round($sparkH - ($pts[$i].score * $sparkH / 100), 1)
            $prefix = 'L'
            if ($i -eq 0) { $prefix = 'M' }
            $pathParts += ($prefix + $x + ',' + $y)
        }
        $pathD = $pathParts -join ' '
        $lastScore = $pts[$pts.Count - 1].score
        $sparkColor = Get-ScoreColor $lastScore
        $sparkHtml  = '<div class="spark-section">'
        $sparkHtml += '<div class="spark-label">SCORE TREND</div>'
        $sparkHtml += '<svg width="' + $sparkW + '" height="' + $sparkH + '" viewBox="0 0 ' + $sparkW + ' ' + $sparkH + '">'
        $sparkHtml += '<path d="' + $pathD + '" fill="none" stroke="' + $sparkColor + '" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>'
        $sparkHtml += '</svg>'
        $sparkHtml += '<div class="spark-dates">'
        $sparkHtml += '<span>' + $pts[0].timestamp.Substring(0,10) + '</span>'
        $sparkHtml += '<span>' + $pts[$pts.Count - 1].timestamp.Substring(0,10) + '</span>'
        $sparkHtml += '</div></div>'
    }

    # --- Build full HTML ---
    $html = '<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">'
    $html += '<meta name="viewport" content="width=device-width,initial-scale=1">'
    $html += '<title>Latency Audit ' + $Summary.score + '% — ' + $AuditedAt + '</title>'
    $html += '<style>'

    # CSS
    $html += ':root{--bg:#0b1120;--surface:#111827;--surface2:#1c2840;--border:#1e3a5f;--text:#e2e8f0;--muted:#7a8fa8;--green:#10b981;--amber:#f59e0b;--red:#ef4444;--blue:#3b82f6}'
    $html += '*{box-sizing:border-box;margin:0;padding:0}'
    $html += 'body{font-family:"Segoe UI",system-ui,-apple-system,sans-serif;background:var(--bg);color:var(--text);padding:24px 16px;line-height:1.5}'
    $html += '.wrap{max-width:1100px;margin:0 auto}'

    # Header
    $html += '.header{display:flex;align-items:center;gap:24px;margin-bottom:24px;flex-wrap:wrap}'
    $html += '.score-ring{flex-shrink:0}'
    $html += '.score-ring svg{transform:rotate(-90deg)}'
    $html += '.score-ring .track{fill:none;stroke:var(--surface2);stroke-width:8}'
    $html += '.score-ring .bar{fill:none;stroke-width:8;stroke-linecap:round;transition:stroke-dasharray .6s}'
    $html += '.score-num{position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);font-size:32px;font-weight:800;letter-spacing:-1px}'
    $html += '.score-label{position:absolute;top:50%;left:50%;transform:translate(-50%,14px);font-size:10px;color:var(--muted);text-transform:uppercase;letter-spacing:1px}'
    $html += '.header-info h1{font-size:20px;font-weight:700;letter-spacing:.3px}'
    $html += '.header-info p{color:var(--muted);font-size:13px;margin-top:3px}'

    # Pill badges
    $html += '.pills{display:flex;gap:8px;margin-top:8px;flex-wrap:wrap}'
    $html += '.pill{display:inline-flex;align-items:center;gap:4px;padding:3px 10px;border-radius:10px;font-size:11px;font-weight:600}'
    $html += '.pill-pass{background:rgba(16,185,129,.12);color:var(--green)}'
    $html += '.pill-warn{background:rgba(245,158,11,.12);color:var(--amber)}'
    $html += '.pill-fail{background:rgba(239,68,68,.12);color:var(--red)}'
    $html += '.pill-skip{background:rgba(100,116,139,.12);color:var(--muted)}'

    # System info bar
    $html += '.sys-bar{display:flex;gap:16px;flex-wrap:wrap;padding:10px 16px;background:var(--surface);border:1px solid var(--border);border-radius:8px;margin-bottom:20px;font-size:12px}'
    $html += '.sys-item{display:flex;gap:6px;align-items:center}'
    $html += '.sys-label{color:var(--muted);text-transform:uppercase;font-size:10px;letter-spacing:.5px}'
    $html += '.sys-val{color:var(--text);font-family:Consolas,monospace;font-size:11px}'

    # Category cards
    $html += '.cat-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px;margin-bottom:20px}'
    $html += '.cat-card{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:12px 14px;text-align:center}'
    $html += '.cat-score{font-size:24px;font-weight:800}'
    $html += '.cat-name{font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.8px;margin-top:2px}'
    $html += '.cat-detail{font-size:10px;color:var(--muted);margin-top:4px}'

    # Filter bar
    $html += '.filter-bar{display:flex;gap:6px;margin-bottom:12px;flex-wrap:wrap}'
    $html += '.filter-btn{padding:5px 14px;border-radius:16px;border:1px solid var(--border);background:transparent;color:var(--muted);font-size:11px;font-weight:600;cursor:pointer;transition:all .15s}'
    $html += '.filter-btn:hover{border-color:var(--blue);color:#93c5fd}'
    $html += '.filter-btn.active{background:rgba(59,130,246,.15);border-color:var(--blue);color:#93c5fd}'

    # Table
    $html += '.results{background:var(--surface);border:1px solid var(--border);border-radius:10px;overflow:hidden}'
    $html += 'table{width:100%;border-collapse:collapse}'
    $html += 'th{text-align:left;padding:10px 12px;font-size:10px;font-weight:600;color:var(--muted);text-transform:uppercase;letter-spacing:.8px;border-bottom:1px solid var(--border);position:sticky;top:0;background:var(--surface);z-index:1}'
    $html += '.check-row{cursor:pointer;border-bottom:1px solid rgba(30,58,95,.4);transition:background .1s}'
    $html += '.check-row:hover{background:rgba(59,130,246,.04)}'
    $html += '.status-cell{padding:10px 12px;font-size:11px;font-weight:700;width:56px;letter-spacing:.3px}'
    $html += '.name-cell{padding:10px 12px;font-size:13px;font-weight:500}'
    $html += '.cat-cell{padding:10px 12px;font-size:11px;color:var(--muted)}'
    $html += '.val-cell{padding:10px 12px;font-size:11px;color:var(--muted);max-width:240px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}'
    $html += '.sev-badge{padding:2px 8px;border-radius:10px;font-size:10px;font-weight:600}'
    $html += '.sev-critical{background:#7f1d1d;color:#fca5a5}'
    $html += '.sev-high{background:#7c2d12;color:#fdba74}'
    $html += '.sev-medium{background:#713f12;color:#fde68a}'
    $html += '.sev-low{background:#1e3a5f;color:#93c5fd}'
    $html += '.sev-info{background:#374151;color:#9ca3af}'

    # Detail row
    $html += '.detail-row{display:none;background:var(--bg)}'
    $html += '.detail-row.open{display:table-row}'
    $html += '.detail-inner{padding:14px 16px 14px 70px}'
    $html += '.detail-msg{color:#d1d5db;font-size:13px;margin-bottom:10px;line-height:1.5}'
    $html += '.detail-meta{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:10px;font-size:11px}'
    $html += '.meta-label{color:var(--muted)}.meta-val{color:var(--text)}.meta-sep{color:var(--border)}'
    $html += '.fix-block{position:relative;margin:8px 0}'
    $html += '.fix-code{background:#0c1222;color:#86efac;padding:10px 14px;border-radius:6px;font-size:11px;font-family:Consolas,monospace;overflow-x:auto;white-space:pre-wrap;word-break:break-all;border:1px solid var(--border)}'
    $html += '.copy-btn{position:absolute;top:6px;right:6px;padding:3px 10px;border-radius:4px;border:1px solid var(--border);background:var(--surface2);color:var(--muted);font-size:10px;cursor:pointer;transition:all .15s}'
    $html += '.copy-btn:hover{color:var(--text);border-color:var(--blue)}'
    $html += '.fix-note{color:var(--amber);font-size:11px;margin:6px 0}'
    $html += '.source-link{color:var(--blue);font-size:11px;text-decoration:none}'
    $html += '.source-link:hover{text-decoration:underline}'

    # Sparkline
    $html += '.spark-section{text-align:center;margin-bottom:20px}'
    $html += '.spark-label{font-size:10px;color:var(--muted);text-transform:uppercase;letter-spacing:1px;margin-bottom:6px}'
    $html += '.spark-dates{display:flex;justify-content:space-between;width:200px;margin:4px auto;font-size:10px;color:var(--muted)}'

    # Footer
    $html += '.footer{margin-top:24px;padding-top:16px;border-top:1px solid var(--border);display:flex;justify-content:space-between;flex-wrap:wrap;gap:8px;font-size:11px;color:var(--muted)}'

    # Responsive
    $html += '@media(max-width:700px){.header{flex-direction:column;text-align:center}.detail-inner{padding:12px}.cat-grid{grid-template-columns:repeat(3,1fr)}}'

    $html += '</style>'

    # JavaScript
    $html += '<script>'
    $html += 'function toggleDetail(id){var r=document.getElementById(id);r.classList.toggle("open");}'
    $html += 'function filterRows(status){document.querySelectorAll(".filter-btn").forEach(function(b){b.classList.toggle("active",b.dataset.filter===status)});'
    $html += 'document.querySelectorAll(".check-row").forEach(function(r){var s=r.dataset.status;var show=(status==="all"||s===status);r.style.display=show?"":"none";'
    $html += 'var next=r.nextElementSibling;if(next&&next.classList.contains("detail-row")){if(!show){next.classList.remove("open")}next.style.display=show?"":"none";}});}'
    $html += 'function copyFix(btn){var t=btn.dataset.fix;var ta=document.createElement("textarea");ta.value=t.replace(/&amp;/g,"&").replace(/&lt;/g,"<").replace(/&gt;/g,">").replace(/&quot;/g,''\"'');'
    $html += 'document.body.appendChild(ta);ta.select();document.execCommand("copy");document.body.removeChild(ta);btn.textContent="Copied!";setTimeout(function(){btn.textContent="Copy"},1500);}'
    $html += '</script>'
    $html += '</head><body><div class="wrap">'

    # Header with SVG score ring
    $html += '<div class="header">'
    $html += '<div class="score-ring" style="position:relative;width:120px;height:120px">'
    $html += '<svg width="120" height="120" viewBox="0 0 120 120">'
    $html += '<circle class="track" cx="60" cy="60" r="54"/>'
    $html += '<circle class="bar" cx="60" cy="60" r="54" stroke="' + $scoreColor + '" stroke-dasharray="' + $dashLen + ' ' + $dashGap + '"/>'
    $html += '</svg>'
    $html += '<div class="score-num" style="color:' + $scoreColor + '">' + $Summary.score + '</div>'
    $html += '<div class="score-label">score</div>'
    $html += '</div>'
    $html += '<div class="header-info">'
    $html += '<h1>System Latency Audit</h1>'
    $html += '<p>Mode: ' + $Mode + ' &nbsp;&bull;&nbsp; ' + $AuditedAt + '</p>'
    $html += '<div class="pills">'
    $html += '<span class="pill pill-pass">' + $Summary.pass + ' pass</span>'
    if ($Summary.warn -gt 0) { $html += '<span class="pill pill-warn">' + $Summary.warn + ' warn</span>' }
    if ($Summary.fail -gt 0) { $html += '<span class="pill pill-fail">' + $Summary.fail + ' fail</span>' }
    if ($Summary.skip -gt 0) { $html += '<span class="pill pill-skip">' + $Summary.skip + ' skip</span>' }
    $html += '</div></div></div>'

    # System info bar
    $html += '<div class="sys-bar">'
    $html += '<div class="sys-item"><span class="sys-label">CPU</span><span class="sys-val">' + (Esc $SystemInfo.cpu) + '</span></div>'
    $html += '<div class="sys-item"><span class="sys-label">GPU</span><span class="sys-val">' + (Esc $SystemInfo.gpu) + '</span></div>'
    $html += '<div class="sys-item"><span class="sys-label">RAM</span><span class="sys-val">' + (Esc $SystemInfo.ram) + '</span></div>'
    $html += '<div class="sys-item"><span class="sys-label">NIC</span><span class="sys-val">' + (Esc $SystemInfo.nic) + '</span></div>'
    $html += '</div>'

    # Sparkline (if history)
    $html += $sparkHtml

    # Category cards
    $html += '<div class="cat-grid">' + $catHtml + '</div>'

    # Filter bar
    $html += '<div class="filter-bar">'
    $html += '<button class="filter-btn active" data-filter="all" onclick="filterRows(''all'')">All (' + $Summary.total + ')</button>'
    if ($Summary.fail -gt 0) { $html += '<button class="filter-btn" data-filter="fail" onclick="filterRows(''fail'')">Fail (' + $Summary.fail + ')</button>' }
    if ($Summary.warn -gt 0) { $html += '<button class="filter-btn" data-filter="warn" onclick="filterRows(''warn'')">Warn (' + $Summary.warn + ')</button>' }
    $html += '<button class="filter-btn" data-filter="pass" onclick="filterRows(''pass'')">Pass (' + $Summary.pass + ')</button>'
    if ($Summary.skip -gt 0) { $html += '<button class="filter-btn" data-filter="skip" onclick="filterRows(''skip'')">Skip (' + $Summary.skip + ')</button>' }
    $html += '</div>'

    # Results table
    $html += '<div class="results"><table><thead><tr>'
    $html += '<th style="width:56px">Status</th><th>Check</th><th>Category</th><th>Severity</th><th>Current Value</th>'
    $html += '</tr></thead><tbody>'
    $html += $rowHtml
    $html += '</tbody></table></div>'

    # Footer
    $html += '<div class="footer">'
    $html += '<span>windows-latency-optimizer &bull; Read-only audit &mdash; no system changes made</span>'
    $html += '<span>Generated ' + $AuditedAt + ' &bull; Click any row for details + fix</span>'
    $html += '</div>'

    $html += '</div></body></html>'
    return $html
}
