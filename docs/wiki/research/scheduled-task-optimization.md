---
tags: [scheduled-tasks, optimization, wpr, etw, gaming]
date: 2026-04-27
status: active
aliases: [Scheduled Task Optimization, Task Scheduler, scheduled-task-optimization]
---

# Scheduled Task Optimization

## Summary

Investigation of Windows scheduled tasks firing during gaming sessions. Found 212 enabled tasks, with several running on hourly or sub-hourly intervals causing CPU, disk I/O, and network spikes.

## Findings

### Task Inventory

- **212 enabled** tasks (Ready + Running + Queued)
- **49 disabled** tasks
- **9 high-impact** tasks identified for gaming optimization
- **2 stale** LatencyGuard tasks cleaned up

### High-Impact Tasks Disabled

| Task | Interval | Impact | Action |
|------|----------|--------|--------|
| Office Actions Server | PT1H | Background Office integration | Disabled |
| Office Automatic Updates 2.0 | Varies | Office update check | Disabled |
| UsageDataFlushing | Telemetry | Flushes experiment data to Microsoft | Disabled |
| UsageDataReceiver | Telemetry | Receives feature experiment data | Disabled |
| ReconcileFeatures | Telemetry | Reconciles feature experiment state | Disabled |
| RefreshCache (OneSettings) | PT6H4M | Feature experiment cache | Disabled |
| QueueReporting (WER) | PT4H | Crash report upload | Disabled |
| PcaPatchDbTask | PT12H | Compat DB patch | Disabled |

### Protected Task (Cannot Disable)

| Task | Interval | Status |
|------|----------|--------|
| UpdateOrchestrator\Schedule Scan | PT6H | Access Denied (Windows-protected). Mitigated by custom `LatencyOptimizer-WU-4AM-Scan` task. |

### Not Found on System

- MicrosoftEdgeUpdateTaskMachineUA/Core — Edge not installed
- WindowsAI\PolicyConfiguration — Recall task already removed

### Stale Tasks Removed

- `LatencyGuard_RegistryWatchdog` — Superseded by `LatencyOptimizer-RegistryWatchdog`
- `LatencyGuard_BootInventory` — Never ran, superseded

### Already Optimized (Pre-existing)

ScheduledDefrag, CEIP Consolidator, MapsUpdateTask, 3/4 Defender tasks, VRAM Clock Lock, Recall InitialConfiguration.

## WPR Task + GPU Tracing

### Custom WPR Profile: `task-scheduler.wprp`

Superset of `input-latency.wprp` with 12 ETW providers covering the full stack:

**GPU Pipeline (9 providers):**
- DxgKrnl — GPU scheduling, present/flip queue, P-state transitions
- DXGI — Swap chain / present events
- D3D11 + D3D12 — Direct3D API calls
- DWM Core — Composition timing
- Win32k — Input-to-render pipeline
- HIDCLASS + USBHUB3 — Input devices
- NVIDIA External — Clock ramps, Reflex markers

**Task/System (3 providers):**
- Microsoft-Windows-TaskScheduler — Task start/complete/trigger events
- Microsoft-Windows-Kernel-Process — Process create/exit
- Microsoft-Windows-Services — Service start/stop

**System Keywords (12):**
ProcessThread, Loader, DPC, Interrupt, CSwitch, ReadyThread, SampledProfile, **Power, IdleStates, Timer, DiskIO, DiskIOInitialization**

### Capture Workflow

```powershell
# Start capture
wpr -start .\scripts\task-scheduler.wprp -filemode

# Optional: stack with built-in GPU profile for maximum coverage
wpr -start .\scripts\task-scheduler.wprp -start GPU.Verbose -filemode

# Play game for 2-5 minutes
# Stop capture
wpr -stop captures\task_trace.etl "Task+GPU gaming trace"

# Automated analysis
.\scripts\analyze-task-trace.ps1 -EtlFile captures\task_trace.etl

# Or open in WPA for visual analysis
wpa.exe captures\task_trace.etl
```

### WPA Analysis Tips

1. **Generic Events** tab > Filter by `Microsoft-Windows-TaskScheduler`
2. Each task fire shows Event 100 (Started) → 102 (Completed)
3. Cross-reference timestamps with:
   - **GPU Scheduling** timeline (frame drops during task execution)
   - **DPC/ISR** tab (driver overhead spikes)
   - **Disk I/O** tab (task-triggered reads/writes)
   - **CPU Usage (Precise)** (per-process CPU cost)

## Scripts

| Script | Purpose |
|--------|---------|
| [[catalog#fix_scheduled_tasks.ps1]] | Disable/restore gaming-impacting tasks |
| [[catalog#analyze-task-trace.ps1]] | ETL task + GPU correlation analysis |
| `task-scheduler.wprp` | WPR profile with Task Scheduler + GPU ETW |

## Related

- [[burst-pattern-analysis]] — Burst patterns partially caused by periodic task execution
- [[system-polling-storms]] — Service polling (different from task scheduling)
- [[driver-health-audit]] — Driver health investigation (same session)
- [[smooth-state-baseline]] — Target smooth state reference
