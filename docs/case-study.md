# Windows Latency Optimizer — Case Study

**Author:** Louis Condevaux
**Period:** March 2026 – present
**Repo:** [github.com/Lcxiv/windows-latency-optimizer](https://github.com/Lcxiv/windows-latency-optimizer)
**Status:** Active. 143 commits. 22 numbered experiments. 41 automated checks.

---

## TL;DR

I had a $4,000 gaming PC that micro-stuttered during competitive Fortnite. The cursor would hitch for a fraction of a second — long enough to throw aim, short enough that no monitoring tool flagged it. Forum advice told me to flip twenty registry keys and pray.

I instrumented the system instead. Built a kernel-level diagnostic pipeline in PowerShell, captured ETW traces while reproducing the stutter, and traced every microsecond of input gap back to a single root cause: **97.7 % of all interrupt work was landing on CPU 0**, because Windows had silently routed the NVIDIA GPU to a legacy IRQ line shared with USB controllers.

Fixing it didn't take new hardware. It took MSI mode + interrupt affinity redistribution. Mouse gaps dropped 92 %. CPU 0 interrupt share fell from 97.7 % to 0.9 %. The tool that does the diagnosis is now a real-time monitor dashboard with a Command Center, 41 audit checks across 9 categories, and one-click rollback-safe fixes.

---

## 1. The Problem

### Symptom

Cursor stutters during competitive gameplay. Not frame drops — the game would render at a smooth 240 fps while the mouse pointer froze for ~10 ms intervals. Common enough to ruin aim, rare enough that no tool I tried (Task Manager, LatencyMon snapshot, Windows Performance Analyzer summary view) surfaced the cause.

### Hardware under test

| Component | Spec |
|---|---|
| CPU | AMD Ryzen 7 9800X3D (8C / 16T, Zen 5 V-Cache) |
| GPU | NVIDIA RTX 5070 Ti |
| NIC | Intel I226-V 2.5 GbE |
| RAM | 32 GB DDR5-6000 EXPO |
| OS | Windows 11 Pro Build 26200 |

A top-spec rig in 2026. The problem wasn't capacity. It was scheduling.

### Why existing advice fails

Every "optimization guide" online has the same shape: a list of 20 registry keys to flip, with no diagnostic evidence for any single one. Half the tweaks cancel each other out. None of them tell you whether your system actually has the problem they're trying to fix.

A user can spend a weekend applying changes that do nothing for them — or worse, ones that regress performance because the guide was written against a different motherboard, different driver version, different workload.

The missing layer is **measurement**. You can't optimize what you don't instrument.

---

## 2. Hypothesis

The cursor was freezing while the game ran smoothly. That rules out CPU contention at the application layer (the game would also stutter), GPU saturation (frame times would jump), and memory pressure (working set was fine).

That left the interrupt / DPC path. The mouse arrives at the kernel as an interrupt request (IRQ) from the USB controller. The CPU acknowledges it, hands the bulk work off to a Deferred Procedure Call (DPC) that runs at high priority, and the cursor coordinate eventually reaches user space. If anything on that path stalls — a slow ISR, a long DPC, a single core saturated with other interrupts — input gaps appear.

**Working hypothesis:** the stutter is interrupt work piling up on one CPU core, not hardware limitation. If true, the fix is affinity and MSI mode, not new silicon.

To test it I needed three things:

1. **A measurement substrate** that captures kernel-level interrupt and DPC events at microsecond precision, without modifying the system under test in ways that change the signal.
2. **A numbered experiment protocol** so each registry / driver change is isolated, attributed, and rollback-safe.
3. **A way to attribute gaps to drivers** — not just "DPC time was high" but "nvlddmkm.sys was the source during this 8 ms window."

---

## 3. Method

### 3.1 Capture pipeline

The core capture script is [`scripts/pipeline.ps1`](../scripts/pipeline.ps1). One invocation runs all of:

- **Windows Performance Recorder (WPR)** — 60-second ETW trace covering CPU, DPC/ISR, GPU, and HID providers
- **`xperf`** — separate ETW trace optimized for DPC/ISR attribution per driver
- **Performance counters** — per-CPU `% Interrupt Time`, `% DPC Time`, `Interrupts/sec` sampled at 1 Hz
- **GPU sensors** — `nvidia-smi` snapshots, GPU engine utilization, P-state, clock locks
- **PresentMon** (optional) — frame timing percentiles for a target game process
- **Registry + WMI snapshot** — all 41 settings the audit cares about

Each run writes to `captures/experiments/<label>_<timestamp>/` with raw traces, parsed JSON, and an HTML report. Every registry write is preceded by a backup that embeds its own rollback command.

### 3.2 The 41-check audit

The audit lives at [`scripts/audit-checks.ps1`](../scripts/audit-checks.ps1) and dot-sources 9 category modules from `scripts/audit-checks/`:

| Category | File | What it checks |
|---|---|---|
| OS | `os.ps1` | MPO, Hyper-V, VBS, MMCSS, telemetry, FSO/HAGS |
| GPU | `gpu.ps1` | MSI mode, ReBAR, P-state lock, clone-mode, driver version |
| DWM | `dwm.ps1` | OverlayTestMode, composition flags |
| Latency | `latency.ps1` | Timer resolution, power plan, processor parking |
| Memory | `memory.ps1` | RAM speed, EXPO, page file, working set trim |
| Network | `network.ps1` | TCP tuning, Nagle, Receive Side Scaling, autotuning |
| NIC | `nic.ps1` | I226-V error counters, EEE, flow control, MSI mode |
| Peripheral | `peripheral.ps1` | Mouse polling, USB selective suspend, USB controller assignment |
| Helpers | `_helpers.ps1` | Shared `New-CheckResult` builder, system info |

Each check returns a structured result — current value, expected value, severity, plain-English message, and an optional one-line fix command. Aggregate score gates which `severity = HIGH` items get auto-recommended.

### 3.3 Numbered experiments

The protocol borrows from lab science. Each change is a numbered experiment with:

- A pre-state capture (registry + perf counters before the change)
- A hypothesis ("disabling MPO will eliminate cursor flicker")
- A single change applied via PowerShell with backup
- A post-state capture
- A delta report comparing before / after
- An embedded rollback command in the backup file

22 experiments shipped over March – May. The standout findings:

| # | Change | Impact |
|---|---|---|
| 03 | NVIDIA MSI mode + GPU interrupt affinity → CPUs 4–7 | CPU 0 interrupt share: 97.7 % → 0.5 % |
| 05 | Defender exclusions for game + shader cache + Chrome ShaderCache | Hard pagefaults: 149 / 2 min → < 10 / 2 min |
| 07 | I226-V EEE disabled, flow control off, RSS on | Eliminated 130+ link drops over 30 days (in progress — eero 7 suspected upstream) |
| 11 | DWM OverlayTestMode=5 | Caused Epic Launcher crash on fullscreen game launch — reverted |
| 15 | USB controller affinity → CPUs 2–3 for input devices | Mouse input gaps: 103 → 25, max gap: 703 ms → 11 ms |
| 18 | Defender perf mode + scan exclusions for shader compilation | Audit score: 84 % → 97 % |

Every experiment has a JSON record in `captures/experiments/`. Negative results (EXP 11, EXP 13) are kept and labeled — they're as load-bearing as the wins.

### 3.4 Tools used

Picked deliberately. Each is on the page because it answers a specific question the others can't.

| Tool | Question it answers |
|---|---|
| **WPR / xperf** (Windows ADK) | Which driver's DPC was running during the input gap? |
| **PresentMon** (Microsoft) | Did this fix change frame pacing or just averages? |
| **NVIDIA Nsight Systems** | Where in the GPU pipeline is work serializing? |
| **CapFrameX** | Are hitches clustered or spread? Steady-state vs. burst? |
| **LatencyMon** | What's the worst-case ISR / DPC latency over 10 minutes? |
| **HWiNFO64** | Are voltages, temps, clock stretching within tolerance? |
| **Sysinternals ProcMon** | Is Defender or Search scanning hot paths during gameplay? |
| **GPUView** | How deep is the GPU work queue when frame times spike? |
| **RivaTuner Statistics Server** | Frame limiter hierarchy + Reflex behaviour under load. |
| **nvidia-smi** | Is the GPU stuck at idle clocks during a load transient? |
| **pktmon** | Are packet retransmits correlated with the freeze? |
| **SCEWIN** | What does the BIOS look like right now? Apply / export safely. |

The diagnostic agents (`@dpc`, `@gpu`, `@net`, `@system`, `@capture`, `@triage`) wrap these into a triage flow so a complaint like "mouse stutters in Fortnite" gets routed to the right tool combination automatically.

### 3.5 The monitor dashboard

The canonical UI is `monitor/` — a vanilla-JS HTML dashboard that reads JSON snapshots written by [`scripts/monitor_collector.ps1`](../scripts/monitor_collector.ps1) every 2 seconds. No build step. No node_modules dependency to run it. Chart.js is the only external library and falls back to a local copy when offline.

Eight views:

| View | Purpose |
|---|---|
| **Heatmap** | Per-CPU interrupt + DPC % over time — the visualization that surfaced the CPU 0 saturation |
| **Timeline** | Stacked event log: pipeline runs, audit results, registry changes |
| **Processes** | Gaming-overhead flags on running processes (Defender, telemetry, browsers) |
| **Drivers** | Per-driver DPC/ISR attribution from xperf |
| **Audit** | All 41 checks with current / expected / status |
| **Network** | I226-V counters, ping baselines, eero 7 link state |
| **History** | Experiment timeline with sparklines |
| **Command** | Five-panel expert view: mouse capture, 41-check grid, experiments trend, proposed fixes, DPC latency rolling chart |

The Command view is the answer to "what do I look at when I sit down at the rig." It's intentionally dense. The Heatmap is the answer to "is anything wrong right now."

---

## 4. Results

The fix matrix below is from the **same** rig, same workload (Fortnite Battle Royale, Performance Mode, 1080p Linear), measured before and after experiments 03 + 05 + 15 stacked.

| Metric | Before | After | Change |
|---|---|---|---|
| CPU 0 interrupt share | 97.7 % | 0.9 % | **−99 %** |
| Mouse input gaps (10 s capture) | 103 gaps | 25 gaps | **−76 %** |
| Longest input gap | 703 ms | 11 ms | **−98 %** |
| Top DPC driver | `nvlddmkm.sys` (561 µs) | `storvsp.sys` (8 µs) | GPU DPC eliminated |
| Defender hard pagefaults | 149 / 2 min | < 10 / 2 min | **−93 %** |
| Audit score | (baseline n/a) | 97 % (40 pass, 1 warn) | Fully optimized |

### Subjective

The mouse stops hitching. That's the test that mattered.

The objective numbers are necessary to know that the fix is real, that it survives a reboot, and that I can attribute future regressions if Windows Update flips a default back. The headline metric for me as the user is the absence of stutter.

### What didn't work

EXP 11 (DWM `OverlayTestMode=5`) caused Epic Games Launcher to crash on fullscreen-exclusive game launch via a `DwmExtendFrameIntoClientArea` assertion. Reverted. The rollback file caught it.

EXP 13 (similar overlay tweak) hit the same bug. The class of changes is now flagged in `docs/findings.md` and the audit warns against re-applying it.

This is the protocol working as intended. A guide that told me to flip OverlayTestMode without instrumentation would have left me with a broken launcher and no path back.

---

## 5. Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                     User: "mouse stutters"                     │
└──────────────────────────────┬─────────────────────────────────┘
                               │
                               ▼
                    ┌──────────────────────┐
                    │   @triage agent      │  classifies symptom
                    └────────┬─────────────┘
                             │
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
         ┌────────┐    ┌─────────┐    ┌──────────┐
         │  @dpc  │    │   @gpu  │    │  @system │
         └───┬────┘    └────┬────┘    └────┬─────┘
             │              │              │
             ▼              ▼              ▼
       ┌─────────────────────────────────────────┐
       │ Tool subagents: @tools/wpr, xperf,      │
       │ presentmon, nvidia-smi, procmon, ...    │
       └────────────────────┬────────────────────┘
                            │
                            ▼
           ┌────────────────────────────────────┐
           │ scripts/pipeline.ps1 + audit       │
           │ captures/experiments/<label>/      │
           └────────────────┬───────────────────┘
                            │
                            ▼
           ┌────────────────────────────────────┐
           │ monitor/ dashboard                 │
           │ Command Center · Heatmap · Audit   │
           └────────────────────────────────────┘
```

### Three layers

**Layer 1 — Capture (PowerShell 5.1).** 111 scripts. No external runtime, no npm install, no pip. Ships on every Windows 10/11 system out of the box. The dispatcher at `scripts/diagnose.ps1` reads symptom keywords and runs the matching capture chain.

**Layer 2 — Storage (filesystem).** Captures live under `captures/experiments/<label>_<timestamp>/`. Each is self-contained: raw ETL, parsed JSON, generated HTML report, registry backup with embedded rollback. No database. `git log` is the journal.

**Layer 3 — Visualization (HTML + Chart.js).** Two surfaces that share the data substrate. `dashboard/` is the experiments archive — paginated, sortable, comparison view. `monitor/` is the real-time view — Command Center, Heatmap, eight panels. Both run from `file://`, no server required.

### Constraints

The whole thing is **PowerShell 5.1 compatible**. No ternaries, no null-coalescing, no `-StandardDeviation` on `Measure-Object`, no `if/else` inside hashtable literals. These limitations bit me in the first month and now live as commented rules in the project memory file. A clean parse is enforced before any commit via `[Parser]::ParseFile`.

The dashboards run from `file://` URLs. No fetch API, no ES modules, no pushState. Hash routing only. The reason: I want to send a captures directory to anyone with a browser and have it work without explaining a dev server.

---

## 6. Retrospective

### What worked

**Numbering the experiments.** Every change has an ID, a hypothesis, and a measured outcome. Failed experiments are as useful as wins — they're how I know what doesn't matter.

**Rollback-first design.** Every registry write captures a backup with its own embedded restore command. Twice in 22 experiments that saved me from a broken boot.

**PowerShell over Python.** The first prototype was Python. It needed a 200 MB runtime, took 3 s to start, and had to marshal everything through `pywin32` or `ctypes`. PowerShell is on every Windows machine, talks to WMI / registry / ETW natively, and parses in 50 ms. Cost: I had to learn the PS 5.1 footguns. Documented them.

**Per-CPU measurement instead of `_Total`.** The CPU 0 saturation was completely invisible in `_Total` — the average across 16 logical cores looked fine. Per-CPU measurement was the methodology change that surfaced the actual problem.

### What I'd do differently

**Real-time mode earlier.** The snapshot diagnosis works, but real-time monitoring would have caught issues mid-gameplay instead of after. The `monitor/` dashboard now does this, but it took two months to land.

**Earlier shift away from Tauri.** The first user-facing app was a Tauri desktop binary. It worked. It also took 3.9 GB of disk for the build output, required a Rust toolchain, and added a layer I didn't need on top of a pipeline that already produced HTML. I retired the Tauri layer in favor of the HTML monitor + Chart.js. Same UI, no compile step, half the LOC.

**Test coverage on the PowerShell side earlier.** Pester tests exist, but they came late. A few regressions in the audit logic would have been caught by a smoke test against a known-good rig.

### Pattern that generalized

> Run the diagnostics. Attach plain-English explanations. Provide the rollback.

This shape — diagnosis tool that produces actionable findings with reversal commands — has shown up in my BI work since. It beats a dashboard that asks the viewer to be the analyst.

---

## 7. 2026 update — from optimizer to forensics

The original project optimized a system. The version running now investigates one.

Two incidents in May 2026 changed the shape of the tool. A boot-time hard freeze (no crash dump the first time) and a black-screen-at-6pm event both started as the wrong diagnosis. The freeze *felt* like an NVIDIA driver fault and turned out to be one — but only a dump decode confirmed it (`0x133_DPC_nvlddmkm`), and the path there wandered through audio drivers and DWM first. The 6pm black screen looked like a network drop and was actually CPU 0 DPC saturation. The pattern repeated often enough to name it: what a problem *feels* like and what it *is* sit in different subsystems, and the gap between them is where time gets lost.

So the project grew an evidence layer. Each subsystem now writes typed rows to an append-only timeline (`captures/evidence/*.jsonl`) — DPC spikes, network verdicts, faulting modules, and, deliberately, *absences* (a six-minute logging gap before a freeze is itself a clue). A correlator (`scripts/evidence_correlate.ps1`) reads the timeline and answers three questions across time: which faulting module keeps recurring, where symptom and cause diverged, and what the full event chain for a given incident was. The **Verdict view** in the monitor renders that — the first screen that states a conclusion instead of asking the viewer to derive one.

The Tauri desktop binary was retired in this same window (see the naming note in the README). It was scope creep on top of a pipeline that already produced HTML. The monitor's nine views — Heatmap through Verdict — cover what the desktop app did, from `file://`, with no build step.

Hardware footnote: the RTX 5070 Ti ran on the Microsoft Basic Display Adapter for part of this period after a DDU sweep, then a clean driver reinstall restored it. The procedure is written up in [docs/ddu-reinstall-plan.md](ddu-reinstall-plan.md).

---

## 8. References

| | |
|---|---|
| Repo | [github.com/Lcxiv/windows-latency-optimizer](https://github.com/Lcxiv/windows-latency-optimizer) |
| Findings doc | [docs/findings.md](findings.md) |
| Methodology | [docs/methodology.md](methodology.md) |
| Capture pipeline | [scripts/pipeline.ps1](../scripts/pipeline.ps1) |
| Monitor dashboard | [monitor/index.html](../monitor/index.html) |
| Audit modules | [scripts/audit-checks/](../scripts/audit-checks/) |
| Domain agents | [.claude/agents/](../.claude/agents/) |

---

*Built solo over six weeks of nights and weekends. The fix held. The rig stopped stuttering. The bigger payoff was the methodology — now reused on every Windows machine I touch.*
