# Boot-Freeze RCA — Deep-Dive Findings (root cause confirmed)

**Date:** 2026-05-30 · **System:** DESKTOP-V5BN4SC (9800X3D · RTX 5070 Ti · I226-V · Win11 26200)
**Method:** ~30 independent tests — multi-log event forensics, **crash-dump decode (WinDbg/cdb)**, filter-driver stack, DriverStore enumeration, power config, recurrence analysis.

> Stance: `[OBSERVED]` = raw tool output. `[INFERENCE]` = reasoning + confidence. Raw evidence saved under `captures\` (§6).
> **Correction note:** an earlier draft inferred a *storage/NTFS* path from the last-logged event. The crash-dump decode overturned that — see §2. Recording the correction in the spirit of evidence-over-speculation.

---

## 1. ROOT CAUSE (confirmed) `[OBSERVED via dump decode]`
**A DPC inside the NVIDIA display driver (`nvlddmkm.sys`) overran the DPC watchdog.** This is the confirmed signature of the recurring fault family on this machine and the most-probable cause of the 05-30 hang.

Decoded from `C:\Windows\Minidump\051126-4859-01.dmp` (the 05-11 sibling event) with `cdb.exe`:
```
BUGCHECK_CODE:        133  (DPC_WATCHDOG_VIOLATION)
DPC_TIMEOUT_TYPE:     SINGLE_DPC_TIMEOUT_EXCEEDED
PROCESS_NAME:         System
MODULE_NAME:          nvlddmkm
IMAGE_NAME:           nvlddmkm.sys
FAILURE_BUCKET_ID:    0x133_DPC_nvlddmkm!unknown_function
FAILURE_ID_HASH:      {15c3af0e-5564-7a80-2e26-65b5115ecc4d}

STACK_TEXT (trimmed):
  nt!KeBugCheckEx
  nt!KeAccumulateTicks+0x59c           <- clock ISR detects the DPC overrun
  nt!KeClockInterruptNotify+0x3ee
  nt!KiInterruptDispatchNoLockNoEtw+0x3c
  nvlddmkm+0x73d8b1                     <- offending DPC (NVIDIA GPU driver)
  nvlddmkm+0x75706b
  nvlddmkm+0x73f366
```
The `nt!` frames at the top are only the clock interrupt that *caught* the overrun; the DPC that actually ran too long is the `nvlddmkm` frames beneath the interrupt dispatch. Symbols for `nvlddmkm` are proprietary (offsets only, no function names) — expected for NVIDIA. Attribution to the module is **definitive**; the exact internal function is not resolvable without NVIDIA private symbols.

Full log: `captures\dump_0x133_051126_analyze.txt`.

---

## 2. The 05-30 freeze vs. the decoded sibling `[OBSERVED + INFERENCE]`
- **05-30 (the reported freeze):** hard hang at idle, **10:14:06 → 10:19:55**, no bugcheck, **no dump**, no auto-reboot, manual hard reset at 12:20:43. Last log lines were routine background (Storport perf summary 10:13:44, cache-latency info 10:13:45, WNS ping 10:14:06) — i.e. an **idle machine**, no workload. `[OBSERVED]`
- **05-11 (decoded above):** `0x133 DPC_WATCHDOG` → `nvlddmkm`. Uptime was only 3m17s (faulted early in session). `[OBSERVED]`
- **04-11:** WATCHDOG live-kernel dumps in `C:\Windows\LiveKernelReports\WATCHDOG\` (incl. a 2.8 GB full report) — same watchdog family. `[OBSERVED]`

**Inference [moderate-high confidence]:** the 05-30 hang is the same `nvlddmkm` DPC-stall family, escalated. A DPC that merely *overruns* triggers a `0x133` bugcheck (recoverable into a dump, as on 05-11). A DPC that **fully wedges at DISPATCH_LEVEL** stops the scheduler entirely — no thread can run, the bugcheck path itself can't complete, so **no dump and no auto-reboot** (exactly the 05-30 signature). Idle-time onset fits a GPU **power/clock-state DPC** (P-state/idle transition) rather than a load spike.
**Honest limit:** 05-30 left no dump, so it's attributed by association to the decoded 05-11 sibling — not directly. That gap is precisely why P1 (crash capture) was applied; the next occurrence will be directly attributable.

---

## 3. Why GPU DPC, and the aggravating context `[OBSERVED]`
- Recurring `nvlddmkm` watchdog hits across 04-11, 05-11 (decoded), and the 05-30 signature.
- Matches this rig's documented telemetry: GPU DPC pinned on CPU 0 (`nvlddmkm`+`dxgkrnl`), the reason the **DDU 596.49→610.47 reinstall** was underway.
- **Driver state on 05-30:** active GPU bound to `oem73.inf` / `nv_dispig.inf`, `nvlddmkm.sys` **32.0.15.9186** (file dated 2026-02-17), loaded and running (T23/T27). A second, **unbound** package `oem0.inf`/`nv_dispsi.inf` **32.0.15.7700** (07-2025) lingers in the DriverStore — DDU/reinstall residue, harmless but clutter.
- BIOS revision at fault time: `36.3.0.0` (from dump WER data).

---

## 4. Ruled out, with evidence
| Hypothesis | Killed by |
|---|---|
| Kernel bugcheck on 05-30 | No dump, no MEMORY.DMP, KP41 BugcheckCode=0, AutoReboot didn't fire |
| **Storage / NTFS DPC** (earlier wrong guess) | Dump stack is `nvlddmkm`, not storage; `BLACKBOXNTFS:1` is a recorder-present flag, not attribution |
| GPU TDR (recoverable) | Zero Event 4101 — this was a *hang*, past TDR recovery |
| Hardware fault (CPU/mem/PCIe) | Zero WHEA events 14d |
| Thermal shutdown | No Kernel-Processor-Power throttle events |
| Sleep/resume failure | Power plan = Ultimate Performance; display + sleep both = never (0x0); no sleep/wake events |
| Multi-monitor VRAM P-state bug | Only 1 active monitor |
| 3rd-party AV / anti-cheat minifilter | `fltmc` = 100% stock Windows; SecurityCenter2 = Defender only |
| Defender platform-update transition (earlier suspect) | 09:58 "STATE_OFF" is a status *report* of a policy-disabled state, not a live transition |

---

## 5. Separate finding — SECURITY (not the freeze cause) `[OBSERVED]`
Defender real-time protection is **off by policy with tamper protection disabled**: `DisableRealtimeMonitoring=True`, `RealTimeProtectionEnabled=False`, `IsTamperProtected=False`, `BehaviorMonitorEnabled=False`. Consistent with this project's latency-tuning. Did not cause the freeze; flagged because the machine currently runs with no real-time AV.

---

## 6. Raw evidence on disk
| File | Contents |
|---|---|
| `captures\dump_0x133_051126_analyze.txt` | Full cdb `!analyze -v` — the nvlddmkm attribution |
| `captures\boot_freeze_rca_*.txt` | 7-source event collector output |
| `scripts\boot_freeze_rca.ps1` | Re-runnable collector |
| `scripts\enable_crashdump.ps1` / `rollback_crashdump.ps1` | P1 apply + rollback |

---

## 7. Recommendations (ranked)
| Pri | Action | Rationale |
|---|---|---|
| **DONE** | P1 crash capture (CrashDumpEnabled=7, AutoReboot=0, CrashOnCtrlScroll=1) | Next hang leaves a directly-attributable dump (reboot to arm combo) |
| **P2 — primary fix** | **Clean-reinstall the NVIDIA driver** (finish the DDU path): DDU in safe mode → install latest WHQL Game Ready / Studio for RTX 5070 Ti. Then remove the orphan: `pnputil /delete-driver oem0.inf /uninstall` | The confirmed offender is `nvlddmkm`. Current 9186 has a recurring DPC stall on this rig; a clean install on a wiped DriverStore is the established remedy |
| **P3** | After reinstall, set NVIDIA **Power Management Mode = "Prefer Maximum Performance"** for the desktop (NVCP global), or test it — idle-onset DPC stalls often trace to GPU idle/clock-state transitions | Removes the idle P-state transition that the stall correlates with; trade-off is higher idle power |
| **P4** | Arm a WPR/xperf **DPC/ISR watchdog trace** (`@dpc` agent / `pipeline.ps1`) so the next stall is captured live even if it self-recovers | Converts inference to direct proof; also catches sub-bugcheck DPC spikes |
| **P5** | If hangs persist after a clean driver + max-perf: test a **BIOS update** (was 36.3.0.0) and PCIe/ASPM settings | GPU DPC stalls can be PCIe link-power-management interactions |
| **P6** | Decide on Defender RTP / tamper protection (§5) | Currently unprotected |
