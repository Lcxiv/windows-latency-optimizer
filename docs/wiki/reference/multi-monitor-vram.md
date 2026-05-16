---
tags: [reference, gpu, vram, p-state, multi-monitor]
date: 2026-04-11
status: complete
aliases: [Multi-Monitor, VRAM P-State]
---

# Multi-Monitor VRAM P-State & Display Reference

## User's Display Setup
- Main: ASUS XG27ACDNG 2560x1440 @ 359Hz via DisplayPort
- Capture: AverMedia AVT GC570-D via DVI (HDMI internally)
- Mode: Extended (NOT cloned)
- GPU: RTX 5070 Ti, GDDR7, driver 591.86

## RTX 5070 Ti VRAM P-States
| Clock | P-State | Use |
|-------|---------|-----|
| 405 MHz | P8 | Deepest idle - causes wake-up stutter |
| 810 MHz | P5 | Stable idle - our floor via nvidia-smi |
| 7001 MHz | P3 | Mid state |
| 13801 MHz | P1 | Near-max |
| 14001 MHz | P0 | Full speed gaming |

## VRAM Clock Lock Commands
```batch
nvidia-smi -lmc 810,14001    # Lock VRAM floor at 810 MHz
nvidia-smi -rmc              # Reset to default (allows 405 MHz)
nvidia-smi -q -d SUPPORTED_CLOCKS  # List all valid clock steps
nvidia-smi --query-gpu=pstate,clocks.current.memory,power.draw --format=csv,noheader
```
Note: -lmc resets on reboot. Task Scheduler task "VRAM Clock Lock" runs vram-clock-lock.bat at logon with 30s delay.

## Clone Mode Dangers (NOT our current config, but documented)
- Forces BOTH outputs to the LOWER refresh rate
- Prevents Hardware: Independent Flip (DWM never sleeps)
- Disables G-Sync/VRR
- Every frame goes through DWM triple-buffer (+1-2 frames latency)

## Multi-Monitor Best Practices
- Extended mode, never clone for gaming
- Disable MPO: `HKLM\SOFTWARE\Microsoft\Windows\Dwm\OverlayTestMode = 5` (DWORD)
- Non-integer refresh ratios (360/144=2.5x) cause DWM frame pacing issues
- Integer ratios cleaner: 360/120=3x, 360/180=2x
- NVCP "Prefer Maximum Performance" fixes RTX 5070 Ti Bus Interface Load bug
- OBS Game Capture + NVENC is lower overhead than hardware capture card clone

## RTX 5070 Ti Known Issues
- Bus Interface Load stuck at 20-50% idle with PerfCap showing Power+VRel
- Fix: NVCP Prefer Maximum Performance
- Driver 576.02+ has most comprehensive 50-series display fixes
- nvidia-smi -lmc DOES work on consumer Blackwell (tested, confirmed)

## DisableDynamicPstate (Nuclear Option)
```
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000" /v "DisableDynamicPstate" /t REG_DWORD /d "1" /f
```
Forces P0 24/7, trades idle power for zero transition stutter. Only use if nvidia-smi -lmc is insufficient.
