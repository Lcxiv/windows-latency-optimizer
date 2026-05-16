---
tags: [reference, bios, scewin, am5]
date: 2026-04-10
status: complete
aliases: [SCEWIN, BIOS Mod]
---

# SCEWIN BIOS Modification Reference

## Tool Location
`C:\Users\L\Downloads\AMD BIOS Tweaks by CatGamerOP\SCEWIN\5.05.01.0002\SCEWIN_64.exe`

## Key Commands
```powershell
# Export all settings
SCEWIN_64.exe /o /s nvram.txt /d

# Import modified settings (causes SMI lag - close games first)
SCEWIN_64.exe /i /s nvram.txt /q

# Read ONE setting (preferred - single SMI)
SCEWIN_64.exe /o /lang en-US /ms "Setting Name" /hb

# Write ONE setting (preferred - single SMI)
SCEWIN_64.exe /i /lang en-US /ms "Setting Name" /qv 0x01 /hb
```

## Export Format
```
Setup Question  = Global C-state Control
Token           =37C        // Do NOT change this line
Offset          =0F
Width           =01
BIOS Default    =[01]Enabled
Options         =[00]Disabled
                *[01]Enabled    // asterisk marks current selection
```

## Safety Rules
- NEVER modify Token lines
- NEVER change: BIOS Lock, flash protection, Secure Boot keys, PSP settings, string variables
- Max 4 settings per import batch (groups-of-4 rule)
- Always export backup first: `SCEWIN_64.exe /o /s backup_YYYYMMDD.txt`
- Single-variable `/ms` + `/qv` writes are safer than full file import
- Each write triggers SMI (45-400ms system freeze per variable)
- Close games and latency-sensitive apps before import

## Recovery
1. CMOS Clear: remove battery 30min, hold power button 30s
2. CMOS Jumper: bridge pins 3 seconds
3. BIOS Flashback: reflash from USB (board-specific)

## User's Current BIOS State (2026-04-10)
Export at: captures/bios_export_20260410_194427.txt (25,927 lines, 1028 settings parsed)
RAM: Team Group UD5-6000 EXPO DDR5-6000 CL30-36-36-76 @ 1.35V
All memory timings on Auto (no manual subtiming tuning)
PBO/CO: All on Auto, CO signs all Positive (no negative offset applied)
Global C-State: DISABLED (should be Enabled)
TSME: Auto (should be Disabled)
FCLK: Auto
