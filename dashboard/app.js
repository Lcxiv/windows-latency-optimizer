// ============================================================
// CONSTANTS
// ============================================================
const BASELINE_ID = 'baseline';

const CHART_DEFAULTS = {
  responsive: true,
  maintainAspectRatio: true,
  plugins: {
    legend: { labels: { color: '#94a3b8', font: { size: 11 }, boxWidth: 12 } },
    tooltip: {
      backgroundColor: '#1c2840',
      borderColor: '#1e3a5f',
      borderWidth: 1,
      titleColor: '#e2e8f0',
      bodyColor: '#94a3b8',
      padding: 10
    }
  },
  scales: {
    x: { ticks: { color: '#7a8fa8', font: { size: 10 } }, grid: { color: 'rgba(30, 58, 95, 0.5)' } },
    y: { ticks: { color: '#7a8fa8', font: { size: 10 } }, grid: { color: 'rgba(30, 58, 95, 0.5)' } }
  }
};

const COLORS = {
  blue: '#3b82f6', green: '#10b981', amber: '#f59e0b', red: '#ef4444',
  purple: '#a855f7', cyan: '#06b6d4',
  blueA: 'rgba(59,130,246,0.7)', greenA: 'rgba(16,185,129,0.7)',
  amberA: 'rgba(245,158,11,0.7)', redA: 'rgba(239,68,68,0.7)',
  purpleA: 'rgba(168,85,247,0.7)', cyanA: 'rgba(6,182,212,0.7)',
};

const PALETTE = [COLORS.blue, COLORS.green, COLORS.amber, COLORS.red, COLORS.purple, COLORS.cyan];
const PALETTE_A = [COLORS.blueA, COLORS.greenA, COLORS.amberA, COLORS.redA, COLORS.purpleA, COLORS.cyanA];

// ============================================================
// STATE
// ============================================================
const AppState = {
  view: 'table',
  detailId: null,
  compareIds: [],
  sortColumn: 'date',
  sortDir: 'desc',
  tagFilter: [],
  selectedIds: new Set(),
  timelineMetric: 'DPCTimePct',
};

let baseline = null;
let charts = {};

// ============================================================
// INIT
// ============================================================
document.addEventListener('DOMContentLoaded', () => {
  if (!window.EXPERIMENTS || !window.EXPERIMENTS.length) {
    document.body.innerHTML = '<div style="padding:40px;color:#ef4444">Error: experiments.js not loaded.</div>';
    return;
  }

  if (window.EXPERIMENTS_GENERATED && window.EXPERIMENTS_GENERATED.length) {
    const existingIds = new Set(window.EXPERIMENTS.map(e => e.id));
    window.EXPERIMENTS_GENERATED.forEach(e => {
      if (!existingIds.has(e.id)) window.EXPERIMENTS.push(e);
    });
  }

  baseline = window.EXPERIMENTS.find(e => e.id === BASELINE_ID) || window.EXPERIMENTS[0];
  handleRoute();
  window.addEventListener('hashchange', handleRoute);
});

// ============================================================
// ROUTING
// ============================================================
function handleRoute() {
  const hash = location.hash || '#table';
  if (hash.startsWith('#detail/')) {
    AppState.view = 'detail';
    AppState.detailId = decodeURIComponent(hash.replace('#detail/', ''));
  } else if (hash.startsWith('#compare')) {
    AppState.view = 'compare';
    const params = new URLSearchParams(hash.split('?')[1] || '');
    AppState.compareIds = (params.get('ids') || '').split(',').filter(Boolean);
  } else {
    AppState.view = 'table';
  }
  render();
}

function navigateTo(hash) {
  location.hash = hash;
}

// ============================================================
// RENDER DISPATCHER
// ============================================================
function render() {
  destroyAllCharts();
  const tableView = document.getElementById('tableView');
  const detailView = document.getElementById('detailView');
  const compareView = document.getElementById('compareView');

  tableView.innerHTML = '';
  detailView.innerHTML = '';
  compareView.innerHTML = '';
  tableView.classList.add('hidden');
  detailView.classList.add('hidden');
  compareView.classList.add('hidden');

  if (AppState.view === 'detail') {
    renderNavBar('detail');
    detailView.classList.remove('hidden');
    renderDetailView();
  } else if (AppState.view === 'compare') {
    renderNavBar('compare');
    compareView.classList.remove('hidden');
    renderCompareView();
  } else {
    renderNavBar('table');
    tableView.classList.remove('hidden');
    renderTableView();
  }
}

// ============================================================
// NAV BAR
// ============================================================
function renderNavBar(view) {
  const nav = document.getElementById('navBar');
  if (view === 'table') {
    nav.innerHTML = '<span class="nav-breadcrumb-active">Experiments</span>' +
      '<span class="nav-breadcrumb" style="margin-left:auto;font-size:11px;color:var(--muted)">' +
      window.EXPERIMENTS.length + ' experiments</span>';
  } else if (view === 'detail') {
    const exp = getExp(AppState.detailId);
    const name = exp ? escHtml(exp.shortName || exp.name) : AppState.detailId;
    nav.innerHTML = '<button class="nav-back" onclick="navigateTo(\'#table\')">&larr; All Experiments</button>' +
      '<span class="nav-breadcrumb"> / </span>' +
      '<span class="nav-breadcrumb-active">' + name + '</span>';
  } else {
    nav.innerHTML = '<button class="nav-back" onclick="navigateTo(\'#table\')">&larr; All Experiments</button>' +
      '<span class="nav-breadcrumb"> / </span>' +
      '<span class="nav-breadcrumb-active">Compare (' + AppState.compareIds.length + ')</span>';
  }
}

// ============================================================
// HELPERS
// ============================================================
function getExp(id) {
  return window.EXPERIMENTS.find(e => e.id === id);
}

function escHtml(s) {
  if (s == null) return '';
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

function makeNoData(msg, hint) {
  return '<div class="no-data"><div class="no-data-icon">---</div>' +
    '<div class="no-data-text">' + escHtml(msg) + '</div>' +
    (hint ? '<div class="no-data-hint">' + escHtml(hint) + '</div>' : '') + '</div>';
}

function destroyChart(key) {
  if (charts[key]) { charts[key].destroy(); charts[key] = null; }
}

function destroyAllCharts() {
  Object.keys(charts).forEach(k => destroyChart(k));
}

function deepMerge(base, override) {
  const result = Object.assign({}, base);
  for (const k in override) {
    if (typeof override[k] === 'object' && !Array.isArray(override[k]) && override[k] !== null) {
      result[k] = deepMerge(base[k] || {}, override[k]);
    } else {
      result[k] = override[k];
    }
  }
  return result;
}

function chartOpts(extra) {
  return deepMerge(CHART_DEFAULTS, extra || {});
}

function fmtDate(dateStr) {
  if (!dateStr) return '--';
  const d = new Date(dateStr);
  return d.toLocaleDateString('en-US', { month:'short', day:'numeric', year:'numeric' }) +
    ' ' + d.toLocaleTimeString('en-US', { hour:'2-digit', minute:'2-digit' });
}

function safeNum(v, decimals) {
  if (v == null || isNaN(v)) return '--';
  return Number(v).toFixed(decimals != null ? decimals : 2);
}

// Safely get a perf counter avg value, handling both curated and generated field names
function perfVal(perf, key) {
  if (!perf) return null;
  if (perf[key] && perf[key].avg != null) return perf[key].avg;
  return null;
}

function getStatus(exp) {
  if (exp.latencymon) return exp.latencymon.result === 'PASS' ? 'PASS' : 'REVIEW';
  return 'N/A';
}

function getAllTags() {
  const tags = new Set();
  window.EXPERIMENTS.forEach(e => {
    if (e.tags && Array.isArray(e.tags)) e.tags.forEach(t => tags.add(t));
  });
  return Array.from(tags).sort();
}

function getMetricValue(exp, metric) {
  if (metric === 'DPCTimePct' && exp.performance && exp.performance.DPCTimePct) return exp.performance.DPCTimePct.avg;
  if (metric === 'InterruptTimePct' && exp.performance && exp.performance.InterruptTimePct) return exp.performance.InterruptTimePct.avg;
  if (metric === 'ProcessorTimePct' && exp.performance && exp.performance.ProcessorTimePct) return exp.performance.ProcessorTimePct.avg;
  if (metric === 'FPSAvg' && exp.frameTiming) return exp.frameTiming.fps.avg;
  if (metric === 'FrameTimeP99' && exp.frameTiming) return exp.frameTiming.frameTimeMs.p99;
  if (metric === 'PagesSec' && exp.performance && exp.performance.PagesSec) return exp.performance.PagesSec.avg;
  if (metric === 'ContextSwitchesSec' && exp.performance && exp.performance.ContextSwitchesSec) return exp.performance.ContextSwitchesSec.avg;
  return null;
}

function getMetricLabel(metric) {
  const map = {
    DPCTimePct: '% DPC Time',
    InterruptTimePct: '% Interrupt Time',
    ProcessorTimePct: '% CPU Time',
    FPSAvg: 'FPS (avg)',
    FrameTimeP99: 'Frame Time p99 (ms)',
    PagesSec: 'Pages/sec',
    ContextSwitchesSec: 'Context Switches/sec',
  };
  return map[metric] || metric;
}

function frameTimeColor(ms) {
  if (ms == null) return 'var(--muted)';
  if (ms < 8) return COLORS.green;
  if (ms < 16) return COLORS.amber;
  return COLORS.red;
}
