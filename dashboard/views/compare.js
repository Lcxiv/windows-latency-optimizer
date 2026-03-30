// ============================================================
// COMPARE VIEW
// Depends on globals from app.js: AppState, COLORS, PALETTE,
// PALETTE_A, charts, escHtml, getExp, makeNoData, chartOpts,
// fmtDate, safeNum, getStatus, destroyChart
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
