---
tags: [research, baseline, voltages, hardware, reference]
date: 2026-04-25
status: complete
aliases: [Known Good Baseline, Post-CMOS]
---

# Known-Good Baseline — 2026-04-25 11:18

## State
- BIOS: CMOS reset → defaults loaded → EXPO Profile 1 enabled
- Disabled in BIOS: Bluetooth, USB Audio, WiFi, IGPU
- Everything else default (CO Auto, PBO Auto, Global C-State Auto, TSME Auto)
- HWiNFO64 sensors-only mode + CSV logging at `C:\Users\L\Documents\HwInfo\post_reboot_defaults.csv`

## Rail readings (idle, 60s)

### CPU (HWiNFO SVI3 telemetry)
| Rail | Value | Notes |
|---|---|---|
| Vcore (VDDCR_VDD) p50 | 1.214 V | Auto idle; 1.18-1.25V normal Zen 5 boost transitions |
| Vcore max | ~1.27 V | within spec |
| **VSOC** | **1.24 V flat** | board's AGESA default; safe |
| **VDDIO_MEM** | **1.3801 V** | EXPO-set; healthy |
| VDDP / VDD_MISC | 1.10 V | healthy |
| CPU Tdie idle p50 | 55.2 °C | healthy |
| CPU CCD1 idle | 41-72 °C burst | normal |
| CPU IOD Hotspot | 49-51 °C | healthy |
| VRM (VDDCR_VDD) | 46-47 °C | healthy |

### GPU (nvidia-smi)
| Rail | Value | Notes |
|---|---|---|
| Edge temp idle | 42 °C | healthy |
| VRAM clock | 14001 MHz locked | floor lock active |
| Power draw idle | ~70 W | healthy |
| PCIe link | Gen5 x16 | max |
| ECC uncorrected | 0 | n/a on consumer (handled) |

### Storage / NIC
| Rail | Value | Notes |
|---|---|---|
| Samsung 9100 PRO 1TB | Healthy | 31ms max read latency |
| WD_BLACK SN850X 1TB | Healthy | clean |
| I226-V link | 2.5 Gbps full-duplex | zero errors during 60s phase |

### Event log
- WHEA past 7 days: **0 events** of any severity

## Comparator verdict
PASS — 18 OK / 0 WARN / 0 CRITICAL / 14 missing (load-phase + MB/chipset temps not exposed)

## Files
- Run dir: `C:\Users\L\Desktop\windows-latency-optimizer\captures\hwdiag\post_reboot_defaults_20260425_110911\`
- Voltages: `idle\voltages_idle.summary.json`
- Manifest: `manifest.json`
- HTML rollup: `hwdiag_rollup.html`

## Use as future fingerprint
Compare any future hwdiag run against these readings. Significant deltas (>0.05 V on voltage rails, >5 °C on temps, >10% delta on idle clocks) = something changed in BIOS or hardware.

## Cross-refs
- `project_20260425_vsoc_underVolt_bootfail.md` — preceded this run; CMOS reset recovered system
- `reference_hardware_diagnostic_voltages.md` — comparator reference (Vcore idle ceiling raised 1.20→1.25 post-this-run)
- `reference_9800x3d_architecture.md` — Zen 5 + V-Cache architecture

## What's NOT covered
- Load-phase voltages (Prime95 not run today — would add 14 more rails)
- Per-DIMM VDDQ (HWiNFO shows VDDQ (SWB) but our pattern has minor differences across boards)
- Chipset/MB temps (X870E SuperIO doesn't expose to HWiNFO)
- Re-enabled peripherals impact (wifi/bluetooth/audio USB/IGPU all OFF in this run)
