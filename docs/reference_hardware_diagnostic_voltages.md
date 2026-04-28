# Hardware Diagnostic Reference — Voltages, Clocks, Temps, Errors

System Under Test: Ryzen 7 9800X3D / RTX 5070 Ti / Team Group UD5-6000 (Hynix M-die EXPO) / Intel I226-V / Win11 26200 / 32 GB DDR5-6000.

This is the machine-comparator reference for `compare_to_reference.ps1`. Sources cited inline. Companion JSON: `reference_hardware_diagnostic_voltages.json` (consumed by the comparator).

---

## 1. CPU — AMD Ryzen 7 9800X3D (Zen 5, AM5)

### Voltages (idle / load)

| Rail | Idle nominal | Load nominal | Daily-safe max | Source |
|---|---|---|---|---|
| Vcore (VID) | 0.95 – 1.10 V | 1.20 – 1.45 V (AVX-light), 1.10 – 1.30 V (AVX-heavy) | 1.50 V | AMD AM5 SoC datasheet; HWiNFO `CPU Core VID` SVI3 telemetry |
| VSOC | 1.10 – 1.20 V | 1.10 – 1.20 V | **1.20 V** (post-7000X3D melt advisory; AGESA 1.0.0.6+ caps to 1.30 V — keep ≤ 1.20 V) | AMD safety advisory 2023-04; ASUS/MSI BIOS guidance |
| VDDIO_MEM (VDD_IO_S) | 1.30 – 1.40 V | 1.30 – 1.40 V | 1.45 V | JEDEC DDR5 spec; X870E vendor BIOS |
| VDD_MISC / VDDP | 1.00 – 1.10 V | 1.00 – 1.10 V | 1.20 V | AMD AM5 SVI3 reference |
| VDD_CLDO | 0.90 – 0.95 V | 0.90 – 0.95 V | 1.00 V | AMD AM5 reference |
| VDDG CCD | 1.00 – 1.10 V | 1.00 – 1.10 V | 1.20 V | AMD AM5 reference |

### Temperatures

| Sensor | Idle | Light load | All-core load | Critical | Source |
|---|---|---|---|---|---|
| Tdie | 35 – 50 °C | 50 – 70 °C | 75 – 89 °C | TjMax 95 °C (9800X3D, NOT 89°C like 7800X3D) | AMD 9800X3D product brief |
| Tctl | = Tdie | = Tdie | = Tdie | TjMax 95 °C | AMD; Tctl on X3D = Tdie (no offset) |
| CCD1 | within 5 °C of Tdie | within 5 °C of Tdie | 75 – 89 °C | 95 °C | HWiNFO sensor naming |
| IOD | 40 – 55 °C | 50 – 65 °C | 60 – 80 °C | 105 °C | HWiNFO IOD |
| VRM (motherboard) | 35 – 50 °C | 45 – 60 °C | 55 – 75 °C | 100 °C (component spec); 85 °C alarm | X870E VRM datasheets (ISL69269) |

### Clocks

| Metric | Idle | Light load | All-core | Source |
|---|---|---|---|---|
| Effective Clock (single core) | 0.4 – 4.7 GHz | 4.7 – 5.2 GHz | 5.2 GHz boost | 9800X3D spec |
| All-core boost | n/a | n/a | 5.0 – 5.2 GHz with PBO | 9800X3D + AM5 PBO behavior |
| Clock-stretching gap | <50 MHz | <50 MHz | **>50 MHz = stretching** | HWiNFO APERF/MPERF; community-confirmed 9800X3D pattern |

### Known-bad signatures

- **WHEA 19 MCE correctable** during light load = aggressive Curve Optimizer (-25 or below). Back off CO.
- **Effective clock dropping >100 MHz below reported clock** under load = thermal/power throttle OR clock stretching. Check Tdie + EDC/TDC headroom.
- **Vcore < 0.85 V at load** = throttle, undervolt-induced instability.
- **Tdie hitting 95 °C** = thermal throttle event imminent.

---

## 2. GPU — NVIDIA RTX 5070 Ti (Blackwell GB203, GDDR7)

### Clocks (driver 591.86)

| Metric | Idle (P8) | Idle (P5 — locked) | Mid (P3) | Near-max (P1) | Full speed (P0) |
|---|---|---|---|---|---|
| GPU core | 210 MHz | 405 – 810 MHz | 1.5 – 2.0 GHz | 2.4 – 2.7 GHz | 2.7 – 3.0 GHz |
| VRAM (GDDR7) | 405 MHz | **810 MHz** (our floor) | 7001 MHz | 13801 MHz | **14001 MHz** |

VRAM floor is locked to 810 MHz via `nvidia-smi -lmc 810,14001` (Task Scheduler at logon). Below 810 = wake-up stutter risk.

### Temperatures

| Sensor | Idle | Gaming | Critical | Source |
|---|---|---|---|---|
| GPU edge | 30 – 45 °C | 60 – 75 °C | 88 °C throttle, 92 °C critical | NVIDIA Blackwell consumer spec |
| GPU memory | 35 – 55 °C | 70 – 90 °C | 100 °C VRAM throttle | GDDR7 spec |
| Hotspot | edge + 5 °C | edge + 10–20 °C | 105 °C | NVIDIA |

### Power

| Metric | Idle | Gaming (default) | Source |
|---|---|---|---|
| TGP | 15 – 35 W | 250 – 300 W (300 W default cap) | RTX 5070 Ti spec |
| PCIe slot draw | < 75 W | scaled | PCIe spec |

### PCIe link state

| Property | Expected | Source |
|---|---|---|
| Link gen | **5** (PCIe Gen5) | RTX 5070 Ti spec; AM5 X870E |
| Link width | **x16** | RTX 5070 Ti spec |

### ECC

| Metric | Healthy | Source |
|---|---|---|
| ECC errors corrected (volatile) | 0 (consumer Blackwell does NOT have ECC; query returns "N/A") | NVIDIA — consumer SKUs lack ECC |
| ECC errors uncorrected | 0 (or N/A) | NVIDIA |

> **Note**: For consumer RTX 5070 Ti, ECC is not a metric — script handles "N/A" gracefully.

### PowerLimit clamp behavior

- Sustained PerfCap reason `Power` >5% of samples under gaming load = power-limited (set NVCP "Prefer Maximum Performance" + check PSU sag).
- PerfCap reason `Voltage` (VRel) at idle is normal for Blackwell.

### Known-bad signatures

- **Bus Interface Load stuck at 20-50% idle** with PerfCap `Power+VRel` = RTX 5070 Ti driver bug. Fix: NVCP Prefer Maximum Performance.
- **Memory clock dropping to 405 MHz** = wake-up stutter risk. Check `nvidia-smi -lmc` lock active.

---

## 3. RAM — Team Group UD5-6000 EXPO CL30-36-36-76 @ 1.35V (Hynix M-die)

### EXPO timings

| Timing | Stock EXPO | Safe Tuned | Aggressive | Source |
|---|---|---|---|---|
| Speed | DDR5-6000 | 6000 | 6000 | EXPO profile |
| CL | 30 | 30 | 28 | Hynix M-die typical |
| tRCD | 36 | 36 | 34 | Hynix M-die |
| tRP | 36 | 36 | 34 | Hynix M-die |
| tRAS | 76 | 76 | 68 | |
| tRFC | Auto (~560) | 480 | 380 – 420 | Hynix M-die safe range |
| tREFI | Auto (~32K) | 65535 | 131071 | Needs RAM cooling above 65K |
| VDIMM | 1.35 V | 1.35 V | 1.35 – 1.40 V | EXPO profile; AM5 limit ~1.45 V |

### FCLK

- DDR5-6000 → FCLK 2000 MHz → UCLK:MCLK 1:1 (sweet spot)
- Above DDR5-6600 → forces 1:2 → +10-15 ns latency
- **WHEA correctable errors during gaming = FCLK marginal**

### AIDA64 latency benchmark targets

| Profile | Latency target |
|---|---|
| Stock EXPO | 78 – 85 ns |
| Basic subtiming tuning | 67 – 72 ns |
| Aggressive | 60 – 65 ns |
| Best daily-stable | 57 – 60 ns |

### Known-bad signatures

- **AIDA64 latency >85 ns at DDR5-6000 EXPO** = misconfigured (likely 1:2 ratio or training fail).
- **TestMem5 anta777 Extreme errors** = unstable.
- **WHEA 19 storms during disk activity** = tRFC too low (silent corruption risk).

---

## 4. NIC — Intel I226-V 2.5 GbE

| Metric | Healthy | Source |
|---|---|---|
| Link speed | 2.5 Gbps (or 1 Gbps if cable/switch limit) | I226-V datasheet |
| Duplex | Full | |
| RX errors / sec | 0 | |
| TX errors / sec | 0 | |
| RX CRC errors | 0 (any > 0 indicates cable/PHY fault) | |
| TX CRC errors | 0 | |
| RX discards | <0.01% of RX packets | |
| Interrupt moderation | OFF for low-latency gaming | community (Battle(non)sense, Blur Busters) |

### Known-bad signatures

- **Any RX CRC > 0** = cable, PHY, or driver-firmware mismatch (I226-V has firmware history).
- **Link speed < 2.5 Gbps** with confirmed 2.5G switch = cable Cat5e/Cat6 marginal or autoneg fail.
- **NIC affinity overlap with GPU DPC mask** = CPU contention. I226-V is masked to 6-7; GPU DPC mask is 0xF0 (4-7). **Cores 6-7 carry both** — known overlap.

---

## 5. Storage — NVMe SMART thresholds

| Metric | Healthy | Warn | Source |
|---|---|---|---|
| Wear (used %) | <50% | >70% | NVMe spec |
| Temperature | <50 °C | >70 °C | NVMe spec |
| Read errors total | 0 | >0 | |
| Write errors total | 0 | >0 | |
| ReadLatencyMax | <50 ms | >100 ms | typical NVMe |
| WriteLatencyMax | <50 ms | >100 ms | |
| Power-on hours | informational | > rated lifetime | drive datasheet |

### Known-bad signatures

- **Reallocated sectors >0** on NVMe = cells failing.
- **Temperature >70 °C sustained** = throttle and reduced lifespan.

---

## 6. WHEA Error Decoding

### Common Event IDs (System log, Microsoft-Windows-WHEA-Logger)

| ID | Severity | Meaning | Action |
|---|---|---|---|
| 1 | Fatal | uncorrectable hardware error | machine check — CPU/RAM/PCIe; collect kernel dump |
| 17 | Warning | corrected hardware error (cache/MC) | driver/hardware health degrading |
| 18 | Error | uncorrectable PCIe error (AER) | PCIe link/device fault |
| 19 | Warning | corrected MCE | typical: aggressive CO, marginal FCLK, RAM instability |
| 20 | Error | uncorrected MCE | imminent CPU/RAM fault |
| 41 | Critical | unexpected shutdown / kernel-power | crash without bugcheck — usually power/thermal |
| 46 | Warning | bug check log | preceded a BSOD |
| 47 | Warning | crash dump initialization fail | |

### Error Source IDs (decoded from event payload)

- `Cache Hierarchy Error` (Bank 1) → CPU L1/L2/L3 corrected error
- `Bus/Interconnect Error` (Bank 5) → IO Die / IOD interconnect
- `Memory Controller Error` → DRAM channel fault
- `PCIe AER Correctable` → PCIe link CRC retransmit (cable/firmware)
- `PCIe AER Uncorrectable` → PCIe link drop or device hard fault

### Healthy signature

- **Zero WHEA Critical/Error in last 7 days**.
- **WHEA 19 (Warning) acceptable up to ~1 per day** during heavy gaming if Curve Optimizer is mildly aggressive — anything more = back off CO.

---

## 7. Comparator JSON Schema

`reference_hardware_diagnostic_voltages.json` keys:

```json
{
  "schemaVersion": 1,
  "system": "9800X3D / RTX 5070 Ti / DDR5-6000 / I226-V / Win11 26200",
  "rails": [
    {
      "id": "cpu_vcore",
      "component": "CPU",
      "metric": "Vcore (VID)",
      "phase": "idle",
      "min": 0.95, "max": 1.10, "unit": "V",
      "severity_below": "warn", "severity_above": "warn",
      "source": "AMD AM5 SoC datasheet; HWiNFO CPU Core VID SVI3"
    }
  ]
}
```

Severity levels: `info` / `warn` / `critical`. Comparator emits red for `critical`, amber for `warn`.

---

## Sources / Citations

- AMD AM5 SoC datasheet & SVI3 telemetry (HWiNFO sensor map)
- AMD safety advisory 2023-04 (VSOC ≤ 1.30 V cap, AGESA 1.0.0.6+)
- 9800X3D product brief (TjMax 95 °C, V-Cache layer below cores)
- NVIDIA RTX 5070 Ti / Blackwell GB203 spec
- JEDEC DDR5 (1.10 V VDD, 1.35 V VDIMM EXPO)
- Intel I226-V datasheet (link speeds, CRC behavior)
- NVMe 2.0 specification (SMART thresholds)
- Windows WHEA error structure (Microsoft Docs; `Microsoft-Windows-WHEA-Logger`)
- Community: Hardware Unboxed clock-stretching analysis; Buildzoid VSOC safety
- Project memory: `reference_9800x3d_architecture.md`, `reference_ddr5_timings.md`, `reference_multimonitor_vram.md` (this repo)

---

## Versioning

| Rev | Date | Change |
|---|---|---|
| 1 | 2026-04-25 | Initial. |
