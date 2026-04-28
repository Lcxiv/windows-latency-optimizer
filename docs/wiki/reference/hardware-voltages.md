---
tags: [reference, hardware, voltages, hwdiag, sensors]
date: 2026-04-25
status: complete
aliases: [Hardware Voltages, HWiNFO]
---

# Hardware Diagnostic Reference (Voltages, Clocks, Temps, Errors)

Source-of-truth for the hwdiag comparator. Lives in the repo (machine-readable + human-readable).

## Files

- **Narrative reference**: `C:\Users\L\Desktop\windows-latency-optimizer\docs\reference_hardware_diagnostic_voltages.md`
- **Comparator JSON**: `C:\Users\L\Desktop\windows-latency-optimizer\docs\reference_hardware_diagnostic_voltages.json`

## What it covers

Per-rail nominal/min/max with source citations for:
- CPU: Vcore (VID), VSOC (≤1.20V daily), VDDIO_MEM, VDDP, Tdie idle/load (TjMax 95°C on 9800X3D), IOD, VRM
- GPU: VRAM P-state floor (810 MHz), edge/memory temps, PCIe Gen5 x16, ECC, PowerLimit clamp
- RAM: DDR5-6000 EXPO timings, AIDA64 latency targets (57-85 ns), VDIMM
- NIC: I226-V link 2.5 Gbps, RX/TX errors, CRC
- Storage: NVMe SMART thresholds (temp, wear, errors, latency)
- WHEA: error severity, MCE corrected (ID 19) per-day budget

## Comparator integration

`scripts\compare_to_reference.ps1` walks every rail in the JSON, resolves observed values from `hwdiag/<run>/*/*.json`, classifies green/yellow/red, emits `manifest.json` + `anomalies.json` + `hwdiag_rollup.html`.

## Hwdiag scripts that produce data

- `hw_pcie_state.ps1` → `preflight\pcie_state.json`
- `hw_storage_smart.ps1` → `preflight\smart.json`
- `hw_whea_summary.ps1` → `preflight\whea.json`
- `hw_voltage_sensors.ps1` → `idle\voltages_idle.summary.json`, `loaded\voltages_load.summary.json`
- `hw_gpu_ecc.ps1` → `idle\gpu_ecc_idle.summary.json`, `loaded\gpu_ecc_loaded.summary.json`
- `hw_nic_errors.ps1` → `idle\nic_errors_idle.json`, `loaded\nic_errors_loaded.json`
- `hw_kill_test.ps1` → `kill_test\kill_decision.json` (4/24 slow-state hypothesis test)
- `run_hwdiag.ps1` → top-level orchestrator (admin)

## Voltage capture prerequisite

HWiNFO64 must be running with **CSV logging enabled** before voltage rails populate. Setup: HWiNFO64 → Sensors → right-click trash icon → Logging Start → choose CSV. The script auto-discovers the latest CSV in `Documents\HWiNFO64\` or HWiNFO install dir, and parses the last `DurationSec` rows.

Without HWiNFO64 logging, the voltage script falls back to nvidia-smi rails + ACPI thermal zones (CPU voltages remain unknown — Windows has no native voltage API).

## Versioning

Update the `lastUpdated` field in the JSON when any rail changes. Add a row to the narrative MD's "Versioning" table.
