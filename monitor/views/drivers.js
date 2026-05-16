/* ============================================================
 * Drivers View — Per-CPU driver DPC attribution table
 * Requires xperf data (collector -XperfIntervalSec 30)
 * ============================================================ */

function renderDriversView() {
  var el = document.getElementById('driversView');
  if (!el) return;

  var snap = window.MONITOR_SNAPSHOT;

  /* ── No xperf data ── */
  if (!snap || !snap.xperf) {
    el.innerHTML =
      '<div class="no-data">' +
      '  <div class="no-data-icon">&#9881;</div>' +
      '  <div class="no-data-text">No driver data</div>' +
      '  <div class="no-data-hint">Start collector with <code>-XperfIntervalSec 30</code></div>' +
      '</div>';
    return;
  }

  var xperf   = snap.xperf;
  var drivers = xperf.drivers || [];

  if (xperf.error) {
    el.innerHTML =
      '<div class="no-data">' +
      '  <div class="no-data-icon">&#9888;</div>' +
      '  <div class="no-data-text">xperf error</div>' +
      '  <div class="no-data-hint">' + escHtml(xperf.error) + '</div>' +
      '</div>';
    return;
  }

  if (drivers.length === 0) {
    el.innerHTML =
      '<div class="no-data">' +
      '  <div class="no-data-icon">&#9201;</div>' +
      '  <div class="no-data-text">No driver DPC data captured yet</div>' +
      '  <div class="no-data-hint">xperf trace running — results appear after the trace window.</div>' +
      '</div>';
    return;
  }

  /* ── Sort drivers by totalUsec descending ── */
  var sorted = drivers.slice().sort(function(a, b) {
    return (b.totalUsec || 0) - (a.totalUsec || 0);
  });

  var durationMs = xperf.traceDurationUs != null
    ? (xperf.traceDurationUs / 1000).toFixed(0) + ' ms'
    : '--';

  var html = '';

  /* Summary cards */
  html += '<div class="summary-bar">';
  html += summaryCard({
    label: 'Drivers',
    value: sorted.length,
    unit:  '',
    color: 'blue'
  });
  html += summaryCard({
    label: 'Trace Duration',
    value: durationMs,
    unit:  '',
    color: 'cyan'
  });
  html += summaryCard({
    label: 'Captured At',
    value: fmtTime(xperf.timestamp),
    unit:  '',
    color: 'blue'
  });
  html += '</div>';

  html += sectionHeader('Driver DPC Attribution', 'µs per CPU');

  /* Wide table with horizontal scroll */
  html += '<div class="driver-table-wrap drivers-table-wrap">';
  html += '<table class="drivers-table">';

  /* Header row */
  html += '<thead><tr>';
  html += '  <th>Driver</th>';
  html += '  <th>Total (µs)</th>';
  html += '  <th>DPC Count</th>';
  for (var c = 0; c < 16; c++) {
    html += '  <th>CPU ' + c + '</th>';
  }
  html += '</tr></thead>';

  html += '<tbody>';
  for (var i = 0; i < sorted.length; i++) {
    var d    = sorted[i];
    var cpus = d.cpuUsec || [];

    html += '<tr>';
    html += '  <td><span class="driver-name">' + escHtml(d.module || '--') + '</span></td>';
    html += '  <td class="mono">' + (d.totalUsec != null ? d.totalUsec.toLocaleString() : '--') + '</td>';
    html += '  <td class="mono">' + (d.dpcCount  != null ? d.dpcCount.toLocaleString()  : '--') + '</td>';

    for (var ci = 0; ci < 16; ci++) {
      var usec = cpus[ci] != null ? cpus[ci] : 0;
      var cellStyle = '';
      var cellClass = 'mono';
      if (usec > 10000) {
        cellStyle = 'background:var(--bad-bg);color:var(--bad);';
      } else if (usec > 1000) {
        cellStyle = 'background:var(--warn-bg);color:var(--warn);';
      }
      var cellText = usec > 0 ? usec.toLocaleString() : '';
      html += '  <td class="' + cellClass + '" style="' + cellStyle + '">' + cellText + '</td>';
    }

    html += '</tr>';
  }
  html += '</tbody>';
  html += '</table>';
  html += '</div>'; /* driver-table-wrap */

  el.innerHTML = html;
}

window.renderDriversView = renderDriversView;
