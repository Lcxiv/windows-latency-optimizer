/* ============================================================
 * Heatmap View — CPU Grid (4×4) colored by DPC severity
 * Globals: MonitorState, MonitorCharts, MON_COLORS,
 *          escHtml, safeNum, severityColor, severityBg,
 *          sectionHeader, summaryCard, fmtTime
 * ============================================================ */

/* CPU topology labels for the 9800X3D */
var CPU_ROLES = {
  0:  'Preferred Core',
  1:  'General',
  2:  'Input (KB/Mouse)',
  3:  'Input (KB/Mouse)',
  4:  'GPU/NIC DPC',
  5:  'GPU/NIC DPC',
  6:  'GPU/NIC DPC',
  7:  'GPU/NIC DPC',
  8:  'Game Threads',
  9:  'Game Threads',
  10: 'Game Threads',
  11: 'Game Threads',
  12: 'Game Threads',
  13: 'Game Threads',
  14: 'Game Threads',
  15: 'Game Threads'
};

function renderHeatmapView() {
  var el = document.getElementById('heatmapView');
  if (!el) return;

  var snap = window.MONITOR_SNAPSHOT;

  /* ── No data state ── */
  if (!snap || !snap.counters) {
    el.innerHTML =
      '<div class="no-data">' +
      '  <div class="no-data-icon">&#9635;</div>' +
      '  <div class="no-data-text">No snapshot data</div>' +
      '  <div class="no-data-hint">Run: scripts\\monitor_collector.ps1</div>' +
      '</div>';
    return;
  }

  var counters = snap.counters;
  var sys      = counters.system   || {};
  var perCpu   = counters.perCpu   || [];
  var spikes   = counters.spikes   || {};

  /* ── Build HTML ── */
  var html = '';

  /* 1. Summary bar */
  html += '<div class="summary-bar">';
  html += summaryCard({
    label: 'DPC %',
    value: safeNum(sys.dpcPct, 2),
    unit:  '%',
    color: sys.dpcPct >= 5 ? 'red' : sys.dpcPct >= 1 ? 'amber' : 'green',
    badge: sys.dpcPct >= 5 ? 'HIGH' : sys.dpcPct >= 1 ? 'WARN' : 'OK',
    badgeClass: sys.dpcPct >= 5 ? 'badge-fail' : sys.dpcPct >= 1 ? 'badge-warn' : 'badge-pass'
  });
  html += summaryCard({
    label: 'Interrupt %',
    value: safeNum(sys.intrPct, 2),
    unit:  '%',
    color: sys.intrPct >= 5 ? 'red' : sys.intrPct >= 1 ? 'amber' : 'green'
  });
  html += summaryCard({
    label: 'CS / sec',
    value: sys.ctxSwitchSec != null ? Math.round(sys.ctxSwitchSec).toLocaleString() : '--',
    unit:  '',
    color: sys.ctxSwitchSec >= 80000 ? 'red' : sys.ctxSwitchSec >= 50000 ? 'amber' : 'blue',
    badge: sys.ctxSwitchSec >= 80000 ? 'SPIKE' : null,
    badgeClass: 'badge-fail'
  });
  html += summaryCard({
    label: 'Int / sec',
    value: sys.intrPerSec != null ? Math.round(sys.intrPerSec).toLocaleString() : '--',
    unit:  '',
    color: 'cyan'
  });
  html += summaryCard({
    label: 'Proc Queue',
    value: sys.procQueueLen != null ? sys.procQueueLen : '--',
    unit:  '',
    color: sys.procQueueLen > 0 ? 'amber' : 'green',
    badge: sys.procQueueLen > 0 ? 'BUSY' : null,
    badgeClass: 'badge-warn'
  });
  html += '</div>';

  /* 2. Spike alert bar */
  var spikeMessages = [];
  if (spikes.totalDpcSpike)       spikeMessages.push('Total DPC spike');
  if (spikes.totalInterruptSpike) spikeMessages.push('Total interrupt spike');
  if (spikes.contextSwitchSpike)  spikeMessages.push('Context-switch spike');
  if (spikes.highDpcCpus && spikes.highDpcCpus.length > 0) {
    spikeMessages.push('High DPC on CPU ' + spikes.highDpcCpus.join(', '));
  }

  var alertVisible = spikeMessages.length > 0;
  html += '<div class="spike-alert-bar' + (alertVisible ? '' : ' hidden') + '">';
  html += '<div class="spike-alert-icon">&#9888;</div>';
  html += '<div><strong>Spike detected:</strong> ' + escHtml(spikeMessages.join(' &middot; ')) + '</div>';
  html += '</div>';

  /* 3. CPU grid header */
  html += sectionHeader('CPU DPC Heatmap', fmtTime(counters.timestamp));

  /* 4. 4×4 grid */
  html += '<div class="heatmap-grid">';

  for (var i = 0; i < 16; i++) {
    /* Find the entry for this CPU index */
    var entry = null;
    for (var j = 0; j < perCpu.length; j++) {
      if (perCpu[j].cpu === i) { entry = perCpu[j]; break; }
    }

    var dpc  = entry ? (entry.dpcPct  || 0) : 0;
    var intr = entry ? (entry.intrPct || 0) : 0;
    var ips  = entry ? (entry.intrPerSec || 0) : 0;

    var isSpiking = dpc >= 5;
    var isWarn    = dpc >= 1 && dpc < 5;

    var cellClass = 'heatmap-cell';
    if (isSpiking) cellClass += ' spiking';
    else if (isWarn) cellClass += ' warn';

    var dpcColor = severityColor(dpc);

    /* Bar width: 0-10% DPC maps to 0-100% bar width */
    var barWidth = Math.min(100, (dpc / 10) * 100);

    var roleTip = CPU_ROLES[i] || 'General';

    html += '<div class="' + cellClass + '">';
    html += '  <div class="heatmap-cell-cpu">CPU ' + i +
                (isSpiking ? ' <span class="spike-badge">SPIKE</span>' : '') +
                '</div>';
    html += '  <div style="font-size:9px;color:var(--muted);margin-bottom:5px;">' + escHtml(roleTip) + '</div>';
    html += '  <div class="heatmap-cell-dpc" style="color:' + dpcColor + ';">' +
                safeNum(dpc, 1) + '<span class="heatmap-cell-unit">% DPC</span>' +
                '</div>';
    html += '  <div class="heatmap-cell-intr">INT ' + safeNum(intr, 1) + '%' +
                ' &nbsp; ' + Math.round(ips).toLocaleString() + '/s</div>';
    html += '  <div class="heatmap-cell-bar" style="width:' + barWidth + '%;background:' + dpcColor + ';"></div>';
    html += '</div>';
  }

  html += '</div>'; /* end heatmap-grid */

  el.innerHTML = html;
}

/* Expose globally */
window.renderHeatmapView = renderHeatmapView;
