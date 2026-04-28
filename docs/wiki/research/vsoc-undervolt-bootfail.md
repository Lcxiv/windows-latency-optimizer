---
tags: [research, voltage, bios, critical, 9800x3d]
date: 2026-04-25
status: complete
aliases: [VSOC Boot Fail, IMC Corruption]
---

# Incident — VSOC=1.1V breaks 9800X3D + DDR5-6000

## Symptom
After setting VSOC to 1.1V via SCEWIN (down from BIOS auto-default 1.24V), Windows failed to boot. ntoskrnl error on POST → splash screen → BSOD/crash. Corruption persisted across reboot attempts. CMOS reset required to recover.

## Root cause
At DDR5-6000 EXPO with FCLK 2000 MHz (1:1), the IMC/SoC fabric needs ≥1.15-1.20V VSOC for stability. 1.1V starves the memory controller → silent data corruption during memory access → page faults / kernel image corruption → ntoskrnl unable to load on next boot.

The community "≤1.20V daily ceiling" guidance is a CEILING (avoid >1.20V for chip longevity), NOT a target. Going BELOW that range without validation = unstable.

## Recovery
1. CMOS reset (clear BIOS to defaults).
2. Re-apply EXPO Profile 1.
3. Allow VSOC to stay at AGESA-default (1.20-1.24V on this board).
4. Reboot — Windows recovers (page corruption was at runtime cache only; on-disk image survived).

## Validated safe range for this rig (9800X3D + DDR5-6000 EXPO)
- **VSOC**: keep at AGESA default (1.20-1.24V). DO NOT lower below 1.18V without TestMem5/y-cruncher validation.
- **VDDIO/MC**: BIOS auto-set ~1.40V. Lowering risks IMC instability same as VSOC.
- **Vcore**: idle p50 ~1.18V is normal Auto behavior. Curve Optimizer offsets work but stay milder than -25.

## Updated reference
- `docs\reference_hardware_diagnostic_voltages.json` — VSOC `min: 1.05` is too low for this rig at DDR5-6000. Functional minimum is ~1.18V. The 1.05V was JEDEC theoretical floor, not validated for our memory profile.
- Recommend tightening VSOC `min` to 1.15V in JSON to flag dangerous undervolt attempts.

## Action items
- [ ] Update `reference_hardware_diagnostic_voltages.json` — VSOC `min` 1.05 → 1.15
- [ ] Update `reference_hardware_diagnostic_voltages.md` — note the 1.18V floor
- [ ] Memory file `reference_9800x3d_architecture.md` — add SoC voltage minimums section

## Repeat-prevention rules
1. NEVER set VSOC below AGESA default (1.20-1.24V) on a system with active EXPO without first running TestMem5 anta777 Extreme on a manual-tuned profile.
2. Step VSOC changes in 0.025V increments, not 0.14V jumps.
3. Always have CMOS reset jumper / BIOS-flashback known-good.
4. Voltage diagnostic findings are "bands to evaluate", not "targets to hit". The 1.20V cap was for safety, not optimization.

## Cross-refs
- `reference_9800x3d_architecture.md` — Zen 5 / V-Cache / FCLK behavior
- `reference_ddr5_timings.md` — DDR5-6000 stability dependence on FCLK
- `reference_hardware_diagnostic_voltages.md` — comparator reference
- `docs\hwdiag-runbook.md` — diagnostic runbook
