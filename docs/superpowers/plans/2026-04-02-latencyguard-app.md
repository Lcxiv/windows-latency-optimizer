# LatencyGuard Tauri App — Implementation Plan

> **For agentic workers:** Use superpowers-extended-cc:executing-plans to implement this plan.

**Spec:** `docs/superpowers/specs/2026-04-02-latencyguard-app-design.md`
**Prerequisite:** Rust toolchain must be installed (`rustup`)
**Branch:** Create new branch `feat/latencyguard-app` from `feat/audit-tool`

---

## Phase Overview

This is a large project. It decomposes into 3 phases, each independently shippable:

- **Phase 1 (Tasks 1-4):** Scaffold + Simple Mode — app opens, runs audit, shows score + fixes
- **Phase 2 (Tasks 5-7):** Expert Mode — Diagnostics + History tabs with existing data
- **Phase 3 (Tasks 8-9):** Live Monitor — real-time streaming during gameplay

Each phase produces a working app. Ship Phase 1 first, iterate.

---

## Task 1: Prerequisites + Tauri Scaffold

**Goal:** Install Rust, scaffold the Tauri v2 project, get a blank window opening.

**Files:**
- Create: `latencyguard/` directory with Tauri scaffold
- Create: `latencyguard/src/index.html` (minimal shell)
- Create: `latencyguard/src-tauri/tauri.conf.json`

**Acceptance Criteria:**
- [ ] `rustc --version` works
- [ ] `cargo tauri dev` opens a window with "LatencyGuard" title
- [ ] Window is 1200x800, dark background
- [ ] Admin elevation requested on launch (UAC prompt)

**Steps:**

- [ ] **Step 1: Install Rust toolchain**
  ```bash
  # Download and run rustup-init.exe
  # Select default installation (stable-x86_64-pc-windows-msvc)
  ```
  This is a user action — Claude cannot install Rust. Provide the command and wait for confirmation.

- [ ] **Step 2: Install Tauri CLI**
  ```bash
  cargo install tauri-cli --version "^2"
  ```

- [ ] **Step 3: Scaffold Tauri project**
  Create `latencyguard/` directory at project root with:
  - `package.json` (minimal — just `@tauri-apps/api` dependency)
  - `src/index.html` (dark-themed shell with header)
  - `src/app.css` (copy design system from `dashboard/app.css`)
  - `src/app.js` (empty router shell)
  - `src-tauri/Cargo.toml` (Tauri v2 dependencies)
  - `src-tauri/tauri.conf.json` (window config, admin elevation)
  - `src-tauri/src/main.rs` (minimal Tauri entry point)

- [ ] **Step 4: Configure admin elevation**
  In `tauri.conf.json`, set `windows.webviewInstallMode` and create a manifest requesting `requireAdministrator`.

- [ ] **Step 5: Verify `cargo tauri dev` opens the window**

**Verify:** `cd latencyguard && cargo tauri dev` — window opens with dark background and header.

```json:metadata
{"files": ["latencyguard/src/index.html", "latencyguard/src/app.css", "latencyguard/src/app.js", "latencyguard/src-tauri/src/main.rs", "latencyguard/src-tauri/Cargo.toml", "latencyguard/src-tauri/tauri.conf.json"], "verifyCommand": "cd latencyguard && cargo tauri dev", "acceptanceCriteria": ["Window opens", "1200x800 dark theme", "Header renders", "Admin elevation works"], "requiresUserVerification": true, "userVerificationPrompt": "Does the LatencyGuard window open with a dark background and header?"}
```

---

## Task 2: Rust Backend — PowerShell Runner

**Goal:** Build the Rust module that spawns PowerShell scripts and streams output.

**Files:**
- Create: `latencyguard/src-tauri/src/powershell.rs`
- Create: `latencyguard/src-tauri/src/commands.rs`
- Modify: `latencyguard/src-tauri/src/main.rs` (register commands)

**Acceptance Criteria:**
- [ ] `invoke('run_audit', { mode: 'Quick' })` spawns `audit.ps1` and returns JSON result
- [ ] Progress events emitted during scan
- [ ] `invoke('apply_fix', { command: '...' })` executes a PowerShell command and returns success/failure
- [ ] Script path resolution finds `../scripts/audit.ps1` relative to app binary

**Steps:**

- [ ] **Step 1: Create `powershell.rs`**
  - `pub fn spawn_script(script: &str, args: &[&str]) -> Result<Child>` — starts PowerShell process
  - `pub fn run_and_capture(script: &str, args: &[&str]) -> Result<String>` — runs to completion, returns stdout
  - `pub fn stream_output(child: Child, app: AppHandle, event: &str)` — reads stdout line by line, emits Tauri events
  - Script path resolution: check `../scripts/` relative to executable, then fallback to `scripts/` in CWD

- [ ] **Step 2: Create `commands.rs`**
  - `#[tauri::command] async fn run_audit(mode: String, app: AppHandle) -> Result<serde_json::Value>`
    - Spawns `audit.ps1 -Mode $mode -Quiet`
    - On completion: finds latest `audit_*.json` in `captures/audits/`, reads and returns it
  - `#[tauri::command] async fn apply_fix(command: String) -> Result<bool>`
    - Runs the PS command via `run_and_capture`
    - Returns true on exit code 0
  - `#[tauri::command] async fn get_system_info() -> Result<serde_json::Value>`
    - Runs `Get-SystemInfo` from audit-checks.ps1 (dot-source + call)

- [ ] **Step 3: Register commands in `main.rs`**
  ```rust
  tauri::Builder::default()
      .invoke_handler(tauri::generate_handler![
          commands::run_audit,
          commands::apply_fix,
          commands::get_system_info,
      ])
  ```

- [ ] **Step 4: Test via browser devtools console**
  Open devtools in the Tauri window, run:
  ```js
  await window.__TAURI__.core.invoke('get_system_info')
  ```

**Verify:** Devtools console returns system info JSON from PowerShell.

```json:metadata
{"files": ["latencyguard/src-tauri/src/powershell.rs", "latencyguard/src-tauri/src/commands.rs", "latencyguard/src-tauri/src/main.rs"], "verifyCommand": "cd latencyguard && cargo tauri dev", "acceptanceCriteria": ["run_audit spawns audit.ps1", "apply_fix executes PS command", "get_system_info returns JSON", "No panics on error paths"]}
```

---

## Task 3: Frontend — Simple Mode

**Goal:** Build the Simple Mode UI: score ring, issue list, fix buttons.

**Files:**
- Create: `latencyguard/src/views/simple.js`
- Create: `latencyguard/src/components/score-ring.js`
- Modify: `latencyguard/src/app.js` (router + state)
- Modify: `latencyguard/src/app.css` (Simple Mode styles)
- Modify: `latencyguard/src/index.html` (load scripts)

**Acceptance Criteria:**
- [ ] Score ring animates from 0 to audit score on scan completion
- [ ] Issue list shows all WARN/FAIL checks with plain-English descriptions
- [ ] "Apply" button on each fix calls `invoke('apply_fix')` and shows "Fixed" state
- [ ] "Scan Again" button triggers new audit
- [ ] Score trend sparkline renders from history.csv data
- [ ] Simple/Expert toggle visible in header (Expert is placeholder)

**Steps:**

- [ ] **Step 1: Build `app.js` router**
  - State: `{ mode: 'simple', auditData: null, scanning: false }`
  - On load: call `invoke('get_system_info')` for header chips
  - Mode toggle: swaps between `renderSimple()` and `renderExpert()`

- [ ] **Step 2: Build `score-ring.js`**
  - SVG circle with `stroke-dasharray` animation
  - `animateScore(target)` — tweens from 0 to target over 1s
  - Color: green ≥80, amber ≥50, red <50

- [ ] **Step 3: Build `simple.js`**
  - `renderSimple(auditData)` — builds the full Simple Mode DOM
  - Issue list: filter checks where status !== 'PASS', sort FAIL first
  - Each issue: icon + description + Apply button (or "How to fix" for manual fixes)
  - Recently Fixed section: collapsed by default, expands on click
  - Action bar: Scan Again + View Full Report

- [ ] **Step 4: Wire up Scan button**
  - On click: set `scanning = true`, show progress bar
  - Call `invoke('run_audit', { mode: 'Deep' })`
  - Listen for progress events to update bar
  - On completion: store auditData, call `renderSimple()`

- [ ] **Step 5: Wire up Fix buttons**
  - On click: call `invoke('apply_fix', { command: check.fix })`
  - On success: move issue to "Recently Fixed", update score

- [ ] **Step 6: Add sparkline from history**

**Verify:** Open app, click Scan, see score animate, click a fix, see it move to "Fixed".

```json:metadata
{"files": ["latencyguard/src/views/simple.js", "latencyguard/src/components/score-ring.js", "latencyguard/src/app.js", "latencyguard/src/app.css", "latencyguard/src/index.html"], "verifyCommand": "cd latencyguard && cargo tauri dev", "acceptanceCriteria": ["Score ring animates", "Issue list renders", "Fix buttons work", "Scan triggers audit.ps1", "Sparkline shows history"], "requiresUserVerification": true, "userVerificationPrompt": "Click Scan in the app. Does the score animate and issues appear? Try clicking a Fix button."}
```

---

## Task 4: Phase 1 Polish + Commit

**Goal:** Polish Simple Mode, handle errors, commit Phase 1.

**Files:** All Phase 1 files

**Steps:**
- [ ] Error handling: show toast on PS script failure
- [ ] Loading states: skeleton UI during scan
- [ ] Empty state: "No scan yet — click Scan to start"
- [ ] Verify on a clean boot (no prior audit data)
- [ ] Commit Phase 1

```json:metadata
{"files": [], "acceptanceCriteria": ["App works on first launch with no prior data", "Errors shown as toast not crash", "All Phase 1 features working"]}
```

---

## Task 5: Expert Mode — Diagnostics Tab

**Goal:** Port the unified report HTML into the Diagnostics tab.

**Files:**
- Create: `latencyguard/src/views/diagnostics.js`
- Create: `latencyguard/src/components/dpc-bars.js`
- Modify: `latencyguard/src-tauri/src/commands.rs` (add `get_pipeline_data`)

**Acceptance Criteria:**
- [ ] Diagnostics tab shows hero P95 (or score ring fallback)
- [ ] 4 dashboard panels render (frame dist, stutter, DPC blame, system health)
- [ ] Audit checklist with filter buttons and copy-fix
- [ ] "Export HTML" button generates self-contained report file

**Steps:**
- [ ] **Step 1:** Add Rust command `get_pipeline_data` — reads latest experiment.json + input_latency_analysis.json
- [ ] **Step 2:** Port `Build-HeroSection`, `Build-FrameDistPanel`, `Build-DpcBlamePanel`, `Build-StutterPanel`, `Build-SystemHealthPanel` from PowerShell string concat to JS DOM manipulation
- [ ] **Step 3:** Port `Build-ChecklistSection` (filter buttons, expandable rows, copy-fix)
- [ ] **Step 4:** Add "Export HTML" — calls `invoke('run_audit')` with HTML output, saves via Tauri file dialog
- [ ] **Step 5:** Wire Expert toggle to switch between Simple and Diagnostics

```json:metadata
{"files": ["latencyguard/src/views/diagnostics.js", "latencyguard/src/components/dpc-bars.js", "latencyguard/src-tauri/src/commands.rs"], "acceptanceCriteria": ["Diagnostics tab renders all panels", "Filter buttons work", "Export HTML saves valid file"]}
```

---

## Task 6: Expert Mode — History Tab

**Goal:** Port the existing experiment dashboard into the History tab.

**Files:**
- Create: `latencyguard/src/views/history.js`
- Modify: `latencyguard/src-tauri/src/commands.rs` (add `get_experiments`)

**Acceptance Criteria:**
- [ ] Sortable experiment table with all columns
- [ ] Tag filtering
- [ ] Click row → detail view with charts
- [ ] Multi-select → compare view

**Steps:**
- [ ] **Step 1:** Add Rust command `get_experiments` — scans `captures/experiments/`, reads all experiment.json, returns array
- [ ] **Step 2:** Port `table.js` view logic to `history.js`
- [ ] **Step 3:** Port `detail.js` view (Chart.js integration)
- [ ] **Step 4:** Port `compare.js` view
- [ ] **Step 5:** Bundle Chart.js locally (copy from CDN to `src/lib/chart.min.js`)

```json:metadata
{"files": ["latencyguard/src/views/history.js", "latencyguard/src/lib/chart.min.js"], "acceptanceCriteria": ["Experiment table renders", "Sorting works", "Detail view shows charts", "Compare view works"]}
```

---

## Task 7: Expert Mode — Advanced Tab

**Goal:** Build the raw data tab with ETW counts, per-CPU table, DPC histograms, ProcMon data.

**Files:**
- Create: `latencyguard/src/views/advanced.js`

**Steps:**
- [ ] **Step 1:** Port `Build-AdvancedTab` logic from audit-report.ps1 to JS
- [ ] **Step 2:** Add ProcMon process table + high-duration ops
- [ ] **Step 3:** Add Defender analysis section (if defenderAnalysis exists in experiment.json)

```json:metadata
{"files": ["latencyguard/src/views/advanced.js"], "acceptanceCriteria": ["ETW provider table renders", "Per-CPU table renders", "DPC histogram renders", "ProcMon data shows when available"]}
```

---

## Task 8: Live Monitor — Perf Streaming Backend

**Goal:** Build the Rust module that streams real-time perf counters to the frontend.

**Files:**
- Create: `latencyguard/src-tauri/src/perf_stream.rs`
- Modify: `latencyguard/src-tauri/src/commands.rs` (add `start_capture`, `stop_capture`)

**Acceptance Criteria:**
- [ ] `start_capture` spawns pipeline.ps1 and starts perf counter streaming
- [ ] `perf_update` events emitted every 500ms with: CPU per-core %, DPC %, interrupt %, context switches
- [ ] `stop_capture` terminates the pipeline and runs analysis
- [ ] Game auto-detection result included in events

**Steps:**
- [ ] **Step 1:** Create `perf_stream.rs`
  - Spawns a PowerShell process that samples perf counters in a loop (500ms interval)
  - Output format: one JSON line per sample
  - Thread reads stdout, emits Tauri `perf_update` event per line
- [ ] **Step 2:** Add `start_capture` command — spawns pipeline.ps1 + perf streamer concurrently
- [ ] **Step 3:** Add `stop_capture` command — kills pipeline, runs analyze-input-latency.ps1
- [ ] **Step 4:** Test: start capture, verify devtools receives perf_update events

```json:metadata
{"files": ["latencyguard/src-tauri/src/perf_stream.rs", "latencyguard/src-tauri/src/commands.rs"], "acceptanceCriteria": ["perf_update events every 500ms", "CPU per-core data present", "Pipeline spawns correctly", "Stop + analyze works"]}
```

---

## Task 9: Live Monitor — Frontend

**Goal:** Build the Live Monitor tab with real-time streaming charts.

**Files:**
- Create: `latencyguard/src/views/live-monitor.js`
- Create: `latencyguard/src/components/frame-graph.js`
- Create: `latencyguard/src/components/cpu-heatmap.js`

**Acceptance Criteria:**
- [ ] Start/Stop capture buttons work
- [ ] Frame time graph scrolls with incoming data, spikes highlighted red
- [ ] DPC activity panel updates in real-time
- [ ] CPU heatmap colors by interrupt load per core
- [ ] Stutter counter increments when frame spike detected
- [ ] Capture timer shows elapsed/total
- [ ] Game auto-detection shown in capture bar

**Steps:**
- [ ] **Step 1:** Build `frame-graph.js` — Chart.js line chart with `chart.data.datasets[0].data.push()` + `chart.update('none')` for streaming. Ring buffer of 600 samples (10s at 500ms, or 10s of frame data).
- [ ] **Step 2:** Build `cpu-heatmap.js` — 16-cell grid, colors update on each `perf_update` event
- [ ] **Step 3:** Build `live-monitor.js` — layout with capture bar + grid of panels
- [ ] **Step 4:** Wire up Start/Stop buttons to Rust commands
- [ ] **Step 5:** Subscribe to `perf_update` events, distribute to graph + heatmap + DPC panel
- [ ] **Step 6:** Stutter detection: track rolling median of frame times, flag spikes >2x
- [ ] **Step 7:** On capture stop: switch to Diagnostics tab with fresh results

```json:metadata
{"files": ["latencyguard/src/views/live-monitor.js", "latencyguard/src/components/frame-graph.js", "latencyguard/src/components/cpu-heatmap.js"], "acceptanceCriteria": ["Frame graph streams smoothly", "CPU heatmap updates", "DPC panel updates", "Start/Stop works", "Stutter counter functional"], "requiresUserVerification": true, "userVerificationPrompt": "Start a capture in Expert → Live Monitor. Does the frame graph stream? Do the panels update in real-time?"}
```

---

## Dependency Order

```
Phase 1 (shippable):
  Task 1 (scaffold) → Task 2 (Rust backend) → Task 3 (Simple Mode) → Task 4 (polish)

Phase 2 (shippable):
  Task 5 (Diagnostics) ─┐
  Task 6 (History)      ─┼→ Phase 2 commit
  Task 7 (Advanced)     ─┘

Phase 3 (shippable):
  Task 8 (Perf streaming backend) → Task 9 (Live Monitor frontend)
```

## Blocker: Rust Installation

Task 1 requires Rust. Run `winget install Rustlang.Rustup` or download from https://rustup.rs. This is a user action — confirm installation before proceeding.
