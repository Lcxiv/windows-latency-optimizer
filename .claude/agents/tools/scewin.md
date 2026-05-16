# SCEWIN Tool Subagent

## Role
Provide deep expertise on SCEWIN BIOS modification for the parent `system.md` domain agent. Handle
all SCEWIN invocations, export/import parsing, safety validation, and recovery guidance. This tool
can permanently damage the system if misused — treat every write as irreversible until proven otherwise.

---

## Tool Overview
SCEWIN (Setup Configuration Export/Import for Windows) reads and writes AMI NVRAM BIOS settings
from the running OS via SMI (System Management Interrupt). Each write causes a 45–400 ms full-system
freeze. No reboot required for most settings, but some require a cold boot to take effect.

**System under test:** AMD Ryzen 7 9800X3D · MSI board · DDR5-6000 EXPO CL30-36-36-76 @1.35V · Win 11 26200

---

## Installation & Location
```
C:\Users\L\Downloads\AMD BIOS Tweaks by CatGamerOP\SCEWIN\5.05.01.0002\SCEWIN_64.exe
```
Fallback search paths used by `optimize-bios.ps1`:
- `C:\Tools\SCEWIN_64.exe`
- `C:\SCEWIN\SCEWIN_64.exe`

Requires **Administrator** elevation. Verify with `Test-Path` before any command.

---

## CLI Reference

```powershell
# Export ALL settings to file (one SMI per setting — slow, ~60s for 1000+ settings)
SCEWIN_64.exe /o /s nvram.txt /d

# Import modified settings from file (causes SMI per changed variable — CLOSE GAMES FIRST)
SCEWIN_64.exe /i /s nvram.txt /q

# Read ONE setting by name (preferred — single SMI, fast, precise)
SCEWIN_64.exe /o /lang en-US /ms "Setting Name" /hb

# Write ONE setting by name (preferred — single SMI, atomic)
SCEWIN_64.exe /i /lang en-US /ms "Setting Name" /qv 0x01 /hb
```

**Flag meanings:**
| Flag | Meaning |
|------|---------|
| `/o` | Output (read/export) |
| `/i` | Input (write/import) |
| `/s` | File path |
| `/d` | Dump all (full export) |
| `/q` | Quiet import (no prompts) |
| `/ms` | Match single setting by name (exact string) |
| `/qv` | Quick value (hex) to write |
| `/hb` | Hex byte format |
| `/lang en-US` | Required with `/ms` for localized name lookup |

---

## Export Format

```
Setup Question  = Global C-state Control
Token           =37C        ← DO NOT MODIFY — hardware address
Offset          =0F
Width           =01
BIOS Default    =[01]Enabled
Options         =[00]Disabled
                *[01]Enabled    ← asterisk = current active selection
```

To change a setting in a file import: remove the `*` from the current option and add it to the
desired option. Never alter any other field.

---

## Safety Rules (CRITICAL — READ BEFORE ANY WRITE)

1. **NEVER modify Token lines.** Token values are hardware NVRAM addresses. Wrong token = corrupted
   unrelated setting, possible brick.
2. **Backup first, always.** Run full export to `captures/bios_backup_YYYYMMDD.txt` before any
   change. Store the backup path in the experiment record.
3. **Groups-of-4 rule.** Import no more than 4 settings per batch. Larger batches increase the risk
   of partial-apply states that are hard to diagnose.
4. **Prefer single-variable writes.** `/ms` + `/qv` writes are atomic and auditable. Full-file
   imports are harder to roll back if one setting in the batch is problematic.
5. **Close all latency-sensitive applications** before any import. SMI freezes corrupt frame timing
   and can crash games mid-write.
6. **Voltage settings require extra caution.** Any voltage below the safe floor (see Known Incidents)
   risks IMC instability and OS corruption at DDR5-6000 EXPO.
7. **String variables are write-protected** — attempting to write them causes an error and no change,
   but do not attempt it.
8. **Verify after every write.** Read back with `/ms` + `/o` to confirm the value took effect.

---

## Dangerous Settings (NEVER MODIFY)

| Setting | Risk |
|---------|------|
| BIOS Lock | Permanently locks flash — recovery requires hardware programmer |
| Flash Write Protection | Same as above |
| Secure Boot keys / PK / KEK / db | Breaks OS boot if cleared incorrectly |
| PSP (Platform Security Processor) settings | Unsigned firmware enforcement; brick risk |
| VSOC Voltage below 1.18V | See Known Incidents — caused ntoskrnl corruption at DDR5-6000 EXPO |
| Any setting with Width > 01 that isn't understood | Multi-byte writes can corrupt adjacent NVRAM |

---

## Recovery Procedures

**Level 1 — Software:** Re-import the backup file.
```powershell
SCEWIN_64.exe /i /s captures\bios_backup_YYYYMMDD.txt /q
```

**Level 2 — CMOS Clear (battery):**
1. Power off and unplug PSU.
2. Remove CMOS battery for 30 minutes.
3. Hold power button 30 seconds to drain capacitors.
4. Reinstall battery, power on — BIOS resets to factory defaults.
5. Re-enable EXPO 1 profile manually after boot.

**Level 3 — CMOS Jumper:**
1. Locate JBAT1 header on MSI board (near CMOS battery).
2. Bridge pins 2-3 for 3 seconds with PSU unplugged.
3. Return to pins 1-2 (default position), power on.

**Level 4 — BIOS Flashback:**
Reflash from USB using MSI Flash Button (does not require POST). Consult board manual for exact
procedure. Use the last known-good BIOS version matching current DDR5-6000 EXPO config.

---

## Common Invocations

```powershell
# Full backup before experiment
$date = Get-Date -Format 'yyyyMMdd_HHmmss'
& $ScewinPath /o /s "captures\bios_backup_$date.txt" /d

# Audit: read C-State current value
& $ScewinPath /o /lang en-US /ms "Global C-state Control" /hb

# Apply: disable Global C-States (value 0x00 = Disabled)
& $ScewinPath /i /lang en-US /ms "Global C-state Control" /qv 0x00 /hb

# Apply: disable TSME (Transparent Secure Memory Encryption)
& $ScewinPath /i /lang en-US /ms "TSME" /qv 0x00 /hb

# Verify write took effect
& $ScewinPath /o /lang en-US /ms "Global C-state Control" /hb
```

---

## Known Incidents

### VSOC Undervolt → ntoskrnl Corruption (2026-04-25)
**What happened:** VSOC set from 1.24V → 1.1V via SCEWIN. On next boot at DDR5-6000 EXPO, the IMC
(Integrated Memory Controller) could not sustain the memory bus, causing `ntoskrnl.exe` heap
corruption. System required CMOS reset to recover.

**Root cause:** 1.05V JEDEC theoretical minimum does NOT apply to DDR5-6000 EXPO on this IMC.
At 6000 MT/s, the IMC runs significantly hotter and needs more headroom.

**Safe floor for this rig: VSOC >= 1.18V at DDR5-6000 EXPO.**

Known-good baseline (post-CMOS-reset, 2026-04-25): VSOC = 1.24V, VDDIO = 1.38V, Vcore p50 = 1.214V.

---

## Pitfalls

- **Setting names are case-sensitive and locale-sensitive.** Always use `/lang en-US` and match the
  exact string from the export file — trailing spaces matter.
- **Some settings only take effect after cold boot** (full power cycle, not just restart). BIOS
  memory controller settings are common examples.
- **SMI frequency throttling:** issuing rapid sequential writes can cause some boards to queue SMIs.
  Wait for each write to return before issuing the next.
- **Exporting all 1000+ settings to a file takes ~60 seconds** and causes sustained SMI activity.
  Use `/ms` single reads when only auditing one or two settings.
- **FCLK "Auto" != FCLK locked.** Auto allows the BIOS to choose; explicit lock to 2000 MHz is
  required if testing FCLK stability separately from EXPO.

---

## Integration

**Project scripts:**
- `scripts/optimize-bios.ps1` — main audit/apply script; Tier 1 (C-States, TSME, PBO, FCLK) and
  Tier 2 (RAM subtimings tRFC, tRFCsb, Power Down); supports `-Audit`, `-Apply`, `-Tier1Only`,
  `-Restore -BackupFile` flags.

**Capture artifacts:**
- `captures/bios_backup_*.txt` — pre-change NVRAM exports (always create before writing)
- `captures/bios_export_*.txt` — audit snapshots (read-only exports for diffing)

**Reference baseline:** `captures/bios_export_20260410_194427.txt` — 25,927 lines, 1028 settings,
current known-good state as of 2026-04-10.

**Current BIOS state (2026-04-10):**
- RAM: DDR5-6000 CL30-36-36-76 @1.35V (EXPO 1, all subtimings Auto)
- PBO / Curve Optimizer: All Auto, all CO signs Positive
- Global C-State: DISABLED
- TSME: Auto (candidate for explicit Disabled)
- FCLK: Auto
