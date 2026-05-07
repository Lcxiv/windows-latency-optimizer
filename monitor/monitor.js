/* ============================================================
 * Latency Monitor — Core Shell
 * File:// compatible, no ES modules, no fetch, no pushState.
 * Chart.js 4.4.0 (CDN + local fallback).
 * ============================================================ */

var REFRESH_INTERVAL_MS = 2000;
var STALE_THRESHOLD_MS  = 10000;

/* ── State ── */
var MonitorState = {
  view:             'heatmap',
  lastTimestamp:    null,
  isCollectorAlive: false,
  refreshTimer:     null
};

/* ── Chart registry ── */
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

/* ── Color palette ── */
var MON_COLORS = {
  blue:   '#3b82f6',
  green:  '#10b981',
  amber:  '#f59e0b',
  red:    '#ef4444',
  purple: '#a855f7',
  cyan:   '#06b6d4',
  muted:  '#7a8fa8',
  text:   '#e2e8f0',
  greenA: 'rgba(16,185,129,0.15)',
  amberA: 'rgba(245,158,11,0.15)',
  redA:   'rgba(239,68,68,0.15)',
  blueA:  'rgba(59,130,246,0.15)'
};

/* ── Chart.js defaults ── */
var MON_CHART_DEFAULTS = {
  responsive:          true,
  maintainAspectRatio: true,
  animation:           false,
  plugins: {
    legend: {
      labels: { color: '#94a3b8', font: { size: 11 }, boxWidth: 12 }
    },
    tooltip: {
      backgroundColor: '#1c2840',
      borderColor:     '#1e3a5f',
      borderWidth:     1,
      titleColor:      '#e2e8f0',
      bodyColor:       '#94a3b8',
      padding:         10
    }
  },
  scales: {
    x: {
      ticks: { color: '#7a8fa8', font: { size: 10 } },
      grid:  { color: 'rgba(30,58,95,0.5)' }
    },
    y: {
      ticks: { color: '#7a8fa8', font: { size: 10 } },
      grid:  { color: 'rgba(30,58,95,0.5)' }
    }
  }
};

/* ── View registry ── */
var VIEWS = ['heatmap', 'timeline', 'processes', 'drivers', 'audit', 'history'];
var VIEW_LABELS = {
  heatmap:   'CPU Heatmap',
  timeline:  'Timeline',
  processes: 'Processes',
  drivers:   'Drivers',
  audit:     'Pre-Gaming',
  history:   'History'
};

/* ── View render dispatch ── */
var VIEW_RENDERERS = {
  heatmap:   function() { if (typeof renderHeatmapView   === 'function') renderHeatmapView();   else renderNoViewYet('heatmap');   },
  timeline:  function() { if (typeof renderTimelineView  === 'function') renderTimelineView();  else renderNoViewYet('timeline');  },
  processes: function() { if (typeof renderProcessesView === 'function') renderProcessesView(); else renderNoViewYet('processes'); },
  drivers:   function() { if (typeof renderDriversView   === 'function') renderDriversView();   else renderNoViewYet('drivers');   },
  audit:     function() { if (typeof renderAuditView     === 'function') renderAuditView();     else renderNoViewYet('audit');     },
  history:   function() { if (typeof renderHistoryView   === 'function') renderHistoryView();   else renderNoViewYet('history');   }
};

/* ── Boot ── */
document.addEventListener('DOMContentLoaded', function() {
  /* Initial check of already-loaded snapshot */
  checkCollectorAlive();
  handleRoute();
  window.addEventListener('hashchange', handleRoute);
  startAutoRefresh();
});

/* ── Routing ── */
function handleRoute() {
  var hash = location.hash.replace('#', '') || 'heatmap';
  if (VIEWS.indexOf(hash) === -1) hash = 'heatmap';
  MonitorState.view = hash;
  renderAll();
}

function navigateTo(hash) {
  location.hash = hash;
}

/* ── Auto-refresh ── */
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

/* ── Collector health check ── */
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

/* ── Render orchestration ── */
function renderAll() {
  /* Tear down all charts before re-rendering — avoids canvas reuse errors */
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

/* ── Nav bar ── */
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

/* ── Status bar ── */
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

/* ── Placeholder for views not yet implemented ── */
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

/* ────────────────────────────────────────────────────────────
 * Utility helpers — shared across all view modules
 * ──────────────────────────────────────────────────────────── */

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
