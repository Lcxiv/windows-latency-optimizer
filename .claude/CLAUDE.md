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
- **Scripts:** PowerShell 5.1 (Windows built-in) — all scripts must be PS 5.1 compatible
- **Dashboard:** HTML shell + app.css + app.js with Chart.js (CDN), vanilla JS, file:// compatible
- **Capture Tools:** WPR (built-in), xperf/WPA (Windows ADK), PresentMon (via FrameView)
- **Minimal tooling** — npx (via Node.js) for dev server only; no npm install, no pip, no build step

## Key Constraints
- **PowerShell 5.1 only** — no ternary operators (`? :`), no null-coalescing (`??`), no `-StandardDeviation` on `Measure-Object`, no `if/else` inside `@{}` hashtable literals, no `Join-String`
- **No fetch / no modules** — dashboard must be file:// compatible (no fetch API, no ES modules, no pushState, hash routing only). CSS in app.css, JS in app.js, HTML shell in index.html
- **Admin required** — most scripts need elevated privileges for registry + perf counters
- **No hardcoded secrets** — never embed tokens/PATs in scripts or git config

## Project Structure
```
scripts/
  pipeline.ps1              # Main capture: WPR + perf + GPU + xperf + dashboard update
  run_experiment.ps1         # Simpler perf counter + registry capture
  rollback.ps1               # Restore from backup (cmdlet allowlist validated)
  generate_dashboard_data.ps1 # JSON experiments -> experiments_generated.js
  baseline_capture.ps1       # Quick 10s perf + registry snapshot
  analyze_procmon.ps1        # ProcMon CSV parser
captures/
  experiments/               # Pipeline output directories (JSON + reports)
  backup_pre_*.txt           # Registry backups with embedded rollback commands
  os_baseline_*.txt          # Quick baseline snapshots
dashboard/
  index.html                 # HTML shell (loads app.css + app.js)
  app.css                    # Dashboard styles
  app.js                     # Dashboard logic (table/detail/compare views)
  data/experiments.js        # Hand-curated experiment data (baseline + exp01-07)
  data/experiments_generated.js  # Auto-generated from pipeline JSON
docs/
  findings.md, implementation-plan.md, methodology.md
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

## Recommended Agents
| Situation | Agent |
|-----------|-------|
| Planning experiments | `planner` (Opus) |
| PowerShell script changes | `code-reviewer` (Sonnet) |
| Dashboard JS/HTML changes | `typescript-reviewer` (Sonnet) |
| Security-sensitive registry ops | `security-reviewer` (Sonnet) |
| Dead code / unused scripts | `refactor-cleaner` (Sonnet) |
| Build/parse errors | `build-error-resolver` (Sonnet) |
