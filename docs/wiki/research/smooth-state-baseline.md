---
tags: [research, baseline, smooth, polling, performance]
date: 2026-04-27
status: active
aliases: [Smooth State Baseline, Smooth Baseline, Golden State]
---

# Smooth State Baseline

User reported OS feeling "really smooth" at 16:43 on 2026-04-27. Forensic analysis of what made this state different.

## The Key Finding

Between **16:19:29** (last system event) and **16:43** (smooth report), the system logged **zero events** — no service changes, no errors, no tasks, no WHEA. This was the longest quiet window since boot at 13:04.

**Smoothness = absence of background activity.** All optimization storms had settled, Defender was off, no maintenance running.

## Timeline to Smooth

| Time | Event | Impact |
|------|-------|--------|
| 13:04 | Boot | |
| 13:02-13:28 | UPnP/SSDP registration churn | Normal post-boot |
| 13:40 | [[system-polling-storms\|Polling fixes]] applied | -5 storms |
| 14:10 | [[chrome-render-latency\|Defender OFF]] confirmed | -454K pagefaults/sec |
| 15:45 | **WSearch disabled** | -8,292 events/sec |
| 16:08 | **camsvc disabled** | -216 events/sec |
| 16:19 | **ShellHWDetection disabled** | Last SCM event |
| 16:19-16:43 | **24 min silence** | All optimizations settled |
| **16:43** | **"Feels smooth"** | |

## Performance Counters at Smooth State

| Counter | Value | Verdict |
|---------|-------|---------|
| CPU Total | 1.27% | Excellent |
| DPC Time (Total) | 0.02% | Excellent |
| DPC Time (CPU 0) | 0.00% | Fixed (was 97.7%) |
| Page Faults/sec | 4,069 | Normal (was 454K) |
| Available RAM | 22,523 MB | 70% free |
| Context Switches/sec | 5,519 | Normal |
| Disk Queue | 0 | No I/O pressure |
| Processor Queue | 0 | No CPU pressure |

## ProcMon Event Rate

| Process | Events/sec | Status |
|---------|-----------|--------|
| Winmgmt | 3,425 | Known unfixable |
| Explorer | 3,553 | Normal namespace enum |
| ctfmon | **0** | Eliminated |
| camsvc | **0** | Eliminated |
| SearchIndexer | **0** | Eliminated |
| **Actionable overhead** | **373/sec** | Minimal |

## Services Disabled (19)

WSearch, camsvc, lfsvc, DiagTrack, ShellHWDetection, wmiApSrv, CscService, ExitLagPmService, Razer services, RemoteAccess, RemoteRegistry, MsKeyboardFilter, others.

See [[system-polling-storms]] for full details.

## How to Reproduce

1. Apply all fixes: `fix_system_polling.ps1` + `disable_defender.ps1`
2. **Wait 20+ minutes post-boot** — Windows front-loads BITS, SPP licensing, UPnP in first 30-60 min
3. Verify with `analyze_procmon_idle.ps1`

The key variable is **time since boot**. The system reaches this minimal state only after all Windows maintenance settles.

## GPU State

P0 idle, 2587 MHz core, 32C, 55W. No P-state transitions = no DPC spikes.

## Related

- [[system-polling-storms]] — 8 storms fixed
- [[chrome-render-latency]] — Defender impact
- [[gpu-affinity-discovery]] — CPU 0 DPC fix
- [[performance-findings]] — 84% to 97% audit score
