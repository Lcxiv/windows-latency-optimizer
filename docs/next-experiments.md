# Next Experiments Roadmap

Ranked list of optimization experiments to test against EXP00 clean baseline. Each changes ONE variable to isolate its effect. Research-backed with community benchmarks.

**Baseline:** EXP00 — DPC% 0.134%, Interrupt% 0.076%, CPU 0 share 1.1%

**Already applied (DO NOT re-test):**
- Interrupt affinity (GPU/NIC→CPUs 4-7, KB/mouse→CPUs 2-3)
- NVIDIA MSI mode + PerfLevelSrc=0x2222 + HAGS
- Windows Defender exclusions + CPU throttle
- MMCSS priority (SystemResponsiveness=0, Games=High/6/High)

---

## Tier 1: RECOMMENDED (Proven Impact, Low Risk)

### EXP01 — Win32PrioritySeparation = 22
```powershell
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' -Name Win32PrioritySeparation -Value 22 -Type DWord
```
- **What:** Long fixed quanta with maximum foreground boost. Game threads get 12ms uninterrupted slices (vs 6ms default) with 3:1 priority over background. Fewer context switches = fewer cache evictions.
- **Why 9800X3D:** The 96MB V-cache benefits enormously from fewer context switches — each switch flushes working set from cache.
- **Impact:** Moderate — measurable frame-time consistency improvement
- **Risk:** Low — instant, no reboot, easily reversed (`-Value 38` for default)
- **Alternative:** Try 42 (0x2A) for competitive shooters (short+fixed+high boost — more responsive input, more context switches)

### EXP02 — Intel I226-V Low Latency Profile
```powershell
Set-NetAdapterAdvancedProperty -Name "Ethernet" -DisplayName "Interrupt Moderation" -DisplayValue "Disabled"
Set-NetAdapterAdvancedProperty -Name "Ethernet" -DisplayName "Energy Efficient Ethernet" -DisplayValue "Disabled"
Set-NetAdapterAdvancedProperty -Name "Ethernet" -DisplayName "Large Send Offload V2 (IPv4)" -DisplayValue "Disabled"
Set-NetAdapterAdvancedProperty -Name "Ethernet" -DisplayName "Large Send Offload V2 (IPv6)" -DisplayValue "Disabled"
Set-NetAdapterAdvancedProperty -Name "Ethernet" -DisplayName "Flow Control" -DisplayValue "Disabled"
Set-NetAdapterAdvancedProperty -Name "Ethernet" -DisplayName "Receive Buffers" -DisplayValue "256"
Set-NetAdapterAdvancedProperty -Name "Ethernet" -DisplayName "Transmit Buffers" -DisplayValue "256"
```
- **What:** Intel's own low-latency profile disables interrupt batching, EEE wake latency, TCP offload, and flow control. Each packet generates an immediate interrupt.
- **Impact:** Significant for network latency — removes up to 1ms interrupt coalescing delay
- **Risk:** Low — all reversible via adapter properties
- **Bonus:** If experiencing random disconnects, set I226-V PCIe lane to Gen 3 in BIOS (known hw bug fix)

### EXP03 — Nagle Algorithm + Delayed ACK Disable
```powershell
# Find your NIC interface GUID
$guid = (Get-NetAdapter -Name "Ethernet").InterfaceGuid
$path = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid"
Set-ItemProperty -Path $path -Name TcpAckFrequency -Value 1 -Type DWord
Set-ItemProperty -Path $path -Name TCPNoDelay -Value 1 -Type DWord
```
- **What:** Nagle batches small TCP packets (up to 200ms delay). Delayed ACK waits before acknowledging. Both add latency to game server communication.
- **Impact:** Moderate for online games — Fortnite uses TCP for some connections
- **Risk:** Low — slightly increased packet count

### EXP04 — Disable SysMain + DiagTrack + Delivery Optimization
```powershell
Stop-Service SysMain -Force; Set-Service SysMain -StartupType Disabled
Stop-Service DiagTrack -Force; Set-Service DiagTrack -StartupType Disabled
Stop-Service DoSvc -Force; Set-Service DoSvc -StartupType Disabled
# Disable telemetry scheduled tasks
schtasks /Change /TN "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator" /Disable
schtasks /Change /TN "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" /Disable
```
- **What:** SysMain preloads apps (redundant on NVMe), DiagTrack sends telemetry, DoSvc shares updates P2P. All generate background CPU + disk DPCs.
- **Impact:** Moderate — eliminates periodic background spikes
- **Risk:** Low — all easily re-enabled

### EXP05 — NVIDIA Reflex 2 + Pre-Rendered Frames
```
In-game: Enable NVIDIA Reflex (On + Boost)
NVIDIA Control Panel → Manage 3D Settings:
  - Low Latency Mode: Ultra (for non-Reflex games)
  - Power Management Mode: Prefer Maximum Performance
  - Shader Cache Size: Unlimited
```
- **What:** Reflex 2 manages the render queue at engine level, adds Frame Warp (updates mouse position before scanout). RTX 5070 Ti benchmarks: 56ms → 8ms in The Finals (75% reduction).
- **Impact:** SIGNIFICANT — single most impactful latency optimization available
- **Risk:** Low — per-game toggle
- **Note:** Reflex overrides Low Latency Mode and pre-rendered frames when active. Set the fallbacks for non-Reflex games.

### EXP06 — Storage Latency: NVMe + PCIe Power Management
```powershell
# Disable NVMe idle timeout
powercfg -setacvalueindex scheme_current SUB_DISK d639518a-e56d-4345-8af2-b9f32fb26109 0
# Disable NVMe latency tolerance
powercfg -setacvalueindex scheme_current SUB_DISK fc95af4d-40e7-4b6d-835a-56d131dbc80e 0
# Disable PCIe ASPM (via power plan)
powercfg -setacvalueindex scheme_current SUB_PCIEXPRESS ee12f906-d277-404b-b6da-e5fa1a576df5 0
# Disable AHCI link power management
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\storahci\Parameters\Device' -Name EnableHIPM -Value 0 -Type DWord
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\storahci\Parameters\Device' -Name EnableDIPM -Value 0 -Type DWord
# Apply
powercfg -setactive scheme_current
```
- **What:** Prevents NVMe, PCIe links, and AHCI from entering power-saving states. Eliminates wake-from-idle latency spikes during game asset streaming.
- **Impact:** Moderate — prevents 10-100ms storage wake spikes
- **Risk:** Low — slightly higher idle power

---

## Tier 2: WORTH TESTING (Moderate Evidence)

### EXP07 — BIOS: Enable C-States
```
BIOS → Advanced → AMD CBS → CPU Common Options → Global C-state Control → Enabled
```
- **What:** Counterintuitively, ENABLING C-states (changing from Auto/Disabled) fixes stuttering on AM5 boards with 9800X3D. Well-documented in Zen 5 X3D Owner's Club threads.
- **Impact:** Moderate — can fix periodic game stuttering
- **Risk:** Low — BIOS toggle
- **Reboot required:** Yes

### EXP08 — BIOS: PBO + Curve Optimizer
```
BIOS → AMD Overclocking → PBO → Advanced
  - PBO Limits: Motherboard
  - Curve Optimizer: Per Core, Negative offsets (-10 to -30)
  - Scalar: Auto or 1x
```
- **What:** PBO lets CPU exceed stock power limits. Curve Optimizer applies per-core voltage offsets for higher clocks at lower voltage.
- **Impact:** Significant — 5-15% single-thread boost improvement
- **Risk:** Medium — requires per-core stability testing with CoreCycler. Bad values cause crashes.
- **Reboot required:** Yes

### EXP09 — Disable HPET Sync (bcdedit)
```
bcdedit /deletevalue useplatformclock
```
- **What:** Prevents Windows from syncing to HPET. Forces standalone TSC. The 9800X3D has invariant TSC (zero-latency on-die read vs HPET's PCIe round-trip).
- **Impact:** Marginal — removes microsecond-level HPET bus latency from QPC calls
- **Risk:** Low — reversed with `bcdedit /set useplatformclock true`
- **DO NOT** disable HPET in BIOS or Device Manager — only use bcdedit
- **Reboot required:** Yes

### EXP10 — Disable Memory Compression
```powershell
Disable-MMAgent -MemoryCompression
```
- **What:** Windows compresses RAM pages instead of paging to disk. Decompression creates CPU DPCs.
- **Impact:** Marginal on 32GB (compression rarely activates) — more impactful on 16GB
- **Risk:** Low
- **Reboot required:** Yes

### EXP11 — VSync + G-Sync + FPS Cap Strategy
```
NVIDIA Control Panel:
  - G-SYNC: On (fullscreen + windowed)
  - VSync: On (in NVCP, off in-game)
  - In-game FPS cap: Monitor refresh rate - 3 (e.g., 141 for 144Hz)
```
- **What:** G-Sync handles variable refresh. VSync ON in NVCP prevents tearing at VRR boundary without adding input lag. FPS cap below max keeps GPU under 95% utilization (prevents render queue buildup).
- **Impact:** Moderate — eliminates tearing + frame pacing issues
- **Risk:** Low

---

## Tier 3: SKIP (Proven Ineffective or Harmful for This Setup)

These were researched and found to be **NOT recommended** for the 9800X3D + RTX 5070 Ti:

| Optimization | Why Skip |
|---|---|
| `bcdedit /set disabledynamictick yes` | Causes mouse acceleration artifacts on Win11 |
| `bcdedit /set useplatformtick yes` | Already default on Win11 — redundant |
| Ultimate Performance power plan | Hurts 9800X3D opportunistic boosting |
| Core parking disable | Wastes thermal headroom that active cores need for boost |
| DisablePagingExecutive | Placebo on 32GB RAM systems |
| LargeSystemCache | Not relevant to gaming |
| Disable IOMMU | Breaks Resizable BAR (SAM) performance for RTX 5070 Ti |
| Disable MPO (OverlayTestMode=5) | MPO actually reduces windowed latency since driver 461.09 |
| HIDUSBF USB polling override | Triggers anti-cheat, requires HVCI disable |
| Disable SVM (AMD-V) | Better to disable VBS/HVCI instead; SVM disable breaks Hyper-V/WSL2 |

---

## Testing Protocol

For each experiment:
```powershell
# 1. Capture pre-change baseline
.\scripts\pipeline.ps1 -Label "EXP0X_BEFORE" -Description "Pre-change" -DurationSec 120 -SkipPresentMon

# 2. Apply the change

# 3. Capture post-change (add -GameProcess for gaming tests)
.\scripts\pipeline.ps1 -Label "EXP0X_AFTER" -Description "description" -DurationSec 120 -SkipPresentMon

# 4. Compare in dashboard: select both → Compare Selected
# 5. If improved: keep. If regression: rollback.
# 6. Commit regardless — negative results are data too.
```

## Priority Order

```
Session 1 (instant, no reboot):
  EXP01 — Win32PrioritySeparation = 22
  EXP02 — NIC low latency profile
  EXP03 — Nagle disable
  EXP04 — Disable SysMain/DiagTrack
  EXP05 — NVIDIA Reflex + shader cache (in-game)
  EXP06 — Storage power management

Session 2 (requires reboot):
  EXP07 — BIOS: Enable C-States
  EXP09 — Disable HPET sync
  EXP10 — Disable memory compression

Session 3 (BIOS + stability testing):
  EXP08 — PBO + Curve Optimizer
  EXP11 — VSync/G-Sync strategy
```
