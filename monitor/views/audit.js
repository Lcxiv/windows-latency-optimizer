/* ============================================================
 * Audit View — Pre-gaming checklist with score card
 * ============================================================ */

function renderAuditView() {
  var el = document.getElementById('auditView');
  if (!el) return;

  var snap = window.MONITOR_SNAPSHOT;

  if (!snap) {
    el.innerHTML =
      '<div class="no-data">' +
      '  <div class="no-data-icon">&#9745;</div>' +
      '  <div class="no-data-text">No snapshot data</div>' +
      '  <div class="no-data-hint">Run: scripts\\monitor_collector.ps1</div>' +
      '</div>';
    return;
  }

  var procData = snap.processes || {};
  var counters = snap.counters  || {};
  var sys      = counters.system || {};
  var flagged  = procData.flagged  || [];
  var score    = procData.auditScore != null ? procData.auditScore : 0;

  var html = '';

  /* ── Score card ── */
  var scoreLabel, scoreColor, scoreBadge;
  if (score === 0)     { scoreLabel = 'System ready';          scoreColor = 'green'; scoreBadge = 'READY';               }
  else if (score <= 3) { scoreLabel = 'Minor overhead';        scoreColor = 'amber'; scoreBadge = 'MINOR OVERHEAD';      }
  else                 { scoreLabel = 'Significant overhead';  scoreColor = 'red';   scoreBadge = 'SIGNIFICANT OVERHEAD'; }

  html += '<div class="summary-bar" style="margin-bottom:20px;">';
  html += summaryCard({
    label: 'Audit Score',
    value: score,
    unit:  '',
    color: scoreColor,
    badge: scoreBadge,
    badgeClass: score === 0 ? 'badge-pass' : score <= 3 ? 'badge-warn' : 'badge-fail',
    sub: scoreLabel
  });
  html += summaryCard({
    label: 'Flagged Groups',
    value: flagged.length,
    unit:  '',
    color: flagged.length > 0 ? 'amber' : 'green'
  });
  html += summaryCard({
    label: 'Snapshot Age',
    value: fmtTime(snap.timestamp),
    unit:  '',
    color: 'blue'
  });
  html += '</div>';

  /* ── System checks ── */
  html += sectionHeader('System Checks');
  html += '<div class="audit-list">';

  var checks = [
    {
      label:  'DPC % below 1%',
      detail: 'Current: ' + safeNum(sys.dpcPct, 2) + '%',
      pass:   sys.dpcPct != null && sys.dpcPct < 1,
      fail:   sys.dpcPct == null
    },
    {
      label:  'Interrupt % below 1%',
      detail: 'Current: ' + safeNum(sys.intrPct, 2) + '%',
      pass:   sys.intrPct != null && sys.intrPct < 1,
      fail:   sys.intrPct == null
    },
    {
      label:  'Context switches below 80K/sec',
      detail: 'Current: ' + (sys.ctxSwitchSec != null ? Math.round(sys.ctxSwitchSec).toLocaleString() : '--') + '/sec',
      pass:   sys.ctxSwitchSec != null && sys.ctxSwitchSec < 80000,
      fail:   sys.ctxSwitchSec == null
    },
    {
      label:  'Process run queue = 0',
      detail: 'Current: ' + (sys.procQueueLen != null ? sys.procQueueLen : '--'),
      pass:   sys.procQueueLen != null && sys.procQueueLen === 0,
      fail:   sys.procQueueLen == null
    }
  ];

  for (var i = 0; i < checks.length; i++) {
    var chk = checks[i];
    var itemClass, icon;
    if (chk.fail) {
      itemClass = 'audit-item'; icon = '&#8212;';
    } else if (chk.pass) {
      itemClass = 'audit-item pass'; icon = '&#10003;';
    } else {
      itemClass = 'audit-item fail'; icon = '&#10007;';
    }

    html += '<div class="' + itemClass + '">';
    html += '  <div class="audit-icon" style="color:' +
              (chk.fail ? 'var(--muted)' : chk.pass ? 'var(--green)' : 'var(--red)') + ';">' +
              icon + '</div>';
    html += '  <div class="audit-text">' + escHtml(chk.label) + '</div>';
    html += '  <div class="audit-detail">' + escHtml(chk.detail) + '</div>';
    html += '</div>';
  }
  html += '</div>'; /* audit-list */

  /* ── Flagged processes table ── */
  if (flagged.length > 0) {
    html += sectionHeader('Overhead Processes', 'Consider closing before gaming');
    html += '<div class="proc-table-wrap">';
    html += '<table class="proc-table">';
    html += '<thead><tr>';
    html += '  <th>Group</th>';
    html += '  <th>Instances</th>';
    html += '  <th>Threads</th>';
    html += '  <th>Memory (MB)</th>';
    html += '  <th>Action</th>';
    html += '</tr></thead>';
    html += '<tbody>';

    for (var j = 0; j < flagged.length; j++) {
      var f = flagged[j];
      html += '<tr class="flagged">';
      html += '  <td><span class="proc-name">' + escHtml(f.group) + '</span></td>';
      html += '  <td>' + (f.count || 0) + '</td>';
      html += '  <td>' + (f.totalThreads || 0) + '</td>';
      html += '  <td>' + safeNum(f.totalWorkingSetMB, 0) + '</td>';
      html += '  <td><span class="proc-flagged-tag">Close</span></td>';
      html += '</tr>';
    }

    html += '</tbody></table>';
    html += '</div>'; /* proc-table-wrap */
  } else {
    html += '<div style="margin-top:16px;padding:12px 14px;background:rgba(16,185,129,0.08);' +
            'border:1px solid rgba(16,185,129,0.3);border-radius:8px;font-size:12px;color:var(--green);">' +
            '&#10003; No overhead processes detected — system is clean for gaming.' +
            '</div>';
  }

  el.innerHTML = html;
}

window.renderAuditView = renderAuditView;
