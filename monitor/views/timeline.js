/* ============================================================
 * Timeline View — 3 scrolling Chart.js line charts
 * CS/sec | DPC% | Interrupt%
 * Uses MONITOR_HISTORY window of last 300 points.
 * On re-render: update chart data in-place (no flicker).
 * ============================================================ */

/* Track whether we've already built the DOM for timeline */
var _timelineDomBuilt = false;

function renderTimelineView() {
  var el = document.getElementById('timelineView');
  if (!el) return;

  var history = window.MONITOR_HISTORY || [];
  var window300 = history.slice(-300);

  if (window300.length === 0) {
    el.innerHTML =
      '<div class="no-data">' +
      '  <div class="no-data-icon">&#9201;</div>' +
      '  <div class="no-data-text">No history data yet</div>' +
      '  <div class="no-data-hint">Collector writes history as it runs — wait a few seconds.</div>' +
      '</div>';
    _timelineDomBuilt = false;
    return;
  }

  /* Extract parallel arrays for chart data */
  var labels  = [];
  var csData  = [];
  var dpcData = [];
  var intrData = [];

  for (var i = 0; i < window300.length; i++) {
    var entry = window300[i];
    labels.push(fmtTime(entry.timestamp));
    var sys = entry.system || {};
    csData.push(sys.ctxSwitchSec != null ? sys.ctxSwitchSec : null);
    dpcData.push(sys.dpcPct != null ? sys.dpcPct : null);
    intrData.push(sys.intrPct != null ? sys.intrPct : null);
  }

  /* ── First render: build DOM ── */
  if (!_timelineDomBuilt || !document.getElementById('tlCanvasCs')) {
    _timelineDomBuilt = true;

    var html = '';
    html += '<div class="charts-grid" style="grid-template-columns:1fr;">';

    html += _chartCardHtml('tlCanvasCs',
      'Context Switches / sec',
      'System-wide thread context switches per second (threshold: 80K)');
    html += _chartCardHtml('tlCanvasDpc',
      'DPC % (System Total)',
      'Percentage of CPU time spent in Deferred Procedure Calls');
    html += _chartCardHtml('tlCanvasIntr',
      'Interrupt % (System Total)',
      'Percentage of CPU time spent handling hardware interrupts');

    html += '</div>';
    el.innerHTML = html;

    /* Create charts */
    _createTimelineChart('tlCs',  'tlCanvasCs',  labels, csData,
      MON_COLORS.cyan, 'CS/sec', { suggestedMax: 100000 });
    _createTimelineChart('tlDpc', 'tlCanvasDpc', labels, dpcData,
      MON_COLORS.amber, 'DPC %', { suggestedMax: 10, max: 100 });
    _createTimelineChart('tlIntr','tlCanvasIntr',labels, intrData,
      MON_COLORS.purple, 'Intr %', { suggestedMax: 10, max: 100 });
  } else {
    /* ── Subsequent renders: update data in-place ── */
    _updateTimelineChart('tlCs',   labels, csData);
    _updateTimelineChart('tlDpc',  labels, dpcData);
    _updateTimelineChart('tlIntr', labels, intrData);
  }
}

/* ── Shared chart create / update used by history.js too ── */

function updateOrCreateTimelineChart(key, canvasId, labels, data, color, dataLabel, yOpts) {
  if (MonitorCharts._charts[key]) {
    _updateTimelineChart(key, labels, data);
  } else {
    _createTimelineChart(key, canvasId, labels, data, color, dataLabel, yOpts || {});
  }
}

function _chartCardHtml(canvasId, title, subtitle) {
  return (
    '<div class="chart-card full" >' +
    '  <div class="chart-title">' + escHtml(title) + '</div>' +
    '  <div class="chart-subtitle">' + escHtml(subtitle) + '</div>' +
    '  <div class="chart-wrap" style="height:140px;">' +
    '    <canvas id="' + escHtml(canvasId) + '"></canvas>' +
    '  </div>' +
    '</div>'
  );
}

function _createTimelineChart(key, canvasId, labels, data, color, dataLabel, yOpts) {
  var ctx = document.getElementById(canvasId);
  if (!ctx) return;

  var yMax = yOpts.max != null ? yOpts.max : undefined;
  var ySugMax = yOpts.suggestedMax != null ? yOpts.suggestedMax : undefined;

  var opts = monChartOpts({
    aspectRatio: false,
    plugins: {
      legend: { display: false }
    },
    scales: {
      x: {
        ticks: {
          maxTicksLimit: 10,
          color: MON_COLORS.muted,
          font: { size: 9 }
        }
      },
      y: {
        min: 0,
        max: yMax,
        suggestedMax: ySugMax,
        ticks: { color: MON_COLORS.muted, font: { size: 9 } }
      }
    }
  });

  MonitorCharts.create(key, ctx, {
    type: 'line',
    data: {
      labels: labels,
      datasets: [{
        label:            dataLabel,
        data:             data,
        borderColor:      color,
        backgroundColor:  _hexToRgba(color, 0.12),
        borderWidth:      1.5,
        pointRadius:      0,
        tension:          0.3,
        fill:             true,
        spanGaps:         true
      }]
    },
    options: opts
  });
}

function _updateTimelineChart(key, labels, data) {
  var chart = MonitorCharts._charts[key];
  if (!chart) return;
  chart.data.labels          = labels;
  chart.data.datasets[0].data = data;
  chart.update('none'); /* 'none' = no animation for low-flicker update */
}

function _hexToRgba(hex, alpha) {
  /* Basic hex-to-rgba for the few MON_COLORS values we use */
  var r = parseInt(hex.slice(1, 3), 16);
  var g = parseInt(hex.slice(3, 5), 16);
  var b = parseInt(hex.slice(5, 7), 16);
  return 'rgba(' + r + ',' + g + ',' + b + ',' + alpha + ')';
}

/* Expose globals */
window.renderTimelineView          = renderTimelineView;
window.updateOrCreateTimelineChart = updateOrCreateTimelineChart;
