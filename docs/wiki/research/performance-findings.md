---
tags: [research, performance, dpc, defender, measurements]
date: 2026-04-23
status: complete
aliases: [Performance Findings]
---

## System Under Test
- AMD Ryzen 7 9800X3D (8C/16T), NVIDIA RTX 5070 Ti, Intel I226-V, 32GB @ 6000 MT/s
- Windows 11 Build 26200, KB5079473 installed

## Audit Score Progression
- Initial: 84% (16 pass, 3 warn) — GPU misdetected, Power Plan GUID mismatch
- After GPU/Power fix: 95% (18 pass, 1 warn)
- After EXP15 mitigations: 97% (36 pass, 1 warn — mouse polling only)
- 2026-04-23 post-reboot deep-test: 87% (regression from 97%; likely due to missing GPU affinity override — see project_20260423_rca_gpu_affinity.md)

## EXP15 Mitigation Results (before → after)

| Metric | Before | After | Delta |
|--------|--------|-------|-------|
| ProcMon event rate | 21,671/s | 9,737/s | **-55%** |
| Defender events | 36,951 | 12,945 | **-65%** |
| Frame P99 | 36.8ms | 5.45ms | **-85%** |
| Stutters (idle) | 70 → 24 (filtered) | 16 | **-33%** |
| CPU 0 share | 1.9% | 0% | **Perfect** |
| GPU/NIC topology | 87% | 94.4% | Better isolation |

## What Causes Latency (ranked by measured impact)

### HIGH IMPACT
1. **Defender real-time scanning** — 37K events/10s at idle. CatRoot scanning (13K) is unavoidable but game folder exclusions cut 65%
2. **RTX 5070 Ti idle bus load** — 20% PCIe bus interface load from power state transitions. PerfLevelSrc=0x2222 fixes it
3. **LwtNetLog autologger** — Reportedly 5-15% CPU reduction when disabled

### MEDIUM IMPACT
4. **DWM idle gaps** — P99 frame time 36.8ms at idle is DWM sleeping, not stutter. Disappears during gaming (Independent Flip)
5. **KB5079473 FSO scheduling** — Rhythmic stutter on Build 26200. FSO disable per-game is the only mitigation

### LOW/NONE IMPACT
6. **NAME NOT FOUND errors (36K/10s)** — Normal Windows DLL/registry probing. Sub-microsecond per lookup. No action needed.
7. **WBEM Tracing reads (23K/10s)** — In-memory registry reads, negligible CPU cost

## Key Diagnostic Discovery: DPC Parser Was Broken
The existing xperf DPC/ISR parser in pipeline-helpers.ps1 looked for "DPC Module Summary" headers that don't exist in xperf output. Every experiment.json had empty dpcDrivers arrays. The actual format is per-module histograms: "Total = N for module X.sys".

## Pending: Gaming Capture
All measurements are from idle desktop. Real stutter diagnosis needs gameplay capture to validate:
- Frame time distribution under GPU load
- DPC spikes during texture streaming
- Defender interference with shader cache reads
- EAC kernel callback overhead

## 2026-04-22/23 Addendum — GPU Contention + Missing GPU Affinity

**Mouse stutter 2026-04-22 16:09 PT** — root cause: Remotion render on `fortnite-highlights/` at `--concurrency=8` saturated GPU (`chrome-headless-shell` logged `GpuControl.CreateCommandBuffer TransientFailure`). DWM cursor compositor starved. Concurrent Claude Code subprocess leak (102 node, 9 claude CLIs) added commit pressure.

**P2 fix:** `RENDER.bat` + `package.json`: `--concurrency=8` → `--concurrency=4`. Validated 3× (0 TransientFailure across 180f, 600f, 300f-at-99%-commit tests).

**NEW finding 2026-04-23:** RTX 5070 Ti (`VEN_10DE&DEV_2C05`) has NO interrupt affinity registry override. Other devices (AMD USB CPUs 2,3; NVIDIA HDA CPU 6; Intel NIC CPUs 6,7) all set correctly. GPU defaults to CPU 0.

### Deep-test 2026-04-23 per-CPU DPC (120-sec capture)

| Metric | Value |
|---|---|
| CPU 0 DPC time | 56.1 sec / 120 sec = **46.8%** (!!) |
| CPU 0 share of total DPC | **82.5%** |
| `nvlddmkm.sys` total | 22.4 sec, all on CPU 0 |
| `dxgkrnl.sys` total | 33.8 sec, all on CPU 0 |
| _Total DPC aggregate | 0.59% (misleadingly healthy) |
| Mouse input gaps in 30s | 121 (longest 974 ms) |
| DWM P99 frame | 144 ms |
| Pester suite | 659/659 green |

**Regression vs EXP15 baseline:** CPU 0 share went from "0% Perfect" to 46.8%. Cause: earlier `SET_GPU_AFFINITY` experiment likely targeted old RTX 4090 device ID; not re-applied when RTX 5070 Ti installed.

### Methodology insight: `_Total` DPC hides per-CPU saturation

`_Total` aggregate divides DPC time across 16 CPUs. 46.8% on CPU 0 looks like 0.59% when aggregated. **Pipeline must record `\Processor(N)\% DPC Time` for each CPU 0-15 separately.** See `docs/next-experiments.md` EXP_PER_CPU_DPC_PIPELINE.

### Pending fix: EXP_GPU_AFFINITY_FIX

Set RTX 5070 Ti affinity to mask 0xF0 (CPUs 4-7) — project GPU/bulk group per topology. Registry path + exact commands in `docs/next-experiments.md`. Reboot required to activate.
