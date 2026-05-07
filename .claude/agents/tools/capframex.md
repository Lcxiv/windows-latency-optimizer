# CapFrameX Tool Subagent

## Role
Tool subagent providing deep CapFrameX expertise for parent domain agents (`gpu.md`). Answers questions about capture interpretation, script invocation, metric calculation, and hitch diagnosis. Does not run scripts directly — advises on correct invocation and interprets output.

## Tool Overview
CapFrameX is the primary frame-timing capture tool for this rig. It wraps PresentMon, records per-frame timestamps, GPU/CPU active fractions, PC latency, and optional HWiNFO sensor data into a single JSON file per session.

- Download: https://www.capframex.com/
- Requires: PresentMon service running (installed with CapFrameX)
- Overlay key: F11 (toggle overlay), F12 (start/stop capture — configurable)

## Installation & Capture Directory
Default capture output: `$env:USERPROFILE\Documents\CapFrameX\Captures\`

Each capture is a `.json` file named with timestamp + game process name. All four project scripts accept either `$env:USERPROFILE\Documents\CapFrameX\Captures` (default enumeration in `analyze_capframex.ps1`) or an explicit `-Path` / `-Files` parameter.

## JSON Capture Format
```
Runs[0]
  CaptureData          — per-frame arrays (one element per presented frame)
  SensorData2          — sensor time-series (HWiNFO shared memory, ~1 Hz)
Info                   — metadata: GPU, CPU, resolution, driver, API, comment
```
`Runs[0]` is always the target. Multi-run captures are rare; scripts always index `[0]`.

## CaptureData Fields

| Field | Type | Description |
|---|---|---|
| `MsBetweenPresents` | `double[]` | Frame time in ms. Core latency signal. |
| `TimeInSeconds` | `double[]` | Absolute timestamp per frame (seconds since capture start). |
| `GpuActive` | `double[]` | GPU-active fraction per frame (0–100 %). High = GPU-bound. |
| `CpuActive` | `double[]` | CPU-active fraction per frame (0–100 %). High = CPU-bound. |
| `PcLatency` | `double[]` | End-to-end PC latency in ms (Reflex if available, else estimated). |
| `Dropped` | `bool[]` | True when the frame was dropped by the present queue. |
| `PresentMode` | `int[]` | Present mode: 1=Windowed/Flip, 2=Fullscreen, etc. |

All arrays are co-indexed: `MsBetweenPresents[i]` corresponds to `TimeInSeconds[i]`. Filter out frames where `MsBetweenPresents[i] <= 0` before computing statistics.

## SensorData2 Fields (HWiNFO Integration)
`SensorData2.MeasureTime.Values` holds the sensor timestamp array. All other keys are HWiNFO shared-memory paths:

| JSON key | Sensor |
|---|---|
| `/gpu-nvidia/0/temperature/0` | GPU edge temperature (°C) |
| `/gpu-nvidia/0/clock/0` | GPU core clock (MHz) |
| `/gpu-nvidia/0/load/0` | GPU load (%) |
| `/gpu-nvidia/0/power/0` | GPU package power (W) |
| `/amdcpu/0/temperature/2` | CPU Tdie (°C) |
| `/amdcpu/0/clock/3` | CPU all-core clock (MHz) |
| `/amdcpu/0/load/0` | CPU load (%) |
| `/amdcpu/0/power/0` | CPU package power (W) |
| `/ram/data/4` | RAM used (GB) |

HWiNFO64 must be running **before** CapFrameX starts for shared memory to attach. If `SensorData2` columns are all null/absent in the correlate script output, restart HWiNFO64, then reopen CapFrameX.

## Frame Timing Analysis
`analyze_capframex.ps1` computes a full metric set across all `.json` files in the capture directory (or explicit `-Files` list) and prints a transposed side-by-side comparison table.

Key computed metrics:

| Metric | Formula / Definition |
|---|---|
| `AvgFps` | `1000 / mean(MsBetweenPresents)` |
| `Low1pctFps` | Average FPS of the worst 1 % of frames by frame time |
| `Low0_1pctFps` | Average FPS of the worst 0.1 % of frames by frame time |
| `MedianFtMs` | P50 of frame time array |
| `P95 / P99 / P99.9 FtMs` | Tail percentiles; P99 is the stutter headline number |
| `StutterScore` | `P99 / P50` — ratio of tail to median frame time |
| `Hitches_gt2xMedian` | Frame count where `FtMs > 2 × median` (canonical stutter def) |
| `StdFtMs` | Sample standard deviation (manual, PS 5.1 has no `-StandardDeviation`) |
| `AvgGpuActivePct` | Mean `GpuActive` across all frames |
| `AvgPcLatMs / P99PcLatMs` | PcLatency mean and tail |

**StutterScore thresholds:** <1.25 = smooth, 1.25–1.5 = noticeable, 1.5–2.0 = bad, >2.0 = severe.

## Hitch Detection Methodology
`capframex_hitches.ps1` — reports individual frames that breach a threshold and clusters adjacent events.

**Default threshold:** 16.67 ms (one 60 Hz refresh period). Tune with `-HitchThresholdMs`.

Frame time severity reference for this rig (360 Hz monitor, target ~2.78 ms/frame):

| Frame time | Meaning |
|---|---|
| ≥ 5.0 ms | 50 % over 360 FPS median — use as correlate threshold |
| ≥ 8.33 ms | Lost one 120 Hz refresh |
| ≥ 16.67 ms | Lost one 60 Hz refresh (default hitch threshold) |
| ≥ 33 ms | Two 60 Hz refreshes lost (noticeable stutter) |
| ≥ 100 ms | Full stall — perceptible freeze |
| ≥ 1000 ms | Freeze event |

**Clustering:** hitches within 0.5 s of each other are grouped into a cluster. Cluster `Spread` = time between first and last hitch in the group. A tight cluster with high `Count` and `MaxFtMs` indicates a sustained stall (shader compile, decompression, GC).

Output columns: `Frame`, `TimeSec`, `FtMs`, `GpuActPct`, `CpuActPct`, `PcLatMs`, `Dropped`.

## Steady-State Windowing
`capframex_steady_state.ps1` recomputes the full metric set on a trimmed `[StartSec, EndSec]` window to exclude loading screens and alt-tab transients at capture boundaries.

- Default: `StartSec=25`, `EndSec=captureDuration-1`
- Adds `P99.9FtMs` and `Hitches>2xMedian` to the output vs the comparison script
- Use for experiment comparisons where captures have variable-length preambles

When game launches capture a shader compile spike in the first 10–30 s, always use this script rather than `analyze_capframex.ps1` for fair A/B comparison.

## Sensor Correlation
`capframex_correlate_sensors.ps1` — links each hitch frame to its nearest `SensorData2` sample via binary search, then shows a per-hitch joined table plus an aggregate comparison of sensor state during hitches vs the full gameplay window.

**Default threshold:** 5.0 ms (use `-HitchThresholdMs 5.0` for 360 FPS captures).  
**Default window:** `StartSec=25`, `EndSec=captureDuration-1`.

Aggregate comparison output interprets whether sensor readings at hitch time differ significantly from the window-wide baseline:

| Pattern | Diagnosis |
|---|---|
| Hitch avg `GpuClkMHz` noticeably below window avg | GPU P-state drop / clock stretch during stall |
| Hitch avg `CpuLoad` noticeably below window avg | CPU likely not the bottleneck (something else blocking) |
| `CpuActMs` ≈ `FtMs` at hitch | CPU waiting on present (alt-tab, focus loss) |
| `GpuActMs` ≈ `FtMs` at hitch | GPU busy the entire frame — genuine GPU stall |
| `GpuPwrW` spike at hitch | Power-limit throttle event |

## Common Invocations

```powershell
# Side-by-side comparison of all captures in default dir
.\scripts\analyze_capframex.ps1

# Explicit file list (A/B experiment)
.\scripts\analyze_capframex.ps1 -Files @('C:\...\baseline.json', 'C:\...\exp01.json')

# Worst hitches in a single capture (default 60 Hz threshold)
.\scripts\capframex_hitches.ps1 -Path 'C:\...\capture.json'

# Lower threshold for 360 FPS captures; show top 40
.\scripts\capframex_hitches.ps1 -Path '...\capture.json' -HitchThresholdMs 8.33 -TopN 40

# Steady-state window (skip first 30 s loading)
.\scripts\capframex_steady_state.ps1 -Path '...\capture.json' -StartSec 30

# Hitch/sensor correlation (360 FPS threshold, gameplay window)
.\scripts\capframex_correlate_sensors.ps1 -Path '...\capture.json' `
    -HitchThresholdMs 5.0 -StartSec 25 -EndSec 300
```

## Pitfalls

1. **Frame 0 is invalid** — `MsBetweenPresents[0]` is always 0 or spurious; filter `> 0` before statistics.
2. **SensorData2 absent** — HWiNFO64 must start before CapFrameX. If sensor columns are null, the correlate script still runs but aggregate comparison rows will show NaN/0.
3. **Multi-run captures** — Scripts hard-index `Runs[0]`. If CapFrameX appended multiple runs (pause/resume), only the first is analyzed.
4. **Loading screen bias** — `analyze_capframex.ps1` includes the full capture including load. Use `capframex_steady_state.ps1` whenever captures have preambles.
5. **PS 5.1 percentile** — `Measure-Object -Percentile` does not exist. Project scripts implement `Get-Percentile` with floor-index interpolation. Do not replace with `Measure-Object`.
6. **Dropped frames** — `Dropped=true` frames are included in frame-time arrays. They inflate tail percentiles. Report the `Dropped` count separately; exclude them from `AvgPcLatMs` if PcLatency is 0 for dropped frames.
7. **PresentMode changes** — A change mid-capture (windowed → fullscreen) invalidates single-run comparison. Check `Info.PresentationMode` and ensure both captures used the same mode.

## Result Interpretation

Primary signal hierarchy for experiment comparison:
1. **StutterScore (P99/P50)** — overall consistency verdict
2. **Low1pctFps / Low0.1pctFps** — tail frame rate (what the player feels in worst moments)
3. **HitchPct** — proportion of frames above 2× median
4. **AvgPcLatMs** — end-to-end click-to-photon latency (lower = better responsiveness)
5. **AvgGpuActivePct vs AvgCpuActivePct** — bottleneck identification (GPU-bound = high GPU, low CPU)

A tweak is a regression if StutterScore increases AND Low1pctFps drops, even if AvgFps is unchanged.

## Integration

| Consumer | Usage |
|---|---|
| `gpu.md` agent | Delegates frame-timing and hitch analysis here |
| `capframex_correlate_sensors.ps1` | Reads `SensorData2` via HWiNFO shared memory (see `hwinfo.md`) |
| `pipeline.ps1 -GameProcess` | Calls PresentMon internally; output feeds `frameTiming` in experiment JSON |
| Dashboard `frameTiming` field | P50/P95/P99/P999 frame times + AvgFps from pipeline captures |
| `analyze_capframex.ps1` | Standalone A/B comparison outside the pipeline |
