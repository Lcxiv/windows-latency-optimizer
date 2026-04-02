# Unified Latency Report v2 — Implementation Plan

> **For agentic workers:** Use superpowers-extended-cc:executing-plans to implement this plan task-by-task.

**Spec:** `docs/superpowers/specs/2026-04-02-unified-latency-report-design.md`
**Branch:** `feat/audit-tool` (continue existing branch)

---

## Task 1: Pipeline Data Helpers — Game Detection + Enhanced Frame Parsing

**Goal:** Add `Find-ForegroundGame` and enhance `Parse-FrameCSV` with stutter detection and P95/P99.

**Files:**
- Modify: `scripts/pipeline-helpers.ps1`

**Acceptance Criteria:**
- [ ] `Find-ForegroundGame` returns process name or `$null`
- [ ] `Parse-FrameCSV` output includes: `stutters` array, `p95`, `p99`, `variance`
- [ ] Parser: 0 errors

**Verify:** `powershell -ExecutionPolicy Bypass -Command "[System.Management.Automation.Language.Parser]::ParseFile('scripts\pipeline-helpers.ps1',[ref]$null,[ref]$e);$e.Count"` → `0`

**Steps:**

- [ ] **Step 1: Add `Find-ForegroundGame` function** (insert before `Invoke-PresentMonCapture` at ~line 262)

```powershell
function Find-ForegroundGame {
    # Known game process names (without .exe)
    $knownGames = @(
        'FortniteClient-Win64-Shipping', 'FPSAimTrainer', 'cs2',
        'VALORANT-Win64-Shipping', 'r5apex', 'OverwatchOW',
        'RocketLeague', 'PUBG-Win64-Shipping', 'destiny2', 'cod'
    )
    # Check for known games first
    foreach ($name in $knownGames) {
        $proc = Get-Process -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $proc) {
            Log ('Game detected: ' + $proc.ProcessName + ' (PID ' + $proc.Id + ', ' + [math]::Round($proc.WorkingSet64/1MB) + ' MB)') 'PASS'
            return $proc.ProcessName
        }
    }
    # Fallback: any process using >500MB with game-like name
    $procs = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.WorkingSet64 -gt 500MB } |
        Where-Object { $_.ProcessName -match 'game|shipping|client|unreal|unity' } |
        Sort-Object WorkingSet64 -Descending |
        Select-Object -First 1
    if ($null -ne $procs) {
        Log ('Possible game detected: ' + $procs.ProcessName + ' (' + [math]::Round($procs.WorkingSet64/1MB) + ' MB)') 'INFO'
        return $procs.ProcessName
    }
    return $null
}
```

- [ ] **Step 2: Enhance `Parse-FrameCSV`** (modify existing function at lines 37-95)

After the existing percentile calculations (line ~65), add:
- P95 calculation: `$sorted[[math]::Floor($sorted.Count * 0.95)]`
- P99 calculation: `$sorted[[math]::Floor($sorted.Count * 0.99)]`
- Variance (coefficient of variation): `$stdev / $avg * 100` (using existing stdev if computed, or manual)
- Stutter detection loop: iterate frames, compute rolling median (window=30), flag frames >2× median
- Add `stutters` array to return hashtable: `@{ frameIndex; frameTimeMs; medianMs }`
- Add `stutterCount` to return hashtable

- [ ] **Step 3: Parse-validate**

```json:metadata
{"files": ["scripts/pipeline-helpers.ps1"], "verifyCommand": "powershell -ExecutionPolicy Bypass -Command \"[System.Management.Automation.Language.Parser]::ParseFile('scripts\\pipeline-helpers.ps1',[ref]$null,[ref]$e);$e.Count\"", "acceptanceCriteria": ["Find-ForegroundGame returns process name or null", "Parse-FrameCSV includes stutters array and p95/p99", "0 parse errors"]}
```

---

## Task 2: Pipeline Auto-Game Detection

**Goal:** When `-GameProcess` is not specified, auto-detect running game.

**Files:**
- Modify: `scripts/pipeline.ps1` (around line 74)

**Acceptance Criteria:**
- [ ] Pipeline auto-detects game when `-GameProcess` is empty
- [ ] Falls back gracefully when no game found
- [ ] Parser: 0 errors

**Verify:** `powershell -ExecutionPolicy Bypass -Command "[System.Management.Automation.Language.Parser]::ParseFile('scripts\pipeline.ps1',[ref]$null,[ref]$e);$e.Count"` → `0`

**Steps:**

- [ ] **Step 1: Add auto-detection before PresentMon call** (before line 74)

Insert before the `Invoke-PresentMonCapture` call:
```powershell
# Auto-detect game if not specified
if ($GameProcess -eq '' -and -not $SkipPresentMon) {
    $detectedGame = Find-ForegroundGame
    if ($null -ne $detectedGame) {
        $GameProcess = $detectedGame
    } else {
        Log 'No game detected — PresentMon frame capture skipped (DWM fallback available)' 'INFO'
    }
}
```

- [ ] **Step 2: Parse-validate**

```json:metadata
{"files": ["scripts/pipeline.ps1"], "verifyCommand": "powershell -ExecutionPolicy Bypass -Command \"[System.Management.Automation.Language.Parser]::ParseFile('scripts\\pipeline.ps1',[ref]$null,[ref]$e);$e.Count\"", "acceptanceCriteria": ["Auto-detects game when GameProcess empty", "Graceful fallback when no game", "0 parse errors"]}
```

---

## Task 3: DWM Present Extraction + DPC-Stutter Correlation

**Goal:** Extract DWM frame timing from ETL as fallback, correlate DPC spikes with stutter events.

**Files:**
- Modify: `scripts/analyze-input-latency.ps1`

**Acceptance Criteria:**
- [ ] `Extract-DwmFrameTiming` returns frame time array from DxgKrnl events
- [ ] `Correlate-DpcStutters` matches stutter frames to high-latency DPC drivers
- [ ] Output includes `frameTiming` and `stutterCorrelation` in result hashtable
- [ ] Parser: 0 errors

**Verify:** `powershell -ExecutionPolicy Bypass -File scripts/analyze-input-latency.ps1 -EtlFile "captures\experiments\20260402_131351_EXP13_INPUT_LATENCY\trace.etl"` — should show frame timing extraction

**Steps:**

- [ ] **Step 1: Add `Extract-DwmFrameTiming` function** (insert before the provider extraction section at ~line 130)

Approach: Parse the `events_DxgKrnl_GPU.txt` dumper output for Present/Flip events, extract timestamps, compute inter-present deltas as frame times. Return same schema as `Parse-FrameCSV` for unified handling.

- [ ] **Step 2: Add `Correlate-DpcStutters` function**

For each stutter frame (from frame timing), check the DPC histogram dump for high-latency DPCs (>128μs) in the same time window. Best-effort: use the per-module histogram data to estimate which driver likely caused the stutter. Return array of `@{ frameIndex; frameTimeMs; blamedDriver; dpcLatencyUs }`.

- [ ] **Step 3: Integrate into main analysis flow**

After the existing provider extraction (line ~161), call `Extract-DwmFrameTiming` if no PresentMon CSV exists. Call `Correlate-DpcStutters` if stutters were detected. Add both to the result hashtable:
```powershell
$result['frameTiming'] = $dwmFrameTiming  # or PresentMon data
$result['stutterCorrelation'] = $correlations
```

- [ ] **Step 4: Parse-validate and test**

```json:metadata
{"files": ["scripts/analyze-input-latency.ps1"], "verifyCommand": "powershell -ExecutionPolicy Bypass -File scripts/analyze-input-latency.ps1 -EtlFile \"captures\\experiments\\20260402_131351_EXP13_INPUT_LATENCY\\trace.etl\"", "acceptanceCriteria": ["DWM frame timing extracted from ETL", "Stutter-DPC correlation attempted", "Result includes frameTiming and stutterCorrelation", "0 parse errors"]}
```

---

## Task 4: Audit.ps1 — Load Pipeline Data for Report

**Goal:** After running checks, load latest experiment.json and pass pipeline data to the report generator.

**Files:**
- Modify: `scripts/audit.ps1` (between check aggregation and HTML write, ~lines 100-136)

**Acceptance Criteria:**
- [ ] Loads latest experiment.json from captures/experiments/
- [ ] Only uses data <24h old
- [ ] Passes `-PipelineData` hashtable to `New-AuditHtmlReport`
- [ ] Report still works when no pipeline data exists
- [ ] Parser: 0 errors

**Verify:** `powershell -ExecutionPolicy Bypass -File scripts/audit.ps1 -Mode Deep` — report opens with pipeline panels populated

**Steps:**

- [ ] **Step 1: Add pipeline data loading** (insert before the `# --- Write HTML ---` section at ~line 132)

```powershell
# --- Load latest pipeline data for report ---
$pipelineData = $null
$expRoot = Join-Path $projectRoot 'captures\experiments'
if (Test-Path $expRoot) {
    $expDirs = @(Get-ChildItem $expRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($expDirs.Count -gt 0) {
        $latestJson = Join-Path $expDirs[0].FullName 'experiment.json'
        if (Test-Path $latestJson) {
            $expAge = (Get-Date) - (Get-Item $latestJson).LastWriteTime
            if ($expAge.TotalHours -lt 24) {
                try {
                    $expData = Get-Content $latestJson -Raw | ConvertFrom-Json -ErrorAction Stop
                    $pipelineData = @{
                        label             = $expData.label
                        capturedAt        = $expData.capturedAt
                        dpcIsrAnalysis    = $expData.dpcIsrAnalysis
                        frameTiming       = $expData.frameTiming
                        cpuData           = $expData.cpuData
                        cpuTotal          = $expData.cpuTotal
                        interruptTopology = $expData.interruptTopology
                        gpuUtilization    = $expData.gpuUtilization
                    }
                    # Also load input latency analysis if present
                    $inputJson = Join-Path $expDirs[0].FullName 'input_latency_analysis.json'
                    if (Test-Path $inputJson) {
                        $inputData = Get-Content $inputJson -Raw | ConvertFrom-Json -ErrorAction Stop
                        $pipelineData['inputLatency'] = $inputData
                    }
                    if (-not $Quiet) { Log ('Loaded pipeline data from ' + $expDirs[0].Name) 'INFO' }
                } catch {}
            }
        }
    }
}
```

- [ ] **Step 2: Update `New-AuditHtmlReport` call** (modify line 134)

Change from:
```powershell
$html = New-AuditHtmlReport -Summary $summary -Checks $allChecks -SystemInfo $sysInfo -AuditedAt $auditedAt -Mode $Mode -History $historyData
```
To:
```powershell
$html = New-AuditHtmlReport -Summary $summary -Checks $allChecks -SystemInfo $sysInfo -AuditedAt $auditedAt -Mode $Mode -History $historyData -PipelineData $pipelineData
```

- [ ] **Step 3: Parse-validate and test**

```json:metadata
{"files": ["scripts/audit.ps1"], "verifyCommand": "powershell -ExecutionPolicy Bypass -File scripts/audit.ps1 -Mode Deep", "acceptanceCriteria": ["Loads latest experiment.json", "Skips data older than 24h", "Passes PipelineData to report", "Still works with no pipeline data", "0 parse errors"]}
```

---

## Task 5: Report Rewrite — Panel Builder Architecture

**Goal:** Rewrite `audit-report.ps1` with the new tabbed layout: Overview (hero + 4 panels + checklist), Advanced, Compare.

**Files:**
- Rewrite: `scripts/audit-report.ps1`

**Acceptance Criteria:**
- [ ] `New-AuditHtmlReport` accepts `-PipelineData` parameter
- [ ] Overview tab: hero P95 (or score ring fallback), frame distribution, stutter detection, DPC blame, system health, checklist
- [ ] Advanced tab: ETW event counts, per-CPU interrupt rates, full DPC histograms
- [ ] Compare tab: side-by-side of latest two history entries with deltas
- [ ] All panels show placeholders when data is missing
- [ ] Tab switching, filter buttons, copy-fix all work
- [ ] Fully self-contained HTML (inline CSS+JS, no CDN)
- [ ] Parser: 0 errors

**Verify:** Open generated HTML in browser. Test: (1) tabs switch, (2) filter buttons work, (3) copy fix works, (4) panels show data or placeholders.

**Steps:**

- [ ] **Step 1: Rewrite function signature and helpers**

Add `-PipelineData` parameter (hashtable, default `$null`). Keep existing helpers (`Get-StatusColor`, `Get-ScoreColor`, `Esc`). Add new helpers:
- `Build-Placeholder($title, $message)` — returns placeholder div HTML
- `Get-BarColor($valueUs)` — returns green/amber/red based on microsecond thresholds

- [ ] **Step 2: Build CSS**

Reuse existing CSS variables. Add new classes:
- `.tab-bar`, `.tab-btn`, `.tab-btn.active` — tab navigation
- `.hero` — large centered P95 number
- `.stage-pills` — horizontal flow of pipeline stage badges
- `.panel` — dashboard panel container
- `.panel-grid` — 2×2 grid layout
- `.bar-chart` — horizontal bar container
- `.histogram` — vertical bar histogram
- `.placeholder-panel` — "no data" state

- [ ] **Step 3: Build JavaScript**

Inline `<script>` with:
- `switchTab(name)` — shows/hides tab content divs
- `filterRows(status)` — existing filter logic (keep from current)
- `copyFix(btn)` — existing copy logic (keep from current)
- `toggleDetail(id)` — existing expand/collapse (keep from current)

- [ ] **Step 4: Build Hero Section**

```powershell
function Build-HeroSection {
    param($PipelineData, $Summary)
    # If PipelineData has frameTiming with p95:
    #   Big P95 number + pipeline stage pills
    # Else:
    #   SVG score ring (existing) with audit score
}
```

- [ ] **Step 5: Build Frame Distribution Panel**

```powershell
function Build-FrameDistPanel {
    param($FrameTiming)
    # If null: return placeholder
    # Build histogram: bucket frame times into 2ms ranges
    # Color: green < 8ms, amber 8-16ms, red > 16ms
    # Show P50, P95, P99 summary below
}
```

- [ ] **Step 6: Build Stutter Detection Panel**

```powershell
function Build-StutterPanel {
    param($FrameTiming)
    # If null: return placeholder
    # Build vertical bar sparkline (one bar per frame, height = frame time)
    # Stutter frames (>2× median) in red
    # Show count + blamed driver if correlation exists
}
```

- [ ] **Step 7: Build DPC Blame Panel**

```powershell
function Build-DpcBlamePanel {
    param($DpcDrivers)
    # If null: return placeholder
    # Horizontal bars for top 5 drivers by MaxUs
    # Color: green <128μs, amber 128-512μs, red >512μs
    # Show count and max for each
}
```

- [ ] **Step 8: Build System Health Panel**

```powershell
function Build-SystemHealthPanel {
    param($Summary, $PipelineData)
    # Always rendered (uses audit data)
    # Grid: CPU0 share, total DPC%, total interrupt%, ctx switch/s, audit score
    # Each with green/amber/red dot
    # If no PipelineData: show only audit score
}
```

- [ ] **Step 9: Build Advanced Tab**

```powershell
function Build-AdvancedTab {
    param($PipelineData)
    # If null: return placeholder
    # ETW provider events table
    # Per-CPU interrupt rate table (from cpuData)
    # Full DPC histogram per driver (from dpcDrivers with bucket data)
}
```

- [ ] **Step 10: Build Compare Tab**

```powershell
function Build-CompareTab {
    param($History)
    # If History.Count < 2: return placeholder
    # Two side-by-side cards (latest two entries)
    # Each: score, mode, pass/warn/fail counts
    # Delta row with color coding
    # If >2 entries: add <select> dropdowns
}
```

- [ ] **Step 11: Build Checklist Section** (reuse existing expandable rows)

Keep the existing sorted check rows, filter buttons, copy-fix buttons from current `audit-report.ps1`. Extract into `Build-ChecklistSection` function.

- [ ] **Step 12: Assemble HTML document**

Combine all sections:
```
DOCTYPE + head (CSS + JS)
  .wrap
    Build-HeroSection
    Build-TabBar
    #tab-overview
      .panel-grid (4 panels)
      Build-ChecklistSection
    #tab-advanced
      Build-AdvancedTab
    #tab-compare
      Build-CompareTab
    footer
```

- [ ] **Step 13: Parse-validate and test**

Open the generated HTML, verify all tabs, panels, filters, and copy buttons work.

```json:metadata
{"files": ["scripts/audit-report.ps1"], "verifyCommand": "powershell -ExecutionPolicy Bypass -File scripts/audit.ps1 -Mode Deep", "acceptanceCriteria": ["Three tabs render and switch", "Hero section shows P95 or score ring", "Frame distribution panel works or shows placeholder", "DPC blame panel works or shows placeholder", "Filter buttons work", "Copy fix buttons work", "Self-contained HTML, no CDN", "0 parse errors"], "requiresUserVerification": true, "userVerificationPrompt": "Open the HTML report from captures/audits/. Do the three tabs work? Do the panels show data or placeholders correctly?"}
```

---

## Task 6: Commit + End-to-End Smoke Test

**Goal:** Commit all changes, run full pipeline + audit, verify the complete flow.

**Files:** All modified files

**Acceptance Criteria:**
- [ ] All 5 scripts parse with 0 errors
- [ ] `pipeline.ps1 -Label TEST -Description "smoke test" -DurationSec 10 -WPRProfile InputLatency` completes
- [ ] `audit.ps1 -Mode Deep` generates HTML with populated pipeline panels
- [ ] Tabs switch, filters work, copy-fix works
- [ ] Compare tab shows entries from history
- [ ] Score + file paths printed in console

**Verify:** Full end-to-end run, open HTML report

**Steps:**

- [ ] **Step 1: Parse-validate all 5 scripts**
- [ ] **Step 2: Run pipeline capture** (10s, InputLatency profile)
- [ ] **Step 3: Run audit** (Deep mode)
- [ ] **Step 4: Open and verify HTML report**
- [ ] **Step 5: Commit all changes**

```json:metadata
{"files": ["scripts/audit-report.ps1", "scripts/audit.ps1", "scripts/pipeline-helpers.ps1", "scripts/analyze-input-latency.ps1", "scripts/pipeline.ps1"], "verifyCommand": "powershell -ExecutionPolicy Bypass -File scripts/audit.ps1 -Mode Deep", "acceptanceCriteria": ["All scripts parse clean", "Pipeline captures successfully", "HTML report has all three tabs", "Panels populated from pipeline data"], "requiresUserVerification": true, "userVerificationPrompt": "Open the final HTML report. Does it look right? Are the tabs, panels, and checklist all working?"}
```

---

## Dependency Order

```
Task 1 (helpers) ─→ Task 2 (pipeline auto-detect) ─→ Task 3 (DWM extraction)
                                                          ↓
                                              Task 4 (audit loads pipeline data)
                                                          ↓
                                              Task 5 (report rewrite)
                                                          ↓
                                              Task 6 (smoke test + commit)
```

Tasks are sequential — each depends on the previous.
