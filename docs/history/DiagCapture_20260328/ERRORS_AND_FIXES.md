# System Diagnostic: Errors Found & Fixes Applied

**Date:** 2026-04-09
**System:** AMD Ryzen 7 9800X3D / RTX 5070 Ti / 32GB DDR5-6000 / Windows 11 Pro 26200

---

## Errors Found

### 1. BTHUSB Driver Crash (HIGH SEVERITY)

**Error:** `BTHUSB Error 17` + `BTHUSB Warning 3` in Event Viewer, every boot.
**Detail:** "The local Bluetooth adapter has failed in an undetermined manner and will not be used. The driver has been unloaded." Preceded by "A command sent to the adapter has timed out."
**Driver:** Generic Bluetooth Adapter, driver dated 2006-06-20 (placeholder driver, not manufacturer-specific)
**Device:** USB Bluetooth adapter (VID_0489, PID_E0E2)
**Impact:** Crashing drivers generate DPC (Deferred Procedure Call) latency spikes. Every time the driver loads, fails, and unloads, it disrupts interrupt handling. This can cause system-wide micro-stutters and input delay.
**Event IDs:** Error 17, Warning 3 (System log, source: BTHUSB)

### 2. UDP Port Exhaustion (HIGH SEVERITY)

**Error:** `Tcpip Warning 4266` on 2026-04-08 at 15:24:53
**Detail:** "A request to allocate an ephemeral port number from the global UDP port space has failed due to all such ports being in use."
**Configuration:** Default range was 49152-65535 (only 16,384 ports)
**Impact:** When UDP ports run out, new game connections fail. Causes rubberbanding, connection drops, and network lag. ExitLag + game connections + background apps can exhaust this small pool.

### 3. Razer Software Bloat (MEDIUM SEVERITY)

**Processes running:** 10 RazerAppEngine instances + razer_elevation_service + Razer Game Manager Service 3
**Impact:** Each process consumes CPU cycles and can generate DPC latency through USB polling. Razer Synapse is a known DPC latency contributor. The Game Manager Service provides overlay/optimization features not needed for basic mouse functionality.

### 4. luafv Driver Blocked (MEDIUM SEVERITY)

**Error:** `Service Control Manager Error 7000` every boot
**Detail:** "The luafv service failed to start due to the following error: This driver has been blocked from loading"
**Impact:** The LUA File Virtualization driver is being blocked by a security policy. Generates error handling overhead at boot. May cause startup delays but unlikely to affect runtime gaming performance.

### 5. Intel I226-V Network Link Disconnect (LOW SEVERITY)

**Warning:** `e2fnexpress Warning 27` every boot
**Detail:** "Intel(R) Ethernet Controller I226-V Network link is disconnected."
**Impact:** Occurs during boot initialization before the link establishes. Current status is UP at 1 Gbps. However, the Intel I226-V has known firmware issues in some revisions that can cause intermittent disconnects.

### 6. GameBar DCOM Timeout (LOW SEVERITY)

**Error:** `DistributedCOM Error 10010`
**Detail:** "The server Windows.Gaming.GameBar.PresenceServer.Internal.PresenceWriter did not register with DCOM within the required timeout."
**Impact:** Game Bar presence server timing out. Low impact but indicates Game Bar is attempting to run and failing.

### 7. WD_BLACK SN850X Unpartitioned (INFO)

**Detail:** Second NVMe drive (1TB WD_BLACK SN850X) is online but has zero partitions.
**Impact:** No performance impact, but games could be installed here to separate OS I/O from game I/O.

---

## Fixes Applied

### Fix 1: Bluetooth Adapter Disabled

**Command used:**
```powershell
Get-PnpDevice | Where-Object { $_.FriendlyName -like '*Bluetooth*' } | Disable-PnpDevice -Confirm:$false
```

**Effect:** Prevents the BTHUSB driver from loading and crashing. Eliminates DPC latency spikes from Bluetooth.

**How to revert:**
```powershell
# Re-enable the Bluetooth adapter
Get-PnpDevice | Where-Object { $_.FriendlyName -like '*Bluetooth*' } | Enable-PnpDevice -Confirm:$false

# Or via Device Manager: Bluetooth > Generic Bluetooth Adapter > Right-click > Enable device
```

**Permanent fix:** Install the correct Bluetooth driver from your ASUS motherboard support page, or if you don't use Bluetooth, leave it disabled.

---

### Fix 2: Razer Game Manager Service Stopped

**Commands used:**
```powershell
Stop-Service "Razer Game Manager Service 3" -Force
Set-Service "Razer Game Manager Service 3" -StartupType Manual
```

**Effect:** Stops the Game Manager overlay/optimization service. Reduces background CPU usage and potential DPC interference. Your Viper V3 Pro wireless mouse continues to work via the core Razer services.

**How to revert:**
```powershell
# Restart the service
Set-Service "Razer Game Manager Service 3" -StartupType Automatic
Start-Service "Razer Game Manager Service 3"

# Or open Razer Synapse > it will restart the service automatically
```

**Note:** The 10 RazerAppEngine processes will clear on next reboot. Only essential ones will restart since Game Manager is now set to Manual.

---

### Fix 3: Ephemeral Port Range Expanded

**Commands used:**
```cmd
netsh int ipv4 set dynamicport udp start=1025 num=64511
netsh int ipv4 set dynamicport tcp start=1025 num=64511
```

**Before:** 49152-65535 (16,384 ports)
**After:** 1025-65535 (64,511 ports) -- 4x larger

**Effect:** Prevents UDP/TCP port exhaustion. All game connections, ExitLag, and background apps now have a much larger port pool.

**How to revert:**
```cmd
:: Restore Windows default port range
netsh int ipv4 set dynamicport udp start=49152 num=16384
netsh int ipv4 set dynamicport tcp start=49152 num=16384
```

**Note:** This setting persists across reboots. No need to reapply.

---

### Fix 4: UAC Disabled (Pre-existing)

**Observed:** `EnableLUA = 0` in registry. UAC is completely disabled.
**Impact:** Not a fix we applied, but worth noting. With UAC off, all processes run with full admin privileges. This means malware or misbehaving software has unrestricted access. Consider re-enabling UAC if security is a concern:
```cmd
:: Re-enable UAC (requires reboot)
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLUA /t REG_DWORD /d 1 /f
```

---

## Master Revert Script

Run this to undo ALL fixes and restore original state:

```powershell
# --- Revert ALL fixes ---

# 1. Re-enable Bluetooth adapter
Get-PnpDevice | Where-Object { $_.FriendlyName -like '*Bluetooth*' } | Enable-PnpDevice -Confirm:$false

# 2. Restore Razer Game Manager Service
Set-Service "Razer Game Manager Service 3" -StartupType Automatic
Start-Service "Razer Game Manager Service 3"

# 3. Restore default port range
netsh int ipv4 set dynamicport udp start=49152 num=16384
netsh int ipv4 set dynamicport tcp start=49152 num=16384

Write-Host "All fixes reverted. Reboot to fully restore original state."
```

Save this as `C:\Users\L\Desktop\DiagCapture\REVERT_ALL_FIXES.ps1`

---

## System Configuration Snapshot

| Component | Value |
|---|---|
| CPU | AMD Ryzen 7 9800X3D 8C/16T @ 4.7 GHz |
| GPU | NVIDIA RTX 5070 Ti, driver 32.0.15.9597 (2026-03-16) |
| RAM | 32GB DDR5-6000 (Team Group, dual channel, XMP/EXPO active) |
| Storage | Samsung 9100 PRO 1TB NVMe (C:) + WD_BLACK SN850X 1TB NVMe (unpartitioned) |
| Network | Intel I226-V 1Gbps Ethernet |
| Power Plan | Ultimate Performance (min/max 100%) |
| OS | Windows 11 Pro Build 26200 |
| UAC | Disabled (EnableLUA=0) |
| Mouse | Razer Viper V3 Pro (wireless USB) |
| Keyboard | Wooting (analog hall-effect, USB) |
| Audio | Realtek USB 2.0 Audio |
| Motherboard | ASUS ROG (BIOS 3602, 2026-02-24) |
