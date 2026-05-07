# GPUView Tool Subagent

## Role
Specialized subagent providing GPUView expertise within the windows-latency-optimizer project. Called by domain agents (gpu.md, dpc.md) when GPU queue scheduling, DMA packet timing, present mode analysis, or visual GPU-DPC correlation is needed. GPUView is purely a manual visual investigation tool — it produces no programmatic output. Use it when xperf or Nsight data points to a GPU scheduling anomaly that requires visual confirmation.

---

## Tool Overview
GPUView is part of the Windows ADK (Windows Performance Toolkit component). It opens ETL traces captured by its bundled `log.cmd` script and renders a timeline view showing GPU hardware queues, CPU context, DPC/ISR events, and present operations side-by-side. It is the primary tool for diagnosing GPU queue depth issues, stutter patterns caused by DMA packet preemption, and present mode mismatches.

GPUView is NOT a replacement for xperf or Nsight:
- No per-driver attribution (use xperf for that)
- No structured output (purely visual)
- No NVIDIA-specific GPU counters (use Nsight for that)

Its unique value is the **spatial relationship** between CPU DPC activity and the GPU hardware queue — visible at a glance in a way that per-driver tables cannot convey.

---

## Installation & Location

```
C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\GPUView\
```

Key files:
- `log.cmd` — toggle script: first call starts trace, second call stops
- `GPUView.exe` — GUI viewer
- `Merged.etl` — output trace file (created in the GPUView directory on stop)

Installation check (used in `analyze-dpc-deep.ps1`):
```powershell
$gpuViewDir = 'C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\GPUView'
$logCmd = Join-Path $gpuViewDir 'log.cmd'
if (-not (Test-Path $logCmd)) {
    Write-Host 'GPUView not found — install Windows ADK Windows Performance Toolkit' -ForegroundColor Red
}
```

---

## Capture Flow (log.cmd)

`log.cmd` uses a toggle mechanism: the first invocation starts the ETW session; the second invocation stops it and writes `Merged.etl` to the GPUView directory.

Project-standard capture pattern (from `analyze-dpc-deep.ps1 -GpuViewCapture`):
```powershell
$gpuViewDir = 'C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\GPUView'
$logCmd = Join-Path $gpuViewDir 'log.cmd'

Push-Location $gpuViewDir
& $logCmd 2>&1 | Out-Null            # Start trace
Write-Host 'Trace running. Reproduce the issue now...'
Start-Sleep -Seconds $DurationSec
& $logCmd 2>&1 | Out-Null            # Stop trace
Pop-Location

$mergedEtl = Join-Path $gpuViewDir 'Merged.etl'
$destEtl = Join-Path $captureDir 'gpuview_trace.etl'
Move-Item $mergedEtl $destEtl -Force  # Move out of ADK dir immediately
```

Invoke the project's built-in capture mode:
```powershell
.\scripts\analyze-dpc-deep.ps1 -GpuViewCapture -DurationSec 15
```
This creates a timestamped directory under `captures\experiments\<timestamp>_GPUVIEW\` and prints the exact GPUView.exe open command.

Open an existing trace:
```powershell
& 'C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\GPUView\GPUView.exe' 'path\to\gpuview_trace.etl'
```

---

## GUI Analysis Guide

GPUView opens with a horizontal timeline. Each row is a process or hardware queue. Time runs left to right.

**Navigation**
- Scroll wheel: zoom in/out on the time axis
- Click + drag: pan the timeline
- Right-click on a DMA packet: shows duration, queue depth at that moment, owning process
- Right-click on a flip/present packet: shows present mode (flip, blt, blt_scanout)

**Key rows to locate**
1. **GPU Hardware Queue** (labeled by GPU node): DMA packets appear as colored blocks — green = running, black = preempted
2. **DWM.exe row**: Desktop Window Manager present packets; look for queue depth > 2 (buffering)
3. **Game process row**: direct flip packets if exclusive fullscreen; blt packets if windowed/borderless
4. **CPU rows (0-15)**: shows which thread owns each CPU at each moment; cross-reference with DPC overlay
5. **DPC/ISR overlay**: orange bars at the top of CPU rows indicate interrupt service time

---

## Key Visual Elements

| Element | Color / Shape | What It Means |
|---------|--------------|---------------|
| Normal DMA packet | Green block | GPU executing work |
| Preempted DMA packet | Black block | GPU work was interrupted (preemption event) |
| Present/flip packet | Blue or purple block | Frame presented to display |
| DPC/ISR spike | Orange bar on CPU row | Kernel interrupt; long bars indicate DPC latency >500us |
| Empty GPU queue gap | White/blank space | GPU was idle — CPU did not submit work in time (CPU-bound stutter) |
| Deep present queue | Multiple stacked blue blocks | Frames queued up; flip lag = input latency |

**Preemption diagnosis**: black DMA packets immediately followed by resumption of the same packet usually mean a higher-priority context (DWM, another GPU process) preempted the game. Excessive preemption = frame time jitter.

**Queue depth diagnosis**: count how many DMA packets are queued in the GPU hardware queue row at any moment. Depth > 3 means the GPU is ahead of the display; depth = 0 with CPU activity = CPU is the bottleneck.

---

## Common Invocations

| Goal | Command |
|------|---------|
| Capture 15s trace (project standard) | `.\scripts\analyze-dpc-deep.ps1 -GpuViewCapture -DurationSec 15` |
| Capture custom duration | `.\scripts\analyze-dpc-deep.ps1 -GpuViewCapture -DurationSec 30` |
| Open saved trace | `& 'C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\GPUView\GPUView.exe' 'captures\experiments\...\gpuview_trace.etl'` |
| Start trace manually | `Push-Location 'C:\...\GPUView'; & .\log.cmd; Pop-Location` |
| Stop trace manually | `Push-Location 'C:\...\GPUView'; & .\log.cmd; Pop-Location` |

---

## GPUView vs Alternatives

| Tool | Use When |
|------|----------|
| GPUView | Visual GPU queue inspection, DMA packet preemption, present mode verification, GPU-DPC spatial correlation |
| xperf `-a dpcisr` | Programmatic per-driver DPC attribution, histogram analysis, per-CPU DPC tables — run this first |
| Nsight Systems | NVIDIA-specific GPU timeline with API-level detail (draw calls, shader stages), CUDA profiling |
| PresentMon / CapFrameX | Frame timing numbers (percentiles, 1%/0.1% lows), sensor correlation — no GPU queue visualization |
| WPR + WPA | Long-duration system-wide traces; CPU scheduler, memory, storage — not GPU queue focused |

Decision rule: run xperf first. If `nvlddmkm.sys` shows HighLatCount > 0 or MaxUs >= 512, use GPUView to see whether DPC spikes correlate with GPU preemption events or present queue stalls.

---

## Pitfalls

- **log.cmd must run from its own directory**: `Push-Location $gpuViewDir` before calling it. Running from another directory fails silently — no trace is started.
- **Merged.etl lands in the GPUView directory**: always `Move-Item` it out immediately after stop. Leaving it in place risks the next capture overwriting it.
- **Toggle confusion**: calling `log.cmd` twice starts then stops correctly, but calling it an odd number of times leaves an active session. Check Task Manager for `wpr.exe` or `logman query` if unsure. Kill the session with `logman stop "GPUView" -ets` if stuck.
- **ETW session conflict with WPR**: `log.cmd` starts its own ETW session. If WPR is already recording (`wpr -status`), GPUView trace may fail or produce incomplete data. Stop WPR first.
- **Admin required**: `log.cmd` must run elevated. `analyze-dpc-deep.ps1` has `#Requires -RunAsAdministrator` to enforce this.
- **No programmatic output**: GPUView.exe is a GUI only. Do not attempt to parse its output — use xperf for structured data.
- **Large traces**: captures longer than ~60s produce very large Merged.etl files (can exceed 1 GB). Keep captures short (10-30s) focused on the stutter window.

---

## Result Interpretation

| Observation | Diagnosis | Recommended Action |
|-------------|-----------|-------------------|
| Frequent black (preempted) DMA packets for game | DWM or another process preempting game GPU work | Check Exclusive Fullscreen mode; disable MPO (`OverlayTestMode=5` — note: breaks Epic Launcher, see `project_dwm_mpo_ue_crash.md`) |
| GPU hardware queue repeatedly empty, CPU active | CPU-bound stutter — GPU starving for work | Profile CPU thread (game or DWM) with Nsight or WPA |
| Present queue depth > 3 consistently | Flip lag / buffering — adds input latency | Enable Reflex, cap frames at GPU-limited value |
| DPC orange bars on CPU 0 aligned with GPU stalls | CPU 0 DPC activity blocking GPU submission | Re-verify interrupt affinity; CPU 0 should be idle (target: <1% DPC) |
| DPC spikes on CPUs 4-7 coinciding with frame drops | GPU/NIC DPCs on correct CPUs but still causing stalls | Check nvlddmkm.sys MaxUs in xperf; may need MSI interrupt mode (exp21) |
| Clean GPU queue, no preemption, smooth presents | No GPU scheduling issue | Root cause is elsewhere — check CPU scheduler or network |

**CPU Topology reminder**: CPU 0 = preferred core (keep idle), CPUs 2-3 = input devices, CPUs 4-7 = GPU/NIC DPC target, CPUs 8-15 = game threads.

---

## Integration

| Script | GPUView Role |
|--------|-------------|
| `scripts/analyze-dpc-deep.ps1 -GpuViewCapture` | Full capture flow: log.cmd start/stop, move Merged.etl, print open command |
| `scripts/health-check.ps1` | Checks GPUView directory exists; warns if ADK not installed |

Output artifact: `captures/experiments/<timestamp>_GPUVIEW/gpuview_trace.etl`

Dashboard integration: none — GPUView is manual visual investigation only. Findings are recorded in `docs/findings.md` as qualitative observations cross-referenced to the experiment label.
