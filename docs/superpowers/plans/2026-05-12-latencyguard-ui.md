# LatencyGuard UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the v4-refined prototype's dark frosted glass design into the real Tauri v2 app, replacing the current light Apple-inspired theme with the validated dark glass + teal accent design system across all three modes (Simple, Monitor, Expert).

**Architecture:** Vanilla JS frontend in `latencyguard/src/` with no build step. CSS design tokens rewritten from light to dark. New view files replace legacy ones. Reusable components extracted for score ring, CPU heatmap, and Chart.js timeline. Existing Tauri IPC (`invoke()`) and Rust backend commands unchanged.

**Tech Stack:** Vanilla HTML/CSS/JS, Chart.js 4.x (bundled), Tauri v2 WebView2, existing PowerShell diagnostic engine.

**User Verification:** NO — no user verification required.

---

## File Structure

### Files to Create

| File | Responsibility |
|------|---------------|
| `latencyguard/src/lib/chart.min.js` | Bundled Chart.js 4.4.0 for offline use |
| `latencyguard/src/components/score-ring.js` | SVG animated score ring (Simple results + tray) |
| `latencyguard/src/components/cpu-heatmap.js` | 4×4 CPU DPC/interrupt grid (Monitor + diagnostics) |
| `latencyguard/src/components/dpc-timeline.js` | Chart.js wrapper for DPC/Interrupt rolling chart |
| `latencyguard/src/views/simple.js` | Simple Mode: 4-step wizard flow |
| `latencyguard/src/views/monitor.js` | Monitor Mode: real-time dashboard |
| `latencyguard/src/views/expert.js` | Expert Mode: experiment tracker table |
| `latencyguard/src/views/tray.js` | System tray popup overlay |

### Files to Modify

| File | What Changes |
|------|-------------|
| `latencyguard/src/app.css` | Complete rewrite — dark glass tokens, all component styles |
| `latencyguard/src/index.html` | Header restructure, new script tags, status bar, Chart.js |
| `latencyguard/src/app.js` | Mode routing update, state fields, cleanup legacy renderers |

### Files to Remove (Task 7)

| File | Replaced By |
|------|------------|
| `latencyguard/src/views/instrument.js` | `views/simple.js` |
| `latencyguard/src/views/timeline.js` | `views/monitor.js` + `views/expert.js` |
| `latencyguard/src/views/command.js` | `views/expert.js` |
| `latencyguard/src/views/diagnostics.js` | `views/simple.js` (narratives inlined) |
| `latencyguard/src/views/history.js` | `views/expert.js` (comparison absorbed) |
| `latencyguard/src/views/advanced.js` | Dropped — raw data tables not in v4 spec |

---

### Task 0: Project Setup & Chart.js Bundle

**Goal:** Scaffold directories and bundle Chart.js for offline use.

**Files:**
- Create: `latencyguard/src/lib/chart.min.js`
- Create: `latencyguard/src/components/` (directory)

**Acceptance Criteria:**
- [ ] `lib/chart.min.js` contains Chart.js 4.4.0 UMD build
- [ ] `Chart` global is available when script is loaded
- [ ] `components/` directory exists

**Verify:** Open `latencyguard/src/index.html` in browser → `typeof Chart` in console returns `"function"`

**Steps:**

- [ ] **Step 1: Create lib directory and download Chart.js**

```powershell
New-Item -ItemType Directory -Path "latencyguard/src/lib" -Force
Invoke-WebRequest -Uri "https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js" -OutFile "latencyguard/src/lib/chart.min.js"
```

- [ ] **Step 2: Verify the download**

Run: `powershell -Command "(Get-Item latencyguard/src/lib/chart.min.js).Length"`
Expected: File size > 100KB (Chart.js UMD is ~200KB)

- [ ] **Step 3: Create components directory**

```powershell
New-Item -ItemType Directory -Path "latencyguard/src/components" -Force
```

- [ ] **Step 4: Commit**

```bash
git add latencyguard/src/lib/chart.min.js
git commit -m "chore: bundle Chart.js 4.4.0 for offline use"
```

---

### Task 1: Design System CSS

**Goal:** Complete rewrite of `app.css` with v4-refined dark frosted glass design tokens, replacing the current light Apple-inspired theme.

**Files:**
- Modify: `latencyguard/src/app.css` (full rewrite — 1,872 lines → ~1,400 lines)

**Acceptance Criteria:**
- [ ] All v4-refined design tokens defined in `:root` (dark backgrounds, teal accent, status colors)
- [ ] `.glass` utility class with `backdrop-filter: blur(16px)`
- [ ] Body background uses dual radial gradients with teal tint
- [ ] Typography: system-ui for UI, monospace for data values, 14px base
- [ ] All status colors match spec: red `#ef4444`, yellow `#eab308`, green `#22c55e`, blue `#3b82f6`
- [ ] Icon box styles for 6 symptom types
- [ ] Focus indicators use 2px teal outline
- [ ] Reduced-motion media query preserved
- [ ] Scrollbar styling for dark theme
- [ ] No light-theme tokens remain

**Verify:** `cargo tauri dev` → app window shows dark background with no white/light elements

**Steps:**

- [ ] **Step 1: Write the test — verify no light-theme tokens remain**

After rewrite, run:
```bash
grep -n "fbfbfd\|#fff\|apple\|systemRed\|FF3B30" latencyguard/src/app.css
```
Expected: No matches (zero lines)

- [ ] **Step 2: Rewrite app.css with v4-refined design tokens**

Replace the entire contents of `latencyguard/src/app.css` with the new design system. The `:root` block:

```css
:root {
  /* ── v4-refined design tokens ── */

  /* Background layers */
  --bg-app: #0b1120;
  --bg-surface: rgba(255,255,255,0.05);
  --bg-surface-alt: rgba(255,255,255,0.07);
  --bg-surface-strong: rgba(255,255,255,0.10);
  --bg-hover: rgba(255,255,255,0.13);

  /* Borders */
  --border: rgba(255,255,255,0.10);
  --border-dim: rgba(255,255,255,0.06);

  /* Text */
  --text: #f1f5f9;
  --text-secondary: #94a3b8;
  --text-tertiary: #64748b;

  /* Accent — teal (never competes with status colors) */
  --accent: #0891b2;
  --accent-bright: #22d3ee;
  --accent-dim: rgba(8,145,178,0.15);

  /* Status colors (never used as accents) */
  --red: #ef4444;
  --red-dim: rgba(239,68,68,0.12);
  --yellow: #eab308;
  --yellow-dim: rgba(234,179,8,0.12);
  --green: #22c55e;
  --green-dim: rgba(34,197,94,0.12);
  --blue: #3b82f6;
  --blue-dim: rgba(59,130,246,0.12);
  --orange: #f97316;

  /* Typography */
  --font: 'Inter', system-ui, -apple-system, 'Segoe UI', sans-serif;
  --font-mono: 'JetBrains Mono', 'Cascadia Code', 'Consolas', monospace;
  --text-xs: 10px;
  --text-sm: 12px;
  --text-base: 14px;
  --text-lg: 16px;
  --text-xl: 20px;
  --text-2xl: 28px;
  --text-3xl: 32px;
  --text-4xl: 48px;

  /* Spacing */
  --sp-xs: 4px;
  --sp-sm: 8px;
  --sp-md: 12px;
  --sp-lg: 16px;
  --sp-xl: 24px;
  --sp-2xl: 32px;

  /* Radius */
  --radius: 8px;
  --radius-lg: 12px;
  --radius-full: 999px;

  /* Motion */
  --ease: cubic-bezier(0.16, 1, 0.3, 1);
  --duration: 150ms;
  --duration-slow: 300ms;
}
```

Body and glass:

```css
* { margin: 0; padding: 0; box-sizing: border-box; }

body {
  font-family: var(--font);
  font-size: var(--text-base);
  color: var(--text);
  background: var(--bg-app);
  background-image:
    radial-gradient(ellipse at 50% -20%, rgba(8,145,178,0.08) 0%, transparent 60%),
    radial-gradient(ellipse at 80% 50%, rgba(8,145,178,0.04) 0%, transparent 40%);
  overflow-x: hidden;
  min-height: 100vh;
  -webkit-font-smoothing: antialiased;
  line-height: 1.5;
}

.glass {
  background: var(--bg-surface);
  backdrop-filter: blur(16px);
  -webkit-backdrop-filter: blur(16px);
  border: 1px solid var(--border-dim);
  box-shadow: 0 2px 8px rgba(0,0,0,0.2), inset 0 1px 0 rgba(255,255,255,0.04);
  border-radius: var(--radius);
}
```

The full CSS file includes sections for:
- Accessibility (`.sr-only`, `:focus-visible` with teal outline, reduced-motion)
- Skip link (dark background)
- App header (glass bar with `-webkit-app-region: drag`)
- System chips (monospace, dark pill)
- Mode switcher (glass pill with teal active state)
- Status bar (bottom bar with collector status)
- Buttons (`.btn-primary` teal gradient, `.btn-secondary` glass, `.btn-ghost` transparent)
- Glass cards (`.card` base class)
- Severity pills (`.pill-high` red, `.pill-medium` yellow, `.pill-low` blue, `.pill-pass` green)
- Icon boxes (`.icon-box` 48×48, colored backgrounds at 15% opacity)
- Symptom grid (3×2 grid for Simple Mode Step 1)
- Progress ring (SVG stroke animation for Step 2)
- Score ring (160px ring for Step 3)
- Finding cards (colored left border for Step 3)
- Fix wizard (before/after comparison cards for Step 4)
- Metric cards (5-across strip for Monitor Mode)
- Alert banner (yellow at 10% opacity)
- CPU heatmap grid (4×4 cells with intensity colors)
- Timeline chart container
- Experiment table (alternating row stripe)
- Tag filter bar (pill-style buttons)
- System tray popup (300px wide overlay)
- Scrollbar styling (dark theme)
- Toast notifications

Each section follows the prototype CSS tokens exactly from `docs/prototypes/latencyguard-v4-refined.html`.

- [ ] **Step 3: Verify no light-theme remnants**

Run: `grep -n "fbfbfd\|apple\|systemRed\|FF3B30\|prefers-color-scheme" latencyguard/src/app.css`
Expected: No matches — the app is dark-only, no light mode toggle.

- [ ] **Step 4: Verify CSS parses cleanly**

Run: `npx stylelint latencyguard/src/app.css --config '{"rules":{}}' 2>&1 || echo "Stylelint not configured, manual check OK"`
Fallback: Open in browser, check DevTools console for CSS parse errors.

- [ ] **Step 5: Commit**

```bash
git add latencyguard/src/app.css
git commit -m "feat: rewrite design system with v4-refined dark glass tokens"
```

---

### Task 2: App Shell & Router

**Goal:** Restructure `index.html` header and update `app.js` mode routing to match v4-refined spec (Simple/Monitor/Expert mode names, new header layout, status bar, Chart.js script tag).

**Files:**
- Modify: `latencyguard/src/index.html`
- Modify: `latencyguard/src/app.js`

**Acceptance Criteria:**
- [ ] Header shows: teal logo + "LatencyGuard" (left), system spec chips (center), mode switcher (right)
- [ ] Mode switcher labels: "Simple" | "Monitor" | "Expert" (not Instrument/Timeline/Command)
- [ ] Status bar at bottom with collector status dot + clock
- [ ] `index.html` loads `lib/chart.min.js`, all component scripts, all new view scripts
- [ ] `app.js` routes `simple` → `renderSimple()`, `monitor` → `renderMonitor()`, `expert` → `renderExpert()`
- [ ] State object has new fields: `monitorData`, `experiments`, `trayVisible`
- [ ] Legacy render functions removed from `app.js` (moved to view files)

**Verify:** `cargo tauri dev` → header renders dark glass bar with teal logo, three mode buttons work, status bar visible at bottom

**Steps:**

- [ ] **Step 1: Write test — verify mode names in HTML**

After changes:
```bash
grep -c "Simple\|Monitor\|Expert" latencyguard/src/index.html
```
Expected: 3 (one per mode button)

```bash
grep -c "Instrument\|Timeline\|Command" latencyguard/src/index.html
```
Expected: 0

- [ ] **Step 2: Rewrite index.html**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>LatencyGuard</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
  <link rel="stylesheet" href="app.css">
</head>
<body>
  <a href="#app" class="skip-link">Skip to main content</a>

  <header class="app-header glass">
    <div class="app-logo">
      <span class="logo-icon"></span>
      <span>Latency<span class="logo-accent">Guard</span></span>
    </div>
    <div id="sys-chips" class="sys-chips"></div>
    <div class="header-spacer"></div>
    <div class="mode-switcher" id="mode-toggle" role="tablist"
         aria-label="View mode">
      <button class="mode-btn active" role="tab" aria-selected="true"
              data-mode="simple" onclick="setMode('simple')">Simple</button>
      <button class="mode-btn" role="tab" aria-selected="false"
              data-mode="monitor" onclick="setMode('monitor')">Monitor</button>
      <button class="mode-btn" role="tab" aria-selected="false"
              data-mode="expert" onclick="setMode('expert')">Expert</button>
    </div>
    <button class="header-tray-link" onclick="toggleTray()"
            aria-label="Open system tray">SYSTEM TRAY</button>
  </header>

  <main id="app" role="main"></main>

  <footer class="status-bar" id="status-bar">
    <span class="status-dot green" id="status-dot"></span>
    <span class="status-label" id="status-label">Collectors idle</span>
    <span class="status-spacer"></span>
    <span class="status-clock" id="status-clock"></span>
  </footer>

  <div id="tray-overlay"></div>
  <div id="toasts" aria-live="polite"></div>
  <div id="a11y-announce" class="sr-only" aria-live="polite"></div>

  <!-- Chart.js (bundled for offline) -->
  <script src="lib/chart.min.js"></script>

  <!-- Reusable components -->
  <script src="components/score-ring.js"></script>
  <script src="components/cpu-heatmap.js"></script>
  <script src="components/dpc-timeline.js"></script>

  <!-- Views -->
  <script src="views/simple.js"></script>
  <script src="views/monitor.js"></script>
  <script src="views/expert.js"></script>
  <script src="views/tray.js"></script>

  <!-- App shell (must load last) -->
  <script src="app.js"></script>
</body>
</html>
```

- [ ] **Step 3: Update app.js — state, routing, and header logic**

Replace the `state` object:

```javascript
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
  // v4 additions
  monitorData: null,
  experiments: [],
  trayVisible: false,
  wizardStep: 0,
  wizardFindings: [],
};
```

Replace the `render()` function:

```javascript
function render() {
  var app = document.getElementById('app');
  if (state.mode === 'simple') {
    if (typeof window.renderSimpleView === 'function') {
      window.renderSimpleView(app);
    } else {
      app.innerHTML = '<div class="empty-state">Simple view loading...</div>';
    }
  } else if (state.mode === 'monitor') {
    if (typeof window.renderMonitorView === 'function') {
      window.renderMonitorView(app);
    } else {
      app.innerHTML = '<div class="empty-state">Monitor view loading...</div>';
    }
  } else if (state.mode === 'expert') {
    if (typeof window.renderExpertView === 'function') {
      window.renderExpertView(app);
    } else {
      app.innerHTML = '<div class="empty-state">Expert view loading...</div>';
    }
  }
}
```

Replace `setMode()` to use `.mode-btn` selector:

```javascript
function setMode(mode) {
  state.mode = mode;
  document.querySelectorAll('.mode-btn').forEach(function(b) {
    var isActive = b.dataset.mode === mode;
    b.classList.toggle('active', isActive);
    b.setAttribute('aria-selected', isActive);
  });
  announce('Switched to ' + mode + ' mode');
  render();
}
```

Update `renderSysChips()` to use v4 styling:

```javascript
function renderSysChips() {
  var el = document.getElementById('sys-chips');
  if (!state.systemInfo || !el) return;
  var info = state.systemInfo;
  var chips = [];
  if (info.cpu) chips.push(info.cpu.replace('AMD ', '').replace(' 8-Core Processor', ''));
  if (info.gpu) chips.push(info.gpu.replace('NVIDIA ', '').replace('GeForce ', ''));
  if (info.ram) chips.push(info.ram);
  if (info.os) chips.push(info.os.replace('Microsoft Windows ', 'Win '));
  el.innerHTML = chips.map(function(c) {
    return '<span class="sys-chip">' + escHtml(c) + '</span>';
  }).join('');
}
```

Add status bar clock:

```javascript
function updateClock() {
  var el = document.getElementById('status-clock');
  if (el) {
    var now = new Date();
    el.textContent = now.toLocaleTimeString('en-US', {
      hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit'
    });
  }
}
setInterval(updateClock, 1000);
```

Remove legacy functions: `renderSimple()`, `renderExpert()`, `renderTimelinePlaceholder()`, `renderMetricCards()`, `renderSymptomPicker()`, `renderDiagnosticProgress()`, all the old inline HTML builders. Keep: `invoke()`, `escHtml()`, `showToast()`, `announce()`, `loadSystemInfo()`, `loadCachedData()`, `setMode()`, `render()`, event listeners for Tauri.

- [ ] **Step 4: Verify mode routing**

Run: `grep -c "renderSimpleView\|renderMonitorView\|renderExpertView" latencyguard/src/app.js`
Expected: 3

Run: `grep -c "renderInstrument\|renderTimeline\|renderCommand" latencyguard/src/app.js`
Expected: 0

- [ ] **Step 5: Commit**

```bash
git add latencyguard/src/index.html latencyguard/src/app.js
git commit -m "feat: restructure app shell with v4-refined header and mode routing"
```

---

### Task 3: Reusable Components

**Goal:** Create three reusable rendering components shared across views: score ring, CPU heatmap, and DPC timeline chart.

**Files:**
- Create: `latencyguard/src/components/score-ring.js`
- Create: `latencyguard/src/components/cpu-heatmap.js`
- Create: `latencyguard/src/components/dpc-timeline.js`

**Acceptance Criteria:**
- [ ] `renderScoreRing(score, size)` returns SVG markup with animated stroke-dasharray
- [ ] Score ring color: green ≥80, yellow 50-79, red <50 (using `--green`, `--yellow`, `--red`)
- [ ] `renderCpuHeatmap(cpuData)` returns a 4×4 grid with role labels (Preferred, Input, GPU/NIC, Game)
- [ ] Heatmap cells color-scale: green <1% DPC, yellow 1-3%, red >5%, with red glow for spikes
- [ ] `createDpcTimeline(canvasId, options)` initializes a Chart.js line chart with 60s rolling window
- [ ] Timeline has two lines: DPC (teal) and Interrupt (blue) with proper legend
- [ ] All functions attached to `window` for access from view files

**Verify:** Load app, navigate to Monitor mode → heatmap renders 16 cells, Chart.js canvas initializes

**Steps:**

- [ ] **Step 1: Write score-ring.js**

```javascript
// components/score-ring.js — SVG animated score ring
// Usage: renderScoreRing(score, size) → HTML string

function renderScoreRing(score, size) {
  size = size || 160;
  var r = (size / 2) - 10;
  var circumference = 2 * Math.PI * r;
  var dashLen = (circumference * Math.min(100, Math.max(0, score)) / 100).toFixed(1);
  var dashGap = (circumference - parseFloat(dashLen)).toFixed(1);

  var color;
  if (score >= 80) color = 'var(--green)';
  else if (score >= 50) color = 'var(--yellow)';
  else color = 'var(--red)';

  var half = size / 2;
  var html = '<div class="score-ring" style="width:' + size + 'px;height:' + size + 'px">';
  html += '<svg width="' + size + '" height="' + size + '" viewBox="0 0 ' + size + ' ' + size + '"';
  html += ' role="img" aria-label="Score: ' + score + ' out of 100">';
  html += '<circle cx="' + half + '" cy="' + half + '" r="' + r + '"';
  html += ' fill="none" stroke="var(--bg-surface-strong)" stroke-width="10"/>';
  html += '<circle cx="' + half + '" cy="' + half + '" r="' + r + '"';
  html += ' fill="none" stroke="' + color + '" stroke-width="10"';
  html += ' stroke-linecap="round" stroke-dasharray="' + dashLen + ' ' + dashGap + '"';
  html += ' transform="rotate(-90 ' + half + ' ' + half + ')"';
  html += ' style="transition: stroke-dasharray 1s ease"/>';
  html += '</svg>';
  html += '<div class="score-value">';
  html += '<span class="score-num" style="color:' + color + '">' + score + '</span>';
  html += '</div>';
  html += '</div>';
  return html;
}

window.renderScoreRing = renderScoreRing;
```

- [ ] **Step 2: Write cpu-heatmap.js**

```javascript
// components/cpu-heatmap.js — 4×4 CPU DPC/interrupt grid
// Usage: renderCpuHeatmap(cpuData) → HTML string
// cpuData: array of { cpu, dpcPct, interruptPct, intrPerSec }

var CPU_ROLES = [
  'Preferred', 'Preferred', 'Input', 'Input',
  'GPU/NIC', 'GPU/NIC', 'GPU/NIC', 'GPU/NIC',
  'Game', 'Game', 'Game', 'Game',
  'Game', 'Game', 'Game', 'Game'
];

function renderCpuHeatmap(cpuData) {
  if (!cpuData || cpuData.length === 0) {
    return '<div class="heatmap-empty">No CPU data available</div>';
  }

  var html = '<div class="heatmap-grid">';

  for (var i = 0; i < 16; i++) {
    var cpu = null;
    for (var k = 0; k < cpuData.length; k++) {
      if (cpuData[k].cpu === i) { cpu = cpuData[k]; break; }
    }

    var dpc = cpu ? (cpu.dpcPct || 0) : 0;
    var intr = cpu ? (cpu.interruptPct || 0) : 0;
    var ips = cpu ? (cpu.intrPerSec || 0) : 0;
    var role = CPU_ROLES[i] || 'Game';

    // Color intensity based on DPC%
    var cellClass = 'heatmap-cell';
    if (dpc > 5) cellClass += ' heatmap-spike';
    else if (dpc > 1) cellClass += ' heatmap-elevated';
    // else default green

    html += '<div class="' + cellClass + '">';
    html += '<div class="heatmap-cpu-label">CPU ' + i + '</div>';
    html += '<div class="heatmap-role">' + role + '</div>';
    html += '<div class="heatmap-dpc">' + dpc.toFixed(2) + '%</div>';
    html += '<div class="heatmap-secondary">';
    html += 'INT ' + intr.toFixed(2) + '% · ' + Math.round(ips) + '/s';
    html += '</div>';
    html += '</div>';
  }

  html += '</div>';
  return html;
}

window.renderCpuHeatmap = renderCpuHeatmap;
```

- [ ] **Step 3: Write dpc-timeline.js**

```javascript
// components/dpc-timeline.js — Chart.js DPC/Interrupt rolling timeline
// Usage: createDpcTimeline(canvasId) → Chart instance
//        updateDpcTimeline(chart, dpcPct, intrPct) → appends point

function createDpcTimeline(canvasId) {
  var canvas = document.getElementById(canvasId);
  if (!canvas || typeof Chart === 'undefined') return null;

  var chart = new Chart(canvas, {
    type: 'line',
    data: {
      labels: [],
      datasets: [
        {
          label: 'DPC %',
          data: [],
          borderColor: '#0891b2',
          backgroundColor: 'rgba(8,145,178,0.1)',
          borderWidth: 2,
          pointRadius: 0,
          tension: 0.3,
          fill: true
        },
        {
          label: 'Interrupt %',
          data: [],
          borderColor: '#60a5fa',
          backgroundColor: 'rgba(96,165,250,0.05)',
          borderWidth: 1.5,
          pointRadius: 0,
          tension: 0.3,
          fill: false
        }
      ]
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      animation: { duration: 300 },
      scales: {
        x: {
          display: true,
          grid: { color: 'rgba(148,163,184,0.1)' },
          ticks: { color: '#64748b', font: { size: 10 }, maxTicksLimit: 6 }
        },
        y: {
          display: true,
          beginAtZero: true,
          grid: { color: 'rgba(148,163,184,0.1)' },
          ticks: {
            color: '#64748b',
            font: { size: 10 },
            callback: function(v) { return v.toFixed(1) + '%'; }
          }
        }
      },
      plugins: {
        legend: {
          position: 'top',
          align: 'end',
          labels: {
            color: '#94a3b8',
            font: { size: 11 },
            boxWidth: 12,
            padding: 16
          }
        }
      },
      interaction: {
        intersect: false,
        mode: 'index'
      }
    }
  });

  return chart;
}

function updateDpcTimeline(chart, dpcPct, intrPct) {
  if (!chart) return;
  var MAX_POINTS = 60;
  var now = new Date();
  var label = now.toLocaleTimeString('en-US', {
    hour12: false, minute: '2-digit', second: '2-digit'
  });

  chart.data.labels.push(label);
  chart.data.datasets[0].data.push(dpcPct);
  chart.data.datasets[1].data.push(intrPct);

  // Rolling window: drop oldest when exceeding max
  if (chart.data.labels.length > MAX_POINTS) {
    chart.data.labels.shift();
    chart.data.datasets[0].data.shift();
    chart.data.datasets[1].data.shift();
  }

  chart.update('none'); // skip animation for streaming
}

window.createDpcTimeline = createDpcTimeline;
window.updateDpcTimeline = updateDpcTimeline;
```

- [ ] **Step 4: Verify all components export globals**

Run: `grep -c "window\\.render" latencyguard/src/components/score-ring.js`
Expected: 1

Run: `grep -c "window\\.render" latencyguard/src/components/cpu-heatmap.js`
Expected: 1

Run: `grep -c "window\\.create" latencyguard/src/components/dpc-timeline.js`
Expected: 1

- [ ] **Step 5: Commit**

```bash
git add latencyguard/src/components/
git commit -m "feat: add reusable components (score-ring, cpu-heatmap, dpc-timeline)"
```

---

### Task 4: Simple Mode View

**Goal:** Implement the 4-step Simple Mode wizard flow matching the v4-refined spec: symptom picker → scan progress → results → fix wizard.

**Files:**
- Create: `latencyguard/src/views/simple.js`

**Acceptance Criteria:**
- [ ] Step 1 (Symptom Picker): 6 symptom cards in 3×2 grid with icon boxes, "Run Full Scan" CTA
- [ ] Step 2 (Scan Progress): centered progress ring (160px), percentage, pipeline step list
- [ ] Step 3 (Results): score ring, severity pills, findings grouped by severity with colored left borders
- [ ] Step 4 (Fix Wizard): step indicator, before/after cards, "What this does" explanation, Apply/Skip buttons
- [ ] All 6 symptoms render: Mouse (⌖ red), Frames (◰ yellow), Network (◎ blue), Audio (♪ green), General (⚡ orange), Full Scan (◉ teal)
- [ ] Network and Audio symptoms show "Coming soon" state (no backend handler yet)
- [ ] Narrative templates preserved from diagnostics.js for finding descriptions
- [ ] Fix application uses existing `invoke('apply_fix', { command })` IPC
- [ ] `window.renderSimpleView` exported for app.js routing

**Verify:** `cargo tauri dev` → Simple mode shows 6 symptom cards → click Mouse → progress ring → results with score ring → click fix → wizard step appears

**Steps:**

- [ ] **Step 1: Create views/simple.js with symptom catalog**

```javascript
// views/simple.js — Simple Mode: 4-step wizard
// Steps: 1=picker, 2=progress, 3=results, 4=wizard

var SYMPTOMS = [
  { key: 'MouseFreezing', label: 'Mouse issues', desc: 'Freezing, stuttering, input gaps',
    icon: '⌖', iconColor: 'var(--red)', iconBg: 'var(--red-dim)', enabled: true },
  { key: 'FrameDrops', label: 'Frame drops', desc: 'Hitches, stutters, low FPS',
    icon: '◰', iconColor: 'var(--yellow)', iconBg: 'var(--yellow-dim)', enabled: true },
  { key: 'NetworkLatency', label: 'Network latency', desc: 'Ping spikes, packet loss',
    icon: '◎', iconColor: 'var(--blue)', iconBg: 'var(--blue-dim)', enabled: false },
  { key: 'AudioGlitches', label: 'Audio glitches', desc: 'Pops, crackles, dropouts',
    icon: '♪', iconColor: 'var(--green)', iconBg: 'var(--green-dim)', enabled: false },
  { key: 'GeneralSluggishness', label: 'General slowness', desc: 'System-wide sluggishness',
    icon: '⚡', iconColor: 'var(--orange)', iconBg: 'rgba(249,115,22,0.15)', enabled: true },
  { key: 'FullAudit', label: 'Full scan', desc: 'Complete system diagnostic',
    icon: '◉', iconColor: 'var(--accent-bright)', iconBg: 'var(--accent-dim)', enabled: true },
];
```

- [ ] **Step 2: Implement renderSimpleView dispatcher**

```javascript
function renderSimpleView(container) {
  if (state.scanning) {
    container.innerHTML = renderScanProgress();
  } else if (state.wizardStep > 0 && state.wizardFindings.length > 0) {
    container.innerHTML = renderFixWizard();
    wireWizardEvents();
  } else if (state.findings) {
    container.innerHTML = renderScanResults();
    wireResultsEvents();
  } else {
    container.innerHTML = renderSymptomPicker();
    wirePickerEvents();
  }
}

window.renderSimpleView = renderSimpleView;
```

- [ ] **Step 3: Implement Step 1 — Symptom Picker**

Renders a centered heading "What's the problem?" with 6 cards in a 3×2 grid. Each card has an icon box (48×48, border-radius 10px), label, and description. Disabled symptoms get 50% opacity and no click handler. Bottom has teal gradient "Run Full Scan" button.

```javascript
function renderSymptomPicker() {
  var html = '<div class="simple-picker">';
  html += '<div class="picker-hero">';
  html += '<h2 class="picker-title">What\'s the problem?</h2>';
  html += '</div>';
  html += '<div class="symptom-grid">';

  SYMPTOMS.forEach(function(s) {
    var cls = 'symptom-card glass';
    if (!s.enabled) cls += ' symptom-disabled';
    html += '<div class="' + cls + '" data-symptom="' + s.key + '">';
    html += '<div class="icon-box" style="background:' + s.iconBg + ';color:' + s.iconColor + '">';
    html += s.icon;
    html += '</div>';
    html += '<div class="symptom-label">' + escHtml(s.label) + '</div>';
    html += '<div class="symptom-desc">' + escHtml(s.desc) + '</div>';
    if (!s.enabled) html += '<div class="symptom-soon">Coming soon</div>';
    html += '</div>';
  });

  html += '</div>';
  html += '<div class="picker-cta">';
  html += '<button class="btn-primary" onclick="startFullScan()">Run Full Scan</button>';
  html += '</div>';
  html += '</div>';
  return html;
}
```

- [ ] **Step 4: Implement Step 2 — Scan Progress**

Renders centered progress ring (160px, teal stroke), percentage inside (monospace 48px), and pipeline step list below with status indicators.

```javascript
function renderScanProgress() {
  var prog = state.diagnosticProgress || {};
  var current = prog.current || 0;
  var total = prog.total || 10;
  var stepName = prog.stepName || 'Initializing…';
  var pct = Math.round((current / total) * 100);
  var circumference = 2 * Math.PI * 70;
  var offset = circumference - (circumference * pct / 100);

  var html = '<div class="scan-progress">';
  html += '<div class="progress-ring">';
  html += '<svg width="160" height="160" viewBox="0 0 160 160">';
  html += '<circle cx="80" cy="80" r="70" fill="none" stroke="var(--bg-surface-strong)" stroke-width="4"/>';
  html += '<circle cx="80" cy="80" r="70" fill="none" stroke="var(--accent-bright)"';
  html += ' stroke-width="4" stroke-linecap="round"';
  html += ' stroke-dasharray="' + circumference.toFixed(1) + '"';
  html += ' stroke-dashoffset="' + offset.toFixed(1) + '"';
  html += ' transform="rotate(-90 80 80)"';
  html += ' style="filter:drop-shadow(0 0 4px rgba(34,211,238,0.3));transition:stroke-dashoffset 0.5s ease"/>';
  html += '</svg>';
  html += '<div class="progress-pct">' + pct + '%</div>';
  html += '</div>';

  html += '<div class="progress-status">' + escHtml(stepName) + '</div>';

  // Pipeline steps
  var steps = ['System Info', 'Registry Audit', 'DPC Analysis', 'Defender Check',
               'Network Config', 'Driver Audit', 'GPU Settings'];
  html += '<div class="progress-steps">';
  steps.forEach(function(name, i) {
    var stepClass = 'progress-step';
    if (i < current) stepClass += ' done';
    else if (i === current) stepClass += ' active';
    html += '<div class="' + stepClass + '">';
    html += '<span class="step-dot"></span>';
    html += '<span>' + name + '</span>';
    html += '</div>';
  });
  html += '</div>';

  html += '<button class="btn-secondary" onclick="cancelScan()" style="margin-top:24px">Cancel</button>';
  html += '</div>';
  return html;
}
```

- [ ] **Step 5: Implement Step 3 — Scan Results**

Score ring at top, summary text, severity pills, findings list grouped by severity (HIGH → MEDIUM → LOW) with colored left borders. Bottom actions: "Fix All", "Export Report", "Scan Again".

```javascript
function renderScanResults() {
  var data = state.findings || {};
  var findings = data.findings || [];
  var summary = data.summary || {};
  var score = summary.score || 0;

  var html = '<div class="results-container">';

  // Header with score ring
  html += '<div class="results-header">';
  html += renderScoreRing(score, 160);
  html += '<div class="results-summary">';
  html += '<h2>' + findings.length + ' optimizations found</h2>';
  html += '<p>' + (summary.pass || 0) + ' of ' + (summary.total || 0) + ' checks pass.</p>';
  html += '<div class="summary-chips">';
  if (summary.high > 0) html += '<span class="summary-chip chip-high">' + summary.high + ' HIGH</span>';
  if (summary.medium > 0) html += '<span class="summary-chip chip-medium">' + summary.medium + ' MEDIUM</span>';
  if (summary.low > 0) html += '<span class="summary-chip chip-low">' + summary.low + ' LOW</span>';
  html += '<span class="summary-chip chip-pass">' + (summary.pass || 0) + ' PASS</span>';
  html += '</div>';
  html += '</div>';
  html += '</div>';

  // Findings grouped by severity
  var groups = { high: [], medium: [], low: [] };
  findings.forEach(function(f) {
    var sev = f.severity || 'low';
    if (groups[sev]) groups[sev].push(f);
    else groups.low.push(f);
  });

  ['high', 'medium', 'low'].forEach(function(sev) {
    if (groups[sev].length === 0) return;
    var label = sev.toUpperCase() + ' PRIORITY';
    html += '<div class="findings-section">';
    html += '<div class="findings-label">' + label + '</div>';
    groups[sev].forEach(function(f, i) {
      html += renderFindingCard(f, sev);
    });
    html += '</div>';
  });

  // Actions
  var fixCount = findings.filter(function(f) { return f.fixType === 'auto' && f.fix; }).length;
  html += '<div class="results-actions">';
  if (fixCount > 0) {
    html += '<button class="btn-primary" onclick="startFixWizard()">Fix All (' + fixCount + ' Issues)</button>';
  }
  html += '<button class="btn-secondary" onclick="exportReport()">Export Report</button>';
  html += '<button class="btn-secondary" onclick="runScan()">Scan Again</button>';
  html += '</div>';

  html += '</div>';
  return html;
}

function renderFindingCard(finding, severity) {
  var html = '<div class="finding-card glass">';
  html += '<div class="finding-severity ' + severity + '"></div>';
  html += '<div class="finding-body">';
  html += '<div class="finding-title">' + escHtml(finding.title) + '</div>';
  html += '<div class="finding-desc">' + escHtml(finding.message || '') + '</div>';
  html += '<div class="finding-meta">';
  if (finding.category) html += '<span class="finding-tag">' + escHtml(finding.category) + '</span>';
  html += '</div>';
  html += '</div>';
  if (finding.fixType === 'auto' && finding.fix) {
    html += '<div class="finding-fix">';
    html += '<button class="btn-fix" onclick="startFixWizard(\'' + escHtml(finding.title) + '\')">Fix</button>';
    html += '</div>';
  }
  html += '</div>';
  return html;
}
```

- [ ] **Step 6: Implement Step 4 — Fix Wizard**

Step indicator ("Fix 1 of 7" with dots), before/after comparison cards, "What this does" text, registry command in code block, Apply/Skip buttons.

```javascript
function renderFixWizard() {
  var fixable = state.wizardFindings;
  var idx = state.wizardStep - 1;
  if (idx < 0 || idx >= fixable.length) {
    // All fixes applied — return to results
    state.wizardStep = 0;
    state.wizardFindings = [];
    return renderScanResults();
  }
  var f = fixable[idx];

  var html = '<div class="wizard">';

  // Header: step indicator + dots
  html += '<div class="wizard-header">';
  html += '<span class="wizard-step-label">Fix ' + (idx + 1) + ' of ' + fixable.length + '</span>';
  html += '<div class="wizard-progress">';
  for (var d = 0; d < fixable.length; d++) {
    var dotCls = 'wizard-dot';
    if (d < idx) dotCls += ' done';
    else if (d === idx) dotCls += ' active';
    html += '<span class="' + dotCls + '"></span>';
  }
  html += '</div>';
  html += '</div>';

  // Title
  html += '<h2 class="wizard-title">' + escHtml(f.title) + '</h2>';

  // Before / After comparison
  html += '<div class="wizard-compare">';
  html += '<div class="wizard-state glass">';
  html += '<div class="wizard-state-label">BEFORE</div>';
  html += '<div class="wizard-state-value" style="color:var(--red)">' + escHtml(f.current || '—') + '</div>';
  html += '</div>';
  html += '<div class="wizard-arrow">→</div>';
  html += '<div class="wizard-state glass">';
  html += '<div class="wizard-state-label">AFTER (PREDICTED)</div>';
  html += '<div class="wizard-state-value" style="color:var(--green)">' + escHtml(f.expected || '—') + '</div>';
  html += '</div>';
  html += '</div>';

  // Explanation
  html += '<div class="wizard-explain">';
  html += '<h4>What this does</h4>';
  html += '<p>' + escHtml(f.message || f.why || 'Applies the recommended system optimization.') + '</p>';
  html += '</div>';

  // Command preview
  if (f.fix) {
    html += '<pre class="wizard-code glass">' + escHtml(f.fix) + '</pre>';
  }

  // Auto-backup notice
  html += '<div class="wizard-backup">';
  html += '<span class="wizard-backup-icon">✓</span>';
  html += 'Auto-backup created. Rollback available via Undo in settings.';
  html += '</div>';

  // Actions
  html += '<div class="wizard-actions">';
  html += '<button class="btn-secondary" onclick="skipFix()">Skip</button>';
  html += '<button class="btn-primary" onclick="applyWizardFix(' + idx + ')">Apply Fix</button>';
  html += '<button class="btn-secondary" onclick="applyAllRemaining()">Apply All Remaining</button>';
  html += '</div>';

  html += '</div>';
  return html;
}
```

- [ ] **Step 7: Wire up event handlers and scan logic**

Add functions: `startFullScan()`, `runScan(symptom)`, `cancelScan()`, `startFixWizard()`, `applyWizardFix(idx)`, `skipFix()`, `applyAllRemaining()`, `backToSymptoms()`. These delegate to existing `invoke()` IPC and manage state transitions.

```javascript
window.startFullScan = function() { runScan('FullAudit'); };

window.runScan = async function(symptom) {
  symptom = symptom || state.activeSymptom || 'FullAudit';
  state.activeSymptom = symptom;
  state.scanning = true;
  state.findings = null;
  state.diagnosticProgress = { current: 0, total: 10, stepName: 'Starting…' };
  render();

  try {
    var result = await invoke('run_diagnostic_chain', { symptom: symptom });
    if (result) {
      state.findings = result;
    }
  } catch (e) {
    showToast('Scan failed: ' + e, 'error');
  }
  state.scanning = false;
  render();
};

window.cancelScan = function() {
  state.scanning = false;
  state.diagnosticProgress = null;
  render();
};

window.startFixWizard = function(title) {
  var findings = (state.findings && state.findings.findings) || [];
  state.wizardFindings = findings.filter(function(f) { return f.fixType === 'auto' && f.fix; });
  if (title) {
    var idx = state.wizardFindings.findIndex(function(f) { return f.title === title; });
    state.wizardStep = idx >= 0 ? idx + 1 : 1;
  } else {
    state.wizardStep = 1;
  }
  render();
};

window.applyWizardFix = async function(idx) {
  var f = state.wizardFindings[idx];
  if (!f || !f.fix) return;
  try {
    await invoke('apply_fix', { command: f.fix });
    showToast('Applied: ' + f.title, 'success');
  } catch (e) {
    showToast('Fix failed: ' + e, 'error');
  }
  state.wizardStep++;
  render();
};

window.skipFix = function() {
  state.wizardStep++;
  render();
};

window.applyAllRemaining = async function() {
  var start = state.wizardStep - 1;
  for (var i = start; i < state.wizardFindings.length; i++) {
    var f = state.wizardFindings[i];
    if (f && f.fix) {
      try { await invoke('apply_fix', { command: f.fix }); }
      catch (e) { showToast('Fix failed: ' + f.title, 'error'); }
    }
  }
  state.wizardStep = 0;
  state.wizardFindings = [];
  showToast('All fixes applied', 'success');
  render();
};

window.backToSymptoms = function() {
  state.findings = null;
  state.activeSymptom = null;
  state.wizardStep = 0;
  state.wizardFindings = [];
  render();
};
```

- [ ] **Step 8: Wire picker click events**

```javascript
function wirePickerEvents() {
  document.querySelectorAll('.symptom-card:not(.symptom-disabled)').forEach(function(card) {
    card.addEventListener('click', function() {
      var symptom = card.dataset.symptom;
      if (symptom) runScan(symptom);
    });
  });
}

function wireResultsEvents() { /* findings list scroll handlers if needed */ }
function wireWizardEvents() { /* keyboard nav for wizard */ }
```

- [ ] **Step 9: Verify simple.js exports renderSimpleView**

Run: `grep -c "window.renderSimpleView" latencyguard/src/views/simple.js`
Expected: 1

- [ ] **Step 10: Commit**

```bash
git add latencyguard/src/views/simple.js
git commit -m "feat: implement Simple Mode 4-step wizard (picker/progress/results/fix)"
```

---

### Task 5: Monitor Mode View

**Goal:** Implement the Monitor Mode real-time dashboard with metric cards, alert banner, CPU DPC heatmap, and Chart.js DPC/Interrupt timeline.

**Files:**
- Create: `latencyguard/src/views/monitor.js`

**Acceptance Criteria:**
- [ ] 5 metric cards across top: DPC %, Interrupt %, CS/sec, Int/sec, Proc Queue
- [ ] Each metric card shows: label (11px uppercase), value (28px monospace bold), status badge
- [ ] Alert banner (yellow at 10% opacity) shows spike description when active
- [ ] CPU DPC heatmap renders 16 cells in 4×4 grid using `renderCpuHeatmap()` component
- [ ] Chart.js DPC/Interrupt timeline renders with 60s rolling window using `createDpcTimeline()`
- [ ] Sub-tab navigation: CPU HEATMAP | TIMELINE | PROCESSES | DRIVERS | NETWORK
- [ ] Tauri event listener subscribed to `perf_update` events for real-time updates
- [ ] Falls back to last pipeline capture data when no live stream active
- [ ] `window.renderMonitorView` exported

**Verify:** `cargo tauri dev` → Monitor mode shows metric cards with pipeline data, heatmap renders 16 cells, Chart.js canvas visible

**Steps:**

- [ ] **Step 1: Create views/monitor.js with metric card rendering**

```javascript
// views/monitor.js — Monitor Mode: real-time dashboard

var monitorChart = null;
var monitorInterval = null;
var monitorSubTab = 'heatmap';

function renderMonitorView(container) {
  var cpuData = [];
  var cpuTotal = {};
  var topo = {};

  // Use live monitor data if available, else fall back to pipeline
  if (state.monitorData) {
    cpuData = state.monitorData.cpuData || [];
    cpuTotal = state.monitorData.cpuTotal || {};
    topo = state.monitorData.interruptTopology || {};
  } else if (state.pipelineData) {
    cpuData = state.pipelineData.cpuData || [];
    cpuTotal = state.pipelineData.cpuTotal || {};
    topo = state.pipelineData.interruptTopology || {};
  }

  var html = '<div class="monitor-dashboard">';

  // Metric cards (5 across)
  html += '<div class="metric-cards">';
  html += metricCard('DPC %', fmtPct(cpuTotal.dpcPct), statusBadge(cpuTotal.dpcPct, 0.3, 1));
  html += metricCard('INTERRUPT %', fmtPct(cpuTotal.interruptPct), statusBadge(cpuTotal.interruptPct, 0.5, 2));
  html += metricCard('CS/SEC', fmtNum(cpuTotal.contextSwitchesPerSec), 'OK');
  html += metricCard('INT/SEC', fmtNum(cpuTotal.interruptsPerSec), 'OK');
  html += metricCard('PROC QUEUE', fmtNum(cpuTotal.processorQueueLength), statusBadge(cpuTotal.processorQueueLength, 1, 4));
  html += '</div>';

  // Alert banner (conditional)
  var spike = detectSpike(cpuData);
  if (spike) {
    html += '<div class="alert-banner">';
    html += '<span class="alert-icon">⚠</span>';
    html += '<span>' + escHtml(spike) + '</span>';
    html += '</div>';
  }

  // Sub-tabs
  html += '<div class="monitor-tabs" role="tablist">';
  ['heatmap', 'timeline', 'processes', 'drivers', 'network'].forEach(function(tab) {
    var on = monitorSubTab === tab;
    html += '<button class="monitor-tab' + (on ? ' active' : '') + '" role="tab"';
    html += ' aria-selected="' + on + '" data-tab="' + tab + '"';
    html += ' onclick="switchMonitorTab(\'' + tab + '\')">';
    html += tab.toUpperCase();
    html += '</button>';
  });
  html += '</div>';

  // Sub-tab content
  if (monitorSubTab === 'heatmap') {
    html += '<div class="monitor-panel glass">';
    html += '<div class="panel-header">';
    html += '<span class="section-label">CPU DPC HEATMAP</span>';
    html += '<span class="panel-timestamp">' + new Date().toLocaleTimeString() + '</span>';
    html += '</div>';
    html += renderCpuHeatmap(cpuData);
    html += '</div>';
  } else if (monitorSubTab === 'timeline') {
    html += '<div class="monitor-panel glass">';
    html += '<div class="panel-header"><span class="section-label">DPC / INTERRUPT TIMELINE</span></div>';
    html += '<div class="chart-container" style="height:280px">';
    html += '<canvas id="dpc-chart"></canvas>';
    html += '</div>';
    html += '</div>';
  } else {
    html += '<div class="monitor-panel glass">';
    html += '<div class="panel-empty">Live ' + monitorSubTab + ' data requires an active capture.</div>';
    html += '</div>';
  }

  html += '</div>';
  container.innerHTML = html;

  // Initialize Chart.js after DOM render
  if (monitorSubTab === 'timeline') {
    monitorChart = createDpcTimeline('dpc-chart');
    // Seed with existing data if available
    if (cpuData.length > 0 && monitorChart) {
      updateDpcTimeline(monitorChart, cpuTotal.dpcPct || 0, cpuTotal.interruptPct || 0);
    }
  }
}

window.renderMonitorView = renderMonitorView;
```

- [ ] **Step 2: Add metric card and helper functions**

```javascript
function metricCard(label, value, badge) {
  var badgeClass = badge === 'OK' ? 'badge-ok' : badge === 'ELEVATED' ? 'badge-warn' : badge === 'HIGH' ? 'badge-high' : 'badge-ok';
  var html = '<div class="metric-card glass">';
  html += '<div class="metric-label">' + label + '</div>';
  html += '<div class="metric-value">' + (value || '—') + '</div>';
  html += '<span class="metric-badge ' + badgeClass + '">' + (badge || 'OK') + '</span>';
  html += '</div>';
  return html;
}

function statusBadge(val, warnThreshold, highThreshold) {
  if (val == null) return 'OK';
  if (val >= highThreshold) return 'HIGH';
  if (val >= warnThreshold) return 'ELEVATED';
  return 'OK';
}

function fmtPct(v) {
  if (v == null) return '—';
  return v.toFixed(3) + '%';
}

function fmtNum(v) {
  if (v == null) return '—';
  if (v >= 1000) return (v / 1000).toFixed(1) + 'K';
  return String(Math.round(v));
}

function detectSpike(cpuData) {
  if (!cpuData || cpuData.length === 0) return null;
  for (var i = 0; i < cpuData.length; i++) {
    var c = cpuData[i];
    if (c.dpcPct > 5) {
      return 'Spike detected: HIGH DPC on CPU ' + c.cpu + ' - ' + c.dpcPct.toFixed(1) + '% (threshold: 5%)';
    }
  }
  return null;
}

window.switchMonitorTab = function(tab) {
  monitorSubTab = tab;
  var app = document.getElementById('app');
  if (app) renderMonitorView(app);
};
```

- [ ] **Step 3: Add Tauri event listener for live streaming**

```javascript
// Subscribe to perf_update events from Rust backend
document.addEventListener('DOMContentLoaded', function() {
  if (window.__TAURI__) {
    window.__TAURI__.event.listen('perf_update', function(event) {
      if (state.mode !== 'monitor') return;
      state.monitorData = event.payload;
      // Update chart without full re-render
      if (monitorChart && event.payload.cpuTotal) {
        updateDpcTimeline(monitorChart,
          event.payload.cpuTotal.dpcPct || 0,
          event.payload.cpuTotal.interruptPct || 0
        );
      }
      // Re-render metric cards and heatmap
      var app = document.getElementById('app');
      if (app && monitorSubTab === 'heatmap') {
        renderMonitorView(app);
      }
    });
  }
});
```

- [ ] **Step 4: Verify monitor.js exports renderMonitorView**

Run: `grep -c "window.renderMonitorView" latencyguard/src/views/monitor.js`
Expected: 1

- [ ] **Step 5: Commit**

```bash
git add latencyguard/src/views/monitor.js
git commit -m "feat: implement Monitor Mode dashboard (metrics, heatmap, timeline)"
```

---

### Task 6: Expert Mode View

**Goal:** Implement the Expert Mode experiment tracker table with tag filtering and data visualization.

**Files:**
- Create: `latencyguard/src/views/expert.js`

**Acceptance Criteria:**
- [ ] Header: "Experiments" + count badge, "+ New Capture" button (teal)
- [ ] Tag filter bar with pill buttons: all, baseline, gaming, post-optimization, network, etc.
- [ ] Active filter: teal background. Inactive: glass surface.
- [ ] Experiment table with columns: NAME, DATE, DPC %, INTERRUPT %, FPS, CPU %, TAGS
- [ ] NAME column uses teal link text
- [ ] Data cells show primary value + delta badge (green positive, red negative)
- [ ] Tags column shows small glass pills
- [ ] Alternating row stripe at `rgba(255,255,255,0.02)`
- [ ] Loads experiments via existing `invoke('get_experiments')` IPC
- [ ] `window.renderExpertView` exported

**Verify:** `cargo tauri dev` → Expert mode shows experiment table with tag filters, data from pipeline captures

**Steps:**

- [ ] **Step 1: Create views/expert.js with data loading**

```javascript
// views/expert.js — Expert Mode: experiment tracker

var expertFilter = 'all';
var expertExperiments = [];

async function renderExpertView(container) {
  // Load experiments if not cached
  if (!state.experiments || state.experiments.length === 0) {
    container.innerHTML = '<div class="expert-loading">Loading experiments…</div>';
    try {
      var exps = await invoke('get_experiments');
      state.experiments = exps || [];
    } catch (e) {
      state.experiments = [];
    }
  }
  expertExperiments = state.experiments;

  var html = '<div class="expert-container">';

  // Header
  html += '<div class="expert-header">';
  html += '<div class="expert-title-row">';
  html += '<h2>Experiments</h2>';
  html += '<span class="expert-count">' + expertExperiments.length + '</span>';
  html += '</div>';
  html += '<button class="btn-primary" onclick="newCapture()">+ New Capture</button>';
  html += '</div>';

  // Tag filter bar
  var tags = extractTags(expertExperiments);
  tags.unshift('all');
  html += '<div class="tag-filter-bar">';
  tags.forEach(function(tag) {
    var on = expertFilter === tag;
    html += '<button class="tag-pill' + (on ? ' active' : '') + '"';
    html += ' onclick="filterExpert(\'' + escHtml(tag) + '\')">' + tag + '</button>';
  });
  html += '</div>';

  // Filter experiments
  var filtered = expertExperiments;
  if (expertFilter !== 'all') {
    filtered = expertExperiments.filter(function(e) {
      var eTags = (e.tags || []).map(function(t) { return t.toLowerCase(); });
      return eTags.indexOf(expertFilter.toLowerCase()) >= 0;
    });
  }

  // Sort by date descending
  filtered.sort(function(a, b) {
    return (b.capturedAt || '').localeCompare(a.capturedAt || '');
  });

  // Table
  if (filtered.length === 0) {
    html += '<div class="expert-empty glass">No experiments match the selected filter.</div>';
  } else {
    html += '<div class="expert-table-wrap">';
    html += '<table class="expert-table">';
    html += '<thead><tr>';
    html += '<th>NAME</th><th>DATE</th><th>DPC %</th><th>INTERRUPT %</th>';
    html += '<th>FPS</th><th>CPU %</th><th>TAGS</th>';
    html += '</tr></thead>';
    html += '<tbody>';

    // Find baseline for delta calculation
    var baseline = expertExperiments.find(function(e) {
      return (e.label || '').toLowerCase().indexOf('baseline') >= 0;
    }) || expertExperiments[0];

    filtered.forEach(function(exp) {
      html += renderExpertRow(exp, baseline);
    });

    html += '</tbody></table>';
    html += '</div>';
  }

  html += '</div>';
  container.innerHTML = html;
}

window.renderExpertView = renderExpertView;
```

- [ ] **Step 2: Implement table row renderer with delta badges**

```javascript
function renderExpertRow(exp, baseline) {
  var label = exp.label || '—';
  var date = (exp.capturedAt || '').substring(0, 10);
  var cpu = exp.cpuTotal || {};
  var baseCpu = (baseline && baseline.cpuTotal) || {};
  var ft = exp.frameTiming || {};

  var dpc = cpu.dpcPct != null ? cpu.dpcPct.toFixed(3) : '—';
  var intr = cpu.interruptPct != null ? cpu.interruptPct.toFixed(3) : '—';
  var fps = ft.fps && ft.fps.avg ? String(Math.round(ft.fps.avg)) : '—';
  var cpuPct = cpu.totalCpuPct != null ? cpu.totalCpuPct.toFixed(1) : '—';

  // Deltas vs baseline
  var dpcDelta = (baseCpu.dpcPct != null && cpu.dpcPct != null)
    ? (cpu.dpcPct - baseCpu.dpcPct) : null;
  var intrDelta = (baseCpu.interruptPct != null && cpu.interruptPct != null)
    ? (cpu.interruptPct - baseCpu.interruptPct) : null;

  var tags = exp.tags || [];
  var tagHtml = tags.map(function(t) {
    return '<span class="exp-tag">' + escHtml(t) + '</span>';
  }).join('');

  var html = '<tr>';
  html += '<td class="exp-name">' + escHtml(label) + '</td>';
  html += '<td class="exp-date">' + date + '</td>';
  html += '<td>' + dpc + deltaBadge(dpcDelta, false) + '</td>';
  html += '<td>' + intr + deltaBadge(intrDelta, false) + '</td>';
  html += '<td>' + fps + '</td>';
  html += '<td>' + cpuPct + '</td>';
  html += '<td class="exp-tags">' + tagHtml + '</td>';
  html += '</tr>';
  return html;
}

function deltaBadge(delta, higherIsBetter) {
  if (delta == null || Math.abs(delta) < 0.001) return '';
  var improved = higherIsBetter ? delta > 0 : delta < 0;
  var cls = improved ? 'delta-good' : 'delta-bad';
  var sign = delta > 0 ? '+' : '';
  return ' <span class="delta-badge ' + cls + '">' + sign + delta.toFixed(3) + '</span>';
}

function extractTags(experiments) {
  var tagSet = {};
  experiments.forEach(function(e) {
    (e.tags || []).forEach(function(t) {
      tagSet[t.toLowerCase()] = true;
    });
  });
  return Object.keys(tagSet).sort();
}

window.filterExpert = function(tag) {
  expertFilter = tag;
  var app = document.getElementById('app');
  if (app) renderExpertView(app);
};

window.newCapture = function() {
  showToast('Start a capture via pipeline.ps1 or the Scan button in Simple mode', 'info');
};
```

- [ ] **Step 3: Verify expert.js exports renderExpertView**

Run: `grep -c "window.renderExpertView" latencyguard/src/views/expert.js`
Expected: 1

- [ ] **Step 4: Commit**

```bash
git add latencyguard/src/views/expert.js
git commit -m "feat: implement Expert Mode experiment tracker with tag filters"
```

---

### Task 7: System Tray Popup & Legacy Cleanup

**Goal:** Implement the system tray popup overlay and remove all legacy view files that have been replaced.

**Files:**
- Create: `latencyguard/src/views/tray.js`
- Remove: `latencyguard/src/views/instrument.js`
- Remove: `latencyguard/src/views/timeline.js`
- Remove: `latencyguard/src/views/command.js`
- Remove: `latencyguard/src/views/diagnostics.js`
- Remove: `latencyguard/src/views/history.js`
- Remove: `latencyguard/src/views/advanced.js`

**Acceptance Criteria:**
- [ ] Tray popup: 300px wide, anchored bottom-right, glass blur(20px) background
- [ ] Shows: LatencyGuard icon + status dot ("Healthy"), DPC % and INT % (monospace 24px), score + uptime
- [ ] Action buttons: Scan, Monitor, Quit (glass pill style)
- [ ] Toggle via `SYSTEM TRAY` link in header or keyboard shortcut
- [ ] All 6 legacy view files deleted
- [ ] `index.html` no longer references legacy scripts
- [ ] App builds and runs with no console errors

**Verify:** `cargo tauri dev` → all three modes work, tray popup opens/closes, no 404s in DevTools Network tab

**Steps:**

- [ ] **Step 1: Create views/tray.js**

```javascript
// views/tray.js — System tray popup overlay

function renderTrayPopup() {
  if (!state.trayVisible) return '';

  var cpuTotal = {};
  if (state.monitorData) cpuTotal = state.monitorData.cpuTotal || {};
  else if (state.pipelineData) cpuTotal = state.pipelineData.cpuTotal || {};

  var score = state.auditData && state.auditData.summary ? state.auditData.summary.score : null;
  var dpc = cpuTotal.dpcPct != null ? cpuTotal.dpcPct.toFixed(3) + '%' : '—';
  var intr = cpuTotal.interruptPct != null ? cpuTotal.interruptPct.toFixed(3) + '%' : '—';

  var statusLabel = 'Healthy';
  var statusColor = 'var(--green)';
  if (state.auditData && state.auditData.summary) {
    var s = state.auditData.summary;
    if (s.fail > 0) { statusLabel = 'Issues found'; statusColor = 'var(--red)'; }
    else if (s.warn > 0) { statusLabel = 'Warnings'; statusColor = 'var(--yellow)'; }
  }

  var html = '<div class="tray-popup">';

  // Header
  html += '<div class="tray-header">';
  html += '<span class="tray-logo-icon"></span>';
  html += '<span class="tray-name">LatencyGuard</span>';
  html += '<span class="tray-status-dot" style="background:' + statusColor + '"></span>';
  html += '<span class="tray-status-label" style="color:' + statusColor + '">' + statusLabel + '</span>';
  html += '</div>';

  // Metrics
  html += '<div class="tray-metrics">';
  html += '<div class="tray-metric">';
  html += '<div class="tray-metric-label">DPC %</div>';
  html += '<div class="tray-metric-value">' + dpc + '</div>';
  html += '</div>';
  html += '<div class="tray-metric">';
  html += '<div class="tray-metric-label">INT %</div>';
  html += '<div class="tray-metric-value">' + intr + '</div>';
  html += '</div>';
  html += '</div>';

  // Score + uptime
  html += '<div class="tray-score-row">';
  if (score != null) {
    var scoreColor = score >= 80 ? 'var(--green)' : score >= 50 ? 'var(--yellow)' : 'var(--red)';
    html += '<span class="tray-score" style="color:' + scoreColor + '">' + score + '</span>';
  }
  html += '</div>';

  // Actions
  html += '<div class="tray-actions">';
  html += '<button class="tray-btn" onclick="setMode(\'simple\');toggleTray()">Scan</button>';
  html += '<button class="tray-btn" onclick="setMode(\'monitor\');toggleTray()">Monitor</button>';
  html += '<button class="tray-btn" onclick="quitApp()">Quit</button>';
  html += '</div>';

  html += '</div>';
  return html;
}

window.toggleTray = function() {
  state.trayVisible = !state.trayVisible;
  var overlay = document.getElementById('tray-overlay');
  if (overlay) overlay.innerHTML = renderTrayPopup();
};

window.quitApp = function() {
  if (window.__TAURI__) {
    window.__TAURI__.process.exit(0);
  }
};

window.renderTrayPopup = renderTrayPopup;
```

- [ ] **Step 2: Delete legacy view files**

```bash
rm latencyguard/src/views/instrument.js
rm latencyguard/src/views/timeline.js
rm latencyguard/src/views/command.js
rm latencyguard/src/views/diagnostics.js
rm latencyguard/src/views/history.js
rm latencyguard/src/views/advanced.js
```

- [ ] **Step 3: Verify no references to deleted files**

Run: `grep -rn "instrument\\.js\|timeline\\.js\|command\\.js\|diagnostics\\.js\|history\\.js\|advanced\\.js" latencyguard/src/index.html`
Expected: 0 matches (these script tags were removed in Task 2)

- [ ] **Step 4: Verify app loads without errors**

Run: `cargo tauri dev` (in `latencyguard/` directory)
Check browser DevTools console: no 404 errors, no undefined function errors.

- [ ] **Step 5: Commit**

```bash
git add -A latencyguard/src/views/
git commit -m "feat: add tray popup, remove legacy view files"
```

---

## Task Dependencies

```
Task 0 (Chart.js) ──┐
                     ├──> Task 3 (Components) ──┐
Task 1 (CSS) ───────┤                          ├──> Task 4 (Simple Mode)
                     ├──> Task 2 (Shell/Router) ┤
                     │                          ├──> Task 5 (Monitor Mode)
                     │                          │
                     │                          └──> Task 6 (Expert Mode)
                     │                                     │
                     └─────────────────────────────────────> Task 7 (Tray + Cleanup)
```

- Task 0 and Task 1 have no dependencies (can run in parallel)
- Task 2 depends on Task 1 (CSS must exist for shell to render)
- Task 3 depends on Task 0 (Chart.js) and Task 1 (CSS)
- Tasks 4, 5, 6 depend on Task 2 (router) and Task 3 (components) — can run in parallel
- Task 7 depends on Tasks 4, 5, 6 (all views must work before removing legacy files)
