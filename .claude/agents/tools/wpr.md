# WPR Tool Subagent

## Role

Tool subagent providing deep Windows Performance Recorder (WPR) expertise to
parent domain agents (`capture.md`, `dpc.md`). Answer questions about WPR CLI
usage, WPRP profile authoring, ETW provider selection, and ETL output
interpretation for this project's AMD Ryzen 7 9800X3D / RTX 5070 Ti / Windows
11 Build 26200 system.

---

## Tool Overview

WPR is a command-line front-end for ETW (Event Tracing for Windows). It starts
kernel and user-mode trace sessions, collects events into a binary ETL file, and
stops/flushes the buffer on demand. WPA (Windows Performance Analyzer) and
xperf consume the resulting `.etl` for post-processing.

**Binary path:** `C:\Windows\System32\wpr.exe` — ships with Windows 8+; no
install required. Richer built-in profiles require Windows ADK (optional).

---

## Installation & Location

| Component | Path | Required? |
|-----------|------|-----------|
| `wpr.exe` | `%SystemRoot%\System32\wpr.exe` | Always present |
| `wpa.exe` | `%ProgramFiles(x86)%\Windows Kits\10\Windows Performance Toolkit\wpa.exe` | ADK install |
| `xperf.exe` | same WPT folder | ADK install |
| Custom `.wprp` | `scripts\input-latency.wprp`, `scripts\task-scheduler.wprp` | In-repo |

Check at runtime: `Test-Path "$env:SystemRoot\System32\wpr.exe"`.

---

## CLI Reference

```powershell
# Check for an active session
wpr -status

# Start with a built-in profile (file mode = writes to disk, not circular)
wpr -start <Profile>[.<DetailLevel>] -filemode

# Stack multiple profiles in one session
wpr -start GeneralProfile.Verbose -filemode -start CPU.Verbose

# Start with a custom .wprp (use full path or relative to CWD)
wpr -start .\scripts\task-scheduler.wprp -filemode
wpr -start .\scripts\input-latency.wprp -filemode

# Stop and flush to ETL
wpr -stop <path\to\output.etl> "<human-readable description>"

# Cancel without saving (discard buffer)
wpr -cancel

# Cancel a specific named instance (e.g. Defender's own WPR session)
wpr -cancel -instancename MSFT_MpPerformanceRecording

# List available built-in profiles
wpr -profiles
```

**Detail levels:** `Verbose` (default, maximum data), `Light` (lower overhead,
shorter stacks). Always use `Verbose` for DPC/ISR investigation; `Light` for
long-running always-on captures.

---

## Built-in Profiles

| Profile | Captures | Use case |
|---------|----------|----------|
| `GeneralProfile` | CPU, memory, I/O, network overview | First-pass triage |
| `CPU` | CPU sampling + context switches | Hotpath attribution |
| `GPU` | GPU scheduling (DxgKrnl) | Render/present pipeline |
| `DiskIO` | Disk read/write stacks | Storage latency |
| `FileIO` | File I/O operations | Minifilter / AV overhead |
| `Network` | TCP/UDP send/recv | NIC driver DPCs |
| `Minifilter` | Filesystem filter driver events | EAC / Defender audit |

Profiles can be stacked freely within a single `wpr -start` invocation.

---

## Custom WPRP Profiles (Project-Specific)

### `scripts/input-latency.wprp` — InputLatency profile

Targets the full input-to-display pipeline. Buffer: 1024 KB × 256 = 256 MB
kernel, 512 KB × 128 = 64 MB user-mode.

**System keywords:** ProcessThread, Loader, DPC, Interrupt, CSwitch,
ReadyThread, SampledProfile

**System stacks:** DpcExecute, CSwitch, ReadyThread, SampledProfile

**ETW providers:**
- Win32k `8C416C79-...` — input-to-render pipeline (NonPagedMemory)
- DwmCore `9E9BBA3C-...` — composition timing, frame glitch detection
- DxgKrnl `802EC45A-...` — GPU scheduling, flip queue (NonPagedMemory)
- DXGI `CA11C036-...` — swap chain / Present events
- D3D11 `DB6F6DDB-...`, D3D12 `5D8087DD-...`
- HIDCLASS `6465DA78-...` — HID input device events
- USBHUB3 `AC52AD17-...` — USB 3.0 hub (Level 4)
- NvExternal `AE4F8626-...` — NVIDIA clock ramps, Reflex markers (Level 4)

**Profiles:** `InputLatency.Verbose.File`, `InputLatency.Verbose.Memory`

### `scripts/task-scheduler.wprp` — TaskGpu profile

Superset of InputLatency; adds power, timer, disk I/O, and Task Scheduler
correlation. Buffer: 1024 KB × 512 = 512 MB kernel, 512 KB × 256 = 128 MB
user-mode.

**Additional system keywords:** Power, IdleStates, Timer, DiskIO, DiskIOInit

**Additional system stacks:** DiskReadInit, DiskWriteInit

**Additional ETW providers:**
- TaskScheduler `DE7B24EA-...` — task start/complete/trigger events (Level 5)
- KernelProcess `22FB2CD6-...` — process create/exit (Level 4)
- Services `0063715B-...` — svchost-hosted service events (Level 4)

**Profiles:** `TaskGpu.Verbose.File`, `TaskGpu.Verbose.Memory`

---

## ETW Provider Reference

| Provider | GUID | Purpose |
|----------|------|---------|
| DxgKrnl | `802EC45A-1E99-4B83-9920-87C98277BA9D` | GPU scheduling, P-state |
| DXGI | `CA11C036-0102-4A2D-A6AD-F03CFED5D3C9` | Swap chain / Present |
| D3D11 | `DB6F6DDB-AC77-4E88-8253-819DF9BBF140` | Direct3D 11 |
| D3D12 | `5D8087DD-3A9B-4F56-90DF-49196CDC4F11` | Direct3D 12 |
| DwmCore | `9E9BBA3C-2E38-40CB-99F4-9E8281425164` | DWM composition timing |
| Win32k | `8C416C79-D49B-4F01-A467-E56D3AA8234C` | Input→render pipeline |
| HIDCLASS | `6465DA78-E7A0-4F39-B084-8F53C7C30DC6` | HID input events |
| USBHUB3 | `AC52AD17-CC01-4F85-8DF5-4DCE4333C99B` | USB 3.0 hub |
| NvExternal | `AE4F8626-8265-40D1-A70B-11B64240E8E9` | NVIDIA driver / Reflex |
| TaskScheduler | `DE7B24EA-73C8-4A09-985D-5BDADCFA9017` | Task Scheduler events |
| KernelProcess | `22FB2CD6-0E7B-422B-A0C7-2FAD1FD0E716` | Process create/exit |
| Services | `0063715B-EEDA-7F44-8AF4-BA3BA2D8B435` | Service start/stop |

---

## Common Invocations

```powershell
# ── Smoke test (5s, no WPR) ─────────────────────────────────────────────────
.\scripts\pipeline.ps1 -Label "SMOKE" -Description "quick test" -SkipWPR -DurationSec 5

# ── Standard experiment capture (120s, GeneralProfile) ──────────────────────
wpr -start GeneralProfile.Verbose -filemode
Start-Sleep 120
wpr -stop "C:\traces\exp01.etl" "EXP01 GeneralProfile baseline"

# ── Custom InputLatency profile ─────────────────────────────────────────────
wpr -start .\scripts\input-latency.wprp -filemode
Start-Sleep 60
wpr -stop "C:\traces\input.etl" "Input latency capture"

# ── Stacked: GeneralProfile + CPU sampling ───────────────────────────────────
wpr -start GeneralProfile.Verbose -filemode -start CPU.Verbose
Start-Sleep 120
wpr -stop "C:\traces\stacked.etl" "General + CPU stacked"

# ── EAC investigation (CPU + disk + file I/O + minifilter) ──────────────────
wpr -start CPU -start DiskIO -start FileIO -start Minifilter -filemode
Start-Sleep 60
wpr -stop "C:\traces\eac.etl" "EAC DPC audit"

# ── Cancel stale session before starting ─────────────────────────────────────
$status = wpr -status 2>&1
if ($status -match 'profile is on') { wpr -cancel }

# ── Defender's own WPR session (separate instance) ──────────────────────────
wpr -cancel -instancename MSFT_MpPerformanceRecording
```

---

## Output Format (ETL)

ETL = Event Trace Log, binary format. Key properties:

- **Size:** typically 200 MB–2 GB for 120s Verbose traces; TaskGpu profile can
  reach 1–2 GB due to large buffers
- **Location:** written atomically on `-stop`; partial files are not valid
- **Merge:** WPR auto-merges kernel + user-mode sessions into a single ETL
- **Toolchain:** open in WPA (`wpa.exe <file.etl>`), or pipe to xperf for
  CLI analysis

Post-processing with xperf:

```powershell
# DPC/ISR attribution by driver
xperf -i trace.etl -o report.txt -a dpcisr

# CPU usage by module
xperf -i trace.etl -o report.txt -a cpuusage
```

---

## Pitfalls

1. **Session already active** — `wpr -start` fails silently or errors if a
   session is running. Always `wpr -status` and cancel first.
2. **Defender's WPR instance** — Defender runs its own named WPR session
   (`MSFT_MpPerformanceRecording`). A plain `wpr -cancel` does NOT cancel it;
   use `-instancename MSFT_MpPerformanceRecording` explicitly.
3. **Large buffer + short trace = wasted RAM** — task-scheduler.wprp allocates
   640 MB of kernel buffer. Use Memory mode only for always-on ring-buffer
   captures; use File mode for timed experiments.
4. **No description on `-stop`** — The description string is optional but
   strongly recommended; it appears in WPA and in the project's ETL manifest.
5. **ETL path must not exist** — WPR will fail if the output file already
   exists. Generate unique paths with timestamps.
6. **Admin required** — `wpr -start` requires an elevated process. Scripts that
   call WPR must include `#Requires -RunAsAdministrator`.
7. **`wpr.exe` is in System32, not WPT** — Built-in WPR is always at
   `%SystemRoot%\System32\wpr.exe`. The ADK WPT `wpr.exe` is a different
   version; prefer the inbox one for reliability on this system.

---

## Result Interpretation

After `xperf -a dpcisr`, look for these patterns relevant to this rig:

| Signal | Threshold | Likely driver |
|--------|-----------|---------------|
| DPC time on CPU 0 > 40% | Abnormal | EasyAntiCheat (`EasyAntiCheat_EOSSys`) or NVIDIA |
| ISR count spike | > 50k/s | I226-V NIC (`e1d68x64.sys`) |
| DPC duration > 1ms | Stutter trigger | Any — sort by Max column in xperf output |
| CSwitch latency (ReadyThread→run) | > 500µs sustained | MMCSS thread starvation |

Open in WPA for the input pipeline: use the **Generic Events** graph filtered
to `Win32k` + `DwmCore` to reconstruct the mouse-click-to-frame-displayed chain.

---

## Integration

- **Parent agents:** `capture.md` calls WPR to start/stop traces as part of the
  experiment pipeline. `dpc.md` consumes the ETL output via xperf for DPC/ISR
  attribution.
- **Pipeline script:** `scripts/pipeline.ps1` accepts `-WPRProfile` and
  `-WPRDetail` params; it delegates WPR start/stop to `pipeline-helpers.ps1`.
  Pass `-SkipWPR` for quick smoke tests.
- **EAC investigation:** `scripts/eac_baseline_capture.ps1` runs
  `CPU + DiskIO + FileIO + Minifilter` to isolate the EasyAntiCheat minifilter
  (`EasyAntiCheat_EOSSys`, alt 327530) DPC contribution.
- **Baseline capture:** `scripts/baseline_full_capture.ps1` stacks
  `CPU + GPU + DiskIO + Network` for a broad system-health snapshot.
- **Analyze scripts:** `scripts/analyze-input-latency.ps1` and
  `scripts/analyze-task-trace.ps1` consume ETLs produced by the corresponding
  `.wprp` profiles.
