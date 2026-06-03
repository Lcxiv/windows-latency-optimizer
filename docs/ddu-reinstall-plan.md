# DDU Reinstall + Full Reoptimization Plan

**Date:** 2026-05-26
**Current Driver:** NVIDIA 596.49 (installed 2026-05-05)
**Trigger:** GPU DPC 100% pinned to CPU 0 despite affinity mask; DWM at 9.7% CPU; constant input delay in Fortnite

## Current Tweaks Inventory (will be wiped by DDU)

| Setting | Current Value | Registry Path / Method |
|---------|---------------|----------------------|
| GPU Interrupt Affinity | DevicePolicy=4, Mask=0xF0 (CPUs 4-7) | `HKLM:\SYSTEM\CCS\Enum\PCI\VEN_10DE*\*\Interrupt Management\Affinity Policy` |
| PerfLevelSrc | 0x3322 (should be 0x2222) | `HKLM:\SYSTEM\CCS\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000` |
| MMCSS SystemResponsiveness | 0 | `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile` |
| MMCSS NetworkThrottlingIndex | 0xFFFFFFFF | Same path |
| Power Plan | Ultimate Performance | `powercfg` |
| Hyper-V | OFF (`hypervisorlaunchtype off`) | `bcdedit` |
| Dynamic Tick | Disabled | `bcdedit /set disabledynamictick yes` |
| Defender Exclusions | 15 paths | `Get-MpPreference` |
| Fortnite Reflex | ON | GameUserSettings.ini |
| Fortnite Mouse Accel | OFF (fixed today) | GameUserSettings.ini |
| GameDVR | Disabled | HKCU registry |

**Note:** DDU only wipes GPU driver + NVIDIA registry entries. MMCSS, power plan, bcdedit, Defender, and Fortnite settings survive.

---

## Phase 0: Pre-DDU Documentation (15 min)

### 0.1 Export NVIDIA Control Panel Settings
```powershell
# Screenshot approach - NVCP doesn't have CLI export
# Instead, document key NVCP settings:
nvidia-smi --query-gpu=driver_version,name,pstate,clocks.max.graphics,clocks.max.memory,power.limit --format=csv
```

### 0.2 Save Current Registry Tweaks
```powershell
# Export GPU-related registry
reg export "HKLM\SYSTEM\CurrentControlSet\Enum\PCI\VEN_10DE" "$env:TEMP\nvidia_enum_backup.reg"
reg export "HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}" "$env:TEMP\nvidia_class_backup.reg"
```

### 0.3 Run Pre-DDU Baseline
```powershell
cd C:\Users\L\Desktop\windows-latency-optimizer
.\scripts\baseline_capture.ps1 -Label "PRE_DDU_596_49"
.\scripts\audit.ps1 -Mode Deep -Symptom FullAudit
```

### 0.4 Capture DPC/ISR Baseline (10s trace)
```powershell
$xperf = "C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\xperf.exe"
& $xperf -on PROC_THREAD+LOADER+DPC+INTERRUPT -BufferSize 1024 -MinBuffers 256 -MaxBuffers 512
Start-Sleep -Seconds 10
& $xperf -d "$env:TEMP\pre_ddu_dpc.etl"
& $xperf -i "$env:TEMP\pre_ddu_dpc.etl" -a dpcisr -summary > "$env:TEMP\pre_ddu_dpc_summary.txt"
```

---

## Phase 1: DDU Clean Sweep (20 min)

### 1.1 Download Target Driver
- Check latest Game Ready driver at https://www.nvidia.com/Download/index.aspx
- Current: 596.49. Target: latest GRD (or Studio if stability preferred)
- Download to `C:\Users\L\Downloads\` before rebooting

### 1.2 Download DDU
- DDU latest from https://www.wagnardsoft.com/
- Already installed? Check `C:\Users\L\Desktop\DDU` or Downloads

### 1.3 Boot to Safe Mode
```powershell
# Set Safe Mode boot for next restart
bcdedit /set {current} safeboot minimal
# Reboot
shutdown /r /t 0
```

### 1.4 Run DDU in Safe Mode
1. Open DDU (Display Driver Uninstaller)
2. Select "GPU" and "NVIDIA"
3. Click "Clean and restart"
4. DDU removes:
   - Driver files (nvlddmkm.sys, etc.)
   - NVIDIA registry entries (including affinity, PerfLevelSrc)
   - NVIDIA App/GeForce Experience remnants
   - Shader cache
   - Telemetry services

### 1.5 Post-DDU (still in Safe Mode)
```powershell
# Clear Safe Mode flag before installing driver
bcdedit /deletevalue {current} safeboot
```

### 1.6 Install New Driver
1. Run NVIDIA installer
2. Select **Custom (Advanced)** install
3. Uncheck:
   - NVIDIA App (reinstall later if wanted)
   - HD Audio Driver (unless needed)
   - USB-C Driver (unless used)
4. Check **Perform a clean installation**
5. Install and reboot

---

## Phase 2: Post-Install Clean Baseline (15 min)

### 2.1 Verify Driver Loaded
```powershell
nvidia-smi --query-gpu=driver_version,name,pstate --format=csv
# Expect: new version, P8 at idle (no overlays yet)
```

### 2.2 Check GPU Interrupt CPU Assignment (CRITICAL)
```powershell
# Before applying any affinity tweaks, check where GPU interrupts land naturally
$xperf = "C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\xperf.exe"
& $xperf -on PROC_THREAD+LOADER+DPC+INTERRUPT -BufferSize 1024 -MinBuffers 256 -MaxBuffers 512
Start-Sleep -Seconds 10
& $xperf -d "$env:TEMP\post_ddu_clean_dpc.etl"
& $xperf -i "$env:TEMP\post_ddu_clean_dpc.etl" -a dpcisr -summary > "$env:TEMP\post_ddu_clean_dpc_summary.txt"
# Check: does nvlddmkm.sys STILL pin to CPU 0 with fresh driver?
# If yes: hardware limitation, affinity mask won't help
# If distributed: fresh driver fixed the routing
```

### 2.3 Run Clean Baseline
```powershell
cd C:\Users\L\Desktop\windows-latency-optimizer
.\scripts\baseline_capture.ps1 -Label "POST_DDU_CLEAN"
.\scripts\audit.ps1 -Mode Deep -Symptom FullAudit
```

### 2.4 Document Clean State
- GPU P-state (should be P8 at idle with no overlays)
- CPU 0 DPC % (target: < 1%)
- DWM CPU % (target: < 2% with no overlays)
- GPU temp, clocks, power draw

---

## Phase 3: Reapply Tweaks (20 min)

Apply in order. Test CPU 0 DPC after GPU affinity to see if fresh driver respects it.

### 3.1 GPU Interrupt Affinity (MOST IMPORTANT)
```powershell
# Find GPU device path
$gpuDevice = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI\VEN_10DE*' -Recurse |
    Where-Object { $_.PSChildName -eq 'Affinity Policy' } |
    Select-Object -First 1

# If path doesn't exist after DDU, create it:
$gpuEnum = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' |
    Where-Object { $_.PSChildName -like 'VEN_10DE*' }
$gpuInstance = Get-ChildItem $gpuEnum.PSPath | Select-Object -First 1
$intMgmt = Join-Path $gpuInstance.PSPath 'Interrupt Management'
$affPolicy = Join-Path $intMgmt 'Affinity Policy'

# Create keys if needed
New-Item -Path $intMgmt -Force -ErrorAction SilentlyContinue
New-Item -Path $affPolicy -Force -ErrorAction SilentlyContinue

# Set affinity to CPUs 4-7 (Mask = 0xF0 = 240)
Set-ItemProperty -Path $affPolicy -Name DevicePolicy -Value 4 -Type DWord
Set-ItemProperty -Path $affPolicy -Name AssignmentSetOverride -Value ([byte[]](240,0,0,0,0,0,0,0)) -Type Binary

# REBOOT required for affinity to take effect
```

### 3.2 Post-Affinity DPC Test (after reboot)
```powershell
# Critical test: does fresh driver + affinity mask move DPC off CPU 0?
$xperf = "C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\xperf.exe"
& $xperf -on PROC_THREAD+LOADER+DPC+INTERRUPT -BufferSize 1024
Start-Sleep -Seconds 10
& $xperf -d "$env:TEMP\post_affinity_dpc.etl"
& $xperf -i "$env:TEMP\post_affinity_dpc.etl" -a dpcisr -summary > "$env:TEMP\post_affinity_dpc_summary.txt"

# Check nvlddmkm.sys CPU distribution
# SUCCESS: DPC spread across CPUs 4-7
# FAILURE: still 100% CPU 0 = hardware limitation confirmed
```

### 3.3 PerfLevelSrc Fix
```powershell
# Force maximum performance levels (0x2222 = all scenarios max perf)
$classPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000'
Set-ItemProperty -Path $classPath -Name PerfLevelSrc -Value 0x2222 -Type DWord
# Verify
(Get-ItemProperty $classPath -Name PerfLevelSrc).PerfLevelSrc
# Should return 8738 (0x2222 in decimal)
```

### 3.4 NVIDIA Control Panel Settings
Apply via NVCP GUI (no registry equivalent for most):
- **Power management mode:** Prefer maximum performance
- **Low Latency Mode:** Ultra (or On)
- **Texture filtering - Quality:** High performance
- **Threaded optimization:** On
- **Shader Cache Size:** Unlimited
- **G-Sync:** On (if supported by monitor)
- **Vertical sync:** Off (game-controlled)
- **Max Frame Rate:** Match monitor refresh (360)

### 3.5 MMCSS (Survives DDU - verify)
```powershell
# These should still be set, but verify
$mmcss = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
(Get-ItemProperty $mmcss -Name SystemResponsiveness).SystemResponsiveness  # Should be 0
(Get-ItemProperty $mmcss -Name NetworkThrottlingIndex).NetworkThrottlingIndex  # Should be 0xFFFFFFFF
```

### 3.6 Defender Exclusions (Survives DDU - verify)
```powershell
# Verify exclusions still present
(Get-MpPreference).ExclusionPath | Format-List
# Should show 15 paths including game directories, shader cache, etc.
```

### 3.7 bcdedit Settings (Survives DDU - verify)
```powershell
bcdedit /enum {current} | Select-String -Pattern 'hypervisor|dynamictick'
# Should show: hypervisorlaunchtype Off, disabledynamictick Yes
```

---

## Phase 4: Gaming Workload Analysis (30 min)

### 4.1 Pre-Game Cleanup
```powershell
# Kill background noise before testing
Stop-Process -Name EpicWebHelper -Force -ErrorAction SilentlyContinue
# Close NVIDIA App overlay if running
# Disable Discord overlay: Settings > Game Activity > uncheck "Enable in-game overlay"
# Close Notion, extra browser tabs
# Keep only: Fortnite, Discord voice (no overlay), HWiNFO64 (for temps)
```

### 4.2 Start HWiNFO64 Logging
- Open HWiNFO64 in Sensors Only mode
- Enable CSV logging to `C:\Users\L\Desktop\windows-latency-optimizer\captures\hwinfo_post_ddu.csv`
- Key sensors: CPU Tdie, GPU Hot Spot, GPU Power, VRAM Usage, VRM temps

### 4.3 Run Pipeline Capture (During Fortnite)
```powershell
cd C:\Users\L\Desktop\windows-latency-optimizer
.\scripts\pipeline.ps1 -Label "POST_DDU_FORTNITE" -Description "Post-DDU with all tweaks, Fortnite creative" -SkipWPR -DurationSec 30 -GameProcess "FortniteClient-Win64-Shipping"
```

### 4.4 DPC/ISR Trace Under Gaming Load
```powershell
$xperf = "C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\xperf.exe"
& $xperf -on PROC_THREAD+LOADER+DPC+INTERRUPT -BufferSize 1024 -MinBuffers 256 -MaxBuffers 512
Start-Sleep -Seconds 30
& $xperf -d "$env:TEMP\post_ddu_gaming_dpc.etl"
& $xperf -i "$env:TEMP\post_ddu_gaming_dpc.etl" -a dpcisr -summary > "$env:TEMP\post_ddu_gaming_dpc_summary.txt"
```

### 4.5 CapFrameX Comparison (if captures exist)
```powershell
# Compare frame timing pre vs post DDU
.\scripts\analyze_capframex.ps1 -Files @(
    "path\to\pre_ddu_capture.csv",
    "path\to\post_ddu_capture.csv"
)
```

---

## Phase 5: Final Validation (15 min)

### 5.1 Full Audit
```powershell
.\scripts\audit.ps1 -Mode Deep -Symptom FullAudit
# Target: >= 91% (match or exceed 5/21 baseline)
```

### 5.2 Success Criteria

| Metric | Pre-DDU (today) | Target | Method |
|--------|-----------------|--------|--------|
| CPU 0 DPC % | 7.7% (GPU) | < 2% | xperf dpcisr |
| DWM CPU % | 9.7% | < 3% | Get-Process dwm |
| GPU P-state (idle) | P0 (stuck) | P8 | nvidia-smi |
| GPU power (idle) | 68W | < 20W | nvidia-smi |
| nvlddmkm DPC distribution | 100% CPU 0 | Spread CPUs 4-7 | xperf |
| Audit score | 91% | >= 93% | audit.ps1 |
| Fortnite input feel | Constant delay | Responsive | Subjective |

### 5.3 Rollback Plan
If DDU + reinstall makes things worse:
1. Registry backups at `$env:TEMP\nvidia_*.reg`
2. Previous driver 596.49 installer (keep a copy)
3. Pre-DDU baseline for comparison
4. `bcdedit` settings are untouched by DDU

---

## Timeline Summary

| Phase | Duration | Reboots | Admin? |
|-------|----------|---------|--------|
| 0 - Documentation | 15 min | 0 | Yes |
| 1 - DDU Sweep | 20 min | 2 (safe mode + normal) | Yes |
| 2 - Clean Baseline | 15 min | 0 | Yes |
| 3 - Reapply Tweaks | 20 min | 1 (after affinity) | Yes |
| 4 - Gaming Analysis | 30 min | 0 | Yes |
| 5 - Validation | 15 min | 0 | Yes |
| **Total** | **~2 hours** | **3** | |

---

## Key Hypothesis Being Tested

**"A fresh NVIDIA driver install will reset interrupt routing tables, potentially allowing the DevicePolicy=4/Mask=0xF0 affinity to actually move GPU DPC work off CPU 0."**

If Phase 2.2 shows nvlddmkm DPC STILL on CPU 0 with a fresh driver and NO affinity set, then:
- This is a hardware/firmware limitation of the RTX 5070 Ti
- Affinity masks cannot fix it
- Alternative mitigations needed:
  1. Reduce GPU submission rate (close overlays, reduce DWM work)
  2. Use fullscreen exclusive mode in games (bypass DWM)
  3. Pin game threads OFF CPU 0 (process affinity)
  4. Accept the overhead and focus on other optimizations

This is the most important diagnostic outcome of the entire procedure.
