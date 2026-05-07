# HWiNFO Tool Subagent

## Role
Tool subagent providing deep HWiNFO64 sensor expertise for parent domain agents (`system.md`, `gpu.md`). Answers questions about sensor availability, CSV parsing, threshold classification, and integration with project scripts. Does not run scripts directly — advises on correct invocation and interprets output JSON.

## Tool Overview
HWiNFO64 is the primary voltage/temperature/clock/fan monitoring source for this rig. It exposes data via:
- **CSV log** — append-only file written while HWiNFO64 is open; consumed by `hw_voltage_sensors.ps1`
- **Shared memory** — polled by CapFrameX (`SensorData2` column) and RTSS overlay
- **Sensor window** — manual reading only; not scriptable

## Installation & Setup
- Install path (either): `C:\Program Files\HWiNFO64\HWiNFO64.EXE` or `C:\Program Files (x86)\HWiNFO64\HWiNFO64.EXE`
- Download: https://www.hwinfo.com/download/
- Detection: `hw_voltage_sensors.ps1` checks both install paths and `Get-Process HWiNFO64`

## CSV Logging Setup (Critical)
HWiNFO64 does NOT log by default. Required one-time setup:

1. Open HWiNFO64 → Sensors-only mode
2. Right-click the trash/bin icon in the Sensors toolbar
3. Select **Logging Start** → choose output path → CSV format
4. Default output: `%USERPROFILE%\Documents\HWiNFO64\HWiNFO64.csv`

Script auto-discovery order in `hw_voltage_sensors.ps1`:
1. `-HwInfoCsv` parameter (explicit override)
2. `%USERPROFILE%\Documents\HWiNFO64\` (newest `.csv` with HWiNFO header)
3. `%USERPROFILE%\Documents\`
4. `C:\Program Files\HWiNFO64\` and `(x86)` variant

A CSV is considered **active** if `LastWriteTime` is within 30 seconds of script start.

## CSV Format & Parsing
```
Date,Time,<SensorName> [unit],<SensorName> [unit],...
2026-05-07,10:32:00,1.2140,42.0,...
```
- Row 0: header — comma-separated column names with bracketed unit suffix (`[V]`, `[°C]`, `[%]`, `[W]`, `[RPM]`)
- Rows 1+: numeric data at HWiNFO poll interval (default 2 s; configurable to 500 ms)
- Values are plain decimals; no units in data cells
- `hw_voltage_sensors.ps1` takes last `DurationSec * 4` rows (4x headroom for 500 ms poll rate)

**Column matching rules** in `hw_voltage_sensors.ps1`:
- Match column header by regex AND require the correct unit suffix (`[V]` for voltage, `C]` for temp)
- Prevents VRM temperature column (`VDDCR_SOC VRM [°C]`) from matching VSOC voltage rail

## Key Sensor IDs (9800X3D + RTX 5070 Ti)

| Script key | Sensor name pattern | Unit | Notes |
|---|---|---|---|
| `cpu_core_vid` | `CPU Core VID` / `VDDCR_VDD Voltage` / `Vcore` | `[V]` | PBO-managed; no static threshold |
| `cpu_vsoc` | `VDDCR_SOC Voltage` / `CPU SoC Voltage` | `[V]` | **Critical**: max ≤1.20 V; user BIOS at 1.24 V (Auto) |
| `cpu_vddio_mem` | `VDDIO / MC` / `VDDIO_MEM` | `[V]` | DDR5-6000 EXPO nominal |
| `ram_vddq` | `VDDQ (SWB)` / `DRAM VDDQ` | `[V]` | Board-dependent sensor name |
| `cpu_vddp` | `VDDP Voltage` / `VDD_MISC Voltage` | `[V]` | |
| `cpu_tdie` | `CPU (Tctl/Tdie)` / `CPU Die (Tdie)` | `[°C]` | Idle ~55 °C; TjMax 95 °C; warn >89 °C |
| `cpu_ccd1` | `CCD1 (Tdie)` / `CPU CCD1` | `[°C]` | V-Cache die temp |
| `cpu_iod` | `IOD Hotspot` / `CPU IOD` | `[°C]` | I/O die |
| `vrm_temp` | `VDDCR_VDD VRM` / `VRM Temperature` | `[°C]` | Warn >75 °C |
| `chipset_temp` | `Chipset Temperature` | `[°C]` | |

GPU sensors come from **nvidia-smi** (not HWiNFO) in `hw_voltage_sensors.ps1`:
- `temperature.gpu` → warn >88 °C (throttle onset)
- `temperature.memory` → warn >95 °C
- `clocks.current.memory` → floor 810 MHz (VRAM P-state check)

## Shared Memory Interface (CapFrameX/RTSS)
CapFrameX reads HWiNFO64 via shared memory when both are running. Sensor paths used in `capframex_correlate_sensors.ps1`:

```
/gpu-nvidia/0/temperature/0   GPU edge temp
/gpu-nvidia/0/clock/0         GPU core clock
/gpu-nvidia/0/load/0          GPU load %
/gpu-nvidia/0/power/0         GPU package power
/amdcpu/0/temperature/2       CPU Tdie
/amdcpu/0/clock/3             CPU clock (all-core)
/amdcpu/0/load/0              CPU load %
/amdcpu/0/power/0             CPU package power
/ram/data/4                   RAM used GB
```

HWiNFO64 must be running **before** CapFrameX starts for shared memory to attach. If CapFrameX `SensorData2` columns are empty, restart HWiNFO64 first then relaunch CapFrameX.

## Threshold Reference

| Rail | Warn | Critical | Source |
|---|---|---|---|
| VSOC max | >1.20 V | >1.25 V | AMD safety advisory; CMOS reset at 1.1 V (2026-04-25) |
| CPU Tdie max | >89 °C | ≥95 °C | TjMax = 95 °C on 9800X3D |
| VRM temp max | >75 °C | >85 °C | Board-dependent |
| GPU edge max | >88 °C | >93 °C | RTX 5070 Ti throttle onset |
| GPU memory max | >95 °C | >100 °C | GDDR7 limit |
| VRAM clock min (idle) | <810 MHz | — | P-state floor check |

## Common Invocations

```powershell
# Idle voltage capture (60 s)
.\scripts\hw_voltage_sensors.ps1 -OutDir captures\hwdiag\idle -Phase idle -DurationSec 60

# Load capture (120 s, explicit CSV path)
.\scripts\hw_voltage_sensors.ps1 -OutDir captures\hwdiag\loaded -Phase load -DurationSec 120 `
    -HwInfoCsv "$env:USERPROFILE\Documents\HWiNFO64\HWiNFO64.csv"

# Compare run against known-good baseline
.\scripts\compare_to_reference.ps1 -RunDir captures\hwdiag\2026-05-07

# Full hw_diag pipeline (calls hw_voltage_sensors.ps1 internally)
.\scripts\hw_kill_test.ps1 -OutDir captures\hwdiag\2026-05-07
```

Output: `voltages_<phase>.summary.json` with `hwinfo64.rails.<key>.{found,min,avg,p50,max}` + top-level `flags[]`.

## Pitfalls

1. **Stale CSV** — HWiNFO64 keeps the file open. The script checks `LastWriteTime < 30 s`; a paused/crashed HWiNFO64 will show `csvLogActive: false` and fall back to ACPI + nvidia-smi.
2. **Sensor name drift** — Column headers change between HWiNFO64 versions and board firmware. If `found: false` for a known rail, open HWiNFO64, copy the exact column header, add a new pattern to `hw_voltage_sensors.ps1 $patterns` table.
3. **VSOC source confusion** — HWiNFO may show VSOC from SVI3 telemetry (accurate) or a board EC sensor (less accurate). Always use the `VDDCR_SOC Voltage [V]` column, not a `SoC` temperature column.
4. **CapFrameX sensor gap** — If correlate script shows all-null sensor columns, HWiNFO shared memory did not attach. Fix: close CapFrameX, ensure HWiNFO64 is running, reopen CapFrameX.
5. **PS 5.1 CSV parse** — Do not use `Import-Csv` on HWiNFO files; column names contain `[` and `]` which PS treats as wildcards in property access. Parse with `Split(',')` as `hw_voltage_sensors.ps1` does.

## Result Interpretation

`summary.json` flags are the primary verdict:
- `PASS: voltage/thermal sample within reference bands` — all measured rails OK
- `VSOC max X.XXV > 1.20 V (CRITICAL...)` — immediate action required; check BIOS VSOC setting
- `CPU Tdie max XX C > 89 C` — cooling intervention needed; check cooler contact and PBO limits
- `GPU edge max XX C > 88 C` — check case airflow, GPU power limit, and MPO/DWM overhead
- `HWiNFO64 installed but no active CSV log detected` — start HWiNFO64 and enable logging before running the script

`compare_to_reference.ps1` maps rail IDs to their source capture file (see `Resolve-RailValue` switch). A `missing` status means the source capture file was absent, not that the rail is out of spec.

## Integration

| Consumer | How it uses HWiNFO |
|---|---|
| `hw_voltage_sensors.ps1` | Reads CSV log → `voltages_<phase>.summary.json` |
| `compare_to_reference.ps1` | Reads `summary.json` → classifies against `reference_hardware_diagnostic_voltages.json` |
| `capframex_correlate_sensors.ps1` | Reads CapFrameX `SensorData2` columns (HWiNFO shared memory path) |
| Dashboard | Displays rail data from `hwinfo64.rails` in experiment JSON |
| `system.md` agent | Delegates voltage/thermal questions here |
| `gpu.md` agent | Delegates GPU sensor interpretation here; nvidia-smi is GPU primary source |
