---
tags: [research, gpu, affinity, dpc, cpu-topology, rca]
date: 2026-04-23
status: complete
aliases: [GPU Affinity, RTX 5070 Ti DPC]
---

## Timeline

- **2026-04-22 16:09 PT** — User reported mouse went from stuttery to smooth "suddenly"
- **2026-04-22 16:10-16:40** — Investigation + P2 fix applied + validated (twice)
- **2026-04-23 07:34** — System rebooted
- **2026-04-23 08:00-09:05** — Post-reboot verification + full deep-test + new GPU affinity finding

## Root cause: mouse stutter at 16:09

**Proximate trigger** — `chrome-headless-shell` (from Remotion render in `fortnite-highlights/`) logged at 16:09:05.807:
```
[ERROR:gpu\ipc\client\command_buffer_proxy_impl.cc:128]
ContextResult::kTransientFailure: Failed to send GpuControl.CreateCommandBuffer
```

GPU was saturated by Remotion render at `--concurrency=8`. DWM (cursor compositor) starved → cursor stuttered. When webpack bundle finished + before headless Chrome ramped up, brief lull let DWM catch up → smooth.

**Contributing factors:**
- 102 node.exe Claude-agent subprocesses (known leak bug)
- 9 claude.exe sessions
- Commit at ~62%, would peak ~90% during render
- Concurrent Vite/Astro build on `Website/portfolio/`

## P2 fix (applied + validated)

Changed `fortnite-highlights/RENDER.bat` and `package.json`:
- `--concurrency=8` → `--concurrency=4`

**Validation evidence:**
- 180-frame test: `out/validate-p2.mp4` 1.2 MB, **0 TransientFailure**
- 600-frame test with live sampling: GPU peak 60%, DPC 0.20-1.56%, **0 TransientFailure**
- Today's 300-frame test at 99.1% commit pressure: still **0 TransientFailure**, GPU peak only 23% (memory-bound not GPU-bound under stress)

## NEW discovery: missing RTX 5070 Ti interrupt affinity

On 2026-04-23 09:00 `analyze-dpc-deep.ps1` revealed:
- **CPU 0 eating 82.5% of total DPC time** (56.1 sec / 120 sec capture)
- `nvlddmkm.sys` 22.4 sec + `dxgkrnl.sys` 33.8 sec (two entries) all on CPU 0

**Registry check:** RTX 5070 Ti `VEN_10DE&DEV_2C05` has **no `Affinity Policy`** under `Device Parameters\Interrupt Management\`. All other devices have correct masks:

| Device | Mask | Target |
|---|---|---|
| AMD USB (VEN_1022) | `12,0` | CPUs 2,3 (input) ✓ |
| NVIDIA HDA (VEN_10DE&DEV_22E9) | `64,0` | CPU 6 (audio) ✓ |
| Intel NIC I226-V | `192,0,0,0,0,0,0,0` | CPUs 6,7 ✓ |
| **RTX 5070 Ti (VEN_10DE&DEV_2C05)** | **empty** | **defaults to CPU 0** ✗ |

Per project MEMORY.md `project_performance_findings.md` EXP15: "CPU 0 share 1.9% → 0% Perfect". Today CPU 0 is at 46.8% DPC time — regression. Likely the earlier `SET_GPU_AFFINITY` experiment targeted RTX 4090 device ID; not re-applied when RTX 5070 Ti was installed.

## Fix

Packaged as `scripts/set_gpu_affinity.ps1` (commit 2f36c45, branch `claude/gpu-affinity-fix-20260423`). Writes `DevicePolicy=3` + `AssignmentSetOverride=0xF0 0x00` (CPUs 4-7) to RTX 5070 Ti's Affinity Policy key. Has `-WhatIf` + `-Rollback` + auto-backup.

Mask `0xF0` = CPUs 4-7 = project's GPU/NIC/bulk DPC group.

## Fix validation (2026-04-23 10:15)

Capture `captures/experiments/20260423_100433_GPU_AFFINITY_POST/` under Prime95 SmallFFT + 512 MB disk burn (matches `BASELINE_POST_REBOOT_CLEAN_20260422-100418` workload). Commit 62e8bde.

Registry check: `analyze_affinity_overlap.ps1` confirms `GPU (nvlddmkm) : Policy=3 -> CPUs 4,5,6,7 (mask 0xF0)`.

Per-CPU DPC delta:

| CPU group       | Pre-fix abs DPC | Post-fix abs DPC | Factor |
|-----------------|-----------------|------------------|--------|
| CPU 0 preferred | 46.80 %         | **0.03 %**       | ~1560× |
| CPUs 4-7 GPU    | ~0              | 11.80 % total    | target |
| Total DPC       | ~56 %           | 0.78 %           | 71×    |

Caveats:
- `xperf` analysis failed on 10.3 GB `trace.etl` (`33365 Events were lost`). Driver-level attribution still relies on aggregate Get-Counter `cpuData`; shrink WPR buffer set or chunk captures in future runs.
- Prime95 SmallFFT is CPU-heavy; GPU driver DPC rate is naturally low during this workload. Real-world benefit under GPU-active loads (games, Remotion) still needs confirmation. Follow-up: `EXP_REMOTION_ISOLATION` queued in `docs/next-experiments.md`.
- `analysis.txt` CPU-group labels are off-by-one (cosmetic formatter bug). Raw `cpuData` in `experiment.json` is correct.

## Methodology insight

`_Total` DPC aggregate HIDES per-CPU saturation. Today's `_Total` was 0.59% — looks healthy. Per-CPU revealed CPU 0 at 46.8%. **Pipeline must record per-CPU DPC 0-15 as separate series.**

## Real-world stutter reproduction (2026-04-23)

`diagnose-mouse.ps1 -DurationSec 30` under 23 claude + 144 node load:
- 121 input gaps > 4ms
- Longest gap: **974 ms**
- DWM P99 frame: **144 ms**
- Top DPC correlation: `ntoskrnl.exe` 256 μs peaks

Same stutter class as yesterday's 16:09 event — still reproducing.

## Ruled out (both days)

- PnP device re-enumeration (Razer wired stable since 13:49 yesterday)
- Thermal throttling (CPU at 4700 MHz base, no throttle events)
- Sleep/wake (powercfg /lastwake = 0 entries)
- Defender scan (only healthy-status pings)
- Razer Synapse (services Stopped/Disabled, confirmed both days)
- Windows Update driver install (no events in window)
- Memory compression (actually HELPING — saved system at 99.1% commit)
- Core isolation / MPO (project already has correct state)
- NIC disconnect warning (`e2fnexpress`) — unrelated to mouse/GPU
- Game Mode (AutoGameModeEnabled=1, intact)

## Research-backed context

- **Claude Code subprocess leak confirmed as upstream bug** — Issues #11502, #32792, #13126, #15423
- **Windows routes ISRs to CPU 0 by default** — Microsoft docs + guru3D confirmation. Registry override is only reliable fix.
- **Job Object + `JOB_OBJECT_LIMIT_AFFINITY`** propagates to child processes (including Chrome-headless from Remotion)
- **Memory compression should stay enabled** on 32 GB systems with heavy concurrent Node builds (saved system at 99.1% commit this week)

## References

- `C:\Users\L\.claude\plans\mouse-smooth-at-1609-rootcause-20260422.md` — 2026-04-22 RCA
- `C:\Users\L\.claude\plans\p2-validation-evidence-20260422.md` — P2 validation
- `C:\Users\L\.claude\plans\p2-postreboot-verification-20260423.md` — post-reboot diff
- `C:\Users\L\.claude\plans\deep-research-latency-optimization-20260423.md` — literature report (20 cited sources)
- `C:\Users\L\.claude\plans\deep-test-report-20260423.md` — deep-test full report
- `captures/experiments/20260423_085432_DEEP_TEST_20260423/` — raw WPR + dpcisr_report + dpc_deep_analysis.json
