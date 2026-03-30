# Windows Latency Optimization Report
## AMD Ryzen 7 9800X3D + RTX 5070 Ti + Intel I226-V + Windows 11 Build 26200

Generated: 2026-03-29 | Research-backed analysis with community benchmark references

---

## Table of Contents
1. [Timer Resolution](#1-timer-resolution)
2. [Power Plan](#2-power-plan)
3. [Process Scheduler](#3-process-scheduler)
4. [Memory Management](#4-memory-management)
5. [Network Adapter](#5-network-adapter-intel-i226-v)
6. [GPU Driver Tweaks](#6-gpu-driver-tweaks)
7. [USB Polling Rate](#7-usb-polling-rate)
8. [BIOS/Firmware](#8-biosfirmware)
9. [Windows Services](#9-windows-services)
10. [DWM / Multiplane Overlay](#10-dwm--multiplane-overlay)
11. [Context Switch Overhead](#11-context-switch-overhead)
12. [Storage Latency](#12-storage-latency)

---

## 1. Timer Resolution

### What It Does
Windows uses hardware timers (TSC, HPET, RTC) to schedule thread wakeups, sleep precision, and game loop timing. The default timer resolution is 15.625ms; games and multimedia apps request 1ms or 0.5ms resolution.

### Key Settings & Analysis

#### `bcdedit /set useplatformtick yes`
- **What**: Forces Windows to use RTC (Real Time Clock) tick instead of TSC tick
- **Windows 11 Note**: Windows 11 ALREADY uses RTC tick by default (`useplatformtick` is always on). This command is redundant on Win11 Build 26200.
- **Impact**: None on Win11
- **Verdict**: SKIP (already default behavior)

#### `bcdedit /set disabledynamictick yes`
- **What**: Prevents Windows from suppressing timer ticks during idle to save power
- **Windows 11 Note**: On Win11, combining `disabledynamictick` with the already-active `useplatformtick` can cause timer desynchronization issues. Multiple Blur Busters forum users report mouse acceleration artifacts when enabled on Win11.
- **Impact**: Marginal at best, potentially negative
- **Risk**: Medium (can cause input anomalies, requires reboot to revert)
- **Verdict**: SKIP on Windows 11

#### `bcdedit /deletevalue useplatformclock` (disable HPET sync)
- **What**: Prevents Windows from syncing to the HPET hardware timer, letting TSC run standalone
- **Zen 5 Relevance**: The 9800X3D supports invariant TSC (constant rate across all P/C/T-states). TSC is on-die (zero bus latency), while HPET lives on the southbridge (adds PCIe communication delay). Windows QPC already uses invariant TSC on Zen 5 when HPET sync is disabled.
- **Impact**: Marginal (removes HPET southbridge round-trip, ~microsecond level)
- **Risk**: Low (easily reversible: `bcdedit /set useplatformclock true`)
- **DO NOT** disable HPET in BIOS or Device Manager -- only use the bcdedit method. BIOS disable forces fallback to PMT (worse). Device Manager disable does nothing useful.
- **Verdict**: WORTH TESTING

#### Timer Resolution Tools (SetTimerResolution / ISLC)
- **What**: Forces the system-wide timer resolution to 0.5ms instead of the default 15.6ms or game-requested 1ms
- **Impact**: Marginal (the jump from 15.6ms to 1ms is significant; 1ms to 0.5ms is final polish felt mainly at 240Hz+ competitive play)
- **Risk**: Low
- **Verdict**: WORTH TESTING (use ISLC or TimerResolution.exe, benchmark with PresentMon/CapFrameX)

### TSC Behavior on Zen 5 (9800X3D)
- Zen 5 supports invariant TSC (CPUID bit Fn8000_0007:EDX[8])
- TSC rate is constant across all ACPI power states, boost states, and C-states
- Windows QPC automatically uses RDTSCP when invariant TSC is detected
- No known TSC bugs specific to Zen 5 (historical TSC issues were Zen 1/Zen+ era)

---

## 2. Power Plan

### What It Does
Controls CPU frequency scaling, core parking, idle state transitions, and boost behavior.

### Key Settings & Analysis

#### Ultimate Performance Plan
- **What**: `powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61`
  Disables core parking, minimizes idle states, keeps clocks primed for instant boost.
- **9800X3D Note**: Community consensus is that **Balanced** mode is actually superior for 9800X3D. The X3D's opportunistic boosting and fine-grained power control works best when allowed to manage its own states. Forcing all cores active can hit thermal limits faster and trigger frequency throttling.
- **Impact**: Marginal to Negative on 9800X3D
- **Risk**: Low (easily switchable)
- **Verdict**: SKIP -- use Balanced power plan

#### Core Parking Disable (CPMINCORES = 100%)
- **What**: `Powercfg -setacvalueindex scheme_current sub_processor CPMINCORES 100`
  Keeps all cores active at all times.
- **9800X3D Note**: On an 8C/16T chip with excellent single-thread boost, keeping all cores unparked wastes thermal headroom that the active cores could use for higher boost clocks. The 9800X3D's V-cache gaming advantage is single-thread dependent.
- **Impact**: Marginal (may improve 1% lows by ~1-2ms at cost of thermal headroom)
- **Risk**: Low
- **Verdict**: SKIP (thermal headroom more valuable than eliminating ~5us unpark latency)

#### PerfBoostMode (Processor Performance Boost Mode)
- **What**: Controls CPU boost algorithm. Options: Disabled/Enabled/Aggressive/Efficient Aggressive
- **All three default power plans** already set this to "Aggressive"
- **Impact**: None (already maxed)
- **Verdict**: SKIP (verify it's Aggressive, don't change)

#### Processor Performance Time Check Interval
- **What**: How frequently Windows re-evaluates CPU utilization for frequency scaling decisions
- **Impact**: Marginal (reducing interval makes scaling more responsive but increases scheduler overhead)
- **Risk**: Medium
- **Verdict**: SKIP

---

## 3. Process Scheduler (Win32PrioritySeparation)

### What It Does
Controls three scheduling parameters via a single registry DWORD at `HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl\Win32PrioritySeparation`:
- **Quantum length**: Short (6ms) vs Long (12ms) -- how long a thread runs before preemption check
- **Quantum type**: Fixed (equal for all) vs Variable (foreground gets more)
- **Foreground boost**: 0x (none), 1x (medium/2:1), 2x (high/3:1 ratio for foreground app)

### Recommended Values for Gaming

| Value (Dec) | Quantum | Type | FG Boost | Use Case |
|---|---|---|---|---|
| 38 (default) | Short | Variable | High | Windows default for desktop |
| 22 | Long | Fixed | High | Smoothest gameplay, minimal context switching |
| 40 | Short | Fixed | None | Lowest theoretical input latency |
| 42 (0x2A) | Short | Fixed | High | Aggressive gaming, may hurt multitasking |

### Analysis
- **Dec 22** (long, fixed, high boost): Minimizes context switching overhead. Each context switch costs ~5us plus cache invalidation. Longer quanta = fewer switches = more consistent frame times. Recommended by Calypto's Latency Guide for smooth gameplay.
- **Dec 42 (0x2A)** (short, fixed, high boost): More responsive input sampling but more context switches. Better for competitive shooters where input latency matters more than frame consistency.
- **No reboot required** -- changes apply immediately. Test in-game with regedit open.

### Verdict
- **Impact**: Moderate (measurable frame-time consistency improvement)
- **Risk**: Low (instantly reversible, no reboot)
- **Relevance**: High -- the 9800X3D's large V-cache benefits from longer uninterrupted execution (fewer cache evictions from context switches)
- **Verdict**: RECOMMENDED
  - Start with **Dec 22** for general gaming
  - Try **Dec 42** for competitive FPS titles
  - Benchmark with CapFrameX frame-time analysis

---

## 4. Memory Management

### What It Does
Registry tweaks under `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management` that control kernel paging, caching, and compression behavior.

### Key Settings & Analysis

#### DisablePagingExecutive = 1
- **What**: Keeps kernel-mode drivers in physical RAM instead of allowing them to be paged to disk
- **Reality**: Only affects `ntoskrnl.exe` paging. Does NOT disable the pagefile or affect application memory. Commonly misunderstood.
- **Impact**: None to Marginal (kernel drivers are rarely paged on systems with 32GB+ RAM)
- **Risk**: Low
- **Verdict**: SKIP (placebo on modern systems with ample RAM)

#### LargeSystemCache = 1
- **What**: Tells Windows to use all available RAM minus 4MB for filesystem cache
- **Impact**: None for gaming (games don't benefit from filesystem cache -- they load assets into GPU VRAM)
- **Risk**: Medium (can starve game processes of RAM if they need it)
- **Verdict**: SKIP

#### IoPageLockLimit
- **What**: Maximum bytes the system can lock for I/O operations
- **Impact**: None for gaming
- **Risk**: Low
- **Verdict**: SKIP

#### Disable Memory Compression (`Disable-MMAgent -mc`)
- **What**: Windows compresses infrequently used memory pages instead of writing to pagefile. Decompression uses CPU cycles.
- **Impact**: Moderate on systems with 16GB RAM; Marginal on 32GB+ (compression rarely activates with ample RAM)
- **Risk**: Low (easily reversible: `Enable-MMAgent -mc`)
- **Relevance**: If running 32GB+ RAM, compression rarely engages. If 16GB, disabling removes CPU overhead during memory pressure.
- Multiple Steam community reports confirm disabling memory compression fixed game stuttering (Horizon Zero Dawn, etc.)
- **Verdict**: RECOMMENDED if 16GB RAM; WORTH TESTING if 32GB+

#### SysMain/SuperFetch Disable
- **Covered in Section 9 (Windows Services)**

---

## 5. Network Adapter (Intel I226-V)

### What It Does
The Intel I226-V is a 2.5GbE controller with known quirks. Network adapter settings control how packets are batched, interrupted, and processed.

### Key Settings & Analysis

#### Interrupt Moderation = Disabled
- **What**: Stops the NIC from batching interrupts. Each packet generates an immediate interrupt.
- **Impact**: Moderate (removes up to 1ms of interrupt coalescing delay)
- **Risk**: Low (slightly higher CPU usage from more frequent interrupts, negligible on 9800X3D)
- **I226-V Note**: Intel's own low-latency profile sets interrupt moderation to OFF
- **Verdict**: RECOMMENDED

#### RSS (Receive Side Scaling) = Enabled
- **What**: Distributes receive processing across multiple CPU cores
- **CRITICAL NOTE**: Intel has DROPPED RSS support for I226-V in recent drivers. Check your driver version -- if RSS is unavailable, this is expected behavior, not a misconfiguration.
- **Impact**: Moderate (when available, distributes network processing load)
- **Risk**: Low
- **Verdict**: RECOMMENDED (enable if available in your driver version)

#### Energy Efficient Ethernet (EEE) = Disabled
- **What**: Prevents the NIC from entering low-power states during idle periods
- **Impact**: Moderate (eliminates wake-from-idle latency spikes)
- **Risk**: Low
- **Verdict**: RECOMMENDED

#### Large Send Offload (LSO) = Disabled
- **What**: Offloads TCP segmentation to the NIC. Can cause packet fragmentation issues.
- **Impact**: Marginal
- **Risk**: Low
- **Verdict**: RECOMMENDED

#### TCP Checksum Offload = Disabled
- **What**: Forces CPU to handle TCP checksums instead of the NIC
- **Impact**: Marginal (CPU is faster at this than the I226-V's offload engine)
- **Risk**: Low
- **Verdict**: WORTH TESTING

#### Flow Control = Disabled
- **What**: Prevents the NIC from telling the switch to slow down
- **Impact**: Marginal (prevents occasional pauses in packet flow)
- **Risk**: Low
- **Verdict**: RECOMMENDED

#### Nagle Algorithm Disable (TcpNoDelay=1, TcpAckFrequency=1)
- **What**: Registry tweak per network interface that disables packet batching (Nagle) and delayed ACKs
- **Location**: `HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{GUID}`
- **Impact**: Moderate for online games (removes up to 200ms of Nagle delay on small packets)
- **Risk**: Low (slightly increased packet count on network)
- **Note**: Some games already set TCP_NODELAY in their socket code, making this redundant
- **Verdict**: RECOMMENDED for online gaming

#### TCP Auto-Tuning
- **What**: `netsh int tcp set global autotuninglevel=normal` (default) dynamically adjusts receive window
- **Impact**: Marginal (auto-tuning is generally correct; only change if experiencing specific throughput issues)
- **Risk**: Low
- **Verdict**: SKIP (leave at normal)

#### I226-V Stability Fix
- **Known Issue**: I226-V has PCIe compatibility problems causing disconnects under load
- **Fix**: In BIOS, set the I226-V's PCIe lane to Gen 3 (instead of Auto/Gen 4/Gen 5)
- **Impact**: Significant (fixes random disconnects, no performance penalty for 2.5GbE)
- **Risk**: Low
- **Verdict**: RECOMMENDED (if experiencing any network instability)

---

## 6. GPU Driver Tweaks (NVIDIA RTX 5070 Ti)

### Key Settings & Analysis

#### NVIDIA Reflex / Reflex 2
- **What**: Engine-level render queue management. Reflex 2 adds Frame Warp (updates frame with latest mouse input before scanout).
- **Benchmarks**: RTX 5070 Ti in The Finals: 56ms (no Reflex) -> 27ms (Reflex) -> 8ms (Reflex 2). Up to 75% latency reduction.
- **Impact**: Significant (the single most impactful latency optimization available)
- **Risk**: Low (per-game toggle)
- **Note**: Reflex OVERRIDES both Low Latency Mode and Max Pre-Rendered Frames settings
- **Verdict**: RECOMMENDED (enable in every supported game)

#### Max Pre-Rendered Frames / Low Latency Mode
- **What**: Controls the CPU-side render queue depth. "Ultra" = 0 frames queued.
- **Impact**: Moderate when Reflex is unavailable; None when Reflex is active (Reflex overrides this)
- **Risk**: Low
- **Verdict**: RECOMMENDED as fallback (set to 1 or Ultra in NVCP for non-Reflex games)

#### Shader Cache Size
- **What**: Disk cache for compiled shaders. Prevents recompilation stuttering on subsequent game launches.
- **Impact**: Moderate (eliminates shader compilation stutter after first run)
- **Risk**: Low
- **Recommendation**: Set to Unlimited on SSD (no reason to limit on NVMe)
- **Verdict**: RECOMMENDED

#### Threaded Optimization
- **What**: Allows driver to offload GPU tasks to multiple CPU threads
- **Impact**: Marginal (Auto is usually correct; some older games need it Off)
- **Risk**: Low
- **Verdict**: SKIP (leave on Auto; only change per-game profile if issues arise)

#### Power Management Mode = Prefer Maximum Performance
- **What**: Prevents GPU from downclocking during lighter scenes
- **Impact**: Moderate (eliminates GPU clock ramp-up latency of 10-50ms)
- **Risk**: Low (slightly higher idle power/temp)
- **Verdict**: RECOMMENDED

#### NVIDIA Profile Inspector (NPI) Compatibility Warning
- **RTX 50 Series Note**: NPI conflicts with the NVIDIA App. If NVIDIA App is installed, it will immediately overwrite any NPI settings. You must fully uninstall NVIDIA App to use NPI.
- If using NPI on RTX 5070 Ti, it can enable Multi-Frame Generation, DLSS overrides, ReBAR settings, and per-game shader cache sizes.

---

## 7. USB Polling Rate

### What It Does
Controls how frequently Windows polls USB HID devices (mouse, keyboard) for new input data.

### Key Settings & Analysis

#### Default vs 1000Hz vs 8000Hz
| Polling Rate | Worst-Case Input Age | Improvement Over Previous |
|---|---|---|
| 125Hz (default) | 8ms | -- |
| 1000Hz | 1ms | -7ms (significant) |
| 4000Hz | 0.25ms | -0.75ms (marginal) |
| 8000Hz | 0.125ms | -0.125ms (negligible) |

#### Registry bInterval Override (HIDUSBF)
- **What**: Overrides the USB HID descriptor's polling interval at the driver level
- **Method**: HIDUSBF driver filters the bInterval value, telling Windows to poll at the overridden rate
- **HVCI Conflict**: Windows 11 with Memory Integrity (HVCI) enabled blocks unsigned drivers including HIDUSBF. Must temporarily disable Core Isolation > Memory Integrity.
- **Anti-Cheat Risk**: Vanguard, EasyAntiCheat may flag HIDUSBF as suspicious
- **Impact**: Significant (125Hz -> 1000Hz); Marginal (1000Hz -> 8000Hz)
- **Risk**: Medium (requires driver signing bypass, may trigger anti-cheat)
- **Verdict**: SKIP the registry hack -- buy a mouse with native 1000Hz+ polling instead

#### Native High Polling Rate Mice
- Most modern gaming mice support 1000Hz natively; some support 4000Hz/8000Hz
- **Windows 11 24H2+** has native improvements for high polling rate mice (fixed background app message throttling)
- **CPU overhead**: 8000Hz generates 8x more USB interrupts. Negligible on 9800X3D but can cause DPC issues if interrupt affinity isn't set correctly
- **Verdict**: Native 1000Hz is RECOMMENDED; 4000Hz+ is WORTH TESTING if mouse supports it

---

## 8. BIOS/Firmware

### Key Settings & Analysis

#### C-States (Global C-State Control)
- **What**: Controls CPU idle power states (C0=active, C1=halt, C6=deep sleep)
- **9800X3D Specific**: AM5 boards ship with C-States set to "Auto" (effectively OFF). Multiple users report that ENABLING C-States actually reduces stuttering on 9800X3D. This is counterintuitive but well-documented in the Zen 5 X3D Owner's Club threads.
- **Impact**: Moderate (can fix game stuttering on AM5)
- **Risk**: Low (easily toggled in BIOS)
- **Verdict**: RECOMMENDED -- try ENABLING C-States (change from Auto to Enabled)

#### AMD Cool'n'Quiet
- **What**: Legacy power management for frequency/voltage scaling
- **9800X3D Note**: Superseded by CPPC2 on Zen 5. Disabling has no measurable impact.
- **Impact**: None
- **Verdict**: SKIP

#### PBO (Precision Boost Overdrive) + Curve Optimizer
- **What**: PBO allows the CPU to exceed stock power limits for higher boost. Curve Optimizer applies per-core voltage offsets for stability at lower voltages.
- **Impact**: Significant (5-15% single-thread boost improvement with proper tuning)
- **Risk**: Medium (requires per-core stability testing; improper CO values cause crashes)
- **Process**: Enable PBO, then apply negative CO offsets per core (-10 to -30 typical), stress test each core individually (CoreCycler recommended)
- **MSI Enhanced PBO**: Can unlock up to 15% additional performance on Zen 5
- **Verdict**: RECOMMENDED (but requires careful stability testing)

#### SVM (Secure Virtual Machine) Disable
- **What**: Disables AMD-V hardware virtualization
- **Impact**: Mixed results. Some users report fixing game stuttering (Spider-Man Remastered). Others report LOWER FPS with SVM off in GPU-limited titles.
- **Root Cause**: The stuttering is typically caused by Windows VBS (Virtualization Based Security) / Core Isolation, not SVM itself. Disabling SVM is a sledgehammer approach.
- **Risk**: Medium (breaks Hyper-V, WSL2, WSA, Docker, some anti-cheat)
- **Better Alternative**: Disable VBS/HVCI via `bcdedit /set hypervisorlaunchtype off` while keeping SVM enabled
- **Verdict**: WORTH TESTING (disable VBS first; only disable SVM if VBS disable alone doesn't fix stuttering)

#### IOMMU
- **What**: Hardware I/O memory management unit for DMA isolation
- **9800X3D + RTX 5070 Ti**: IOMMU should generally stay ENABLED for Resizable BAR / Smart Access Memory support. Disabling IOMMU disables ReBAR.
- **Impact**: Negative if disabled (loses ReBAR performance benefit)
- **Risk**: Medium
- **Better approach**: Keep IOMMU enabled, disable Pre-Boot DMA Protection and Kernel DMA Protection if experiencing DMA-related issues
- **Verdict**: SKIP (keep enabled for ReBAR)

#### fTPM (Firmware TPM)
- **What**: AMD's firmware-based TPM implementation
- **Known Issue**: AMD documented that fTPM can cause intermittent system stuttering due to extended SPIROM memory transactions. Fixed in AGESA 1207+ BIOS updates.
- **Impact**: Moderate (eliminates periodic stutter spikes if on old AGESA)
- **Risk**: Medium (Windows 11 requires TPM 2.0; disabling breaks BitLocker and some features)
- **Verdict**: UPDATE BIOS to latest AGESA first. If stuttering persists, switch to dTPM hardware module or disable fTPM (only if you don't need TPM features)

---

## 9. Windows Services

### Key Settings & Analysis

#### SysMain (SuperFetch) = Disabled
- **What**: Predictive app preloading into RAM. Designed for HDDs, redundant on NVMe.
- **Impact**: Moderate (removes 100-300MB RAM usage + periodic disk/CPU spikes from usage analysis)
- **Risk**: Low (easily re-enabled; app launch times unaffected on NVMe)
- **Verdict**: RECOMMENDED

#### DiagTrack (Connected User Experiences and Telemetry) = Disabled
- **What**: Sends diagnostic/telemetry data to Microsoft. Causes periodic CPU, disk, and network spikes.
- **Impact**: Moderate (eliminates background telemetry processing spikes)
- **Risk**: Low (some Xbox/Game Pass features may degrade)
- **How**: `Stop-Service DiagTrack; Set-Service DiagTrack -StartupType Disabled`
- **Verdict**: RECOMMENDED

#### Delivery Optimization = Disabled
- **What**: Peer-to-peer Windows Update distribution. Uses bandwidth and CPU in background.
- **Impact**: Marginal
- **Risk**: Low (updates still work, just from Microsoft servers only)
- **Verdict**: RECOMMENDED

#### Windows Search (WSearch) = Manual or Disabled
- **What**: Background file indexing service
- **Impact**: Marginal (periodic indexing spikes)
- **Risk**: Low (disabling removes Start Menu search and file search from Explorer)
- **Verdict**: WORTH TESTING (set to Manual if you use Windows Search occasionally)

#### Additional Task Scheduler Cleanup
- Disable tasks under `Microsoft\Windows\Customer Experience Improvement Program` (Consolidator, UsbCeip)
- Disable `Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser`
- **Impact**: Marginal (removes scheduled telemetry jobs)
- **Risk**: Low
- **Verdict**: RECOMMENDED

---

## 10. DWM / Multiplane Overlay

### What It Does
Desktop Window Manager (DWM) composites all windows. Multiplane Overlay (MPO) lets games bypass DWM composition for lower latency in windowed/borderless mode.

### Key Settings & Analysis

#### MPO (Multiplane Overlay) Status
- **What**: Since NVIDIA driver 461.09, MPO allows windowed games to present independently of DWM, enabling VSync control and reducing windowed latency.
- **2025 Note**: The old registry tweak to disable MPO (`OverlayTestMode=5`) reportedly no longer works on current Windows 11 builds. The current method uses:
  ```
  HKLM\SOFTWARE\Microsoft\Windows\Dwm
  OverlayTestMode = DWORD 5
  EnableOverlay = DWORD 0
  ```
- **Should You Disable MPO?**: Only if experiencing flickering or stutter in windowed mode. MPO generally REDUCES latency in windowed games -- disabling it adds latency.
- **Impact**: Significant if MPO is causing issues; Negative if disabled unnecessarily
- **Risk**: Low (registry change, reversible)
- **Verdict**: SKIP (keep MPO enabled unless experiencing flickering artifacts)

#### Fullscreen Exclusive vs Borderless Windowed
- With MPO + NVIDIA Reflex, borderless windowed now matches fullscreen exclusive latency
- Hardware: Independent Flip and Hardware Composed: Independent Flip both bypass DWM composition
- **Verdict**: Use borderless windowed with Reflex -- no latency penalty vs fullscreen exclusive

#### VSync + Frame Limiter Strategy
- **Optimal Setup**: Enable VRR (G-SYNC) + Enable VSync (in NVCP) + In-game FPS cap 3-5 below max refresh rate + Keep GPU usage below 95%
- **Why VSync ON with G-SYNC**: Prevents tearing at the edges of VRR range without adding latency (VSync only activates as a frametime limiter when at the ceiling)
- **Impact**: Moderate (eliminates tearing + render queue buildup)
- **Risk**: Low
- **Verdict**: RECOMMENDED

#### OverlayMinFPS = 0
- **What**: `HKLM\Software\Microsoft\Windows\Dwm\OverlayMinFPS = DWORD 0`
  Disables DWM's minimum FPS requirement for overlay plane assignment. Prevents low-FPS apps (Discord, browsers) from causing MPO plane reassignment flicker.
- **Impact**: Marginal (fixes specific Discord/overlay flickering issues)
- **Risk**: Low
- **Verdict**: WORTH TESTING (if experiencing overlay app flickering)

---

## 11. Context Switch Overhead

### What It Does
Every time Windows switches CPU execution between threads, it costs ~5us plus cache invalidation overhead. Reducing unnecessary context switches keeps the game's working set in cache longer.

### Key Settings & Analysis

#### Thread Quantum Tuning
- **Covered in Section 3** (Win32PrioritySeparation)
- Longer quanta = fewer context switches = better cache utilization
- The 9800X3D's 96MB V-cache benefits enormously from fewer cache evictions
- **Verdict**: See Section 3 recommendations

#### CPU Sets API
- **What**: Windows API that lets applications claim exclusive access to specific CPU cores, preventing other threads from being scheduled there
- **How**: Game must call `SetProcessDefaultCpuSets()` or use Process Lasso/ParkControl to assign CPU sets
- **Impact**: Moderate (eliminates context switches on game-dedicated cores)
- **Risk**: Low (application-level, doesn't affect system stability)
- **Note**: Most games don't use this API. Third-party tools like Process Lasso can approximate it with CPU affinity + priority rules.
- **Verdict**: WORTH TESTING (via Process Lasso CPU affinity for your primary game)

#### Microsoft's Guidance
- Target: fewer than 1,000 context switches per second per core for gaming workloads
- Use WPA (Windows Performance Analyzer) with CPU Usage (Precise) to measure
- **Verdict**: Monitor with WPA before and after other tweaks to validate improvement

---

## 12. Storage Latency

### What It Does
NVMe power state transitions and AHCI link power management can introduce latency spikes when the drive wakes from low-power states during game asset loading.

### Key Settings & Analysis

#### AHCI Link Power Management = Active (Disabled)
- **What**: Power plan setting under PCI Express > Link State Power Management
- Set to "Off" in power plan advanced settings
- Also: `HKLM\SYSTEM\CurrentControlSet\Services\storahci\Parameters\Device\EnableHIPM = 0` and `EnableDIPM = 0`
- **Impact**: Moderate (eliminates SATA link wake-from-idle latency of ~10-100ms)
- **Risk**: Low (slightly higher idle power)
- **Verdict**: RECOMMENDED

#### NVMe Power State Transitions (StorNVMe)
- **What**: Windows StorNVMe driver transitions NVMe to low-power states during idle. Waking adds latency (ENLAT+EXLAT values from NVMe spec).
- **Settings**:
  - Primary NVMe Idle Timeout: `powercfg -setacvalueindex scheme_current SUB_DISK d639518a-e56d-4345-8af2-b9f32fb26109 0`
  - Primary NVMe Latency Tolerance: `powercfg -setacvalueindex scheme_current SUB_DISK fc95af4d-40e7-4b6d-835a-56d131dbc80e 0`
  - Disable NOPME (Non-Operational Power Management): `powercfg -setacvalueindex scheme_current SUB_DISK d639518a-e56d-4345-8af2-b9f32fb26109 0`
  - Apply: `powercfg -setactive scheme_current`
- **Impact**: Moderate (prevents NVMe wake latency spikes during streaming asset loads)
- **Risk**: Low (slightly higher NVMe idle power/temp)
- **Verdict**: RECOMMENDED

#### PCIe ASPM (Active State Power Management) = Disabled
- **What**: PCIe link power saving. Can cause NVMe queue stalls on wake.
- Set via BIOS or power plan: PCI Express > Link State Power Management = Off
- **Impact**: Moderate
- **Risk**: Low
- **Verdict**: RECOMMENDED

---

## Summary Matrix

| # | Optimization | Impact | Risk | Relevance to 9800X3D+5070Ti | Verdict |
|---|---|---|---|---|---|
| 1a | useplatformtick | None | Low | N/A (Win11 default) | SKIP |
| 1b | disabledynamictick | Marginal/Negative | Medium | Can cause input issues on Win11 | SKIP |
| 1c | Disable HPET sync (bcdedit) | Marginal | Low | TSC is on-die, faster | WORTH TESTING |
| 1d | Timer resolution 0.5ms | Marginal | Low | Polish for 240Hz+ | WORTH TESTING |
| 2a | Ultimate Performance plan | Marginal/Negative | Low | Hurts X3D boost behavior | SKIP |
| 2b | Core parking disable | Marginal | Low | Wastes thermal headroom | SKIP |
| 3 | Win32PrioritySeparation | Moderate | Low | V-cache benefits from fewer ctx switches | RECOMMENDED |
| 4a | DisablePagingExecutive | None | Low | Placebo on 32GB+ | SKIP |
| 4b | LargeSystemCache | None | Medium | Not relevant to gaming | SKIP |
| 4c | Disable memory compression | Moderate | Low | Depends on RAM amount | RECOMMENDED (16GB) |
| 5a | Interrupt moderation off | Moderate | Low | I226-V low-latency profile | RECOMMENDED |
| 5b | Disable EEE/LSO/Flow Control | Moderate | Low | I226-V best practices | RECOMMENDED |
| 5c | Nagle disable | Moderate | Low | Helps online games | RECOMMENDED |
| 5d | I226-V PCIe Gen 3 fix | Significant | Low | Fixes known instability | RECOMMENDED |
| 6a | NVIDIA Reflex 2 | Significant | Low | Up to 75% latency reduction | RECOMMENDED |
| 6b | Max pre-rendered frames=1 | Moderate | Low | Fallback for non-Reflex games | RECOMMENDED |
| 6c | Shader cache unlimited | Moderate | Low | Eliminates compile stutter | RECOMMENDED |
| 6d | GPU power = max performance | Moderate | Low | No clock ramp delay | RECOMMENDED |
| 7a | Native 1000Hz mouse polling | Significant | Low | 7ms improvement over 125Hz | RECOMMENDED |
| 7b | 8000Hz via HIDUSBF | Marginal | Medium | Anti-cheat risk, HVCI conflict | SKIP |
| 8a | C-States ENABLE | Moderate | Low | Fixes AM5 stuttering | RECOMMENDED |
| 8b | PBO + Curve Optimizer | Significant | Medium | 5-15% boost improvement | RECOMMENDED |
| 8c | SVM disable | Mixed | Medium | Better to disable VBS instead | WORTH TESTING |
| 8d | IOMMU disable | Negative | Medium | Loses ReBAR | SKIP |
| 8e | fTPM fix | Moderate | Medium | Update BIOS to latest AGESA | RECOMMENDED |
| 9a | SysMain disable | Moderate | Low | Redundant on NVMe | RECOMMENDED |
| 9b | DiagTrack disable | Moderate | Low | Removes telemetry spikes | RECOMMENDED |
| 9c | Delivery Optimization off | Marginal | Low | Removes P2P update traffic | RECOMMENDED |
| 10a | MPO disable | Negative | Low | MPO reduces windowed latency | SKIP |
| 10b | VSync+GSync+FPS cap | Moderate | Low | Optimal frame delivery | RECOMMENDED |
| 10c | OverlayMinFPS=0 | Marginal | Low | Fixes overlay flicker | WORTH TESTING |
| 11 | CPU affinity/sets | Moderate | Low | Reduce context switches | WORTH TESTING |
| 12a | AHCI link PM disable | Moderate | Low | Eliminates disk wake latency | RECOMMENDED |
| 12b | NVMe idle timeout=0 | Moderate | Low | Prevents NVMe sleep | RECOMMENDED |
| 12c | PCIe ASPM disable | Moderate | Low | Prevents link sleep | RECOMMENDED |

---

## Priority Implementation Order

### Tier 1: Do First (Highest Impact, Lowest Risk)
1. Enable NVIDIA Reflex 2 in all supported games
2. Win32PrioritySeparation = 22 (or 42 for competitive)
3. I226-V: Disable interrupt moderation, EEE, LSO, Flow Control
4. Nagle disable (TcpNoDelay=1, TcpAckFrequency=1)
5. BIOS: Enable C-States, update to latest AGESA for fTPM fix
6. Disable SysMain and DiagTrack services
7. NVCP: Shader cache unlimited, Power = max performance, Low Latency = Ultra (non-Reflex games)

### Tier 2: Do Second (Moderate Impact, Some Testing Required)
8. PBO + Curve Optimizer tuning (per-core stability testing)
9. NVMe power management: idle timeout=0, latency tolerance=0
10. AHCI link PM and PCIe ASPM disable
11. I226-V PCIe Gen 3 fix (if experiencing disconnects)
12. VSync + G-SYNC + FPS cap strategy

### Tier 3: Test and Validate (Marginal Impact, System-Dependent)
13. Disable VBS/HVCI (`bcdedit /set hypervisorlaunchtype off`)
14. Timer resolution 0.5ms (ISLC)
15. Disable HPET sync (`bcdedit /deletevalue useplatformclock`)
16. CPU affinity tuning via Process Lasso
17. Disable memory compression (if 16GB RAM)
18. OverlayMinFPS=0 for DWM

### Do NOT Do
- Do NOT use Ultimate Performance power plan (use Balanced for 9800X3D)
- Do NOT disable core parking (wastes thermal headroom)
- Do NOT disable IOMMU (loses ReBAR)
- Do NOT disable MPO (increases windowed latency)
- Do NOT use `disabledynamictick` on Windows 11
- Do NOT use HIDUSBF registry hack (anti-cheat and HVCI conflicts)
- Do NOT set DisablePagingExecutive or LargeSystemCache (placebo)

---

## Measurement Tools

Always benchmark before and after changes:
- **CapFrameX**: Frame time analysis, 1% / 0.1% lows
- **PresentMon**: Microsoft's presentation latency tool (flip model, frame queue)
- **LatencyMon**: DPC latency, ISR latency, hard pagefault monitoring
- **NVIDIA FrameView**: End-to-end latency measurement with Reflex
- **WPA (Windows Performance Analyzer)**: Context switch analysis, CPU scheduling
- **TimerBench**: Timer resolution verification
- **NVIDIA Profile Inspector**: MPO indicator overlay for verifying overlay plane status

---

## Sources

- [Melody's Tweaks - Timer Misconceptions](https://sites.google.com/view/melodystweaks/misconceptions-about-timers-hpet-tsc-pmt)
- [Blur Busters Forums - useplatformtick](https://forums.blurbusters.com/viewtopic.php?t=8643)
- [XbitLabs - Win32PrioritySeparation](https://www.xbitlabs.com/win32priorityseparation-performance/)
- [Intel I226-V Settings - Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/3889480/controller-intel-i226-v)
- [Intel Interrupt Moderation Rate](https://edc.intel.com/content/www/us/en/design/products/ethernet/adapters-and-devices-user-guide/interrupt-moderation-rate/)
- [NVIDIA Reflex 2 Announcement](https://www.nvidia.com/en-us/geforce/news/reflex-2-even-lower-latency-gameplay-with-frame-warp/)
- [NVIDIA V-Sync + MPO Guidance](https://nvidia.custhelp.com/app/answers/detail/a_id/5159)
- [AMD fTPM Stutter Advisory](https://www.amd.com/en/resources/support-articles/faqs/PA-410.html)
- [Zen 5 X3D Owner's Club](https://www.overclock.net/threads/official-zen-5-x3d-owners-club-9800x3d-9900x3d-9950x3d.1812505/)
- [Microsoft NVMe Power Management](https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/power-management-for-storage-hardware-devices-nvme)
- [Microsoft Network Adapter Tuning](https://learn.microsoft.com/en-us/windows-server/networking/technologies/network-subsystem/net-sub-performance-tuning-nics)
- [Microsoft High Resolution Timestamps / QPC](https://learn.microsoft.com/en-us/windows/win32/sysinfo/acquiring-high-resolution-time-stamps)
- [Microsoft GDK - Context Switch Guidance](https://learn.microsoft.com/en-us/gaming/gdk/_content/gc/system/overviews/finding-threading-issues/high-context-switches)
- [ParkControl - Core Parking Tool](https://bitsum.com/parkcontrol/)
- [Guru3D - MPO Disable 2025](https://forums.guru3d.com/threads/disabling-mpo-multiplane-overlay-in-2025.455222/)
- [Windows 11 24H2 High Polling Rate Fix](https://forums.blurbusters.com/viewtopic.php?t=12157)
- [Overclock.net - SVM/IOMMU Discussion](https://www.overclock.net/threads/svm-mode-and-iommu-mode-should-be-disabled-or-enabled.1814485/)
