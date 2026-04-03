// ============================================================
// TABLE VIEW
// Depends on globals from app.js: AppState, COLORS, PALETTE,
// PALETTE_A, charts, baseline, escHtml, getExp, makeNoData,
// chartOpts, fmtDate, safeNum, perfVal, getStatus, getAllTags,
// getMetricValue, getMetricLabel, destroyChart, navigateTo, render
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
    { key: 'ping', label: 'Ping' },
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
    tableHtml += '<td>' + getBestPing(exp) + '</td>';
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

// Network latency helpers
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
