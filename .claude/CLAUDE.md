# Windows Latency Optimizer

## Project Overview
Scientific toolkit for measuring, analyzing, and reducing Windows system latency — focused on gaming and real-time input. Each optimization is tracked as a numbered experiment with before/after captures, rollback instructions, and an interactive dashboard.

## System Under Test
- AMD Ryzen 7 9800X3D (8C/16T, 16 logical CPUs)
- NVIDIA RTX 5070 Ti
- Intel I226-V 2.5GbE NIC
- Windows 11 Build 26200
- 32 GB RAM

## Stack
- **Scripts:** PowerShell 5.1 (Windows built-in) — all scripts must be PS 5.1 compatible (145 scripts under `scripts/`)
- **Experiment Dashboard:** `dashboard/` — HTML shell + app.css + app.js with Chart.js (CDN), vanilla JS, file:// compatible. Historical experiment archive.
- **Monitor Dashboard:** `monitor/` — canonical live UI. 8 views (Heatmap, Timeline, Processes, Drivers, Audit, Network, History, Command Center). Reads JSON snapshots from `scripts/monitor_collector.ps1` every 2s. Same file:// constraints as dashboard.
- **Capture Tools:** WPR (built-in), xperf/WPA (Windows ADK), PresentMon (via FrameView), CapFrameX, NVIDIA Nsight Systems
- **Minimal tooling** — npx (via Node.js) for dev server only; no npm install, no pip, no build step

## Key Constraints
- **PowerShell 5.1 only** — no ternary operators (`? :`), no null-coalescing (`??`), no `-StandardDeviation` on `Measure-Object`, no `if/else` inside `@{}` hashtable literals, no `Join-String`
- **No fetch / no modules** — dashboard must be file:// compatible (no fetch API, no ES modules, no pushState, hash routing only). CSS in app.css, JS in app.js, HTML shell in index.html
- **Admin required** — most scripts need elevated privileges for registry + perf counters
- **No hardcoded secrets** — never embed tokens/PATs in scripts or git config

## Project Structure
```
scripts/
  pipeline.ps1                # Main capture: WPR + perf + GPU + xperf + dashboard update
  monitor_collector.ps1       # Live collector — writes monitor/data/{snapshot,history}.js every 2s
  diagnose.ps1                # 3-layer diagnostic dispatcher (symptom keywords -> chain)
  audit.ps1 / audit-checks.ps1 # 41-check audit; dot-sources scripts/audit-checks/*.ps1
  audit-checks/               # 9 category modules: os, gpu, dwm, latency, memory, network, nic, peripheral, _helpers
  rollback.ps1                # Restore from backup (cmdlet allowlist validated)
  startup_guard.ps1           # Verify + auto-fix optimizations at logon
  helpers/                    # Shared modules: logging, capture-core, network, wmi-cache, etc.
  generate_dashboard_data.ps1 # JSON experiments -> experiments_generated.js
  baseline_capture.ps1        # Quick 10s perf + registry snapshot
  analyze_procmon.ps1         # ProcMon CSV parser
  exp*.ps1                    # Individual numbered experiment scripts
captures/
  experiments/                # Pipeline output directories (JSON + reports + rollback)
  backup_pre_*.txt            # Registry backups with embedded rollback commands
  os_baseline_*.txt           # Quick baseline snapshots
monitor/
  index.html                  # Live monitor shell (canonical UI)
  monitor.css / monitor.js    # Core styles + view router
  data/snapshot.js            # Current state (refreshed by collector every 2s)
  data/history.js             # Rolling 60-point history
  views/                      # 8 view modules: heatmap, timeline, processes, drivers, audit, network, history, command-center
  views/command-center.{js,css} # 5-panel expert view (Command Center)
  lib/chart.umd.min.js        # Offline Chart.js fallback
dashboard/
  index.html                  # Experiment archive shell
  app.css / app.js            # Table / detail / compare views
  data/experiments.js         # Hand-curated experiment data (baseline + exp01-07)
  data/experiments_generated.js  # Auto-generated from pipeline JSON
docs/
  case-study.md               # Project narrative (problem -> method -> results)
  findings.md / methodology.md / implementation-plan.md
  tools-glossary.md           # Diagnostic tool reference
  slides/index.html           # Self-contained HTML slide deck
  history/                    # Retired artifacts (Tauri summary, etc.)
  wiki/                       # Research notes + reference docs
tests/
  *.Tests.ps1                 # 12 Pester suites (768 tests)
  dashboard.test.js           # Node assert (47 tests)
config/
  defender_exclusions.txt     # Local Defender exclusion list (gitignored copy)
```

## Scripts Reference

| Script | Purpose | Admin? |
|--------|---------|--------|
| `pipeline.ps1 -Label X -Description Y` | Full capture (WPR + perf + GPU + xperf) | Yes |
| `pipeline.ps1 ... -GameProcess "exe"` | Add PresentMon frame timing | Yes |
| `pipeline.ps1 ... -SkipWPR` | Skip WPR trace (faster) | Yes |
| `run_experiment.ps1 -Label X -Description Y` | Perf counters + registry only | Yes |
| `rollback.ps1 -BackupFile path [-WhatIf]` | Restore registry from backup | Yes |
| `generate_dashboard_data.ps1` | Rebuild experiments_generated.js | No |
| `baseline_capture.ps1 -Label X` | Quick 10s snapshot | Yes |
| `analyze_capframex.ps1 [-Files ...]` | Side-by-side CapFrameX capture comparison | No |
| `capframex_hitches.ps1 -Path X [-HitchThresholdMs Y] [-TopN Z]` | Per-frame hitch table + cluster detection | No |
| `capframex_steady_state.ps1 -Path X [-StartSec Y] [-EndSec Z]` | Trimmed gameplay-window recompute | No |
| `capframex_correlate_sensors.ps1 -Path X [-HitchThresholdMs Y]` | Correlate hitches with GPU/CPU sensor readings | No |

## Data Schema (v3)
Experiments have these fields (all nullable except id/label/date):
- `performance`: perf counter stats `{ DPCTimePct: {avg,min,max}, ... }`
- `cpuData`: per-CPU array `[{ cpu, interruptPct, dpcPct, intrPerSec }]`
- `latencymon`: LatencyMon report data (manual capture)
- `frameTiming`: PresentMon frame time percentiles + FPS (pipeline v3)
- `gpuUtilization`: GPU engine utilization (pipeline v3)
- `dpcIsrAnalysis`: xperf DPC/ISR driver attribution
- `registry`: MMCSS, Defender, GPU, affinity settings

## CPU Topology (9800X3D specific)
- **CPU 0:** Preferred core — keep idle (was 97.7% interrupt share, now 0.5%)
- **CPUs 2-3:** Input devices (keyboard/mouse USB controllers, mask=0x0C)
- **CPUs 4-7:** GPU/NIC/USB bulk DPC work (mask=0xF0)
- **CPUs 8-15:** Free for game threads

## Common PowerShell Pitfalls
1. `"text ($var stuff)"` — PS sees `($var stuff)` as subexpression. Use string concatenation: `'text ' + $var + ' stuff'`
2. `${var}s` or `${var} MB` — use `$var + 's'` concatenation instead
3. `@{ key = if ($x) { 'a' } else { 'b' } }` — pre-compute to a variable first
4. `-like '*pattern[_total]*'` — `[]` are wildcard chars in `-like`. Use `.Contains()` instead
5. `Measure-Object -StandardDeviation` — doesn't exist in PS 5.1, compute manually
6. Always test with: `[Parser]::ParseFile('path', [ref]$null, [ref]$errors); $errors.Count`

## Workflow
1. Run `/plan` before any significant change
2. Test PS scripts parse cleanly before committing
3. Run pipeline with `-SkipWPR -DurationSec 5` for quick smoke tests
4. Open dashboard in browser to verify chart rendering
5. Conventional commits: `feat:`, `fix:`, `exp:`, `chore:`, `docs:`

## Domain Expert Agents

Specialized latency diagnosis and optimization agents. Use `@triage` as entry point — it classifies symptoms and routes to the right specialist.

| Agent | Domain | When to use |
|-------|--------|-------------|
| `@triage` | Router | Any latency complaint — classifies and routes to specialists |
| `@dpc` | DPC/ISR/Input/Audio | Mouse stutter, input gaps, DPC storms, audio warble, CPU 0 saturation |
| `@gpu` | GPU/Frame Timing/Display | Frame drops, hitches, NVIDIA clocks, G-Sync, FSO/MPO/HAGS |
| `@net` | Network | Ping spikes, packet loss, bufferbloat, DNS, I226-V NIC, TCP tuning |
| `@system` | System Health | Full audit, Defender, BIOS, services, registry drift, hardware diag |
| `@capture` | Capture Pipeline | WPR/xperf captures, baseline snapshots, dashboard data, experiment comparison |

### Tool Subagents

Deep CLI reference for specific tools. Domain agents dispatch to these automatically.

| Subagent | Tool | Used by |
|----------|------|---------|
| `@tools/wpr` | Windows Performance Recorder | `@capture`, `@dpc` |
| `@tools/xperf` | xperf / WPA | `@capture`, `@dpc` |
| `@tools/capframex` | CapFrameX frame timing | `@gpu` |
| `@tools/presentmon` | Microsoft PresentMon | `@gpu`, `@capture` |
| `@tools/nvidia-smi` | nvidia-smi GPU queries | `@gpu` |
| `@tools/nsight` | NVIDIA Nsight Systems | `@gpu`, `@dpc` |
| `@tools/procmon` | Sysinternals Process Monitor | `@system`, `@dpc` |
| `@tools/gpuview` | GPUView queue visualization | `@gpu`, `@dpc` |
| `@tools/rtss` | RivaTuner Statistics Server | `@gpu` |
| `@tools/hwinfo` | HWiNFO64 sensor monitoring | `@system` |
| `@tools/scewin` | SCEWIN BIOS modification | `@system` |
| `@tools/pktmon` | Windows packet monitor | `@net` |

### Example Invocations

```
# Mouse stutters in Fortnite → triage routes to @dpc then @gpu
@triage "My mouse stutters in Fortnite"

# Analyze a specific DPC report
@dpc "Analyze DPC attribution in captures/experiments/latest/dpcisr_report.txt"

# Frame timing analysis
@gpu "Compare CapFrameX captures before and after HAGS disable"

# Network baseline
@net "Run 60s ping baseline and check I226-V error counters"

# Full system audit
@system "Run audit.ps1 and health-check.ps1, report findings"

# Capture pipeline
@capture "Run pipeline with -SkipWPR -DurationSec 30 -Label POST_FIX"
```

## General Agents
| Situation | Agent |
|-----------|-------|
| Planning experiments | `planner` (Opus) |
| PowerShell script changes | `code-reviewer` (Sonnet) |
| Dashboard JS/HTML changes | `typescript-reviewer` (Sonnet) |
| Security-sensitive registry ops | `security-reviewer` (Sonnet) |
| Dead code / unused scripts | `refactor-cleaner` (Sonnet) |
| Build/parse errors | `build-error-resolver` (Sonnet) |
