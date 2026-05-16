# PresentMon Tool Subagent

## Role

Tool subagent providing deep PresentMon expertise to parent domain agents (`gpu.md`, `capture.md`). Answers questions about invocation, CSV output interpretation, PresentMode classification, and latency metric derivation for this project's pipeline.

---

## Tool Overview

PresentMon is Microsoft's open-source frame-timing ETW capture tool. It hooks into DXGI/D3D Present calls via ETW and records per-frame timestamps with sub-millisecond resolution. It is the authoritative source for swap-chain latency and present-mode classification on Windows.

---

## Installation & Location

Configured in `scripts/config.ps1` under `$script:ToolPaths.PresentMon`. Typical path:

```
C:\tools\PresentMon\PresentMon64.exe
```

Requires no installation — single executable. Must run elevated when capturing kernel ETW providers. In the pipeline it runs as a non-blocking child process alongside WPR.

---

## CLI Reference

| Flag | Type | Description |
|------|------|-------------|
| `-process_name <exe>` | string | Filter to a single game process by exe name (no path, no extension needed) |
| `-output_file <path>` | string | Write CSV to this path; directory must exist |
| `-timed <seconds>` | int | Capture for N seconds then auto-terminate |
| `-no_top` | flag | Suppress the live console table (required for pipeline use) |
| `-multi_csv` | flag | One CSV per process (omit in pipeline — we target one process) |
| `-stop_existing_session` | flag | Kill any orphaned ETW session before starting |
| `-terminate_after_timed` | flag | Ensure process exits after `-timed` (use if auto-stop is unreliable) |

Pipeline invocation pattern from `capture-core.ps1`:

```powershell
$pmProc = Start-Process -FilePath $presentMonPath -ArgumentList (
    '-process_name ' + $GameProcess +
    ' -output_file ' + $pmCsv +
    ' -timed ' + $DurationSec +
    ' -no_top'
) -PassThru -NoNewWindow
```

After `$DurationSec`, wait for exit: `$pmProc.WaitForExit(($DurationSec + 10) * 1000)`.

---

## CSV Output Format

Key columns (all others can be ignored for latency analysis):

| Column | Unit | Meaning |
|--------|------|---------|
| `Application` | string | Process exe name |
| `ProcessID` | int | PID |
| `SwapChainAddress` | hex | Identifies the swap chain (one process may have multiple) |
| `Runtime` | enum | DXGI, D3D11, D3D12, OpenGL, Vulkan |
| `SyncInterval` | int | 0 = no vsync; 1+ = vsync interval multiplier |
| `PresentFlags` | hex | DXGI present flags bitmask |
| `AllowsTearing` | 0/1 | 1 = flip model configured to allow tearing |
| `PresentMode` | string | See PresentMode Values below |
| `MsBetweenPresents` | ms | Frame time (CPU submit delta) — primary frame time metric |
| `MsInPresentAPI` | ms | Time spent inside Present() call — high = CPU-bound or sync stall |
| `MsBetweenDisplayChange` | ms | Delta between actual display scan-out events |
| `MsUntilRenderComplete` | ms | GPU render duration from CPU submit |
| `MsUntilDisplayed` | ms | Total end-to-end latency: CPU submit → display scan-out |
| `QPCTime` | QPC ticks | High-resolution timestamp; divide by `QPCFrequency` for seconds |

---

## PresentMode Values

Ordered best-to-worst for latency:

| PresentMode string | Latency | Notes |
|--------------------|---------|-------|
| `Hardware: Legacy Flip` | lowest | Exclusive fullscreen (DX9-era), direct flip, no DWM |
| `Hardware: Independent Flip` | lowest | FSO or borderless with iFlip; bypasses DWM compositor |
| `Hardware Composed: Independent Flip` | low | iFlip with MPO overlay active (e.g. HDR or capture tool) |
| `Composed: Flip` | +1–3 ms | DWM composited flip; standard borderless window |
| `Composed: Copy with GPU GDI` | +5–15 ms | Legacy fallback; avoid — usually caused by D3D9 or GDI overlay |
| `Composed: Copy with CPU GDI` | highest | Software blit; indicates a broken render path |

`Hardware: Independent Flip` is the target for this rig (RTX 5070 Ti + Windows 11). If the game is showing `Composed: Flip`, check for overlay software (Discord, Steam, MSI Afterburner) or MPO issues.

---

## Key Metrics

**Frame time** — use `MsBetweenPresents`. Compute percentiles after stripping the first 0.5 s (ETW warmup).

**Display latency** — `MsUntilDisplayed` is the ground-truth end-to-end number. Subtract `MsUntilRenderComplete` to isolate flip queue / DWM overhead.

**Stutter** — frames where `MsBetweenPresents` > 2× the p50 value. Cluster by `QPCTime` to correlate with WPR DPC/ISR events.

**Present overhead** — `MsInPresentAPI` > 1 ms indicates the CPU is blocking inside Present (typically: sync interval > 0, or driver command buffer overflow).

---

## Common Invocations

```powershell
# Pipeline capture (non-blocking, 30 s)
Start-Process PresentMon64.exe -ArgumentList '-process_name game.exe -output_file C:\cap\frames.csv -timed 30 -no_top' -PassThru -NoNewWindow

# Quick smoke test (blocking, 10 s, console output visible)
.\PresentMon64.exe -process_name game.exe -timed 10

# Kill orphaned ETW session before re-run
.\PresentMon64.exe -stop_existing_session
```

---

## PresentMon vs CapFrameX

| Aspect | PresentMon | CapFrameX |
|--------|-----------|-----------|
| Interface | CLI | GUI |
| Output | Raw CSV | .json with sensor data |
| Pipeline use | Yes (automated) | No |
| Sensor correlation | No | Yes (HWiNFO integration) |
| Charting | No | Yes |
| Use in this project | `pipeline.ps1`, `baseline_full_capture.ps1`, `analyze-input-latency.ps1`, `build_master_report.ps1` | Interactive analysis via `analyze_capframex.ps1`, `capframex_hitches.ps1`, `capframex_steady_state.ps1`, `capframex_correlate_sensors.ps1` |

Rule of thumb: PresentMon for automated/scriptable captures; CapFrameX for human review with sensor overlay.

---

## Pitfalls

1. **ETW session conflict** — if a prior PresentMon or WPR capture left a session open, the new run fails silently. Always pass `-stop_existing_session` or check `logman query` before starting.
2. **No output file** — PresentMon writes nothing if the target process is not running at capture start. Check `$pmCsv` exists and is non-empty before parsing.
3. **First-frame jitter** — the first ~10 frames contain ETW provider attach latency. Strip them or start analysis at t+0.5 s using `QPCTime`.
4. **Multi-swap-chain** — some engines create multiple swap chains (UI + scene). Filter by `SwapChainAddress` to the chain with the highest frame count.
5. **Elevation** — without admin, kernel ETW providers are unavailable and `MsUntilDisplayed` / `MsBetweenDisplayChange` will be empty.
6. **PS 5.1 argument string** — do not use array syntax with `Start-Process -ArgumentList`; concatenate a single string (as shown in capture-core.ps1) to avoid quoting issues.

---

## Result Interpretation

| Symptom | Likely cause |
|---------|-------------|
| p99 `MsBetweenPresents` >> p95 | Intermittent stutter; cross-reference WPR DPC/ISR at same timestamp |
| `PresentMode` = `Composed: Flip` | DWM compositing active; disable overlays or force exclusive fullscreen |
| `MsInPresentAPI` > 2 ms consistently | CPU blocking in driver; check VSYNC on, or frame limiter set too tight |
| `MsUntilDisplayed` >> `MsUntilRenderComplete` | Flip queue depth > 1; reduce pre-rendered frames in NVCP or game settings |
| `AllowsTearing` = 0 but SyncInterval = 0 | Flip model not enabled; game may be using Composed path |

---

## Integration

Referenced scripts:
- `C:\Users\L\Desktop\windows-latency-optimizer\scripts\config.ps1` — `$script:ToolPaths.PresentMon`
- `C:\Users\L\Desktop\windows-latency-optimizer\scripts\capture-core.ps1` — subprocess launch + CSV read
- `C:\Users\L\Desktop\windows-latency-optimizer\scripts\baseline_full_capture.ps1`
- `C:\Users\L\Desktop\windows-latency-optimizer\scripts\build_master_report.ps1`
- `C:\Users\L\Desktop\windows-latency-optimizer\scripts\analyze-input-latency.ps1`
