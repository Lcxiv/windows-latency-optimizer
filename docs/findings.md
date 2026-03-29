# Latency Analysis Findings

**System:** DESKTOP-V5BN4SC | AMD Ryzen 7 9800X3D | 32 GB RAM | Windows 11 Build 26200
**Analysis date:** 2026-03-28

---

## LatencyMon Summary

**Result: PASS** — System is suitable for real-time audio and low-latency workloads.

| Metric | Value |
|---|---|
| Max interrupt → process latency | 178.80 µs |
| Avg interrupt → process latency | 10.26 µs |
| Max interrupt → DPC latency | 160.60 µs |
| Avg interrupt → DPC latency | 3.38 µs |
| Highest ISR execution time | 4.63 µs (Wdf01000.sys) |
| Highest DPC execution time | **561.60 µs** (ntoskrnl.exe, CPU 6) |
| Driver with most total DPC time | **nvlddmkm.sys** at 0.105% |
| Total time in DPCs | 0.193% |
| DPCs ≥ 500 µs | 6 of 247,013 |
| Hard pagefaults | 338 total (149 from msmpeng.exe) |

---

## CPU Interrupt Distribution

CPU 0 handles the vast majority of interrupt/DPC work:

| CPU | Interrupt Cycle (s) | DPC Count | Highest DPC (µs) |
|---|---|---|---|
| **CPU 0** | **7.82** | **241,319** | 281.3 |
| CPU 6 | 1.04 | 1,251 | **561.6** |
| CPU 5 | 0.93 | 816 | 332.4 |
| CPU 7 | 0.96 | 773 | 269.1 |
| CPU 4 | 0.89 | 1,959 | 340.6 |
| CPUs 1–3, 8–15 | < 0.85 each | < 325 each | < 52 each |

**Key observation:** CPU 0 carries 97.7% of all DPCs. CPUs 4–7 (physical cores 2–4 of the X3D die) see the highest NVIDIA driver DPC activity. CPUs 12–15 are lightly loaded (likely efficiency-mode or parked).

---

## Top Issues

### 1. Windows Defender (msmpeng.exe) — 149 hard pagefaults

Defender is the single largest source of hard page faults (44% of total). Each pagefault pauses the triggering process while Windows reads the faulted page from disk. During gaming, this manifests as micro-stutter.

**Mitigation:** Add game executable directories to Defender's exclusion list. Applied in Experiment 01 for Fortnite.

### 2. NVIDIA GPU driver DPC load (nvlddmkm.sys)

nvlddmkm.sys accounts for 0.105% of total CPU time in DPCs — the largest share of any driver. The highest single DPC on CPUs 4–7 ranges from 269–562 µs, likely from frame synchronization or interrupt coalescing.

**Mitigation options:**
- Keep NVIDIA drivers current (tested: v595.97)
- Enable Message Signaled Interrupts (MSI mode) via registry to reduce interrupt coalescing latency
- Consider pinning GPU IRQ away from CPU 0 using interrupt affinity tools

### 3. CPU 0 interrupt monopoly

All hardware interrupts default to CPU 0. This causes CPU 0 to burn 7.82 seconds in interrupt cycles during the 1:45 capture window while other cores sit mostly idle. For a gaming workload, this competes with the game's main thread if it runs on CPU 0.

**Mitigation options:**
- Use an IRQ affinity tool (e.g., `msconfig` or registry `IRQAffinity`) to spread network/audio interrupts to non-game cores
- Pin game executable to specific CPU affinity to avoid the interrupt-heavy CPU 0

---

## Experiment 01 — MMCSS + Network Throttling

**Date:** 2026-03-28 20:17

### Registry changes applied

```
HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile
  SystemResponsiveness:    20  →  0
  NetworkThrottlingIndex:  10  →  4294967295 (0xFFFFFFFF = disabled)

HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games
  Scheduling Category:  Medium  →  High
  Priority:             2       →  6
  SFIO Priority:        Normal  →  High

Windows Defender exclusions added:
  C:\Program Files\Epic Games\Fortnite
  C:\Program Files\Epic Games\Launcher
```

### Performance metrics: Before vs After

| Metric | Before | After | Delta |
|---|---|---|---|
| Available Memory (avg MB) | 27,903 | 27,931 | +28 MB |
| Memory Pages/sec (avg) | 9.89 | **0.00** | −100% |
| Disk avg sec/read | 0.0001 | 0.0000 | Improved |
| % DPC Time (avg) | 0.293% | 0.293% | No change |
| % Interrupt Time (avg) | 0.293% | **0.224%** | −0.069% |
| % Processor Time (avg) | 3.49% | 3.78% | +0.29% (noise) |
| Context Switches/sec | 19,964 | 20,475 | +511 |
| Processor Queue Length | 0 | 0 | Unchanged |

**Notable:** Memory paging dropped to zero in the AFTER capture. This likely reflects the system being more settled (warm caches) rather than a direct effect of registry changes. Interrupt time improved slightly (−23.5%), which may reflect the NetworkThrottlingIndex change.

---

## Next Steps

- [ ] Run LatencyMon under gaming load (Fortnite) for a post-optimization comparison
- [ ] Test CPU interrupt affinity — move NIC and audio IRQs off CPU 0
- [ ] Evaluate HPET disable (`bcdedit /set useplatformclock false`) — can reduce timer overhead on AMD systems
- [ ] Enable MSI mode for NVIDIA GPU (eliminates shared IRQ contention)
- [ ] Profile frame time variance in-game (CapFrameX or PresentMon) to correlate with DPC spikes
- [ ] Test with ULPS (Ultra Low Power State) disabled for NVIDIA GPU
