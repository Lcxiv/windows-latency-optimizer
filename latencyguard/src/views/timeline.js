// ============================================================
// LatencyGuard — Timeline view (v2 Direction 03)
// ============================================================
// Source: latencyguard/design/project/LatencyGuard Wireframes v2.html #p3
// Replaces: old history.js row-per-experiment table when mode=timeline
// (history.js stays in place as the data-loader + comparison renderer)
//
// Layout:
//   Window with app-nav
//   tl-top   — headline ("N→M milliseconds") + segment toggle (mouse/frames/system)
//   tl-chart — SVG line chart across 20-day experiment run
//   tl-stats — 4-cell strip (longest gap / CPU0 IRQ share / defender / checks)
//   tl-log   — experiment rows (EXP·NN · title · delta · date)
//
// Segment toggle changes which metric the chart + stats show.
// Metrics mapped from experiment.json fields:
//   mouse  → cpuTotal.dpcPct               (lower is better)
//   frames → frameTiming.frameTimeMs.p95   (if present)
//   system → interruptTopology.cpu0Share   (lower is better)
// ============================================================

// segment state lives on window so the toggle persists across renders
if (typeof window.__tlSegment === 'undefined') window.__tlSegment = 'mouse';

var TL_SEGMENTS = [
  { key: 'mouse',  label: 'Mouse',  metric: 'dpcPct',       unit: '%' },
  { key: 'frames', label: 'Frames', metric: 'framesP95',    unit: 'ms' },
  { key: 'system', label: 'System', metric: 'cpu0Share',    unit: '%' },
];

// ------------------------------------------------------------
// Entry — called from app.js render('timeline')
// ------------------------------------------------------------
async function renderTimeline(container) {
  // Load if not cached
  if (!state.experiments || state.experiments.length === 0) {
    container.innerHTML = renderTimelineLoading();
    try {
      var exps = await invoke('get_experiments');
      state.experiments = exps || [];
    } catch (e) {
      state.experiments = [];
    }
  }

  var exps = state.experiments || [];
  if (exps.length === 0) {
    container.innerHTML = renderTimelineEmpty();
    return;
  }

  // Sort by capturedAt ascending (oldest baseline first)
  var sorted = exps.slice().sort(function (a, b) {
    return (a.capturedAt || '').localeCompare(b.capturedAt || '');
  });

  var seg = window.__tlSegment;
  var html = '<div class="tl-shell">';
  html += '<section class="inst-win">';
  html += renderTimelineChrome();
  html += renderTimelineAppNav();
  html += renderTimelineTop(sorted, seg);
  html += renderTimelineChart(sorted, seg);
  html += renderTimelineStats(sorted, seg);
  html += renderTimelineLog(sorted);
  html += '</section>';
  html += '</div>';
  container.innerHTML = html;
  wireTimelineEvents();
}

// ------------------------------------------------------------
// Chrome / app-nav
// ------------------------------------------------------------
function renderTimelineChrome() {
  return '<div class="inst-chrome">' +
    '<div class="inst-lights"><span></span><span></span><span></span></div>' +
    '<div class="inst-title-bar">LatencyGuard — Timeline</div>' +
    '</div>';
}

function renderTimelineAppNav() {
  var sys = state.systemInfo || {};
  var cpu = sys.cpu ? (sys.cpu.replace('AMD ', '').replace(' 8-Core Processor', '')) : '—';
  var gpu = sys.gpu ? (sys.gpu.replace('NVIDIA ', '').replace('GeForce ', '')) : '—';
  var ram = sys.ram || '—';
  var html = '<div class="inst-app-nav">';
  html += '<div class="inst-brand"><span class="inst-brand-dot"></span>LatencyGuard</div>';
  html += '<div class="inst-sys">';
  html += '<span>' + escHtml(cpu) + '</span>';
  html += '<span>' + escHtml(gpu) + '</span>';
  html += '<span>' + escHtml(ram) + '</span>';
  html += '</div>';
  html += '<div class="inst-grow"></div>';
  html += '<button class="inst-btn inst-btn-ghost" style="padding:6px 12px;font-size:12px" onclick="setMode(\'simple\')">New scan</button>';
  html += '<div class="inst-cmdk" aria-hidden="true">⌘K</div>';
  html += '</div>';
  return html;
}

// ------------------------------------------------------------
// Top — headline + segment toggle
// ------------------------------------------------------------
function renderTimelineTop(sorted, seg) {
  var firstVal = getMetricValue(sorted[0], seg);
  var lastVal = getMetricValue(sorted[sorted.length - 1], seg);
  var segInfo = TL_SEGMENTS.filter(function (s) { return s.key === seg; })[0];

  var headline;
  if (firstVal != null && lastVal != null && firstVal !== lastVal) {
    headline = fmtMetric(firstVal, seg) + ' <span class="inst-alt">→</span> ' + fmtMetric(lastVal, seg);
  } else if (lastVal != null) {
    headline = fmtMetric(lastVal, seg) + ' <span class="inst-alt">today.</span>';
  } else {
    headline = 'No ' + segInfo.label.toLowerCase() + ' data yet.';
  }

  var days = 0;
  if (sorted[0] && sorted[sorted.length - 1] && sorted[0].capturedAt && sorted[sorted.length - 1].capturedAt) {
    var d1 = new Date(sorted[0].capturedAt), d2 = new Date(sorted[sorted.length - 1].capturedAt);
    days = Math.max(1, Math.round((d2 - d1) / (1000 * 60 * 60 * 24)));
  }

  var html = '<div class="tl-top">';
  html += '<div>';
  html += '<div class="inst-kicker">This rig · ' + days + ' day' + (days !== 1 ? 's' : '') + ' · ' + sorted.length + ' experiments</div>';
  html += '<h4 class="tl-h">' + headline + '</h4>';
  html += '</div>';
  html += '<div class="tl-seg" role="tablist">';
  TL_SEGMENTS.forEach(function (s) {
    var on = s.key === seg;
    html += '<button class="' + (on ? 'on' : '') + '" role="tab" aria-selected="' + on + '" data-seg="' + s.key + '">' + s.label + '</button>';
  });
  html += '</div>';
  html += '</div>';
  return html;
}

// ------------------------------------------------------------
// Chart — SVG line across experiments
// ------------------------------------------------------------
function renderTimelineChart(sorted, seg) {
  var W = 1000, H = 220, LEFT = 60, RIGHT = 980, TOP = 16, BOT = 200;
  var values = sorted.map(function (e) { return getMetricValue(e, seg); }).filter(function (v) { return v != null; });
  if (values.length === 0) {
    return '<div class="tl-chart tl-chart-empty"><div class="inst-mono-note">No ' + seg + ' metric available across experiments.</div></div>';
  }
  var maxV = Math.max.apply(null, values);
  var minV = Math.min.apply(null, values);
  if (maxV === minV) maxV = minV + 1;

  var coords = sorted.map(function (e, i) {
    var v = getMetricValue(e, seg);
    var x = LEFT + (i / Math.max(1, sorted.length - 1)) * (RIGHT - LEFT);
    var y = v == null ? BOT : TOP + ((maxV - v) / (maxV - minV)) * (BOT - TOP);
    return { x: x, y: y, v: v, e: e };
  });

  // Build path
  var d = '';
  coords.forEach(function (c, i) {
    if (c.v == null) return;
    d += (i === 0 ? 'M' : 'L') + c.x.toFixed(1) + ',' + c.y.toFixed(1) + ' ';
  });
  var area = d + 'L' + coords[coords.length - 1].x.toFixed(1) + ',' + BOT + ' L' + coords[0].x.toFixed(1) + ',' + BOT + ' Z';

  // Grid lines at 3 horizontal positions
  var grid = '';
  for (var g = 1; g <= 3; g++) {
    var y = TOP + (g / 4) * (BOT - TOP);
    grid += '<line x1="' + LEFT + '" y1="' + y + '" x2="' + RIGHT + '" y2="' + y + '" stroke="rgba(0,0,0,.06)" stroke-width="1"/>';
  }

  // Axis labels (y)
  var labels = '';
  labels += '<text x="10" y="' + (TOP + 4) + '" font-family="JetBrains Mono" font-size="10" fill="var(--ink-3)">' + fmtMetric(maxV, seg).replace(/ .*$/, '') + '</text>';
  labels += '<text x="48" y="' + ((TOP + BOT) / 2 + 4) + '" font-family="JetBrains Mono" font-size="10" fill="var(--ink-3)">' + fmtMetric((maxV + minV) / 2, seg).replace(/ .*$/, '') + '</text>';
  labels += '<text x="48" y="' + (BOT + 4) + '" font-family="JetBrains Mono" font-size="10" fill="var(--ink-3)">' + fmtMetric(minV, seg).replace(/ .*$/, '') + '</text>';

  // Points
  var points = '';
  var annots = '';
  coords.forEach(function (c, i) {
    if (c.v == null) return;
    var isFirst = i === 0;
    var isLast = i === coords.length - 1;
    if (isFirst) {
      points += '<circle cx="' + c.x + '" cy="' + c.y + '" r="5" fill="var(--accent)"/>';
      annots += '<text x="' + (c.x + 10) + '" y="' + (c.y - 6) + '" font-family="Inter" font-weight="500" font-size="11" fill="var(--accent)">Baseline · ' + fmtMetric(c.v, seg) + '</text>';
    } else if (isLast) {
      points += '<circle cx="' + c.x + '" cy="' + c.y + '" r="5.5" fill="var(--accent-2)"/>';
      annots += '<text x="' + (c.x - 100) + '" y="' + (c.y - 6) + '" font-family="Inter" font-weight="500" font-size="11" fill="var(--accent-2)" text-anchor="start">Now · ' + fmtMetric(c.v, seg) + '</text>';
    } else {
      points += '<circle cx="' + c.x + '" cy="' + c.y + '" r="3.2" fill="var(--ink)"/>';
      // Annotate every other mid-point to avoid crowd
      if (i % Math.max(1, Math.floor(coords.length / 5)) === 0) {
        var lbl = (c.e.label || '').slice(0, 14);
        if (lbl) annots += '<text x="' + (c.x + 6) + '" y="' + (c.y - 4) + '" font-family="Inter" font-size="10" fill="var(--ink-3)">' + escHtml(lbl) + '</text>';
      }
    }
  });

  var pctImprove = 0;
  if (coords[0] && coords[coords.length - 1] && coords[0].v != null && coords[coords.length - 1].v != null && coords[0].v > 0) {
    pctImprove = Math.round(((coords[0].v - coords[coords.length - 1].v) / coords[0].v) * 100);
  }
  var improveAnnot = '';
  if (pctImprove > 0) {
    improveAnnot = '<text x="' + (LEFT + 260) + '" y="' + (TOP + 24) + '" font-family="Inter" font-weight="500" font-size="13" fill="var(--accent)">' + pctImprove + '% reduction ↘</text>';
  }

  var baseline = '<line x1="' + LEFT + '" y1="' + BOT + '" x2="' + RIGHT + '" y2="' + BOT + '" stroke="var(--ink)" stroke-width="1"/>';
  var areaPath = '<path d="' + area + '" fill="rgba(11,11,15,.04)"/>';
  var linePath = '<path d="' + d + '" stroke="var(--ink)" stroke-width="2" fill="none" stroke-linecap="round"/>';

  var html = '<div class="tl-chart">';
  html += '<svg viewBox="0 0 ' + W + ' ' + H + '" width="100%" height="' + H + '" preserveAspectRatio="none" style="overflow:visible">';
  html += grid;
  html += baseline;
  html += areaPath;
  html += linePath;
  html += labels;
  html += points;
  html += annots;
  html += improveAnnot;
  html += '</svg>';
  html += '</div>';
  return html;
}

// ------------------------------------------------------------
// Stats — 4-cell strip
// ------------------------------------------------------------
function renderTimelineStats(sorted, seg) {
  var latest = sorted[sorted.length - 1] || {};
  var baseline = sorted[0] || {};

  var cpuTotalLatest = latest.cpuTotal || {};
  var cpuTotalBase = baseline.cpuTotal || {};
  var topoLatest = latest.interruptTopology || {};
  var topoBase = baseline.interruptTopology || {};

  var dpcLatest = (cpuTotalLatest.dpcPct || 0).toFixed(3);
  var dpcBase = (cpuTotalBase.dpcPct || 0).toFixed(3);
  var dpcDelta = (parseFloat(dpcBase) - parseFloat(dpcLatest)).toFixed(3);

  var cpu0Latest = (topoLatest.cpu0Share || 0).toFixed(1);
  var cpu0Base = (topoBase.cpu0Share || 0).toFixed(1);
  var cpu0Delta = (parseFloat(cpu0Base) - parseFloat(cpu0Latest)).toFixed(1);

  var checks = '—';
  if (state.auditData && state.auditData.summary) {
    checks = (state.auditData.summary.pass || 0) + ' / ' + (state.auditData.summary.total || 0);
  }

  var html = '<div class="tl-stats">';
  html += tlStatCell('DPC %',         dpcLatest,       dpcDelta > 0 ? '↓ ' + dpcDelta + '% vs baseline' : null);
  html += tlStatCell('CPU 0 share',   cpu0Latest + '%', cpu0Delta > 0 ? '↓ from ' + cpu0Base + '%' : null);
  html += tlStatCell('Experiments',   String(sorted.length), baseline.label ? 'Baseline ' + baseline.label.slice(0, 14) : null);
  html += tlStatCell('Checks passing', checks, null);
  html += '</div>';
  return html;
}

function tlStatCell(label, value, delta) {
  var html = '<div class="tl-stat">';
  html += '<div class="tl-stat-k">' + escHtml(label) + '</div>';
  html += '<div class="tl-stat-v">' + value + '</div>';
  if (delta) html += '<div class="tl-stat-d">' + escHtml(delta) + '</div>';
  html += '</div>';
  return html;
}

// ------------------------------------------------------------
// Log — experiment rows
// ------------------------------------------------------------
function renderTimelineLog(sorted) {
  var rows = sorted.slice().reverse().slice(0, 8); // most recent 8

  var html = '<div class="tl-log">';
  html += '<h5>Experiment log — most recent ' + rows.length + '</h5>';
  rows.forEach(function (e) {
    var id = (e.label || '').match(/EXP\w*/);
    var idStr = id ? id[0] : (e.label || '').slice(0, 8).toUpperCase();
    var title = (e.label || 'experiment').replace(/^\d{8}_\d{6}_/, '').replace(/_/g, ' ').toLowerCase();
    var date = (e.capturedAt || '').substring(5, 10).replace('-', ' / ');

    var cpu = e.cpuTotal || {};
    var dpc = cpu.dpcPct;
    var delta = '';
    if (dpc != null) {
      delta = dpc.toFixed(3) + '% DPC';
    }

    html += '<div class="tl-row">';
    html += '<div class="tl-row-id">' + escHtml(idStr) + '</div>';
    html += '<div class="tl-row-t">' + escHtml(title) + '</div>';
    html += '<div class="tl-row-delta">' + escHtml(delta) + '</div>';
    html += '<div class="tl-row-d">' + escHtml(date) + '</div>';
    html += '</div>';
  });
  html += '</div>';
  return html;
}

// ------------------------------------------------------------
// Loading / empty states
// ------------------------------------------------------------
function renderTimelineLoading() {
  return '<div class="tl-shell"><section class="inst-win">' +
    renderTimelineChrome() +
    '<div class="inst-finding inst-finding-empty">' +
    '<div class="inst-kicker">Loading · experiments</div>' +
    '<div class="inst-empty-h" style="font-size:32px;margin-top:12px">Reading experiment data…</div>' +
    '</div>' +
    '</section></div>';
}

function renderTimelineEmpty() {
  return '<div class="tl-shell"><section class="inst-win">' +
    renderTimelineChrome() +
    renderTimelineAppNav() +
    '<div class="inst-finding inst-finding-empty">' +
    '<div class="inst-finding-top">' +
    '<span class="inst-kicker">00 · no experiments</span>' +
    '<span class="inst-kicker">Ready</span>' +
    '</div>' +
    '<div class="inst-empty-hero">' +
    '<div class="inst-empty-dot"></div>' +
    '<div class="inst-empty-copy">' +
    '<h3 class="inst-empty-h">No experiments yet.</h3>' +
    '<p class="inst-empty-p">Run <code style="font-family:var(--font-mono);font-size:12px;color:var(--accent)">pipeline.ps1</code> at the repo root to capture experiment data. Each run becomes a point on the timeline.</p>' +
    '</div></div>' +
    '</div>' +
    '</section></div>';
}

// ------------------------------------------------------------
// Events
// ------------------------------------------------------------
function wireTimelineEvents() {
  document.querySelectorAll('.tl-seg button').forEach(function (b) {
    b.addEventListener('click', function () {
      window.__tlSegment = b.dataset.seg;
      var app = document.getElementById('app');
      if (app) renderTimeline(app);
    });
  });
}

// ------------------------------------------------------------
// Metric helpers
// ------------------------------------------------------------
function getMetricValue(exp, seg) {
  if (!exp) return null;
  if (seg === 'mouse') {
    return exp.cpuTotal ? exp.cpuTotal.dpcPct : null;
  }
  if (seg === 'frames') {
    var ft = exp.frameTiming || (exp.inputLatency && exp.inputLatency.frameTiming);
    if (ft && ft.frameTimeMs && ft.frameTimeMs.p95 != null) return ft.frameTimeMs.p95;
    return null;
  }
  if (seg === 'system') {
    return exp.interruptTopology ? exp.interruptTopology.cpu0Share : null;
  }
  return null;
}

function fmtMetric(v, seg) {
  if (v == null) return '—';
  if (seg === 'mouse')  return v.toFixed(3) + ' % DPC';
  if (seg === 'frames') return v.toFixed(1) + ' ms p95';
  if (seg === 'system') return v.toFixed(1) + ' % CPU0';
  return String(v);
}

// Expose to app.js
window.renderTimeline = renderTimeline;
