---
tags: [drivers, chipset, nvme, audit, hardware]
date: 2026-04-27
status: active
aliases: [Driver Health Audit, Chipset Drivers, driver-health-audit]
---

# Driver Health Audit

## Summary

System-wide driver health investigation revealing critical gaps in AMD chipset driver coverage and NVMe driver optimization.

## Critical Finding: Missing AMD Chipset Software

The AMD Chipset Software Package is **NOT installed** on this 9800X3D system. This affects 7 devices across 5 chipset controllers:

| Device ID | Controller | Error | Impact |
|-----------|-----------|-------|--------|
| `ACPI\AMDI_F031` (x2) | AMD I2C Controller | Code 28 | USB/sensor communication |
| `ACPI\AMDI_0101` | AMD I3C Controller | Code 28 | Low-power device bus |
| `ACPI\AMDI_0204` | AMD Sensor Fusion Hub | Code 28 | Power management sensors |
| `ACPI\AMDI_0052` | AMD GPIO Controller | Code 28 | Pin control / interrupt routing |
| `PCI\VEN_1022&DEV_14DE` | AMD SFH (PCI) | Code 28 | Hardware power state transitions |
| `PCI\VEN_1022&DEV_1649` | AMD CCP/PSP | Code 28 | fTPM, hardware RNG, crypto |

### Latency Impact

- **No AMD PPM (`amdppm.sys`)** — Processor P-state management handled by generic Windows `cpu.inf` driver instead of AMD's optimized power management. This means suboptimal frequency scaling on the 9800X3D's Zen 5 cores.
- **No GPIO controller** — Interrupt routing uses generic ACPI handling instead of AMD-optimized paths.
- **No CCP/PSP** — fTPM operations (BitLocker, Credential Guard) handled in software instead of hardware co-processor. Adds CPU overhead during secure operations.
- **No SFH** — No hardware-accelerated power state transitions. C-state entry/exit takes longer.

### Remediation

Run `.\scripts\fix_chipset_drivers.ps1 -OpenDownload` to get step-by-step guide.

## NVMe Driver Audit

Both NVMe drives use Microsoft's generic `stornvme.sys` driver:

| Drive | Current | Recommended | Priority |
|-------|---------|-------------|----------|
| Samsung SSD 9100 PRO 1TB | Microsoft `nvmedisk.inf` | Samsung NVMe Driver 4.x | Medium |
| WD_BLACK SN850X HS 1000GB | Microsoft `nvmedisk.inf` | WD Dashboard driver | Low |

Samsung's native driver enables APST (Autonomous Power State Transitions) tuning and better queue depth management. WD's driver provides minimal benefit over generic.

## Event Viewer Summary (7 days)

| Source | Count | Severity | Notes |
|--------|-------|----------|-------|
| luafv (Service Control Manager 7000) | 35x | Error | UAC Virtualization filter blocked from loading. Fixed: disabled via `-FixLuafv` |
| WUDFRd (Kernel-PnP 219) | 2x | Warning | Razer HID device driver load failure |
| Windows Search (SCM 7022) | 1x | Warning | Service did not respond on starting (already disabled) |
| Windows Update (SCM 7043) | 1x | Warning | WU service improper shutdown |

### WHEA: Zero events — Clean hardware.

## Scripts

| Script | Purpose |
|--------|---------|
| [[catalog#audit-drivers.ps1]] | Full driver health audit |
| [[catalog#fix_chipset_drivers.ps1]] | AMD chipset remediation guide |

## Related

- [[9800x3d-architecture]] — Zen 5 V-Cache, why AMD PPM matters
- [[known-good-baseline]] — Reference hardware state
- [[scheduled-task-optimization]] — Task hygiene for gaming
