// ============================================================
// TABLE VIEW
// Depends on globals from app.js: AppState, COLORS, PALETTE,
// PALETTE_A, charts, baseline, escHtml, getExp, makeNoData,
// chartOpts, fmtDate, safeNum, perfVal, getStatus, getAllTags,
// getMetricValue, getMetricLabel, destroyChart, navigateTo, render
// Components: threshold.js (evaluateThreshold, thresholdClass),
//   sparkline.js (Sparkline.init/reset/getData/render),
//   health-score.js (renderInlineScore, calculateHealthScore),
//   keyboard.js (reapplyKeyboardFocus)
// ============================================================

// Metrics where lower values are better (used for delta computation)
var LOWER_IS_BETTER = { DPCTimePct: true, InterruptTimePct: true, ProcessorTimePct: true, FrameTimeP99: true };

function renderTableView() {
  var container = document.getElementById('tableView');

  // --- Health score summary for latest experiment ---
  var sorted = window.EXPERIMENTS.slice().sort(function(a, b) {
    return (b.date || '').localeCompare(a.date || '');
  });
  var latestExp = sorted[0] || null;
  var healthHtml = '<div class="health-summary" id="tableHealthScore"></div>';

  // --- Search input ---
  var searchVal = AppState.searchQuery || '';
  var searchHtml = '<input type="text" id="searchInput" class="search-input" placeholder="Search experiments..." value="' + escHtml(searchVal) + '">';

  // --- Tag filter ---
  var allTags = getAllTags();
  var tagHtml = '<div class="tag-bar"><span class="tag-bar-label">Tags</span>';
  allTags.forEach(function(tag) {
    var active = AppState.tagFilter.includes(tag);
    tagHtml += '<button class="tag-pill' + (active ? ' active' : '') + '" onclick="toggleTag(\'' + escHtml(tag) + '\')">' + escHtml(tag) + '</button>';
  });
  tagHtml += '</div>';

  // --- Compare bar ---
  var selCount = AppState.selectedIds.size;
  var compareHtml = '<div class="compare-bar">' +
    '<button class="compare-btn" ' + (selCount < 2 ? 'disabled' : '') + ' onclick="goCompare()">Compare Selected</button>' +
    '<span class="compare-count">' + (selCount > 0 ? selCount + ' selected' : 'Select 2+ experiments to compare') + '</span></div>';

  // --- Filter and sort experiments ---
  var exps = window.EXPERIMENTS.slice();
  if (AppState.tagFilter.length > 0) {
    exps = exps.filter(function(e) { return e.tags && AppState.tagFilter.some(function(t) { return e.tags.includes(t); }); });
  }
  if (searchVal) {
    var q = searchVal.toLowerCase();
    exps = exps.filter(function(e) {
      var name = (e.shortName || e.name || '').toLowerCase();
      var desc = (e.description || '').toLowerCase();
      return name.indexOf(q) !== -1 || desc.indexOf(q) !== -1;
    });
  }
  exps = sortExperiments(exps);

  // --- Table columns (ping removed) ---
  var cols = [
    { key: 'cb', label: '', noSort: true },
    { key: 'name', label: 'Name' },
    { key: 'date', label: 'Date' },
    { key: 'tags', label: 'Tags', noSort: true },
    { key: 'dpc', label: 'DPC%', metric: 'DPCTimePct' },
    { key: 'interrupt', label: 'Interrupt%', metric: 'InterruptTimePct' },
    { key: 'fps', label: 'FPS', metric: 'FPSAvg' },
    { key: 'cpu', label: 'CPU%', metric: 'ProcessorTimePct' },
    { key: 'status', label: 'Status', noSort: true }
  ];

  var tableHtml = '<div class="exp-table-wrap"><table class="exp-table"><thead><tr>';
  cols.forEach(function(c) {
    var isSorted = AppState.sortColumn === c.key;
    var cls = c.noSort ? 'no-sort' : (isSorted ? ('sorted-' + AppState.sortDir) : '');
    var onclick = c.noSort ? '' : ' onclick="sortBy(\'' + c.key + '\')"';
    tableHtml += '<th class="' + cls + '"' + onclick + '>' + (c.key === 'cb' ? '' : c.label) + '</th>';
  });
  tableHtml += '</tr>';

  // --- Sparkline row ---
  tableHtml += '<tr class="sparkline-row">';
  tableHtml += '<td></td>'; // checkbox
  tableHtml += '<td></td>'; // name
  tableHtml += '<td></td>'; // date
  tableHtml += '<td></td>'; // tags
  tableHtml += '<td class="sparkline-cell"><div data-sparkline="DPCTimePct"></div></td>';
  tableHtml += '<td class="sparkline-cell"><div data-sparkline="InterruptTimePct"></div></td>';
  tableHtml += '<td class="sparkline-cell"><div data-sparkline="FPSAvg"></div></td>';
  tableHtml += '<td class="sparkline-cell"><div data-sparkline="ProcessorTimePct"></div></td>';
  tableHtml += '<td></td>'; // status
  tableHtml += '</tr>';
  tableHtml += '</thead><tbody>';

  // --- Data rows ---
  exps.forEach(function(exp) {
    var perf = exp.performance;
    var ft = exp.frameTiming;
    var status = getStatus(exp);
    var checked = AppState.selectedIds.has(exp.id) ? ' checked' : '';
    var isBaseline = baseline && exp.id === baseline.id;
    var rowCls = isBaseline ? ' class="baseline-row"' : '';

    tableHtml += '<tr' + rowCls + '>';
    tableHtml += '<td class="cb-cell"><input type="checkbox"' + checked + ' onchange="toggleSelect(\'' + escHtml(exp.id) + '\', this.checked)"></td>';

    // Name with baseline marker
    var nameLabel = escHtml(exp.shortName || exp.name);
    if (isBaseline) nameLabel += ' <span class="baseline-ref">(ref)</span>';
    tableHtml += '<td><a class="name-link" href="#detail/' + encodeURIComponent(exp.id) + '">' + nameLabel + '</a></td>';

    tableHtml += '<td>' + fmtDate(exp.date) + '</td>';
    tableHtml += '<td class="tag-cell">' + (exp.tags || []).map(function(t) { return '<span class="tag-pill">' + escHtml(t) + '</span>'; }).join('') + '</td>';

    // DPC% with threshold + delta
    var dpcVal = perf && perf.DPCTimePct ? perf.DPCTimePct.avg : null;
    tableHtml += buildMetricCell(dpcVal, 'DPCTimePct', 3, '%');

    // Interrupt% with threshold + delta
    var intVal = perf && perf.InterruptTimePct ? perf.InterruptTimePct.avg : null;
    tableHtml += buildMetricCell(intVal, 'InterruptTimePct', 3, '%');

    // FPS with threshold + delta
    var fpsVal = ft ? ft.fps.avg : null;
    tableHtml += buildMetricCell(fpsVal, 'FPSAvg', 1, '');

    // CPU% with threshold + delta
    var cpuVal = perf && perf.ProcessorTimePct ? perf.ProcessorTimePct.avg : null;
    tableHtml += buildMetricCell(cpuVal, 'ProcessorTimePct', 1, '%');

    // Status
    tableHtml += '<td><span class="status-badge status-' + status.toLowerCase().replace('/', '') + '">' + status + '</span></td>';
    tableHtml += '</tr>';
  });

  if (exps.length === 0) {
    tableHtml += '<tr><td colspan="' + cols.length + '" style="text-align:center;padding:40px;color:var(--muted)">No experiments match the selected filters</td></tr>';
  }

  tableHtml += '</tbody></table></div>';

  // --- Metric timeline ---
  var metricOptions = ['DPCTimePct','InterruptTimePct','ProcessorTimePct','FPSAvg','FrameTimeP99','PagesSec','ContextSwitchesSec'];
  var timelineHtml = '<div class="metric-timeline-section">' +
    '<div class="section-header"><h2>Metric Timeline</h2><div class="section-line"></div>' +
    '<select class="metric-select" id="metricSelect" onchange="changeTimelineMetric(this.value)">';
  metricOptions.forEach(function(m) {
    timelineHtml += '<option value="' + m + '"' + (m === AppState.timelineMetric ? ' selected' : '') + '>' + getMetricLabel(m) + '</option>';
  });
  timelineHtml += '</select></div>';
  timelineHtml += '<div class="chart-card"><div class="chart-wrap" id="timelineChartWrap"></div></div></div>';

  // --- Assemble ---
  container.innerHTML = healthHtml + searchHtml + tagHtml + compareHtml + tableHtml + timelineHtml;

  // --- Post-render: health score ---
  if (latestExp && typeof renderInlineScore === 'function') {
    renderInlineScore('tableHealthScore', latestExp, baseline);
  }

  // --- Post-render: search input listener ---
  var searchInput = document.getElementById('searchInput');
  if (searchInput) {
    searchInput.addEventListener('input', function() {
      AppState.searchQuery = this.value;
      renderTableView();
    });
  }

  // --- Post-render: sparklines ---
  if (window.Sparkline) {
    Sparkline.reset();
    Sparkline.init();
  }

  // --- Post-render: keyboard focus ---
  if (typeof window.reapplyKeyboardFocus === 'function') {
    window.reapplyKeyboardFocus();
  }

  // --- Render timeline chart ---
  renderTimelineChart(exps);
}

// ============================================================
// METRIC CELL — threshold coloring + inline delta
// ============================================================
function buildMetricCell(value, metricKey, decimals, suffix) {
  if (value == null) return '<td>--</td>';

  var cls = thresholdClass(metricKey, value);
  var display = safeNum(value, decimals) + suffix;
  var deltaHtml = buildDelta(value, metricKey);

  return '<td class="' + cls + '">' + display + deltaHtml + '</td>';
}

function buildDelta(value, metricKey) {
  if (!baseline || value == null) return '';

  var baseVal = getBaselineValue(metricKey);
  if (baseVal == null) return '';

  var delta = value - baseVal;
  if (delta === 0) return '';

  // Determine significance: < 5% of baseline = neutral
  var threshold = Math.abs(baseVal) * 0.05;
  if (threshold < 0.001) threshold = 0.001; // avoid zero threshold
  var isNeutral = Math.abs(delta) < threshold;

  // Determine if delta is good or bad
  var lowerBetter = LOWER_IS_BETTER[metricKey];
  var isGood = lowerBetter ? (delta < 0) : (delta > 0);
  var arrow = delta < 0 ? '↓' : '↑';
  var absVal = Math.abs(delta);
  var formatted = absVal < 1 ? absVal.toFixed(3) : absVal.toFixed(1);

  var cls;
  if (isNeutral) {
    cls = 'delta-neu';
  } else {
    cls = isGood ? 'delta-pos' : 'delta-neg';
  }

  return ' <span class="' + cls + '">' + arrow + formatted + '</span>';
}

function getBaselineValue(metricKey) {
  if (!baseline) return null;
  if (metricKey === 'FPSAvg') {
    return baseline.frameTiming && baseline.frameTiming.fps ? baseline.frameTiming.fps.avg : null;
  }
  if (metricKey === 'FrameTimeP99') {
    return baseline.frameTiming && baseline.frameTiming.frameTimeMs ? baseline.frameTiming.frameTimeMs.p99 : null;
  }
  if (baseline.performance && baseline.performance[metricKey]) {
    return baseline.performance[metricKey].avg != null ? baseline.performance[metricKey].avg : null;
  }
  return null;
}

// ============================================================
// SORTING
// ============================================================
function sortExperiments(exps) {
  var col = AppState.sortColumn;
  var dir = AppState.sortDir === 'asc' ? 1 : -1;

  return exps.sort(function(a, b) {
    var va, vb;
    switch (col) {
      case 'name': va = (a.shortName || a.name || '').toLowerCase(); vb = (b.shortName || b.name || '').toLowerCase(); break;
      case 'date': va = a.date || ''; vb = b.date || ''; break;
      case 'dpc': va = a.performance && a.performance.DPCTimePct ? a.performance.DPCTimePct.avg : -1; vb = b.performance && b.performance.DPCTimePct ? b.performance.DPCTimePct.avg : -1; break;
      case 'interrupt': va = a.performance && a.performance.InterruptTimePct ? a.performance.InterruptTimePct.avg : -1; vb = b.performance && b.performance.InterruptTimePct ? b.performance.InterruptTimePct.avg : -1; break;
      case 'fps': va = a.frameTiming ? a.frameTiming.fps.avg : -1; vb = b.frameTiming ? b.frameTiming.fps.avg : -1; break;
      case 'cpu': va = a.performance && a.performance.ProcessorTimePct ? a.performance.ProcessorTimePct.avg : -1; vb = b.performance && b.performance.ProcessorTimePct ? b.performance.ProcessorTimePct.avg : -1; break;
      case 'ping': va = getBestPingValue(a); vb = getBestPingValue(b); break;
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
  var idx = AppState.tagFilter.indexOf(tag);
  if (idx === -1) { AppState.tagFilter.push(tag); }
  else { AppState.tagFilter.splice(idx, 1); }
  render();
}

function toggleSelect(id, checked) {
  if (checked) { AppState.selectedIds.add(id); }
  else { AppState.selectedIds.delete(id); }
  // Update compare bar without full re-render
  var btn = document.querySelector('.compare-btn');
  var cnt = document.querySelector('.compare-count');
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
  var exps = getFilteredSortedExps();
  renderTimelineChart(exps);
}

function getFilteredSortedExps() {
  var exps = window.EXPERIMENTS.slice();
  if (AppState.tagFilter.length > 0) {
    exps = exps.filter(function(e) { return e.tags && AppState.tagFilter.some(function(t) { return e.tags.includes(t); }); });
  }
  return exps.sort(function(a, b) { return (a.date || '').localeCompare(b.date || ''); });
}

// ============================================================
// TIMELINE CHART
// ============================================================
function renderTimelineChart(exps) {
  destroyChart('timeline');
  var wrap = document.getElementById('timelineChartWrap');
  if (!wrap) return;

  var chartSorted = exps.slice().sort(function(a, b) { return (a.date || '').localeCompare(b.date || ''); });
  var metric = AppState.timelineMetric;
  var labels = chartSorted.map(function(e) { return e.shortName || e.name; });
  var data = chartSorted.map(function(e) { return getMetricValue(e, metric); });

  if (data.every(function(v) { return v == null; })) {
    wrap.innerHTML = makeNoData('No data for ' + getMetricLabel(metric));
    return;
  }

  wrap.innerHTML = '<canvas id="timelineCanvas" height="160"></canvas>';
  var ctx = document.getElementById('timelineCanvas').getContext('2d');

  // Build plugins array — include threshold lines if available
  var plugins = [];
  if (typeof thresholdLinesPlugin !== 'undefined') {
    plugins.push(thresholdLinesPlugin);
  }

  charts.timeline = new Chart(ctx, {
    type: 'line',
    data: {
      labels: labels,
      datasets: [{
        label: getMetricLabel(metric),
        data: data,
        borderColor: COLORS.blue,
        backgroundColor: COLORS.blueA,
        pointBackgroundColor: data.map(function(v) { return v == null ? '#555' : COLORS.blue; }),
        pointRadius: 5,
        pointHoverRadius: 7,
        fill: false,
        tension: 0.3,
        spanGaps: true
      }]
    },
    options: chartOpts({
      plugins: {
        thresholdLines: { metricKey: metric }
      },
      scales: {
        y: {
          ticks: { color: '#7a8fa8', font: { size: 10 } },
          grid: { color: 'rgba(30,58,95,0.5)' },
          title: { display: true, text: getMetricLabel(metric), color: '#7a8fa8', font: { size: 10 } }
        }
      }
    }),
    plugins: plugins
  });
}

// ============================================================
// NETWORK LATENCY HELPERS (preserved for backward compat)
// ============================================================
function getBestPingValue(exp) {
  if (!exp.networkLatency) return -1;
  var best = Infinity;
  var keys = Object.keys(exp.networkLatency);
  for (var i = 0; i < keys.length; i++) {
    var v = exp.networkLatency[keys[i]];
    if (v && v.avg != null && v.avg < best) best = v.avg;
  }
  return best === Infinity ? -1 : best;
}

function getBestPing(exp) {
  var val = getBestPingValue(exp);
  if (val < 0) return '--';
  return safeNum(val, 1) + ' ms';
}
