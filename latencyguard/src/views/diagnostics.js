// Diagnostics Tab — ported from audit-report.ps1 panel builders

function renderDiagnostics(container, auditData, pipelineData) {
  let html = '';

  // Resolve frame timing
  let ft = null;
  if (pipelineData) {
    ft = pipelineData.frameTiming || null;
    if (!ft && pipelineData.inputLatency) ft = pipelineData.inputLatency.frameTiming || null;
  }

  // Hero section
  if (ft && ft.frameTimeMs) {
    const p95 = ft.frameTimeMs.p95;
    const color = p95 > 16 ? 'var(--red)' : p95 > 8 ? 'var(--amber)' : 'var(--green)';
    html += '<div class="diag-hero">';
    html += '<div class="diag-number" style="color:' + color + '">' + p95 + '<span class="diag-unit">ms</span></div>';
    html += '<div class="diag-label">P95 FRAME TIME</div>';
    html += '<div class="diag-sub">P50: ' + ft.frameTimeMs.p50 + 'ms &middot; P99: ' + ft.frameTimeMs.p99 + 'ms';
    if (ft.fps) html += ' &middot; ' + ft.fps.avg + ' FPS';
    html += '</div>';
    if (ft.stutterCount > 0) html += '<div class="diag-stutter">' + ft.stutterCount + ' stutter event(s)</div>';
    html += '</div>';
  } else if (auditData && auditData.summary) {
    // Fallback: score ring
    const s = auditData.summary;
    const sc = s.score >= 80 ? 'var(--green)' : s.score >= 50 ? 'var(--amber)' : 'var(--red)';
    const circ = 439.82;
    const dash = (circ * s.score / 100).toFixed(1);
    const gap = (circ - dash).toFixed(1);
    html += '<div class="diag-hero">';
    html += '<div class="score-ring-wrap"><svg width="160" height="160" viewBox="0 0 160 160">';
    html += '<circle class="track" cx="80" cy="80" r="70"/>';
    html += '<circle class="bar" cx="80" cy="80" r="70" stroke="' + sc + '" stroke-dasharray="' + dash + ' ' + gap + '"/>';
    html += '</svg><div class="score-num" style="color:' + sc + '">' + s.score + '</div>';
    html += '<div class="score-label">SCORE</div></div>';
    html += '</div>';
  }

  // 4 Dashboard panels
  html += '<div class="diag-grid">';

  // Frame Distribution
  html += '<div class="diag-panel">';
  html += '<div class="diag-panel-title">FRAME DISTRIBUTION</div>';
  if (ft && ft.frameTimeMs) {
    html += '<div class="diag-metrics">';
    html += '<span>P50: <b style="color:var(--green)">' + ft.frameTimeMs.p50 + 'ms</b></span>';
    html += '<span>P95: <b style="color:var(--amber)">' + ft.frameTimeMs.p95 + 'ms</b></span>';
    html += '<span>P99: <b style="color:var(--red)">' + ft.frameTimeMs.p99 + 'ms</b></span>';
    html += '</div>';
    if (ft.fps) html += '<div class="diag-sub-metric">FPS avg: ' + ft.fps.avg + (ft.fps.p1Low ? ' &middot; 1% low: ' + ft.fps.p1Low : '') + '</div>';
  } else {
    html += '<div class="diag-placeholder">Run pipeline.ps1 for frame data</div>';
  }
  html += '</div>';

  // Stutter Detection
  html += '<div class="diag-panel">';
  html += '<div class="diag-panel-title">STUTTER DETECTION</div>';
  if (ft) {
    const sc = ft.stutterCount || 0;
    if (sc === 0) {
      html += '<div class="diag-big-num" style="color:var(--green)">0</div>';
      html += '<div class="diag-sub-metric">No stutters detected</div>';
    } else {
      html += '<div class="diag-big-num" style="color:var(--red)">' + sc + '</div>';
      html += '<div class="diag-sub-metric">Frames &gt;2x rolling median</div>';
    }
  } else {
    html += '<div class="diag-placeholder">Run pipeline.ps1 for stutter data</div>';
  }
  html += '</div>';

  // DPC Driver Blame
  const dpcDrivers = pipelineData && pipelineData.dpcIsrAnalysis ? pipelineData.dpcIsrAnalysis.dpcDrivers : null;
  html += '<div class="diag-panel">';
  html += '<div class="diag-panel-title">DPC DRIVER BLAME</div>';
  if (dpcDrivers && dpcDrivers.length > 0) {
    const top = dpcDrivers.slice(0, 5);
    const maxVal = Math.max(1, top[0].MaxUs || top[0].maxUs || 1);
    top.forEach(d => {
      const name = d.Module || d.module || '?';
      const maxUs = d.MaxUs || d.maxUs || 0;
      const pct = Math.min(100, Math.round(maxUs / maxVal * 100));
      const barColor = maxUs >= 512 ? 'var(--red)' : maxUs >= 128 ? 'var(--amber)' : 'var(--green)';
      html += '<div class="dpc-row"><div class="dpc-bar-wrap"><div class="dpc-bar" style="width:' + pct + '%;background:' + barColor + '">';
      html += '<span class="dpc-label">' + escHtml(name) + '</span></div></div>';
      html += '<span class="dpc-val">' + maxUs + '&micro;s</span></div>';
    });
    const anyHigh = dpcDrivers.some(d => (d.MaxUs || d.maxUs || 0) >= 512);
    html += anyHigh ? '<div class="dpc-alert">&gt;512&micro;s detected</div>' : '<div class="dpc-ok">All under 512&micro;s</div>';
  } else {
    html += '<div class="diag-placeholder">Run pipeline.ps1 for DPC data</div>';
  }
  html += '</div>';

  // System Health
  html += '<div class="diag-panel">';
  html += '<div class="diag-panel-title">SYSTEM HEALTH</div>';
  if (auditData && auditData.summary) {
    const s = auditData.summary;
    const sc = s.score >= 80 ? 'var(--green)' : s.score >= 50 ? 'var(--amber)' : 'var(--red)';
    html += healthRow('Audit Score', s.score + '%', sc);
  }
  if (pipelineData && pipelineData.cpuTotal) {
    const ct = pipelineData.cpuTotal;
    const dpc = (ct.dpcPct || 0).toFixed(2);
    const intr = (ct.interruptPct || 0).toFixed(2);
    html += healthRow('Total DPC', dpc + '%', dpc > 0.5 ? 'var(--red)' : dpc > 0.3 ? 'var(--amber)' : 'var(--green)');
    html += healthRow('Total Interrupt', intr + '%', intr > 1 ? 'var(--red)' : intr > 0.5 ? 'var(--amber)' : 'var(--green)');
  }
  if (pipelineData && pipelineData.interruptTopology) {
    const c0 = (pipelineData.interruptTopology.cpu0Share || 0).toFixed(1);
    html += healthRow('CPU 0 Share', c0 + '%', c0 > 10 ? 'var(--red)' : c0 > 5 ? 'var(--amber)' : 'var(--green)');
  }
  html += '</div>';

  html += '</div>'; // end grid

  // CPU Heatmap
  if (pipelineData && pipelineData.cpuData && pipelineData.cpuData.length > 0) {
    html += renderCpuHeatmap(pipelineData.cpuData);
  }

  // Mouse diagnostic section
  html += renderMouseDiagSection();

  // Checklist
  if (auditData && auditData.checks) {
    html += renderChecklist(auditData.checks, auditData.summary);
  }

  container.innerHTML = html;
}

function renderCpuHeatmap(cpuData) {
  var rowLabels = ['Preferred', 'Input', 'GPU / NIC', 'GPU / NIC', 'Game', 'Game', 'Game', 'Game'];
  // 9800X3D: 16 logical CPUs in 4x4 grid, but we label rows of 2
  var groupLabels = [
    { label: 'Preferred', rows: [0] },
    { label: 'Input',     rows: [1] },
    { label: 'GPU/NIC',   rows: [2, 3] },
    { label: 'Game',      rows: [4, 5, 6, 7] }
  ];

  var html = '<div class="heatmap-section">';
  html += '<div class="heatmap-title">CPU Interrupt Heatmap</div>';
  html += '<div class="heatmap-grid">';

  for (var row = 0; row < 4; row++) {
    // Row label (4 rows of 4 CPUs each)
    var label = '';
    if (row === 0) label = 'Preferred';
    if (row === 1) label = 'Input';
    if (row === 2) label = 'GPU/NIC';
    if (row === 3) label = 'Game';
    html += '<div class="heatmap-label">' + label + '</div>';

    for (var col = 0; col < 4; col++) {
      var cpuIdx = row * 4 + col;
      var cpu = null;
      for (var k = 0; k < cpuData.length; k++) {
        if (cpuData[k].cpu === cpuIdx) { cpu = cpuData[k]; break; }
      }

      if (!cpu) {
        html += '<div class="heatmap-cell" style="background:var(--surface2)"><div class="heatmap-cpu">CPU ' + cpuIdx + '</div><div class="heatmap-pct">-</div></div>';
        continue;
      }

      var intrPct = cpu.interruptPct || 0;
      var dpcPct = cpu.dpcPct || 0;
      var intrSec = cpu.intrPerSec || 0;
      var bgColor = 'rgba(16,185,129,0.2)';   // green
      var textColor = 'var(--green)';
      if (intrPct >= 5) {
        bgColor = 'rgba(239,68,68,0.25)'; textColor = 'var(--red)';
      } else if (intrPct >= 1) {
        bgColor = 'rgba(245,158,11,0.25)'; textColor = 'var(--amber)';
      }

      html += '<div class="heatmap-cell" style="background:' + bgColor + '">';
      html += '<div class="heatmap-cpu" style="color:' + textColor + '">CPU ' + cpuIdx + '</div>';
      html += '<div class="heatmap-pct" style="color:' + textColor + '">' + intrPct.toFixed(1) + '%</div>';
      html += '<div class="heatmap-tooltip">';
      html += 'CPU ' + cpuIdx + '<br>';
      html += 'Interrupt: ' + intrPct.toFixed(2) + '%<br>';
      html += 'DPC: ' + dpcPct.toFixed(2) + '%<br>';
      html += 'Intr/sec: ' + Math.round(intrSec).toLocaleString();
      html += '</div>';
      html += '</div>';
    }
  }

  html += '</div></div>';
  return html;
}

// --- Mouse Diagnostic ---
function renderMouseDiagSection() {
  var html = '<div class="mouse-diag-section">';
  html += '<div class="diag-panel-title">MOUSE INPUT HEALTH</div>';

  // Show last diagnostic result if available, otherwise show run button
  if (state.mouseDiag && state.mouseDiag.mouseInputGaps) {
    var gaps = state.mouseDiag.mouseInputGaps;
    var healthy = gaps.gapCount === 0;
    var color = healthy ? 'var(--green)' : 'var(--red)';

    html += '<div class="mouse-diag-summary">';
    html += '<div class="mouse-diag-stat">';
    html += '<span class="mouse-diag-num" style="color:' + color + '">' + gaps.gapCount + '</span>';
    html += '<span class="mouse-diag-label">input gaps</span>';
    html += '</div>';

    if (!healthy) {
      html += '<div class="mouse-diag-stat">';
      html += '<span class="mouse-diag-num" style="color:var(--amber)">' + gaps.maxGapMs + '</span>';
      html += '<span class="mouse-diag-label">max gap (ms)</span>';
      html += '</div>';
      html += '<div class="mouse-diag-stat">';
      html += '<span class="mouse-diag-num" style="color:var(--muted)">' + gaps.medianIntervalMs + '</span>';
      html += '<span class="mouse-diag-label">median (ms)</span>';
      html += '</div>';
    }
    html += '</div>';

    if (!healthy && gaps.gaps && gaps.gaps.length > 0) {
      // Show gap timeline as bars
      html += '<div class="mouse-gap-bars">';
      var maxGap = gaps.maxGapMs || 1;
      var shown = gaps.gaps.slice(0, 20);
      for (var gi = 0; gi < shown.length; gi++) {
        var g = shown[gi];
        var pct = Math.min(100, Math.round(g.gapMs / maxGap * 100));
        var barColor = g.gapMs >= 10 ? 'var(--red)' : 'var(--amber)';
        html += '<div class="mouse-gap-row">';
        html += '<div class="mouse-gap-bar" style="width:' + pct + '%;background:' + barColor + '"></div>';
        html += '<span class="mouse-gap-val">' + g.gapMs + 'ms';
        if (g.blamedDriver && g.blamedDriver !== 'unknown') {
          html += ' <span style="color:var(--muted)">(' + escHtml(g.blamedDriver) + ')</span>';
        }
        html += '</span></div>';
      }
      html += '</div>';
    }

    html += '<div style="margin-top:8px">';
    html += '<button class="btn-secondary" onclick="runMouseDiag()" style="font-size:11px;padding:5px 14px">Re-run Diagnostic</button>';
    if (state.mouseDiag.mouse) {
      html += '<span style="font-size:11px;color:var(--muted);margin-left:12px">' + escHtml(state.mouseDiag.mouse) + '</span>';
    }
    html += '</div>';
  } else {
    html += '<div class="diag-placeholder">';
    html += '<button class="btn-secondary" onclick="runMouseDiag()" aria-label="Run mouse stutter diagnostic">&#128433; Run Mouse Diagnostic</button>';
    html += '<div style="font-size:11px;color:var(--muted);margin-top:6px">10-second capture to detect input gaps</div>';
    html += '</div>';
  }

  html += '</div>';
  return html;
}

window.runMouseDiag = async function() {
  showToast('Starting mouse diagnostic (10s)... move your mouse continuously', 'info');
  try {
    var result = await invoke('diagnose_mouse', { duration_sec: 10 });
    if (result) {
      state.mouseDiag = result;
      if (result.mouseInputGaps && result.mouseInputGaps.gapCount > 0) {
        showToast(result.mouseInputGaps.gapCount + ' input gaps detected (max ' + result.mouseInputGaps.maxGapMs + 'ms)', 'error');
      } else {
        showToast('Mouse input healthy — no gaps detected', 'success');
      }
      // Re-render diagnostics tab
      var pane = document.getElementById('tab-diagnostics');
      if (pane) renderDiagnostics(pane, state.auditData, state.pipelineData);
    }
  } catch (e) {
    showToast('Mouse diagnostic failed: ' + e, 'error');
  }
};

// --- Comparison View ---
function renderComparison(container, data) {
  var e1 = data.exp1;
  var e2 = data.exp2;
  var d = data.deltas;
  var html = '<div class="compare-section">';

  // Header
  html += '<div class="compare-header">';
  html += '<div class="compare-exp"><span class="compare-tag">BEFORE</span>' + escHtml(e1.label || '') + '</div>';
  html += '<div class="compare-vs">vs</div>';
  html += '<div class="compare-exp"><span class="compare-tag compare-tag-after">AFTER</span>' + escHtml(e2.label || '') + '</div>';
  html += '</div>';

  // Score rings side-by-side (use audit scores if available, else DPC-based proxy)
  var s1 = e1.auditScore || null;
  var s2 = e2.auditScore || null;
  if (s1 !== null && s2 !== null) {
    html += '<div class="compare-rings">';
    html += compactScoreRing(s1, 'Before');
    html += '<div class="compare-delta-big">' + deltaArrow(s2 - s1, true) + '</div>';
    html += compactScoreRing(s2, 'After');
    html += '</div>';
  }

  // Delta metric cards
  html += '<div class="compare-deltas">';
  html += deltaCard('DPC %', d.dpcPct.before, d.dpcPct.after, d.dpcPct.delta, d.dpcPct.improved, false);
  html += deltaCard('Interrupt %', d.interruptPct.before, d.interruptPct.after, d.interruptPct.delta, d.interruptPct.improved, false);
  html += deltaCard('CPU 0 Share', d.cpu0Share.before, d.cpu0Share.after, d.cpu0Share.delta, d.cpu0Share.improved, false);
  html += '</div>';

  // Side-by-side CPU heatmaps
  var cpu1 = e1.cpuData || [];
  var cpu2 = e2.cpuData || [];
  if (cpu1.length > 0 || cpu2.length > 0) {
    html += '<div class="compare-heatmaps">';
    html += '<div class="compare-heatmap-col">';
    html += '<div class="compare-heatmap-label">Before</div>';
    html += cpu1.length > 0 ? renderCpuHeatmap(cpu1) : '<div class="diag-placeholder">No CPU data</div>';
    html += '</div>';
    html += '<div class="compare-heatmap-col">';
    html += '<div class="compare-heatmap-label">After</div>';
    html += cpu2.length > 0 ? renderCpuHeatmap(cpu2) : '<div class="diag-placeholder">No CPU data</div>';
    html += '</div>';
    html += '</div>';
  }

  html += '</div>';
  container.innerHTML = html;

  // Scroll into view
  container.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function compactScoreRing(score, label) {
  var sc = score >= 80 ? 'var(--green)' : score >= 50 ? 'var(--amber)' : 'var(--red)';
  var circ = 314.16;
  var dash = (circ * score / 100).toFixed(1);
  var gap = (circ - dash).toFixed(1);
  return '<div class="compare-ring">' +
    '<svg width="100" height="100" viewBox="0 0 100 100">' +
    '<circle class="track" cx="50" cy="50" r="45"/>' +
    '<circle class="bar" cx="50" cy="50" r="45" stroke="' + sc + '" stroke-dasharray="' + dash + ' ' + gap + '"/>' +
    '</svg>' +
    '<div class="compare-ring-num" style="color:' + sc + '">' + score + '</div>' +
    '<div class="compare-ring-label">' + label + '</div></div>';
}

function deltaCard(title, before, after, delta, improved, higherIsBetter) {
  var absD = Math.abs(delta);
  var color = improved ? 'var(--green)' : absD < 0.001 ? 'var(--muted)' : 'var(--red)';
  var arrow = improved ? '&#9660;' : delta > 0 ? '&#9650;' : '&#9679;';
  var sign = delta > 0 ? '+' : '';
  return '<div class="compare-delta-card">' +
    '<div class="compare-delta-title">' + title + '</div>' +
    '<div class="compare-delta-row">' +
    '<span class="compare-val">' + before.toFixed(3) + '</span>' +
    '<span class="compare-arrow">&#8594;</span>' +
    '<span class="compare-val">' + after.toFixed(3) + '</span>' +
    '</div>' +
    '<div class="compare-delta-badge" style="color:' + color + '">' +
    arrow + ' ' + sign + delta.toFixed(3) +
    '</div></div>';
}

function deltaArrow(diff, higherIsBetter) {
  var improved = higherIsBetter ? diff > 0 : diff < 0;
  var color = improved ? 'var(--green)' : Math.abs(diff) < 0.5 ? 'var(--muted)' : 'var(--red)';
  var sign = diff > 0 ? '+' : '';
  return '<span style="color:' + color + ';font-size:24px;font-weight:700">' + sign + Math.round(diff) + '</span>';
}

function healthRow(label, val, color) {
  return '<div class="health-row"><span class="health-dot" style="background:' + color + '" aria-hidden="true"></span>' +
    '<span class="health-label">' + label + '</span><span class="health-val" style="color:' + color + '">' + val + '</span></div>';
}

function renderChecklist(checks, summary) {
  const order = { FAIL: 0, WARN: 1, ERROR: 2, SKIP: 3, PASS: 4 };
  const sorted = [...checks].sort((a, b) => (order[a.status] || 9) - (order[b.status] || 9));

  let html = '<div class="checklist-section">';

  // Filter bar
  html += '<div class="filter-bar">';
  html += '<button class="filter-btn active" data-filter="all" onclick="filterChecks(\'all\')">All (' + summary.total + ')</button>';
  if (summary.fail > 0) html += '<button class="filter-btn" data-filter="fail" onclick="filterChecks(\'fail\')">Fail (' + summary.fail + ')</button>';
  if (summary.warn > 0) html += '<button class="filter-btn" data-filter="warn" onclick="filterChecks(\'warn\')">Warn (' + summary.warn + ')</button>';
  html += '<button class="filter-btn" data-filter="pass" onclick="filterChecks(\'pass\')">Pass (' + summary.pass + ')</button>';
  html += '</div>';

  // Table
  html += '<div class="check-table">';
  sorted.forEach((c, i) => {
    const color = c.status === 'PASS' ? 'var(--green)' : c.status === 'FAIL' ? 'var(--red)' : c.status === 'WARN' ? 'var(--amber)' : 'var(--muted)';
    const id = 'ck-' + i;
    html += '<div class="check-row" data-status="' + c.status.toLowerCase() + '" onclick="toggleCheck(\'' + id + '\')">';
    html += '<span class="check-status" style="color:' + color + '">' + c.status + '</span>';
    html += '<span class="check-name">' + escHtml(c.name) + '</span>';
    html += '<span class="check-cat">' + c.category + '</span>';
    html += '<span class="check-val">' + escHtml(c.current) + '</span>';
    html += '</div>';
    html += '<div class="check-detail" id="' + id + '">';
    if (c.message) html += '<p class="check-msg">' + escHtml(c.message) + '</p>';
    html += '<div class="check-meta">Expected: ' + escHtml(c.expected) + '</div>';
    if (c.fix) html += '<pre class="check-fix">' + escHtml(c.fix) + '</pre>';
    if (c.fixNote) html += '<p class="check-note">' + escHtml(c.fixNote) + '</p>';
    html += '</div>';
  });
  html += '</div></div>';

  return html;
}

// Filter + toggle
window.filterChecks = function(status) {
  document.querySelectorAll('.filter-btn').forEach(b => {
    const isActive = b.dataset.filter === status;
    b.classList.toggle('active', isActive);
    b.setAttribute('aria-pressed', isActive);
  });
  document.querySelectorAll('.check-row').forEach(r => {
    const show = status === 'all' || r.dataset.status === status;
    r.style.display = show ? '' : 'none';
    const detail = r.nextElementSibling;
    if (detail && detail.classList.contains('check-detail')) {
      if (!show) detail.style.display = 'none';
    }
  });
};

window.toggleCheck = function(id) {
  const el = document.getElementById(id);
  if (el) el.style.display = el.style.display === 'block' ? 'none' : 'block';
};
