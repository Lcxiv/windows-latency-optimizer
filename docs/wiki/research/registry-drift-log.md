---
tags: [research, registry, watchdog, defender, drift]
date: 2026-04-27
status: complete
aliases: [Registry Drift]
---

# Registry Drift Log

Daily watchdog analysis. Tracks registry changes that affect gaming latency.
Unstable keys (changed >1 time across boots) indicate OS/driver reset behavior.

## Daily Entries

### 2026-04-25

- **Snapshots total**: 4
- **Diffs total**: 2
- **Latest diff**: 3 change(s): defender_DisableRealtimeMonitoring, defender_ScanAvgCPULoadFactor, defender_ExclusionPathCount
- **Unstable keys** (3):
  - `defender_DisableRealtimeMonitoring` changed 2x (last: False)
  - `defender_ScanAvgCPULoadFactor` changed 2x (last: 5)
  - `defender_ExclusionPathCount` changed 2x (last: 14)
- **Verdict**: CLEAN (defender timing only)

### 2026-04-26

- **Snapshots total**: 7
- **Diffs total**: 4
- **Latest diff**: 3 change(s): defender_DisableRealtimeMonitoring, defender_ScanAvgCPULoadFactor, defender_ExclusionPathCount
- **Unstable keys** (3):
  - `defender_ScanAvgCPULoadFactor` changed 3x (last: <null>)
  - `defender_ExclusionPathCount` changed 3x (last: <null>)
  - `defender_DisableRealtimeMonitoring` changed 3x (last: <null>)
- **Verdict**: CLEAN (defender timing only)

### 2026-04-27

- **Snapshots total**: 10
- **Diffs total**: 5
- **Latest diff**: 3 change(s): defender_DisableRealtimeMonitoring, defender_ScanAvgCPULoadFactor, defender_ExclusionPathCount
- **Unstable keys** (3):
  - `defender_ScanAvgCPULoadFactor` changed 4x (last: 5)
  - `defender_ExclusionPathCount` changed 4x (last: 14)
  - `defender_DisableRealtimeMonitoring` changed 4x (last: True)
- **Verdict**: CLEAN (defender timing only)

