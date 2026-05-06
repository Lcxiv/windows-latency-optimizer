// ============================================================
// DETAIL VIEW + ALL CHART FUNCTIONS
// Depends on globals from app.js: AppState, BASELINE_ID, COLORS,
// PALETTE, PALETTE_A, CHART_DEFAULTS, charts, baseline, escHtml,
// getExp, makeNoData, chartOpts, fmtDate, safeNum, perfVal,
// getStatus, destroyChart, frameTimeColor
// Depends on components: thresholdLinesPlugin, evaluateThreshold,
// thresholdClass, getThreshold, renderHealthGauge, calculateHealthScore
// ============================================================

// Register thresholdLinesPlugin globally with Chart.js
if (window.Chart && thresholdLinesPlugin) {
  Chart.register(thresholdLinesPlugin);
}

// ============================================================
// SECTION TOGGLE (global)
// ============================================================
function toggleSection(sectionId) {
  var body = document.getElementById(sectionId + '_body');
  if (!body) return;
  var header = body.previousElementSibling;
  body.classList.toggle('expanded');
  if (header) {
    header.classList.toggle('expanded');
  }
  // Persist state in localStorage
  var isExpanded = body.classList.contains('expanded') ? '1' : '0';
  try { localStorage.setItem('latopt_section_' + sectionId, isExpanded); } catch (e) { /* ignore */ }
}

/**
 * Check localStorage for saved section state.
 * @param {string} sectionId
 * @param {boolean} defaultExpanded — fallback if no saved state
 * @returns {boolean}
 */
function getSectionState(sectionId, defaultExpanded) {
  try {
    var saved = localStorage.getItem('latopt_section_' + sectionId);
    if (saved === '1') return true;
    if (saved === '0') return false;
  } catch (e) { /* ignore */ }
  return defaultExpanded;
}

// ============================================================
// COLLAPSIBLE SECTION BUILDER
// ============================================================
/**
 * Build HTML for a collapsible section header + body wrapper.
 * @param {object} opts
 * @param {string} opts.id — section ID (used for toggle/localStorage)
 * @param {string} opts.title — section heading text
 * @param {string} opts.badge — badge text (e.g., "LatencyMon")
 * @param {boolean} opts.hasData — whether section has data
 * @param {string} opts.innerHtml — content inside the body
 * @returns {string} complete HTML
 */
function buildCollapsibleSection(opts) {
  var id = opts.id;
  var hasData = opts.hasData;
  var expanded = getSectionState(id, hasData);
  var expandedClass = expanded ? ' expanded' : '';
  var notCaptured = hasData ? '' : ' (not captured)';

  var html = '<div class="collapsible-header' + expandedClass + '" onclick="toggleSection(\'' + id + '\')">';
  html += '<h2>' + escHtml(opts.title) + notCaptured + '</h2>';
  html += '<div class="section-line"></div>';
  if (opts.badge) {
    html += '<div class="section-badge">' + opts.badge + '</div>';
  }
  html += '</div>';
  html += '<div class="collapsible-body' + expandedClass + '" id="' + id + '_body">';
  html += '<div>';
  if (hasData) {
    html += opts.innerHtml;
  }
  html += '</div></div>';
  return html;
}

// ============================================================
// DETAIL VIEW MAIN RENDER
// ============================================================
function renderDetailView() {
  var container = document.getElementById('detailView');
  var exp = getExp(AppState.detailId);
  if (!exp) {
    container.innerHTML = '<div style="padding:40px;color:var(--muted)">Experiment not found: ' + escHtml(AppState.detailId) + '</div>';
    return;
  }

  // Data availability checks
  var hasDpcData = !!(exp.latencymon && (exp.latencymon.dpcBuckets || exp.latencymon.dpcDrivers)) || !!exp.dpcIsrAnalysis;
  var hasCpuData = !!(exp.cpuData) || !!(baseline && baseline.cpuData);
  var hasFrameData = !!exp.frameTiming;
  var hasGpuData = !!exp.gpuUtilization;
  var hasNetworkData = !!exp.networkLatency;
  var hasPerfData = !!(exp.performance) || !!(baseline && baseline.performance);
  var hasRegData = exp.id !== BASELINE_ID && !!(exp.registry || (baseline && baseline.registry));

  // Health score
  var healthResult = calculateHealthScore(exp, baseline);
  var isBaseline = exp.id === BASELINE_ID;

  var html = '';

  // ── Header with health gauge ──
  html += '<div class="detail-header" style="display:flex;align-items:flex-start;gap:24px;flex-wrap:wrap">';
  html += '<div style="flex:1;min-width:280px">';
  html += '<h2>' + escHtml(exp.name) + '</h2>';
  html += '<div class="detail-meta">';
  html += '<span>' + fmtDate(exp.date) + '</span>';
  if (healthResult.score > 0) {
    html += '<span style="color:var(--border)"> · </span>';
    html += '<span>Score: <strong style="color:' + _scoreColor(healthResult.score) + '">' + healthResult.score + '</strong>';
    if (healthResult.trend && !isBaseline) {
      var trendColor = healthResult.trend.charAt(0) === '+' ? 'var(--good)' : 'var(--bad)';
      html += ' <span style="color:' + trendColor + '">(' + healthResult.trend + ' vs baseline)</span>';
    }
    html += '</span>';
  }
  html += '</div>';
  html += '<div class="detail-meta" style="margin-top:4px">';
  html += '<span>' + escHtml(exp.description || '') + '</span>';
  if (exp.tags && exp.tags.length) {
    html += '<div class="detail-tags" style="display:inline-flex;gap:4px;margin-left:8px">';
    exp.tags.forEach(function(t) { html += '<span class="tag-pill">' + escHtml(t) + '</span>'; });
    html += '</div>';
  }
  html += '</div>';
  html += '</div>';
  html += '<div id="detailGauge" style="flex-shrink:0"></div>';
  html += '</div>';

  // ── Summary cards ──
  html += '<div class="cards" id="detailCards"></div>';

  // ── DPC/ISR Section ──
  var dpcBadge = 'LatencyMon';
  var dpcInner = '<div class="charts-grid">';
  dpcInner += '<div class="chart-card"><div class="chart-title">DPC Execution Time Distribution</div>';
  dpcInner += '<div class="chart-subtitle">Count of DPCs grouped by execution time bucket</div>';
  dpcInner += '<div class="chart-wrap" id="dpcBucketsWrap"></div></div>';
  dpcInner += '<div class="chart-card"><div class="chart-title">Top DPC Offenders</div>';
  dpcInner += '<div class="chart-subtitle">Drivers with highest DPC execution time or total DPC time share</div>';
  dpcInner += '<div class="chart-wrap" id="dpcOffendersWrap"></div></div>';
  dpcInner += '</div>';
  html += buildCollapsibleSection({ id: 'dpcIsr', title: 'DPC / ISR Latency', badge: dpcBadge, hasData: hasDpcData, innerHtml: dpcInner });

  // ── CPU Section ──
  var cpuCount = (exp.interruptTopology && exp.interruptTopology.totalLogicalCpus)
    ? exp.interruptTopology.totalLogicalCpus
    : (exp.cpuData ? exp.cpuData.length : (baseline && baseline.cpuData ? baseline.cpuData.length : '?'));
  var cpuBadge = cpuCount + ' Logical Processors';
  var cpuInner = '<div class="charts-grid">';
  cpuInner += '<div class="chart-card"><div class="chart-title">Interrupt Cycle Time per CPU</div>';
  cpuInner += '<div class="chart-subtitle">Total seconds spent in interrupt context per logical processor</div>';
  cpuInner += '<div class="chart-wrap" id="cpuInterruptWrap"></div></div>';
  cpuInner += '<div class="chart-card"><div class="chart-title">DPC Count per CPU</div>';
  cpuInner += '<div class="chart-subtitle">Number of DPC executions per logical processor</div>';
  cpuInner += '<div class="chart-wrap" id="cpuDpcCountWrap"></div></div>';
  cpuInner += '</div>';
  html += buildCollapsibleSection({ id: 'cpu', title: 'CPU Interrupt Distribution', badge: cpuBadge, hasData: hasCpuData, innerHtml: cpuInner });

  // ── Frame Timing Section ──
  var ftInner = '';
  if (hasFrameData) {
    var ft = exp.frameTiming;
    ftInner = '<div class="charts-grid">';
    ftInner += '<div class="chart-card"><div class="chart-title">Frame Time Percentiles</div>';
    ftInner += '<div class="chart-subtitle">Average / P50 / P95 / P99 / Max frame time in ms</div>';
    ftInner += '<div class="chart-wrap" id="frameTimeWrap"></div></div>';
    ftInner += '<div class="chart-card"><div class="chart-title">FPS Breakdown</div>';
    ftInner += '<div class="chart-subtitle">Average FPS, 1% low, and minimum with 60fps target</div>';
    ftInner += '<div class="chart-wrap" id="fpsBreakdownWrap"></div></div>';
    ftInner += '</div>';
  }
  var ftBadge = hasFrameData ? escHtml((exp.frameTiming.processName || 'Unknown') + ' | ' + (exp.frameTiming.totalFrames || 0).toLocaleString() + ' frames') : '';
  html += buildCollapsibleSection({ id: 'frameTiming', title: 'Frame Timing', badge: ftBadge, hasData: hasFrameData, innerHtml: ftInner });

  // ── GPU Utilization Section ──
  var gpuInner = '';
  var gpuBadge = '';
  if (hasGpuData) {
    var engines = Object.keys(exp.gpuUtilization);
    gpuBadge = engines.length + ' engine(s)';
    gpuInner = '<div class="charts-grid"><div class="chart-card full">';
    gpuInner += '<div class="chart-title">GPU Engine Utilization</div>';
    gpuInner += '<div class="chart-subtitle">Average and max utilization per engine type</div>';
    gpuInner += '<div class="chart-wrap" id="gpuUtilWrap"></div></div></div>';
  }
  html += buildCollapsibleSection({ id: 'gpu', title: 'GPU Utilization', badge: gpuBadge, hasData: hasGpuData, innerHtml: gpuInner });

  // ── Network Latency Section ──
  var netInner = '<div id="networkLatencyContent"></div>';
  var netBadge = hasNetworkData ? 'Ping' : '';
  html += buildCollapsibleSection({ id: 'network', title: 'Network Latency', badge: netBadge, hasData: hasNetworkData, innerHtml: netInner });

  // ── Performance Section ──
  var perfBadge = '10s capture';
  var perfInner = '<div class="charts-grid">';
  perfInner += '<div class="chart-card"><div class="chart-title">Hard Pagefaults by Process</div>';
  perfInner += '<div class="chart-subtitle">Processes causing the most hard page faults</div>';
  perfInner += '<div class="chart-wrap" id="pagefaultsWrap"></div></div>';
  perfInner += '<div class="chart-card"><div class="chart-title">Performance Counters &mdash; Baseline vs Experiment</div>';
  perfInner += '<div class="chart-subtitle">10-second average values; metrics normalized for visibility</div>';
  perfInner += '<div class="chart-wrap" id="perfCompWrap"></div></div>';
  perfInner += '</div>';
  html += buildCollapsibleSection({ id: 'perf', title: 'Performance Metrics', badge: perfBadge, hasData: hasPerfData, innerHtml: perfInner });

  // ── Registry Section ──
  var regInner = '<div id="regContent"></div>';
  var regBadge = hasRegData ? 'Before / After' : '';
  html += buildCollapsibleSection({ id: 'registry', title: 'Registry Settings', badge: regBadge, hasData: hasRegData, innerHtml: regInner });

  container.innerHTML = html;

  // Render health gauge
  renderHealthGauge('detailGauge', exp, baseline);

  // Render all detail sub-views
  renderDetailCards(exp);
  if (hasDpcData) {
    renderDPCBuckets(exp);
    renderDPCOffenders(exp);
  }
  if (hasCpuData) {
    renderCPUInterrupt(exp);
    renderCPUDpcCount(exp);
  }
  if (hasFrameData) {
    renderFrameTiming(exp);
  }
  if (hasGpuData) {
    renderGPUUtilization(exp);
  }
  if (hasNetworkData) {
    renderNetworkLatency(exp);
  }
  if (hasPerfData) {
    renderPagefaults(exp);
    renderPerfComparison(exp);
  }
  if (hasRegData) {
    renderRegistryTable(exp);
  }
}

// ============================================================
// DETAIL CARDS (with delta vs baseline)
// ============================================================
function renderDetailCards(exp) {
  var el = document.getElementById('detailCards');
  if (!el) return;
  var lm = exp.latencymon;
  var perf = exp.performance;
  var ft = exp.frameTiming;
  var isBaseline = exp.id === BASELINE_ID;
  var cards = [];

  // LatencyMon result
  if (lm) {
    var pass = lm.result === 'PASS';
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
    var bp = baseline ? baseline.performance : null;
    var dpcAvg = perfVal(perf, 'DPCTimePct');
    var intAvg = perfVal(perf, 'InterruptTimePct');
    var cpuAvg = perfVal(perf, 'ProcessorTimePct');
    var bpDpc = bp ? perfVal(bp, 'DPCTimePct') : null;
    var bpInt = bp ? perfVal(bp, 'InterruptTimePct') : null;
    var bpCpu = bp ? perfVal(bp, 'ProcessorTimePct') : null;

    if (dpcAvg != null) {
      var dpcDelta = !isBaseline && bpDpc != null ? (dpcAvg - bpDpc) : null;
      var dpcDeltaHtml = buildDeltaHtml(dpcDelta, '%', true);
      var dpcThCls = thresholdClass('DPCTimePct', dpcAvg);
      cards.push('<div class="card cyan ' + dpcThCls + '"><div class="card-label">DPC TIME</div>' +
        '<div class="card-value">' + safeNum(dpcAvg, 3) + '<span class="card-unit">%</span></div>' +
        '<div class="card-sub">' + dpcDeltaHtml + '</div></div>');
    }
    if (intAvg != null) {
      var intDelta = !isBaseline && bpInt != null ? (intAvg - bpInt) : null;
      var intDeltaHtml = buildDeltaHtml(intDelta, '%', true);
      var intThCls = thresholdClass('InterruptTimePct', intAvg);
      cards.push('<div class="card blue ' + intThCls + '"><div class="card-label">INTERRUPT TIME</div>' +
        '<div class="card-value">' + safeNum(intAvg, 3) + '<span class="card-unit">%</span></div>' +
        '<div class="card-sub">' + intDeltaHtml + '</div></div>');
    }
    if (cpuAvg != null) {
      var cpuDelta = !isBaseline && bpCpu != null ? (cpuAvg - bpCpu) : null;
      var cpuDeltaHtml = buildDeltaHtml(cpuDelta, '%', true);
      cards.push('<div class="card purple"><div class="card-label">CPU TIME</div>' +
        '<div class="card-value">' + safeNum(cpuAvg, 1) + '<span class="card-unit">%</span></div>' +
        '<div class="card-sub">' + cpuDeltaHtml + '</div></div>');
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

  // SMI health card
  if (exp.smiAnalysis) {
    var smi = exp.smiAnalysis;
    var smiVerdict = smi.verdict || 'PASS';
    var smiColor = smiVerdict === 'PASS' ? 'green' : (smiVerdict === 'REVIEW' ? 'amber' : 'red');
    var smiBadge = smiVerdict === 'PASS' ? 'badge-pass' : 'badge-warn';
    var smiLabel = smiVerdict === 'PASS' ? 'No SMI blackouts' :
      (smiVerdict === 'REVIEW' ? smi.highLatencyDpcCount + ' high-latency DPCs' :
      smi.driversWithHighDpc + ' driver(s) stalled >1ms');
    var smiSub = 'max bucket: ' + safeNum(smi.maxBucketUs, 0) + 'us';
    if (smi.correlationScore > 0) { smiSub += ' | corr: ' + smi.correlationScore; }
    cards.push('<div class="card ' + smiColor + '"><div class="card-label">SMI Health</div>' +
      '<div class="card-value">' + escHtml(smiVerdict) + '</div>' +
      '<div class="card-sub">' + smiSub + '</div>' +
      '<div class="card-badge ' + smiBadge + '">' + smiLabel + '</div></div>');
  }

  // Network latency card (best ping)
  if (exp.networkLatency) {
    var bestPing = getBestPingValue(exp);
    if (bestPing > 0) {
      var cls = bestPing < 20 ? 'green' : (bestPing < 50 ? 'amber' : 'red');
      cards.push('<div class="card ' + cls + '"><div class="card-label">Best Ping</div>' +
        '<div class="card-value">' + safeNum(bestPing, 1) + '<span class="card-unit">ms</span></div>' +
        '<div class="card-sub">' + getBestPingTarget(exp) + '</div></div>');
    }
  }

  el.innerHTML = cards.join('');
}

/**
 * Build HTML for a delta indicator vs baseline.
 * @param {number|null} delta — raw delta value
 * @param {string} unit — unit suffix (e.g., '%', 'ms')
 * @param {boolean} lowerIsBetter — if true, negative delta = good
 * @returns {string} HTML string
 */
function buildDeltaHtml(delta, unit, lowerIsBetter) {
  if (delta == null) return '10s sample';
  var abs = Math.abs(delta);
  var formatted = abs < 0.001 ? '0' : abs.toFixed(3);
  var isGood = lowerIsBetter ? (delta <= 0) : (delta >= 0);

  if (Math.abs(delta) < 0.0001) {
    return '<span class="delta-neu">= baseline</span>';
  }
  var cls = isGood ? 'delta-pos' : 'delta-neg';
  var prefix = delta < 0 ? '' : '+';
  return '<span class="' + cls + '">' + prefix + formatted + unit + ' vs baseline</span>';
}

// ============================================================
// DPC BUCKETS CHART
// ============================================================
function renderDPCBuckets(exp) {
  var wrap = document.getElementById('dpcBucketsWrap');
  if (!wrap) return;
  destroyChart('dpcBuckets');

  var lm = exp.latencymon;
  if (!lm || !lm.dpcBuckets) {
    wrap.innerHTML = makeNoData('No LatencyMon data for this experiment', 'Run LatencyMon and add data to experiments.js');
    return;
  }

  wrap.innerHTML = '<canvas id="dpcBucketsCanvas" height="220"></canvas>';
  var ctx = document.getElementById('dpcBucketsCanvas').getContext('2d');
  var bucketLabels = ['<250us', '250-500us', '500-10ms', '1-2ms', '2-4ms', '>=4ms'];
  var dpcData = lm.dpcBuckets;
  var isrData = lm.isrBuckets || [];

  charts.dpcBuckets = new Chart(ctx, {
    type: 'bar',
    data: {
      labels: bucketLabels,
      datasets: [
        {
          label: 'DPC count', data: dpcData,
          backgroundColor: dpcData.map(function(v, i) { return i === 0 ? COLORS.blueA : i <= 2 ? COLORS.amberA : COLORS.redA; }),
          borderColor: dpcData.map(function(v, i) { return i === 0 ? COLORS.blue : i <= 2 ? COLORS.amber : COLORS.red; }),
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
      plugins: {
        thresholdLines: { metricKey: 'DPCTimePct' },
        tooltip: { callbacks: { label: function(c) { return ' ' + c.dataset.label + ': ' + (c.raw != null ? c.raw.toLocaleString() : 'n/a'); } } }
      },
      scales: { y: { type: 'logarithmic', ticks: { color: '#7a8fa8', font: { size: 10 }, callback: function(v) { return v >= 1000 ? (v/1000).toFixed(0)+'K' : v; } }, grid: { color: 'rgba(30,58,95,0.5)' } } }
    })
  });
}

// ============================================================
// DPC OFFENDERS CHART
// ============================================================
function renderDPCOffenders(exp) {
  var wrap = document.getElementById('dpcOffendersWrap');
  if (!wrap) return;
  destroyChart('dpcOffenders');

  var lm = exp.latencymon;
  if (!lm || !lm.dpcDrivers || !lm.dpcDrivers.length) {
    wrap.innerHTML = makeNoData('No driver data for this experiment');
    return;
  }

  wrap.innerHTML = '<canvas id="dpcOffendersCanvas" height="220"></canvas>';
  var ctx = document.getElementById('dpcOffendersCanvas').getContext('2d');
  var drivers = lm.dpcDrivers;
  var labels = drivers.map(function(d) { return d.driver; });
  var totalPcts = drivers.map(function(d) { return d.totalPct != null ? (d.totalPct * 100).toFixed(4) : null; });
  var maxUsArr = drivers.map(function(d) { return d.highestUs; });

  charts.dpcOffenders = new Chart(ctx, {
    type: 'bar',
    data: {
      labels: labels,
      datasets: [
        { label: 'Total DPC time (%)', data: totalPcts, backgroundColor: COLORS.blueA, borderColor: COLORS.blue, borderWidth: 1, borderRadius: 4, yAxisID: 'yPct' },
        { label: 'Max DPC exec (us)', data: maxUsArr, backgroundColor: COLORS.amberA, borderColor: COLORS.amber, borderWidth: 1, borderRadius: 4, yAxisID: 'yUs', type: 'bar' }
      ]
    },
    options: chartOpts({
      plugins: { tooltip: { callbacks: { label: function(c) { var v = c.raw; if (v == null) return ' ' + c.dataset.label + ': n/a'; return c.dataset.yAxisID === 'yUs' ? ' Max exec: ' + v + ' us' : ' Total time: ' + v + '%'; } } } },
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
  var wrap = document.getElementById('cpuInterruptWrap');
  if (!wrap) return;
  destroyChart('cpuInterrupt');

  var cpuData = exp.cpuData || (baseline ? baseline.cpuData : null);
  if (!cpuData) { wrap.innerHTML = makeNoData('No per-CPU data available'); return; }

  wrap.innerHTML = '<canvas id="cpuInterruptCanvas" height="220"></canvas>';
  var ctx = document.getElementById('cpuInterruptCanvas').getContext('2d');

  var source = exp.cpuData ? exp : baseline;
  var isBase = source && source.id === BASELINE_ID;
  var hasLMData = cpuData.some(function(c) { return c.interruptCycleS != null; });
  var dataKey = hasLMData ? 'interruptCycleS' : 'interruptPct';
  var dataLabel = hasLMData ? 'Interrupt cycle time (s)' : 'Interrupt time (%)';
  var dataSuffix = hasLMData ? 's' : '%';
  var validData = cpuData.filter(function(c) { return c[dataKey] != null; });
  var max = validData.length ? Math.max.apply(null, validData.map(function(c) { return c[dataKey]; })) : 0;

  charts.cpuInterrupt = new Chart(ctx, {
    type: 'bar',
    data: {
      labels: cpuData.map(function(c) { return 'CPU ' + c.cpu; }),
      datasets: [{
        label: dataLabel + (!isBase && source ? ' -- ' + (source.shortName || '') : ''),
        data: cpuData.map(function(c) { return c[dataKey] != null ? +c[dataKey].toFixed(4) : null; }),
        backgroundColor: cpuData.map(function(c) { var v = c[dataKey]; return v == null ? 'rgba(100,100,100,0.3)' : v === max ? COLORS.redA : v > max * 0.1 ? COLORS.amberA : COLORS.blueA; }),
        borderColor: cpuData.map(function(c) { var v = c[dataKey]; return v == null ? '#555' : v === max ? COLORS.red : v > max * 0.1 ? COLORS.amber : COLORS.blue; }),
        borderWidth: 1, borderRadius: 3
      }]
    },
    options: chartOpts({
      plugins: {
        thresholdLines: { metricKey: 'InterruptTimePct' },
        tooltip: { callbacks: { label: function(c) { var cpu = cpuData[c.dataIndex]; var parts = [' ' + c.raw + dataSuffix]; if (cpu.isrCount != null) parts.push('ISR count: ' + cpu.isrCount.toLocaleString()); if (cpu.intrPerSec != null) parts.push('Intrs/sec: ' + cpu.intrPerSec.toFixed(0)); return parts.join(' | '); } } }
      },
      scales: { y: { ticks: { color: '#7a8fa8', font: { size: 10 }, callback: function(v) { return v + dataSuffix; } }, grid: { color: 'rgba(30,58,95,0.5)' } } }
    })
  });
}

// ============================================================
// CPU DPC COUNT CHART
// ============================================================
function renderCPUDpcCount(exp) {
  var wrap = document.getElementById('cpuDpcCountWrap');
  if (!wrap) return;
  destroyChart('cpuDpcCount');

  var cpuData = exp.cpuData || (baseline ? baseline.cpuData : null);
  if (!cpuData) { wrap.innerHTML = makeNoData('No per-CPU data available'); return; }

  wrap.innerHTML = '<canvas id="cpuDpcCountCanvas" height="220"></canvas>';
  var ctx = document.getElementById('cpuDpcCountCanvas').getContext('2d');

  var hasDpcCount = cpuData.some(function(c) { return c.dpcCount != null; });
  var dpcKey = hasDpcCount ? 'dpcCount' : 'dpcPct';
  var dpcLabel = hasDpcCount ? 'DPC count' : 'DPC time (%)';
  var validDpc = cpuData.filter(function(c) { return c[dpcKey] != null; });
  var maxCount = validDpc.length ? Math.max.apply(null, validDpc.map(function(c) { return c[dpcKey]; })) : 0;

  charts.cpuDpcCount = new Chart(ctx, {
    type: 'bar',
    data: {
      labels: cpuData.map(function(c) { return 'CPU ' + c.cpu; }),
      datasets: [{
        label: dpcLabel,
        data: cpuData.map(function(c) { return c[dpcKey] != null ? c[dpcKey] : null; }),
        backgroundColor: cpuData.map(function(c) { var v = c[dpcKey]; return v == null ? 'rgba(100,100,100,0.3)' : v === maxCount ? COLORS.redA : v > maxCount * 0.01 ? COLORS.purpleA : COLORS.blueA; }),
        borderColor: cpuData.map(function(c) { var v = c[dpcKey]; return v == null ? '#555' : v === maxCount ? COLORS.red : v > maxCount * 0.01 ? COLORS.purple : COLORS.blue; }),
        borderWidth: 1, borderRadius: 3
      }]
    },
    options: chartOpts({
      plugins: {
        thresholdLines: { metricKey: 'DPCTimePct' },
        tooltip: { callbacks: { label: function(c) { var cpu = cpuData[c.dataIndex]; var parts = []; if (cpu.dpcCount != null) parts.push(' DPC count: ' + cpu.dpcCount.toLocaleString()); if (cpu.dpcPct != null) parts.push(' DPC%: ' + cpu.dpcPct.toFixed(4) + '%'); if (cpu.dpcHighestUs != null) parts.push(' Highest DPC: ' + cpu.dpcHighestUs.toFixed(1) + 'us'); if (cpu.dpcTotalS != null) parts.push(' Total DPC time: ' + cpu.dpcTotalS.toFixed(4) + 's'); return parts.length ? parts : [' ' + dpcLabel + ': ' + c.raw]; } } }
      },
      scales: { y: { type: hasDpcCount ? 'logarithmic' : 'linear', ticks: { color: '#7a8fa8', font: { size: 10 }, callback: function(v) { return hasDpcCount && v >= 1000 ? (v/1000).toFixed(0)+'K' : v; } }, grid: { color: 'rgba(30,58,95,0.5)' } } }
    })
  });
}

// ============================================================
// FRAME TIMING
// ============================================================
function renderFrameTiming(exp) {
  if (!exp.frameTiming) return;
  var ft = exp.frameTiming;

  // Frame time chart
  var ftWrap = document.getElementById('frameTimeWrap');
  if (!ftWrap) return;
  ftWrap.innerHTML = '<canvas id="frameTimeCanvas" height="220"></canvas>';
  var ftCtx = document.getElementById('frameTimeCanvas').getContext('2d');
  var ftLabels = ['avg', 'p50', 'p95', 'p99', 'max'];
  var ftValues = [ft.frameTimeMs.avg, ft.frameTimeMs.p50, ft.frameTimeMs.p95, ft.frameTimeMs.p99, ft.frameTimeMs.max];
  var ftColors = ftValues.map(function(v) { return frameTimeColor(v); });

  destroyChart('frameTime');
  charts.frameTime = new Chart(ftCtx, {
    type: 'bar',
    data: {
      labels: ftLabels,
      datasets: [{
        label: 'Frame Time (ms)',
        data: ftValues,
        backgroundColor: ftColors.map(function(c) { return c + 'bb'; }),
        borderColor: ftColors,
        borderWidth: 1, borderRadius: 4
      }]
    },
    options: chartOpts({
      plugins: {
        thresholdLines: { metricKey: 'FrameTimeP99' },
        tooltip: { callbacks: { label: function(c) { return ' ' + c.raw.toFixed(2) + ' ms'; } } },
        annotation: undefined
      },
      scales: { y: { ticks: { color: '#7a8fa8', font: { size: 10 }, callback: function(v) { return v + 'ms'; } }, grid: { color: 'rgba(30,58,95,0.5)' } } }
    })
  });

  // FPS chart
  var fpsWrap = document.getElementById('fpsBreakdownWrap');
  if (!fpsWrap) return;
  fpsWrap.innerHTML = '<canvas id="fpsCanvas" height="220"></canvas>';
  var fpsCtx = document.getElementById('fpsCanvas').getContext('2d');
  var fpsLabels = ['avg', '1% low', 'min'];
  var fpsValues = [ft.fps.avg, ft.fps.p1Low, ft.fps.min];

  destroyChart('fpsBreakdown');
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
        thresholdLines: { metricKey: 'FPSAvg' },
        tooltip: { callbacks: { label: function(c) { return ' ' + (c.raw != null ? c.raw.toFixed(1) : '--') + ' FPS'; } } },
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
// GPU UTILIZATION
// ============================================================
function renderGPUUtilization(exp) {
  if (!exp.gpuUtilization) return;

  var gpu = exp.gpuUtilization;
  var engines = Object.keys(gpu);
  if (engines.length === 0) return;

  var wrap = document.getElementById('gpuUtilWrap');
  if (!wrap) return;
  wrap.innerHTML = '<canvas id="gpuUtilCanvas" height="180"></canvas>';
  var ctx = document.getElementById('gpuUtilCanvas').getContext('2d');

  destroyChart('gpuUtil');
  charts.gpuUtil = new Chart(ctx, {
    type: 'bar',
    data: {
      labels: engines,
      datasets: [
        { label: 'Avg %', data: engines.map(function(e) { return gpu[e].avg; }), backgroundColor: COLORS.blueA, borderColor: COLORS.blue, borderWidth: 1, borderRadius: 4 },
        { label: 'Max %', data: engines.map(function(e) { return gpu[e].max; }), backgroundColor: COLORS.redA, borderColor: COLORS.red, borderWidth: 1, borderRadius: 4 }
      ]
    },
    options: chartOpts({
      scales: { y: { max: 100, ticks: { color: '#7a8fa8', font: { size: 10 }, callback: function(v) { return v + '%'; } }, grid: { color: 'rgba(30,58,95,0.5)' } } }
    })
  });
}

// ============================================================
// PAGEFAULTS CHART
// ============================================================
function renderPagefaults(exp) {
  var wrap = document.getElementById('pagefaultsWrap');
  if (!wrap) return;
  destroyChart('pagefaults');

  var lm = exp.latencymon || (exp.id !== BASELINE_ID && baseline ? baseline.latencymon : null);
  if (!lm || !lm.pagefaultsByProcess) {
    wrap.innerHTML = makeNoData('No LatencyMon data for this experiment');
    return;
  }

  wrap.innerHTML = '<canvas id="pagefaultsCanvas" height="220"></canvas>';
  var ctx = document.getElementById('pagefaultsCanvas').getContext('2d');
  var pf = lm.pagefaultsByProcess;
  var colors = [COLORS.red, COLORS.amber, COLORS.blue, COLORS.purple, COLORS.cyan, COLORS.green];

  charts.pagefaults = new Chart(ctx, {
    type: 'doughnut',
    data: {
      labels: pf.map(function(p) { return p.process + ' (' + p.count + ')'; }),
      datasets: [{ data: pf.map(function(p) { return p.count; }), backgroundColor: pf.map(function(_, i) { return colors[i % colors.length] + 'bb'; }), borderColor: pf.map(function(_, i) { return colors[i % colors.length]; }), borderWidth: 1.5, hoverOffset: 6 }]
    },
    options: {
      responsive: true, maintainAspectRatio: true, cutout: '62%',
      plugins: {
        legend: { position: 'right', labels: { color: '#94a3b8', font: { size: 11 }, boxWidth: 12, padding: 8 } },
        tooltip: { backgroundColor: '#1c2840', borderColor: '#1e3a5f', borderWidth: 1, titleColor: '#e2e8f0', bodyColor: '#94a3b8', padding: 10, callbacks: { label: function(c) { var pct = ((c.raw / (lm.hardPagefaultsTotal || 1)) * 100).toFixed(1); return ' ' + c.raw + ' pagefaults (' + pct + '%)'; } } }
      }
    }
  });
}

// ============================================================
// PERFORMANCE COMPARISON CHART
// ============================================================
function renderPerfComparison(exp) {
  var wrap = document.getElementById('perfCompWrap');
  if (!wrap) return;
  destroyChart('perfComp');

  var isBase = exp.id === BASELINE_ID;
  var expPerf = exp.performance;
  var basPerf = baseline ? baseline.performance : null;

  if (!expPerf && !basPerf) { wrap.innerHTML = makeNoData('No performance data available'); return; }

  wrap.innerHTML = '<canvas id="perfCompCanvas" height="160"></canvas>';
  var ctx = document.getElementById('perfCompCanvas').getContext('2d');

  var metrics = [
    { key: 'DPCTimePct', label: '% DPC Time', unit: '%', scale: 1 },
    { key: 'InterruptTimePct', label: '% Interrupt Time', unit: '%', scale: 1 },
    { key: 'ProcessorTimePct', label: '% CPU Time', unit: '%', scale: 1 },
    { key: 'PagesSec', label: 'Pages/sec', unit: '', scale: 1 },
    { key: 'ContextSwitchesSec', label: 'Context Sw/sec', unit: '', scale: 0.001 },
  ];

  var labels = metrics.map(function(m) { return m.label; });
  var basVals = metrics.map(function(m) { return basPerf && basPerf[m.key] && basPerf[m.key].avg != null ? +(basPerf[m.key].avg * m.scale).toFixed(4) : 0; });
  var expVals = metrics.map(function(m) { return expPerf && expPerf[m.key] && expPerf[m.key].avg != null ? +(expPerf[m.key].avg * m.scale).toFixed(4) : 0; });

  var datasets = isBase
    ? [{ label: 'Baseline (avg)', data: basVals, backgroundColor: COLORS.blueA, borderColor: COLORS.blue, borderWidth: 1, borderRadius: 4 }]
    : [
        { label: 'Baseline (avg)', data: basVals, backgroundColor: COLORS.blueA, borderColor: COLORS.blue, borderWidth: 1, borderRadius: 4 },
        { label: (exp.shortName || exp.name) + ' (avg)', data: expVals, backgroundColor: COLORS.greenA, borderColor: COLORS.green, borderWidth: 1, borderRadius: 4 }
      ];

  charts.perfComp = new Chart(ctx, {
    type: 'bar',
    data: { labels: labels, datasets: datasets },
    options: chartOpts({
      plugins: { tooltip: { callbacks: { label: function(c) { var m = metrics[c.dataIndex]; var raw = c.dataset.data[c.dataIndex]; var display = m.scale === 0.001 ? (raw * 1000).toFixed(0) + ' /sec' : raw + (m.unit || ''); return ' ' + c.dataset.label + ': ' + display; } } } },
      scales: { y: { ticks: { color: '#7a8fa8', font: { size: 10 } }, grid: { color: 'rgba(30,58,95,0.5)' }, title: { display: true, text: 'Value (Context Sw/sec / 1000)', color: '#7a8fa8', font: { size: 10 } } } }
    })
  });
}

// ============================================================
// REGISTRY TABLE
// ============================================================
function renderRegistryTable(exp) {
  var section = document.getElementById('regContent');
  if (!section) return;

  var isBase = exp.id === BASELINE_ID;
  if (isBase) { section.innerHTML = ''; return; }

  var base = baseline ? baseline.registry : null;
  var expReg = exp.registry;
  if (!base && !expReg) { section.innerHTML = ''; return; }

  var knownDescs = {
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

  var allKeys = {};
  if (base) { Object.keys(base).forEach(function(k) { allKeys[k] = true; }); }
  if (expReg) { Object.keys(expReg).forEach(function(k) { allKeys[k] = true; }); }

  function fmt(val) {
    if (val === null || val === undefined) return '--';
    if (Array.isArray(val)) return val.length ? val.map(function(v) { return '<div>' + escHtml(v) + '</div>'; }).join('') : '(none)';
    if (val === 4294967295) return '0xFFFFFFFF (disabled)';
    return escHtml(String(val));
  }

  function changed(a, b) {
    if (Array.isArray(a) && Array.isArray(b)) return JSON.stringify(a) !== JSON.stringify(b);
    return a !== b;
  }

  var rows = Object.keys(allKeys).map(function(key) {
    return { key: key, label: key.replace(/([A-Z])/g, ' $1').trim(), desc: knownDescs[key] || '' };
  });

  var html = '<div class="chart-card"><div class="chart-title">Registry Settings Comparison</div>';
  html += '<div class="chart-subtitle">MMCSS / Multimedia / Defender settings</div>';
  html += '<table class="reg-table"><thead><tr>';
  html += '<th>Setting</th><th>Description</th><th>Baseline</th><th>' + escHtml(exp.shortName || exp.name) + '</th><th></th>';
  html += '</tr></thead><tbody>';

  rows.forEach(function(row) {
    var bVal = base ? base[row.key] : undefined;
    var eVal = expReg ? expReg[row.key] : undefined;
    var diff = changed(bVal, eVal);
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
// NETWORK LATENCY
// ============================================================
function getBestPingTarget(exp) {
  if (!exp.networkLatency) return '';
  var best = Infinity;
  var target = '';
  var keys = Object.keys(exp.networkLatency);
  for (var i = 0; i < keys.length; i++) {
    var v = exp.networkLatency[keys[i]];
    if (v && v.avg != null && v.avg < best) { best = v.avg; target = keys[i]; }
  }
  return target.replace('ping-', '').replace('.ds.on.epicgames.com', ' (Epic)');
}

function renderNetworkLatency(exp) {
  var content = document.getElementById('networkLatencyContent');
  if (!content) return;
  if (!exp.networkLatency) { content.innerHTML = ''; return; }

  var nl = exp.networkLatency;
  var keys = Object.keys(nl).sort();

  var html = '<div class="charts-grid">';

  // Table
  html += '<div class="chart-card"><div class="chart-title">Ping Results by Target</div>';
  html += '<div class="chart-subtitle">60 ICMP samples per target</div>';
  html += '<table class="reg-table"><thead><tr>';
  html += '<th>Target</th><th>Avg</th><th>Min</th><th>Max</th><th>p50</th><th>p95</th><th>p99</th><th>Jitter</th><th>Loss</th>';
  html += '</tr></thead><tbody>';

  keys.forEach(function(host) {
    var v = nl[host];
    var label = host.replace('ping-', '').replace('.ds.on.epicgames.com', ' (Epic)');
    if (v.avg == null) {
      html += '<tr><td>' + escHtml(label) + '</td><td colspan="8" style="color:var(--muted)">Failed: ' + escHtml(v.error || 'unknown') + '</td></tr>';
      return;
    }
    var cls = v.avg < 20 ? 'color:#22c55e' : (v.avg < 50 ? 'color:#f59e0b' : 'color:#ef4444');
    html += '<tr>';
    html += '<td>' + escHtml(label) + '</td>';
    html += '<td style="' + cls + ';font-weight:600">' + safeNum(v.avg, 1) + ' ms</td>';
    html += '<td>' + safeNum(v.min, 0) + '</td>';
    html += '<td>' + safeNum(v.max, 0) + '</td>';
    html += '<td>' + safeNum(v.p50, 0) + '</td>';
    html += '<td>' + safeNum(v.p95, 0) + '</td>';
    html += '<td>' + safeNum(v.p99, 0) + '</td>';
    html += '<td>' + safeNum(v.jitter, 2) + ' ms</td>';
    html += '<td>' + safeNum(v.packetLoss, 1) + '%</td>';
    html += '</tr>';
  });

  html += '</tbody></table></div>';

  // Bar chart
  html += '<div class="chart-card"><div class="chart-title">Ping Latency Comparison</div>';
  html += '<div class="chart-subtitle">Average / p99 by target</div>';
  html += '<div class="chart-wrap" id="pingChartWrap"></div></div>';

  html += '</div>';
  content.innerHTML = html;

  // Render bar chart
  var wrap = document.getElementById('pingChartWrap');
  if (!wrap) return;
  var canvas = document.createElement('canvas');
  wrap.appendChild(canvas);
  var ctx = canvas.getContext('2d');

  var chartLabels = keys.map(function(h) { return h.replace('ping-', '').replace('.ds.on.epicgames.com', ''); });
  var avgData = keys.map(function(h) { return nl[h].avg; });
  var p99Data = keys.map(function(h) { return nl[h].p99; });

  destroyChart('ping');
  charts.ping = new Chart(ctx, {
    type: 'bar',
    data: {
      labels: chartLabels,
      datasets: [
        { label: 'Avg (ms)', data: avgData, backgroundColor: COLORS.blueA, borderColor: COLORS.blue, borderWidth: 1 },
        { label: 'p99 (ms)', data: p99Data, backgroundColor: COLORS.amberA, borderColor: COLORS.amber, borderWidth: 1 }
      ]
    },
    options: chartOpts({
      scales: {
        y: {
          beginAtZero: true,
          ticks: { color: '#7a8fa8', font: { size: 10 } },
          grid: { color: 'rgba(30,58,95,0.5)' },
          title: { display: true, text: 'Latency (ms)', color: '#7a8fa8', font: { size: 10 } }
        }
      }
    })
  });
}
