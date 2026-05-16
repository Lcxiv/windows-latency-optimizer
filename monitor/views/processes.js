/* ============================================================
 * Processes View — Top 20 process table with overhead flags
 * ============================================================ */

function renderProcessesView() {
  var el = document.getElementById('processesView');
  if (!el) return;

  var snap = window.MONITOR_SNAPSHOT;

  if (!snap || !snap.processes) {
    el.innerHTML =
      '<div class="no-data">' +
      '  <div class="no-data-icon">&#9881;</div>' +
      '  <div class="no-data-text">No process data</div>' +
      '  <div class="no-data-hint">Run: scripts\\monitor_collector.ps1</div>' +
      '</div>';
    return;
  }

  var procData  = snap.processes;
  var procs     = procData.processes || [];
  var flagged   = procData.flagged   || [];
  var score     = procData.auditScore != null ? procData.auditScore : 0;

  /* Build a lookup: process name → flag group (case-insensitive partial match) */
  function isFlagged(procName) {
    var n = (procName || '').toLowerCase();
    for (var i = 0; i < flagged.length; i++) {
      var g = (flagged[i].group || '').toLowerCase();
      if (g && n.indexOf(g.toLowerCase()) !== -1) return true;
      /* Also check reverse: group contains proc name */
      if (g && g.indexOf(n) !== -1) return true;
    }
    return false;
  }

  var html = '';

  /* ── Score card ── */
  var scoreLabel, scoreClass;
  if (score === 0)      { scoreLabel = 'READY';              scoreClass = 'green'; }
  else if (score <= 3)  { scoreLabel = 'MINOR OVERHEAD';     scoreClass = 'amber'; }
  else                  { scoreLabel = 'SIGNIFICANT OVERHEAD'; scoreClass = 'red'; }

  html += '<div class="summary-bar">';
  html += summaryCard({
    label: 'Audit Score',
    value: score,
    unit:  '',
    color: scoreClass,
    badge: scoreLabel,
    badgeClass: score === 0 ? 'badge-pass' : score <= 3 ? 'badge-warn' : 'badge-fail'
  });
  html += summaryCard({
    label: 'Total Processes',
    value: procs.length,
    unit:  '',
    color: 'blue'
  });
  html += summaryCard({
    label: 'Flagged Groups',
    value: flagged.length,
    unit:  '',
    color: flagged.length > 0 ? 'amber' : 'green'
  });
  html += '</div>';

  /* ── Flagged group cards ── */
  if (flagged.length > 0) {
    html += sectionHeader('Flagged Overhead Groups', flagged.length);
    html += '<div class="flagged-grid">';
    for (var i = 0; i < flagged.length; i++) {
      var f = flagged[i];
      html += '<div class="flagged-card">';
      html += '  <div class="flagged-card-name">' + escHtml(f.group) + '</div>';
      html += '  <div class="flagged-card-stat"><strong>' + (f.count || 0) + '</strong> instances</div>';
      html += '  <div class="flagged-card-stat"><strong>' + (f.totalThreads || 0) + '</strong> threads</div>';
      html += '  <div class="flagged-card-stat"><strong>' + safeNum(f.totalWorkingSetMB, 0) + '</strong> MB WS</div>';
      html += '</div>';
    }
    html += '</div>';
  }

  /* ── Process table ── */
  html += sectionHeader('Top 20 Processes', fmtTime(procData.timestamp));
  html += '<div class="proc-table-wrap">';
  html += '<table class="proc-table">';
  html += '<thead><tr>';
  html += '  <th>Name</th>';
  html += '  <th>PID</th>';
  html += '  <th>Threads</th>';
  html += '  <th>Handles</th>';
  html += '  <th>CPU (sec)</th>';
  html += '  <th>WS (MB)</th>';
  html += '  <th>Flag</th>';
  html += '</tr></thead>';
  html += '<tbody>';

  for (var j = 0; j < procs.length; j++) {
    var p   = procs[j];
    var fl  = isFlagged(p.name);
    var rowClass = fl ? ' class="flagged"' : '';
    html += '<tr' + rowClass + '>';
    html += '  <td><span class="proc-name">' + escHtml(p.name) + '</span></td>';
    html += '  <td class="color-muted mono">' + escHtml(String(p.pid)) + '</td>';
    html += '  <td>' + escHtml(String(p.threads != null ? p.threads : '--')) + '</td>';
    html += '  <td>' + escHtml(String(p.handles != null ? p.handles : '--')) + '</td>';
    html += '  <td>' + safeNum(p.cpuSec, 2) + '</td>';
    html += '  <td>' + safeNum(p.workingSetMB, 1) + '</td>';
    html += '  <td>';
    if (fl) {
      html += '<span class="proc-flagged-tag">Overhead</span>';
    }
    html += '  </td>';
    html += '</tr>';
  }

  html += '</tbody></table>';
  html += '</div>'; /* proc-table-wrap */

  el.innerHTML = html;
}

window.renderProcessesView = renderProcessesView;
