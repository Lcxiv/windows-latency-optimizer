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

// ============================================================
// TABLE VIEW
// ============================================================
function renderTableView() {
  const container = document.getElementById('tableView');

  // Tag filter
  const allTags = getAllTags();
  let tagHtml = '<div class="tag-bar"><span class="tag-bar-label">Tags</span>';
  allTags.forEach(tag => {
    const active = AppState.tagFilter.includes(tag);
    tagHtml += '<button class="tag-pill' + (active ? ' active' : '') + '" onclick="toggleTag(\'' + escHtml(tag) + '\')">' + escHtml(tag) + '</button>';
  });
  tagHtml += '</div>';

  // Compare bar
  const selCount = AppState.selectedIds.size;
  let compareHtml = '<div class="compare-bar">' +
    '<button class="compare-btn" ' + (selCount < 2 ? 'disabled' : '') + ' onclick="goCompare()">Compare Selected</button>' +
    '<span class="compare-count">' + (selCount > 0 ? selCount + ' selected' : 'Select 2+ experiments to compare') + '</span></div>';

  // Filter and sort experiments
  let exps = window.EXPERIMENTS.slice();
  if (AppState.tagFilter.length > 0) {
    exps = exps.filter(e => e.tags && AppState.tagFilter.some(t => e.tags.includes(t)));
  }
  exps = sortExperiments(exps);

  // Table
  const cols = [
    { key: 'cb', label: '', noSort: true },
    { key: 'name', label: 'Name' },
    { key: 'date', label: 'Date' },
    { key: 'tags', label: 'Tags', noSort: true },
    { key: 'dpc', label: 'DPC%' },
    { key: 'interrupt', label: 'Interrupt%' },
    { key: 'fps', label: 'FPS' },
    { key: 'frametime', label: 'Frame Time p99' },
    { key: 'cpu', label: 'CPU%' },
    { key: 'status', label: 'Status' },
  ];

  let tableHtml = '<div class="exp-table-wrap"><table class="exp-table"><thead><tr>';
  cols.forEach(c => {
    const isSorted = AppState.sortColumn === c.key;
    const cls = c.noSort ? 'no-sort' : (isSorted ? ('sorted-' + AppState.sortDir) : '');
    const onclick = c.noSort ? '' : ' onclick="sortBy(\'' + c.key + '\')"';
    tableHtml += '<th class="' + cls + '"' + onclick + '>' + (c.key === 'cb' ? '' : c.label) + '</th>';
  });
  tableHtml += '</tr></thead><tbody>';

  exps.forEach(exp => {
    const perf = exp.performance;
    const ft = exp.frameTiming;
    const status = getStatus(exp);
    const checked = AppState.selectedIds.has(exp.id) ? ' checked' : '';

    tableHtml += '<tr>';
    tableHtml += '<td class="cb-cell"><input type="checkbox"' + checked + ' onchange="toggleSelect(\'' + escHtml(exp.id) + '\', this.checked)"></td>';
    tableHtml += '<td><a class="name-link" href="#detail/' + encodeURIComponent(exp.id) + '">' + escHtml(exp.shortName || exp.name) + '</a></td>';
    tableHtml += '<td>' + fmtDate(exp.date) + '</td>';
    tableHtml += '<td class="tag-cell">' + (exp.tags || []).map(t => '<span class="tag-pill">' + escHtml(t) + '</span>').join('') + '</td>';
    tableHtml += '<td>' + (perf && perf.DPCTimePct ? safeNum(perf.DPCTimePct.avg, 3) + '%' : '--') + '</td>';
    tableHtml += '<td>' + (perf && perf.InterruptTimePct ? safeNum(perf.InterruptTimePct.avg, 3) + '%' : '--') + '</td>';
    tableHtml += '<td>' + (ft ? safeNum(ft.fps.avg, 1) : '--') + '</td>';
    tableHtml += '<td>' + (ft ? safeNum(ft.frameTimeMs.p99, 2) + ' ms' : '--') + '</td>';
    tableHtml += '<td>' + (perf && perf.ProcessorTimePct ? safeNum(perf.ProcessorTimePct.avg, 1) + '%' : '--') + '</td>';
    tableHtml += '<td><span class="status-badge status-' + status.toLowerCase().replace('/', '') + '">' + status + '</span></td>';
    tableHtml += '</tr>';
  });

  if (exps.length === 0) {
    tableHtml += '<tr><td colspan="' + cols.length + '" style="text-align:center;padding:40px;color:var(--muted)">No experiments match the selected filters</td></tr>';
  }

  tableHtml += '</tbody></table></div>';

  // Metric timeline
  const metricOptions = ['DPCTimePct','InterruptTimePct','ProcessorTimePct','FPSAvg','FrameTimeP99','PagesSec','ContextSwitchesSec'];
  let timelineHtml = '<div class="metric-timeline-section">' +
    '<div class="section-header"><h2>Metric Timeline</h2><div class="section-line"></div>' +
    '<select class="metric-select" id="metricSelect" onchange="changeTimelineMetric(this.value)">';
  metricOptions.forEach(m => {
    timelineHtml += '<option value="' + m + '"' + (m === AppState.timelineMetric ? ' selected' : '') + '>' + getMetricLabel(m) + '</option>';
  });
  timelineHtml += '</select></div>';
  timelineHtml += '<div class="chart-card"><div class="chart-wrap" id="timelineChartWrap"></div></div></div>';

  container.innerHTML = tagHtml + compareHtml + tableHtml + timelineHtml;

  // Render timeline chart
  renderTimelineChart(exps);
}

function sortExperiments(exps) {
  const col = AppState.sortColumn;
  const dir = AppState.sortDir === 'asc' ? 1 : -1;

  return exps.sort((a, b) => {
    let va, vb;
    switch (col) {
      case 'name': va = (a.shortName || a.name || '').toLowerCase(); vb = (b.shortName || b.name || '').toLowerCase(); break;
      case 'date': va = a.date || ''; vb = b.date || ''; break;
      case 'dpc': va = a.performance && a.performance.DPCTimePct ? a.performance.DPCTimePct.avg : -1; vb = b.performance && b.performance.DPCTimePct ? b.performance.DPCTimePct.avg : -1; break;
      case 'interrupt': va = a.performance && a.performance.InterruptTimePct ? a.performance.InterruptTimePct.avg : -1; vb = b.performance && b.performance.InterruptTimePct ? b.performance.InterruptTimePct.avg : -1; break;
      case 'fps': va = a.frameTiming ? a.frameTiming.fps.avg : -1; vb = b.frameTiming ? b.frameTiming.fps.avg : -1; break;
      case 'frametime': va = a.frameTiming ? a.frameTiming.frameTimeMs.p99 : -1; vb = b.frameTiming ? b.frameTiming.frameTimeMs.p99 : -1; break;
      case 'cpu': va = a.performance && a.performance.ProcessorTimePct ? a.performance.ProcessorTimePct.avg : -1; vb = b.performance && b.performance.ProcessorTimePct ? b.performance.ProcessorTimePct.avg : -1; break;
      case 'status': va = getStatus(a); vb = getStatus(b); break;
      default: va = a.date || ''; vb = b.date || '';
    }
    if (va < vb) return -1 * dir;
    if (va > vb) return 1 * dir;
    return 0;
  });
}

function sortBy(col) {
  if (AppState.sortColumn === col) {
    AppState.sortDir = AppState.sortDir === 'asc' ? 'desc' : 'asc';
  } else {
    AppState.sortColumn = col;
    AppState.sortDir = col === 'name' ? 'asc' : 'desc';
  }
  render();
}

function toggleTag(tag) {
  const idx = AppState.tagFilter.indexOf(tag);
  if (idx === -1) { AppState.tagFilter.push(tag); }
  else { AppState.tagFilter.splice(idx, 1); }
  render();
}

function toggleSelect(id, checked) {
  if (checked) { AppState.selectedIds.add(id); }
  else { AppState.selectedIds.delete(id); }
  // Update compare bar without full re-render
  const btn = document.querySelector('.compare-btn');
  const cnt = document.querySelector('.compare-count');
  if (btn && cnt) {
    btn.disabled = AppState.selectedIds.size < 2;
    cnt.textContent = AppState.selectedIds.size > 0 ? AppState.selectedIds.size + ' selected' : 'Select 2+ experiments to compare';
  }
}

function goCompare() {
  if (AppState.selectedIds.size < 2) return;
  navigateTo('#compare?ids=' + Array.from(AppState.selectedIds).join(','));
}

function changeTimelineMetric(metric) {
  AppState.timelineMetric = metric;
  const exps = getFilteredSortedExps();
  renderTimelineChart(exps);
}

function getFilteredSortedExps() {
  let exps = window.EXPERIMENTS.slice();
  if (AppState.tagFilter.length > 0) {
    exps = exps.filter(e => e.tags && AppState.tagFilter.some(t => e.tags.includes(t)));
  }
  return exps.sort((a, b) => (a.date || '').localeCompare(b.date || ''));
}

function renderTimelineChart(exps) {
  destroyChart('timeline');
  const wrap = document.getElementById('timelineChartWrap');
  if (!wrap) return;

  const sorted = exps.slice().sort((a, b) => (a.date || '').localeCompare(b.date || ''));
  const metric = AppState.timelineMetric;
  const labels = sorted.map(e => e.shortName || e.name);
  const data = sorted.map(e => getMetricValue(e, metric));

  if (data.every(v => v == null)) {
    wrap.innerHTML = makeNoData('No data for ' + getMetricLabel(metric));
    return;
  }

  wrap.innerHTML = '<canvas id="timelineCanvas" height="160"></canvas>';
  const ctx = document.getElementById('timelineCanvas').getContext('2d');

  charts.timeline = new Chart(ctx, {
    type: 'line',
    data: {
      labels: labels,
      datasets: [{
        label: getMetricLabel(metric),
        data: data,
        borderColor: COLORS.blue,
        backgroundColor: COLORS.blueA,
        pointBackgroundColor: data.map(v => v == null ? '#555' : COLORS.blue),
        pointRadius: 5,
        pointHoverRadius: 7,
        fill: false,
        tension: 0.3,
        spanGaps: true,
      }]
    },
    options: chartOpts({
      scales: {
        y: {
          ticks: { color: '#7a8fa8', font: { size: 10 } },
          grid: { color: 'rgba(30,58,95,0.5)' },
          title: { display: true, text: getMetricLabel(metric), color: '#7a8fa8', font: { size: 10 } }
        }
      }
    })
  });
}

// ============================================================
// DETAIL VIEW
// ============================================================
function renderDetailView() {
  const container = document.getElementById('detailView');
  const exp = getExp(AppState.detailId);
  if (!exp) {
    container.innerHTML = '<div style="padding:40px;color:var(--muted)">Experiment not found: ' + escHtml(AppState.detailId) + '</div>';
    return;
  }

  let html = '';

  // Header
  html += '<div class="detail-header">';
  html += '<h2>' + escHtml(exp.name) + '</h2>';
  html += '<div class="detail-meta">';
  html += '<span>' + fmtDate(exp.date) + '</span>';
  html += '<span style="color:var(--border)">|</span>';
  html += '<span>' + escHtml(exp.description || '') + '</span>';
  if (exp.tags && exp.tags.length) {
    html += '<div class="detail-tags">';
    exp.tags.forEach(t => { html += '<span class="tag-pill">' + escHtml(t) + '</span>'; });
    html += '</div>';
  }
  html += '</div></div>';

  // Summary cards
  html += '<div class="cards" id="detailCards"></div>';

  // DPC/ISR section
  html += '<div id="latencySection">';
  html += '<div class="section-header"><h2>DPC / ISR Latency</h2><div class="section-line"></div>';
  html += '<div class="section-badge" id="latencyBadge">LatencyMon</div></div>';
  html += '<div class="charts-grid">';
  html += '<div class="chart-card"><div class="chart-title">DPC Execution Time Distribution</div>';
  html += '<div class="chart-subtitle">Count of DPCs grouped by execution time bucket</div>';
  html += '<div class="chart-wrap" id="dpcBucketsWrap"></div></div>';
  html += '<div class="chart-card"><div class="chart-title">Top DPC Offenders</div>';
  html += '<div class="chart-subtitle">Drivers with highest DPC execution time or total DPC time share</div>';
  html += '<div class="chart-wrap" id="dpcOffendersWrap"></div></div>';
  html += '</div></div>';

  // CPU section
  html += '<div id="cpuSection">';
  html += '<div class="section-header"><h2>CPU Interrupt Distribution</h2><div class="section-line"></div>';
  html += '<div class="section-badge">16 Logical Processors</div></div>';
  html += '<div class="charts-grid">';
  html += '<div class="chart-card"><div class="chart-title">Interrupt Cycle Time per CPU</div>';
  html += '<div class="chart-subtitle">Total seconds spent in interrupt context per logical processor</div>';
  html += '<div class="chart-wrap" id="cpuInterruptWrap"></div></div>';
  html += '<div class="chart-card"><div class="chart-title">DPC Count per CPU</div>';
  html += '<div class="chart-subtitle">Number of DPC executions per logical processor</div>';
  html += '<div class="chart-wrap" id="cpuDpcCountWrap"></div></div>';
  html += '</div></div>';

  // Frame Timing section (conditional)
  html += '<div id="frameTimingSection"></div>';

  // GPU Utilization section (conditional)
  html += '<div id="gpuUtilSection"></div>';

  // Performance section
  html += '<div class="section-header"><h2>Performance Metrics</h2><div class="section-line"></div>';
  html += '<div class="section-badge" id="perfBadge">10s capture</div></div>';
  html += '<div class="charts-grid">';
  html += '<div class="chart-card"><div class="chart-title">Hard Pagefaults by Process</div>';
  html += '<div class="chart-subtitle">Processes causing the most hard page faults</div>';
  html += '<div class="chart-wrap" id="pagefaultsWrap"></div></div>';
  html += '<div class="chart-card"><div class="chart-title">Performance Counters &mdash; Baseline vs Experiment</div>';
  html += '<div class="chart-subtitle">10-second average values; metrics normalized for visibility</div>';
  html += '<div class="chart-wrap" id="perfCompWrap"></div></div>';
  html += '</div>';

  // Registry section
  html += '<div id="regSection"></div>';

  container.innerHTML = html;

  // Render all detail sub-views
  renderDetailCards(exp);
  renderDPCBuckets(exp);
  renderDPCOffenders(exp);
  renderCPUInterrupt(exp);
  renderCPUDpcCount(exp);
  renderFrameTiming(exp);
  renderGPUUtilization(exp);
  renderPagefaults(exp);
  renderPerfComparison(exp);
  renderRegistryTable(exp);
}

// ============================================================
// DETAIL CARDS
// ============================================================
function renderDetailCards(exp) {
  const el = document.getElementById('detailCards');
  if (!el) return;
  const lm = exp.latencymon;
  const perf = exp.performance;
  const ft = exp.frameTiming;
  const isBaseline = exp.id === BASELINE_ID;
  const cards = [];

  // LatencyMon result
  if (lm) {
    const pass = lm.result === 'PASS';
    cards.push('<div class="card ' + (pass ? 'green' : 'red') + '">' +
      '<div class="card-label">LatencyMon Result</div>' +
      '<div class="card-value">' + escHtml(lm.result) + '</div>' +
      '<div class="card-sub">' + safeNum(lm.durationMin, 0) + 'min capture on all CPUs</div>' +
      '<div class="card-badge ' + (pass ? 'badge-pass' : 'badge-warn') + '">' + (pass ? 'Real-time capable' : 'Latency issues detected') + '</div></div>');

    cards.push('<div class="card amber"><div class="card-label">Max DPC Execution</div>' +
      '<div class="card-value">' + safeNum(lm.maxDPCExecutionUs, 0) + '<span class="card-unit">us</span></div>' +
      '<div class="card-sub">' + escHtml(lm.maxDPCExecutionDriver) + '</div></div>');
  } else {
    cards.push('<div class="card cyan"><div class="card-label">LatencyMon Result</div>' +
      '<div class="card-value" style="font-size:16px;color:var(--muted)">--</div>' +
      '<div class="card-badge badge-na">Not yet captured</div></div>');
  }

  // Perf counters (handle both hand-curated and generated field names)
  if (perf) {
    const bp = baseline ? baseline.performance : null;
    const dpcAvg = perfVal(perf, 'DPCTimePct');
    const intAvg = perfVal(perf, 'InterruptTimePct');
    const cpuAvg = perfVal(perf, 'ProcessorTimePct');
    const bpDpc = bp ? perfVal(bp, 'DPCTimePct') : null;
    const bpInt = bp ? perfVal(bp, 'InterruptTimePct') : null;
    const dpcDelta = !isBaseline && bpDpc != null && dpcAvg != null ? (dpcAvg - bpDpc).toFixed(3) : null;
    const intDelta = !isBaseline && bpInt != null && intAvg != null ? (intAvg - bpInt).toFixed(3) : null;

    if (dpcAvg != null) {
      cards.push('<div class="card cyan"><div class="card-label">% DPC Time (avg)</div>' +
        '<div class="card-value">' + safeNum(dpcAvg, 3) + '<span class="card-unit">%</span></div>' +
        '<div class="card-sub">' + (dpcDelta !== null ? 'vs baseline: ' + (dpcDelta >= 0 ? '+' : '') + dpcDelta + '%' : '10s sample') + '</div></div>');
    }
    if (intAvg != null) {
      cards.push('<div class="card blue"><div class="card-label">% Interrupt Time (avg)</div>' +
        '<div class="card-value">' + safeNum(intAvg, 3) + '<span class="card-unit">%</span></div>' +
        '<div class="card-sub">' + (intDelta !== null ? 'vs baseline: ' + (intDelta >= 0 ? '+' : '') + intDelta + '%' : '10s sample') + '</div></div>');
    }
    if (cpuAvg != null) {
      cards.push('<div class="card purple"><div class="card-label">% CPU Time (avg)</div>' +
        '<div class="card-value">' + safeNum(cpuAvg, 1) + '<span class="card-unit">%</span></div></div>');
    }
  }

  // Frame timing cards
  if (ft) {
    cards.push('<div class="card green"><div class="card-label">FPS (avg)</div>' +
      '<div class="card-value">' + safeNum(ft.fps.avg, 1) + '</div>' +
      '<div class="card-sub">1% low: ' + safeNum(ft.fps.p1Low, 1) + ' | min: ' + safeNum(ft.fps.min, 0) + '</div></div>');

    cards.push('<div class="card amber"><div class="card-label">Frame Time p99</div>' +
      '<div class="card-value">' + safeNum(ft.frameTimeMs.p99, 2) + '<span class="card-unit">ms</span></div>' +
      '<div class="card-sub">avg: ' + safeNum(ft.frameTimeMs.avg, 2) + 'ms | max: ' + safeNum(ft.frameTimeMs.max, 1) + 'ms</div></div>');
  }

  // GPU utilization card
  if (exp.gpuUtilization && exp.gpuUtilization['3D']) {
    cards.push('<div class="card purple"><div class="card-label">GPU 3D%</div>' +
      '<div class="card-value">' + safeNum(exp.gpuUtilization['3D'].avg, 1) + '<span class="card-unit">%</span></div>' +
      '<div class="card-sub">max: ' + safeNum(exp.gpuUtilization['3D'].max, 1) + '%</div></div>');
  }

  el.innerHTML = cards.join('');
}

// ============================================================
// DPC BUCKETS CHART
// ============================================================
function renderDPCBuckets(exp) {
  const wrap = document.getElementById('dpcBucketsWrap');
  if (!wrap) return;
  destroyChart('dpcBuckets');

  const lm = exp.latencymon;
  if (!lm || !lm.dpcBuckets) {
    wrap.innerHTML = makeNoData('No LatencyMon data for this experiment', 'Run LatencyMon and add data to experiments.js');
    return;
  }

  wrap.innerHTML = '<canvas id="dpcBucketsCanvas" height="220"></canvas>';
  const ctx = document.getElementById('dpcBucketsCanvas').getContext('2d');
  const bucketLabels = ['<250us', '250-500us', '500-10ms', '1-2ms', '2-4ms', '>=4ms'];
  const dpcData = lm.dpcBuckets;
  const isrData = lm.isrBuckets || [];

  charts.dpcBuckets = new Chart(ctx, {
    type: 'bar',
    data: {
      labels: bucketLabels,
      datasets: [
        {
          label: 'DPC count', data: dpcData,
          backgroundColor: dpcData.map((v, i) => i === 0 ? COLORS.blueA : i <= 2 ? COLORS.amberA : COLORS.redA),
          borderColor: dpcData.map((v, i) => i === 0 ? COLORS.blue : i <= 2 ? COLORS.amber : COLORS.red),
          borderWidth: 1, borderRadius: 4
        },
        {
          label: 'ISR count', data: isrData,
          backgroundColor: COLORS.greenA, borderColor: COLORS.green,
          borderWidth: 1, borderRadius: 4
        }
      ]
    },
    options: chartOpts({
      plugins: { tooltip: { callbacks: { label: c => ' ' + c.dataset.label + ': ' + (c.raw != null ? c.raw.toLocaleString() : 'n/a') } } },
      scales: { y: { type: 'logarithmic', ticks: { color: '#7a8fa8', font: { size: 10 }, callback: v => v >= 1000 ? (v/1000).toFixed(0)+'K' : v }, grid: { color: 'rgba(30,58,95,0.5)' } } }
    })
  });
}

// ============================================================
// DPC OFFENDERS CHART
// ============================================================
function renderDPCOffenders(exp) {
  const wrap = document.getElementById('dpcOffendersWrap');
  if (!wrap) return;
  destroyChart('dpcOffenders');

  const lm = exp.latencymon;
  if (!lm || !lm.dpcDrivers || !lm.dpcDrivers.length) {
    wrap.innerHTML = makeNoData('No driver data for this experiment');
    return;
  }

  wrap.innerHTML = '<canvas id="dpcOffendersCanvas" height="220"></canvas>';
  const ctx = document.getElementById('dpcOffendersCanvas').getContext('2d');
  const drivers = lm.dpcDrivers;
  const labels = drivers.map(d => d.driver);
  const totalPcts = drivers.map(d => d.totalPct != null ? (d.totalPct * 100).toFixed(4) : null);
  const maxUsArr = drivers.map(d => d.highestUs);

  charts.dpcOffenders = new Chart(ctx, {
    type: 'bar',
    data: {
      labels,
      datasets: [
        { label: 'Total DPC time (%)', data: totalPcts, backgroundColor: COLORS.blueA, borderColor: COLORS.blue, borderWidth: 1, borderRadius: 4, yAxisID: 'yPct' },
        { label: 'Max DPC exec (us)', data: maxUsArr, backgroundColor: COLORS.amberA, borderColor: COLORS.amber, borderWidth: 1, borderRadius: 4, yAxisID: 'yUs', type: 'bar' }
      ]
    },
    options: chartOpts({
      plugins: { tooltip: { callbacks: { label: c => { const v = c.raw; if (v == null) return ' ' + c.dataset.label + ': n/a'; return c.dataset.yAxisID === 'yUs' ? ' Max exec: ' + v + ' us' : ' Total time: ' + v + '%'; } } } },
      scales: {
        yPct: { type: 'linear', position: 'left', title: { display: true, text: 'Total time (%)', color: '#7a8fa8', font: { size: 10 } }, ticks: { color: '#7a8fa8', font: { size: 10 } }, grid: { color: 'rgba(30,58,95,0.5)' } },
        yUs: { type: 'linear', position: 'right', title: { display: true, text: 'Max exec (us)', color: '#7a8fa8', font: { size: 10 } }, ticks: { color: '#7a8fa8', font: { size: 10 } }, grid: { drawOnChartArea: false } },
        x: { ticks: { color: '#7a8fa8', font: { size: 11 } }, grid: { color: 'rgba(30,58,95,0.5)' } }
      }
    })
  });
}

// ============================================================
// CPU INTERRUPT CHART
// ============================================================
function renderCPUInterrupt(exp) {
  const wrap = document.getElementById('cpuInterruptWrap');
  if (!wrap) return;
  destroyChart('cpuInterrupt');

  const cpuData = exp.cpuData || (baseline ? baseline.cpuData : null);
  if (!cpuData) { wrap.innerHTML = makeNoData('No per-CPU data available'); return; }

  wrap.innerHTML = '<canvas id="cpuInterruptCanvas" height="220"></canvas>';
  const ctx = document.getElementById('cpuInterruptCanvas').getContext('2d');

  const source = exp.cpuData ? exp : baseline;
  const isBase = source && source.id === BASELINE_ID;
  const hasLMData = cpuData.some(c => c.interruptCycleS != null);
  const dataKey = hasLMData ? 'interruptCycleS' : 'interruptPct';
  const dataLabel = hasLMData ? 'Interrupt cycle time (s)' : 'Interrupt time (%)';
  const dataSuffix = hasLMData ? 's' : '%';
  const validData = cpuData.filter(c => c[dataKey] != null);
  const max = validData.length ? Math.max(...validData.map(c => c[dataKey])) : 0;

  charts.cpuInterrupt = new Chart(ctx, {
    type: 'bar',
    data: {
      labels: cpuData.map(c => 'CPU ' + c.cpu),
      datasets: [{
        label: dataLabel + (!isBase && source ? ' -- ' + (source.shortName || '') : ''),
        data: cpuData.map(c => c[dataKey] != null ? +c[dataKey].toFixed(4) : null),
        backgroundColor: cpuData.map(c => { const v = c[dataKey]; return v == null ? 'rgba(100,100,100,0.3)' : v === max ? COLORS.redA : v > max * 0.1 ? COLORS.amberA : COLORS.blueA; }),
        borderColor: cpuData.map(c => { const v = c[dataKey]; return v == null ? '#555' : v === max ? COLORS.red : v > max * 0.1 ? COLORS.amber : COLORS.blue; }),
        borderWidth: 1, borderRadius: 3
      }]
    },
    options: chartOpts({
      plugins: { tooltip: { callbacks: { label: c => { const cpu = cpuData[c.dataIndex]; const parts = [' ' + c.raw + dataSuffix]; if (cpu.isrCount != null) parts.push('ISR count: ' + cpu.isrCount.toLocaleString()); if (cpu.intrPerSec != null) parts.push('Intrs/sec: ' + cpu.intrPerSec.toFixed(0)); return parts.join(' | '); } } } },
      scales: { y: { ticks: { color: '#7a8fa8', font: { size: 10 }, callback: v => v + dataSuffix }, grid: { color: 'rgba(30,58,95,0.5)' } } }
    })
  });
}

// ============================================================
// CPU DPC COUNT CHART
// ============================================================
function renderCPUDpcCount(exp) {
  const wrap = document.getElementById('cpuDpcCountWrap');
  if (!wrap) return;
  destroyChart('cpuDpcCount');

  const cpuData = exp.cpuData || (baseline ? baseline.cpuData : null);
  if (!cpuData) { wrap.innerHTML = makeNoData('No per-CPU data available'); return; }

  wrap.innerHTML = '<canvas id="cpuDpcCountCanvas" height="220"></canvas>';
  const ctx = document.getElementById('cpuDpcCountCanvas').getContext('2d');

  const hasDpcCount = cpuData.some(c => c.dpcCount != null);
  const dpcKey = hasDpcCount ? 'dpcCount' : 'dpcPct';
  const dpcLabel = hasDpcCount ? 'DPC count' : 'DPC time (%)';
  const validDpc = cpuData.filter(c => c[dpcKey] != null);
  const maxCount = validDpc.length ? Math.max(...validDpc.map(c => c[dpcKey])) : 0;

  charts.cpuDpcCount = new Chart(ctx, {
    type: 'bar',
    data: {
      labels: cpuData.map(c => 'CPU ' + c.cpu),
      datasets: [{
        label: dpcLabel,
        data: cpuData.map(c => c[dpcKey] != null ? c[dpcKey] : null),
        backgroundColor: cpuData.map(c => { const v = c[dpcKey]; return v == null ? 'rgba(100,100,100,0.3)' : v === maxCount ? COLORS.redA : v > maxCount * 0.01 ? COLORS.purpleA : COLORS.blueA; }),
        borderColor: cpuData.map(c => { const v = c[dpcKey]; return v == null ? '#555' : v === maxCount ? COLORS.red : v > maxCount * 0.01 ? COLORS.purple : COLORS.blue; }),
        borderWidth: 1, borderRadius: 3
      }]
    },
    options: chartOpts({
      plugins: { tooltip: { callbacks: { label: c => { const cpu = cpuData[c.dataIndex]; const parts = []; if (cpu.dpcCount != null) parts.push(' DPC count: ' + cpu.dpcCount.toLocaleString()); if (cpu.dpcPct != null) parts.push(' DPC%: ' + cpu.dpcPct.toFixed(4) + '%'); if (cpu.dpcHighestUs != null) parts.push(' Highest DPC: ' + cpu.dpcHighestUs.toFixed(1) + 'us'); if (cpu.dpcTotalS != null) parts.push(' Total DPC time: ' + cpu.dpcTotalS.toFixed(4) + 's'); return parts.length ? parts : [' ' + dpcLabel + ': ' + c.raw]; } } } },
      scales: { y: { type: hasDpcCount ? 'logarithmic' : 'linear', ticks: { color: '#7a8fa8', font: { size: 10 }, callback: v => hasDpcCount && v >= 1000 ? (v/1000).toFixed(0)+'K' : v }, grid: { color: 'rgba(30,58,95,0.5)' } } }
    })
  });
}

// ============================================================
// FRAME TIMING (NEW)
// ============================================================
function renderFrameTiming(exp) {
  const section = document.getElementById('frameTimingSection');
  if (!section) return;
  if (!exp.frameTiming) { section.innerHTML = ''; return; }

  const ft = exp.frameTiming;
  let html = '<div class="section-header"><h2>Frame Timing</h2><div class="section-line"></div>';
  html += '<div class="section-badge">' + escHtml(ft.processName || 'Unknown') + ' | ' + (ft.totalFrames || 0).toLocaleString() + ' frames</div></div>';
  html += '<div class="charts-grid">';
  html += '<div class="chart-card"><div class="chart-title">Frame Time Percentiles</div>';
  html += '<div class="chart-subtitle">Average / P50 / P95 / P99 / Max frame time in ms</div>';
  html += '<div class="chart-wrap" id="frameTimeWrap"></div></div>';
  html += '<div class="chart-card"><div class="chart-title">FPS Breakdown</div>';
  html += '<div class="chart-subtitle">Average FPS, 1% low, and minimum with 60fps target</div>';
  html += '<div class="chart-wrap" id="fpsBreakdownWrap"></div></div>';
  html += '</div>';
  section.innerHTML = html;

  // Frame time chart
  const ftWrap = document.getElementById('frameTimeWrap');
  ftWrap.innerHTML = '<canvas id="frameTimeCanvas" height="220"></canvas>';
  const ftCtx = document.getElementById('frameTimeCanvas').getContext('2d');
  const ftLabels = ['avg', 'p50', 'p95', 'p99', 'max'];
  const ftValues = [ft.frameTimeMs.avg, ft.frameTimeMs.p50, ft.frameTimeMs.p95, ft.frameTimeMs.p99, ft.frameTimeMs.max];
  const ftColors = ftValues.map(v => frameTimeColor(v));

  charts.frameTime = new Chart(ftCtx, {
    type: 'bar',
    data: {
      labels: ftLabels,
      datasets: [{
        label: 'Frame Time (ms)',
        data: ftValues,
        backgroundColor: ftColors.map(c => c + 'bb'),
        borderColor: ftColors,
        borderWidth: 1, borderRadius: 4
      }]
    },
    options: chartOpts({
      plugins: {
        tooltip: { callbacks: { label: c => ' ' + c.raw.toFixed(2) + ' ms' } },
        annotation: undefined
      },
      scales: { y: { ticks: { color: '#7a8fa8', font: { size: 10 }, callback: v => v + 'ms' }, grid: { color: 'rgba(30,58,95,0.5)' } } }
    })
  });

  // FPS chart
  const fpsWrap = document.getElementById('fpsBreakdownWrap');
  fpsWrap.innerHTML = '<canvas id="fpsCanvas" height="220"></canvas>';
  const fpsCtx = document.getElementById('fpsCanvas').getContext('2d');
  const fpsLabels = ['avg', '1% low', 'min'];
  const fpsValues = [ft.fps.avg, ft.fps.p1Low, ft.fps.min];

  charts.fpsBreakdown = new Chart(fpsCtx, {
    type: 'bar',
    data: {
      labels: fpsLabels,
      datasets: [{
        label: 'FPS',
        data: fpsValues,
        backgroundColor: [COLORS.greenA, COLORS.amberA, COLORS.redA],
        borderColor: [COLORS.green, COLORS.amber, COLORS.red],
        borderWidth: 1, borderRadius: 4
      }]
    },
    options: chartOpts({
      indexAxis: 'y',
      plugins: {
        tooltip: { callbacks: { label: c => ' ' + (c.raw != null ? c.raw.toFixed(1) : '--') + ' FPS' } },
        annotation: {
          annotations: {
            target60: {
              type: 'line', xMin: 60, xMax: 60,
              borderColor: COLORS.amber, borderWidth: 2, borderDash: [4, 4],
              label: { display: true, content: '60fps', position: 'start', backgroundColor: 'rgba(245,158,11,0.3)', color: COLORS.amber, font: { size: 10 } }
            }
          }
        }
      },
      scales: { x: { ticks: { color: '#7a8fa8', font: { size: 10 } }, grid: { color: 'rgba(30,58,95,0.5)' } } }
    })
  });
}

// ============================================================
// GPU UTILIZATION (NEW)
// ============================================================
function renderGPUUtilization(exp) {
  const section = document.getElementById('gpuUtilSection');
  if (!section) return;
  if (!exp.gpuUtilization) { section.innerHTML = ''; return; }

  const gpu = exp.gpuUtilization;
  const engines = Object.keys(gpu);
  if (engines.length === 0) { section.innerHTML = ''; return; }

  let html = '<div class="section-header"><h2>GPU Utilization</h2><div class="section-line"></div>';
  html += '<div class="section-badge">' + engines.length + ' engine(s)</div></div>';
  html += '<div class="charts-grid"><div class="chart-card full">';
  html += '<div class="chart-title">GPU Engine Utilization</div>';
  html += '<div class="chart-subtitle">Average and max utilization per engine type</div>';
  html += '<div class="chart-wrap" id="gpuUtilWrap"></div></div></div>';
  section.innerHTML = html;

  const wrap = document.getElementById('gpuUtilWrap');
  wrap.innerHTML = '<canvas id="gpuUtilCanvas" height="180"></canvas>';
  const ctx = document.getElementById('gpuUtilCanvas').getContext('2d');

  charts.gpuUtil = new Chart(ctx, {
    type: 'bar',
    data: {
      labels: engines,
      datasets: [
        { label: 'Avg %', data: engines.map(e => gpu[e].avg), backgroundColor: COLORS.blueA, borderColor: COLORS.blue, borderWidth: 1, borderRadius: 4 },
        { label: 'Max %', data: engines.map(e => gpu[e].max), backgroundColor: COLORS.redA, borderColor: COLORS.red, borderWidth: 1, borderRadius: 4 }
      ]
    },
    options: chartOpts({
      scales: { y: { max: 100, ticks: { color: '#7a8fa8', font: { size: 10 }, callback: v => v + '%' }, grid: { color: 'rgba(30,58,95,0.5)' } } }
    })
  });
}

// ============================================================
// PAGEFAULTS CHART
// ============================================================
function renderPagefaults(exp) {
  const wrap = document.getElementById('pagefaultsWrap');
  if (!wrap) return;
  destroyChart('pagefaults');

  const lm = exp.latencymon || (exp.id !== BASELINE_ID && baseline ? baseline.latencymon : null);
  if (!lm || !lm.pagefaultsByProcess) {
    wrap.innerHTML = makeNoData('No LatencyMon data for this experiment');
    return;
  }

  wrap.innerHTML = '<canvas id="pagefaultsCanvas" height="220"></canvas>';
  const ctx = document.getElementById('pagefaultsCanvas').getContext('2d');
  const pf = lm.pagefaultsByProcess;
  const colors = [COLORS.red, COLORS.amber, COLORS.blue, COLORS.purple, COLORS.cyan, COLORS.green];

  charts.pagefaults = new Chart(ctx, {
    type: 'doughnut',
    data: {
      labels: pf.map(p => p.process + ' (' + p.count + ')'),
      datasets: [{ data: pf.map(p => p.count), backgroundColor: pf.map((_, i) => colors[i % colors.length] + 'bb'), borderColor: pf.map((_, i) => colors[i % colors.length]), borderWidth: 1.5, hoverOffset: 6 }]
    },
    options: {
      responsive: true, maintainAspectRatio: true, cutout: '62%',
      plugins: {
        legend: { position: 'right', labels: { color: '#94a3b8', font: { size: 11 }, boxWidth: 12, padding: 8 } },
        tooltip: { backgroundColor: '#1c2840', borderColor: '#1e3a5f', borderWidth: 1, titleColor: '#e2e8f0', bodyColor: '#94a3b8', padding: 10, callbacks: { label: c => { const pct = ((c.raw / (lm.hardPagefaultsTotal || 1)) * 100).toFixed(1); return ' ' + c.raw + ' pagefaults (' + pct + '%)'; } } }
      }
    }
  });
}

// ============================================================
// PERFORMANCE COMPARISON CHART
// ============================================================
function renderPerfComparison(exp) {
  const wrap = document.getElementById('perfCompWrap');
  const badge = document.getElementById('perfBadge');
  if (!wrap) return;
  destroyChart('perfComp');

  const isBase = exp.id === BASELINE_ID;
  const expPerf = exp.performance;
  const basPerf = baseline ? baseline.performance : null;

  if (!expPerf && !basPerf) { wrap.innerHTML = makeNoData('No performance data available'); return; }
  if (badge) badge.textContent = isBase ? 'Baseline only' : 'Baseline vs ' + (exp.shortName || exp.name);

  wrap.innerHTML = '<canvas id="perfCompCanvas" height="160"></canvas>';
  const ctx = document.getElementById('perfCompCanvas').getContext('2d');

  const metrics = [
    { key: 'DPCTimePct', label: '% DPC Time', unit: '%', scale: 1 },
    { key: 'InterruptTimePct', label: '% Interrupt Time', unit: '%', scale: 1 },
    { key: 'ProcessorTimePct', label: '% CPU Time', unit: '%', scale: 1 },
    { key: 'PagesSec', label: 'Pages/sec', unit: '', scale: 1 },
    { key: 'ContextSwitchesSec', label: 'Context Sw/sec', unit: '', scale: 0.001 },
  ];

  const labels = metrics.map(m => m.label);
  const basVals = metrics.map(m => basPerf && basPerf[m.key] && basPerf[m.key].avg != null ? +(basPerf[m.key].avg * m.scale).toFixed(4) : 0);
  const expVals = metrics.map(m => expPerf && expPerf[m.key] && expPerf[m.key].avg != null ? +(expPerf[m.key].avg * m.scale).toFixed(4) : 0);

  const datasets = isBase
    ? [{ label: 'Baseline (avg)', data: basVals, backgroundColor: COLORS.blueA, borderColor: COLORS.blue, borderWidth: 1, borderRadius: 4 }]
    : [
        { label: 'Baseline (avg)', data: basVals, backgroundColor: COLORS.blueA, borderColor: COLORS.blue, borderWidth: 1, borderRadius: 4 },
        { label: (exp.shortName || exp.name) + ' (avg)', data: expVals, backgroundColor: COLORS.greenA, borderColor: COLORS.green, borderWidth: 1, borderRadius: 4 }
      ];

  charts.perfComp = new Chart(ctx, {
    type: 'bar',
    data: { labels, datasets },
    options: chartOpts({
      plugins: { tooltip: { callbacks: { label: c => { const m = metrics[c.dataIndex]; const raw = c.dataset.data[c.dataIndex]; const display = m.scale === 0.001 ? (raw * 1000).toFixed(0) + ' /sec' : raw + (m.unit || ''); return ' ' + c.dataset.label + ': ' + display; } } } },
      scales: { y: { ticks: { color: '#7a8fa8', font: { size: 10 } }, grid: { color: 'rgba(30,58,95,0.5)' }, title: { display: true, text: 'Value (Context Sw/sec / 1000)', color: '#7a8fa8', font: { size: 10 } } } }
    })
  });
}

// ============================================================
// REGISTRY TABLE
// ============================================================
function renderRegistryTable(exp) {
  const section = document.getElementById('regSection');
  if (!section) return;

  const isBase = exp.id === BASELINE_ID;
  if (isBase) { section.innerHTML = ''; return; }

  const base = baseline ? baseline.registry : null;
  const expReg = exp.registry;
  if (!base && !expReg) { section.innerHTML = ''; return; }

  const knownDescs = {
    SystemResponsiveness: 'ms CPU reservation for multimedia',
    NetworkThrottlingIndex: 'Max packets/ms (0xFFFFFFFF = off)',
    GamesSchedulingCategory: 'Scheduler priority class',
    GamesPriority: 'MMCSS priority value',
    GamesSFIOPriority: 'Synchronous file I/O priority',
    DefenderExclusions: 'Directories excluded from real-time scan',
    DefenderExclusionProcessPaths: 'Processes excluded from real-time scan',
    ScanAvgCPULoadFactor: 'Max CPU% for scheduled scans',
    EnableLowCpuPriority: 'Run scans at low CPU priority',
    NvidiaMSISupported: 'MSI mode enabled for GPU',
    NvidiaMessageNumberLimit: 'MSI message count limit',
    PerfLevelSrc: 'GPU performance level source',
    HwSchMode: 'Hardware-accelerated GPU scheduling',
    InterruptAffinityPolicy: 'Device interrupt CPU assignment policy',
    DevicesAffined: 'Devices with explicit CPU affinity',
    InputDeviceAffinityPolicy: 'Input device interrupt CPU assignment',
    InputControllersAffined: 'Input USB controllers with affinity',
    NIC_GPU_USB_AffinityPolicy: 'NIC/GPU/USB interrupt CPU assignment',
    ExclusionPathCount: 'Number of Defender path exclusions',
    ExclusionProcessCount: 'Number of Defender process exclusions',
  };

  const allKeys = new Set();
  if (base) Object.keys(base).forEach(k => allKeys.add(k));
  if (expReg) Object.keys(expReg).forEach(k => allKeys.add(k));

  function fmt(val) {
    if (val === null || val === undefined) return '--';
    if (Array.isArray(val)) return val.length ? val.map(v => '<div>' + escHtml(v) + '</div>').join('') : '(none)';
    if (val === 4294967295) return '0xFFFFFFFF (disabled)';
    return escHtml(String(val));
  }

  function changed(a, b) {
    if (Array.isArray(a) && Array.isArray(b)) return JSON.stringify(a) !== JSON.stringify(b);
    return a !== b;
  }

  const rows = Array.from(allKeys).map(key => ({ key, label: key.replace(/([A-Z])/g, ' $1').trim(), desc: knownDescs[key] || '' }));

  let html = '<div class="section-header"><h2>Registry Settings</h2><div class="section-line"></div>';
  html += '<div class="section-badge">Before / After</div></div>';
  html += '<div class="chart-card"><div class="chart-title">Registry Settings Comparison</div>';
  html += '<div class="chart-subtitle">MMCSS / Multimedia / Defender settings</div>';
  html += '<table class="reg-table"><thead><tr>';
  html += '<th>Setting</th><th>Description</th><th>Baseline</th><th>' + escHtml(exp.shortName || exp.name) + '</th><th></th>';
  html += '</tr></thead><tbody>';

  rows.forEach(row => {
    const bVal = base ? base[row.key] : undefined;
    const eVal = expReg ? expReg[row.key] : undefined;
    const diff = changed(bVal, eVal);
    html += '<tr><td><span class="reg-key">' + escHtml(row.label) + '</span></td>';
    html += '<td style="color:var(--muted);font-size:11px">' + escHtml(row.desc) + '</td>';
    html += '<td><span class="reg-val baseline">' + fmt(bVal) + '</span></td>';
    html += '<td><span class="reg-val exp ' + (diff ? 'reg-changed' : '') + '">' + fmt(eVal) + '</span></td>';
    html += '<td>' + (diff ? '<span class="reg-tag tag-changed">changed</span>' : '<span class="reg-tag tag-same">same</span>') + '</td></tr>';
  });

  html += '</tbody></table></div>';
  section.innerHTML = html;
}

// ============================================================
// COMPARE VIEW
// ============================================================
function renderCompareView() {
  const container = document.getElementById('compareView');
  const exps = AppState.compareIds.map(id => getExp(id)).filter(Boolean);

  if (exps.length === 0) {
    container.innerHTML = '<div style="padding:40px;color:var(--muted)">No valid experiments selected for comparison.</div>';
    return;
  }

  let html = '<div class="compare-header"><h2>Comparing ' + exps.length + ' experiments</h2></div>';

  // Side-by-side summary cards
  html += '<div class="compare-grid">';
  exps.forEach((exp, i) => {
    html += '<div>';
    html += '<div class="compare-col-header" style="border-color:' + PALETTE[i % PALETTE.length] + '">' + escHtml(exp.shortName || exp.name) + '</div>';
    html += buildCompareCards(exp);
    html += '</div>';
  });
  html += '</div>';

  // Charts
  html += '<div class="charts-grid">';

  // Per-CPU Interrupt%
  html += '<div class="chart-card full"><div class="chart-title">Per-CPU Interrupt Time</div>';
  html += '<div class="chart-subtitle">Grouped bars, one color per experiment</div>';
  html += '<div class="chart-wrap" id="compareCpuIntWrap"></div></div>';

  // DPC%
  html += '<div class="chart-card"><div class="chart-title">DPC Time %</div>';
  html += '<div class="chart-subtitle">Average DPC time per experiment</div>';
  html += '<div class="chart-wrap" id="compareDpcWrap"></div></div>';

  // Frame time percentiles (if any have frameTiming)
  const anyFrameTiming = exps.some(e => e.frameTiming);
  if (anyFrameTiming) {
    html += '<div class="chart-card"><div class="chart-title">Frame Time Percentiles</div>';
    html += '<div class="chart-subtitle">P50 / P95 / P99 per experiment</div>';
    html += '<div class="chart-wrap" id="compareFrameTimeWrap"></div></div>';
  }

  // FPS comparison (if any have frameTiming)
  if (anyFrameTiming) {
    html += '<div class="chart-card"><div class="chart-title">FPS Comparison</div>';
    html += '<div class="chart-subtitle">Average FPS per experiment</div>';
    html += '<div class="chart-wrap" id="compareFpsWrap"></div></div>';
  }

  html += '</div>';

  // Registry diff table
  html += '<div id="compareRegSection"></div>';

  container.innerHTML = html;

  // Render charts
  renderCompareCpuInterrupt(exps);
  renderCompareDpc(exps);
  if (anyFrameTiming) {
    renderCompareFrameTime(exps);
    renderCompareFps(exps);
  }
  renderCompareRegistry(exps);
}

function buildCompareCards(exp) {
  const perf = exp.performance;
  const lm = exp.latencymon;
  const ft = exp.frameTiming;
  let html = '';

  const status = getStatus(exp);
  html += '<div class="card ' + (status === 'PASS' ? 'green' : status === 'REVIEW' ? 'amber' : 'cyan') + '" style="margin-bottom:8px">';
  html += '<div class="card-label">Status</div><div class="card-value" style="font-size:16px">' + status + '</div>';
  html += '<div class="card-sub">' + fmtDate(exp.date) + '</div></div>';

  if (perf) {
    html += '<div class="card blue" style="margin-bottom:8px"><div class="card-label">DPC%</div>';
    html += '<div class="card-value" style="font-size:18px">' + safeNum(perf.DPCTimePct.avg, 3) + '%</div></div>';
    html += '<div class="card cyan" style="margin-bottom:8px"><div class="card-label">Interrupt%</div>';
    html += '<div class="card-value" style="font-size:18px">' + safeNum(perf.InterruptTimePct.avg, 3) + '%</div></div>';
  }

  if (ft) {
    html += '<div class="card green" style="margin-bottom:8px"><div class="card-label">FPS avg</div>';
    html += '<div class="card-value" style="font-size:18px">' + safeNum(ft.fps.avg, 1) + '</div></div>';
    html += '<div class="card amber" style="margin-bottom:8px"><div class="card-label">Frame Time p99</div>';
    html += '<div class="card-value" style="font-size:18px">' + safeNum(ft.frameTimeMs.p99, 2) + ' ms</div></div>';
  }

  return html;
}

function renderCompareCpuInterrupt(exps) {
  const wrap = document.getElementById('compareCpuIntWrap');
  if (!wrap) return;
  destroyChart('compareCpuInt');

  // Find experiments with cpuData
  const withCpu = exps.filter(e => e.cpuData);
  if (withCpu.length === 0) { wrap.innerHTML = makeNoData('No per-CPU data available'); return; }

  // Determine CPU count from largest
  const maxCpus = Math.max(...withCpu.map(e => e.cpuData.length));
  const labels = Array.from({ length: maxCpus }, (_, i) => 'CPU ' + i);

  const datasets = withCpu.map((exp, idx) => {
    const hasLM = exp.cpuData.some(c => c.interruptCycleS != null);
    const key = hasLM ? 'interruptCycleS' : 'interruptPct';
    return {
      label: exp.shortName || exp.name,
      data: Array.from({ length: maxCpus }, (_, i) => {
        const cpu = exp.cpuData.find(c => c.cpu === i);
        return cpu && cpu[key] != null ? +cpu[key].toFixed(4) : null;
      }),
      backgroundColor: PALETTE_A[idx % PALETTE_A.length],
      borderColor: PALETTE[idx % PALETTE.length],
      borderWidth: 1, borderRadius: 3
    };
  });

  wrap.innerHTML = '<canvas id="compareCpuIntCanvas" height="220"></canvas>';
  const ctx = document.getElementById('compareCpuIntCanvas').getContext('2d');

  charts.compareCpuInt = new Chart(ctx, {
    type: 'bar',
    data: { labels, datasets },
    options: chartOpts({ scales: { y: { ticks: { color: '#7a8fa8', font: { size: 10 } }, grid: { color: 'rgba(30,58,95,0.5)' } } } })
  });
}

function renderCompareDpc(exps) {
  const wrap = document.getElementById('compareDpcWrap');
  if (!wrap) return;
  destroyChart('compareDpc');

  const labels = exps.map(e => e.shortName || e.name);
  const data = exps.map(e => e.performance && e.performance.DPCTimePct ? e.performance.DPCTimePct.avg : null);

  if (data.every(v => v == null)) { wrap.innerHTML = makeNoData('No DPC data'); return; }

  wrap.innerHTML = '<canvas id="compareDpcCanvas" height="220"></canvas>';
  const ctx = document.getElementById('compareDpcCanvas').getContext('2d');

  charts.compareDpc = new Chart(ctx, {
    type: 'bar',
    data: {
      labels,
      datasets: [{
        label: 'DPC Time %',
        data,
        backgroundColor: exps.map((_, i) => PALETTE_A[i % PALETTE_A.length]),
        borderColor: exps.map((_, i) => PALETTE[i % PALETTE.length]),
        borderWidth: 1, borderRadius: 4
      }]
    },
    options: chartOpts({ scales: { y: { ticks: { color: '#7a8fa8', font: { size: 10 }, callback: v => v + '%' }, grid: { color: 'rgba(30,58,95,0.5)' } } } })
  });
}

function renderCompareFrameTime(exps) {
  const wrap = document.getElementById('compareFrameTimeWrap');
  if (!wrap) return;
  destroyChart('compareFrameTime');

  const withFT = exps.filter(e => e.frameTiming);
  if (withFT.length === 0) { wrap.innerHTML = makeNoData('No frame timing data'); return; }

  const labels = ['p50', 'p95', 'p99'];
  const datasets = withFT.map((exp, idx) => ({
    label: exp.shortName || exp.name,
    data: [exp.frameTiming.frameTimeMs.p50, exp.frameTiming.frameTimeMs.p95, exp.frameTiming.frameTimeMs.p99],
    backgroundColor: PALETTE_A[idx % PALETTE_A.length],
    borderColor: PALETTE[idx % PALETTE.length],
    borderWidth: 1, borderRadius: 4
  }));

  wrap.innerHTML = '<canvas id="compareFrameTimeCanvas" height="220"></canvas>';
  const ctx = document.getElementById('compareFrameTimeCanvas').getContext('2d');

  charts.compareFrameTime = new Chart(ctx, {
    type: 'bar',
    data: { labels, datasets },
    options: chartOpts({ scales: { y: { ticks: { color: '#7a8fa8', font: { size: 10 }, callback: v => v + 'ms' }, grid: { color: 'rgba(30,58,95,0.5)' } } } })
  });
}

function renderCompareFps(exps) {
  const wrap = document.getElementById('compareFpsWrap');
  if (!wrap) return;
  destroyChart('compareFps');

  const withFT = exps.filter(e => e.frameTiming);
  if (withFT.length === 0) { wrap.innerHTML = makeNoData('No FPS data'); return; }

  const labels = withFT.map(e => e.shortName || e.name);
  const data = withFT.map(e => e.frameTiming.fps.avg);

  wrap.innerHTML = '<canvas id="compareFpsCanvas" height="220"></canvas>';
  const ctx = document.getElementById('compareFpsCanvas').getContext('2d');

  charts.compareFps = new Chart(ctx, {
    type: 'bar',
    data: {
      labels,
      datasets: [{
        label: 'Average FPS',
        data,
        backgroundColor: withFT.map((_, i) => PALETTE_A[i % PALETTE_A.length]),
        borderColor: withFT.map((_, i) => PALETTE[i % PALETTE.length]),
        borderWidth: 1, borderRadius: 4
      }]
    },
    options: chartOpts({ scales: { y: { ticks: { color: '#7a8fa8', font: { size: 10 } }, grid: { color: 'rgba(30,58,95,0.5)' } } } })
  });
}

function renderCompareRegistry(exps) {
  const section = document.getElementById('compareRegSection');
  if (!section) return;

  // Collect all keys
  const allKeys = new Set();
  exps.forEach(e => { if (e.registry) Object.keys(e.registry).forEach(k => allKeys.add(k)); });
  if (allKeys.size === 0) { section.innerHTML = ''; return; }

  function fmt(val) {
    if (val === null || val === undefined) return '--';
    if (Array.isArray(val)) return val.length ? val.join(', ') : '(none)';
    if (val === 4294967295) return '0xFFFFFFFF';
    return String(val);
  }

  function valsDiffer(vals) {
    const strs = vals.map(v => JSON.stringify(v));
    return strs.some(s => s !== strs[0]);
  }

  let html = '<div class="section-header"><h2>Registry Diff</h2><div class="section-line"></div></div>';
  html += '<div class="chart-card"><table class="reg-table"><thead><tr><th>Setting</th>';
  exps.forEach(e => { html += '<th>' + escHtml(e.shortName || e.name) + '</th>'; });
  html += '<th></th></tr></thead><tbody>';

  Array.from(allKeys).sort().forEach(key => {
    const vals = exps.map(e => e.registry ? e.registry[key] : undefined);
    const diff = valsDiffer(vals);
    html += '<tr' + (diff ? ' class="diff-highlight"' : '') + '>';
    html += '<td><span class="reg-key">' + escHtml(key.replace(/([A-Z])/g, ' $1').trim()) + '</span></td>';
    vals.forEach(v => {
      html += '<td><span class="reg-val' + (diff ? ' reg-changed' : '') + '">' + escHtml(fmt(v)) + '</span></td>';
    });
    html += '<td>' + (diff ? '<span class="reg-tag tag-changed">diff</span>' : '<span class="reg-tag tag-same">same</span>') + '</td>';
    html += '</tr>';
  });

  html += '</tbody></table></div>';
  section.innerHTML = html;
}
