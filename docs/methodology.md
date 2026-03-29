# Experimental Methodology

This document describes the scientific protocol for running and comparing experiments in this project. Following it consistently ensures results are reproducible and comparable across sessions.

---

## Hypothesis Framework

Each experiment should be framed as a falsifiable hypothesis before running it:

```
H: [change X] will reduce [metric Y] from [baseline value] to [target value]
   by [mechanism Z].
```

**Example:**
> H: Pinning interrupt affinity for NIC/GPU to CPUs 4–7 will reduce CPU 0's interrupt cycle time from 7.83s to <2.0s by redistributing DPC processing off the preferred core.

Document the hypothesis in the experiment's `description` field before capture.

---

## Prerequisites

Before every capture:

1. **Close all non-essential applications** — browsers, Discord, streaming software, background updaters.
2. **Wait 2 minutes after system boot** before capturing baseline — let Windows finish startup tasks.
3. **Disable Windows Update** during capture windows: `Services.msc → Windows Update → Startup type: Disabled` (re-enable after).
4. **Same hardware state** — same monitors plugged in, same USB devices connected between experiments.
5. **No active game/workload** unless you are specifically testing under load (document the load in the description).

---

## Capture Protocol

### Standard Capture (scripts/run_experiment.ps1)

```powershell
.\scripts\run_experiment.ps1 -Label "EXP07_HPET_OFF" -Description "Disabled HPET via bcdedit /set useplatformclock false"
```

- **Minimum duration:** 120 seconds (default). Use 60s only for quick checks; never compare 60s vs 120s results.
- **Script checks** CPU usage before starting — if >15%, it warns and waits. Let it settle or close apps.
- **Output:** `captures/experiments/YYYYMMDD_HHMMSS_LABEL.json`

### LatencyMon Capture (manual — recommended for each experiment)

LatencyMon provides ISR/DPC driver attribution that perf counters cannot. Run it alongside `run_experiment.ps1`:

1. Open LatencyMon as Administrator.
2. Click **Start** at the same time as `run_experiment.ps1`.
3. Let both run for the full duration (≥2 minutes).
4. In LatencyMon: **Report → Save to file** → save as `captures/latencymon_LABEL.txt`.
5. Extract key fields and add to the experiment's `latencymon` object in `experiments.js`.

### Environmental Controls

- **Network:** Disconnect Ethernet or put it in airplane mode if measuring baseline interrupt load — network traffic generates interrupts.
- **Peripherals:** Keep all USB devices plugged in between experiments.
- **Display:** Same resolution/refresh rate between experiments.
- **Power plan:** High Performance or Ultimate Performance throughout. Check: `powercfg /getactivescheme`.

---

## Registry Change Procedure

1. **Backup first** — always capture current state before any change:
   ```powershell
   # Capture current state to a backup file
   .\scripts\baseline_capture.ps1 -Label "PRE_EXP07"
   ```
   For interrupt affinity changes, also manually document the rollback commands in `captures/backup_pre_expXX.txt`.

2. **Apply one change at a time** — never combine multiple unrelated changes in a single experiment. This makes it impossible to attribute effects.

3. **Reboot after interrupt affinity changes** — Windows does not apply new interrupt affinity until device enumeration at boot.

4. **Verify** — after applying (and rebooting if needed), confirm registry values are as expected before capturing.

---

## Rollback

To undo an experiment's changes:

```powershell
.\scripts\rollback.ps1 -BackupFile ..\captures\backup_pre_expXX.txt
```

Use `-WhatIf` first to preview what will be executed:
```powershell
.\scripts\rollback.ps1 -BackupFile ..\captures\backup_pre_expXX.txt -WhatIf
```

---

## Metrics and Targets

| Metric | Tool | Baseline | Target | Notes |
|--------|------|----------|--------|-------|
| CPU 0 interrupt cycle time | LatencyMon | 7.83s | <2.0s | Per-session; depends on uptime |
| nvlddmkm DPC load | LatencyMon | 0.105% | <0.030% | % of total CPU time |
| Max observed DPC | LatencyMon | 561µs | <200µs | Worst-case spike |
| msmpeng hard pagefaults | LatencyMon | 149/session | <10 | In a 2-min window |
| Total DPC% (perf counter) | `run_experiment.ps1` | ~0.40% | <0.05% | Idle system |
| Total interrupt% | `run_experiment.ps1` | ~0.38% | <0.10% | Idle system |
| CPU 0 share of interrupts | `run_experiment.ps1` | ~97.7% | <25% | After affinity change |

**Important:** Perf counter DPC% numbers are heavily load-dependent. Always capture under comparable system activity levels. The Exp 05 capture showed 0.43% DPC% but the system had 23K context switches/sec (active) vs Exp 02's 2417/sec (very idle) — these are not directly comparable.

---

## Statistical Significance

A single 2-minute capture is not statistically rigorous. For publication-quality results:

- Run **3 captures** under the same conditions and average them.
- Report mean ± standard deviation.
- Ensure the _same game or workload_ is running (or all are idle) across all 3 runs.

For this project's purposes, single captures are sufficient for directional improvement tracking. Document if the system was loaded vs idle.

---

## Experiment Numbering

- Experiments are numbered sequentially: `EXP01`, `EXP02`, etc.
- If an experiment is abandoned or reverted, skip the number — don't reuse it.
- Post-reboot verification of a prior experiment uses the same base number with `_POST_REBOOT` suffix (e.g., `EXP05_POST_REBOOT`).

---

## Adding Results to the Dashboard

After a successful capture:

1. **Automated experiments** (from `run_experiment.ps1`):
   ```powershell
   .\scripts\generate_dashboard_data.ps1
   ```
   This writes `dashboard/data/experiments_generated.js`.

2. **Manual experiments** (from `baseline_capture.ps1` + LatencyMon):
   - Copy an existing entry in `dashboard/data/experiments.js`
   - Fill in measured values
   - The dashboard reloads automatically on file save (if served locally) or on next browser open.

3. Commit: `git add -A && git commit -m "expXX: description"`

---

## Reproduction

To reproduce this project's results on a different system:

1. Clone the repo: `git clone <url>`
2. Run `.\scripts\baseline_capture.ps1 -Label YOUR_BASELINE` to capture your system's starting point.
3. Run LatencyMon for 2+ minutes, save to `captures/latencymon_YOUR_BASELINE.txt`.
4. Follow `docs/implementation-plan.md` step by step.
5. After each fix, run `.\scripts\run_experiment.ps1 -Label EXP0X_... -Description "..."`.
6. Run `.\scripts\generate_dashboard_data.ps1` and open `dashboard/index.html`.

Note: CPU topology and interrupt controller assignment differ between systems. Affinity masks (`0xF0` = CPUs 4–7) are specific to this Ryzen 9800X3D system. Adjust bitmasks for your CPU count and preferred core layout.
