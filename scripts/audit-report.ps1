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
        [string]$FixScriptPath = ''
    )

    # Score color
    $scoreColor = '#ef4444'
    if ($Summary.score -ge 80) { $scoreColor = '#22c55e' }
    elseif ($Summary.score -ge 50) { $scoreColor = '#f59e0b' }

    # Status icon map (pre-compute to avoid PS subexpression issues)
    function Get-StatusIcon($status) {
        if ($status -eq 'PASS')  { return '&#10003;' }  # checkmark
        if ($status -eq 'FAIL')  { return '&#10007;' }  # X
        if ($status -eq 'WARN')  { return '&#9888;'  }  # warning
        if ($status -eq 'SKIP')  { return '&#8212;'  }  # em-dash
        return '!'
    }
    function Get-StatusColor($status) {
        if ($status -eq 'PASS')  { return '#22c55e' }
        if ($status -eq 'FAIL')  { return '#ef4444' }
        if ($status -eq 'WARN')  { return '#f59e0b' }
        if ($status -eq 'SKIP')  { return '#6b7280' }
        return '#6b7280'
    }
    function Get-SeverityBadge($sev) {
        if ($sev -eq 'CRITICAL') { return '<span style="background:#7f1d1d;color:#fca5a5;padding:1px 6px;border-radius:4px;font-size:11px">CRITICAL</span>' }
        if ($sev -eq 'HIGH')     { return '<span style="background:#7c2d12;color:#fdba74;padding:1px 6px;border-radius:4px;font-size:11px">HIGH</span>' }
        if ($sev -eq 'MEDIUM')   { return '<span style="background:#713f12;color:#fde68a;padding:1px 6px;border-radius:4px;font-size:11px">MEDIUM</span>' }
        if ($sev -eq 'LOW')      { return '<span style="background:#1e3a5f;color:#93c5fd;padding:1px 6px;border-radius:4px;font-size:11px">LOW</span>' }
        return '<span style="background:#374151;color:#9ca3af;padding:1px 6px;border-radius:4px;font-size:11px">INFO</span>'
    }

    # Category pass rates
    $cats = @('OS','NIC','GPU','Memory','Peripheral','Network')
    $catHtml = ''
    foreach ($cat in $cats) {
        $catChecks = @($Checks | Where-Object { $_.category -eq $cat })
        $catPass   = @($catChecks | Where-Object { $_.status -eq 'PASS' }).Count
        $catTotal  = @($catChecks | Where-Object { $_.status -ne 'SKIP' -and $_.status -ne 'ERROR' }).Count
        $catScore  = 0
        if ($catTotal -gt 0) { $catScore = [math]::Round(($catPass / $catTotal) * 100) }
        $catColor  = '#ef4444'
        if ($catScore -ge 80) { $catColor = '#22c55e' }
        elseif ($catScore -ge 50) { $catColor = '#f59e0b' }
        $catHtml += '<div style="background:#1f2937;border-radius:8px;padding:12px 16px;text-align:center">'
        $catHtml += '<div style="font-size:22px;font-weight:bold;color:' + $catColor + '">' + $catScore + '%</div>'
        $catHtml += '<div style="font-size:12px;color:#9ca3af;margin-top:4px">' + $cat + '</div>'
        $catHtml += '<div style="font-size:11px;color:#6b7280">' + $catPass + '/' + $catTotal + ' pass</div>'
        $catHtml += '</div>'
    }

    # Results table rows
    $rowHtml = ''
    $rowIdx  = 0
    foreach ($check in $Checks) {
        $rowIdx++
        $icon     = Get-StatusIcon $check.status
        $color    = Get-StatusColor $check.status
        $sevBadge = Get-SeverityBadge $check.severity
        $detailId = 'detail-' + $rowIdx

        $rowHtml += '<tr onclick="toggleDetail(''' + $detailId + ''')" style="cursor:pointer;border-bottom:1px solid #374151">'
        $rowHtml += '<td style="padding:10px 8px;color:' + $color + ';font-size:18px;width:32px">' + $icon + '</td>'
        $rowHtml += '<td style="padding:10px 8px">' + [System.Web.HttpUtility]::HtmlEncode($check.name) + '</td>'
        $rowHtml += '<td style="padding:10px 8px;color:#6b7280;font-size:12px">' + $check.category + '</td>'
        $rowHtml += '<td style="padding:10px 8px">' + $sevBadge + '</td>'
        $rowHtml += '<td style="padding:10px 8px;color:#9ca3af;font-size:12px;max-width:200px;overflow:hidden;text-overflow:ellipsis">' + [System.Web.HttpUtility]::HtmlEncode($check.current) + '</td>'
        $rowHtml += '</tr>'

        # Expandable detail row
        $rowHtml += '<tr id="' + $detailId + '" style="display:none;background:#111827">'
        $rowHtml += '<td colspan="5" style="padding:12px 16px">'
        if ($check.message -ne '') {
            $rowHtml += '<p style="color:#d1d5db;margin:0 0 8px">' + [System.Web.HttpUtility]::HtmlEncode($check.message) + '</p>'
        }
        $rowHtml += '<div style="display:flex;gap:16px;flex-wrap:wrap;margin-bottom:8px">'
        $rowHtml += '<span style="color:#6b7280;font-size:12px">Expected: <span style="color:#d1d5db">' + [System.Web.HttpUtility]::HtmlEncode($check.expected) + '</span></span>'
        $rowHtml += '</div>'
        if ($check.fix -ne '' -and $null -ne $check.fix) {
            $rowHtml += '<pre style="background:#0f172a;color:#86efac;padding:8px 12px;border-radius:4px;font-size:12px;overflow-x:auto;margin:4px 0">' + [System.Web.HttpUtility]::HtmlEncode($check.fix) + '</pre>'
        }
        if ($check.fixNote -ne '' -and $null -ne $check.fixNote) {
            $rowHtml += '<p style="color:#f59e0b;font-size:12px;margin:4px 0">&#9888; ' + [System.Web.HttpUtility]::HtmlEncode($check.fixNote) + '</p>'
        }
        if ($check.source -ne '' -and $null -ne $check.source) {
            $rowHtml += '<a href="' + $check.source + '" target="_blank" style="color:#60a5fa;font-size:12px">Source &#8599;</a>'
        }
        $rowHtml += '</td></tr>'
    }

    # Full HTML document
    $html  = '<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">'
    $html += '<meta name="viewport" content="width=device-width,initial-scale=1">'
    $html += '<title>System Latency Audit — ' + $AuditedAt + '</title>'
    $html += '<style>*{box-sizing:border-box}body{font-family:''Segoe UI'',system-ui,sans-serif;background:#0f172a;color:#e2e8f0;margin:0;padding:24px}'
    $html += 'table{width:100%;border-collapse:collapse}tr:hover{background:#1f2937}'
    $html += 'th{text-align:left;padding:10px 8px;color:#6b7280;font-size:12px;font-weight:600;border-bottom:1px solid #374151}'
    $html += 'pre{white-space:pre-wrap;word-break:break-all}</style>'
    $html += '<script>function toggleDetail(id){var el=document.getElementById(id);el.style.display=el.style.display===''none''?''table-row'':''none'';}</script>'
    $html += '</head><body>'

    # Header
    $html += '<div style="max-width:1100px;margin:0 auto">'
    $html += '<div style="display:flex;align-items:center;gap:24px;margin-bottom:32px">'
    $html += '<div style="text-align:center;min-width:100px">'
    $html += '<div style="font-size:48px;font-weight:900;color:' + $scoreColor + '">' + $Summary.score + '</div>'
    $html += '<div style="font-size:13px;color:#6b7280">SCORE</div>'
    $html += '</div>'
    $html += '<div>'
    $html += '<h1 style="margin:0;font-size:24px">System Latency Audit</h1>'
    $html += '<p style="margin:4px 0 0;color:#9ca3af;font-size:14px">Mode: ' + $Mode + ' &nbsp;|&nbsp; Audited: ' + $AuditedAt + '</p>'
    $html += '<p style="margin:4px 0 0;color:#9ca3af;font-size:13px">' + [System.Web.HttpUtility]::HtmlEncode($SystemInfo.cpu) + ' &nbsp;&bull;&nbsp; ' + [System.Web.HttpUtility]::HtmlEncode($SystemInfo.gpu) + '</p>'
    $html += '<p style="margin:4px 0 0;color:#9ca3af;font-size:13px">' + [System.Web.HttpUtility]::HtmlEncode($SystemInfo.ram) + ' &nbsp;&bull;&nbsp; ' + [System.Web.HttpUtility]::HtmlEncode($SystemInfo.nic) + '</p>'
    $html += '</div>'
    $html += '<div style="margin-left:auto;text-align:right;font-size:13px;color:#6b7280">'
    $html += '<div>' + $Summary.pass + ' PASS &nbsp; ' + $Summary.warn + ' WARN &nbsp; ' + $Summary.fail + ' FAIL &nbsp; ' + $Summary.skip + ' SKIP</div>'
    $html += '</div>'
    $html += '</div>'

    # Category cards
    $html += '<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:12px;margin-bottom:32px">'
    $html += $catHtml
    $html += '</div>'

    # Results table
    $html += '<div style="background:#1f2937;border-radius:12px;overflow:hidden">'
    $html += '<table><thead><tr>'
    $html += '<th></th><th>Check</th><th>Category</th><th>Severity</th><th>Current Value</th>'
    $html += '</tr></thead><tbody>'
    $html += $rowHtml
    $html += '</tbody></table></div>'

    # Footer
    $html += '<p style="margin-top:24px;color:#374151;font-size:12px;text-align:center">windows-latency-optimizer &nbsp;|&nbsp; Read-only audit — no system changes made &nbsp;|&nbsp; Click any row for details + fix command</p>'
    $html += '</div></body></html>'

    return $html
}
