// LatencyGuard — App Shell
// Vanilla JS, no framework. Tauri IPC via window.__TAURI__

const state = {
  mode: 'simple',
  auditData: null,
  pipelineData: null,
  systemInfo: null,
  scanning: false,
  mouseDiag: null,
  activeSymptom: null,
  findings: null,
  diagnosticProgress: null,
};

// --- Tauri IPC helpers ---
async function invoke(cmd, args) {
  if (window.__TAURI__) {
    return window.__TAURI__.core.invoke(cmd, args || {});
  }
  // Fallback for dev without Tauri (static file preview)
  console.warn('Tauri not available, invoke:', cmd, args);
  return null;
}

// --- Init ---
document.addEventListener('DOMContentLoaded', async () => {
  await loadSystemInfo();
  await loadCachedData();
  render();
});

async function loadCachedData() {
  try {
    var audit = await invoke('get_latest_audit');
    if (audit && audit !== null && audit.summary) {
      state.auditData = audit;
    }
  } catch (e) {
    console.warn('No cached audit data:', e);
  }
  try {
    var pipeline = await invoke('get_pipeline_data');
    if (pipeline && pipeline !== null) {
      state.pipelineData = pipeline;
    }
  } catch (e) {
    console.warn('No pipeline data:', e);
  }
}

async function loadSystemInfo() {
  try {
    state.systemInfo = await invoke('get_system_info');
    renderSysChips();
  } catch (e) {
    console.error('Failed to load system info:', e);
  }
}

function renderSysChips() {
  const el = document.getElementById('sys-chips');
  if (!state.systemInfo || !el) return;
  const info = state.systemInfo;
  const chips = [];
  if (info.cpu) chips.push(info.cpu.replace('AMD ', '').replace(' 8-Core Processor', ''));
  if (info.gpu) chips.push(info.gpu.replace('NVIDIA ', '').replace('GeForce ', ''));
  if (info.ram) chips.push(info.ram);
  el.innerHTML = chips.map(c => '<span class="sys-chip">' + escHtml(c) + '</span>').join('');
}

// --- Mode toggle ---
function setMode(mode) {
  state.mode = mode;
  document.querySelectorAll('.mode-toggle button').forEach(b => {
    const isActive = b.dataset.mode === mode;
    b.classList.toggle('active', isActive);
    b.setAttribute('aria-selected', isActive);
  });
  announce('Switched to ' + mode + ' mode');
  render();
}

function announce(msg) {
  const el = document.getElementById('a11y-announce');
  if (el) { el.textContent = ''; setTimeout(() => { el.textContent = msg; }, 50); }
}
// Expose to onclick
window.setMode = setMode;

// --- Render ---
// v2 handoff mode map (see plan: ~/.claude/plans/latencyguard-design-handoff-v2.md):
//   'simple'   -> Instrument (symptom picker + finding)   ← Phase 2 LANDED
//   'timeline' -> Timeline   (history = home)             — Phase 3, placeholder
//   'expert'   -> Command    (dense canvas)               — Phase 4, uses old renderExpert for now
function render() {
  const app = document.getElementById('app');
  if (state.mode === 'simple') {
    // Prefer v2 Instrument view when available (views/instrument.js).
    // Fall back to legacy renderSimple only if instrument.js didn't load.
    if (typeof window.renderInstrument === 'function') {
      window.renderInstrument(app);
    } else {
      renderSimple(app);
    }
  } else if (state.mode === 'timeline') {
    renderTimelinePlaceholder(app);
  } else {
    renderExpert(app);
  }
}

// Phase 1 placeholder — Phase 3 will replace this with the full Timeline view
// from design/project/LatencyGuard Wireframes v2.html #p3.
function renderTimelinePlaceholder(app) {
  app.innerHTML =
    '<section style="max-width:980px;margin:60px auto;padding:40px 32px;' +
    'border:1px solid var(--hair);border-radius:var(--r);background:#fff;text-align:center">' +
    '<div class="mono" style="font-family:var(--font-mono);font-size:10.5px;letter-spacing:.12em;' +
    'text-transform:uppercase;color:var(--ink-3);margin-bottom:8px">Timeline · coming soon</div>' +
    '<h2 style="font-size:40px;font-weight:600;letter-spacing:-.03em;line-height:1.05;margin:4px 0 12px">' +
    '20 days. <span style="color:var(--ink-3);font-weight:500">One chart.</span></h2>' +
    '<p style="color:var(--ink-3);font-size:16px;max-width:520px;margin:0 auto;line-height:1.5;letter-spacing:-.005em">' +
    'Experiment history lands in Phase 3 of the v2 design handoff. ' +
    'Until then use the <b>Instrument</b> tab for live diagnostics or <b>Command</b> for dense expert view.</p>' +
    '</section>';
}

// --- Category mapping ---
const CATEGORIES = {
  'OS':         { label: 'Windows',     icon: '&#9881;',   color: 'var(--blue)' },
  'NIC':        { label: 'Networking',  icon: '&#127760;', color: 'var(--cyan)' },
  'GPU':        { label: 'GPU',         icon: '&#127918;', color: 'var(--purple)' },
  'Memory':     { label: 'Memory',      icon: '&#128190;', color: 'var(--amber)' },
  'Peripheral': { label: 'Peripherals', icon: '&#128433;', color: 'var(--green)' },
  'Network':    { label: 'Network',     icon: '&#128225;', color: 'var(--cyan)' },
};

// --- Simple Mode ---
function renderSimple(container) {
  if (state.scanning) {
    container.innerHTML = renderDiagnosticProgress();
    return;
  }
  if (state.findings) {
    renderFindings(container, state.findings);
    return;
  }
  if (!state.auditData) {
    container.innerHTML = renderSymptomPicker();
    return;
  }
  const data = state.auditData;
  const summary = data.summary;
  const checks = data.checks || [];
  const scoreColor = summary.score >= 80 ? 'var(--green)' : summary.score >= 50 ? 'var(--amber)' : 'var(--red)';

  // Score ring
  const circum = 439.82;
  const dashLen = (circum * summary.score / 100).toFixed(1);
  const dashGap = (circum - dashLen).toFixed(1);

  let html = '<div class="simple-center">';

  // Score ring
  html += '<div class="score-ring-wrap">';
  html += '<svg width="160" height="160" viewBox="0 0 160 160" role="img" aria-label="Health score: ' + summary.score + ' out of 100">';
  html += '<circle class="track" cx="80" cy="80" r="70"/>';
  html += '<circle class="bar" cx="80" cy="80" r="70" stroke="' + scoreColor + '" stroke-dasharray="' + dashLen + ' ' + dashGap + '"/>';
  html += '</svg>';
  html += '<div class="score-num" style="color:' + scoreColor + '" aria-hidden="true">' + summary.score + '</div>';
  html += '<div class="score-label" aria-hidden="true">Health Score</div>';
  html += '</div>';

  // Pills
  html += '<div class="pills">';
  html += '<span class="pill pill-pass">' + summary.pass + ' optimized</span>';
  if (summary.warn > 0) html += '<span class="pill pill-warn">' + summary.warn + ' suggestion' + (summary.warn > 1 ? 's' : '') + '</span>';
  if (summary.fail > 0) html += '<span class="pill pill-fail">' + summary.fail + ' issue' + (summary.fail > 1 ? 's' : '') + '</span>';
  html += '</div>';
  html += '</div>';

  // Metric cards (from pipeline data)
  html += renderMetricCards(state.pipelineData);

  // Group checks by category
  const groups = {};
  checks.forEach((c, i) => {
    const cat = c.category || 'Other';
    if (!groups[cat]) groups[cat] = [];
    groups[cat].push({ ...c, _index: i });
  });

  // Render each category
  const catOrder = ['OS', 'GPU', 'NIC', 'Network', 'Memory', 'Peripheral'];
  catOrder.forEach(cat => {
    const items = groups[cat];
    if (!items || items.length === 0) return;
    const catInfo = CATEGORIES[cat] || { label: cat, icon: '&#9670;', color: 'var(--muted)' };
    const passCount = items.filter(c => c.status === 'PASS').length;
    const totalCount = items.length;
    const allPass = passCount === totalCount;

    html += '<div class="cat-section">';
    html += '<button class="cat-header" aria-expanded="' + (!allPass) + '" onclick="toggleCat(\'' + cat + '\')">';
    html += '<span class="cat-icon" style="color:' + catInfo.color + '" aria-hidden="true">' + catInfo.icon + '</span>';
    html += '<span class="cat-label">' + catInfo.label + '</span>';
    html += '<span class="cat-count">' + passCount + '/' + totalCount + '</span>';
    html += '<span class="cat-badge" style="background:' + (allPass ? 'rgba(16,185,129,.15);color:var(--green)' : 'rgba(245,158,11,.15);color:var(--amber)') + '">' + (allPass ? 'All good' : (totalCount - passCount) + ' to fix') + '</span>';
    html += '<span class="cat-chevron" id="chev-' + cat + '" aria-hidden="true">&#9662;</span>';
    html += '</button>';

    html += '<div class="cat-body" id="cat-' + cat + '" style="' + (allPass ? 'display:none' : '') + '">';
    items.forEach(c => {
      const isPassing = c.status === 'PASS';
      const statusColor = isPassing ? 'var(--green)' : c.status === 'FAIL' ? 'var(--red)' : 'var(--amber)';
      const hasFix = c.fix && c.fix !== '';

      html += '<div class="setting-row">';
      const statusText = isPassing ? 'Pass' : c.status === 'FAIL' ? 'Fail' : 'Warning';
      html += '<div class="setting-status"><span class="setting-dot" style="background:' + statusColor + '" aria-hidden="true"></span><span class="sr-only">' + statusText + '</span></div>';
      html += '<div class="setting-info">';
      html += '<div class="setting-name">' + escHtml(c.name) + '</div>';
      html += '<div class="setting-values">';
      html += '<span class="setting-current">Current: <b>' + escHtml(truncate(c.current, 50)) + '</b></span>';
      if (c.expected && !isPassing) {
        html += '<span class="setting-arrow">&#8594;</span>';
        html += '<span class="setting-expected">Recommended: <b style="color:var(--green)">' + escHtml(truncate(c.expected, 50)) + '</b></span>';
      }
      html += '</div>';
      if (c.message && !isPassing) {
        html += '<div class="setting-why">' + escHtml(c.message) + '</div>';
      }
      html += '</div>';

      // Action button
      if (isPassing) {
        html += '<div class="setting-action"><span class="setting-pass-badge">&#10003;</span></div>';
      } else if (hasFix) {
        html += '<div class="setting-action"><button class="setting-apply" id="fix-' + c._index + '" onclick="applyFixByIndex(' + c._index + ')">Apply</button></div>';
      } else if (c.fixNote) {
        html += '<div class="setting-action"><button class="setting-info-btn" onclick="showFixNote(' + c._index + ')">Info</button></div>';
      } else {
        html += '<div class="setting-action"></div>';
      }

      html += '</div>';
    });
    html += '</div></div>';
  });

  // Actions
  html += '<div class="action-bar">';
  html += '<button class="btn-secondary" onclick="backToSymptoms()">&#8592; Symptoms</button>';
  html += '<button class="btn-primary" onclick="runScan()">&#8635; Scan Again</button>';
  html += '<button class="btn-secondary" onclick="exportReport()" aria-label="Export HTML report">&#128196; Export Report</button>';
  html += '<button class="btn-secondary" onclick="setMode(\'expert\')">Expert Mode &#8594;</button>';
  html += '</div>';

  container.innerHTML = html;
}

function truncate(str, max) {
  if (!str) return '';
  return str.length > max ? str.substring(0, max - 3) + '...' : str;
}

window.toggleCat = function(cat) {
  const body = document.getElementById('cat-' + cat);
  const chev = document.getElementById('chev-' + cat);
  const btn = body ? body.previousElementSibling : null;
  if (!body) return;
  const open = body.style.display !== 'none';
  body.style.display = open ? 'none' : 'block';
  if (chev) chev.innerHTML = open ? '&#9662;' : '&#9652;';
  if (btn) btn.setAttribute('aria-expanded', !open);
};

window.applyFixByIndex = async function(index) {
  const checks = (state.auditData && state.auditData.checks) ? state.auditData.checks : [];
  const check = checks[index];
  if (!check || !check.fix) return;
  if (!confirm('Apply fix: ' + check.name + '?\n\nThis will modify a system setting.')) return;

  const btn = document.getElementById('fix-' + index);
  if (btn) { btn.textContent = 'Applying...'; btn.disabled = true; }

  try {
    const ok = await invoke('apply_fix', { command: check.fix });
    if (ok && btn) {
      btn.textContent = '✓ Done';
      btn.classList.add('done');
    } else if (btn) {
      btn.textContent = 'Failed';
      setTimeout(() => { btn.textContent = 'Retry'; btn.disabled = false; }, 2000);
    }
  } catch (e) {
    if (btn) { btn.textContent = 'Error'; }
    console.error('Fix failed:', e);
  }
};

window.showFixNote = function(index) {
  const checks = (state.auditData && state.auditData.checks) ? state.auditData.checks : [];
  const check = checks[index];
  if (check && check.fixNote) showToast(check.fixNote, 'info');
};

function renderMetricCards(pd) {
  if (!pd) return '';
  var html = '<div class="metric-cards">';

  // Card 1: DPC Latency
  var dpcPct = pd.cpuTotal ? pd.cpuTotal.dpcPct : null;
  var dpcVal = dpcPct !== null ? dpcPct.toFixed(2) + '%' : 'N/A';
  var dpcColor = dpcPct === null ? 'var(--muted)' : dpcPct < 2 ? 'var(--green)' : dpcPct < 5 ? 'var(--amber)' : 'var(--red)';
  html += metricCard('DPC Latency', dpcVal, 'Total DPC time', dpcColor, '&#9201;');

  // Card 2: Network
  var netVal = 'N/A';
  var netSub = 'No ping data';
  var netColor = 'var(--muted)';
  if (pd.networkLatency) {
    var bestPing = 999;
    var bestHost = '';
    var keys = Object.keys(pd.networkLatency);
    for (var i = 0; i < keys.length; i++) {
      var entry = pd.networkLatency[keys[i]];
      if (entry && entry.p50 < bestPing) {
        bestPing = entry.p50;
        bestHost = keys[i].replace('ping-', '').replace('.ds.on.epicgames.com', '');
      }
    }
    if (bestPing < 999) {
      netVal = bestPing + 'ms';
      netSub = bestHost + ' (p50)';
      netColor = bestPing < 20 ? 'var(--green)' : bestPing < 50 ? 'var(--amber)' : 'var(--red)';
    }
  }
  html += metricCard('Network', netVal, netSub, netColor, '&#127760;');

  // Card 3: Interrupt Distribution
  var cpu0Val = 'N/A';
  var cpu0Sub = 'CPU 0 interrupt share';
  var cpu0Color = 'var(--muted)';
  if (pd.interruptTopology) {
    var cpu0Share = pd.interruptTopology.cpu0Share;
    cpu0Val = cpu0Share.toFixed(1) + '%';
    cpu0Color = cpu0Share < 5 ? 'var(--green)' : cpu0Share < 20 ? 'var(--amber)' : 'var(--red)';
    cpu0Sub = cpu0Share < 5 ? 'Balanced (optimal)' : 'CPU 0 overloaded';
  }
  html += metricCard('Interrupts', cpu0Val, cpu0Sub, cpu0Color, '&#9889;');

  // Card 4: Connection Quality
  var qualVal = 'N/A';
  var qualSub = 'No data';
  var qualColor = 'var(--muted)';
  if (pd.connectionQuality !== undefined && pd.connectionQuality !== null) {
    qualVal = pd.connectionQuality + '/100';
    qualColor = pd.connectionQuality >= 80 ? 'var(--green)' : pd.connectionQuality >= 50 ? 'var(--amber)' : 'var(--red)';
    qualSub = pd.connectionQuality >= 80 ? 'Excellent' : pd.connectionQuality >= 50 ? 'Fair' : 'Poor';
  }
  html += metricCard('Connection', qualVal, qualSub, qualColor, '&#128225;');

  html += '</div>';
  return html;
}

function metricCard(title, value, subtitle, color, icon) {
  return '<div class="metric-card">' +
    '<div class="metric-icon" style="color:' + color + '">' + icon + '</div>' +
    '<div class="metric-body">' +
    '<div class="metric-title">' + title + '</div>' +
    '<div class="metric-value" style="color:' + color + '">' + value + '</div>' +
    '<div class="metric-sub">' + escHtml(subtitle) + '</div>' +
    '</div></div>';
}

// --- Symptom Picker ---
function renderSymptomPicker() {
  var html = '<div class="symptom-picker">';
  html += '<div class="symptom-heading">What are you experiencing?</div>';
  html += '<div class="symptom-subheading">Select a symptom and we\'ll run targeted diagnostics</div>';
  html += '<div class="symptom-grid">';

  html += '<button class="symptom-card" data-symptom="MouseFreezing" onclick="startDiagnostic(\'MouseFreezing\')" tabindex="0">';
  html += '<div class="symptom-icon">&#128433;</div>';
  html += '<div class="symptom-title">Mouse Freezing</div>';
  html += '<div class="symptom-desc">Cursor stutters, freezes, or feels unresponsive during gameplay</div>';
  html += '</button>';

  html += '<button class="symptom-card" data-symptom="FrameDrops" onclick="startDiagnostic(\'FrameDrops\')" tabindex="0">';
  html += '<div class="symptom-icon">&#127918;</div>';
  html += '<div class="symptom-title">Frame Drops</div>';
  html += '<div class="symptom-desc">FPS drops, micro-stutters, or hitching during gameplay</div>';
  html += '</button>';

  html += '<button class="symptom-card" data-symptom="GeneralSluggishness" onclick="startDiagnostic(\'GeneralSluggishness\')" tabindex="0">';
  html += '<div class="symptom-icon">&#128034;</div>';
  html += '<div class="symptom-title">General Sluggishness</div>';
  html += '<div class="symptom-desc">Everything feels slow or laggy, system not performing well</div>';
  html += '</button>';

  html += '<button class="symptom-card" data-symptom="FullAudit" onclick="startDiagnostic(\'FullAudit\')" tabindex="0">';
  html += '<div class="symptom-icon">&#128269;</div>';
  html += '<div class="symptom-title">Full System Audit</div>';
  html += '<div class="symptom-desc">Check all 41 settings across OS, GPU, NIC, and peripherals</div>';
  html += '</button>';

  html += '</div></div>';
  return html;
}

// --- Diagnostic Progress ---
var DIAGNOSTIC_STEPS = {
  MouseFreezing: [
    'Checking mouse polling rate and USB controller',
    'Analyzing GPU interrupt configuration',
    'Measuring DPC latency',
    'Running 10-second mouse input capture',
    'Analyzing results'
  ],
  FrameDrops: [
    'Checking GPU configuration (HAGS, MSI, ReBAR)',
    'Analyzing power and priority settings',
    'Measuring DPC latency',
    'Checking frame timing and memory',
    'Analyzing results'
  ],
  GeneralSluggishness: [
    'Checking power plan and CPU priority',
    'Scanning background services and telemetry',
    'Checking memory and network settings',
    'Analyzing system overhead',
    'Analyzing results'
  ],
  FullAudit: [
    'Scanning OS and power settings',
    'Checking GPU and display configuration',
    'Analyzing NIC and network stack',
    'Checking peripherals and memory',
    'Running deep analysis',
    'Analyzing results'
  ]
};

function renderDiagnosticProgress() {
  var symptom = state.activeSymptom || 'FullAudit';
  var steps = DIAGNOSTIC_STEPS[symptom] || DIAGNOSTIC_STEPS.FullAudit;
  var progress = state.diagnosticProgress || { step: 0, total: steps.length, status: '' };

  var titles = {
    MouseFreezing: 'Investigating mouse freezing...',
    FrameDrops: 'Investigating frame drops...',
    GeneralSluggishness: 'Investigating sluggishness...',
    FullAudit: 'Running full system audit...'
  };

  var html = '<div class="diag-progress">';
  html += '<div class="diag-progress-title">' + (titles[symptom] || 'Diagnosing...') + '</div>';
  html += '<div class="diag-progress-sub">' + escHtml(progress.status || 'Starting diagnostics...') + '</div>';

  // Progress bar
  var pct = Math.round((progress.step / steps.length) * 100);
  html += '<div class="progress-bar"><div class="progress-fill" style="width:' + pct + '%"></div></div>';

  // Step list
  html += '<div class="diag-steps">';
  for (var i = 0; i < steps.length; i++) {
    var cls = 'diag-step';
    var icon = (i + 1);
    if (i < progress.step) {
      cls += ' done';
      icon = '&#10003;';
    } else if (i === progress.step) {
      cls += ' active';
    }
    html += '<div class="' + cls + '">';
    html += '<div class="diag-step-icon">' + icon + '</div>';
    html += '<span>' + escHtml(steps[i]) + '</span>';
    html += '</div>';
  }
  html += '</div></div>';
  return html;
}

// --- Diagnostic Chain ---
async function startDiagnostic(symptom) {
  state.activeSymptom = symptom;
  state.scanning = true;
  state.findings = null;
  state.diagnosticProgress = { step: 0, total: 1, status: 'Starting diagnostics...' };
  render();
  announce('Starting ' + symptom + ' diagnostic');

  // Listen for progress events from Tauri
  var unlisten = null;
  if (window.__TAURI__ && window.__TAURI__.event) {
    try {
      unlisten = await window.__TAURI__.event.listen('diagnostic-progress', function(event) {
        state.diagnosticProgress = event.payload;
        // Re-render progress without full render cycle
        var app = document.getElementById('app');
        if (app && state.scanning) {
          app.innerHTML = renderDiagnosticProgress();
        }
      });
    } catch (e) {
      console.warn('Could not listen for progress events:', e);
    }
  }

  try {
    var result = await invoke('run_diagnostic_chain', { symptom: symptom });
    state.scanning = false;
    state.diagnosticProgress = null;

    if (result) {
      state.findings = result;
      state.auditData = result.auditData || state.auditData;
      if (result.mouseDiag) state.mouseDiag = result.mouseDiag;
    }
    render();
    if (result && result.summary) {
      var total = (result.summary.high || 0) + (result.summary.medium || 0) + (result.summary.low || 0);
      announce('Diagnostic complete. Found ' + total + ' issue' + (total !== 1 ? 's' : ''));
    }
  } catch (e) {
    state.scanning = false;
    state.diagnosticProgress = null;
    render();
    showToast('Diagnostic failed: ' + e, 'error');
  } finally {
    if (unlisten) {
      try { await unlisten(); } catch (ignored) {}
    }
  }
}
window.startDiagnostic = startDiagnostic;

// --- Back to symptom picker ---
function backToSymptoms() {
  state.findings = null;
  state.activeSymptom = null;
  state.auditData = null;
  render();
}
window.backToSymptoms = backToSymptoms;

function renderEmpty() {
  return '<div class="empty-state">' +
    '<div class="empty-state-icon">&#128270;</div>' +
    '<div class="empty-state-title">Welcome to LatencyGuard</div>' +
    '<div class="empty-state-desc">Scan your system to detect latency issues and optimize for gaming</div>' +
    '<button class="btn-primary" onclick="runScan()">&#9654; Run First Scan</button>' +
    '</div>';
}

function renderScanning() {
  // Legacy scanning state — now handled by renderDiagnosticProgress
  return renderDiagnosticProgress();
}

async function renderExpert(container) {
  // Tab bar + content containers
  let html = '<div class="expert-tabs" role="tablist" aria-label="Expert mode views">';
  html += '<button class="expert-tab active" data-tab="diagnostics" onclick="switchExpertTab(\'diagnostics\')">Diagnostics</button>';
  html += '<button class="expert-tab" data-tab="history" onclick="switchExpertTab(\'history\')">History</button>';
  html += '<button class="expert-tab" data-tab="advanced" onclick="switchExpertTab(\'advanced\')">Advanced</button>';
  html += '<button class="expert-tab" data-tab="live" onclick="switchExpertTab(\'live\')">Live Monitor</button>';
  html += '</div>';
  html += '<div id="tab-diagnostics" class="tab-pane active"></div>';
  html += '<div id="tab-history" class="tab-pane"></div>';
  html += '<div id="tab-advanced" class="tab-pane"></div>';
  html += '<div id="tab-live" class="tab-pane"><div class="expert-placeholder"><div style="font-size:36px;opacity:0.3;margin-bottom:12px">&#128308;</div><div style="font-size:16px;font-weight:600;margin-bottom:8px">Live Monitor</div><div style="color:var(--muted)">Real-time streaming during gameplay — coming in Phase 3</div></div></div>';
  container.innerHTML = html;

  // Load pipeline data
  if (!state.pipelineData) {
    try { state.pipelineData = await invoke('get_pipeline_data'); } catch (e) { console.error(e); }
  }

  // Render diagnostics tab (default)
  renderDiagnostics(document.getElementById('tab-diagnostics'), state.auditData, state.pipelineData);
}

window.switchExpertTab = function(tab) {
  document.querySelectorAll('.expert-tab').forEach(b => {
    const isActive = b.dataset.tab === tab;
    b.classList.toggle('active', isActive);
    b.setAttribute('aria-selected', isActive);
  });
  document.querySelectorAll('.tab-pane').forEach(p => p.classList.toggle('active', p.id === 'tab-' + tab));

  // Lazy-load tab content
  const pane = document.getElementById('tab-' + tab);
  if (tab === 'history' && pane.innerHTML === '') {
    renderHistory(pane);
  } else if (tab === 'advanced' && pane.innerHTML === '') {
    renderAdvanced(pane, state.pipelineData);
  }
};

// --- Actions ---
async function runScan() {
  // Re-run the active symptom, or default to FullAudit
  startDiagnostic(state.activeSymptom || 'FullAudit');
}
window.runScan = runScan;

async function applyFix(issueIndex) {
  const checks = (state.auditData && state.auditData.checks) ? state.auditData.checks : [];
  const issues = checks.filter(c => c.status !== 'PASS' && c.status !== 'SKIP');
  const issue = issues[issueIndex];
  if (!issue || !issue.fix) return;

  const btn = document.querySelector('#issue-' + issueIndex + ' .issue-btn');
  if (btn) { btn.textContent = 'Applying...'; btn.disabled = true; }

  try {
    const ok = await invoke('apply_fix', { command: issue.fix });
    if (ok && btn) {
      btn.textContent = '✓ Fixed';
      btn.classList.add('done');
    } else if (btn) {
      btn.textContent = 'Failed';
      setTimeout(() => { btn.textContent = 'Retry'; btn.disabled = false; }, 2000);
    }
  } catch (e) {
    if (btn) { btn.textContent = 'Error'; }
    console.error('Fix failed:', e);
  }
}
window.applyFix = applyFix;

// --- Export ---
async function exportReport() {
  var btns = document.querySelectorAll('.action-bar .btn-secondary');
  var btn = null;
  for (var i = 0; i < btns.length; i++) {
    if (btns[i].textContent.indexOf('Export') !== -1) { btn = btns[i]; break; }
  }
  if (btn) { btn.textContent = 'Exporting...'; btn.disabled = true; }

  try {
    var path = await invoke('export_report');
    if (path) {
      showToast('Report exported to: ' + path, 'success');
    } else {
      showToast('Export completed but no file path returned.', 'info');
    }
  } catch (e) {
    showToast('Export failed: ' + e, 'error');
  }

  if (btn) { btn.textContent = '\uD83D\uDCC4 Export Report'; btn.disabled = false; }
}
window.exportReport = exportReport;

// --- Toast notifications ---
function showToast(message, type) {
  var container = document.getElementById('toasts');
  if (!container) return;
  var el = document.createElement('div');
  el.className = 'toast toast-' + (type || 'info');
  el.textContent = message;
  container.appendChild(el);
  setTimeout(function() { if (el.parentNode) el.parentNode.removeChild(el); }, 5000);
}
window.showToast = showToast;

// --- Util ---
function escHtml(str) {
  if (!str) return '';
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}
