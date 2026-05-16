/* ============================================================
 * Latency Monitor â€” Core Shell
 * File:// compatible, no ES modules, no fetch, no pushState.
 * Chart.js 4.4.0 (CDN + local fallback).
 * ============================================================ */

var REFRESH_INTERVAL_MS = 2000;
var STALE_THRESHOLD_MS  = 10000;

/* â”€â”€ State â”€â”€ */
var MonitorState = {
  view:             'heatmap',
  lastTimestamp:    null,
  isCollectorAlive: false,
  refreshTimer:     null
};

/* â”€â”€ Chart registry â”€â”€ */
var MonitorCharts = {
  _charts: {},

  create: function(key, ctx, config) {
    this.destroy(key);
    this._charts[key] = new Chart(ctx, config);
    return this._charts[key];
  },

  destroy: function(key) {
    if (this._charts[key]) {
      this._charts[key].destroy();
      delete this._charts[key];
    }
  },

  destroyAll: function() {
    var keys = Object.keys(this._charts);
    for (var i = 0; i < keys.length; i++) {
      this.destroy(keys[i]);
    }
  }
};

/* â”€â”€ Color palette â”€â”€ */
var MON_COLORS = {
  blue:   '#5b8fd9',
  green:  '#4caf82',
  amber:  '#c49a2c',
  red:    '#c75a5a',
  purple: '#8c6ec4',
  cyan:   '#5ba8c4',
  muted:  '#6b7a8e',
  text:   '#e3e7ed',
  greenA: 'rgba(76,175,130,0.10)',
  amberA: 'rgba(196,154,44,0.10)',
  redA:   'rgba(199,90,90,0.10)',
  blueA:  'rgba(91,143,217,0.10)'
};

/* â”€â”€ Chart.js defaults â”€â”€ */
var MON_CHART_DEFAULTS = {
  responsive:          true,
  maintainAspectRatio: true,
  animation:           false,
  plugins: {
    legend: {
      labels: { color: '#6b7a8e', font: { size: 11, weight: '500' }, boxWidth: 10 }
    },
    tooltip: {
      backgroundColor: 'rgba(10, 15, 28, 0.95)',
      borderColor:     'rgba(56, 92, 148, 0.2)',
      borderWidth:     1,
      titleColor:      '#e3e7ed',
      bodyColor:       '#6b7a8e',
      padding:         12
    }
  },
  scales: {
    x: {
      ticks: { color: '#555f6e', font: { size: 10 } },
      grid:  { color: 'rgba(40, 55, 80, 0.15)' }
    },
    y: {
      ticks: { color: '#555f6e', font: { size: 10 } },
      grid:  { color: 'rgba(40, 55, 80, 0.15)' }
    }
  }
};

/* â”€â”€ View registry â”€â”€ */
var VIEWS = ['heatmap', 'timeline', 'processes', 'drivers', 'audit', 'network', 'history', 'command'];
var VIEW_LABELS = {
  heatmap:   'CPU Heatmap',
  timeline:  'Timeline',
  processes: 'Processes',
  drivers:   'Drivers',
  audit:     'Pre-Gaming',
  network:   'Network',
  history:   'History',
  command:   'Command Center'
};

/* â”€â”€ View render dispatch â”€â”€ */
var VIEW_RENDERERS = {
  heatmap:   function() { if (typeof renderHeatmapView   === 'function') renderHeatmapView();   else renderNoViewYet('heatmap');   },
  timeline:  function() { if (typeof renderTimelineView  === 'function') renderTimelineView();  else renderNoViewYet('timeline');  },
  processes: function() { if (typeof renderProcessesView === 'function') renderProcessesView(); else renderNoViewYet('processes'); },
  drivers:   function() { if (typeof renderDriversView   === 'function') renderDriversView();   else renderNoViewYet('drivers');   },
  audit:     function() { if (typeof renderAuditView     === 'function') renderAuditView();     else renderNoViewYet('audit');     },
  network:   function() { if (typeof renderNetworkView   === 'function') renderNetworkView();   else renderNoViewYet('network');   },
  history:   function() { if (typeof renderHistoryView   === 'function') renderHistoryView();   else renderNoViewYet('history');   },
  command:   function() { if (typeof renderCommandView   === 'function') renderCommandView();   else renderNoViewYet('command');   }
};

/* â”€â”€ Boot â”€â”€ */
document.addEventListener('DOMContentLoaded', function() {
  /* Initial check of already-loaded snapshot */
  checkCollectorAlive();
  handleRoute();
  window.addEventListener('hashchange', handleRoute);
  startAutoRefresh();
});

/* â”€â”€ Routing â”€â”€ */
function handleRoute() {
  var hash = location.hash.replace('#', '') || 'heatmap';
  if (VIEWS.indexOf(hash) === -1) hash = 'heatmap';
  MonitorState.view = hash;
  renderAll();
}

function navigateTo(hash) {
  location.hash = hash;
}

/* â”€â”€ Auto-refresh â”€â”€ */
function startAutoRefresh() {
  if (MonitorState.refreshTimer) clearInterval(MonitorState.refreshTimer);
  MonitorState.refreshTimer = setInterval(refreshData, REFRESH_INTERVAL_MS);
}

function refreshData() {
  /* Remove old snapshot script tag */
  var old = document.getElementById('snapshotScript');
  if (old) old.parentNode.removeChild(old);

  var script    = document.createElement('script');
  script.id     = 'snapshotScript';
  script.src    = 'data/snapshot.js?t=' + Date.now();
  script.onerror = function() {
    MonitorState.isCollectorAlive = false;
    updateStatusBar();
  };
  script.onload = function() {
    checkCollectorAlive();
    renderAll();
  };
  document.body.appendChild(script);
}

/* â”€â”€ Collector health check â”€â”€ */
function checkCollectorAlive() {
  if (!window.MONITOR_SNAPSHOT || !window.MONITOR_SNAPSHOT.timestamp) {
    MonitorState.isCollectorAlive = false;
    return;
  }
  var snapshotTime = new Date(window.MONITOR_SNAPSHOT.timestamp).getTime();
  var age = Date.now() - snapshotTime;
  MonitorState.isCollectorAlive = age < STALE_THRESHOLD_MS;
  MonitorState.lastTimestamp    = window.MONITOR_SNAPSHOT.timestamp;
}

/* â”€â”€ Render orchestration â”€â”€ */
function renderAll() {
  /* Tear down all charts before re-rendering â€” avoids canvas reuse errors */
  MonitorCharts.destroyAll();

  renderNavBar();
  updateStatusBar();

  /* Hide all views */
  for (var i = 0; i < VIEWS.length; i++) {
    var el = document.getElementById(VIEWS[i] + 'View');
    if (el) {
      el.innerHTML    = '';
      el.style.display = 'none';
    }
  }

  /* Show active view */
  var activeEl = document.getElementById(MonitorState.view + 'View');
  if (activeEl) activeEl.style.display = 'block';

  /* Dispatch to view renderer */
  var renderer = VIEW_RENDERERS[MonitorState.view];
  if (renderer) renderer();
}

/* â”€â”€ Nav bar â”€â”€ */
function renderNavBar() {
  var nav  = document.getElementById('navBar');
  if (!nav) return;
  var html = '';
  for (var i = 0; i < VIEWS.length; i++) {
    var v      = VIEWS[i];
    var active = MonitorState.view === v ? ' active' : '';
    html += '<button class="nav-tab' + active + '" onclick="navigateTo(\'' + v + '\')">' + VIEW_LABELS[v] + '</button>';
  }
  nav.innerHTML = html;
}

/* â”€â”€ Status bar â”€â”€ */
function updateStatusBar() {
  var bar = document.getElementById('statusBar');
  if (!bar) return;

  if (MonitorState.isCollectorAlive) {
    var snap  = window.MONITOR_SNAPSHOT;
    var meta  = snap.meta || {};
    var host  = meta.hostname   ? escHtml(meta.hostname) : 'unknown';
    var count = meta.sampleCount != null ? meta.sampleCount : '?';

    bar.innerHTML =
      '<span class="collector-dot alive"></span>' +
      '<span class="status-label alive">Live</span>' +
      '<span class="status-sep">|</span>' +
      '<span class="status-chip">' + host + '</span>' +
      '<span class="status-sep">|</span>' +
      '<span class="status-chip">Sample #' + count + '</span>';
  } else {
    bar.innerHTML =
      '<span class="collector-dot dead"></span>' +
      '<span class="status-label dead">Collector not running</span>' +
      '<span class="status-sep">|</span>' +
      '<span class="status-hint">Run: <code>scripts\\monitor_collector.ps1</code></span>';
  }
}

/* â”€â”€ Placeholder for views not yet implemented â”€â”€ */
function renderNoViewYet(viewName) {
  var el = document.getElementById(viewName + 'View');
  if (!el) return;
  el.innerHTML =
    '<div class="no-data">' +
    '  <div class="no-data-icon">&#9881;</div>' +
    '  <div class="no-data-text">' + escHtml(VIEW_LABELS[viewName]) + ' view coming soon</div>' +
    '  <div class="no-data-hint">views/' + escHtml(viewName) + '.js not yet loaded</div>' +
    '</div>';
}

/* â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
 * Utility helpers â€” shared across all view modules
 * â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ */

function escHtml(s) {
  if (s == null) return '';
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function safeNum(v, decimals) {
  if (v == null || v === '' || isNaN(Number(v))) return '--';
  return Number(v).toFixed(decimals != null ? decimals : 2);
}

/**
 * Return a CSS color string based on a percentage value.
 * <1% = green, <5% = amber, >=5% = red.
 */
function severityColor(pct) {
  if (pct < 1) return MON_COLORS.green;
  if (pct < 5) return MON_COLORS.amber;
  return MON_COLORS.red;
}

/**
 * Background variant (low-opacity) of severityColor.
 */
function severityBg(pct) {
  if (pct < 1) return MON_COLORS.greenA;
  if (pct < 5) return MON_COLORS.amberA;
  return MON_COLORS.redA;
}

/**
 * Shallow-deep merge two plain objects. Used for Chart.js config overrides.
 */
function deepMerge(base, override) {
  var result = {};
  var k;
  for (k in base)     result[k] = base[k];
  for (k in override) {
    if (
      typeof override[k] === 'object' &&
      !Array.isArray(override[k]) &&
      override[k] !== null
    ) {
      result[k] = deepMerge(base[k] || {}, override[k]);
    } else {
      result[k] = override[k];
    }
  }
  return result;
}

/**
 * Produce a Chart.js options object merged with MON_CHART_DEFAULTS.
 * Pass extra options to override/extend. Returns a new object each call.
 */
function monChartOpts(extra) {
  return deepMerge(MON_CHART_DEFAULTS, extra || {});
}

/**
 * Format a UTC ISO timestamp as a local HH:MM:SS string.
 */
function fmtTime(isoStr) {
  if (!isoStr) return '--';
  var d = new Date(isoStr);
  if (isNaN(d.getTime())) return '--';
  var hh = String(d.getHours()).padStart   ? d.getHours()   : d.getHours();
  var mm = d.getMinutes();
  var ss = d.getSeconds();
  return (hh < 10 ? '0' : '') + hh + ':' + (mm < 10 ? '0' : '') + mm + ':' + (ss < 10 ? '0' : '') + ss;
}

/**
 * Build a section header element (matches dashboard style).
 */
function sectionHeader(title, badge) {
  var b = badge != null ? '<span class="section-badge">' + escHtml(String(badge)) + '</span>' : '';
  return '<div class="section-header"><h2>' + escHtml(title) + '</h2><div class="section-line"></div>' + b + '</div>';
}

/**
 * Build a summary card HTML string.
 * opts: { label, value, unit, sub, color, badge, badgeClass }
 */
function summaryCard(opts) {
  var color      = opts.color      || 'blue';
  var badgeHtml  = '';
  if (opts.badge != null) {
    var bc = opts.badgeClass || 'badge-na';
    badgeHtml = '<div class="card-badge ' + bc + '">' + escHtml(String(opts.badge)) + '</div>';
  }
  return (
    '<div class="card ' + color + '">' +
    '  <div class="card-label">' + escHtml(opts.label || '') + '</div>' +
    '  <div class="card-value">' + escHtml(String(opts.value != null ? opts.value : '--')) +
    '    <span class="card-unit">' + escHtml(opts.unit || '') + '</span>' +
    '  </div>' +
    (opts.sub ? '<div class="card-sub">' + escHtml(opts.sub) + '</div>' : '') +
    badgeHtml +
    '</div>'
  );
}
