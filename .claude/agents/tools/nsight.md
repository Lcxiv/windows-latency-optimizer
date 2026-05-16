# Nsight Systems Tool Subagent

## Role
Specialized subagent for NVIDIA Nsight Systems capture and analysis within the windows-latency-optimizer project. Called by domain agents (`gpu.md`, `dpc.md`) when GPU-CPU timeline correlation, WDDM scheduling inspection, or DPC/ISR visual overlay is needed. All CLI flags, output formats, and GUI analysis steps are embedded here — no external lookups required.

---

## Tool Overview
Nsight Systems is NVIDIA's system-wide performance profiler. It records a unified GPU+CPU timeline: GPU hardware queues, WDDM scheduler decisions, DX12 API calls, ISR/DPC events, and CPU sampling — all on a shared time axis. In this project it answers **which GPU operation triggered the DPC stall that delayed mouse input**.

Use Nsight when:
- You need to see GPU preemption or context-switch timing alongside CPU DPCs
- WDDM HW Scheduler decisions need to be correlated with frame drops
- WPR/xperf shows a DPC spike but driver attribution alone doesn't explain the cause
- Visual overlay (Frame Health row) is needed to pinpoint individual stuttery frames

Do NOT use Nsight when:
- You need system-wide DPC/ISR driver attribution in bulk — use WPR + xperf instead
- GPU queue visualization without CPU context is sufficient — use GPUView
- You need long (>60 s) continuous captures — binary size grows very fast (~16 MB/s rep, ~240 MB/s SQLite for a 15 s capture on this rig)

---

## Installation & Location

```
# Capture CLI (target-windows-x64)
C:\Program Files\NVIDIA Corporation\Nsight Systems <version>\target-windows-x64\nsys.exe

# GUI (host-windows-x64)
C:\Program Files\NVIDIA Corporation\Nsight Systems <version>\host-windows-x64\nsight-sys.exe
```

`profile-nsight.ps1` auto-discovers both by globbing `Nsight Systems*` subdirectories under
`C:\Program Files\NVIDIA Corporation\` and checking for the expected relative paths. No hardcoded
version string — safe across Nsight upgrades.

Download (free): https://developer.nvidia.com/nsight-systems/get-started

Requires **Administrator** elevation. Verify with `nsys --version` before any capture.

---

## CLI Reference (nsys profile)

```powershell
# Version check
& $nsysPath --version

# Full capture (project default — 15 s, system-wide)
& $nsysPath profile `
    --trace=wddm,dx12 `
    --isr=true `
    --wddm-additional-events=true `
    --wddm-memory-trace=false `
    --sample=system-wide `
    --duration=15 `
    --stats=true `
    --export=sqlite `
    --output="captures\experiments\<timestamp>_NSIGHT\nsight_profile" `
    --force-overwrite=true `
    --system-wide=true

# Generate text stats from existing .nsys-rep (post-capture, no admin needed)
& $nsysPath stats "captures\experiments\<timestamp>_NSIGHT\nsight_profile.nsys-rep"

# Open report in GUI directly from PowerShell
& $guiPath "captures\experiments\<timestamp>_NSIGHT\nsight_profile.nsys-rep"
```

---

## Trace Options

| Flag | Effect | Latency relevance |
|------|--------|-------------------|
| `--trace=wddm` | WDDM GPU scheduling events | Context switch timing, queue depth |
| `--trace=dx12` | DirectX 12 API calls and barriers | Frame submission pipeline |
| `--trace=cuda` | CUDA kernel launches | Irrelevant for gaming; omit |
| `--isr=true` | Capture interrupt service routines | ISR→DPC chain correlation |
| `--wddm-additional-events=true` | Extra WDDM detail (preemptions, flips) | Preemption detection |
| `--wddm-memory-trace=false` | Skip WDDM memory alloc events | Reduces SQLite size ~40% |
| `--sample=system-wide` | CPU sampling across all processes | Find CPU hot-spots during DPCs |
| `--system-wide=true` | Capture from all GPUs/processes | Required for multi-process games |
| `--duration=N` | Stop after N seconds | 15 s is sufficient for most stutter hunts |
| `--stats=true` | Print summary statistics to stdout | Auto-generates nsight_stats.txt |
| `--export=sqlite` | Emit .sqlite alongside .nsys-rep | Required for programmatic analysis |
| `--force-overwrite=true` | Overwrite existing output files | Prevents stale-file errors |

---

## Output Formats

| File | Typical size (15 s) | Purpose |
|------|---------------------|---------|
| `nsight_profile.nsys-rep` | ~246 MB | Binary report; open in GUI |
| `nsight_profile.sqlite` | ~3.5 GB | Full event DB; query with sqlite3 |
| `nsight_stats.txt` | < 1 MB | Text summary from `nsys stats` |
| `nsight_profile.json` | < 1 MB | Project meta-summary (written by script) |

The `.sqlite` file is very large — do not commit it to git. The `.nsys-rep` is also large; both are gitignored by the project.

---

## Stats Command (nsys stats)

```powershell
# Generate/regenerate text stats from an existing rep file
& $nsysPath stats "captures\experiments\20260423_090227_NSIGHT\nsight_profile.nsys-rep"
```

Stats output sections relevant to latency:
- **WDDM Events** — queue depth histogram, context switch count
- **GPU HW Queue** — DMA packet durations, preemption count
- **ISR Statistics** — handler name, call count, min/avg/max duration
- **DPC Statistics** — routine name, call count, duration percentiles
- **CPU Sampling** — top functions by sample count (system-wide)

Match the DPC routine names here against xperf DPC attribution (`dxgkrnl.sys`, `nvlddmkm.sys`) to confirm the same driver is responsible across both tools.

---

## GUI Analysis Checklist

Open with: `nsight-sys.exe <path>.nsys-rep`

Priority rows to examine (top to bottom in timeline):

1. **Frame Health** — auto-flagged orange/red frames. Right-click → "Show in table" to get frame numbers and durations. This is the fastest triage entry point.
2. **GPU Hardware Queue** — look for black "Preemption DMA" packets. A preemption means the GPU was interrupted mid-frame to service another workqueue; prolonged preemptions cause frame drops.
3. **WDDM HW Scheduler** — horizontal bar shows which context owns the GPU. Gaps between context blocks = scheduler idle = CPU is the bottleneck. Overlapping colors = multiple contexts competing.
4. **ISR / DPC rows** (CPU timeline) — zoom into a stutter frame and locate the DPC spike. The GPU Hardware Queue row at the same time position reveals what GPU work was completing.
5. **DX12 row** — confirm Present→flip latency. Unusually long gaps between `ExecuteCommandLists` and the matching GPU completion indicate render-queue buildup.
6. **CPU Sampling** — in a zoomed stutter region, identify the top sampled function. If it is `dxgkrnl!DxgkScheduleQpcWorker` or `nvlddmkm`, the DPC stall is GPU-scheduler-driven.

Zoom workflow: select a stutter in Frame Health → Ctrl+Z to zoom to selection → examine all rows in that window.

---

## Common Invocations

```powershell
# Standard 15 s capture (project default)
.\scripts\profile-nsight.ps1

# 30 s capture targeting a specific game process for focused stats
.\scripts\profile-nsight.ps1 -DurationSec 30 -GameProcess "FortniteClient-Win64-Shipping_EAC_EOS.exe"

# Re-generate stats from a past capture without re-running
$nsysPath = (Get-ChildItem 'C:\Program Files\NVIDIA Corporation\Nsight Systems*' |
    ForEach-Object { Join-Path $_.FullName 'target-windows-x64\nsys.exe' } |
    Where-Object { Test-Path $_ } | Select-Object -First 1)
& $nsysPath stats "C:\Users\L\Desktop\windows-latency-optimizer\captures\experiments\20260423_090227_NSIGHT\nsight_profile.nsys-rep"

# Open a past capture in GUI
$guiPath = (Get-ChildItem 'C:\Program Files\NVIDIA Corporation\Nsight Systems*' |
    ForEach-Object { Join-Path $_.FullName 'host-windows-x64\nsight-sys.exe' } |
    Where-Object { Test-Path $_ } | Select-Object -First 1)
& $guiPath "C:\Users\L\Desktop\windows-latency-optimizer\captures\experiments\20260423_090227_NSIGHT\nsight_profile.nsys-rep"
```

---

## Pitfalls

1. **SQLite size explosion** — at 15 s the `.sqlite` file reaches ~3.5 GB. At 30 s it is ~7 GB. Always check available disk space before a long capture; Nsight will silently truncate or fail mid-capture if disk fills.
2. **NVTX SKIPPED warning is non-fatal** — `nsys` exits 0 even when it prints `SKIPPED: NVTX support`. The script correctly ignores this. Do not treat it as a capture failure.
3. **Admin required for ISR capture** — `--isr=true` requires Administrator. Without elevation, ISR rows will be absent in the timeline with no error message; the rep file still loads.
4. **--system-wide requires Secure Boot considerations** — on some systems, `--system-wide=true` is blocked by Driver Signature Enforcement. If capture hangs at "Starting profiling session", try without `--system-wide=true` first.
5. **Rep file only opens in matching Nsight version** — a `.nsys-rep` generated by Nsight 2026.x may refuse to open in an older GUI. Keep the nsys CLI and GUI at the same installed version.
6. **wddm-memory-trace costs ~40% SQLite growth** — leave it `false` unless specifically diagnosing VRAM allocation pressure. With `true`, a 15 s capture exceeds 5 GB SQLite.
7. **GameProcess parameter is stats-only** — `--system-wide=true` always captures everything. `-GameProcess` only affects which process nsys focuses its stats summary on; it does not restrict trace scope.
8. **DX12 trace without a DX12 game** — if no DX12 process is running, the `dx12` trace provider produces an empty row. Not an error; just omit `--trace=dx12` for DX11 titles if row clutter is a concern.

---

## Result Interpretation

| Timeline observation | Diagnosis |
|---------------------|-----------|
| Black preemption packets in GPU HW Queue | Another DMA workload interrupted the frame render; suspect OS scheduler or Defender scan triggering DPC |
| WDDM HW Scheduler gap (no color) during stutter | CPU failed to submit the next frame in time; render-queue underflow, not GPU bottleneck |
| DPC spike (CPU row) aligned with GPU preemption | GPU completion ISR triggered a large DPC; likely `nvlddmkm.sys` or `dxgkrnl.sys` — cross-check with xperf |
| Frame Health orange frame + CPU sampling → `dxgkrnl` | WDDM scheduler overhead; check WDDM HW Scheduler context switch count in stats |
| Frame Health red frame + GPU HW Queue busy throughout | GPU-bound; not a DPC/ISR issue — check frame cap and GPU load |
| ISR row absent | Capture ran without Administrator or `--isr=true` was not set |
| DX12 row empty | No DX12 process was active during capture, or game uses DX11/Vulkan |

Cross-reference DPC routine names in Nsight stats with xperf DPC table (`parse_xperf_trace.ps1` output). If `nvlddmkm.sys` appears in both, the GPU driver is confirmed as the latency source.

---

## Integration

| Script / artifact | How it uses Nsight |
|-------------------|--------------------|
| `scripts/profile-nsight.ps1` | Main capture script; auto-discovers nsys, runs capture, writes `nsight_profile.json` summary |
| `captures/experiments/<timestamp>_NSIGHT/` | Output directory — contains `.nsys-rep`, `.sqlite`, `nsight_stats.txt`, `nsight_profile.json` |
| `gpu.md` domain agent | Delegates GPU-CPU correlation questions here; interprets JSON summary |
| `dpc.md` domain agent | Delegates ISR/DPC visual overlay analysis here; cross-references with xperf output |
| xperf (`parse_xperf_trace.ps1`) | Complementary tool — provides driver-attributed DPC tables that confirm Nsight visual findings |
| WPR (`pipeline.ps1`) | Provides the broader ETL that xperf parses; Nsight captures are separate, not integrated into pipeline |

Existing captures available for re-analysis (no new run needed):
- `captures/experiments/20260407_191207_NSIGHT/`
- `captures/experiments/20260408_100229_NSIGHT/`
- `captures/experiments/20260423_090227_NSIGHT/` — most recent; rep ~246 MB, SQLite ~3.5 GB
