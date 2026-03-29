# Windows Latency Optimizer

A toolkit for measuring, analyzing, and reducing system latency on Windows — focused on gaming and real-time audio use cases.

## System Under Test

| Component | Details |
|---|---|
| Machine | DESKTOP-V5BN4SC |
| CPU | AMD Ryzen 7 9800X3D (8C / 16T, 16 logical) |
| RAM | 32 GB |
| OS | Windows 11 Build 26200 (x64) |
| BIOS | ASUS 3602 |

## What This Does

- **Baseline capture** — samples 10 Windows Performance Counters (CPU, memory, disk, system) before and after each tweak
- **Registry diff** — records MMCSS / network throttling / Defender settings at capture time
- **ProcMon analysis** — parses a 30-second Process Monitor trace for top event sources, I/O hotspots, Defender activity, and stalls
- **Interactive dashboard** — HTML file that visualizes all experiments side-by-side against baseline (DPC latency, CPU interrupt distribution, hard pagefaults, registry diff)

## Prerequisites

| Tool | Purpose | Link |
|---|---|---|
| PowerShell 5.1+ | Run capture scripts | Built into Windows |
| Process Monitor | Capture system traces | [Sysinternals](https://learn.microsoft.com/en-us/sysinternals/downloads/procmon) |
| LatencyMon | Measure DPC/ISR latency | [Resplendence](https://www.resplendence.com/latencymon) |

## Quick Start

### 1. Record a baseline (run as Administrator)

```powershell
.\scripts\baseline_capture.ps1 -Label "BEFORE"
```

This samples 10 performance counters for 10 seconds and snapshots key registry settings.

### 2. Apply your tweak, then capture again

```powershell
.\scripts\baseline_capture.ps1 -Label "AFTER_tweak_name"
```

### 3. Capture a ProcMon trace

1. Open `Procmon64.exe` as Administrator
2. Let it run for ~30 seconds under normal load
3. **File → Save → CSV** → save to `captures\procmon_capture.csv`

### 4. Analyze the ProcMon trace

```powershell
.\scripts\analyze_procmon.ps1
```

### 5. Run LatencyMon

1. Open LatencyMon as Administrator
2. Click **Start** — let it run for at least 1–2 minutes
3. Click **Stop**, then **File → Save report** → save to `captures\latencymon_report.txt`

### 6. View the dashboard

Open `dashboard\index.html` in any browser.

## Project Structure

```
windows-latency-optimizer/
├── scripts/
│   ├── baseline_capture.ps1      # Captures perf counters + registry state
│   └── analyze_procmon.ps1       # Parses ProcMon CSV for top processes/ops
├── captures/
│   ├── os_baseline_BEFORE.txt    # Pre-optimization snapshot
│   ├── os_baseline_AFTER.txt     # Post-optimization snapshot
│   ├── latencymon_report.txt     # LatencyMon full report (text)
│   └── procmon_capture.csv       # 30-second ProcMon trace (CSV)
├── docs/
│   └── findings.md               # Analysis notes and next steps
└── dashboard/
    ├── index.html                 # Interactive dashboard (open in browser)
    └── data/
        └── experiments.js         # ← Add new experiment data here
```

## Adding a New Experiment

1. Run `baseline_capture.ps1 -Label "EXP_NAME"` before and after your tweak
2. Optionally run LatencyMon and save the report
3. Open `dashboard/data/experiments.js` and add a new object to the `window.EXPERIMENTS` array following the existing format
4. Reload `dashboard/index.html`

## Optimizations Tracked

| Setting | Baseline | Experiment 01 | Notes |
|---|---|---|---|
| `SystemResponsiveness` | 20 | **0** | Gives more CPU to multimedia/audio |
| `NetworkThrottlingIndex` | 10 | **Disabled** | Removes 10-packet/ms network cap |
| MMCSS Games Category | Medium | **High** | Raises game thread scheduling class |
| MMCSS Games Priority | 2 | **6** | Higher MMCSS priority value |
| MMCSS Games SFIO | Normal | **High** | Higher I/O scheduling priority |
| Defender Exclusions | None | **Fortnite paths** | Reduces scan stalls in-game |

## Key Findings

- LatencyMon result: **PASS** — suitable for real-time audio
- Highest DPC: **561.6 µs** from `ntoskrnl.exe` (CPU 6)
- Highest DPC total time: `nvlddmkm.sys` at **0.105%** (NVIDIA driver)
- **97.7% of all DPCs** land on CPU 0 — interrupt affinity heavily skewed
- `msmpeng.exe` (Defender) caused **149 of 338 hard pagefaults**

See [docs/findings.md](docs/findings.md) for the full analysis.
