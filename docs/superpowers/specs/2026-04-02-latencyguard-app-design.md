# LatencyGuard — Desktop App Design Spec

## Goal

Evolve the windows-latency-optimizer CLI toolkit into **LatencyGuard**, a Tauri v2 desktop app that makes gaming latency diagnosis accessible to non-technical users while preserving full depth for experts. One app, two modes: Simple (one-click scan + fix checklist) and Expert (3-tab report + live gameplay monitor + experiment history).

## Architecture

Tauri v2 (Rust backend + WebView2 frontend). The existing PowerShell scripts are the core engine — unchanged. The app is a presentation layer that invokes them and streams their output to the UI.

```
Tauri Window (WebView2)
├── Frontend (HTML/CSS/JS — vanilla, no framework)
│   ├── Simple Mode (score + issue list + fix buttons)
│   └── Expert Mode (Diagnostics / Live Monitor / History / Advanced)
│
├── Tauri IPC (invoke + event system)
│
└── Rust Backend
    ├── PowerShell child process spawner
    ├── Real-time perf counter streamer (500ms interval)
    ├── File system watcher (JSON output)
    └── Admin elevation handler
```

## UI Structure

### Shared Header
- App logo + name (LatencyGuard)
- System info chips (CPU, GPU, RAM — compact)
- **Simple | Expert** toggle (pill-style switch)
- Settings gear icon

### Simple Mode (default on launch)
- **Score ring** — large animated health score (0-100)
- **Summary pills** — "36 optimized" / "1 suggestion" counts
- **Issue list** — each issue shows:
  - Severity icon (warn/fail)
  - Plain-English description of what's wrong
  - "How to fix" or "Apply" button per issue
  - After applying: shows checkmark + "Fixed" state
- **Recently Fixed** section — collapsed, shows last applied fixes
- **Action bar** — "Scan Again" + "View Full Report →"
- **Score trend sparkline** — history from captures/audits/history.csv

### Expert Mode
Four tabs:

**1. Diagnostics** (existing unified report)
- Hero P95 frame time with pipeline stage pills
- 4 dashboard panels (frame distribution, stutter detection, DPC blame, system health)
- Full audit checklist with filters and copy-fix

**2. Live Monitor** (new — real-time during gameplay)
- Capture control bar: Start/Stop button, recording timer, detected game name
- Frame time graph: scrolling bar chart, last 10 seconds, spikes highlighted in red
- DPC activity panel: total DPC %, top driver + max μs, threshold status
- CPU core heatmap: 16-cell grid colored by interrupt load (idle/input/GPU+NIC/game)
- Stutter counter: count + timestamp + blamed driver for each event

**3. History** (existing experiment dashboard)
- Sortable experiment table with tag filtering
- Multi-select for comparison
- Timeline chart

**4. Advanced** (raw data)
- ETW provider event counts
- Per-CPU interrupt/DPC rates table
- Full DPC histogram per driver
- ProcMon analysis (top processes, high-duration ops, Defender activity)

## Tech Stack

| Layer | Choice | Rationale |
|-------|--------|-----------|
| Shell | Tauri v2 | 5MB binary, native WebView2, no Chromium overhead |
| Frontend | Vanilla JS + CSS | Matches existing codebase, no build step, file:// compat for HTML export |
| Charts | Chart.js 4.x (bundled) | Already used, supports streaming updates via `chart.update()` |
| Backend IPC | Tauri event system | Rust emits events at 500ms intervals, frontend subscribes |
| Core engine | PowerShell scripts (unchanged) | audit.ps1, pipeline.ps1, exp*.ps1 — Rust spawns and parses output |
| Live data | `std::process::Command` + stdout streaming | PowerShell perf counters sampled every 500ms, streamed as JSON lines |

## Data Flow

### Scan (Simple Mode)
1. Frontend: `invoke('run_audit', { mode: 'Deep' })`
2. Rust: spawns `powershell -File audit.ps1 -Mode Deep -Quiet`
3. Rust: streams stdout progress lines as Tauri events
4. Frontend: shows progress bar
5. On completion: Rust reads latest `audit_*.json`, sends to frontend
6. Frontend: renders score + issues + fix buttons

### Fix (Simple Mode)
1. User clicks "Apply" on an issue
2. Frontend: `invoke('apply_fix', { command: '...' })`
3. Rust: executes the fix command via PowerShell
4. Rust: returns success/failure
5. Frontend: marks issue as fixed, moves to "Recently Fixed"

### Live Capture (Expert Mode)
1. User clicks "Start Capture" (selects duration)
2. Frontend: `invoke('start_capture', { duration: 30, profile: 'InputLatency' })`
3. Rust: spawns `pipeline.ps1 -WPRProfile InputLatency -DurationSec 30`
4. Simultaneously: Rust starts perf counter streaming (500ms PowerShell samples)
5. Rust: emits `perf_update` events with frame time, DPC %, CPU per-core data
6. Frontend: updates charts in real-time
7. On capture stop: Rust runs `analyze-input-latency.ps1` on the ETL
8. Results populate Diagnostics tab

### History (Expert Mode)
1. Rust: watches `captures/experiments/` directory
2. On change: reads all `experiment.json` files, sends index to frontend
3. Frontend: renders sortable table (existing dashboard logic)

## Project Structure

```
latencyguard/
├── src-tauri/
│   ├── src/
│   │   ├── main.rs              # App entry, window config, plugin setup
│   │   ├── commands.rs          # IPC: run_audit, start_capture, apply_fix, get_history
│   │   ├── powershell.rs        # Spawn PS scripts, stream stdout, parse JSON
│   │   └── perf_stream.rs       # Real-time perf counter → Tauri event emitter
│   ├── Cargo.toml
│   └── tauri.conf.json          # Window: 1200x800, title, admin privileges
├── src/
│   ├── index.html               # App shell
│   ├── app.js                   # Router, state, Tauri __TAURI__ bindings
│   ├── app.css                  # Design system (from existing dashboard)
│   ├── views/
│   │   ├── simple.js            # Score + issues + fix checklist
│   │   ├── diagnostics.js       # Unified report (adapted from audit-report.ps1 HTML)
│   │   ├── live-monitor.js      # Real-time streaming UI
│   │   ├── history.js           # Experiment table (adapted from dashboard)
│   │   └── advanced.js          # Raw data tables
│   └── components/
│       ├── score-ring.js        # SVG animated score circle
│       ├── frame-graph.js       # Chart.js streaming frame time
│       ├── cpu-heatmap.js       # 16-core grid with color intensity
│       └── dpc-bars.js          # Horizontal driver blame bars
├── scripts/                     # PowerShell core engine (symlinked from parent)
└── package.json                 # Tauri CLI dependency only
```

## Key Design Decisions

- **PowerShell scripts stay as-is.** Tauri wraps them. No rewrite of the diagnostic engine.
- **Vanilla JS frontend.** No React/Vue/Svelte. Matches existing codebase. Lower complexity.
- **Chart.js bundled (not CDN).** App must work offline.
- **Admin elevation handled by Tauri.** The app manifest requests admin on launch (required for perf counters and registry writes).
- **HTML export preserved.** Expert → Diagnostics → "Export HTML" button generates the same self-contained HTML report that audit-report.ps1 produces today. Users can share the file without the app.
- **Fix checklist over auto-apply.** Each fix shows a description + Apply button. User has full control. No silent system modifications.

## Scope — What's In vs Out

**In (v1):**
- Simple mode: scan, score, issue list, per-fix Apply buttons
- Expert mode: Diagnostics tab (from existing unified report), Live Monitor (streaming), History (existing dashboard), Advanced (raw data)
- Tauri + Rust backend: PS script runner, perf streamer, file watcher
- Admin elevation
- HTML export

**Out (v1):**
- System tray / background service (add in v2)
- Scheduled scans (add in v2)
- Auto-updates (add in v2)
- Installer/MSI packaging (add in v2 — v1 runs as portable .exe)
- Multi-language support
- Cloud sync / remote monitoring

## Verification

1. `cargo tauri dev` opens the app window
2. Simple mode: Scan button invokes audit.ps1, score renders
3. Expert mode: tabs switch, Diagnostics shows existing report data
4. Live Monitor: Start Capture streams real-time data
5. Fix button applies a registry change and shows "Fixed" state
6. Export HTML produces a valid self-contained report file
