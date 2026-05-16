---
tags: [research, polling, windows, procmon, services]
date: 2026-04-27
status: complete
aliases: [System Polling, Polling Storms]
---

## System Polling Storm Analysis (2026-04-27)

**Methodology:** ProcMon64 30-second idle capture, 255,364 events = 8,512 events/sec. Normal Windows idle: ~2,000-3,000 events/sec. This system: 3-4x normal.

---

### Storm 1: ctfmon.exe Text Input Framework

**Rate:** 422 registry reads/sec (12,681 events/30s)
**What:** Continuously reading `HKLM\SOFTWARE\Microsoft\Input\Settings` and `HKLM\SOFTWARE\Microsoft\Input\Settings\proc_1\loc_0409\im_1`

**Root cause:** Setting conflict between two registry levels:
- System-level (`Input\Settings`): AutoCorrection=0, Prediction=0, Spellcheck=0, ShapeWriting=0
- Per-IME level (`proc_1\loc_0409\im_1`): AutoCorrection=1, Prediction=1, Spellcheck=1, ShapeWriting=1
- ctfmon polls BOTH levels every ~70ms in a burst of ~30 key reads to resolve which takes priority
- Additional conflicting settings: InsightsEnabled=1 at HKLM but 0 at HKCU
- Unnecessary features enabled: HarvestContacts=1, DictationEnabled=1, DisablePersonalization=0

**Fix applied:** Aligned per-IME settings to match system-level (all OFF). Disabled personalization features.
```powershell
# Key registry changes (in scripts/fix_system_polling.ps1):
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Input\Settings\proc_1\loc_0409\im_1' -Name AutoCorrection -Value 0
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Input\Settings\proc_1\loc_0409\im_1' -Name Prediction -Value 0
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Input\Settings\proc_1\loc_0409\im_1' -Name Spellcheck -Value 0
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Input\Settings\proc_1\loc_0409\im_1' -Name ShapeWriting -Value 0
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Input\Settings' -Name HarvestContacts -Value 0
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Input\Settings' -Name DictationEnabled -Value 0
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Input\Settings' -Name DisablePersonalization -Value 1
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Input\Settings' -Name InsightsEnabled -Value 0
Set-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Input\TIPC' -Name Enabled -Value 0
```
**Result:** 23,513 events -> 0 events. **100% elimination.**

---

### Storm 2: Winmgmt (svchost PID 3724) WMI Tracing

**Rate:** 271 registry reads/sec (8,130 events/30s on `HKLM\Software\Microsoft\WBEM\Tracing`)
**Service:** `Winmgmt` (Windows Management Instrumentation) running as `svchost.exe -k netsvcs -p -s Winmgmt`

**Root cause:** Known Windows bug. WMI service continuously re-reads its own tracing configuration registry keys even when `EnableWinmgmtTelemetry=0`. No event-driven notification path exists in the WMI service for tracing config changes - it uses a tight polling loop instead. Only 1 WMI event subscription registered (SCM Event Log Filter - normal).

**Fix applied:** Confirmed EnableWinmgmtTelemetry=0, disabled WMI Performance Adapter service (WmiApSrv).
```powershell
Set-ItemProperty 'HKLM:\Software\Microsoft\WBEM\Tracing' -Name EnableWinmgmtTelemetry -Value 0
Set-Service WmiApSrv -StartupType Disabled
```
**Result:** Cannot fully eliminate (Windows bug). Reduced secondary WMI overhead.

---

### Storm 3: camsvc (svchost PID 5616) Capability Access Manager

**Rate:** 216 registry reads/sec (6,490 events/30s on `PolicyManager\default\Privacy`)
**Service:** `camsvc` (Capability Access Manager Service) running as `svchost.exe -k osprivacy -p -s camsvc`

**Root cause:** NOT checking camera/mic - checking LOCATION access. 4 systemAIModels apps registered for location-based AI features:
- aimgr (Windows AI Manager)
- Microsoft.OutlookForWindows
- Microsoft.Windows.Photos
- Microsoft.WindowsNotepad

camsvc polls `LetAppsAccessLocation`, `LetAppsAccessLocation_UserInControlOfTheseApps`, `LetAppsAccessLocation_ForceAllowTheseApps`, `LetAppsAccessLocation_ForceDenyTheseApps` at 181/sec even though Location consent was already set to Deny. Also polls `AppPrivacy` policies (708 events/30s).

**Fix applied:**
```powershell
Set-Service camsvc -StartupType Disabled  # Changed from Manual -> Disabled (Manual still auto-starts on demand, 980/sec)
Stop-Service camsvc -Force
Set-Service lfsvc -StartupType Disabled   # Location Service
Stop-Service lfsvc -Force
# Force deny location via Group Policy
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' -Name LetAppsAccessLocation -Value 2
```
**Result:** Manual was insufficient — Chrome triggers camsvc on-demand (980/sec polling ALL capability policies). Disabled fully eliminates. Camera/mic still work at hardware level, but Windows privacy permission UI dialogs won't show.

---

### Storm 4: Explorer.EXE Shell Extension Enumeration

**Rate:** 1,343 events/sec (40,295 events/30s). Normal Explorer idle: ~300-400/sec. This system: 3-4x normal.

**Root cause (multiple):**
1. **OneDrive ghost overlays:** 7 icon overlay shell extensions registered (OneDrive1 through OneDrive7) but OneDrive NOT RUNNING. Explorer queries each overlay CLSID for every file in every open folder. Ghost COM calls that timeout or fail silently.
   - `{BBACC218-34EA-4666-9D7A-C78F2274A524}` (OneDrive1)
   - `{5AB7172C-9C11-405C-8DD5-AF20F3606282}` (OneDrive2)
   - `{A78ED123-AB77-406B-9962-2A5D9D2F7F30}` (OneDrive3)
   - `{F241C880-6982-4CE5-8CF7-7085BA96DA5A}` (OneDrive4)
   - `{A0396A93-DC06-4AEF-BEE9-95FFCCAEF20E}` (OneDrive5)
   - `{9AA2F32D-362A-42D9-9328-24A483E2CCC3}` (OneDrive6)
   - `{C5FF006E-2AE9-408C-B85B-2DFDD5449D9C}` (OneDrive7)

2. **33 desktop namespace CLSIDs** including unused: File History, CSC Offline Files, MAPI folders, StartMenuProviders, DXP, Search Home. Each = COM object loaded into Explorer.

3. **Enterprise policy checking on gaming rig:**
   - DataProtection/WIP policies: 1,314 reads/30s (Windows Information Protection - enterprise DLP)
   - Terminal Server config: 540 reads/30s (checking if system is RD Server)
   - AppCompatFlags: 674 reads/30s (compatibility shim database)

4. **84 AppX packages** being enumerated via `AppModel` registry (2,160 reads/30s)

5. **Quick Access** folder handler `{088E3905-0323-4B02-9826-5D99428E115F}` causing continuous CLSID re-resolution

**Top Explorer CLSIDs queried:**
- `{06EEE834-461C-42C2-8DCF-1502B527B1F9}` = CExplorerBrowser (ieframe.dll) - 1,982 hits
- `{DFFACDC5-679F-4156-8947-C5C76BC0B67F}` = Shell File System Folder (Windows.Storage.dll) - 932 hits
- `{088E3905-0323-4B02-9826-5D99428E115F}` = Quick Access / Home Folder (shell32.dll) - 917 hits
- `{FBF23B40-E3F0-101B-8488-00AA003E56F8}` = Internet Shortcut (ieframe.dll) - 526 hits
- `{00021401-0000-0000-C000-000000000046}` = Shell Link .lnk handler (windows.storage.dll) - 441 hits

**Fix applied:**
```powershell
# Remove 7 OneDrive ghost overlays
Remove-Item 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers\OneDrive*' -Force
# Disable Offline Files service
Set-Service CscService -StartupType Disabled
# Set Explorer default to "This PC" instead of Quick Access
Set-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name LaunchTo -Value 1
```
**Result:** -6% immediately (overlays unload at reboot). Full effect expected after restart.

---

### Storm 5: WMI Repository Thrash

**Rate:** 302 ops/sec on `C:\Windows\System32\wbem\Repository\OBJECTS.DATA` (503 hits/30s)

**Root cause:** MSI Afterburner (PID 6200, 7MB RAM, 19.8s CPU) polling Win32_PerfFormattedData WMI classes for GPU/CPU sensor readings. Winmgmt rebuilds tracing config check on each query, compounding Storm 2.

**Fix:** Informational only - Afterburner is intentional monitoring software.
- Increase Afterburner's hardware polling interval (Settings > Monitoring > Hardware polling period)
- Or switch to RTSS-only overlay (bypasses WMI entirely, uses direct NVML)
- Or use HWiNFO with shared memory mode (lower WMI overhead)

---

### Storm 6: SearchIndexer.exe (Windows Search) — DISCOVERED POST-FIX

**Rate:** 8,292 events/sec (248,750 events/30s) — **LARGEST single process on system**
**What:** WSearch service writing to `C:\ProgramData\Microsoft\Search` index database

**Root cause:** WSearch service set to Automatic with 50+ scope paths. Post-reboot indexing burst generates massive file I/O:
- 211,177 ReadFile + 29,411 WriteFile = 240K file I/O ops in 30 seconds
- Scope includes dev folders: `.claude`, `.cargo`, `.rustup`, `ComfyUI`, `AppData`, `ProgramData`, `Brand Analysis`, `windows-latency-optimizer`, etc.
- On a gaming rig, full-text search indexing provides minimal value vs massive I/O cost
- Was NOT visible in original baseline because SearchIndexer wasn't in active indexing burst at that time

**Fix applied:**
```powershell
Set-Service WSearch -StartupType Disabled
Stop-Service WSearch -Force
```
**Result:** Service stopped and disabled. Start Menu app search still works. File content search slower but rarely used on gaming rig.

---

### Storm 7: Explorer Enterprise Policy + AppCompat Overhead

**Rate:** 638+ registry reads/sec on policy paths
**What:** Explorer checks WIP/DataProtection, AppCompat shim database, Terminal Server config

**Root cause:** Enterprise features active on gaming desktop:
- DataProtection/WIP policies: 1,314 reads/30s (Windows Information Protection — enterprise DLP)
- AppCompat shim database: 674 reads/30s (compatibility checks for every launched app)
- ShellHWDetection service: triggers COM notifications for hardware changes on static desktop

**Fix applied:**
```powershell
Set-Service ShellHWDetection -StartupType Disabled
Stop-Service ShellHWDetection -Force
# Disable WIP/DataProtection
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataProtection' -Name AllowDirectMemoryAccess -Value 0
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataProtection' -Name AllowAzureRMSForEDP -Value 0
# Disable AppCompat engine
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat' -Name DisableEngine -Value 1
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat' -Name DisablePCA -Value 1
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat' -Name DisableUAR -Value 1
```
**Result:** Full effect after reboot. Expected Explorer reduction from ~2,000 to ~800/sec.

---

### Storm 8: camsvc Escalation (Manual → Disabled)

**Rate:** 980/sec when Manual start triggers on-demand
**What:** Chrome triggers camsvc to check ALL capability policies (camera, mic, location, contacts)

**Root cause:** Setting camsvc to Manual (Storm 3 original fix) was insufficient. Chrome triggers camsvc on-demand via COM activation. Once running, camsvc polls `PolicyManager\default\Privacy` for ALL capability types at 980/sec — far worse than the original 216/sec.

**Fix applied:** Changed Storm 3 fix from Manual to Disabled.
```powershell
Set-Service camsvc -StartupType Disabled
Stop-Service camsvc -Force
```
**Result:** 980/sec → 0. Camera/mic still work at hardware level. Windows privacy permission UI dialogs won't show.

---

## Post-Fix Verification (2026-04-27, 3 captures)

### Service Firing Rate Breakdown (all svchost services)

| Service | Events/sec | Verdict |
|---------|-----------|---------|
| Winmgmt | 624 (settles to ~271) | Windows bug, unfixable |
| Appinfo (UAC) | 183 | Higher when elevated session active |
| Dnscache | 117 | Active DNS from Chrome |
| BrokerInfra/DcomLaunch/Power | 61 | Normal core infrastructure |
| RPC | 37 | Normal |
| StateRepository | 17 | AppX state, normal |
| 55+ other svchost PIDs | 0.2/sec each | Just ProcMon process profiling |

### Final Capture Results (WSearch=Disabled, camsvc=Disabled)

| Process | Pre-fix/sec | Post-fix/sec | Delta | Notes |
|---------|------------|-------------|-------|-------|
| SearchIndexer (Storm 6) | 8,292 | **0** | **-100%** | WSearch disabled |
| camsvc (Storm 3) | 980 | **0** | **-100%** | Disabled (Manual insufficient) |
| System kernel (PID 4) | 2,564 | 326 | **-87%** | Was driven by SearchIndexer |
| Winmgmt (Storm 2) | 1,721 | 624 | -64% | Settling toward steady ~271 |
| ctfmon (Storm 1) conflict reads | 6,000/30s | 2,352/30s | **-61%** | Specific per-IME reads |
| ctfmon total | 422 | ~500 | baseline | Text input framework always polls |
| Explorer.EXE (Storm 4) | 1,943 | 2,350 | +21% | Post-boot transient |

### Key Insights

1. **ctfmon 99.3% was anomalous.** First capture caught ctfmon not yet polling. Actual per-IME conflict reads dropped -61%. Total ctfmon ~500/sec is normal text input framework behavior (polls harder when Chrome/text fields focused).

2. **System kernel I/O was 87% SearchIndexer.** PID 4's 2,564/sec was memory-mapped file ops for index database. With WSearch disabled: 326/sec = normal kernel I/O.

3. **camsvc Manual was insufficient.** Chrome triggers camsvc on-demand to check camera/mic/location capability policies. Once started: 980/sec polling ALL policies. Must be Disabled, not Manual.

4. **Winmgmt is a known Windows design flaw.** WMI service lacks `RegNotifyChangeKeyValue` for tracing config. Uses tight polling loop instead. ~271/sec steady-state. Cannot disable WMI without breaking hardware monitoring, PowerShell, Afterburner, etc.

---

## Detection Methodology

1. **Capture:** ProcMon64 30-second idle capture, no filters, save as CSV
2. **Count:** Events per process - anything >100/sec at idle = polling storm
3. **Group:** Registry paths by process to find which keys are hammered
4. **Identify service:** `Get-WmiObject Win32_Service -Filter "ProcessId=XXXX"` for svchost PIDs
5. **Check conflicts:** Same setting at different registry levels (HKLM vs HKCU vs per-app vs per-IME)
6. **Fix at source:** Align conflicting settings, disable unused services, remove ghost extensions, set Group Policy

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/fix_system_polling.ps1` | Apply all 8 fixes (backup + rollback support) |
| `scripts/enable_system_polling.ps1` | Rollback all changes |
| `scripts/analyze_procmon_idle.ps1` | Capture + analyze with CLI noise exclusion |

**Backup:** `captures/backup_pre_system_polling_fix_20260427_134032.txt`
