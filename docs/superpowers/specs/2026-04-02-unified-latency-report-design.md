# Unified Latency Report v2 — Design Spec

## Goal

Replace the pass/fail checklist HTML report with an actionable latency diagnostic tool. The report should answer: "Where is my latency, what's causing stutter, and what should I fix?" — not just "are my registry keys correct?"

## Architecture

One HTML report template that adapts based on available data:

| Data Source | Available When | Powers |
|---|---|---|
| Audit checks (33 checks) | Always (`audit.ps1`) | System Health panel, config checklist |
| DPC/ISR histograms | Pipeline run with WPR | DPC Driver Blame panel, alerts |
| PresentMon frame CSV | Pipeline + game detected | Frame time distribution, stutter detection, hero P95 |
| DWM present events from ETL | Pipeline with InputLatency profile | Fallback frame timing, compositor latency |
| ETW provider event counts | Pipeline with InputLatency profile | Advanced tab data |
| History CSV | Accumulates over runs | Score trend sparkline, Compare tab |

**Graceful degradation:** Each panel renders a placeholder when its data is missing. Audit-only runs show checklist + system health. Pipeline runs unlock frame timing, DPC blame, and stutter detection. InputLatency profile runs unlock the Advanced tab.

## Report Structure

### Tab Layout

Three tabs, switchable via inline JS:

1. **Overview** — Hero section + 4 dashboard panels + audit checklist
2. **Advanced** — Raw ETW event counts, per-CPU interrupt breakdown, full DPC histograms
3. **Compare** — Side-by-side of two captures (baseline vs gaming, or before/after)

### Overview Tab

**Hero Section (top):**
- Large P95 input-to-display latency number (e.g., "8.2ms") — color-coded green/amber/red
- Pipeline stage pills below: USB → Kernel → Game → GPU, each with their P95 contribution
- When no pipeline data: falls back to the existing SVG score ring (audit score %)

**Dashboard Panels (2×2 grid):**

1. **Frame Time Distribution** — Histogram of frame times in ms buckets. Color bands: green (<target), amber (target–2× target), red (>2× target). Shows P50, P95, P99 below. Source: PresentMon CSV or DWM present extraction.

2. **Stutter Detection** — Vertical bar sparkline of every frame's time. Outlier frames (>2× rolling median) highlighted in red. Below: count of stutter events, timestamps, and blamed driver if DPC correlation found.

3. **DPC Driver Blame** — Horizontal bars showing top 5 drivers by max DPC latency. Bar width = max microseconds. Color: green <128μs, amber 128-512μs, red >512μs. Shows total DPC count per driver.

4. **System Health** — Compact grid of key metrics: CPU 0 share, total DPC %, total interrupt %, context switches/sec, audit score. Each with green/amber/red status dot.

**Audit Checklist (below panels):**
- Existing expandable check rows, sorted FAIL → WARN → PASS
- Filter buttons: All / Fail / Warn / Pass
- Copy fix button on fix commands

### Advanced Tab

- **ETW Provider Events** — Table: provider name, event count, data status
- **Per-CPU Interrupt Rate** — Table: CPU group, interrupts/sec, interrupt %, DPC %
- **DPC Histogram (per driver)** — Full bucket breakdown for top 5 drivers: ≤1μs, ≤4μs, ≤16μs, ≤64μs, ≤128μs, ≤256μs, ≤512μs, >512μs with counts and percentages
- **Context Switch Summary** — Total/sec, per-CPU distribution

### Compare Tab

- Side-by-side cards: left = baseline (or earlier capture), right = latest (or gaming capture)
- Each card shows: P95 latency, stutter count, DPC max, audit score
- Delta row below: "+6.5ms under load" with color coding
- Data source: history.csv entries. Auto-selects latest two entries by default. If >2 entries exist, renders a `<select>` dropdown for each side to override selection.

## Data Pipeline Changes

### Game Auto-Detection

New function `Find-ForegroundGame` in `pipeline-helpers.ps1`:
- Query `Get-Process` sorted by CPU/WorkingSet, filter against known game exe list
- Known list: FortniteClient-Win64-Shipping, FPSAimTrainer, cs2, VALORANT-Win64-Shipping, r5apex, OverwatchOW, RocketLeague, destiny2, cod
- Also check for any process using >500MB memory with "game", "shipping", or "client" in the name
- Returns process name string or `$null`

### Enhanced Frame Timing

Enhance `Parse-FrameCSV` in `pipeline-helpers.ps1`:
- Add stutter detection: frame time >2× rolling median (window=30 frames) = stutter event
- Add stutter list: array of `@{ frameIndex; frameTimeMs; timestamp; medianMs }` for each stutter
- Add P95, P99 frame time (currently only has avg, p50)
- Add frame time variance (coefficient of variation)

### DWM Present Extraction (fallback frame timing)

New function in `analyze-input-latency.ps1`:
- Extract DxgKrnl present events from xperf dumper output
- Parse timestamps, compute inter-present deltas as frame times
- Return same format as `Parse-FrameCSV` output for unified downstream handling

### DPC-to-Stutter Correlation

New function in `analyze-input-latency.ps1`:
- For each detected stutter frame, find the timestamp window
- Check DPC histogram: did any driver have a high-latency DPC (>128μs) during that window?
- Requires per-event timestamps from xperf dumper (best-effort — falls back to "unknown cause" if timestamps don't correlate)
- Attach blamed driver to each stutter event

### Pipeline Auto-Game Detection

Modify `pipeline.ps1`:
- When `-GameProcess` is not specified, call `Find-ForegroundGame`
- If game found: start PresentMon for that process, log detection
- If no game found: log "no game detected, using DWM fallback"
- Pass frame timing data to report generator

### Unified Report Data Flow

Modify `audit.ps1`:
- After running checks, look for latest `experiment.json` in `captures/experiments/`
- If found and recent (<24h old): load pipeline data (DPC, frame timing, ETW counts)
- Pass as `-PipelineData` hashtable to `New-AuditHtmlReport`
- Report renders panels based on what's present in the hashtable

## Report Generator Architecture

`New-AuditHtmlReport` calls panel builder functions:

```
New-AuditHtmlReport(Summary, Checks, SystemInfo, AuditedAt, Mode, PipelineData, History)
  ├── Build-HeroSection(PipelineData, Summary)
  ├── Build-TabBar()
  ├── Build-FrameDistPanel(PipelineData.frameTiming)
  ├── Build-StutterPanel(PipelineData.frameTiming.stutters)
  ├── Build-DpcBlamePanel(PipelineData.dpcDrivers)
  ├── Build-SystemHealthPanel(Summary, PipelineData)
  ├── Build-AdvancedTab(PipelineData)
  ├── Build-CompareTab(History)
  └── Build-ChecklistSection(Checks)
```

Each function returns HTML string. Missing data = placeholder div.

## Technical Constraints

- PowerShell 5.1: no ternary, no null-coalescing, no Join-String
- HTML fully self-contained: inline CSS + JS, no CDN, no fetch, file:// compatible
- CSS variables: `--bg:#0b1120`, `--surface:#111827`, `--border:#1e3a5f`, `--text:#e2e8f0`, `--green:#10b981`, `--amber:#f59e0b`, `--red:#ef4444`, `--blue:#3b82f6`
- Wrap `Where-Object` in `@()` when using `.Count` on potential single-hashtable results
- Pre-compute variables before using in `@{}` hashtable literals

## Files to Modify

| File | Change | Lines (est) |
|---|---|---|
| `scripts/audit-report.ps1` | Rewrite: panel builder architecture, 3 tabs, adaptive rendering | ~500 |
| `scripts/audit.ps1` | Load latest experiment.json, pass to report as PipelineData | ~30 |
| `scripts/pipeline-helpers.ps1` | Add `Find-ForegroundGame`, enhance `Parse-FrameCSV` stutter detection | ~80 |
| `scripts/analyze-input-latency.ps1` | Add DWM present extraction, DPC-to-stutter correlation | ~100 |
| `scripts/pipeline.ps1` | Auto-detect game when -GameProcess not specified | ~15 |

## Verification

1. `audit.ps1 -Mode Deep` — report shows Overview tab with system health + checklist (no pipeline panels)
2. `pipeline.ps1 -Label TEST -Description "test" -DurationSec 15 -WPRProfile InputLatency` — captures with auto-game detection
3. `audit.ps1 -Mode Deep` after pipeline run — report shows all panels populated from latest experiment
4. Open HTML — tabs switch, filters work, copy-fix works
5. Run pipeline twice — Compare tab shows two entries with deltas
6. All scripts parse with 0 errors
