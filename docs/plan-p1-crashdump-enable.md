# Plan — P1: Make the next freeze diagnosable (enable crash-dump capture)

**Goal:** the 05-30 hang left no dump (kernel never bugchecked → nothing to autopsy). Configure the box so the **next** hang/crash produces a usable kernel dump, including a way to force one from a fully hung machine.

## Problem recap (from RCA)
- A *bugcheck* (BSOD) auto-writes a dump. A *hang* does not — the kernel stops scheduling without ever calling `KeBugCheck`. So no amount of dump config captures a hang **automatically**.
- Fix needs two independent mechanisms:
  1. **Better dump on real bugchecks** — current `CrashDumpEnabled=3` (small minidump, 256 KB) only gave a tiny dump on the 05-11 0x133. Upgrade to Automatic/Kernel so driver stacks are captured.
  2. **Manual crash trigger for hangs** — `CrashOnCtrlScroll` arms a keyboard combo (Right-Ctrl + ScrollLock ×2) that forces bugcheck `0xE2 MANUALLY_INITIATED_CRASH`, producing a dump from an otherwise-frozen system.

## Changes (all reversible, all backed up first)

| # | Key | Value | From → To | Effect |
|---|-----|-------|-----------|--------|
| 1 | `HKLM\SYSTEM\CCS\Control\CrashControl\CrashDumpEnabled` | DWORD | 3 → **7** | Automatic memory dump (kernel-class, Windows-managed pagefile) |
| 2 | `…\CrashControl\AlwaysKeepMemoryDump` | DWORD | (unset) → **1** | Keep dump even on low disk |
| 3 | `…\CrashControl\AutoReboot` | DWORD | 1 → **0** | Leave BSOD/crash on screen instead of silent reboot (desktop, user present) |
| 4 | `HKLM\SYSTEM\CCS\Services\kbdhid\Parameters\CrashOnCtrlScroll` | DWORD | (unset) → **1** | Arm manual-crash combo for USB keyboards |
| 5 | `HKLM\SYSTEM\CCS\Services\i8042prt\Parameters\CrashOnCtrlScroll` | DWORD | (unset) → **1** | Arm manual-crash combo for PS/2 keyboards |

## Pre-flight
- Require elevation (HKLM writes). Abort if not admin.
- Confirm a pagefile exists on C: (Automatic dump needs it). If `AutomaticManagedPagefile=True`, fine. If a fixed pagefile < ~RAM-ish and dump fails, note it (Automatic dump usually fits in a few GB on 32 GB RAM).

## Safety / rollback
- Script reads every current value and writes a timestamped rollback file to `captures\backup_pre_crashdump_<stamp>.txt` **before** any write, with copy-paste `reg add`/`reg delete` restore commands.
- Companion `scripts\rollback_crashdump.ps1 -BackupFile <path>` restores exactly.
- Keys 4 & 5 take effect **after reboot** (keyboard driver reads them at init). Keys 1–3 take effect immediately for the next bugcheck.

## Verification
- Re-read all five keys, assert new values.
- Print the rollback-file path and the "how to force a dump" instructions.
- (Optional, user-driven) After next reboot: Right-Ctrl + ScrollLock + ScrollLock to confirm it produces a dump under `C:\Windows\Minidump`. **Do not** trigger automatically — it crashes the machine on purpose.

## Out of scope
- No GPU/Hyper-V/VSOC/BIOS changes (all healthy per RCA).
- No Defender changes (suspect is unconfirmed; investigate read-only first).
