---
tags: [research, burst, performance, timer, dpc, gpu, nic]
date: 2026-04-27
status: active
aliases: [Burst Pattern Analysis, Burst Investigation, Bursty Behavior]
---

# Burst Pattern Analysis

Investigation into why an optimized Windows system still shows "bursty" behavior in Task Manager — processes spiking up, dropping to idle, and spiking again in repeating patterns.

## Key Finding

**Bursts are normal on power-optimized systems.** Modern CPUs sleep between work and wake in batches. The real question is: *which bursts are OS-inherent vs. unnecessary overhead?*

## 7 Sources of Burst Patterns

| # | Source | Frequency | Fixable? | Our Status |
|---|--------|-----------|----------|------------|
| 1 | **Timer coalescing** — Windows batches timer callbacks | 15.6ms multiples | Yes (powercfg) | Check with script |
| 2 | **CPU C-state transitions** — idle/wake cycles | Variable | Partially (BIOS) | Expected on 9800X3D |
| 3 | **WMI polling** — Winmgmt 3,425/sec + Afterburner | ~1s cycles | Afterburner adjustable | [[system-polling-storms]] |
| 4 | **GPU P-state transitions** — clock ramp DPCs | Variable | Yes (clock lock) | [[gpu-affinity-discovery]] |
| 5 | **NIC interrupt moderation** — I226-V batches packets | Traffic-dependent | Check ITR | IntMod=Disabled |
| 6 | **MMCSS scheduling** — background task windows | ~100ms | By design | Not fixable |
| 7 | **Task Manager artifact** — 1s refresh sampling | 1s | Use our script | Use `diagnose-burst-pattern.ps1` |

## Diagnostic Tool

`scripts/diagnose-burst-pattern.ps1` captures CPU, DPC, GPU, and NIC simultaneously at ~1s intervals:

```powershell
.\scripts\diagnose-burst-pattern.ps1 -DurationSec 30
.\scripts\diagnose-burst-pattern.ps1 -DurationSec 60 -Label gaming_test
```

Outputs:
- `burst_timeline.csv` — raw time series (all sources)
- `burst_analysis.json` — burstiness scores, peak detection, cross-correlation, root cause diagnosis

### Burstiness Score (CV)

Coefficient of variation: stdev / mean.

| Score | Meaning |
|-------|---------|
| < 0.3 | Smooth |
| 0.3 - 0.6 | Moderate |
| > 0.6 | Bursty — investigate |

## First Measurement (2026-04-27, idle desktop)

| Source | CV Score | Verdict | Notes |
|--------|---------|---------|-------|
| CPU% | 0.15 | Smooth | 11.7-16.6%, normal range |
| DPC% | 0.69 | **Bursty** | Spikes to 1.07% from 0.1% baseline |
| GPU Clock | 0.003 | Smooth | 2752-2775 MHz, rock stable at P0 |
| NIC Packets | 1.77 | **Very Bursty** | 955-packet bursts vs 11 baseline (~6.4s period) |
| Interrupts/sec | 0.06 | Smooth | 29K-35K steady |
| Context Switches | 0.07 | Smooth | 46K-58K steady |

**Primary burst sources: DPC batching + NIC packet bursts.**

## NIC Burst Pattern

Packet receive spikes of ~955 packets against baseline of ~11. Occurs roughly every 6-7 seconds. Likely causes:
- Background network activity (DNS, NTP, cloud sync)
- Chrome background connections
- ExitLag keepalive bursts

Investigation with pktmon:
```powershell
pktmon start --capture --pkt-size 128 --comp nics
# Wait 30 seconds
pktmon stop
pktmon etl2pcap pktmon.etl -o burst_capture.pcapng
```

## DPC Burst Pattern

DPC% spikes coincide with NIC packet bursts — DPCs are generated to process the incoming packet batch. This is interrupt moderation working as designed, but confirms network traffic as the burst trigger.

## Compared to Smooth State

The [[smooth-state-baseline]] (16:43 measurement) had 373/sec actionable I/O and 0% DPC. The difference: **active network connections** generate periodic packet bursts that cascade into DPC bursts.

## Root Cause Identified (2026-04-27, pktmon investigation)

**Two sources confirmed via pktmon packet capture (30s, 11,783 packets):**

### 1. ExitLag NDIS LightWeight Filter (`nt_ndextlag`)

ExitLag installs an NDIS filter driver that intercepts ALL network traffic even when not routing any game.

| Layer | Rx Packets (30s) | Overhead |
|-------|-------------------|----------|
| NIC Lower | 907 | baseline |
| NIC Upper | 1,375 | **+52%** |
| TCPIP | 2,649 | **+192%** |
| Drops | 466 | — |

Every received packet traverses 5-6 components: NIC → NIC Upper → WFP → ExitLag → TCPIP. Each generates a separate pktmon event, and ExitLag drops ~34% of packets it inspects.

**Fix:** `fix_exitlag_filter.ps1` — disable NDIS filter during idle, re-enable before gaming.

```powershell
.\scripts\fix_exitlag_filter.ps1            # Disable (daily use)
.\scripts\fix_exitlag_filter.ps1 -Enable    # Re-enable (before gaming)
.\scripts\fix_exitlag_filter.ps1 -Verify    # Disable + measure impact
```

### 2. Claude Code TCP connections

Claude Code maintains ~63 persistent TCP connections to Anthropic API (160.79.104.10:443). Multiple subprocesses each hold many connections. This is the primary traffic volume source — not fixable, but documented as known noise.

| Process | PID | TCP Connections |
|---------|-----|-----------------|
| claude | 14732 | 54 |
| claude | 6508 | 52 |
| claude | 4204 | 14 |
| claude | 15276 | 9 |

**Action:** Exclude from burst diagnostics as known noise (similar to CLI noise exclusion in ProcMon).

### Combined Effect

NIC burst pattern: ~955 packets every 6-7s against baseline of ~11. This cascades: packet burst → NIC interrupt batch → DPC spike → Task Manager visual "burst." With ExitLag filter disabled, NIC packet count drops ~52% and DPC bursts should proportionally decrease.

## Recommendations

1. **ExitLag filter**: Disable when not gaming via `fix_exitlag_filter.ps1` — eliminates 52% Rx overhead.
2. **DPC bursts**: Secondary to NIC. Fixing NIC source → DPC bursts decrease proportionally.
3. **optimize-game.ps1**: Auto-re-enables ExitLag filter before gaming (new Step 6).
4. **GPU**: Stable at P0. No action needed.
5. **CPU**: Smooth. C-state behavior is normal.

## Related

- [[smooth-state-baseline]] — Golden state at 373/sec actionable I/O
- [[system-polling-storms]] — 8 storms fixed (8,512 → 373/sec)
- [[gpu-affinity-discovery]] — RTX 5070 Ti DPC affinity
- [[performance-findings]] — 84% → 97% audit score
- [[ping-regression]] — NIC speed lock and related NIC issues
