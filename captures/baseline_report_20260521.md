# Baseline Analysis — 2026-05-21 11:16 PT

**System under test:** AMD Ryzen 7 9800X3D · RTX 5070 Ti (driver 596.36) · 32 GB DDR5-6000 · I226-V 2.5GbE · Win 11 Build 26200
**Context:** Avro media removed. Gaming PC sole role. Fortnite running during capture (in-game baseline per user request).
**Project:** [windows-latency-optimizer](C:\Users\L\Desktop\windows-latency-optimizer)
**Audit HTML:** [audit_20260521_111541.html](C:\Users\L\Desktop\windows-latency-optimizer\captures\audits\audit_20260521_111541.html)
**Baseline txt:** [os_baseline_POST_AVRO_REMOVAL_20260521_111621.txt](C:\Users\L\Desktop\windows-latency-optimizer\captures\os_baseline_POST_AVRO_REMOVAL_20260521_111621.txt)

---

## Verdict

| Layer | State | Trend vs 04-25 |
|---|---|---|
| Hardware | ✅ Clean (0 WHEA in 7d, GPU Gen5 x16, NIC 2.5G connected) | Same |
| OS tuning | ✅ 91% audit score (41/45 pass) | First measurement |
| **Network stability** | ❌ **216 link-downs in 30d** (vs 130 prior) | **Accelerating regression** |
| Crash history | ⚠️ 1× DPC_WATCHDOG_VIOLATION on 5/11 | New since 04-25 |
| Background load | ⚠️ 28% idle CPU (Fortnite + 3 Claude + Discord + Wispr + ExitLag + Epic) | Heavier than baseline |

---

## Connections Check (post-Avro removal)

| Device | Status | Notes |
|---|---|---|
| Monitor (XG27ACDNG) | ✅ 2560×1440 @ 359Hz | Detected via CIM. EDID-preferred mode reads 60Hz — false alarm. |
| GPU | ✅ Gen5 x16, P0, 2820/17001 MHz, 39°C | Healthy under Fortnite load |
| NIC (I226-V) | ⚠️ 2.5 Gbps, 0 packet errors but **216 link-downs/30d** | Link instability, not data corruption |
| Mouse (Razer Viper V3 Pro) | ✅ Present, OK | Two instances enumerated (normal for Viper V3 wireless+dongle) |
| Headset (BlackShark V3 Pro) | ✅ Present (Game + Chat endpoints) | |
| Mic (JLAB TALK) | ✅ Present | Possibly residual from Avro setup — verify needed |
| Audio (Realtek USB2.0) | ✅ Present | DAC/monitoring |
| HDMI audio (XG27ACDNG) | ✅ Present | Monitor speakers |
| USB controllers | ✅ 4 AMD xHCI + 5 root hubs all OK | |

**Avro removal confirmed:** No Avro media devices enumerated. JLAB TALK + Realtek USB still in audio stack — check if intentionally kept.

---

## Audit Warnings (4 WARN, 0 FAIL)

| Severity | Check | Current | Fix |
|---|---|---|---|
| HIGH | NIC SpeedDuplex | Auto-neg 2.5G | `Set-NetAdapterAdvancedProperty -Name "Ethernet" -RegistryKeyword "*SpeedDuplex" -RegistryValue 6` (force 1G Full) — **deferred until Fortnite closed** |
| MED | Discord overlay running | PID present | Close before competitive matches |
| MED | EAC EOS running | Kernel callbacks active | Awareness only — see [eac_sxs_investigation_findings.md](C:\Users\L\.claude\projects\C--Users-L-Desktop-windows-latency-optimizer\memory\eac_sxs_investigation_findings.md) |
| MED | NVIDIA PerfLevelSrc | `0x3322` | Set to `0x2222` Max Performance |

## Skipped
- Bufferbloat: SKIP — needs `pipeline.ps1` run with load test

---

## Performance Counters (10s, in-game)

| Counter | Value | Target | Verdict |
|---|---|---|---|
| `processor(_total)\% dpc time` | 0.55% | <1% | ✅ |
| `processor(_total)\% interrupt time` | 1.46% | <2% | ✅ |
| `processor(_total)\% processor time` | 28.4% | n/a (in-game) | ⚠️ background |
| `system\context switches/sec` | 144,765 | varies | ⚠️ high |
| `memory\available mbytes` | 13,938 (~14 GB free) | >4 GB | ✅ |
| `memory\pages/sec` | 8.8 | <100 | ✅ |
| Disk avg sec/read | 0.2 ms | <10 ms | ✅ |

---

## Crash + Power History

| Class | Count (30d) | Last | Note |
|---|---|---|---|
| WHEA-Logger | 0 (7d) | n/a | Hardware clean |
| Kernel-Power **41** (unexpected shutdown) | 2 | 5/11 9:15 AM + 10:38 AM | **5/11 9:15: Bugcheck 0x133 DPC_WATCHDOG_VIOLATION** |
| Kernel-Power 109 (modern-standby wake) | 110 | 5/20 3:10 PM | Normal noise, but high count = frequent sleep cycles |
| Event 1074 (user restart) | 3 in last 24h (5/20) | 5/20 3:10 PM | Possibly rage-quit reboots per memory pattern |
| I226-V link-down (Event 27) | **216** | **5/21 8:42 AM** | **Worse than prior 130/30d. Last drop: this morning.** |

### DPC_WATCHDOG_VIOLATION (0x133) on 2026-05-11 09:15
Kernel hung on a DPC for >100ms = hard latency event. Suspects: EAC minifilter (memory:`eac_sxs_investigation_findings.md`), NVIDIA driver, I226-V driver. Recommend WPR latency profile next time it happens.

---

## Top CPU Consumers (in-game)

| Process | PID | CPU(s) | RAM (MB) | Threads |
|---|---|---|---|---|
| FortniteClient-Win64-Shipping | 18484 | 3641 | 4651 | 135 |
| System | 4 | 808 | 22 | 267 |
| dwm | 1648 | 448 | 115 | 108 |
| claude | 8284 | 125 | 706 | 34 |
| claude | 17368 | 117 | 324 | 75 |
| EpicGamesLauncher | 10512 | 93 | 269 | 116 |
| audiodg | 8312 | 60 | 18 | 6 |
| Wispr Flow | 7408 | 47 | 228 | 52 |
| Discord | 2756 | 46 | 570 | 62 |
| ExitLag | 21224 | (in GPU users) | — | — |

3× Claude processes + Wispr + Discord + ExitLag during a Fortnite session = significant background pressure. Memory documents Claude subprocess leak (`project_20260423_rca_gpu_affinity.md`).

---

## Registry Spot-Check

| Setting | Value | Expected | Verdict |
|---|---|---|---|
| `PerfLevelSrc` | `0x3322` | `0x2222` (Max Perf) | ⚠️ Fix |
| `HwSchMode` | `2` | `2` (HAGS on) | ✅ |
| `OverlayTestMode` | (missing) | (missing) | ✅ Correct per [project_dwm_mpo_ue_crash.md](C:\Users\L\.claude\projects\C--Users-L-Desktop-windows-latency-optimizer\memory\project_dwm_mpo_ue_crash.md) |
| `Win32PrioritySeparation` | 38 | 38 (0x26) | ✅ |
| `SystemResponsiveness` | 0 | 0 | ✅ |
| MMCSS Games Priority | 6 | 6 | ✅ |

---

## Tool Regression Found

`scripts/audit.ps1` called `Invoke-DriverHealthChecks` + `Invoke-DeepOptimizeChecks` — both lost in refactor commit `9eabc64` ("code quality sweep — split monoliths"). Functions exist in `10d3481` (`audit-checks.ps1` monolith before split). Patched audit.ps1 with `Get-Command` guards so audit runs today; full restore needed in follow-up.

Original source: `git show 10d3481 -- scripts/audit-checks.ps1` (functions start at line 1624+).

---

## Recommended Actions

### Now (no game disruption)
1. Set `PerfLevelSrc = 0x2222` (NVIDIA max perf, no reboot needed) — fix the audit WARN.
2. Start HWiNFO64 in background so future baselines have voltage/temp deltas vs 04-25.
3. Investigate why 3 Claude processes are running — close stale ones.

### After Fortnite session closes
4. Force I226-V to 1G Full Duplex (`Set-NetAdapterAdvancedProperty ... -RegistryValue 6`) — accelerating link-drop trend warrants this now.
5. Reboot, then re-baseline against clean idle state for direct 04-25 comparison.

### Investigation needed
6. **DPC_WATCHDOG_VIOLATION on 5/11** — run `wpr -start GeneralProfile -start CPU -start Network` next time machine feels janky to capture the DPC stack.
7. **216 link-downs accelerating** — escalate beyond NIC tweak. Suspects in priority order: eero 7 firmware (memory:`project_i226v_eero_drops.md`), CAT5 cable damage post-Avro-removal physical work, switch port. Test: swap port on eero, watch for 24h.
8. Restore the lost audit checks (`Invoke-DriverHealthChecks`, `Invoke-DeepOptimizeChecks`) from `10d3481` into new modules under `scripts/audit-checks/`.

---

## Files

| Path | Size | Purpose |
|---|---|---|
| [C:\Users\L\Desktop\windows-latency-optimizer\captures\audits\audit_20260521_111541.json](C:\Users\L\Desktop\windows-latency-optimizer\captures\audits\audit_20260521_111541.json) | — | Audit raw data |
| [C:\Users\L\Desktop\windows-latency-optimizer\captures\audits\audit_20260521_111541.html](C:\Users\L\Desktop\windows-latency-optimizer\captures\audits\audit_20260521_111541.html) | — | Audit HTML report (auto-opened) |
| [C:\Users\L\Desktop\windows-latency-optimizer\captures\os_baseline_POST_AVRO_REMOVAL_20260521_111621.txt](C:\Users\L\Desktop\windows-latency-optimizer\captures\os_baseline_POST_AVRO_REMOVAL_20260521_111621.txt) | — | Perf counter snapshot |
| [C:\Users\L\Desktop\windows-latency-optimizer\captures\baseline_report_20260521.md](C:\Users\L\Desktop\windows-latency-optimizer\captures\baseline_report_20260521.md) | — | This report |
