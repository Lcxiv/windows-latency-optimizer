# Gaming Lag Diagnostic: Tool Reference Guide

**Purpose:** Correlated multi-layer performance capture for diagnosing stutters, input delay, and network lag.
**Sources:** Microsoft Learn WPT docs, Sysinternals docs, tool documentation.

---

## Tool Inventory & Test Results

| # | Tool | Status | Test Result | Output |
|---|---|---|---|---|
| 1 | WPR (Windows Performance Recorder) | Built-in | PASS (534 MB ETL in 10s) | .ETL trace |
| 2 | ProcMon (Process Monitor) | Installed | PASS (154 MB PML in 10s) | .PML log |
| 3 | PerfMon (via logman) | Built-in | PASS (128 KB BLG in 10s) | .BLG counters |
| 4 | Ping (continuous) | Built-in | PASS (3ms avg to 1.1.1.1) | .TXT log |
| 5 | FrameView | Installed | PASS | .CSV frame times |
| 6 | LatencyMon | Installed | PASS | GUI display |
| 7 | HWiNFO64 | Downloaded | PASS | .CSV sensors |
| 8 | WinMTR | Downloaded | PASS | GUI traceroute |

**Paths:**
- WPR: `C:\Windows\System32\wpr.exe`
- ProcMon: `C:\Users\L\Desktop\ProcessMonitor\Procmon.exe`
- FrameView: `C:\Program Files\NVIDIA Corporation\FrameView\FrameView_x64.exe`
- LatencyMon: `C:\Program Files\LatencyMon\LatMon.exe`
- HWiNFO64: `C:\Users\L\Desktop\DiagCapture\Tools\HWiNFO64\HWiNFO64.exe`
- WinMTR: `C:\Users\L\Desktop\DiagCapture\Tools\WinMTR\WinMTR-v092\WinMTR_x64\WinMTR.exe`

---

## Tool 1: Windows Performance Recorder (WPR)

**Source:** [WPR Command-Line Options (Microsoft Learn)](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/wpr-command-line-options) | [Built-in Recording Profiles](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/built-in-recording-profiles)

### What It Captures
ETW (Event Tracing for Windows) system-wide traces including CPU scheduling, context switches, DPC/ISR latency, disk I/O, GPU activity, network activity — all with microsecond timestamps.

### Available Built-in Profiles (Gaming-Relevant)

| Profile | What It Records | Use For |
|---|---|---|
| `GeneralProfile` | First level triage (broad coverage) | Baseline capture, general issues |
| `CPU` | CPU utilization per core, scheduling, context switches | CPU-bound stutters |
| `DiskIO` | All disk I/O activity | Asset loading stalls, antivirus interference |
| `GPU` | GPU engine utilization, present calls, flip queue | GPU-bound issues, present latency |
| `Network` | Networking I/O activity | Network-related lag |
| `Video` | Video streaming glitches | Frame pacing issues |
| `DesktopComposition` | DWM composition activity | Desktop-wide stutters |
| `Thermal` | Thermal status | CPU/GPU throttling detection |
| `Power` | Power states, C-states, P-states | Power management throttling |

### Optimal Command for Gaming Lag

**Important:** GeneralProfile already includes DPC, ISR, CSwitch, DiskIO, ReadyThread, SampledProfile, and Power. Adding CPU/DiskIO/GPU on top adds deeper per-process detail.

```cmd
:: RECOMMENDED: .light variants during gaming (no stack walks = less overhead)
wpr -start GeneralProfile.light -start CPU.light -start DiskIO.light -start GPU.light -start Network.light -start Thermal -filemode

:: Stop and save (use -skipPdbGen to avoid 10-30s CPU spike on stop)
wpr -stop "C:\DiagCapture\<timestamp>\wpr_trace.etl" "gaming stutter repro" -skipPdbGen

:: Check status during recording (verify zero events lost)
wpr -status collectors -details

:: Cancel without saving
wpr -cancel
```

**If you need call stacks** (to pinpoint exact function in a driver causing DPC spikes):
```cmd
:: Verbose mode — use only for short focused repro (30-60s)
wpr -start GeneralProfile -start CPU -start GPU
wpr -stop "trace_verbose.etl" "DPC deep dive"
```

### Key Settings
- **`.light` vs `.verbose`:** Light = timing events only (~2% overhead). Verbose = full stack walks (~4-5% overhead, 2-4x file size). **Use .light during gameplay.**
- **File mode (`-filemode`):** Required for 5-min captures. Memory mode is circular (only keeps last 30-60s).
- **`-skipPdbGen`:** Skips .NET symbol generation on stop. Saves 10-30s of CPU load. Use unless profiling .NET games.
- **`-recordtempto`:** Redirect temp files to a different NVMe if available.
- **Output size:** .light profiles ~30-50 MB/min. Verbose ~100+ MB/min. (534 MB for 10s in our test was verbose with Fortnite active.)

### Analysis in WPA
Open the ETL trace in Windows Performance Analyzer:
```cmd
wpa.exe "C:\DiagCapture\<timestamp>\wpr_trace.etl"
```

**Key WPA Graphs for Gaming Lag:**

**Source:** [List of WPA Graphs (Microsoft Learn)](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/list-of-wpa-graphs) | [CPU Analysis](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/cpu-analysis)

| Category | Graph | What to Look For |
|---|---|---|
| **DPC/ISR** | DPC/ISR Duration by Module, Function | Sort by Exclusive Duration desc — top entry is your DPC offender |
| **DPC/ISR** | DPC/ISR Timeline by Module | When each driver's DPC fires — correlate with stutter timestamps |
| **CPU** | CPU Usage (Precise) > Timeline by Process, Thread | Game render thread in "Ready" state while DPC occupies its core |
| **CPU** | CPU Usage (Sampled) > Utilization by Process, Stack | Hot functions consuming CPU in game process |
| **Disk** | Disk Usage > Service Time by Process, Path Name | I/O latency per file — find slow shader cache reads |
| **Disk** | Disk Usage > Activity by IO Type, Process | MsMpEng.exe or TiWorker.exe generating disk I/O during gameplay |
| **GPU** | DX Frames > Duration by Process, FlipType | Frames exceeding target time (>8.3ms for 120fps, >16.7ms for 60fps) |
| **GPU** | GPU Utilization > GPU by Process | GPU drops to 0% = CPU-starved; 99% = GPU bottleneck |
| **GPU** | Dwm Frame Details > Dwm Frame E2E | End-to-end frame latency from submission to display |

**Microsoft's DPC/ISR thresholds (HLK):** DPCs must not exceed **100 us**. ISRs must not exceed **25 us**.

**WPA Analysis Workflow:**
1. Open ETL in WPA. Go to **Trace > Load Symbols** (resolves driver names)
2. Add symbol path: `SRV*C:\Symbols*https://msdl.microsoft.com/download/symbols`
3. Drag relevant graphs to the Analysis tab
4. **All graphs share the same timeline** — zoom into a stutter spike and ALL panels narrow
5. Right-click > Zoom to Selected Time Range to focus on the exact stutter moment

### Important Notes
- WPR can only run ONE recording at a time. Cancel any existing before starting.
- GeneralProfile already captures DPC/ISR, CSwitch, ReadyThread, SampledProfile, Power.
- Adding CPU/DiskIO/GPU on top adds deeper per-process/thread detail.
- Up to 64 profiles in a single recording.
- Run `wpr -status collectors` during recording — `Events Lost > 0` means switch to `.light` profiles.

---

## Tool 2: Process Monitor (ProcMon)

**Source:** [Sysinternals Process Monitor](https://learn.microsoft.com/en-us/sysinternals/downloads/procmon)

### What It Captures
Every file system, registry, network, and process/thread operation in real-time with microsecond timestamps, stack traces, and process details.

### Optimal Command for Gaming Lag

**Source:** [Sysinternals Process Monitor (Microsoft Learn)](https://learn.microsoft.com/en-us/sysinternals/downloads/procmon) | [Troubleshoot Defender AV with ProcMon](https://learn.microsoft.com/en-us/defender-endpoint/troubleshoot-av-performance-issues-with-procmon)

```cmd
:: Use 64-bit binary on x64 systems
:: Start quiet background capture with backing file and auto-stop after 5 min
Procmon64.exe /AcceptEula /Quiet /Minimized /BackingFile "C:\DiagCapture\<timestamp>\procmon_capture.pml" /Runtime 300

:: Or start with pre-built filter config for lower overhead
Procmon64.exe /AcceptEula /Quiet /Minimized /BackingFile "capture.pml" /LoadConfig "gaming_filters.pmc"

:: Stop a running capture from another terminal
Procmon64.exe /Terminate /Quiet

:: Convert PML to CSV for cross-tool correlation
Procmon64.exe /AcceptEula /Quiet /OpenLog "capture.pml" /SaveAs "capture.csv"

:: Convert with filter applied (export only matching events)
Procmon64.exe /AcceptEula /Quiet /OpenLog "capture.pml" /LoadConfig "gaming_filters.pmc" /SaveAs "filtered.csv" /SaveApplyFilter
```

### Critical Setting: Drop Filtered Events

**IMPORTANT:** Enable `Filter > Drop Filtered Events` before capturing. This makes ProcMon discard non-matching events at the kernel driver level, not just hide them from display. Without it, ALL events are logged (full disk/CPU impact) and only hidden at display time.

- **With Drop Filtered Events:** 1-3% CPU overhead, KB-to-MB per minute disk usage
- **Without:** 5-15% CPU overhead, GB per minute disk usage

### Recommended Exclusion Filters for Gaming

Apply these EXCLUDE rules to cut system noise (Filter > Filter > Ctrl+L):

| Column | Relation | Value | Action | Reason |
|---|---|---|---|---|
| Process Name | is | Procmon64.exe | Exclude | Self-monitoring |
| Process Name | is | System | Exclude | OS kernel I/O (massive volume) |
| Process Name | is | dwm.exe | Exclude | Desktop Window Manager redraws |
| Process Name | is | svchost.exe | Exclude | Service host noise |
| Process Name | is | csrss.exe | Exclude | Client/Server Runtime (high volume) |
| Process Name | is | SearchIndexer.exe | Exclude | Windows Search indexer |
| Process Name | is | backgroundTaskHost.exe | Exclude | Windows background tasks |
| Process Name | is | RuntimeBroker.exe | Exclude | UWP broker |
| Operation | is | RegCloseKey | Exclude | Zero diagnostic value, very high volume |

**Note:** Do NOT exclude MsMpEng.exe (Defender) if hunting antivirus interference — that's one of the main suspects.

### What to Look For (Sort by Duration descending)

| What You See | What It Means |
|---|---|
| `WriteFile` high Duration on shader cache dir | Shader compilation stutter (DX12/Vulkan cache writes) |
| `ReadFile` slow on game .pak/.vpk/.uasset files | Asset streaming bottleneck |
| `MsMpEng.exe` ReadFile on game directory | AV real-time scan during asset load |
| Any op with Result = `SHARING VIOLATION` | File lock contention between processes |
| Long Duration in `EasyAntiCheat.exe` / `BEService.exe` | Anti-cheat system scans causing stutter |
| `svchost.exe` WriteFile to `C:\Windows\Prefetch\` | Prefetch writes competing during gameplay |
| `RegQueryValue` slow on HKLM\SOFTWARE | DRM or anti-cheat registry lookups blocking game thread |
| `ReadFile` on pagefile.sys | Memory pressure causing disk swapping |

### Key Settings
- **Use `Procmon64.exe`** (not `Procmon.exe`) on 64-bit Windows.
- **Backing file mode (`/BackingFile`):** Required. In-memory mode exhausts RAM during gaming.
- **`/Runtime 300`:** Auto-stops after 5 minutes — no manual terminate needed.
- **`/LoadConfig`:** Pre-load a .pmc filter file. Create once via GUI, reuse forever.
- **Overhead:** 154 MB in 10s unfiltered is normal. With "Drop Filtered Events" and proper exclusions, expect ~500 MB for a 5-minute session.

### Important Notes
- Requires admin privileges for full capture.
- Sort by **Duration** descending to find the slowest operations instantly.
- Use **Tools > Count Occurrences** to rank which processes generated the most events.
- The PML format is proprietary — export to CSV via `/SaveAs` for correlation with other tools.
- **Save your filter config:** File > Export Configuration > `gaming_filters.pmc` — reuse with `/LoadConfig`.

---

## Tool 3: Performance Monitor (logman)

**Source:** [logman create counter (Microsoft Learn)](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/logman-create-counter)

### What It Captures
Windows performance counter values sampled at regular intervals. Provides time-series data for CPU, memory, disk, GPU, and network metrics.

### Optimal Command for Gaming Lag

```cmd
:: Create counter file
echo \Processor(_Total)\%% Processor Time > counters.txt
echo \Processor(_Total)\%% Privileged Time >> counters.txt
echo \Memory\Available MBytes >> counters.txt
echo \Memory\Pages/sec >> counters.txt
echo \Memory\Pool Nonpaged Bytes >> counters.txt
echo \PhysicalDisk(_Total)\Avg. Disk Queue Length >> counters.txt
echo \PhysicalDisk(_Total)\Disk Read Bytes/sec >> counters.txt
echo \PhysicalDisk(_Total)\Disk Write Bytes/sec >> counters.txt
echo \PhysicalDisk(_Total)\%% Disk Time >> counters.txt
echo \Network Interface(*)\Bytes Total/sec >> counters.txt
echo \Network Interface(*)\Output Queue Length >> counters.txt
echo \Network Interface(*)\Packets Outbound Errors >> counters.txt
echo \System\Processor Queue Length >> counters.txt
echo \System\Context Switches/sec >> counters.txt
echo \Process(*)\Handle Count >> counters.txt
echo \GPU Engine(*)\Utilization Percentage >> counters.txt

:: Create and start the data collector (1-second intervals)
logman create counter "DiagCapture" -cf "counters.txt" -si 1 -f bin -o "C:\DiagCapture\<timestamp>\perfmon_counters.blg" -ow
logman start "DiagCapture"

:: Stop and delete
logman stop "DiagCapture"
logman delete "DiagCapture"
```

### Key Counters for Gaming Lag

**Source:** [logman create counter (Microsoft Learn)](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/logman-create-counter) | [relog (Microsoft Learn)](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/relog)

**CPU:**

| Counter | Normal | Problem | Indicates |
|---|---|---|---|
| `\Processor(_Total)\% Processor Time` | <80% | >90% sustained | CPU saturation |
| `\Processor(*)\% DPC Time` | <5% | >15% | Driver interrupt overhead eating CPU budget |
| `\Processor(*)\% Interrupt Time` | <10% | >30% | Hardware/driver problem (confirm with LatencyMon) |
| `\Processor(_Total)\% Privileged Time` | <25% | >40% | Kernel/driver overhead |
| `\Processor(_Total)\Interrupts/sec` | Baseline | Spikes >50k/sec | Excessive hardware interrupt rate |
| `\Processor(_Total)\DPCs Queued/sec` | Baseline | Spikes correlating with stutter | DPC backlog building |
| `\System\Processor Queue Length` | <2 | **>2 sustained = bottleneck; >10 = critical** | Most direct CPU bottleneck signal |
| `\System\Context Switches/sec` | <20000 | Spikes correlating with stutter | Thread scheduler thrash |

**Memory:**

| Counter | Normal | Problem | Indicates |
|---|---|---|---|
| `\Memory\Available MBytes` | >4000 | **<400 warning; <100 critical** | RAM exhaustion, paging imminent |
| `\Memory\Pages/sec` | <20 | **>50 sustained = smoking gun** | RAM-to-disk paging causing stutter |
| `\Memory\Pool Nonpaged Bytes` | Stable | Steady growth = kernel leak | Driver memory leak |

**Disk:**

| Counter | Normal | Problem | Indicates |
|---|---|---|---|
| `\PhysicalDisk(*)\Avg. Disk Queue Length` | <1 (SSD) | **>1 sustained on SSD** | Disk I/O backlog |
| `\PhysicalDisk(*)\Avg. Disk sec/Read` | <0.5ms (NVMe) | >2ms on SSD | Unexpectedly slow reads |
| `\PhysicalDisk(*)\Disk Bytes/sec` | Variable | Near rated throughput | Disk saturated |

**Network:**

| Counter | Normal | Problem | Indicates |
|---|---|---|---|
| `\Network Interface(*)\Output Queue Length` | 0 | **Any sustained >0 = bottleneck** | Packets queuing behind NIC |
| `\Network Interface(*)\Packets Outbound Errors` | 0 | **Any non-zero** | NIC driver/hardware fault |

**GPU (WDDM 2.0+):**

| Counter | Normal | Problem | Indicates |
|---|---|---|---|
| `\GPU Engine(*)\Utilization Percentage` | Variable | 99-100% = GPU bottleneck | Use `*_engtype_3D` instance for render engine |
| `\GPU Process Memory(*)\Dedicated Usage` | <VRAM limit | Near VRAM capacity | Texture eviction causing hitches |

### Converting BLG to CSV (relog)

```cmd
:: Basic conversion — all counters, all samples
relog "perfmon_counters.blg" -f csv -o "perfmon_counters.csv"

:: Time-sliced — only the window when stuttering occurred
relog "perfmon_counters.blg" -f csv -o "stutter_window.csv" -b "4/9/2026 20:00:00" -e "4/9/2026 20:10:00"

:: Downsampled — every 5th sample (reduces size for long sessions)
relog "perfmon_counters.blg" -f csv -o "downsampled.csv" -t 5

:: Query what counters and time range exist in the BLG
relog "perfmon_counters.blg" -q
```

### Analysis Patterns in CSV

| Pattern | Diagnosis |
|---|---|
| `% Processor Time` >85% + `Processor Queue Length` >2 + `% DPC Time` >15% | **CPU + driver bottleneck** — confirm with LatencyMon drivers tab |
| `Available MBytes` trending down + `Pages/sec` >50 | **Memory exhaustion** — game paging to disk |
| `Avg. Disk Queue Length` >1 on SSD + `Avg. Disk sec/Read` spikes | **Disk I/O stall** — asset loading or AV scanning |
| `Output Queue Length` >0 + `Packets Outbound Errors` >0 | **Network bottleneck** — NIC driver or hardware issue |
| GPU `_engtype_3D` at 99% for non-game process | **GPU stolen** — background process using GPU |

---

## Tool 4: FrameView

**Path:** `C:\Program Files\NVIDIA Corporation\FrameView\FrameView_x64.exe`
**Ships with:** PresentMon_x64.exe (Microsoft's frame timing tool)

### What It Captures
Per-frame timing data including: FPS, frame time (ms), GPU busy time, GPU power draw, GPU temperature, GPU clock speed, CPU utilization.

### How to Use for Gaming Lag

1. Launch `FrameView_x64.exe`
2. Start your game — FrameView auto-detects the foreground game
3. Press the capture hotkey (default: F1 or configured in Settings.ini)
4. Play for 5+ minutes, reproducing the lag
5. Stop capture (same hotkey)
6. CSV file saved to Desktop or configured output folder

### Key Metrics in CSV Output

| Metric | What to Check |
|---|---|
| **Average FPS** | Baseline performance |
| **1% Low FPS** | Worst 1% of frames — stutters are visible when this is far below average |
| **0.1% Low FPS** | Worst 0.1% — extreme spikes. If avg=200 but 0.1%=15, you have major hitches |
| **Frame Time (ms)** | Should be flat. Spikes = visible stutters |
| **GPU Busy (%)** | <90% means CPU-bound; ~99% means GPU-bound |
| **GPU Clock (MHz)** | Drops during frame spikes = thermal throttling |
| **GPU Power (W)** | Drops correlate with throttling |

### Important Notes
- FrameView uses NVIDIA's PresentMon-based capture; very low overhead.
- The CSV output has millisecond timestamps — correlate with WPR/ProcMon by matching time ranges.
- Settings are in `Settings.ini` in the FrameView directory.

---

## Tool 5: LatencyMon

**Path:** `C:\Program Files\LatencyMon\LatMon.exe`

### What It Captures
Real-time DPC (Deferred Procedure Call) and ISR (Interrupt Service Request) latency per kernel driver.

### How to Use for Gaming Lag

1. Launch LatencyMon
2. Click **Start** (play button)
3. Run IDLE for 2 minutes — note the baseline
4. Launch game, play for 5 minutes during lag
5. Check results in the **Drivers** tab

### Interpreting Results

**Source:** [Resplendence LatencyMon guide](https://www.resplendence.com/latencymon_using)

| Color | Interrupt-to-Process Latency | Verdict |
|---|---|---|
| **Green** | <2,000 us | Suitable for real-time audio and gaming |
| **Orange** | 2,000-4,000 us | Doubtful — dropouts and stutter possible |
| **Red** | >4,000 us | Unsuitable — expect regular stutters and input lag |

### Key Values

| Value | Good | Problematic | What It Means |
|---|---|---|---|
| Highest interrupt-to-process latency | <1,000 us | >2,000 us | Worst-case input-to-response delay |
| Highest DPC execution time | <100 us | >500 us | Longest a driver held the CPU in a DPC |
| Highest ISR execution time | <100 us | >200 us | Longest a hardware interrupt handler ran |
| Hard pagefaults/sec | 0 | >0 sustained | Process blocked waiting for disk reads |

### Drivers Tab (Most Actionable)
Sort by **Highest DPC execution time** — the top entry is your primary culprit. Also check **Total DPC execution time** for cumulative offenders.

| Driver (.sys) | Hardware | Fix Action |
|---|---|---|
| `nvlddmkm.sys` | NVIDIA GPU | Update or DDU-clean reinstall GPU driver |
| `dxgkrnl.sys` | Windows GPU kernel | Windows Update or GPU driver update |
| `tcpip.sys` / `ndis.sys` | Network adapter | Update NIC driver, check firmware |
| `USBXHCI.sys` / `USBHUB3.sys` | USB controller | Disable USB devices one-by-one to isolate |
| `storport.sys` / `iaStorA.sys` | Storage controller | Update chipset/storage drivers |
| `HDAudBus.sys` | Audio device | Update or disable onboard audio |
| `ntoskrnl.exe` | Windows kernel | Disable C-states in BIOS, ensure High Perf power plan |
| `Wdf01000.sys` | WDF (peripheral drivers) | Often Razer/Corsair — check peripheral software |

### Tabs Explained

| Tab | Shows | Key Column |
|---|---|---|
| **Stats** | Overall verdict + headline numbers | Highest interrupt-to-process latency |
| **Drivers** | Per-driver DPC/ISR times | Sort: Highest DPC execution time |
| **Processes** | Per-process hard pagefault count | Game.exe with thousands of pagefaults = RAM issue |
| **CPUs** | Per-core DPC/ISR distribution | One core monopolized = no interrupt distribution |

### Gaming vs Idle Comparison

1. **Idle baseline:** Boot clean, close everything, run LatencyMon 15-20 min, save report
2. **Gaming session:** Start LatencyMon before game, play 15-30 min in stutter-prone areas, save report
3. **Compare:** If values dramatically higher in-game, GPU/storage drivers are culprit. If same as idle, stutter is frame-time variance (use FrameView instead)

**Key distinction:** LatencyMon detects kernel-level interrupt latency, NOT frame rendering time. A game can stutter from shader compilation without LatencyMon showing elevated DPCs.

### Exporting Results
- **File > Save Log** — plain text report of all tabs
- **Edit > Copy Report Text** — paste to clipboard
- Save to: `C:\DiagCapture\<timestamp>\latencymon_results.txt`

---

## Tool 6: HWiNFO64

**Path:** `C:\Users\L\Desktop\DiagCapture\Tools\HWiNFO64\HWiNFO64.exe`

### What It Captures
All hardware sensor data: CPU/GPU temperatures, clock speeds, power draw, VRM temps, fan speeds, throttling flags.

### How to Use for Gaming Lag

1. Launch HWiNFO64 in **Sensors-only mode** (checkbox at startup)
2. Click the **gear icon** (Settings) in the sensors window
3. Go to **Logging** tab:
   - Set **Log File** to `C:\DiagCapture\<timestamp>\hwinfo_sensors.csv`
   - Set **Log Interval** to 1000 ms (1 second)
   - Check **Log all values**
4. Click **Start Logging** button (green circle in toolbar)
5. Play game for 5+ minutes
6. Click **Stop Logging**

### Key Sensors for Gaming Lag

| Sensor | Normal | Throttle Threshold | Issue |
|---|---|---|---|
| CPU Package Temp | <85C | >95C | CPU thermal throttling |
| CPU Core Clock (all cores) | ~4700 MHz | Drops to <3000 MHz | Throttling reducing performance |
| GPU Temperature | <80C | >85C | GPU thermal throttling |
| GPU Clock | Boost clock | Significant drops under load | GPU power/thermal limiting |
| GPU Power | TDP range | Sudden drops | Power limit throttling |
| VRM Temperature | <90C | >100C | Motherboard VRM throttling CPU |
| **Thermal Throttling [Yes/No]** | No | Yes | Direct throttle indicator |
| CPU Package Power | Varies | Sudden drops | Power limit reached |

### Important Notes
- HWiNFO64 sensor logging adds negligible overhead (<0.5% CPU)
- The CSV has timestamps in every row — perfect for correlation
- Check the **Min** column after a session to see worst-case values
- If thermal throttling is detected, clean dust, repaste CPU/GPU, improve airflow

---

## Tool 7: WinMTR

**Path:** `C:\Users\L\Desktop\DiagCapture\Tools\WinMTR\WinMTR-v092\WinMTR_x64\WinMTR.exe`

### What It Captures
Continuous traceroute (ICMP + UDP) showing every network hop between you and a target, with loss percentage and latency per hop.

### How to Use for Gaming Lag

1. Launch WinMTR
2. Enter your **game server IP** in the Host field
3. Click **Start**
4. Let it run for 5-10 minutes while playing
5. Click **Stop**
6. Export: Copy to clipboard or File > Export

### Interpreting Results

| Hop | Loss % | What It Means |
|---|---|---|
| Hop 1 (your router) | >0% | Your local network has problems |
| Hops 2-3 (ISP) | >1% | ISP issue — contact them |
| Middle hops | Variable | Internet backbone — often shows loss that recovers |
| Last 2-3 hops (server) | >1% | Server-side issue — nothing you can do |

**Key rule:** Packet loss is only real if it persists to the final hop. Some routers deprioritize ICMP and show artificial loss at their hop while downstream is fine.

### Important Notes
- Wired Ethernet rules out WiFi jitter (you're on wired — good)
- Run WinMTR to your specific game server IP, not just 8.8.8.8
- High jitter (variance in latency) causes rubberbanding even without packet loss

---

## Tool 8: Continuous Ping

### What It Captures
Simple latency + packet loss over time to a target.

### Optimal Command

```cmd
:: Continuous ping with timestamps to log file
ping -t 1.1.1.1 > "C:\DiagCapture\<timestamp>\ping_log.txt" 2>&1

:: Ping game server specifically
ping -t <game_server_ip> > "C:\DiagCapture\<timestamp>\ping_game.txt" 2>&1
```

### Test Result
- Average latency to 1.1.1.1: **3ms** (excellent)
- Min/Max: 3ms/4ms (very low jitter)

---

## Correlation Strategy

All tools produce time-stamped data. To correlate:

1. **Align start times:** All tools started within ~5 seconds of each other by the orchestrator script.
2. **When FrameView shows a stutter spike at time T:**
   - Check WPA trace at time T for DPC/ISR spikes, CPU scheduling delays, disk I/O bursts
   - Check ProcMon at time T for which process was doing I/O
   - Check HWiNFO at time T for temperature spikes or clock drops
   - Check ping log at time T for latency spikes
   - Check PerfMon at time T for CPU queue length, context switch spikes
3. **Cross-reference the offender:** The tool that shows abnormal activity at the same timestamp as the stutter IS your root cause.

### Timeline Overlay Method

| Time | FrameView | WPA | ProcMon | HWiNFO | Ping |
|---|---|---|---|---|---|
| T=2:34 | 50ms spike | DPC from ndis.sys | Defender scanning game.exe | Normal | Normal |
| T=3:15 | 30ms spike | Disk I/O burst | pagefile.sys read | Normal | Normal |
| T=4:02 | 80ms spike | Normal CPU | Normal | CPU 98C, clock drop | Normal |

This table is what we build after capture to identify the exact root cause(s).

---

## Tool 9: SCEWIN (AMI Setup Control Environment for Windows)

**Path:** `C:\Users\L\Downloads\SCEWIN\5.05.01.0002\SCEWIN_64.exe`
**Source:** [SCEHUB (GitHub)](https://github.com/ab3lkaizen/SCEHUB) | [Win-Raid Forum Guide](https://winraid.level1techs.com/t/guide-fix-scewin-for-protected-z690-z790-to-easily-modify-hidden-bios-settings/94069) | [Blur Busters SCEWIN Thread](https://forums.blurbusters.com/viewtopic.php?t=13918)

### What It Does
Reads and writes UEFI/BIOS NVRAM variables from Windows. Exports ALL BIOS settings (including hidden ones not visible in BIOS GUI) to a text file. Allows modification and re-import.

**Critical safety note:** SCEWIN only modifies NVRAM variables, NOT the BIOS firmware. A CMOS clear always resets ALL changes. You cannot brick your board with SCEWIN.

### Prerequisites for ASUS ROG STRIX X670E-A

Before SCEWIN will work, enable these in BIOS:
1. **Setup > Tool** > Enable **"Publish HII Resources"**
2. **Setup > Advanced > UEFI Variables Protection** > Disable **"Password protection of Runtime Variables"**

### Command-Line Reference

```cmd
:: Export all BIOS settings to text file (read-only)
SCEWIN_64.exe /o /s nvram.txt

:: Export with human-readable format
SCEWIN_64.exe /o /s nvram.txt /hb /lang en-US

:: Export with platform override (if "Platform identification failed")
SCEWIN_64.exe /o /s nvram.txt /d

:: Import modified settings (WRITE — changes take effect on reboot)
SCEWIN_64.exe /i /s nvram.txt

:: Import with warnings suppressed
SCEWIN_64.exe /i /s nvram.txt /q

:: Read a single setting by map string
SCEWIN_64.exe /o /ms "Global C-state Control" /hb

:: Write a single setting by map string and hex value
SCEWIN_64.exe /i /ms "Global C-state Control" /qv 0x00 /hb
```

| Flag | Purpose |
|---|---|
| `/o` | Export (read from NVRAM) |
| `/i` | Import (write to NVRAM) |
| `/s <file>` | Script file path |
| `/d` | Override platform identification checks |
| `/q` | Suppress warnings during import |
| `/hb` | Human-readable output format |
| `/ms <string>` | Target a single setting by map string |
| `/qv <hex>` | Set value for single setting (with `/ms`) |
| `/cpwd <pw>` | Provide BIOS admin password |
| `/v` | Verbose output |

### NVRAM Export File Format

```
Setup Question = ASPM Support
Token          =2C    // Do NOT change this line
Offset         =45
Width          =01
BIOS Default   =[00]Disabled
Options        =[00]Disabled
               *[01]Enabled     <-- asterisk marks current selection
                [02]Auto
```

To change: move the `*` to the desired option. Never modify Token or Offset.

### AMD Ryzen 9800X3D / X670E — Settings to Audit

Search the `nvram.txt` export for these keywords. Settings marked with a skull are the most likely lag culprits.

**CPU Power Management:**

| Setting (search term) | Lag-Causing Value | Gaming-Optimal | Impact |
|---|---|---|---|
| **Global C-State Control** | Enabled/Auto | **Disabled** | Deep C-states add 50-200us wake-up latency per transition |
| **Power Supply Idle Control** | Low Current Idle | **Typical Current Idle** | AMD-specific: low current idle causes voltage droop/wobble |
| **Core Performance Boost** | Disabled | **Enabled** | Allows boost clocks (should be on) |
| **CPPC** | Disabled | **Enabled** | AMD scheduler hints to Windows for core selection |
| **CPPC Preferred Cores** | Disabled | **Enabled** | Tells Windows which cores are fastest |
| **C1E (Enhanced Halt)** | Enabled | **Disabled** | Drops to min frequency when idle, adds wake latency |

**PCIe & Device Power:**

| Setting | Lag-Causing | Gaming-Optimal | Impact |
|---|---|---|---|
| **ASPM Support** | Enabled/Auto | **Disabled** | PCIe link power savings add L0s/L1 wake latency (2-10us+) |
| **Native ASPM** | Enabled | **Disabled** | Prevents OS ASPM control |
| **L1 Substates** | Enabled | **Disabled** | Deep PCIe sub-states |
| **LTR (Latency Tolerance)** | Enabled | **Disabled** | Allows devices to request higher latency tolerance |
| **Above 4G Decoding** | Disabled | **Enabled** | Required for Resizable BAR |
| **Resizable BAR** | Disabled | **Enabled** | Full VRAM access for RTX 5070 Ti |

**Hidden Settings (only visible via SCEWIN):**

| Setting | Default | Gaming-Optimal | Impact |
|---|---|---|---|
| **Legacy IO Low Latency** | Disabled (ASUS) | **Enabled** | Reduces latency of legacy I/O. ASUS defaults to off, MSI to on. |
| **Power Down Mode** | Auto | **No Power Down** | Prevents memory controller power-down states |
| **Spread Spectrum (BCLK)** | Enabled | **Disabled** | Clock jitter for EMI compliance. Introduces timing variance. |

**Virtualization (if not using VMs/WSL2):**

| Setting | Lag-Causing | Gaming-Optimal | Impact |
|---|---|---|---|
| **SVM Mode** | Enabled | **Disabled** | AMD virtualization adds interrupt handling overhead |
| **IOMMU** | Enabled | **Disabled** | DMA remapping overhead on every I/O operation |

**Timers:**

| Setting | AMD AM5 Value | Why |
|---|---|---|
| **HPET** | **Keep Enabled** | AMD internal research: HPET on + `useplatformclock` off in Windows = best AM5 results |

### Red Flags to Search For in Export

After exporting, use these searches to find problems:

```
grep -i "C-State" nvram.txt        # Check C-state settings
grep -i "ASPM" nvram.txt           # Check PCIe power management
grep -i "Spread Spectrum" nvram.txt # Check clock jitter
grep -i "Power Down" nvram.txt     # Check memory power management
grep -i "Legacy IO" nvram.txt      # Check hidden low-latency setting
grep -i "SVM\|IOMMU" nvram.txt     # Check virtualization overhead
grep -i "Resizable BAR" nvram.txt  # Check GPU memory access
```

### Safety & Recovery

| Risk Level | What | Recovery |
|---|---|---|
| **None** | Export (`/o`) — read-only | N/A |
| **Low** | Disabling C-states, ASPM, Spread Spectrum | CMOS clear resets all |
| **Low** | Enabling Resizable BAR, Legacy IO Low Latency | CMOS clear resets all |
| **Medium** | Changing memory timings/voltage via NVRAM | CMOS clear required if no POST |
| **NEVER** | Modifying Token or Offset values in the file | Could corrupt variable store |

**Recovery methods:**
1. **CMOS Clear jumper** — power off, short jumper 10s, remove, power on
2. **CMOS battery removal** — power off, unplug, remove CR2032 for 5 min
3. **BIOS Flashback** — USB drive + flashback button on rear I/O
4. **Load Optimized Defaults** — F5/F9 in BIOS if system still POSTs

### Best Practice
- Always backup before editing: `SCEWIN_64.exe /o /s nvram_BACKUP.txt`
- Change max 4 settings at a time, reboot, test stability
- Know your CMOS clear jumper location before starting

---

## File Locations Summary

| File | Path |
|---|---|
| Orchestrator script | `C:\Users\L\Desktop\DiagCapture\capture_orchestrator.ps1` |
| Error documentation | `C:\Users\L\Desktop\DiagCapture\ERRORS_AND_FIXES.md` |
| Tool reference guide | `C:\Users\L\Desktop\DiagCapture\TOOL_REFERENCE_GUIDE.md` |
| Revert script | `C:\Users\L\Desktop\DiagCapture\REVERT_ALL_FIXES.ps1` |
| Test captures | `C:\DiagCapture\TEST\` |
| Auto-capture script | `C:\Users\L\Desktop\DiagCapture\auto_capture_5min.ps1` |
| SCEWIN tool | `C:\Users\L\Downloads\SCEWIN\5.05.01.0002\SCEWIN_64.exe` |
| BIOS export (after reboot) | `C:\Users\L\Desktop\DiagCapture\bios_nvram_export.txt` |
| Full capture output | `C:\DiagCapture\<timestamp>\` |
