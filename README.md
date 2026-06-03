# Windows Latency Optimizer

A scientific toolkit for measuring and reducing Windows system latency — built because every "optimization guide" online tells you to flip 20 registry keys and pray, with no instrumentation to tell you whether your system has the problem the guide is trying to fix.

This project does it the other way around: capture first, change second, measure the delta, keep the backup. Each optimization is a numbered experiment with a rollback file. The fix that worked on my 9800X3D + RTX 5070 Ti might not be the fix on yours — but the methodology is portable.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/Platform-Windows%2011-0078D4)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE)
![Tests](https://img.shields.io/badge/Tests-786%20passing-10b981)
![Scripts](https://img.shields.io/badge/Scripts-171%20parse--clean-a78bfa)

> See [`docs/case-study.md`](docs/case-study.md) for the full project narrative — hypothesis, method, measured results — or open [`docs/slides/index.html`](docs/slides/index.html) for the slide-deck version.

---

## What's in here

| Layer | Path | What it does |
|---|---|---|
| Capture | `scripts/pipeline.ps1` | Runs WPR + xperf + perf counters + GPU sensors + (optional) PresentMon in one call. Writes a self-contained directory with raw traces, parsed JSON, and a rollback-ready registry backup. |
| Audit | `scripts/audit.ps1` + `scripts/audit-checks/*.ps1` | 41 checks across 9 categories (OS, GPU, DWM, latency, memory, network, NIC, peripheral, helpers). Each check has a current/expected value, severity, plain-English message, and optional fix command. |
| Triage | `scripts/diagnose.ps1` | 3-layer dispatcher. Maps symptom keywords ("mouse stutter", "frame drops", "general sluggishness") to the matching audit subset and capture chain. |
| Live monitor | `monitor/` | Vanilla-JS dashboard. 9 views including a Command Center and a Verdict view. Reads JSON snapshots written by `scripts/monitor_collector.ps1` every 2 seconds. No build step. |
| Evidence bus | `scripts/helpers/evidence-bus.ps1` + `scripts/evidence_correlate.ps1` | Typed, append-only timeline of what each subsystem observed (and, just as usefully, what it *didn't*). The correlator reads the timeline and the Verdict view renders it — recurring faulting module, symptom-vs-cause misdirection, per-incident event chains. |
| Archive | `dashboard/` | Static experiment archive. Chart.js comparison view across the 22 numbered experiments. |
| Rollback | `scripts/rollback.ps1` + every `backup_pre_*.txt` | Every registry write captures its own restore command. `-WhatIf` for dry runs. |
| Startup guard | `scripts/startup_guard.ps1` | Re-verifies optimizations at logon and auto-fixes Windows-Update drift (e.g. USB EPM, MSI mode, affinity masks). |

---

## Headline results

Same rig, same workload (Fortnite, Performance Mode, 1080p Linear), before and after experiments 03 + 05 + 15 stacked.

| Metric | Before | After | Δ |
|---|---|---|---|
| CPU 0 interrupt share | 97.7 % | 0.9 % | **−99 %** |
| Mouse input gaps (10 s capture) | 103 | 25 | **−76 %** |
| Longest input gap | 703 ms | 11 ms | **−98 %** |
| Top DPC driver | `nvlddmkm.sys` · 561 µs | `storvsp.sys` · 8 µs | GPU DPC eliminated |
| Defender hard pagefaults | 149 / 2 min | < 10 / 2 min | **−93 %** |
| Audit score | n/a | 97 % (40 pass, 1 warn) | Fully optimized |

The root cause wasn't hardware. It was Windows defaulting to a legacy IRQ line for the NVIDIA GPU, putting 97.7 % of all interrupt work on CPU 0 while 15 other logical cores sat idle. Enabling MSI mode and redistributing interrupt affinity across cores eliminated the saturation entirely.

Full method in [`docs/case-study.md`](docs/case-study.md).

---

## Quick start

### Prerequisites

- Windows 10 / 11 with PowerShell 5.1 (built-in — no install)
- Administrator rights (most scripts need elevated context for registry + ETW + perf counters)
- Windows ADK with Windows Performance Toolkit for `xperf` / `WPA` (optional but recommended)
- Node.js only if you want to serve `monitor/` over `http://localhost` — the dashboards work fine from `file://` URLs too

### Run an audit

```powershell
# Run as Administrator
.\scripts\audit.ps1 -Mode Deep                      # Full 41-check audit
.\scripts\audit.ps1 -Mode Deep -Symptom MouseFreezing  # Symptom-targeted subset
```

Output: `captures/audits/audit_<timestamp>.json` + `audit_<timestamp>.html` (self-contained, opens in any browser).

### Capture a full experiment

```powershell
# WPR + xperf + perf + GPU + (optional) PresentMon, ~60s by default
.\scripts\pipeline.ps1 -Label "MY_EXPERIMENT" -DurationSec 60

# Add frame timing for a specific game process
.\scripts\pipeline.ps1 -Label "FORTNITE_RUN" -GameProcess "FortniteClient-Win64-Shipping.exe"

# Smoke test (no WPR, 5s)
.\scripts\pipeline.ps1 -Label "SMOKE" -SkipWPR -DurationSec 5
```

Output: `captures/experiments/<label>_<timestamp>/` with raw ETL, parsed JSON, HTML report, and `backup_pre.txt` with embedded rollback commands.

### Open the live monitor

```powershell
# Start the collector (writes JSON snapshots every 2s)
.\scripts\monitor_collector.ps1

# Open the dashboard
start monitor\index.html
# or serve over http for cross-origin features
npx serve monitor -l 3848
```

### Open the experiment archive

```powershell
start dashboard\index.html
# or
npx serve dashboard -l 3847
```

### Roll back a change

```powershell
.\scripts\rollback.ps1 -BackupFile captures\experiments\EXP15_*\backup_pre.txt -WhatIf
.\scripts\rollback.ps1 -BackupFile captures\experiments\EXP15_*\backup_pre.txt
```

---

## Architecture

```
            ┌──────────────────────────────────────────────┐
            │  User: "mouse stutters in Fortnite"          │
            └─────────────────────┬────────────────────────┘
                                  ▼
                       ┌──────────────────────┐
                       │  diagnose.ps1        │  classify symptom
                       └──────────┬───────────┘
                                  │
                  ┌───────────────┼───────────────┐
                  ▼               ▼               ▼
              audit-checks    pipeline.ps1   tool subagent
              (subset of 41)   (WPR + xperf)  (@dpc, @gpu, ...)
                  │               │               │
                  └───────────────┼───────────────┘
                                  ▼
                ┌────────────────────────────────────────┐
                │ captures/experiments/<label>_<ts>/     │
                │   • raw ETL + xperf CSV                │
                │   • parsed JSON                        │
                │   • backup_pre.txt (rollback embedded) │
                │   • report.html                        │
                └─────────────────┬──────────────────────┘
                                  ▼
                ┌────────────────────────────────────────┐
                │ monitor/ (live)      dashboard/ (archive)│
                │ Command Center       Compare view        │
                │ Heatmap · Audit      Experiment table    │
                └────────────────────────────────────────┘
```

Three layers:

1. **Capture (PowerShell 5.1)** — 171 scripts. No external runtime. WMI, registry, ETW, and perf counters via native APIs.
2. **Storage (filesystem)** — `captures/experiments/<label>_<ts>/`. Each is self-contained. No database. `git log` is the journal.
3. **Visualization (HTML + Chart.js)** — `monitor/` live, `dashboard/` archive. Both run from `file://`. Chart.js loads from CDN with a local fallback in `lib/`.

---

## The 41 checks

Grouped by category module under `scripts/audit-checks/`.

<details>
<summary>Click to expand full check list</summary>

| # | Check | Module | Severity | What it detects |
|---|---|---|---|---|
| 1 | MPO Disabled | os | Medium | Multi-Plane Overlay causing cursor flicker |
| 2 | Hyper-V Off | os | High | Hypervisor adding latency to hardware access |
| 3 | VBS/Core Isolation Off | os | High | Virtualization-Based Security overhead |
| 4 | MMCSS SystemResponsiveness | os | Medium | Background task CPU reservation during gaming |
| 5 | MMCSS NetworkThrottling | os | Medium | Network packet throttling during multimedia |
| 6 | MMCSS Games Priority | os | Low | Game thread scheduling priority |
| 7 | Power Plan | os | High | CPU frequency throttling |
| 8 | Win32PrioritySeparation | os | Medium | Foreground process scheduling |
| 9 | GameInput Duplicates | os | Low | Duplicate input device registrations |
| 10 | KB5077181 Stutter Bug | os | High | Known Windows update causing stutters |
| 11 | Defender Gaming Exclusion | os | Medium | Defender scanning game folders |
| 12 | Defender Shader Exclusion | os | Medium | Defender scanning shader cache |
| 13 | LwtNetLog Disabled | os | Medium | ETW autologger consuming 5-15 % CPU |
| 14 | DiagTrack Disabled | os | Low | Telemetry service background I/O |
| 15 | Platform Clock (HPET) | os | Medium | Timer source adding ~1 ms overhead |
| 16 | Anti-Cheat Drivers | os | Low | Kernel-level anti-cheat DPC impact |
| 17 | GPU MSI Mode | gpu | Critical | Line-based interrupt sharing vs dedicated MSI |
| 18 | GPU Interrupt Affinity | gpu | High | GPU interrupts landing on game thread core |
| 19 | HAGS Enabled | gpu | High | Hardware GPU Scheduling (RTX 40/50) |
| 20 | NVIDIA DPC Health | gpu | Critical | `nvlddmkm.sys` DPC spikes > 500 µs |
| 21 | NVIDIA Power Max Perf | gpu | Medium | GPU clock downshift between frames |
| 22 | GPU ReBAR | gpu | Medium | CPU-GPU memory access bandwidth |
| 23 | NIC Driver Line | nic | Medium | Intel I226 driver version |
| 24 | NIC Speed/Duplex | nic | Low | Link speed negotiation |
| 25 | NIC EEE | nic | Medium | Energy Efficient Ethernet adding latency |
| 26 | NIC Interrupt Moderation | nic | Medium | Interrupt batching adding packet delay |
| 27 | Nagle Disabled | nic | Medium | TCP packet batching (up to 200 ms delay) |
| 28 | NIC Interrupt Affinity | nic | Medium | NIC interrupts competing with game threads |
| 29 | Mouse Polling Rate | peripheral | High | Mouse report rate (125 Hz vs 1000 Hz) |
| 30 | Mouse USB Controller | peripheral | Medium | USB port sharing/contention |
| 31 | Overlay Processes | peripheral | Low | Render pipeline hooks from overlays |
| 32 | Capture Card Present | peripheral | Low | Capture card interrupt overhead |
| 33 | RAM Speed vs Rated | memory | Medium | JEDEC defaults vs EXPO (10-15 % slower) |
| 34 | NIC Flow Control | network | Low | Ethernet flow control adding latency |
| 35 | NIC IPv6 Disabled | network | Low | IPv6 overhead on gaming connections |
| 36 | Network Latency Probe | network | Medium | Multi-server ping p50/p95/p99 |
| 37 | TCP Auto-Tuning | network | Low | Window scaling buffer bloat |
| 38 | TCP InitialRTO | network | Low | Initial retransmission timeout |
| 39 | TCP RSC | network | Medium | Receive segment coalescing latency |
| 40 | TCP Timestamps | network | Low | TCP timestamp option overhead |
| 41 | Bufferbloat | network | Medium | Latency under load vs idle |

</details>

---

## Tools used

Each tool is on the page because it answers a specific question the others can't.

| Tool | Question it answers |
|---|---|
| **WPR / xperf** (Windows ADK) | Which driver's DPC was running during the input gap? |
| **PresentMon** (Microsoft) | Did this fix change frame pacing or just averages? |
| **NVIDIA Nsight Systems** | Where in the GPU pipeline is work serializing? |
| **CapFrameX** | Are hitches clustered or spread? Steady-state vs. burst? |
| **LatencyMon** | What's the worst-case ISR / DPC over 10 minutes? |
| **HWiNFO64** | Are voltages, temps, clock stretching within tolerance? |
| **Sysinternals ProcMon** | Is Defender or Search scanning hot paths during gameplay? |
| **GPUView** | How deep is the GPU work queue when frame times spike? |
| **RTSS** | Frame limiter hierarchy + Reflex behaviour under load. |
| **nvidia-smi** | Is the GPU stuck at idle clocks during a load transient? |
| **pktmon** | Are packet retransmits correlated with the freeze? |
| **SCEWIN** | Apply / export BIOS state safely. |

Domain agents (`@dpc`, `@gpu`, `@net`, `@system`, `@capture`, `@triage`) wrap these into a triage flow — full reference in [`docs/tools-glossary.md`](docs/tools-glossary.md).

---

## System under test

| Component | Details |
|---|---|
| CPU | AMD Ryzen 7 9800X3D (8C/16T, Zen 5 V-Cache) |
| GPU | NVIDIA GeForce RTX 5070 Ti |
| RAM | 32 GB DDR5-6000 (EXPO) |
| NIC | Intel I226-V 2.5 GbE |
| OS | Windows 11 Pro Build 26200 |
| Display | 2560×1440 @ 360 Hz |
| Mouse | Razer Viper V3 Pro (Wireless) |

---

## Experiments

22 numbered experiments. Negative results (EXP 11, EXP 13) kept and labeled — they're how I know what doesn't work.

<details>
<summary>Click to expand experiment log</summary>

| # | Experiment | Key Change | Outcome |
|---|---|---|---|
| 00 | Clean Baseline | n/a | Established reference metrics |
| 01 | MMCSS Priority | `SystemResponsiveness: 20 → 0` | More CPU time to game threads |
| 02 | Defender CPU Limit | `ScanAvgCPULoadFactor: 50 → 5` | Scan stalls reduced 93 % |
| 03 | NVIDIA MSI Mode | `MSISupported=1` | Eliminated legacy IRQ sharing |
| 04 | Interrupt Affinity | GPU / NIC → CPUs 4–7 | Registry written (reboot required) |
| 05 | Post-Reboot Verify | n/a | **CPU 0 share: 97.7 % → 4.2 %** |
| 06 | Input Affinity | KB/Mouse → CPUs 2–3 | Input device isolation |
| 07 | C-State Tuning | BIOS C6 disable guide | Latency floor reduction |
| 08 | TCP Tuning | Nagle, RSC, auto-tuning | Network packet latency |
| 09 | HPET Disable | `bcdedit /deletevalue useplatformclock` | Timer overhead removed |
| 10 | Memory Compression | `Disable-MMAgent -mc` | Memory latency reduction |
| 11 | Stutter Fixes | MPO, FSO, GameBar | Caused Epic Launcher crash · reverted |
| 12 | NIC Retuning | Interrupt moderation + EEE | Network interrupt latency |
| 13 | FSO Mitigation | `ForceFlipDisableOverlays` | Reverted (overlay crash class) |
| 15 | Latency Mitigations | Combined TCP + timer + priority | Compound improvement |
| 16 | DNS Optimization | Cloudflare DOH + cache | DNS lookup latency |
| 17 | Bufferbloat Test | Latency under load | Buffer queue measurement |
| 18 | Fortnite Gaming | Live gameplay capture | Real-world validation |
| 19 | Defender Exclusions | EasyAntiCheat + Epic exclusions | Scan I/O during gameplay |
| 20 | HAGS Toggle | `HwSchMode=2` | RTX 5070 Ti needs HAGS enabled |
| 21 | MSI + Clocks | GPU MSI verify + clock stability | Combined GPU optimization |
| 22 | MSI + HAGS Fix | Post-reboot verification | **Final optimized state** |

</details>

---

## Project layout

```
windows-latency-optimizer/
├── scripts/                    # 171 PowerShell scripts (capture, audit, fix, rollback)
│   ├── pipeline.ps1            # Full capture (WPR + xperf + perf + GPU)
│   ├── audit.ps1               # 41-check audit orchestrator
│   ├── audit-checks.ps1        # Loader — dot-sources audit-checks/*.ps1
│   ├── audit-checks/           # 9 category modules
│   ├── diagnose.ps1            # 3-layer triage dispatcher
│   ├── monitor_collector.ps1   # Live collector (2s refresh -> monitor/data/)
│   ├── rollback.ps1            # Safe rollback from backup_pre_*.txt
│   ├── startup_guard.ps1       # Logon-time drift detection + auto-fix
│   ├── helpers/                # Shared modules (logging, capture-core, ...)
│   └── exp*.ps1                # Individual experiment apply scripts
├── monitor/                    # Canonical live UI (vanilla JS + Chart.js)
│   ├── index.html              # Shell
│   ├── monitor.{css,js}        # Core styles + view router
│   ├── views/                  # 9 view modules incl. verdict.js + command-center.{js,css}
│   ├── data/                   # snapshot.js + history.js + evidence_latest.js (collector + correlator output)
│   └── lib/chart.umd.min.js    # Offline fallback
├── dashboard/                  # Experiment archive (static, file://)
│   ├── index.html
│   ├── app.{css,js}
│   └── data/experiments*.js
├── captures/                   # Experiment outputs (gitignored except small JSONs)
│   ├── experiments/<label>_<ts>/
│   └── audits/                 # audit_*.json + audit_*.html
├── docs/
│   ├── case-study.md           # Project narrative
│   ├── slides/                 # Self-contained HTML slide deck
│   ├── findings.md             # Initial LatencyMon root cause analysis
│   ├── methodology.md          # Scientific protocol
│   ├── implementation-plan.md  # Detailed fix plan with rollback commands
│   ├── tools-glossary.md       # Diagnostic tool reference
│   ├── history/                # Retired artifacts (e.g. Tauri app summary)
│   └── wiki/                   # Research notes + reference docs
├── tests/                      # Pester (12 suites · 786 tests) + Node assert (47 tests)
├── config/
│   └── defender_exclusions.txt # Local-only Defender exclusion list (gitignored)
└── .claude/
    ├── CLAUDE.md               # Project instructions for Claude Code agents
    ├── agents/                 # 5 domain agents + 12 tool subagents
    └── launch.json             # Dev-server configs (dashboard, monitor, slides)
```

---

## Tests

```powershell
# Parse-check all PS scripts + WPR profile XML
.\scripts\test-all.ps1

# Run Pester suites (786 tests across 12 files)
Invoke-Pester -Path tests

# Run JS dashboard tests
node tests\dashboard.test.js
```

---

## Related docs

- [`docs/case-study.md`](docs/case-study.md) — Project narrative: problem, hypothesis, method, results, retro
- [`docs/slides/index.html`](docs/slides/index.html) — Slide-deck version
- [`docs/methodology.md`](docs/methodology.md) — Scientific protocol and reproducibility guide
- [`docs/findings.md`](docs/findings.md) — Initial LatencyMon root cause analysis
- [`docs/implementation-plan.md`](docs/implementation-plan.md) — Detailed fix plan with rollback commands
- [`docs/tools-glossary.md`](docs/tools-glossary.md) — Reference for all diagnostic tools
- [`LATENCY-OPTIMIZATION-REPORT.md`](LATENCY-OPTIMIZATION-REPORT.md) — Full 34 KB optimization report

---

## A note on naming

The project's first user-facing app was a Tauri + Rust desktop binary codenamed **LatencyGuard**. It worked, but it was scope creep — a 3.9 GB build dir on top of a pipeline that already produced HTML. The Tauri layer was retired in May 2026 in favour of the `monitor/` HTML dashboard. The LatencyGuard codename survives in a few legacy artifacts: the scheduled task names (`LatencyGuard-StartupCheck`, `\LatencyGuard\LatencyGuard-DefenderDisable`), the firewall rule prefix (`LatencyGuard_`), and the log filename env var (`LATENCYGUARD_LOG`). These stay as-is — renaming them on live systems would silently orphan tasks. Historical research notes live under `docs/wiki/research/` and `docs/history/`.

---

## License

[MIT](LICENSE) — Louis Condevaux ([@Lcxiv](https://github.com/Lcxiv))
