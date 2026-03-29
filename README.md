# Windows Latency Optimizer

A scientific toolkit for measuring, analyzing, and reducing system latency on Windows — focused on gaming and real-time input use cases. Each change is tracked as a numbered experiment with before/after captures and rollback instructions.

## System Under Test

| Component | Details |
|---|---|
| Machine | DESKTOP-V5BN4SC |
| CPU | AMD Ryzen 7 9800X3D (8C / 16T, 16 logical) |
| RAM | 32 GB |
| GPU | NVIDIA RTX 5070 Ti |
| NIC | Intel I226-V 2.5 GbE |
| OS | Windows 11 Build 26200 (x64) |
| BIOS | ASUS 3602 |

## Hypothesis

> Redistributing hardware interrupts away from CPU 0 (the Ryzen preferred core) and isolating Windows Defender's CPU impact will reduce worst-case DPC latency and interrupt jitter experienced during gaming.

**Initial findings (LatencyMon baseline):**
- CPU 0 handled **97.7% of all DPCs** despite 16 logical CPUs available
- `msmpeng.exe` caused **149 of 338** hard pagefaults in a 2-minute window
- `nvlddmkm.sys` accounted for **0.105%** of total CPU time in DPCs

## Results

| Experiment | Change | CPU 0 Interrupt Share | Total DPC% | Key Outcome |
|---|---|---|---|---|
| Baseline | — | ~97.7% | ~0.40% | CPU 0 bottlenecked |
| Exp 01 | MMCSS + network throttling | — | — | Scheduling priority raised |
| Exp 02 | Defender exclusions + CPU limit | — | 0.078% | Scan stalls reduced |
| Exp 03 | NVIDIA MSI mode + PerfLevelSrc | — | 0.312% | Clock-transition DPCs removed |
| Exp 04 | NIC/GPU/USB affinity → CPUs 4–7 | (pre-reboot) | 0.400% | Registry written |
| **Exp 05** | **Post-reboot verification** | **4.2%** | 0.429% | **CPU 0 load reduced 23×** |
| Exp 06 | KB/mouse USB → CPUs 2–3 | — | 0.293% | Input devices isolated |

Exp 05 is the key validation: CPU 0's share of total interrupt time dropped from **97.7% → 4.2%** after rebooting with interrupt affinity applied.

## Prerequisites

| Tool | Purpose | Notes |
|---|---|---|
| PowerShell 5.1+ | Run all scripts | Built into Windows; run as Administrator |
| LatencyMon | Measure DPC/ISR latency per driver | [resplendence.com/latencymon](https://www.resplendence.com/latencymon) |
| Process Monitor | Capture system-call traces | [Sysinternals](https://learn.microsoft.com/en-us/sysinternals/downloads/procmon) |

## Quick Start

### 1. Capture your baseline

```powershell
# Run as Administrator
.\scripts\baseline_capture.ps1 -Label "MY_BASELINE"
```

Then run LatencyMon for 2+ minutes and save the report to `captures\latencymon_MY_BASELINE.txt`.

### 2. Run a full timed experiment

```powershell
.\scripts\run_experiment.ps1 -Label "EXP01_MY_TWEAK" -Description "What I changed and why"
```

This samples 120 seconds of perf counters, per-CPU interrupt distribution, and registry state, then writes a JSON file to `captures/experiments/`.

### 3. Apply a fix, then roll it back if needed

```powershell
# Preview what rollback will do
.\scripts\rollback.ps1 -BackupFile .\captures\backup_pre_expXX.txt -WhatIf

# Apply rollback
.\scripts\rollback.ps1 -BackupFile .\captures\backup_pre_expXX.txt
```

### 4. Update the dashboard

```powershell
.\scripts\generate_dashboard_data.ps1
```

Then open `dashboard\index.html` in any browser.

## Project Structure

```
windows-latency-optimizer/
├── scripts/
│   ├── run_experiment.ps1          # Full experiment capture → JSON
│   ├── rollback.ps1                # Restore settings from backup file
│   ├── generate_dashboard_data.ps1 # Convert experiment JSONs → dashboard JS
│   ├── baseline_capture.ps1        # Quick 10-second perf + registry snapshot
│   └── analyze_procmon.ps1         # Parse ProcMon CSV for top processes/ops
├── captures/
│   ├── experiments/                # Timestamped JSON outputs from run_experiment.ps1
│   ├── backup_pre_*.txt            # Registry backups with embedded rollback commands
│   ├── os_baseline_*.txt           # Quick baseline snapshots
│   └── latencymon_*.txt            # LatencyMon text reports
├── docs/
│   ├── findings.md                 # Initial analysis and root causes
│   ├── implementation-plan.md      # Step-by-step fix plan with rollback
│   └── methodology.md              # Scientific protocol and reproducibility guide
└── dashboard/
    ├── index.html                  # Interactive dashboard (open in browser)
    └── data/
        ├── experiments.js          # Hand-curated experiment data
        └── experiments_generated.js # Auto-generated from run_experiment.ps1 JSONs
```

## Adding a New Experiment

1. State your hypothesis in the description before capturing
2. Back up current registry state to `captures/backup_pre_expXX.txt`
3. Apply your change
4. Reboot if required (interrupt affinity changes always require reboot)
5. Run `.\scripts\run_experiment.ps1 -Label "EXP0X_..." -Description "..."`
6. Optionally run LatencyMon alongside and save the report
7. Run `.\scripts\generate_dashboard_data.ps1`
8. Commit: `git add -A && git commit -m "expXX: description"`

See [docs/methodology.md](docs/methodology.md) for the full scientific protocol.

## Optimizations Applied

| Fix | Registry Path | Change | Mechanism |
|---|---|---|---|
| MMCSS priority | `...\Multimedia\SystemProfile` | SystemResponsiveness: 20→0, NetworkThrottlingIndex: 10→max | More CPU time to game threads |
| Defender CPU limit | `MpPreference` | ScanAvgCPULoadFactor: 50→5, EnableLowCpuPriority: true | Reduces scan stalls during gameplay |
| NVIDIA MSI mode | `...\MessageSignaledInterruptProperties` | MSISupported=1, MessageNumberLimit=1 | Eliminates legacy IRQ sharing |
| NVIDIA perf level | `...\nvlddmkm\Global\NVTweak` | PerfLevelSrc=0x2222 | Prevents clock-transition DPC callbacks |
| NIC/GPU/USB affinity | `...\Affinity Policy` | DevicePolicy=4, CPUs 4–7 (0xF0) | Moves interrupts off preferred core |
| KB/Mouse affinity | `...\Affinity Policy` | DevicePolicy=4, CPUs 2–3 (0x0C) | Isolates input latency path |

## Reproducing on a Different System

The interrupt affinity bitmasks in this project are specific to a **16-logical-CPU Ryzen 9800X3D** system:
- `0xF0` = CPUs 4–7 (non-preferred physical cores)
- `0x0C` = CPUs 2–3 (dedicated input cores)

For other systems, adjust bitmasks to match your core layout. See [docs/methodology.md](docs/methodology.md) for guidance.

## See Also

- [docs/findings.md](docs/findings.md) — Initial LatencyMon analysis
- [docs/implementation-plan.md](docs/implementation-plan.md) — Detailed fix plan with root causes
- [docs/methodology.md](docs/methodology.md) — Scientific protocol
