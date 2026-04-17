// ============================================================
// LatencyGuard — Instrument view (v2 Direction 01)
// ============================================================
// Source: latencyguard/design/project/LatencyGuard Wireframes v2.html #p1
// Replaces: renderSimple score-ring from app.js
//
// Layout: two windows side-by-side
//   Left  (1.15fr)  — symptom picker (4 rows + app-nav)
//   Right (1fr)     — finding: big measurement + verdict + stats + chart
//
// Data flow (reuses existing producers):
//   state.systemInfo   → left-pane app-nav chips
//   state.activeSymptom → pulses the selected symptom row
//   state.scanning     → right-pane shows live capture (progress bar)
//   state.findings     → right-pane renders finding
//   state.auditData    → fallback summary when no symptom run yet
// ============================================================

// Symptom catalog (v2 uses M·01 / F·02 / S·03 / A·00 ids)
var INSTRUMENT_SYMPTOMS = [
  { id: 'M·01', key: 'MouseFreezing',        title: 'Mouse freezing',
    meta: '13 checks · ~28s · ETW capture',    dur: '1·3·13' },
  { id: 'F·02', key: 'FrameDrops',           title: 'Frame drops',
    meta: '14 checks · ~22s · HAGS · MSI · ReBAR', dur: '1·4·14' },
  { id: 'S·03', key: 'GeneralSluggishness',  title: 'General sluggishness',
    meta: '17 checks · ~18s · power · telemetry · TCP', dur: '1·7·17' },
  { id: 'A·00', key: 'FullAudit',            title: 'Full audit',
    meta: '41 checks · ~90s · everything',     dur: '4·1·41' },
];

// ------------------------------------------------------------
// Main dispatcher — called from app.js render('simple')
// ------------------------------------------------------------
function renderInstrument(container) {
  var html = '<div class="inst-shell">';
  html += renderInstrumentLeft();
  html += renderInstrumentRight();
  html += '</div>';
  container.innerHTML = html;
  wireInstrumentEvents();
}

// ------------------------------------------------------------
// Left pane — symptom picker (always visible)
// ------------------------------------------------------------
function renderInstrumentLeft() {
  var sys = state.systemInfo || {};
  var cpu = sys.cpu ? (sys.cpu.replace('AMD ', '').replace(' 8-Core Processor', '')) : '—';
  var gpu = sys.gpu ? (sys.gpu.replace('NVIDIA ', '').replace('GeForce ', '')) : '—';
  var ram = sys.ram || '—';

  var html = '<section class="inst-win" aria-labelledby="inst-picker-title">';

  // window chrome (macOS-style lights + title)
  html += '<div class="inst-chrome">';
  html += '<div class="inst-lights"><span></span><span></span><span></span></div>';
  html += '<div class="inst-title-bar">LatencyGuard — Diagnose</div>';
  html += '</div>';

  // app-nav: brand dot + sys chips
  html += '<div class="inst-app-nav">';
  html += '<div class="inst-brand"><span class="inst-brand-dot"></span>LatencyGuard</div>';
  html += '<div class="inst-sys">';
  html += '<span>' + escHtml(cpu) + '</span>';
  html += '<span>' + escHtml(gpu) + '</span>';
  html += '<span>' + escHtml(ram) + '</span>';
  html += '</div>';
  html += '<div class="inst-grow"></div>';
  html += '<div class="inst-cmdk" aria-hidden="true">⌘K</div>';
  html += '</div>';

  // symptom list
  html += '<div class="inst-picker">';
  html += '<div class="inst-picker-head">';
  html += '<h4 id="inst-picker-title">What are you <span class="inst-alt">trying to fix?</span></h4>';
  html += '</div>';

  INSTRUMENT_SYMPTOMS.forEach(function (s) {
    var isActive = state.activeSymptom === s.key;
    html += '<button type="button" class="inst-sym-row' + (isActive ? ' on' : '') + '"';
    html += ' data-symptom="' + s.key + '"';
    html += ' aria-pressed="' + isActive + '"';
    html += ' aria-label="' + escHtml(s.title) + ' — ' + escHtml(s.meta) + '">';
    html += '<span class="inst-sym-id">' + s.id + '</span>';
    html += '<span class="inst-sym-body">';
    html += '<span class="inst-sym-title">' + escHtml(s.title) + '</span>';
    html += '<span class="inst-sym-meta">' + s.meta.replace(/(\d+)/g, '<b>$1</b>') + '</span>';
    html += '</span>';
    html += '<span class="inst-sym-dur">' + s.dur + '</span>';
    html += '<span class="inst-sym-arr" aria-hidden="true">→</span>';
    html += '</button>';
  });

  html += '</div>'; // .inst-picker
  html += '</section>';
  return html;
}

// ------------------------------------------------------------
// Right pane — finding (empty / scanning / result)
// ------------------------------------------------------------
function renderInstrumentRight() {
  var html = '<section class="inst-win" aria-labelledby="inst-finding-title">';

  html += '<div class="inst-chrome">';
  html += '<div class="inst-lights"><span></span><span></span><span></span></div>';
  html += '<div class="inst-title-bar">' + renderInstrumentTitleBar() + '</div>';
  html += '</div>';

  if (state.scanning) {
    html += renderInstrumentScanning();
  } else if (state.findings) {
    html += renderInstrumentFinding(state.findings);
  } else if (state.auditData && state.auditData.summary) {
    html += renderInstrumentSummary(state.auditData);
  } else {
    html += renderInstrumentEmpty();
  }

  html += '</section>';
  return html;
}

function renderInstrumentTitleBar() {
  if (state.scanning) return 'Measuring…';
  if (state.findings) {
    var sym = findSymptom(state.findings.symptom);
    return (sym ? sym.title : 'Diagnostic') + ' · Result';
  }
  if (state.auditData) return 'Audit summary';
  return 'Pick a symptom to start';
}

// ------------------------------------------------------------
// Right pane: empty state (no scan yet)
// ------------------------------------------------------------
function renderInstrumentEmpty() {
  var html = '<div class="inst-finding inst-finding-empty">';
  html += '<div class="inst-finding-top">';
  html += '<span class="inst-kicker">00 · Idle</span>';
  html += '<span class="inst-kicker">Ready</span>';
  html += '</div>';
  html += '<div class="inst-empty-hero">';
  html += '<div class="inst-empty-dot"></div>';
  html += '<div class="inst-empty-copy">';
  html += '<h3 class="inst-empty-h">Pick a symptom.</h3>';
  html += '<p class="inst-empty-p">Select one of the four on the left and LatencyGuard will run a targeted diagnostic. Each symptom runs only the relevant ETW captures and checks.</p>';
  html += '</div>';
  html += '</div>';
  html += '<div class="inst-sep"></div>';
  html += '<div class="inst-stats inst-stats-idle">';
  html += renderStatCell('symptoms available', '4', null);
  html += renderStatCell('total checks', '41', null);
  html += renderStatCell('full audit', '~90s', null);
  html += '</div>';
  html += '</div>';
  return html;
}

// ------------------------------------------------------------
// Right pane: scanning (live capture)
// ------------------------------------------------------------
function renderInstrumentScanning() {
  var prog = state.diagnosticProgress || {};
  var current = prog.current || 0;
  var total = prog.total || 10;
  var stepName = prog.stepName || 'Initializing…';
  var pct = Math.round((current / total) * 100);

  var html = '<div class="inst-finding">';
  html += '<div class="inst-finding-top">';
  html += '<span class="inst-kicker inst-kicker-live">● LIVE · measuring</span>';
  html += '<span class="inst-kicker">' + current + ' / ' + total + '</span>';
  html += '</div>';

  html += '<div class="inst-scan-hero">';
  html += '<div class="inst-scan-pct">' + pct + '<span class="inst-scan-pct-unit">%</span></div>';
  html += '<div class="inst-scan-step">' + escHtml(stepName) + '</div>';
  html += '</div>';

  html += '<div class="inst-scan-bar" role="progressbar" aria-valuenow="' + pct + '" aria-valuemin="0" aria-valuemax="100">';
  html += '<div class="inst-scan-bar-fill" style="width:' + pct + '%"></div>';
  html += '</div>';

  html += '<div class="inst-mono-note">Measurement runs in-process · no cloud · 10s ETW capture</div>';
  html += '</div>';
  return html;
}

// ------------------------------------------------------------
// Right pane: finding (primary result)
// ------------------------------------------------------------
function renderInstrumentFinding(data) {
  var findings = data.findings || [];
  var summary = data.summary || {};
  var mouseGaps = data.mouseDiag && data.mouseDiag.mouseInputGaps;
  var top = findings[0] || null;
  var issueCount = (summary.high || 0) + (summary.medium || 0) + (summary.low || 0);

  // Hero metric: prefer mouse longest-gap if MouseFreezing, else use issue count
  var heroNum, heroUnit, heroSuffix, heroVerdict, heroAccent;
  if (mouseGaps && mouseGaps.maxGapMs) {
    heroNum = String(Math.round(mouseGaps.maxGapMs));
    heroSuffix = '';
    heroUnit = 'ms · longest input gap';
    heroAccent = mouseGaps.maxGapMs > 50 ? 'var(--accent)' : mouseGaps.maxGapMs > 10 ? 'var(--accent-4)' : 'var(--accent-2)';
    var framesLost = Math.round(mouseGaps.maxGapMs / 16.67);
    heroVerdict = '≈ ' + framesLost + ' dropped frames at 60 fps. ';
    heroVerdict += '<span class="inst-red">You\'d feel this as a cursor lurch during fast aim.</span>';
  } else if (issueCount > 0) {
    heroNum = String(issueCount);
    heroSuffix = '';
    heroUnit = issueCount === 1 ? 'issue to fix' : 'issues to fix';
    heroAccent = issueCount >= 3 ? 'var(--accent)' : 'var(--accent-4)';
    heroVerdict = (summary.pass || 0) + ' of ' + (summary.total || 0) + ' checks pass. ';
    heroVerdict += '<span class="inst-red">Fix these to eliminate the measured latency.</span>';
  } else {
    heroNum = String(summary.pass || 0);
    heroSuffix = '';
    heroUnit = 'of ' + (summary.total || 0) + ' checks passing';
    heroAccent = 'var(--accent-2)';
    heroVerdict = 'Nothing wrong at the measurement layer. System is responsive.';
  }

  var html = '<div class="inst-finding">';

  html += '<div class="inst-finding-top">';
  html += '<span class="inst-kicker">03 · Measured · ' + (mouseGaps ? '10.0s capture' : 'live audit') + '</span>';
  html += '<span class="inst-kicker inst-kicker-live">● RESULT</span>';
  html += '</div>';

  // big num
  html += '<div class="inst-num-hero">';
  html += '<span class="inst-num" style="color:' + heroAccent + '">' + heroNum + '</span>';
  html += '<span class="inst-num-unit">' + heroUnit + '</span>';
  html += '</div>';

  html += '<div class="inst-verdict">' + heroVerdict + '</div>';

  // stats row
  html += '<div class="inst-stats">';
  if (mouseGaps) {
    html += renderStatCell('gaps detected', String(mouseGaps.gapCount || 0), null);
    html += renderStatCell('median interval', (mouseGaps.medianIntervalMs || 0) + '<small>ms</small>', null);
    var blame = (mouseGaps.gaps && mouseGaps.gaps[0] && mouseGaps.gaps[0].blamedDriver) || '—';
    html += renderStatCell('likely cause', blame, 'inst-stat-small');
  } else {
    html += renderStatCell('pass', String(summary.pass || 0), null);
    html += renderStatCell('warn', String(summary.warn || 0), null);
    html += renderStatCell('fail', String(summary.fail || 0), null);
  }
  html += '</div>';

  // gap distribution chart (mouse only)
  if (mouseGaps && mouseGaps.gaps && mouseGaps.gaps.length > 0) {
    html += renderGapChart(mouseGaps);
  } else if (top) {
    html += renderTopFindingCard(top);
  }

  // actions
  html += '<div class="inst-actions">';
  var autoFixCount = findings.filter(function (f) { return f.fixType === 'auto' && f.fix; }).length;
  if (autoFixCount > 0) {
    html += '<button class="inst-btn inst-btn-primary" onclick="applyAllInstrumentFixes()">Apply ' + autoFixCount + ' fix' + (autoFixCount !== 1 ? 'es' : '') + ' <span class="inst-arr">→</span></button>';
  }
  html += '<button class="inst-btn inst-btn-ghost" onclick="runScan()">Re-run capture</button>';
  html += '<button class="inst-btn inst-btn-ghost" onclick="backToSymptoms()">← Back</button>';
  html += '<div class="inst-grow"></div>';
  html += '<span class="inst-mono-note">' + (summary.pass || 0) + ' / ' + (summary.total || 0) + ' passed · ' + (summary.warn || 0) + ' warn</span>';
  html += '</div>';

  html += '</div>'; // .inst-finding
  return html;
}

// ------------------------------------------------------------
// Right pane: audit summary (before a symptom-specific scan ran)
// ------------------------------------------------------------
function renderInstrumentSummary(data) {
  var s = data.summary;
  var accent = s.score >= 80 ? 'var(--accent-2)' : s.score >= 50 ? 'var(--accent-4)' : 'var(--accent)';
  var html = '<div class="inst-finding">';

  html += '<div class="inst-finding-top">';
  html += '<span class="inst-kicker">01 · Audit · cached</span>';
  html += '<span class="inst-kicker">' + (s.total || 0) + ' checks</span>';
  html += '</div>';

  html += '<div class="inst-num-hero">';
  html += '<span class="inst-num" style="color:' + accent + '">' + (s.score || 0) + '</span>';
  html += '<span class="inst-num-unit">of 100 · system health</span>';
  html += '</div>';

  var msg;
  if (s.fail > 0)      msg = '<span class="inst-red">' + s.fail + ' fail</span> · ' + s.warn + ' warn · ' + s.pass + ' pass. Pick a symptom on the left for a targeted capture.';
  else if (s.warn > 0) msg = s.warn + ' warning' + (s.warn > 1 ? 's' : '') + ', ' + s.pass + ' pass. Pick a symptom on the left for a targeted capture.';
  else                 msg = 'All ' + s.pass + ' checks pass. Pick a symptom on the left to measure live latency.';
  html += '<div class="inst-verdict">' + msg + '</div>';

  html += '<div class="inst-stats">';
  html += renderStatCell('pass',  String(s.pass || 0),  null);
  html += renderStatCell('warn',  String(s.warn || 0),  null);
  html += renderStatCell('fail',  String(s.fail || 0),  null);
  html += '</div>';

  html += '<div class="inst-actions">';
  html += '<button class="inst-btn inst-btn-primary" onclick="runScan(\'MouseFreezing\')">Start with mouse → <span class="inst-arr">→</span></button>';
  html += '<button class="inst-btn inst-btn-ghost" onclick="setMode(\'expert\')">Command view</button>';
  html += '</div>';

  html += '</div>';
  return html;
}

// ------------------------------------------------------------
// Helpers
// ------------------------------------------------------------
function renderStatCell(label, value, extraCls) {
  return '<div class="inst-stat' + (extraCls ? ' ' + extraCls : '') + '">' +
    '<div class="inst-stat-k">' + escHtml(label) + '</div>' +
    '<div class="inst-stat-v">' + value + '</div>' +
    '</div>';
}

function findSymptom(key) {
  for (var i = 0; i < INSTRUMENT_SYMPTOMS.length; i++) {
    if (INSTRUMENT_SYMPTOMS[i].key === key) return INSTRUMENT_SYMPTOMS[i];
  }
  return null;
}

// SVG gap-distribution chart (mouse freezing)
function renderGapChart(mouseGaps) {
  var gaps = mouseGaps.gaps || [];
  var maxMs = mouseGaps.maxGapMs || 10;
  var w = 560, h = 70, baseline = 54;

  var sticks = '';
  gaps.forEach(function (g, i) {
    // Spread across the 10s range proportionally by index
    var x = Math.round(30 + (i / Math.max(1, gaps.length - 1)) * (w - 60));
    var height = Math.min(40, Math.round((g.gapMs / maxMs) * 38));
    sticks += '<line x1="' + x + '" y1="' + (baseline - height) + '" x2="' + x + '" y2="' + baseline + '" stroke="var(--accent)" stroke-width="1.3"/>';
  });

  // Highlight longest
  var longestX = Math.round(w / 2);
  var maxLine =
    '<line x1="' + longestX + '" y1="8" x2="' + longestX + '" y2="' + baseline + '" stroke="var(--accent)" stroke-width="2.5"/>' +
    '<circle cx="' + longestX + '" cy="8" r="3.5" fill="var(--accent)"/>' +
    '<text x="' + (longestX + 8) + '" y="14" font-family="Inter" font-weight="500" font-size="11" fill="var(--accent)">' +
    Math.round(mouseGaps.maxGapMs) + ' ms</text>';

  var html = '<div class="inst-chart">';
  html += '<div class="inst-kicker" style="margin-bottom:6px">gap distribution · 10s</div>';
  html += '<svg viewBox="0 0 ' + w + ' ' + h + '" width="100%" height="' + h + '">';
  html += '<line x1="0" y1="' + baseline + '" x2="' + w + '" y2="' + baseline + '" stroke="var(--hair)" stroke-width="1"/>';
  html += '<g font-family="JetBrains Mono" font-size="9" fill="var(--ink-3)">';
  html += '<text x="0" y="68">0s</text><text x="' + (w / 2 - 10) + '" y="68">5s</text><text x="' + (w - 18) + '" y="68">10s</text>';
  html += '</g>';
  html += sticks;
  html += maxLine;
  html += '</svg>';
  html += '</div>';
  return html;
}

// Top-finding card fallback (non-mouse symptoms)
function renderTopFindingCard(top) {
  var html = '<div class="inst-top-find">';
  html += '<div class="inst-kicker">highest severity</div>';
  html += '<div class="inst-top-find-title">' + escHtml(top.title) + '</div>';
  if (top.current) html += '<div class="inst-top-find-meta">Currently: <b>' + escHtml(top.current) + '</b></div>';
  if (top.expected) html += '<div class="inst-top-find-meta">Expected: <b style="color:var(--accent-2)">' + escHtml(top.expected) + '</b></div>';
  html += '</div>';
  return html;
}

// ------------------------------------------------------------
// Events — wire up symptom-row clicks after each render
// ------------------------------------------------------------
function wireInstrumentEvents() {
  document.querySelectorAll('.inst-sym-row').forEach(function (row) {
    row.addEventListener('click', function () {
      var sym = row.dataset.symptom;
      if (sym && typeof runScan === 'function') runScan(sym);
    });
  });
}

// ------------------------------------------------------------
// Actions (delegate to existing app.js helpers)
// ------------------------------------------------------------
window.applyAllInstrumentFixes = async function () {
  var findings = (state.findings && state.findings.findings) || [];
  var auto = [];
  findings.forEach(function (f, i) { if (f.fixType === 'auto' && f.fix) auto.push(i); });
  if (auto.length === 0) return;
  for (var k = 0; k < auto.length; k++) {
    if (typeof applyFinding === 'function') {
      try { await applyFinding(auto[k]); } catch (e) { console.warn('Fix failed:', e); }
    }
  }
};

// Exposed for app.js to call
window.renderInstrument = renderInstrument;
