# Diagnostic Tool Glossary

Reference for all capture, analysis, and visualization tools used by LatencyGuard.

---

## Capture Tools

| Tool | What It Captures | When to Use | Admin? |
|------|-----------------|-------------|--------|
| **WPR** (Windows Performance Recorder) | Kernel ETW traces — DPC, ISR, context switches, input events, GPU scheduling | Deep root cause analysis, DPC investigation | Yes |
| **xperf** (Windows Performance Toolkit) | Parses ETL traces into histograms, event dumps, driver attribution | After WPR capture — extracts actionable data | Yes |
| **PresentMon** (via FrameView) | Per-frame timing — frame time, FPS, present mode, stutter | Gaming sessions — frame time analysis | No |
| **ProcMon** (Process Monitor) | System calls, registry access, file I/O per-process | Defender scan impact, driver I/O behavior | Yes |
| **pktmon** (Packet Monitor) | Network packets at NIC level — zero install | Network latency, retransmissions, bufferbloat | Yes |
| **GPUView** | GPU queue depth, flip timing, DPC overlay on timeline | GPU scheduling, preemption storms, VSync alignment | Yes |
| **Nsight Systems** | Unified GPU + CPU timeline with DPC/ISR correlation | GPU-CPU correlation, stutter root cause (definitive) | Yes |
| **Perf Counters** | CPU, memory, disk, interrupt rates (1s intervals) | Quick health check, trending, experiment baselines | No |
| **Defender Recording** | Defender scan activity per-process and file | Measuring Defender's impact on latency | Yes |
| **nvidia-smi** | GPU state — clocks, temperature, power, BAR1, driver | GPU health checks, clock locking, ReBAR verification | No |
| **LatencyMon** | Real-time per-driver DPC/ISR latency measurement | Quick identification of worst DPC offender | No |

---

## Analysis Scripts

| Script | Input | Output | Purpose |
|--------|-------|--------|---------|
| `pipeline.ps1` | Live system | `experiment.json` + ETL + reports | Full capture — WPR + perf + GPU + PresentMon + network |
| `diagnose-mouse.ps1` | 10s ETW capture | `mouse_diagnostic.json` | Quick mouse stutter triage — HID gap detection |
| `analyze-input-latency.ps1` | ETL trace | `input_latency_analysis.json` | 4-stage pipeline: DPC histogram, event counts, frame timing, HID gaps |
| `analyze-dpc-deep.ps1` | dpcisr_report.txt | `dpc_deep_analysis.json` | Per-CPU DPC, histogram drill-down, input gap correlation |
| `profile-nsight.ps1` | nsys capture | `nsight_profile.json` + .nsys-rep | GPU-CPU correlation with DPC/ISR + WDDM scheduling |
| `audit.ps1` | Registry, WMI, tools | `audit_*.json` + `audit_*.html` | 41 system checks with pass/warn/fail scoring |
| `audit-checks.ps1` | (sourced by audit.ps1) | Check results array | Individual check implementations |
| `audit-report.ps1` | Audit JSON | Self-contained HTML | Standalone report with inline CSS/JS |
| `generate_dashboard_data.ps1` | Experiment JSONs | `experiments_generated.js` | Dashboard data generation from pipeline output |
| `baseline_capture.ps1` | 10s perf counters | `os_baseline_*.txt` | Quick registry + perf snapshot |
| `rollback.ps1` | Backup file | Registry restore | Undo experiment changes from backup |

---

## Experiment Scripts

| Script | What It Changes | Reboot? |
|--------|----------------|---------|
| `exp20_disable_hags.ps1` | HwSchMode 2→1 (disable GPU HW scheduling) | Yes |
| `exp21_msi_gpu_clocks.ps1` | MSISupported 0→1 + nvidia-smi clock lock | Yes (MSI) |
| `exp19_defender_gaming_exclusions.ps1` | Defender process + path exclusions for gaming | No |
| `fix_razer_polling.ps1` | Razer Synapse install for polling rate config | No |

All experiment scripts support `-WhatIf` (dry run) and `-Revert` (undo).

---

## Visualization Tools

| Tool | Purpose | How to Open |
|------|---------|-------------|
| **WPA** (Windows Performance Analyzer) | ETL deep dive — DPC/ISR view, CPU sampling, call stacks | `wpa.exe trace.etl` |
| **GPUView** | GPU queue + DPC timeline overlay | `GPUView.exe Merged.etl` |
| **Nsight Systems GUI** | Unified GPU-CPU timeline with frame health | `nsight-sys.exe profile.nsys-rep` |
| **LatencyGuard App** | Dashboard — score ring, heatmap, comparison, mouse diagnostic | `cargo run` from src-tauri/ |
| **HTML Report** | Self-contained audit report | Open `audit_*.html` in browser |
| **Dashboard** (legacy) | Chart.js experiment comparison | Open `dashboard/index.html` |

---

## ETW Providers

Providers captured by the `input-latency.wprp` WPR profile:

| Provider | GUID | What It Captures |
|----------|------|-----------------|
| Win32k (Input) | `8C416C79-D49B-4F01-A467-E56D3AA8234C` | Mouse/keyboard input processing, message pump |
| DxgKrnl (GPU) | `802EC45A-1E99-4B83-9920-87C98277BA9D` | GPU scheduling, VSync, Present, power states |
| DWM Core | `9E9BBA3C-2E38-40CB-99F4-9E8281425164` | Desktop composition timing |
| DXGI (Present) | `CA11C036-0102-4A2D-A6AD-F03CFED5D3C9` | Swap chain present calls |
| D3D11 | `DB6F6DDB-AC77-4E88-8253-819DF9BBF140` | Direct3D 11 API |
| D3D12 | `5D8087DD-3A9B-4F56-90DF-49196CDC4F11` | Direct3D 12 API |
| HID Class | `6465DA78-E7A0-4F39-B084-8F53C7C30DC6` | HID device events (note: Razer wireless fires 0 events) |
| USB Hub | `AC52AD17-CC01-4F85-8DF5-4DCE4333C99B` | USB completion events |
| NVIDIA External | `AE4F8626-8265-40D1-A70B-11B64240E8E9` | NVIDIA driver internal events |

System kernel events (always captured): ProcessThread, Loader, DPC, Interrupt, CSwitch, ReadyThread, SampledProfile.

---

## Decision Tree

```
MOUSE FREEZING / INPUT STUTTER
├─ Quick triage (10s)
│  └─ diagnose-mouse.ps1
│     Result: N gaps detected, max Xms, blamed driver
├─ Deep DPC analysis
│  └─ analyze-dpc-deep.ps1
│     Result: Per-CPU load, histogram by driver, gap correlation
├─ GPU correlation
│  └─ profile-nsight.ps1 (if installed)
│     Result: Exact GPU operation causing each DPC stall
└─ Fixes
   ├─ exp21_msi_gpu_clocks.ps1 (MSI interrupts + clock lock)
   ├─ Move dongle to USB 2.0 port
   └─ Install Razer Synapse (polling rate)

FRAME STUTTERING / LOW FPS
├─ Full capture during gameplay
│  └─ pipeline.ps1 -GameProcess "game.exe"
│     Result: experiment.json with frame timing + DPC + network
├─ Frame analysis
│  └─ PresentMon CSV → p50/p95/p99 frame times
├─ Visual timeline
│  └─ GPUView or Nsight Systems GUI
└─ Fixes
   ├─ audit.ps1 -Mode Deep (check all 41 settings)
   └─ Experiment scripts (HAGS, MSI, Defender exclusions)

SYSTEM AUDIT / HEALTH CHECK
├─ Quick scan
│  └─ audit.ps1 -Mode Quick (essential checks only)
├─ Full scan
│  └─ audit.ps1 -Mode Deep (41 checks)
├─ Results
│  └─ LatencyGuard app (Simple Mode) or HTML report
└─ Fixes
   └─ One-click "Apply" buttons in app

NETWORK LATENCY
├─ Packet capture
│  └─ pktmon start → pktmon etl2pcap → tshark analysis
├─ Bufferbloat detection
│  └─ pipeline.ps1 (built-in bufferbloat test)
└─ DNS optimization
   └─ exp16 DNS script
```

---

## Tool Comparison Matrix

| Capability | WPR/WPA | xperf | GPUView | PresentMon | Nsight | LatencyGuard |
|-----------|---------|-------|---------|------------|--------|-------------|
| DPC/ISR timing | Deep | Histogram | Visual | - | Correlated | Summary |
| GPU queue depth | - | - | Best | - | Good | - |
| Frame timing | - | - | VSync | Best | Good | Display |
| CPU-GPU correlation | Manual | - | Partial | - | **Best** | - |
| Stutter detection | Manual | - | Manual | Manual | **Auto** | Auto |
| Mouse input gaps | Via ETW | - | - | - | Via ISR | **Best** |
| System audit | - | - | - | - | - | **Best** |
| Scripted export | ETL | Text | ETL | CSV | SQLite | JSON |
| One-click fix | - | - | - | - | - | **Yes** |

---

## Installation Paths

| Tool | Location | Installer |
|------|----------|-----------|
| WPR / xperf / WPA / GPUView | `C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\` | Windows ADK |
| PresentMon | `C:\Program Files\NVIDIA Corporation\FrameView\bin\` | FrameView installer |
| ProcMon | `C:\Users\L\Desktop\ProcessMonitor\` | Sysinternals Suite |
| nvidia-smi | `C:\Windows\System32\` | NVIDIA driver |
| Nsight Systems | `C:\Program Files\NVIDIA Corporation\Nsight Systems <ver>\` | NVIDIA Developer |
| pktmon | System PATH | Built-in Windows 10/11 |
| LatencyMon | Manual download | resplendence.com |

---

## Desktop Shortcuts (user-maintained)

| File | Purpose |
|------|---------|
| `C:\Users\L\Desktop\Reboot to BIOS.bat` | `shutdown /r /fw /t 0` — reboots directly into UEFI for BIOS tuning |
| `C:\Users\L\Desktop\Reboot to Safe Mode.bat` | Enables `bcdedit /set {current} safeboot minimal` + reboot |
| `C:\Users\L\Desktop\Exit Safe Mode.bat` | Clears safeboot flag + reboot back to normal |

---

## Historical Archives

| Location | Contents |
|----------|----------|
| `docs\history\DiagCapture_20260328\` | Pre-repo diagnostic kit. `ERRORS_AND_FIXES.md` + `TOOL_REFERENCE_GUIDE.md` + `DIAGNOSTIC_REPORT.html` tracked; rest in `scripts_and_tools.zip` (gitignored, local only). |
| `captures\archive\legacy_20260328\` | Desktop-captured procmon + latencymon + os baselines from 2026-03-28. Gitignored. |
