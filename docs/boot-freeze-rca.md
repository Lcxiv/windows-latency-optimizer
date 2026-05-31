# Root-Cause Analysis — Computer Froze on Last Boot Session

**Date of analysis:** 2026-05-30 (live, elevated)
**System under test:** DESKTOP-V5BN4SC — Ryzen 7 9800X3D · RTX 5070 Ti · Intel I226-V · Win11 build 26200 · 32 GB
**Verdict (one line):** Not a crash. A **hard system hang** at **10:19:55 on 2026-05-30**, sat dead ~2 h, cleared only by a manual hard reset at 12:20:43. No bugcheck, no dump, no hardware fault.

---

## 1. Method — independent sources, cross-confirmed

A freeze leaves no single authoritative log line, so findings are triangulated across multiple **independent** data sources. A cause is accepted only when **≥2 sources agree** (the "at least two tools" requirement). Sources used this run:

| # | Source / tool | Question it answers independently |
|---|---------------|-----------------------------------|
| 1 | Event Log — power lifecycle (6005/6006/6008/6013/1074, Kernel-Power 41) | Clean vs dirty shutdown; was it user-initiated? |
| 2 | Crash dumps (Minidump, MEMORY.DMP, WER 1001) + CrashControl | Did the kernel bugcheck? Is there a body to autopsy? |
| 3 | Reliability Monitor (`Win32_ReliabilityRecords`) | Independent OS rollup, different parser than source 1 |
| 4 | Diagnostics-Performance (100–110) | Slow/stuck boot perceived as a freeze? |
| 5 | WHEA-Logger + storage errors | Hardware/silicon/drive fault? |
| 6 | Service Control Manager (7000/7026/7031/7034) | Boot-time driver/service load failure? |
| 7 | Application Error/Hang (1000/1002) | Foreground app hang masquerading as system freeze? |

Collector: `scripts\boot_freeze_rca.ps1` (read-only). Tags below — `[OBSERVED]` = raw log fact, `[INFERENCE]` = reasoning.

---

## 2. Freeze timeline `[OBSERVED]`

| Time (local) | Event | Source |
|---|---|---|
| 05-29 15:41:04 | StartMenuExperienceHost initiates power-off — "Other (Unplanned)" (Id 1074) | EventLog |
| 05-30 **08:57:55** | Clean boot — Event Log service started (6005). **This is the session that later froze.** | EventLog |
| 05-30 **10:19:55** | **Last surviving timestamp. System stops responding here.** | derived from 6008 |
| 10:19:55 → 12:20:43 | **~2-hour dead gap. No events. No self-recovery.** | (silence) |
| 05-30 **12:20:43** | Cold boot (manual hard reset). | LastBootUpTime |
| 12:20:45 | Kernel-Power **41**, **BugcheckCode = 0**, PowerButtonTimestamp = 0, SleepInProgress = 0 | Kernel-Power |
| 12:20:54 | "Previous system shutdown at 10:19:55 AM on 5/30/2026 was **unexpected**" (6008) | EventLog |

Critically: **no Event 1074 between 08:57 and 12:20** → the 10:19:55 termination was **not** user- or app-initiated.

---

## 3. Evidence per source `[OBSERVED]`

| Source | Result | Reading |
|--------|--------|---------|
| **1 Power lifecycle** | KP41 + 6008 both name 10:19:55 unexpected. KP41 **BugcheckCode=0**. No 1074 in window. | Dirty stop, no software shutdown path, **no kernel bugcheck**. |
| **2 Dumps / bugcheck** | Newest minidump = **051126-4859-01.dmp (05-11)**. No 05-30 dump. No MEMORY.DMP. Only WER 1001 = the historical **0x133 from 05-11**. CrashDumpEnabled active, AutoReboot=1. | **No crash on 05-30.** If it had bugchecked, AutoReboot would have rebooted it and a dump would exist. Neither happened → **hard hang**, not BSOD. |
| **3 Reliability** | Critical record = the unexpected-shutdown for 05-30; nothing else abnormal in window. | Corroborates source 1 from an independent rollup. |
| **4 Boot perf** | No degradation/stuck-boot events for the 08:57 boot. | The boot itself was fine — the freeze came **mid-session ~10:19**, not during boot. |
| **5 WHEA / storage** | **Zero WHEA events in 14 days.** SN850X + 9100 PRO healthy. No disk 51/153 timeouts. | **No hardware fault** — CPU, memory-controller, PCIe, NVMe all clean. |
| **6 Driver/service** | No 7026/7031/7034 in the 08:57 session. | No boot-time driver wedged this session. |
| **7 App crash/hang** | No 1000/1002 in the freeze window. | Not an app hang. |

---

## 4. Confirmed contributing factors (≥2-source agreement)

| Factor | Independent confirmation | Strength |
|---|---|---|
| **Hard hang, not a bugcheck** | L1 (KP41 BugcheckCode=0, silence before 10:19:55) **+** L2 (no dump, no MEMORY.DMP, AutoReboot didn't fire) | **Strong** |
| **Unattended ~2 h hang → manual reset** | L1 (10:19:55→12:20:43 gap, unexpected-shutdown) **+** L2 (no auto-recovery artifact) | **Strong** |
| **NOT hardware** (CPU/mem/disk/thermal) — ruled out | L5 (WHEA clean, SMART healthy, no throttle) **+** L4 (boot healthy) | **Strong (negative)** |
| **NOT the prior project suspects** (0x133 DPC-watchdog / Hyper-V tax / half-applied DDU driver / VSOC EXPO) — ruled out for *this* event | L2 (no 0x133 on 05-30) **+** L5 (no WHEA) **+** boot-session driver state healthy | **Strong (negative)** |

---

## 5. Unconfirmed signal — single source `[INFERENCE]`

The only abnormality in the pre-silence window was a **maintenance burst**: a Store-app/WinAppRuntime update (~09:37), a VSS shadow-copy snapshot (~09:38), and **Defender real-time protection toggling OFF (~09:58)** followed by an SPP re-arm loop — consistent with a **Defender security-platform update applying** (KB-class platform swap was installed 05-29). A wedged security filter driver during a platform swap is a known soft-lock vector, **but there is no direct log evidence of WdFilter faulting**, so this stays a **suspect, not a verdict**. Single-source ⇒ does not meet the ≥2 bar.

---

## 6. Root-cause statement

**Primary (confirmed):** the 08:57:55 session **hung hard at 10:19:55** — the kernel stopped scheduling/logging without reaching the bugcheck path, so no dump was produced and Windows could not auto-reboot; the machine required a manual hard reset at 12:20:43.
**Trigger (suspected, unconfirmed):** a Defender security-platform / servicing maintenance burst immediately preceding the silence. Needs corroboration.
**Excluded with evidence:** kernel bugcheck, hardware fault (WHEA clean), storage fault, stuck-boot driver, app hang, and all four historical rig-specific suspects.

---

## 7. Remediation + rollback

| Pri | Action | Why | Rollback |
|---|---|---|---|
| **P1** | Enable full crash trigger so the **next** hang is diagnosable: set `CrashControl\CrashDumpEnabled=7`, `AutoReboot=0`, and optionally `CrashOnCtrlScroll=1` (force a dump from a hung machine via Ctrl+ScrollLock×2). | This hang produced **no dump** — without it the next one is also unrooted. | Restore prior CrashControl values; delete CrashOnCtrlScroll key. |
| **P2** | Corroborate the Defender suspect: read `Microsoft-Windows-Windows Defender/Operational` around 09:58 on 05-30; confirm platform-update timing. | Closes the only open hypothesis. | Read-only. |
| **P3** | **Do not** chase DDU 610.47 — live GPU driver is healthy. Leave Hyper-V/VSOC alone — both clean this session. | Avoid fixing what isn't broken. | n/a |
| **P4** | If hangs recur: `pipeline.ps1 -SkipWPR -DurationSec 5` for a fresh per-CPU DPC baseline; capture LiveKD/WPR during the next freeze. | Per-CPU DPC (not _Total) is the established catch method here. | n/a |
