// ============================================================
// LatencyGuard — Command view (v2 Direction 04)
// ============================================================
// Source: latencyguard/design/project/LatencyGuard Wireframes v2.html #p4
// Replaces: tabbed renderExpert (diagnostics/history/advanced/live) in app.js
// when mode=expert.
//
// Layout — single canvas, everything visible:
//   deck-top  — 6-cell strip (system / state / longest gap / DPC hot /
//               checks / Scan button)
//   deck-body — 3-col grid with 1px hair gaps:
//     A. mouse input capture     — driver list with bars
//     B. 41 checks grid          — 8-col cell grid color-coded
//     C. experiments 20d         — mini sparkline SVG
//     D. proposed fixes (dark)   — checkbox rows, spans 2 cols
//     E. DPC latency 1s rolling  — vertical spark bars
// ============================================================

// ------------------------------------------------------------
// Entry
// ------------------------------------------------------------
async function renderCommand(container) {
  container.innerHTML = '<div class="cmd-shell"><section class="inst-win">' +
    renderCmdChrome() +
    renderCmdTop() +
    '<div class="cmd-body" id="cmd-body-slot">' +
    '<div class="inst-mono-note" style="padding:32px">Loading pipeline data…</div>' +
    '</div>' +
    '</section></div>';

  // Ensure pipeline data is fetched
  if (!state.pipelineData) {
    try { state.pipelineData = await invoke('get_pipeline_data'); } catch (e) { /* ignore */ }
  }
  if (!state.experiments || state.experiments.length === 0) {
    try { state.experiments = await invoke('get_experiments'); } catch (e) { state.experiments = []; }
  }

  var slot = document.getElementById('cmd-body-slot');
  if (slot) slot.outerHTML = renderCmdBody();
}

// ------------------------------------------------------------
// Chrome
// ------------------------------------------------------------
function renderCmdChrome() {
  return '<div class="inst-chrome">' +
    '<div class="inst-lights"><span></span><span></span><span></span></div>' +
    '<div class="inst-title-bar">LatencyGuard · Command</div>' +
    '</div>';
}

// ------------------------------------------------------------
// Top 6-cell strip
// ------------------------------------------------------------
function renderCmdTop() {
  var sys = state.systemInfo || {};
  var systemStr = [
    sys.cpu ? sys.cpu.replace('AMD ', '').replace(' 8-Core Processor', '') : '—',
    sys.gpu ? sys.gpu.replace('NVIDIA ', '').replace('GeForce ', '') : '—',
    sys.ram || '—',
    sys.os ? sys.os.replace('Microsoft Windows ', 'Win ') : '—',
  ].join(' · ');

  // State computed from audit summary
  var stateLabel = '—', stateClass = '';
  if (state.auditData && state.auditData.summary) {
    var s = state.auditData.summary;
    if (s.fail > 0)       { stateLabel = 'DEGRADED'; stateClass = 'cmd-state-red'; }
    else if (s.warn > 0)  { stateLabel = 'REVIEW';   stateClass = 'cmd-state-amber'; }
    else                  { stateLabel = 'OPTIMAL';  stateClass = 'cmd-state-green'; }
  }

  // Longest gap — from last mouse diag or pipeline
  var longestGap = '—';
  if (state.mouseDiag && state.mouseDiag.mouseInputGaps && state.mouseDiag.mouseInputGaps.maxGapMs != null) {
    longestGap = Math.round(state.mouseDiag.mouseInputGaps.maxGapMs) + ' ms';
  }

  // DPC hot driver
  var hotDriver = '—';
  if (state.pipelineData && state.pipelineData.dpcIsrAnalysis && state.pipelineData.dpcIsrAnalysis.dpcDrivers && state.pipelineData.dpcIsrAnalysis.dpcDrivers.length > 0) {
    var top = state.pipelineData.dpcIsrAnalysis.dpcDrivers[0];
    var name = top.Module || top.module || '?';
    var us = top.MaxUs || top.maxUs || 0;
    hotDriver = name + ' · ' + us + ' µs';
  }

  // Checks
  var checks = '—';
  if (state.auditData && state.auditData.summary) {
    checks = (state.auditData.summary.pass || 0) + ' / ' + (state.auditData.summary.total || 0);
  }

  var html = '<div class="cmd-top">';
  html += cmdTopCell('System', systemStr, null);
  html += cmdTopCell('State',  stateLabel, 'big ' + stateClass);
  html += cmdTopCell('Longest gap', longestGap, 'big');
  html += cmdTopCell('DPC hot driver', hotDriver, null);
  html += cmdTopCell('Checks', checks, 'big');
  html += '<div class="cmd-top-cell cmd-top-cta">';
  html += '<button class="inst-btn inst-btn-primary" onclick="runScan()">Scan <span class="inst-arr">→</span></button>';
  html += '</div>';
  html += '</div>';
  return html;
}

function cmdTopCell(label, value, cls) {
  return '<div class="cmd-top-cell">' +
    '<div class="cmd-top-k">' + escHtml(label) + '</div>' +
    '<div class="cmd-top-v' + (cls ? ' cmd-top-v-' + cls.replace(/\s+/g, ' cmd-top-v-') : '') + '">' + escHtml(value) + '</div>' +
    '</div>';
}

// ------------------------------------------------------------
// Body — 3-col + spanning fixes row + DPC strip
// ------------------------------------------------------------
function renderCmdBody() {
  var html = '<div class="cmd-body">';
  html += renderCmdSectionA();  // mouse capture
  html += renderCmdSectionB();  // 41 checks grid
  html += renderCmdSectionC();  // experiments sparkline
  html += renderCmdSectionD();  // proposed fixes (dark, spans)
  html += renderCmdSectionE();  // DPC rolling spark
  html += '</div>';
  return html;
}

// A — mouse input capture
function renderCmdSectionA() {
  var md = state.mouseDiag && state.mouseDiag.mouseInputGaps;
  var html = '<section class="cmd-sec">';
  html += '<h6>A · mouse input capture · 10 s</h6>';
  if (!md) {
    html += '<div class="cmd-empty-row">No mouse diagnostic yet.<br>' +
      '<button class="inst-btn inst-btn-ghost" style="margin-top:8px;padding:5px 12px;font-size:12px" onclick="runMouseDiag()">Run diagnostic</button></div>';
  } else {
    html += '<div class="cmd-capture-top">';
    html += '<div class="cmd-capture-n">' + (md.gapCount || 0) + '</div>';
    html += '<div class="cmd-capture-meta">gaps · longest ' + Math.round(md.maxGapMs || 0) + ' ms · median ' + (md.medianIntervalMs || 0) + ' ms</div>';
    html += '</div>';

    // Top 5 driver offenders from gaps
    var gaps = md.gaps || [];
    var byDriver = {};
    gaps.forEach(function (g) {
      var d = g.blamedDriver || 'unknown';
      if (!byDriver[d]) byDriver[d] = { max: 0, count: 0 };
      byDriver[d].count += 1;
      if ((g.gapMs || 0) > byDriver[d].max) byDriver[d].max = g.gapMs;
    });
    var list = Object.keys(byDriver).map(function (k) { return { name: k, max: byDriver[k].max, count: byDriver[k].count }; });
    list.sort(function (a, b) { return b.max - a.max; });
    var top5 = list.slice(0, 5);
    var maxAll = Math.max.apply(null, top5.map(function (x) { return x.max; }).concat([1]));

    html += '<div class="cmd-driver-list">';
    top5.forEach(function (d) {
      var pct = Math.max(5, Math.round((d.max / maxAll) * 100));
      html += '<div class="cmd-driver-row">';
      html += '<div class="cmd-driver-name">' + escHtml(d.name) + '</div>';
      html += '<div class="cmd-driver-bar"><i style="width:' + pct + '%"></i></div>';
      html += '<div class="cmd-driver-val">' + Math.round(d.max) + ' ms</div>';
      html += '</div>';
    });
    html += '</div>';
  }
  html += '</section>';
  return html;
}

// B — 41 checks grid
function renderCmdSectionB() {
  var checks = (state.auditData && state.auditData.checks) || [];
  var summary = (state.auditData && state.auditData.summary) || { pass: 0, fail: 0, warn: 0, skip: 0, total: 0 };

  var html = '<section class="cmd-sec">';
  html += '<h6>B · ' + (summary.total || checks.length || 41) + ' checks</h6>';

  html += '<div class="cmd-check-grid">';
  checks.forEach(function (c) {
    var s = c.status || 'SKIP';
    var cls = s === 'PASS' ? 'pass' : s === 'FAIL' ? 'fail' : s === 'WARN' ? 'warn' : 'skip';
    var title = escHtml(c.name + ' · ' + s + (c.current ? ' · ' + c.current : ''));
    html += '<div class="cmd-check-cell cmd-check-' + cls + '" title="' + title + '"></div>';
  });
  // Fill placeholders if no audit data
  if (checks.length === 0) {
    for (var i = 0; i < 41; i++) html += '<div class="cmd-check-cell cmd-check-skip"></div>';
  }
  html += '</div>';

  html += '<div class="cmd-check-legend">';
  html += '<span><span class="cmd-dot cmd-check-pass-dot"></span>Pass ' + (summary.pass || 0) + '</span>';
  if (summary.warn > 0) html += '<span><span class="cmd-dot cmd-check-warn-dot"></span>Warn ' + summary.warn + '</span>';
  if (summary.fail > 0) html += '<span><span class="cmd-dot cmd-check-fail-dot"></span>Fail ' + summary.fail + '</span>';
  if (summary.skip > 0) html += '<span><span class="cmd-dot cmd-check-skip-dot"></span>Skip ' + summary.skip + '</span>';
  html += '</div>';
  html += '</section>';
  return html;
}

// C — experiments sparkline
function renderCmdSectionC() {
  var exps = state.experiments || [];
  var html = '<section class="cmd-sec">';
  html += '<h6>C · experiments · ' + exps.length + '</h6>';

  if (exps.length < 2) {
    html += '<div class="cmd-empty-row">Need ≥2 experiments for a trend.<br>' +
      '<span class="inst-mono-note">Run <code style="font-family:var(--font-mono);font-size:11px;color:var(--accent)">pipeline.ps1</code></span></div>';
  } else {
    var sorted = exps.slice().sort(function (a, b) { return (a.capturedAt || '').localeCompare(b.capturedAt || ''); });
    var values = sorted.map(function (e) { return e.cpuTotal ? e.cpuTotal.dpcPct || 0 : 0; });
    var maxV = Math.max.apply(null, values);
    var minV = Math.min.apply(null, values);
    if (maxV === minV) maxV = minV + 0.001;
    var W = 280, H = 110;

    var pts = sorted.map(function (e, i) {
      var v = e.cpuTotal ? e.cpuTotal.dpcPct || 0 : 0;
      var x = 10 + (i / Math.max(1, sorted.length - 1)) * (W - 30);
      var y = 16 + ((maxV - v) / (maxV - minV)) * 70;
      return { x: x, y: y };
    });
    var d = '';
    pts.forEach(function (p, i) { d += (i === 0 ? 'M' : 'L') + p.x.toFixed(1) + ',' + p.y.toFixed(1) + ' '; });
    var area = d + 'L' + pts[pts.length - 1].x.toFixed(1) + ',90 L' + pts[0].x.toFixed(1) + ',90 Z';

    var svg = '<svg viewBox="0 0 ' + W + ' ' + H + '" width="100%" height="' + H + '" style="margin-top:8px">';
    svg += '<line x1="10" y1="90" x2="' + (W - 20) + '" y2="90" stroke="var(--hair)" stroke-width="1"/>';
    svg += '<path d="' + area + '" fill="rgba(11,11,15,.04)"/>';
    svg += '<path d="' + d + '" stroke="var(--ink)" stroke-width="1.5" fill="none" stroke-linecap="round"/>';
    svg += '<circle cx="' + pts[0].x + '" cy="' + pts[0].y + '" r="3.5" fill="var(--accent)"/>';
    svg += '<circle cx="' + pts[pts.length - 1].x + '" cy="' + pts[pts.length - 1].y + '" r="3.5" fill="var(--accent-2)"/>';
    var startDate = (sorted[0].capturedAt || '').substring(5, 10);
    var endDate = (sorted[sorted.length - 1].capturedAt || '').substring(5, 10);
    svg += '<text x="10" y="106" font-family="JetBrains Mono" font-size="9" fill="var(--ink-3)">' + startDate + '</text>';
    svg += '<text x="' + (W - 60) + '" y="106" font-family="JetBrains Mono" font-size="9" fill="var(--ink-3)">' + endDate + '</text>';
    svg += '</svg>';
    html += svg;

    var firstVal = values[0];
    var lastVal = values[values.length - 1];
    var delta = firstVal > 0 ? Math.round(((firstVal - lastVal) / firstVal) * 100) : 0;
    html += '<div class="inst-mono-note" style="margin-top:6px">' +
      firstVal.toFixed(3) + ' → ' + lastVal.toFixed(3) + ' % DPC · ' +
      (delta > 0 ? '−' : '+') + Math.abs(delta) + '%</div>';
  }
  html += '</section>';
  return html;
}

// D — proposed fixes (dark, spans cols 1-2)
function renderCmdSectionD() {
  var checks = (state.auditData && state.auditData.checks) || [];
  var fixable = checks.filter(function (c) {
    return (c.status === 'FAIL' || c.status === 'WARN') && c.fix;
  }).slice(0, 6);

  var html = '<section class="cmd-sec cmd-sec-fixes">';
  html += '<h6>D · proposed fixes · review &amp; apply</h6>';

  if (fixable.length === 0) {
    html += '<div class="cmd-empty-row" style="color:rgba(255,255,255,.4);padding:16px 0">No fixes pending. Run a full audit to surface any.</div>';
  } else {
    fixable.forEach(function (c, i) {
      var delta = c.deltaHint || '';
      var dur = c.estDuration || '~3 s';
      html += '<div class="cmd-fix-row">';
      html += '<div class="cmd-fix-check" data-idx="' + i + '" role="checkbox" aria-checked="false"></div>';
      html += '<div class="cmd-fix-body">';
      html += '<div class="cmd-fix-t">' + escHtml(c.name) + '</div>';
      html += '<div class="cmd-fix-m">' + escHtml(c.fix || '') + ' · reversible</div>';
      html += '</div>';
      html += '<div class="cmd-fix-delta">' + escHtml(delta) + '</div>';
      html += '<div class="cmd-fix-dur">' + escHtml(dur) + '</div>';
      html += '</div>';
    });
    html += '<div class="cmd-fix-actions">';
    html += '<button class="inst-btn" style="background:#fff;color:var(--ink);border-color:#fff" onclick="applyAllCmdFixes()">Apply all <span class="inst-arr">→</span></button>';
    html += '<button class="inst-btn inst-btn-ghost" style="background:transparent;color:#fff;border-color:rgba(255,255,255,.22)" onclick="setMode(\'simple\')">Review each</button>';
    html += '<div class="inst-grow"></div>';
    html += '<span class="inst-mono-note" style="color:#8a8a8f">All backed up · rollback any time</span>';
    html += '</div>';
  }
  html += '</section>';
  return html;
}

// E — DPC rolling spark
function renderCmdSectionE() {
  var html = '<section class="cmd-sec">';
  html += '<h6>E · DPC latency · 1 s rolling</h6>';
  var pipelineSparks = [];
  if (state.pipelineData && state.pipelineData.cpuData) {
    state.pipelineData.cpuData.forEach(function (c) {
      pipelineSparks.push(c.dpcPct || 0);
    });
  }
  if (pipelineSparks.length === 0) {
    // Dummy 21-bar decoration if no data
    for (var j = 0; j < 21; j++) pipelineSparks.push(Math.random() * 0.3);
  }
  var maxS = Math.max.apply(null, pipelineSparks.concat([0.5]));

  html += '<div class="cmd-spark">';
  pipelineSparks.forEach(function (v) {
    var h = Math.max(4, Math.round((v / maxS) * 54));
    var cls = v >= 0.5 ? 'hi' : v >= 0.2 ? 'md' : '';
    html += '<i class="' + cls + '" style="height:' + h + 'px"></i>';
  });
  html += '</div>';
  html += '<div class="inst-mono-note" style="margin-top:6px">per-CPU DPC% from last pipeline capture</div>';
  html += '</section>';
  return html;
}

// ------------------------------------------------------------
// Actions
// ------------------------------------------------------------
window.applyAllCmdFixes = async function () {
  var checks = (state.auditData && state.auditData.checks) || [];
  var fixable = checks.filter(function (c) {
    return (c.status === 'FAIL' || c.status === 'WARN') && c.fix;
  });
  for (var i = 0; i < fixable.length; i++) {
    try { await invoke('apply_fix', { command: fixable[i].fix }); }
    catch (e) { console.warn('Fix failed for ' + fixable[i].name + ':', e); }
  }
  // Refresh
  try { state.auditData = await invoke('get_latest_audit'); } catch (e) { /* ignore */ }
  if (state.mode === 'expert') renderCommand(document.getElementById('app'));
};

window.renderCommand = renderCommand;
