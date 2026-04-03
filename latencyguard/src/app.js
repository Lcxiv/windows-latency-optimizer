// LatencyGuard — App Shell
// Vanilla JS, no framework. Tauri IPC via window.__TAURI__

const state = {
  mode: 'simple',
  auditData: null,
  pipelineData: null,
  systemInfo: null,
  scanning: false,
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
  render();
});

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
  document.querySelectorAll('.mode-toggle span').forEach(s => {
    s.classList.toggle('active', s.dataset.mode === mode);
  });
  render();
}
// Expose to onclick
window.setMode = setMode;

// --- Render ---
function render() {
  const app = document.getElementById('app');
  if (state.mode === 'simple') {
    renderSimple(app);
  } else {
    renderExpert(app);
  }
}

// --- Simple Mode ---
function renderSimple(container) {
  if (state.scanning) {
    container.innerHTML = renderScanning();
    return;
  }
  if (!state.auditData) {
    container.innerHTML = renderEmpty();
    return;
  }
  const data = state.auditData;
  const summary = data.summary;
  const checks = data.checks || [];
  const scoreColor = summary.score >= 80 ? 'var(--green)' : summary.score >= 50 ? 'var(--amber)' : 'var(--red)';

  // Score ring
  const circum = 439.82; // 2 * PI * 70
  const dashLen = (circum * summary.score / 100).toFixed(1);
  const dashGap = (circum - dashLen).toFixed(1);

  // Issues (non-PASS)
  const issues = checks.filter(c => c.status !== 'PASS' && c.status !== 'SKIP');
  const passed = checks.filter(c => c.status === 'PASS');

  let html = '<div class="simple-center">';

  // Score ring
  html += '<div class="score-ring-wrap">';
  html += '<svg width="160" height="160" viewBox="0 0 160 160">';
  html += '<circle class="track" cx="80" cy="80" r="70"/>';
  html += '<circle class="bar" cx="80" cy="80" r="70" stroke="' + scoreColor + '" stroke-dasharray="' + dashLen + ' ' + dashGap + '"/>';
  html += '</svg>';
  html += '<div class="score-num" style="color:' + scoreColor + '">' + summary.score + '</div>';
  html += '<div class="score-label">Health Score</div>';
  html += '</div>';

  // Pills
  html += '<div class="pills">';
  html += '<span class="pill pill-pass">' + summary.pass + ' optimized</span>';
  if (summary.warn > 0) html += '<span class="pill pill-warn">' + summary.warn + ' suggestion' + (summary.warn > 1 ? 's' : '') + '</span>';
  if (summary.fail > 0) html += '<span class="pill pill-fail">' + summary.fail + ' issue' + (summary.fail > 1 ? 's' : '') + '</span>';
  html += '</div>';

  // Issues
  if (issues.length > 0) {
    html += '<div class="issue-card">';
    html += '<div class="issue-card-title">Suggestions</div>';
    issues.forEach((c, i) => {
      const icon = c.status === 'FAIL' ? '&#10007;' : '&#9888;';
      const iconColor = c.status === 'FAIL' ? 'var(--red)' : 'var(--amber)';
      const hasFix = c.fix && c.fix !== '';
      html += '<div class="issue-row" id="issue-' + i + '">';
      html += '<span class="issue-icon" style="color:' + iconColor + '">' + icon + '</span>';
      html += '<div class="issue-text">';
      html += '<div class="issue-name">' + escHtml(c.name) + '</div>';
      html += '<div class="issue-desc">' + escHtml(c.message || c.current) + '</div>';
      html += '</div>';
      if (hasFix) {
        html += '<button class="issue-btn" onclick="applyFix(' + i + ')">Apply</button>';
      } else if (c.fixNote) {
        html += '<button class="issue-btn" onclick="alert(\'' + escHtml(c.fixNote).replace(/'/g, "\\'") + '\')">How to fix</button>';
      }
      html += '</div>';
    });
    html += '</div>';
  } else {
    html += '<div class="issue-card" style="border-color:rgba(16,185,129,.3);text-align:center;padding:24px">';
    html += '<span style="font-size:24px;color:var(--green)">&#10003;</span>';
    html += '<div style="font-size:14px;font-weight:600;margin-top:8px">All checks passing</div>';
    html += '<div style="font-size:12px;color:var(--muted);margin-top:4px">Your system is optimized for low-latency gaming</div>';
    html += '</div>';
  }

  // Actions
  html += '<div class="action-bar">';
  html += '<button class="btn-primary" onclick="runScan()">&#8635; Scan Again</button>';
  html += '<button class="btn-secondary" onclick="setMode(\'expert\')">Expert Mode &#8594;</button>';
  html += '</div>';

  html += '</div>';
  container.innerHTML = html;
}

function renderEmpty() {
  return '<div class="empty-state">' +
    '<div class="empty-state-icon">&#128270;</div>' +
    '<div class="empty-state-title">Welcome to LatencyGuard</div>' +
    '<div class="empty-state-desc">Scan your system to detect latency issues and optimize for gaming</div>' +
    '<button class="btn-primary" onclick="runScan()">&#9654; Run First Scan</button>' +
    '</div>';
}

function renderScanning() {
  return '<div class="simple-center" style="padding-top:60px">' +
    '<div style="font-size:48px;opacity:0.3;margin-bottom:16px">&#9881;</div>' +
    '<div style="font-size:18px;font-weight:600">Scanning your system...</div>' +
    '<div class="scanning-text">Checking 37 latency settings across OS, GPU, NIC, and more</div>' +
    '<div class="progress-bar"><div class="progress-fill" style="width:60%"></div></div>' +
    '</div>';
}

async function renderExpert(container) {
  // Tab bar + content containers
  let html = '<div class="expert-tabs">';
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
  document.querySelectorAll('.expert-tab').forEach(b => b.classList.toggle('active', b.dataset.tab === tab));
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
  state.scanning = true;
  render();

  try {
    state.auditData = await invoke('run_audit', { mode: 'Deep' });
    state.scanning = false;
    render();
  } catch (e) {
    state.scanning = false;
    state.auditData = null;
    render();
    alert('Scan failed: ' + e);
  }
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

// --- Util ---
function escHtml(str) {
  if (!str) return '';
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}
