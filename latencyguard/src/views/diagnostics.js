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

  // Checklist
  if (auditData && auditData.checks) {
    html += renderChecklist(auditData.checks, auditData.summary);
  }

  container.innerHTML = html;
}

function healthRow(label, val, color) {
  return '<div class="health-row"><span class="health-dot" style="background:' + color + '"></span>' +
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
  document.querySelectorAll('.filter-btn').forEach(b => b.classList.toggle('active', b.dataset.filter === status));
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
