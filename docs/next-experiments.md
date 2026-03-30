# Next Experiments Roadmap

Ranked list of optimization experiments to test against the EXP00 clean baseline. Each experiment changes ONE variable to isolate its effect.

**Baseline:** EXP00 — DPC% 0.134%, Interrupt% 0.076%, CPU 0 share 1.1%

---

## Tier 1: RECOMMENDED (Proven Impact, Low Risk)

### EXP01 — Timer Resolution: Disable Dynamic Tick
```
bcdedit /set disabledynamictick yes
```
- **What:** Forces the OS timer to fire at a fixed interval instead of tickless idle. On tickless systems, the timer interrupt is suppressed when idle, but re-enabling it can cause jitter when transitioning back to active.
- **Expected impact:** Moderate — reduces timer interrupt jitter during gaming by 50-200us. Particularly beneficial for frame pacing consistency.
- **Risk:** Low — easily reversed with `bcdedit /deletevalue disabledynamictick`
- **Relevance:** High for 9800X3D — Zen 5 TSC is invariant, so fixed ticking has minimal power cost.
- **Reboot required:** Yes

### EXP02 — Timer Resolution: Force Platform Tick
```
bcdedit /set useplatformtick yes
```
- **What:** Forces Windows to use the platform timer instead of synthetic ticks. Can reduce timer coalescing and improve scheduling granularity.
- **Expected impact:** Marginal to Moderate — reduces worst-case scheduling delay by 1-2ms.
- **Risk:** Low — reversed with `bcdedit /deletevalue useplatformtick`
- **Relevance:** Medium — effect depends on BIOS HPET configuration.
- **Reboot required:** Yes
- **Test together with EXP01** if both show positive results individually.

### EXP03 — Win32PrioritySeparation (Foreground Boost)
```powershell
# Current default: 0x02 (short quantum, variable, foreground boost 3:1)
# Gaming optimal: 0x26 (short quantum, fixed, foreground boost 3:1)
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' -Name Win32PrioritySeparation -Value 0x26 -Type DWord
```
- **What:** Controls thread quantum length and foreground process priority boost. Value 0x26 = short fixed quanta with maximum foreground boost — game threads get 3x the CPU time slice of background processes.
- **Expected impact:** Moderate — reduces context switch overhead for the foreground game by giving it longer uninterrupted time slices.
- **Risk:** Low — registry change, easily rolled back.
- **Relevance:** High — directly affects game thread scheduling on all Windows systems.
- **Reboot required:** No (takes effect immediately)
- **Rollback:** `Set-ItemProperty ... -Value 0x02 -Type DWord`

### EXP04 — Disable SysMain (SuperFetch/Prefetch)
```powershell
Stop-Service SysMain -Force
Set-Service SysMain -StartupType Disabled
```
- **What:** SysMain preloads frequently used data into RAM. On systems with 32GB+ RAM and NVMe storage, its disk I/O activity creates unnecessary DPCs.
- **Expected impact:** Moderate — eliminates SysMain disk I/O DPCs (storport.sys contribution). With 32GB RAM, cache misses are rare enough that prefetching adds overhead without benefit.
- **Risk:** Low — easily re-enabled. May increase first-launch times for infrequently used apps.
- **Relevance:** High — 32GB RAM + NVMe makes SysMain redundant.
- **Reboot required:** No

### EXP05 — Intel I226-V Interrupt Coalescing
```powershell
# Disable interrupt moderation for lower latency
Set-NetAdapterAdvancedProperty -Name "Ethernet" -DisplayName "Interrupt Moderation" -DisplayValue "Disabled"
# Reduce receive/transmit buffers
Set-NetAdapterAdvancedProperty -Name "Ethernet" -DisplayName "Receive Buffers" -DisplayValue "256"
Set-NetAdapterAdvancedProperty -Name "Ethernet" -DisplayName "Transmit Buffers" -DisplayValue "256"
```
- **What:** Interrupt moderation batches multiple network packets into fewer interrupts — good for throughput, bad for latency. Disabling it gives per-packet interrupts for lowest network latency.
- **Expected impact:** Significant for network latency — reduces network round-trip by 50-500us depending on packet rate. Critical for competitive gaming (Fortnite, Valorant).
- **Risk:** Low — may increase CPU usage under heavy network load. Easily reversed via adapter properties.
- **Relevance:** Very High — Intel I226-V supports this. Direct impact on game server communication latency.
- **Reboot required:** No

---

## Tier 2: WORTH TESTING (Moderate Evidence, Medium Risk)

### EXP06 — Disable HPET Timer Source
```
bcdedit /set useplatformclock false
```
- **What:** Prevents Windows from using the HPET (High Precision Event Timer) as a clock source. Forces use of TSC (TimeStamp Counter) which is faster to read on modern CPUs.
- **Expected impact:** Marginal to Moderate — can reduce QPC call overhead. Some community reports show 1-3% FPS improvement. The Ryzen 9800X3D has an invariant TSC, so this should be safe.
- **Risk:** Medium — some applications depend on HPET for timing accuracy. Can cause timestamp issues in rare cases.
- **Relevance:** Medium — modern Windows 11 already prefers TSC over HPET on Zen 5, so the effect may be negligible.
- **Reboot required:** Yes
- **Rollback:** `bcdedit /deletevalue useplatformclock`

### EXP07 — Power Plan: Disable Core Parking
```powershell
# Disable core parking (keeps all cores active)
powercfg -setacvalueindex scheme_current sub_processor CPMINCORES 100
powercfg -setacvalueindex scheme_current sub_processor CPMAXCORES 100
# Set min processor state to 100% (no frequency scaling)
powercfg -setacvalueindex scheme_current sub_processor PROCTHROTTLEMIN 100
# Apply
powercfg -setactive scheme_current
```
- **What:** Core parking puts idle cores into a deep sleep state. Waking them introduces latency (10-100us). Disabling it keeps all cores at C0 state.
- **Expected impact:** Moderate — eliminates core wake-up latency spikes. Most beneficial when game threads migrate between cores.
- **Risk:** Medium — increases idle power consumption by 10-30W. CPU runs hotter at idle.
- **Relevance:** High for 9800X3D — the 3D V-Cache die benefits from all cores being warm and ready.
- **Reboot required:** No
- **Rollback:** `powercfg -restoredefaultschemes`

### EXP08 — NVIDIA Max Pre-Rendered Frames = 1
```powershell
# Via NVIDIA Profile Inspector or registry
# Set Maximum Pre-Rendered Frames to 1 (default is 3)
# Registry: HKLM:\SOFTWARE\NVIDIA Corporation\Global\NVTweak
# Or use nvidia-smi / NVIDIA Profile Inspector
```
- **What:** Controls how many frames the CPU can prepare ahead of the GPU. Lower values = less input lag but potentially lower FPS if CPU-bound.
- **Expected impact:** Significant for input latency — reduces render pipeline depth from ~50ms (3 frames at 60fps) to ~16ms (1 frame). At higher FPS (144+), the effect is smaller but still measurable.
- **Risk:** Low — may reduce FPS by 1-3% if CPU is the bottleneck. Easily changed in NVIDIA Control Panel.
- **Relevance:** Very High — RTX 5070 Ti is GPU-heavy, so pre-rendered frames queue up. Reducing to 1 minimizes input-to-display latency.
- **Reboot required:** No

### EXP09 — Disable Memory Compression
```powershell
Disable-MMAgent -MemoryCompression
```
- **What:** Windows 10/11 compresses pages in RAM instead of writing to pagefile. The compression/decompression creates CPU work (DPCs from ntoskrnl.exe) that can spike during gaming.
- **Expected impact:** Marginal — with 32GB RAM, memory pressure is rare. But when it does occur, compression DPCs can be 200-500us.
- **Risk:** Low — with 32GB RAM, rarely matters. May increase pagefile usage slightly.
- **Relevance:** Medium — only impacts systems under memory pressure.
- **Reboot required:** Yes

### EXP10 — DisablePagingExecutive
```powershell
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name DisablePagingExecutive -Value 1 -Type DWord
```
- **What:** Prevents the kernel and drivers from being paged to disk. Keeps all kernel code in physical RAM at all times.
- **Expected impact:** Moderate — eliminates hard pagefaults in kernel-mode code (which cause very high latency DPCs). With 32GB RAM, the ~200MB kernel footprint is negligible.
- **Risk:** Low — standard server optimization. Increases RAM usage by ~200MB.
- **Relevance:** High — directly targets the DPC latency path. Hard pagefaults in ntoskrnl.exe were a baseline problem.
- **Reboot required:** Yes

---

## Tier 3: SITUATIONAL (Niche Impact or Higher Risk)

### EXP11 — BIOS: Disable C-States
```
BIOS → Advanced → AMD CBS → SMU Common Options → CPPC → Disabled
BIOS → Advanced → AMD CBS → CPU Common Options → Global C-state Control → Disabled
```
- **What:** C-states are CPU power-saving states (C1=halt, C6=deep sleep). Transitioning between states takes 10-100us and can cause latency spikes visible in DPC timing.
- **Expected impact:** Moderate in worst-case scenarios — eliminates C-state transition DPCs. Most visible during variable load (game lobby → active gameplay transitions).
- **Risk:** High — significantly increases idle power consumption (30-50W more at idle). CPU runs much hotter. Cannot be changed from Windows — requires BIOS access.
- **Relevance:** Medium — the 9800X3D already has fast C-state transitions on Zen 5, but disabling them eliminates the transition entirely.
- **Rollback:** Re-enable in BIOS

### EXP12 — Disable Hyper-Threading for Game Cores
```powershell
# Use CPU Sets API or Process Lasso to restrict game to physical cores only
# Pins game to CPUs 0,2,4,6,8,10,12,14 (even = physical cores on AMD)
# NOTE: On 9800X3D, core topology may differ — verify with Ryzen Master
```
- **What:** SMT (Simultaneous Multi-Threading) shares execution resources between two logical cores. Disabling it for game threads can reduce cache contention and improve per-core IPC.
- **Expected impact:** Marginal — modern games are well-optimized for SMT. Some competitive titles (CS2, Valorant) show 1-3% improvement.
- **Risk:** Medium — process-level affinity is safe, BIOS-level SMT disable affects all workloads.
- **Relevance:** Low — the 9800X3D's 3D V-Cache already provides massive cache, reducing contention.
- **Rollback:** Remove affinity settings or re-enable SMT in BIOS

### EXP13 — TCP Auto-Tuning + Nagle Disable
```powershell
# Disable TCP auto-tuning (fixed receive window)
netsh int tcp set global autotuninglevel=disabled
# Disable Nagle algorithm for game process (reduces packet batching)
# Registry per-interface:
# HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{GUID}
# TcpAckFrequency=1, TCPNoDelay=1
```
- **What:** Auto-tuning dynamically adjusts TCP receive window size, which can cause brief stalls. Nagle algorithm batches small packets, adding 200ms delay per batch.
- **Expected impact:** Moderate for competitive gaming — Nagle disable reduces network latency by up to 200ms for small packet games. Auto-tuning disable is less impactful on LAN.
- **Risk:** Low — may reduce bulk download speeds. Easily reversed.
- **Relevance:** High for Fortnite — uses TCP for some connections. UDP-heavy games benefit less from Nagle disable.
- **Reboot required:** No

### EXP14 — Disable Delivery Optimization + DiagTrack
```powershell
Stop-Service DiagTrack -Force; Set-Service DiagTrack -StartupType Disabled
Stop-Service DoSvc -Force; Set-Service DoSvc -StartupType Disabled
```
- **What:** DiagTrack (Connected User Experiences and Telemetry) sends telemetry data. Delivery Optimization shares Windows Update data P2P. Both generate network + disk DPCs.
- **Expected impact:** Marginal — these services are mostly idle during gaming, but can spike randomly.
- **Risk:** Low — telemetry loss is acceptable for gaming PCs. Windows Update still works without DoSvc.
- **Relevance:** Low — minimal DPC contribution in our baseline.

### EXP15 — GPU Shader Cache Size
```
NVIDIA Control Panel → Manage 3D Settings → Shader Cache Size → 10GB (or Unlimited)
```
- **What:** Larger shader cache reduces shader compilation stutters during gameplay. First-time stutters are a known issue in Fortnite/UE5 games.
- **Expected impact:** Significant for first-time frame stutter — eliminates shader compilation hitches after cache is built. No effect on steady-state DPC latency.
- **Risk:** Low — uses disk space only. Default is 4GB.
- **Relevance:** Very High for Fortnite (UE5 shader compilation is notorious for stutters).

---

## Experiment Protocol

For each experiment:
1. Capture baseline: `.\scripts\pipeline.ps1 -Label "EXP0X_BEFORE" -Description "Pre-change baseline" -DurationSec 120 -SkipPresentMon`
2. Apply the change (reboot if required)
3. Capture post-change: `.\scripts\pipeline.ps1 -Label "EXP0X_AFTER" -Description "description" -DurationSec 120 -SkipPresentMon`
4. For gaming tests, add: `-GameProcess "FortniteClient-Win64-Shipping.exe"`
5. Compare in dashboard: select both runs → Compare Selected
6. If improvement: keep. If regression or no change: rollback.
7. Commit results regardless of outcome — negative results are data too.

---

## Priority Order

Test in this sequence for maximum impact with minimum risk:

```
Week 1 (Low risk, no reboot):
  EXP03 — Win32PrioritySeparation (immediate effect)
  EXP04 — Disable SysMain
  EXP05 — NIC interrupt coalescing
  EXP08 — NVIDIA pre-rendered frames = 1

Week 2 (Requires reboot):
  EXP01 — Disable dynamic tick
  EXP02 — Force platform tick
  EXP10 — DisablePagingExecutive
  EXP09 — Disable memory compression

Week 3 (More testing needed):
  EXP06 — Disable HPET
  EXP07 — Disable core parking
  EXP13 — TCP tuning + Nagle

Week 4 (Situational):
  EXP15 — Shader cache size
  EXP14 — Disable telemetry
  EXP11 — BIOS C-states (if still seeing transition spikes)
```
