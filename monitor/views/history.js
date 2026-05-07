/* ============================================================
 * History View — Full session history with range selector
 * Reuses updateOrCreateTimelineChart() from timeline.js
 * ============================================================ */

/* Track current range in minutes (null = all) */
var _historyRangeMin = null;

function setHistoryRange(minutes) {
  _historyRangeMin = minutes;
  renderHistoryView();
}

function renderHistoryView() {
  var el = document.getElementById('historyView');
  if (!el) return;

  var allHistory = window.MONITOR_HISTORY || [];

  /* ── No data ── */
  if (allHistory.length === 0) {
    el.innerHTML =
      '<div class="no-data">' +
      '  <div class="no-data-icon">&#9201;</div>' +
      '  <div class="no-data-text">No history data yet</div>' +
      '  <div class="no-data-hint">History accumulates as the collector runs.</div>' +
      '</div>';
    return;
  }

  /* ── Filter by range ── */
  var filtered = allHistory;
  if (_historyRangeMin != null) {
    var cutoffMs = Date.now() - (_historyRangeMin * 60 * 1000);
    filtered = [];
    for (var k = 0; k < allHistory.length; k++) {
      var ts = new Date(allHistory[k].timestamp).getTime();
      if (!isNaN(ts) && ts >= cutoffMs) filtered.push(allHistory[k]);
    }
  }

  /* Build parallel data arrays */
  var labels   = [];
  var csData   = [];
  var dpcData  = [];
  var intrData = [];

  for (var i = 0; i < filtered.length; i++) {
    var entry = filtered[i];
    var sys   = entry.system || {};
    labels.push(fmtTime(entry.timestamp));
    csData.push(sys.ctxSwitchSec  != null ? sys.ctxSwitchSec  : null);
    dpcData.push(sys.dpcPct       != null ? sys.dpcPct        : null);
    intrData.push(sys.intrPct     != null ? sys.intrPct       : null);
  }

  /* ── Duration string for first…last ── */
  var durationStr = _historyDuration(filtered);

  /* ── Compute stats (Avg/Min/Max) ── */
  var csStats   = _computeStats(csData);
  var dpcStats  = _computeStats(dpcData);
  var intrStats = _computeStats(intrData);

  /* ── Build DOM (full redraw each time — this view is not animated) ── */
  var html = '';

  /* Range selector */
  html += '<div style="display:flex;align-items:center;gap:8px;margin-bottom:16px;flex-wrap:wrap;">';
  html += '<span style="font-size:11px;color:var(--muted);">Range:</span>';
  var ranges = [
    { label: '1 min',  value: 1    },
    { label: '5 min',  value: 5    },
    { label: '15 min', value: 15   },
    { label: 'All',    value: null }
  ];
  for (var ri = 0; ri < ranges.length; ri++) {
    var r       = ranges[ri];
    var isActive = _historyRangeMin === r.value;
    var btnStyle = isActive
      ? 'background:var(--blue);color:#fff;border-color:var(--blue);'
      : 'background:var(--surface2);color:var(--muted);border-color:var(--border);';
    var onclickVal = r.value != null ? 'setHistoryRange(' + r.value + ')' : 'setHistoryRange(null)';
    html += '<button onclick="' + onclickVal + '" style="' + btnStyle +
            'border:1px solid;border-radius:5px;padding:4px 10px;font-size:11px;cursor:pointer;font-family:inherit;">' +
            escHtml(r.label) + '</button>';
  }
  html += '<span class="history-meta" style="margin-left:auto;">' +
            escHtml(filtered.length + ' samples') +
            (durationStr ? ' &nbsp;&middot;&nbsp; ' + escHtml(durationStr) : '') +
            '</span>';
  html += '</div>';

  /* ── Charts ── */
  html += '<div class="chart-card full" style="margin-bottom:14px;">';
  html += '  <div class="chart-title">Context Switches / sec</div>';
  html += '  <div class="chart-subtitle">System-wide thread context switch rate</div>';
  html += '  <div class="chart-wrap" style="height:130px;"><canvas id="histCanvasCs"></canvas></div>';
  html += '</div>';

  html += '<div class="chart-card full" style="margin-bottom:20px;">';
  html += '  <div class="chart-title">DPC % (System Total)</div>';
  html += '  <div class="chart-subtitle">Deferred Procedure Call CPU utilization</div>';
  html += '  <div class="chart-wrap" style="height:130px;"><canvas id="histCanvasDpc"></canvas></div>';
  html += '</div>';

  /* Stats table */
  html += sectionHeader('Session Statistics');
  html += '<div style="overflow-x:auto;margin-bottom:20px;">';
  html += '<table class="data-table">';
  html += '<thead><tr>';
  html += '  <th>Metric</th><th>Avg</th><th>Min</th><th>Max</th><th>Samples</th>';
  html += '</tr></thead>';
  html += '<tbody>';
  html += _statsRow('CS / sec',     csStats,   0);
  html += _statsRow('DPC %',        dpcStats,  3);
  html += _statsRow('Interrupt %',  intrStats, 3);
  html += '</tbody></table>';
  html += '</div>';

  /* Always full redraw so destroy charts first */
  MonitorCharts.destroy('histCs');
  MonitorCharts.destroy('histDpc');

  el.innerHTML = html;

  /* Create charts AFTER setting innerHTML */
  renderHistoryCharts(labels, csData, dpcData);
}

function renderHistoryCharts(labels, csData, dpcData) {
  /* CS chart */
  var ctxCs = document.getElementById('histCanvasCs');
  if (ctxCs && typeof updateOrCreateTimelineChart === 'function') {
    updateOrCreateTimelineChart(
      'histCs', 'histCanvasCs', labels, csData,
      MON_COLORS.cyan, 'CS/sec', { suggestedMax: 100000 }
    );
  }

  /* DPC chart */
  var ctxDpc = document.getElementById('histCanvasDpc');
  if (ctxDpc && typeof updateOrCreateTimelineChart === 'function') {
    updateOrCreateTimelineChart(
      'histDpc', 'histCanvasDpc', labels, dpcData,
      MON_COLORS.amber, 'DPC %', { suggestedMax: 10 }
    );
  }
}

/* ── Helpers ── */

function _computeStats(arr) {
  var valid = [];
  for (var i = 0; i < arr.length; i++) {
    if (arr[i] != null && !isNaN(arr[i])) valid.push(arr[i]);
  }
  if (valid.length === 0) return { avg: null, min: null, max: null, n: 0 };
  var sum = 0, mn = valid[0], mx = valid[0];
  for (var j = 0; j < valid.length; j++) {
    sum += valid[j];
    if (valid[j] < mn) mn = valid[j];
    if (valid[j] > mx) mx = valid[j];
  }
  return { avg: sum / valid.length, min: mn, max: mx, n: valid.length };
}

function _statsRow(label, stats, decimals) {
  return (
    '<tr>' +
    '<td>' + escHtml(label) + '</td>' +
    '<td class="mono">' + (stats.avg != null ? stats.avg.toFixed(decimals) : '--') + '</td>' +
    '<td class="mono">' + (stats.min != null ? stats.min.toFixed(decimals) : '--') + '</td>' +
    '<td class="mono">' + (stats.max != null ? stats.max.toFixed(decimals) : '--') + '</td>' +
    '<td class="color-muted">' + stats.n + '</td>' +
    '</tr>'
  );
}

function _historyDuration(entries) {
  if (!entries || entries.length < 2) return '';
  var t0 = new Date(entries[0].timestamp).getTime();
  var t1 = new Date(entries[entries.length - 1].timestamp).getTime();
  if (isNaN(t0) || isNaN(t1)) return '';
  var sec = Math.round((t1 - t0) / 1000);
  if (sec < 60)  return sec + 's';
  if (sec < 3600) return Math.floor(sec / 60) + 'm ' + (sec % 60) + 's';
  return Math.floor(sec / 3600) + 'h ' + Math.floor((sec % 3600) / 60) + 'm';
}

window.renderHistoryView  = renderHistoryView;
window.setHistoryRange    = setHistoryRange;
window.renderHistoryCharts = renderHistoryCharts;
