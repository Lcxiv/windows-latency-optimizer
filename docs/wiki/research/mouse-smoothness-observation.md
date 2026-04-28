---
tags: [research, mouse, smoothness, mpo, windows-update]
date: 2026-04-25
status: complete
aliases: [Mouse Smoothness]
---

# Observation — Mouse smoother than usual at 1:06 PM PT 2026-04-25

## What changed since last boot (all applied this session, pre-reboot pending)

| Time | Change | Applied? |
|---|---|---|
| ~11:09 | CMOS reset → EXPO 1 defaults + disabled BT/WiFi/USB-Audio/IGPU | ✅ booted |
| ~11:30 | MPO disabled (OverlayTestMode=5) | ✅ live (no reboot needed for DWM) |
| ~11:31 | All system sounds muted (registry) | ✅ live |
| ~12:47 | NIC affinity moved from CPUs 6-7 → CPUs 8-9 | ⏳ pending reboot |
| ~12:47 | `bcdedit /set hypervisorlaunchtype off` | ⏳ pending reboot |
| ~12:47 | Registry watchdog baseline snapshot taken | ✅ |

## Most likely cause of improvement at 1:06 PM

**UPDATE 2026-04-25 14:00**: MPO disable REVERTED — caused Fortnite fullscreen-exclusive crash (flickering + loss of screen control). Known pattern from EXP11/EXP13. OverlayTestMode=5 is INCOMPATIBLE with Unreal Engine fullscreen-exclusive. DO NOT RE-APPLY.

Smoothness improvement at 1:06 PM now attributed to: **peripheral disable in BIOS** (BT/WiFi/USB-Audio/IGPU removed from interrupt routing) = fewer DPC sources competing with input device interrupts on CPUs 2-3. Also possibly hypervisor off + NIC affinity separation (pending reboot at that time, but may have contributed post-reboot).

## RCA (deep research 2026-04-25 14:30)

Primary cause: **Windows Update scan ended at 13:03** (3 min before observation). WU was actively scanning 12:59–13:03 (BITS + Office C2R downloads + MsMpEng integrity checks). When WU scan completed, CPU + disk + network background load dropped simultaneously. Combined with MPO-off cursor path improvement, system hit genuinely-idle-optimized state for first time since boot.

Evidence:
- WU event ID 26 at 13:03:02 — "found 13 updates" (scan complete)
- BITS stopped at 13:01:27 (auto → demand)
- Defender config change at 13:01:14 (ServiceStartStates 1→0)
- No new processes started 12:30–13:15
- No driver loads or power events in window

**Key insight**: inconsistent mouse feel across sessions = variable background task timing. WU scans, Defender updates, BITS transfers, Chrome Component Updater all run unpredictably. Registry watchdog catches config drift; need **background task load monitor** for the other half.

## NIC + hypervisor changes NOT yet active at time of observation

These required reboot. May have contributed to further improvement post-reboot.

## Correlation plan

After reboot, re-run `health-check.ps1` and compare:
- CPU 0 interrupt% (was 0.5% — should stay low)
- DPC% total (was 0.5% — may drop further)
- Input device interrupt latency via xperf dpcisr (if captured)

## Cross-refs
- `project_20260425_known_good_baseline.md` — voltage baseline at this BIOS state
- `project_dwm_mpo_ue_crash.md` — MPO disable caveat (Epic Launcher crash on fullscreen-exclusive launch)
- `reference_multimonitor_vram.md` — MPO + multi-monitor DWM behavior
