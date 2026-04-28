---
tags: [research, chrome, defender, render, page-faults]
date: 2026-04-27
status: complete
aliases: [Chrome Render, Twitch Latency]
---

## Chrome Rendering Diagnostic Results (2026-04-27)

**Primary finding:** All 6 Chrome paths NOT in Defender exclusions. Page fault rate spiked to 454K/sec during Twitch navigation (normal: 30K/sec). Each fault traverses WdFilter.sys minifilter, adding latency to every Chrome file operation. Chrome User Data has 10K+ small files — fundamentally different I/O pattern from gaming.

**Secondary findings:**
- ShaderCache at 0.53 MB / 5 files — nearly empty, forces shader recompilation
- `hardware_acceleration_mode_previous: false` in Chrome Local State — may indicate HW accel instability
- MPO enabled + HAGS on — potential compositor overhead (single monitor though)

**Eliminated:**
- GPU P-state wake (stable P0, PerfLevelSrc working)
- DPC/interrupt (<1% total, nvlddmkm.sys well-distributed)
- DNS/TLS (YouTube <1ms, Twitch 4ms, TLS 1.3)
- PCIe (Gen5 x16 = max)
- Memory (17GB free)
- Multi-monitor (only 1 active display)
- GPU process startup (179ms)

**Fix applied (2026-04-27):** Full Defender disable via `scripts/disable_defender.ps1` — GPO registry + MpPreference + scheduled task suppression + boot persistence task `\LatencyGuard\LatencyGuard-DefenderDisable`.

**Post-disable results (pre-reboot, WdFilter.sys still loaded):**
| Metric | Baseline (Defender ON) | Post-Disable | Delta |
|--------|----------------------|-------------|-------|
| Page faults/sec avg | 177,979 | 60,892 | **-66%** |
| Page faults/sec peak | 681,742 | 672,383 | -1% |
| CPU % avg | 15.0% | 4.8% | **-68%** |
| CPU % peak | 42.7% | 19.5% | **-54%** |
| Context switches/sec avg | 71,260 | 17,139 | **-76%** |
| Memory min free | 16,296 MB | 19,436 MB | **+3,140 MB** |
| Chrome processes | 17 | 15 | -2 |
| Chrome memory final | 2,150 MB | 1,727 MB | **-423 MB** |

Note: WdFilter.sys minifilter still loaded in kernel — full improvement expected after reboot.

**Why:** Defender exclusion for Chrome was never added because EXP19 only covered Fortnite/Epic Games directories. User chose full disable over path exclusions.

**How to apply:** Rollback via `scripts/enable_defender.ps1`. Backup at `captures/backup_pre_defender_disable_20260427_105900.txt`.
