# Implementation Plan — Latency Findings

**System:** DESKTOP-V5BN4SC | AMD Ryzen 7 9800X3D | 16 logical processors | Windows 11 26200
**Based on:** LatencyMon capture 2026-03-28, baseline and Exp 01 perf snapshots

---

## Summary

| # | Finding | Severity | Effort | Expected Impact |
|---|---|---|---|---|
| 1 | CPU 0 interrupt bottleneck (97.7% of DPCs) | High | Medium | Reduces CPU 0 contention with game threads |
| 2 | Defender hard pagefaults (149/338 total) | High | Low | Eliminates largest single latency spike source |
| 3 | NVIDIA DPC spikes (561µs peak, 0.105% total) | Medium | Low–Medium | Lowers peak DPC execution time |

**Execution order:** Finding 2 → Finding 3 → Finding 1.
Defender exclusions are no-reboot and lowest risk. NVIDIA MSI mode is a single registry key + reboot. Interrupt affinity requires per-device tuning and a second LatencyMon run to validate.

---

## Finding 1 — CPU 0 Interrupt Bottleneck

### Root Cause

Windows routes hardware interrupts to CPU 0 (the boot processor) by default. The APIC controller assigns IRQ affinity using a policy of "interrupt any available processor starting from 0", and drivers that don't explicitly request spread-interrupt delivery end up serialising everything through CPU 0.

The LatencyMon data makes this visible:

| CPU | Interrupt Cycles (s) | DPC Count | Share |
|---|---|---|---|
| CPU 0 | 7.83 | 241,319 | **97.7%** |
| CPU 4 | 0.89 | 1,959 | 0.8% |
| CPUs 1–3, 5–15 | < 0.93 each | < 1,251 each | 1.5% combined |

For an AMD Ryzen 7 9800X3D, CPU 0 is typically the highest-performing core for single-threaded workloads (selected by the AMD scheduler for the "preferred core"). Having all interrupts processed there directly competes with a game's main thread.

**Goal:** Move NIC and audio interrupts to CPUs 4–7 (physical cores 2–4, away from the game's preferred cores 0–1).

---

### Step 1A — Enable RSS on the Network Adapter (no reboot needed for most drivers)

Receive-Side Scaling spreads network receive processing across multiple CPUs. It is the cleanest and most impactful fix for NIC interrupt load.

```powershell
# Run as Administrator

# 1. Identify the active physical adapter
Get-NetAdapter -Physical | Where-Object Status -eq 'Up' |
    Select-Object Name, InterfaceDescription, PNPDeviceID | Format-Table -AutoSize

# 2. Check current RSS state
$nic = (Get-NetAdapter -Physical | Where-Object Status -eq 'Up')[0].Name
Get-NetAdapterRss -Name $nic | Select-Object Name, Enabled, BaseProcessorNumber, MaxProcessorNumber, MaxProcessors

# 3. Enable RSS, pin to CPUs 4–7 (away from gaming cores 0–1)
Set-NetAdapterRss -Name $nic `
    -Enabled $true `
    -BaseProcessorNumber 4 `
    -MaxProcessorNumber 7

# 4. Confirm
Get-NetAdapterRss -Name $nic | Format-List Name, Enabled, BaseProcessorNumber, MaxProcessorNumber
```

> **Why CPUs 4–7?** On the 9800X3D, these are physical cores 2–4 — active enough to handle interrupt work but not the zero-latency cores the OS scheduler prefers for gaming. Avoids CPU 0 and CPU 1 (its SMT sibling).

---

### Step 1B — Set Interrupt Affinity for Audio and Other High-Frequency Devices

This pins device IRQs to specific CPUs via the Windows `Interrupt Management\Affinity Policy` registry subtree. Requires a **reboot** to take effect.

```powershell
# Run as Administrator

# ── Helper function ─────────────────────────────────────────────────────────
function Set-DeviceInterruptAffinity {
    param(
        [Parameter(Mandatory)] [string]  $DeviceInstanceId,
        [Parameter(Mandatory)] [byte[]]  $AffinityMask,
        [int] $Policy = 4   # 4 = IrqPolicySpecifiedProcessors
                            # 5 = IrqPolicySpreadMessagesAcrossAllProcessors
    )
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$DeviceInstanceId" +
               "\Device Parameters\Interrupt Management\Affinity Policy"
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    Set-ItemProperty -Path $regPath -Name "DevicePolicy"            -Value $Policy      -Type DWord
    Set-ItemProperty -Path $regPath -Name "AssignmentSetOverride"   -Value $AffinityMask -Type Binary
    Write-Host "OK  $DeviceInstanceId"
}

# ── CPU masks (little-endian 8-byte bitmask, bit N = CPU N) ─────────────────
# CPUs 4–7  (0x00F0): F0 00 00 00 00 00 00 00
$mask_cpu4to7  = [byte[]](0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)

# CPUs 2–15 (0xFFFC): FC FF 00 00 00 00 00 00  (exclude CPU 0 and 1)
$mask_cpu2to15 = [byte[]](0xFC, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)

# ── Find audio controllers ───────────────────────────────────────────────────
Write-Host "`n--- Audio Controllers ---"
Get-PnpDevice -Class AudioEndpoint, Media |
    Where-Object Status -eq 'OK' |
    Select-Object FriendlyName, InstanceId | Format-Table -AutoSize

# Copy the InstanceId values from output above, then run:
# Set-DeviceInterruptAffinity -DeviceInstanceId "HDAUDIO\FUNC_01&..." -AffinityMask $mask_cpu4to7

# ── Find USB controllers (host controllers generate frequent interrupts) ─────
Write-Host "`n--- USB Host Controllers ---"
Get-PnpDevice -Class USB |
    Where-Object { $_.FriendlyName -match 'Host Controller|Root Hub' -and $_.Status -eq 'OK' } |
    Select-Object FriendlyName, InstanceId | Format-Table -AutoSize

# ── Apply SpreadAcrossAllProcessors as a quick fallback for any device ───────
# DevicePolicy = 5 tells Windows to spread IRQs automatically (no mask needed)
function Set-DeviceSpreadInterrupts {
    param([Parameter(Mandatory)][string]$DeviceInstanceId)
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$DeviceInstanceId" +
               "\Device Parameters\Interrupt Management\Affinity Policy"
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    Set-ItemProperty -Path $regPath -Name "DevicePolicy" -Value 5 -Type DWord
    Write-Host "Spread set for $DeviceInstanceId"
}
```

> **Reboot required.** Interrupt affinity changes are not hot-applied; Windows re-reads them during driver initialisation at boot.

---

### Verification

After reboot, run LatencyMon for 2 minutes and compare per-CPU interrupt cycle times:

```
Target:  CPU 0 interrupt cycle time < 2.0 s  (down from 7.83 s)
Target:  CPUs 4–7 interrupt cycle time > 0.5 s each (load distributed)
```

Also check with Performance Monitor live:
```powershell
# Watch per-CPU interrupt % in real time
Get-Counter '\Processor(*)\% Interrupt Time' -SampleInterval 1 -MaxSamples 30 |
    ForEach-Object {
        $_.CounterSamples |
            Where-Object { $_.InstanceName -ne '_total' } |
            Sort-Object CookedValue -Descending |
            Select-Object -First 6 |
            ForEach-Object { "{0,-12} {1:N2}%" -f $_.InstanceName, $_.CookedValue }
        Write-Host "---"
    }
```

---

### Rollback

```powershell
# Remove affinity override for a device — restores Windows default (CPU 0)
function Remove-DeviceInterruptAffinity {
    param([Parameter(Mandatory)][string]$DeviceInstanceId)
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$DeviceInstanceId" +
               "\Device Parameters\Interrupt Management\Affinity Policy"
    if (Test-Path $regPath) {
        Remove-ItemProperty -Path $regPath -Name "DevicePolicy" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $regPath -Name "AssignmentSetOverride" -ErrorAction SilentlyContinue
        Write-Host "Cleared affinity override for $DeviceInstanceId"
    }
}

# Revert RSS to Windows default
Set-NetAdapterRss -Name $nic -Enabled $true -BaseProcessorNumber 0 -MaxProcessorNumber 15
```

---
---

## Finding 2 — Windows Defender Hard Pagefaults

### Root Cause

`msmpeng.exe` caused 149 of 338 total hard pagefaults (44%) during the 1:45 LatencyMon capture — at **idle**, before any game was launched. This is real-time protection scanning file system activity. When Defender accesses a page that's been evicted from RAM, the process blocks while the kernel reads it from the pagefile, creating a latency spike in any thread that happens to be scheduled at the same time.

Experiment 01 added path exclusions for the Fortnite install directory, which helps during gameplay. The remaining risk is Defender scanning activity triggered by:
1. Shader compilation and cache writes (happen at game launch)
2. Anti-cheat driver loads (EasyAntiCheat, BattlEye)
3. Launcher update checks and file verification
4. System DLL loads triggered by the game process

**Goal:** Eliminate msmpeng.exe from the pagefault list entirely when gaming.

---

### Step 2A — Verify and Expand Path Exclusions

```powershell
# Run as Administrator

# Check current exclusions (from Exp 01)
(Get-MpPreference).ExclusionPath
(Get-MpPreference).ExclusionProcess

# Add process exclusions — Defender skips scanning these executables entirely
$gameProcesses = @(
    "FortniteClient-Win64-Shipping.exe",
    "EpicGamesLauncher.exe",
    "EasyAntiCheat.exe",
    "EasyAntiCheat_EOS.exe",
    "BEService.exe"             # BattlEye (if applicable)
)
foreach ($proc in $gameProcesses) {
    Add-MpPreference -ExclusionProcess $proc
    Write-Host "Excluded process: $proc"
}

# Add shader cache and temp paths (common latency sources at game launch)
$additionalPaths = @(
    "$env:LOCALAPPDATA\FortniteGame",           # Shader cache
    "$env:LOCALAPPDATA\EpicGamesLauncher",      # Launcher cache
    "$env:PROGRAMDATA\Epic\EpicGamesLauncher",  # Shared launcher data
    "$env:LOCALAPPDATA\Temp"                    # Temp writes during launch
)
foreach ($path in $additionalPaths) {
    if (Test-Path $path) {
        Add-MpPreference -ExclusionPath $path
        Write-Host "Excluded path: $path"
    }
}

# Confirm all active exclusions
Write-Host "`n=== Active Exclusions ==="
Write-Host "Paths:"
(Get-MpPreference).ExclusionPath | ForEach-Object { Write-Host "  $_" }
Write-Host "Processes:"
(Get-MpPreference).ExclusionProcess | ForEach-Object { Write-Host "  $_" }
```

---

### Step 2B — Reduce Defender Background Scan Aggression

These settings limit Defender's CPU usage and scan rate without disabling protection:

```powershell
# Run as Administrator

# Cap CPU usage during scans to 5% of a single core
Set-MpPreference -ScanAvgCPULoadFactor 5

# Run scheduled scans at low process priority (below normal)
Set-MpPreference -EnableLowCpuPriority $true

# Disable scanning of network-mapped drives (not relevant for gaming, adds overhead)
Set-MpPreference -DisableScanningMappedNetworkDrivesForFullScan $true

# Disable behavioural monitoring of network activity
Set-MpPreference -DisableNetworkProtection $false  # Keep network protection ON
# (Only disable this on air-gapped/LAN-only machines)

# Confirm
Get-MpPreference | Select-Object ScanAvgCPULoadFactor, EnableLowCpuPriority, DisableScanningMappedNetworkDrivesForFullScan
```

---

### Step 2C — Reschedule Full Scans Away from Gaming Hours

```powershell
# Run as Administrator

# Move the scheduled full scan to 3 AM (when machine is idle)
Set-MpPreference -ScanScheduleDay 0              # 0 = Every day
Set-MpPreference -ScanScheduleTime 03:00:00      # 3:00 AM
Set-MpPreference -ScanScheduleQuickScanTime 03:30:00

Write-Host "Scan schedule updated"
Get-MpPreference | Select-Object ScanScheduleDay, ScanScheduleTime, ScanScheduleQuickScanTime
```

---

### Verification

Run LatencyMon for 2 minutes after applying exclusions, then check:

```
Target:  msmpeng.exe absent from hard pagefaults list, or count < 10
Target:  Total hard pagefaults < 50 (down from 338)
```

Quick check without LatencyMon — watch for Defender scans in real time:
```powershell
# Watch MsMpEng CPU usage for 30 seconds
Get-Process MsMpEng -ErrorAction SilentlyContinue |
    Select-Object CPU, WorkingSet, PagedMemorySize
```

Also re-run the ProcMon analysis script and look at the Defender section output:
```powershell
.\scripts\analyze_procmon.ps1
# "--- Windows Defender (MsMpEng) Activity ---" section should show fewer/no events
```

---

### Rollback

```powershell
# Remove specific exclusions
Remove-MpPreference -ExclusionProcess "FortniteClient-Win64-Shipping.exe"
Remove-MpPreference -ExclusionPath "$env:LOCALAPPDATA\FortniteGame"

# Restore scan settings to Windows defaults
Set-MpPreference -ScanAvgCPULoadFactor 50
Set-MpPreference -EnableLowCpuPriority $false
```

> **Security note:** Process exclusions are more targeted than path exclusions and carry lower risk. If you're concerned about a specific exclusion, remove it individually rather than reverting all changes.

---
---

## Finding 3 — NVIDIA Driver DPC Spikes

### Root Cause

`nvlddmkm.sys` (NVIDIA Windows Kernel Mode Driver v595.97) accounted for **0.105% of total CPU time in DPCs** — the highest share of any driver. Individual DPCs on CPUs 4–7 peaked at 270–562 µs, which is above the 250 µs threshold that begins to affect real-time audio and can contribute to game frame-time variance.

Two separate mechanisms cause this:

1. **Interrupt delivery mode.** Without MSI (Message Signaled Interrupts), the GPU shares a physical IRQ line with other devices. Each interrupt requires a bus read to identify the source, adding latency. MSI replaces this with a dedicated in-band write directly into CPU memory — lower latency, no sharing.

2. **Power state transitions.** When GPU power management mode is set to "Adaptive" or "Optimal Power", the GPU clocks up and down in response to load. Each transition triggers DPC callbacks in `nvlddmkm.sys` as the driver adjusts memory and core clocks. Under a gaming workload these transitions happen frequently, causing clusters of DPCs.

---

### Step 3A — Enable MSI Mode for the NVIDIA GPU

> This is the highest-impact single change for NVIDIA DPC latency. Requires a **reboot**.

```powershell
# Run as Administrator

# 1. Find the NVIDIA GPU device instance ID
$gpu = Get-PnpDevice -FriendlyName "*NVIDIA*" -Class Display |
       Where-Object Status -eq 'OK' |
       Select-Object -First 1
Write-Host "GPU: $($gpu.FriendlyName)"
Write-Host "InstanceId: $($gpu.InstanceId)"

# 2. Build the MSI registry path
$msiPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($gpu.InstanceId)" +
           "\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"

# 3. Create key if missing and enable MSI
if (-not (Test-Path $msiPath)) {
    New-Item -Path $msiPath -Force | Out-Null
}
Set-ItemProperty -Path $msiPath -Name "MSISupported"      -Value 1 -Type DWord

# Optional: limit to single MSI vector (reduces DPC serialisation for some GPUs)
Set-ItemProperty -Path $msiPath -Name "MessageNumberLimit" -Value 1 -Type DWord

# 4. Confirm
Get-ItemProperty $msiPath | Select-Object MSISupported, MessageNumberLimit
```

After rebooting, verify MSI is active:
```powershell
# MSI-active devices show "Message-Signaled" in their interrupt type
# This reads from the live interrupt table via WMI
Get-WmiObject Win32_PnPAllocatedResource |
    Where-Object { $_.Antecedent -match 'IRQResource' -and $_.Dependent -match 'GPU' }
# (No output = MSI mode, as MSI devices don't appear in the legacy IRQ table)
```

---

### Step 3B — Set NVIDIA Power Management to Maximum Performance

GPU clock transitions are the primary cause of nvlddmkm.sys DPC clusters. Locking the GPU to maximum performance clocks eliminates these transitions entirely at the cost of higher idle power draw.

**Via NVIDIA Control Panel (recommended — most reliable):**
1. Open **NVIDIA Control Panel** → **Manage 3D Settings** → **Global Settings**
2. Find **Power management mode** → set to **Prefer maximum performance**
3. Click **Apply**

**Via registry** (survives driver updates, applies globally):
```powershell
# Run as Administrator
# Find the NVIDIA display adapter class subkey
$classRoot = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"

$nvKey = Get-ChildItem $classRoot -ErrorAction SilentlyContinue |
    Where-Object {
        (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ProviderName -match 'NVIDIA'
    } | Select-Object -First 1

if ($nvKey) {
    Write-Host "Found NVIDIA adapter key: $($nvKey.PSPath)"

    # PerfLevelSrc = 0x2222: force maximum performance (all domains)
    # 0x2222 = adaptive off for both 2D and 3D power levels
    Set-ItemProperty -Path $nvKey.PSPath -Name "PerfLevelSrc" -Value 0x2222 -Type DWord

    Write-Host "PerfLevelSrc set to 0x2222 (prefer maximum performance)"
    Get-ItemProperty $nvKey.PSPath | Select-Object PerfLevelSrc
} else {
    Write-Host "NVIDIA adapter key not found — use NVIDIA Control Panel instead"
}
```

---

### Step 3C — Enable Hardware-Accelerated GPU Scheduling (HAGS)

HAGS offloads GPU work scheduling from the CPU to the GPU itself, reducing the frequency of `nvlddmkm.sys` callbacks needed to manage the command queue. Requires a **reboot** and a GPU that supports it (RTX 20-series and later — confirmed supported on your hardware if running Win11).

```powershell
# Run as Administrator

# Check current state (2 = enabled, 1 = disabled)
$hagsPath = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
$current = (Get-ItemProperty $hagsPath -ErrorAction SilentlyContinue).HwSchMode
Write-Host "Current HwSchMode: $current (1=disabled, 2=enabled)"

# Enable HAGS
Set-ItemProperty -Path $hagsPath -Name "HwSchMode" -Value 2 -Type DWord
Write-Host "HAGS enabled — reboot required"
```

> **Note:** HAGS can occasionally increase input latency in some titles. Benchmark before/after in your specific game with PresentMon or CapFrameX if you suspect regression.

---

### Step 3D — Pin GPU Interrupts Off CPU 0

If nvlddmkm.sys DPCs still appear on CPU 0 after MSI mode is enabled, explicitly route GPU interrupts to CPUs 4–7:

```powershell
# Run as Administrator (reboot required)
$gpu = Get-PnpDevice -FriendlyName "*NVIDIA*" -Class Display |
       Where-Object Status -eq 'OK' | Select-Object -First 1

$affinityPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($gpu.InstanceId)" +
                "\Device Parameters\Interrupt Management\Affinity Policy"

if (-not (Test-Path $affinityPath)) { New-Item -Path $affinityPath -Force | Out-Null }

# CPUs 4–7 mask: 0xF0 → bytes: F0 00 00 00 00 00 00 00
Set-ItemProperty -Path $affinityPath -Name "DevicePolicy"          -Value 4                                              -Type DWord
Set-ItemProperty -Path $affinityPath -Name "AssignmentSetOverride"  -Value ([byte[]](0xF0,0x00,0x00,0x00,0x00,0x00,0x00,0x00)) -Type Binary

Write-Host "GPU interrupt affinity set to CPUs 4–7"
```

---

### Verification

After reboot, run LatencyMon for 2 minutes:

```
Target:  nvlddmkm.sys total DPC time < 0.03%  (down from 0.105%)
Target:  Max single DPC execution time < 200µs (down from 561µs)
Target:  DPC count in 500–10000µs bucket = 0   (down from 6)
```

Also check interrupt type to confirm MSI activated. MSI-mode devices do not appear in the legacy IRQ list — if the GPU's IRQ line disappears from `msinfo32 → Hardware Resources → IRQs`, MSI is active.

---

### Rollback

```powershell
# Disable MSI mode (revert to legacy IRQ)
$gpu = Get-PnpDevice -FriendlyName "*NVIDIA*" -Class Display | Where-Object Status -eq 'OK' | Select-Object -First 1
$msiPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($gpu.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
Set-ItemProperty -Path $msiPath -Name "MSISupported" -Value 0 -Type DWord

# Revert power management to Adaptive
# NVIDIA Control Panel → Power Management Mode → Optimal Power
# Or clear the registry value:
$classRoot = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
$nvKey = Get-ChildItem $classRoot | Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ProviderName -match 'NVIDIA' } | Select-Object -First 1
if ($nvKey) { Remove-ItemProperty -Path $nvKey.PSPath -Name "PerfLevelSrc" -ErrorAction SilentlyContinue }

# Disable HAGS
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -Value 1 -Type DWord
```

---
---

## Post-Fix Verification Procedure

Run this after applying all changes and rebooting:

```powershell
# Run as Administrator
# 1. Capture new baseline
.\scripts\baseline_capture.ps1 -Label "EXP02_POST_FIX"

# 2. Check RSS is active and on the right CPUs
$nic = (Get-NetAdapter -Physical | Where-Object Status -eq 'Up')[0].Name
Get-NetAdapterRss -Name $nic | Format-List Enabled, BaseProcessorNumber, MaxProcessorNumber

# 3. Check Defender exclusions are all present
Write-Host "=== Defender Exclusion Paths ==="
(Get-MpPreference).ExclusionPath
Write-Host "=== Defender Exclusion Processes ==="
(Get-MpPreference).ExclusionProcess

# 4. Check HAGS state
(Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers").HwSchMode

# 5. Check GPU MSI path exists and is set to 1
$gpu = Get-PnpDevice -FriendlyName "*NVIDIA*" -Class Display | Where-Object Status -eq 'OK' | Select-Object -First 1
$msiVal = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\$($gpu.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties" -ErrorAction SilentlyContinue).MSISupported
Write-Host "MSISupported: $msiVal  (expected: 1)"
```

Then **run LatencyMon for 2 minutes** and check against these targets:

| Metric | Baseline | Target After All Fixes |
|---|---|---|
| Max interrupt → process latency | 178.80 µs | < 100 µs |
| CPU 0 interrupt cycle time | 7.83 s | < 2.0 s |
| nvlddmkm.sys total DPC time | 0.105% | < 0.030% |
| Max DPC execution time | 561.60 µs | < 200 µs |
| DPCs ≥ 500 µs | 6 | 0 |
| Hard pagefaults (msmpeng.exe) | 149 | < 10 |

Add the new capture to `dashboard/data/experiments.js` to compare against baseline in the dashboard.
