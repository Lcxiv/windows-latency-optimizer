---
tags: [index, dashboard]
date: 2026-04-27
status: active
aliases: [Home, Dashboard, Wiki Index]
---

# LatencyGuard Knowledge Base

Scientific Windows latency optimization toolkit — research, reference, and scripts.

## System Under Test

| Component | Spec |
|-----------|------|
| CPU | AMD Ryzen 7 9800X3D (8C/16T, Zen 5, 3D V-Cache) |
| GPU | NVIDIA RTX 5070 Ti |
| RAM | 32GB DDR5-6000 (EXPO) |
| NIC | Intel I226-V 2.5GbE |
| OS | Windows 11 Build 26200 |
| Display | 2560x1440 @ 360Hz |

## Quick Stats

- **Audit score:** 84% to 97% (EXP01-EXP21)
- **Defender impact:** -66% page faults, -68% CPU, +3.1GB RAM after full disable
- **Polling storms:** 8 identified, 6 fixed (8,512 to est. <3,000 events/sec)
- **DPC optimization:** CPU 0 interrupt share 97.7% to 0.5%
- **GPU affinity:** RTX 5070 Ti has NO interrupt affinity override — 46.8% CPU 0 DPC

## Research

Deep-dive investigations and root cause analyses.

| Doc | Summary |
|-----|---------|
| [[system-polling-storms]] | 8 polling storms: SearchIndexer, ctfmon, camsvc, Explorer, Winmgmt, AppCompat |
| [[chrome-render-latency]] | Defender WdFilter.sys = 454K page faults/sec during Chrome navigation |
| [[gpu-affinity-discovery]] | RTX 5070 Ti has NO interrupt affinity override — 46.8% CPU 0 DPC |
| [[performance-findings]] | Measured data: 84% to 97% score, EXP15 results, Defender/DPC impact |
| [[dwm-mpo-crash-pattern]] | OverlayTestMode=5 causes Epic Launcher crash on fullscreen-exclusive |
| [[vsoc-undervolt-bootfail]] | VSOC 1.24V to 1.1V broke IMC at DDR5-6000; safe floor ~1.18V |
| [[known-good-baseline]] | Post-CMOS-reset reference readings (Vcore 1.214V, VSOC 1.24V) |
| [[ping-regression]] | NIC speed lock to 1Gbps caused ping regression |
| [[burst-pattern-analysis]] | 7 burst sources: timer coalescing, C-states, WMI, GPU P-state, NIC, MMCSS |
| [[smooth-state-baseline]] | Golden state at 16:43 — 24 min silence, 373/sec actionable I/O, 0% CPU 0 DPC |
| [[mouse-smoothness-observation]] | Mouse smoothness improvement after MPO/Windows Update |
| [[registry-drift-log]] | Tracking registry drift over time with watchdog |
| [[latencyguard-architecture]] | 3-layer design: PS core, HTML reports, Tauri app |
| [[improvements-roadmap]] | Prioritized next steps and feature backlog |

## Reference

Hardware guides, tool references, and optimization guides.

| Doc | Summary |
|-----|---------|
| [[windows-latency]] | ETW providers, stutter signatures, registry paths, tool commands |
| [[9800x3d-architecture]] | Zen 5 V-Cache, BIOS settings, WHEA, clock stretching, FCLK |
| [[blur-busters-tweaks]] | G-Sync 101, frame limiter hierarchy, input lag chain, NVCP |
| [[rtss-reflex-caps]] | Cap hierarchy, Reflex NvAPI, Scanline Sync, 360Hz config |
| [[ddr5-timings]] | Timing hierarchy, DDR5-6000 values, tRFC/tREFI, AIDA64 targets |
| [[scewin-bios]] | Commands, export format, safety rules, recovery |
| [[multi-monitor-vram]] | VRAM P-states, clock lock, MPO disable, RTX 5070 Ti bugs |
| [[defender-diagnostics]] | Performance recording, WPR fallback, exclusion verification |
| [[hardware-voltages]] | Per-rail nominal/min/max for hwdiag comparator |
| [[ps51-pitfalls]] | 5 confirmed PS 5.1 pitfalls: $error/$pid, uint32, no ternary |
| [[tauri-patterns]] | Prerequisites, withGlobalTauri, script execution, build lock |

## Scripts

See [[catalog]] for the full 87+ script index organized by category.

**Most used:**
- `fix_system_polling.ps1` — Fix 8 system polling storms | [[system-polling-storms]]
- `fix_exitlag_filter.ps1` — Toggle ExitLag NDIS filter (52% Rx overhead) | [[burst-pattern-analysis]]
- `analyze_procmon_idle.ps1` — ProcMon idle analysis with CLI noise exclusion
- `disable_defender.ps1` — Full Defender disable with boot persistence | [[chrome-render-latency]]
- `pipeline.ps1` — End-to-end experiment capture pipeline
- `audit.ps1` — System latency audit (32 checks, HTML report)
- `optimize-game.ps1` — Game affinity + bloatware kill before gaming

## Tags

#research #reference #scripts #polling #chrome #defender #gpu #affinity #dpc #dwm #mpo #voltage #bios #9800x3d #ddr5 #rtss #reflex #gsync #nic #registry #tauri #powershell #etw
