# System Latency Audit Tool — Design Spec

*Date: 2026-04-02 | Status: Draft | Author: Louis + Claude*

## Problem

Diagnosing gaming latency issues on Windows requires checking dozens of OS, driver, NIC, GPU, peripheral, and network settings across multiple registry paths, Device Manager properties, bcdedit flags, and TCP parameters. During a real investigation (Fortnite periodic stutter on 9800X3D / 5070 Ti / I226-V), we manually discovered 15+ independent issues — wrong NIC driver line (Win10 on Win11), MPO enabled, Hyper-V active, RAM at JEDEC speeds, mouse at 125Hz, missing Nagle disable, etc. Each took research and multiple commands to detect.

A single audit script should catch all of these automatically, produce a shareable report, and generate a targeted fix script.

## Audience

Community tool (GitHub). Must work on any Windows 10/11 gaming PC regardless of hardware. Hardware is detected dynamically; checks adapt to what's present.

## Architecture

Single `audit.ps1` entry point with modular check functions. Each check is self-contained, returns a structured result, and declares its own fix command.

```
audit.ps1 -Mode Quick|Deep [-GenerateFix] [-OutDir path]
    |
    +-- Check functions (each returns structured result)
    |   +-- OS checks       (Quick tier)
    |   +-- NIC checks      (Quick tier)
    |   +-- GPU checks      (Quick tier)
    |   +-- Peripheral checks (Deep tier)
    |   +-- Memory checks     (Deep tier)
    |   +-- Network checks    (Deep tier)
    |
    +-- Result aggregation --> JSON
    +-- HTML report generation (self-contained)
    +-- Fix script generation (only FAIL/WARN items)
```

### Parameters

```powershell
param(
    [ValidateSet('Quick','Deep')]
    [string]$Mode = 'Quick',

    [switch]$GenerateFix,

    [string]$OutDir = "$PSScriptRoot\..\captures\audits"
)
```

### Check Result Schema

Every check function returns a hashtable:

```powershell
@{
    name     = 'MPO Disabled'
    category = 'OS'              # OS | NIC | GPU | Peripheral | Memory | Network
    tier     = 'Quick'           # Quick | Deep
    severity = 'HIGH'            # CRITICAL | HIGH | MEDIUM | LOW | INFO
    status   = 'FAIL'           # PASS | WARN | FAIL | SKIP | ERROR
    current  = 'Not set (MPO enabled)'
    expected = 'DisableOverlays = 1'
    message  = 'MPO causes periodic frame-time spikes on NVIDIA GPUs'
    source   = 'https://www.ordoh.com/disable-mpo-windows-11-stutter-fix/'
    fix      = 'reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v DisableOverlays /t REG_DWORD /d 1 /f'
    fixNote  = 'Reboot required'
}
```

- `status = 'SKIP'` when the check doesn't apply (e.g., no NVIDIA GPU found)
- `status = 'ERROR'` when the check itself fails (access denied, missing path)
- `fix` is `$null` when status is PASS/SKIP/ERROR or no automated fix exists
- `fixNote` provides human context (reboot required, BIOS change needed, etc.)

## Check Catalog

### Quick Tier (~15 seconds)

#### OS Category

| # | Name | Severity | Detection | Expected | Fix |
|---|------|----------|-----------|----------|-----|
| 1 | MPO Disabled | HIGH | `HKLM:\...\GraphicsDrivers\DisableOverlays` | `1` | `reg add ... /v DisableOverlays /d 1` |
| 2 | Hyper-V Off | MEDIUM | `bcdedit /enum {current}` hypervisorlaunchtype | `Off` | `bcdedit /set hypervisorlaunchtype off` |
| 3 | VBS/Core Isolation Off | MEDIUM | `HKLM:\...\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity\Enabled` | `0` | Registry set + reboot |
| 4 | MMCSS SystemResponsiveness | HIGH | `HKLM:\...\Multimedia\SystemProfile\SystemResponsiveness` | `0` | Registry set |
| 5 | MMCSS NetworkThrottling | HIGH | `HKLM:\...\Multimedia\SystemProfile\NetworkThrottlingIndex` | `0xFFFFFFFF` | Registry set |
| 6 | MMCSS Games Priority | MEDIUM | `...\SystemProfile\Tasks\Games\Priority` and `SFIO Priority` | `6` / `High` | Registry set |
| 7 | Power Plan | HIGH | `powercfg /getactivescheme` | Ultimate Performance or High Performance | `powercfg /setactive SCHEME_MIN` |
| 8 | Win32PrioritySeparation | MEDIUM | `HKLM:\...\Control\PriorityControl\Win32PrioritySeparation` | `0x26` (38) or `0x16` (22) | Registry set |
| 9 | GameInput Duplicates | MEDIUM | `Get-AppxPackage *GameInput*` count | `<= 1` | Uninstall instructions (manual) |
| 10 | FSO Disabled (global) | LOW | `HKLM:\...\GraphicsDrivers` "Optimizations for windowed games" | Off or per-game | Instructions only |

#### NIC Category

| # | Name | Severity | Detection | Expected | Fix |
|---|------|----------|-----------|----------|-----|
| 11 | NIC Driver Line | CRITICAL | Compare driver version major (1.x = Win10, 2.x = Win11) for Intel I225/I226 | Win11 line (2.x) on Win11 | Manual download link |
| 12 | NIC Speed/Duplex | HIGH | `*SpeedDuplex` advanced property on I226-V | Not "Auto Negotiation" at 2.5G | Force 1G Full Duplex |
| 13 | NIC EEE | HIGH | `*EEE` or `EEELinkAdvertisement` | Off/Disabled | `Set-NetAdapterAdvancedProperty` |
| 14 | NIC Interrupt Moderation | MEDIUM | `*InterruptModeration` | Disabled | `Set-NetAdapterAdvancedProperty` |
| 15 | Nagle Disabled | MEDIUM | Per-interface `TcpAckFrequency` + `TCPNoDelay` | Both `1` | `Set-ItemProperty` on interface GUID |
| 16 | NIC Interrupt Affinity | HIGH | Check if CPU 0 interrupt share > 10% (via perf counter snapshot) | CPU 0 < 10% | Affinity policy registry |

#### GPU Category

| # | Name | Severity | Detection | Expected | Fix |
|---|------|----------|-----------|----------|-----|
| 17 | GPU MSI Mode | MEDIUM | `...\Interrupt Management\MessageSignaledInterruptProperties\MSISupported` | `1` | Registry set |
| 18 | GPU Interrupt Affinity | MEDIUM | GPU device affinity policy | Not default (CPU 0) | Registry set to CPUs 4-7 |
| 19 | HAGS Enabled | LOW | `HKLM:\...\GraphicsDrivers\HwSchMode` | `2` (for RTX 40/50/RX 9000) | Registry set |

### Deep Tier (~30-60 seconds additional)

#### Memory Category

| # | Name | Severity | Detection | Expected | Fix |
|---|------|----------|-----------|----------|-----|
| 20 | RAM Speed vs Rated | HIGH | `ConfiguredClockSpeed` vs `Speed` (JEDEC) from `Win32_PhysicalMemory` | Configured >= Speed | BIOS instruction (EXPO/XMP) |

#### Peripheral Category

| # | Name | Severity | Detection | Expected | Fix |
|---|------|----------|-----------|----------|-----|
| 21 | Mouse Polling Rate Risk | HIGH | Detect known mice (Razer VID 1532, Logitech VID 046D) without companion software running | Warn if no config software | Instructions to save onboard profile |
| 22 | Capture Card Present | MEDIUM | Scan PCI/USB for known capture card VIDs (AVerMedia 07CA, Elgato 0FD9) | Info/warn about DPC impact | Disable when not streaming |
| 23 | Overlay Processes | MEDIUM | Check for Discord, GeForce overlay, Xbox Game Bar, Steam overlay, NZXT CAM | None running | Kill/disable instructions |

#### Network Category

| # | Name | Severity | Detection | Expected | Fix |
|---|------|----------|-----------|----------|-----|
| 24 | TCP Auto-Tuning | MEDIUM | `netsh int tcp show global` | `restricted` | `netsh int tcp set global autotuninglevel=restricted` |
| 25 | TCP Timestamps | LOW | Same source | `disabled` | `netsh int tcp set global timestamps=disabled` |
| 26 | TCP RSC | MEDIUM | Same source | `disabled` | `netsh int tcp set global rsc=disabled` |
| 27 | TCP InitialRTO | LOW | Same source | `300` | `netsh int tcp set global initialRto=300` |
| 28 | NIC IPv6 | MEDIUM | `Get-NetAdapterBinding -ComponentID ms_tcpip6` | Disabled | `Disable-NetAdapterBinding` |
| 29 | NIC Flow Control | LOW | `*FlowControl` advanced property | Disabled | `Set-NetAdapterAdvancedProperty` |
| 30 | Defender CPU Limit | MEDIUM | `HKLM:\...\Policies\Microsoft\Windows Defender\...\ScanAvgCPULoadFactor` | `<= 10` | Registry set |
| 31 | KB5077181 Stutter Bug | MEDIUM | Check installed hotfixes for KB5077181/KB5079473 on Build 26200 | Warn if present | FSO disable + instructions |
| 32 | Network Latency Probe | INFO | Ping Epic Games + Cloudflare servers (reuse `Invoke-NetworkLatencyCapture`) | p99 < 50ms, jitter < 10ms | Diagnostic only |

## Output Files

### JSON (`audit_YYYYMMDD_HHMMSS.json`)

```json
{
    "schemaVersion": 1,
    "auditedAt": "2026-04-02T07:30:00",
    "mode": "Deep",
    "system": {
        "os": "Windows 11 Pro Build 26200",
        "cpu": "AMD Ryzen 7 9800X3D",
        "gpu": "NVIDIA GeForce RTX 5070 Ti",
        "gpuDriver": "32.0.15.9597",
        "ram": "32 GB DDR5 6000 MT/s",
        "nic": "Intel I226-V",
        "nicDriver": "2.1.5.7",
        "storage": ["Samsung SSD 9100 PRO 1TB", "WD_BLACK SN850X 1TB"]
    },
    "summary": {
        "total": 32,
        "pass": 22,
        "warn": 4,
        "fail": 5,
        "skip": 1,
        "error": 0,
        "score": 69
    },
    "checks": [
        { "name": "...", "category": "...", ... }
    ],
    "fixScriptPath": "captures/audits/fix_20260402_073000.ps1"
}
```

### HTML Report (`audit_YYYYMMDD_HHMMSS.html`)

Self-contained (inline CSS + JS, no CDN, no fetch). Sections:

1. **Header** — score badge (e.g., "22/32 PASS"), system specs summary, audit timestamp
2. **Score Cards** — category breakdown (OS 8/10, NIC 5/6, GPU 3/3, etc.) with color coding
3. **Results Table** — expandable rows per check: status icon, name, current vs expected, severity, fix command, source link
4. **Fix Script** — embedded code block with the generated fix script (copy-pasteable)
5. **Methodology** — what was checked, data sources, disclaimer

Color scheme: `#22c55e` (pass), `#f59e0b` (warn), `#ef4444` (fail), `#6b7280` (skip)

### Fix Script (`fix_YYYYMMDD_HHMMSS.ps1`)

Generated only when `-GenerateFix` is passed. Contains:

1. Header comment with audit summary + disclaimer
2. Backup section (captures current state of everything it will change)
3. One section per FAIL/WARN item with:
   - Comment explaining what and why
   - The fix command
   - Verification command
4. Summary of changes + reboot requirement flag
5. Rollback instructions pointing to backup

Follows existing `exp*_apply.ps1` backup/rollback pattern. Compatible with `rollback.ps1`.

## File Structure

```
scripts/
    audit.ps1               # Main entry point (~150 lines orchestration)
    audit-checks.ps1        # All check functions (~400 lines, dot-sourced)
    audit-report.ps1        # HTML generation (~200 lines, dot-sourced)
captures/
    audits/                 # Output directory
        audit_YYYYMMDD_HHMMSS.json
        audit_YYYYMMDD_HHMMSS.html
        fix_YYYYMMDD_HHMMSS.ps1
```

Three files because:
- `audit.ps1` stays small (orchestration only, easy to read)
- `audit-checks.ps1` is the knowledge base (all checks in one place, easy to add new ones)
- `audit-report.ps1` separates presentation from logic (HTML template doesn't clutter check logic)

## Hardware Detection Strategy

Rather than hardcoding for specific hardware, each check function detects what's present:

- **NIC checks:** `Get-NetAdapter` to find active adapters. Match Intel I225/I226 by VID `8086` + known I225/I226 DEV IDs. For other NICs, run generic EEE/Flow Control/IPv6 checks.
- **GPU checks:** `Win32_VideoController` to find GPU. Match NVIDIA by name prefix, AMD by name prefix. Skip GPU-specific checks if neither found.
- **Mouse checks:** Scan HID devices for known VIDs (Razer 1532, Logitech 046D, SteelSeries 1038). Check if companion software process is running. If mouse detected without software, warn about default polling rate.
- **NIC driver line check:** Only flags Win10-vs-Win11 mismatch for Intel I225/I226. For other NICs, skips this check (SKIP status).

## Constraints

- PowerShell 5.1 only (no ternary, no null-coalescing, no `Join-String`)
- `#Requires -RunAsAdministrator`
- No external modules or dependencies
- HTML output must be fully self-contained (inline CSS/JS)
- Must not modify any system state (read-only audit)
- Fix script is generated but never executed by the audit
- All string building uses `+` concatenation (no subexpression pitfalls)

## Testing Strategy

- Parser validation: `[Parser]::ParseFile()` for all three scripts
- Smoke test: Run `audit.ps1 -Mode Quick` on the dev machine, verify JSON + terminal output
- HTML validation: Open generated HTML in browser, verify rendering
- Fix script validation: Review generated fix script manually, verify it follows backup pattern
- Edge cases: Run on a system without NVIDIA GPU (should SKIP GPU checks), without Intel NIC (should SKIP I226-specific checks)

## Score Calculation

```
score = (pass_count / (total - skip_count - error_count)) * 100
```

Rounded to integer. Displayed as percentage in HTML report header.

## Future Extensions (Not in v1)

- Dashboard integration (load audit JSON into existing dashboard)
- Diff mode (compare two audit reports)
- Auto-update check catalog from GitHub
- Linux/SteamDeck variant
