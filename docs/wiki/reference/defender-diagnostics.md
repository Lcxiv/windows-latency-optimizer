---
tags: [reference, defender, etw, scanning, exclusions]
date: 2026-04-10
status: complete
aliases: [Defender Diagnostics]
---

# Windows Defender Diagnostics Reference

## Performance Recording (Official Microsoft Tool)
```powershell
# Record what Defender scans (needs interactive console or WPR fallback)
New-MpPerformanceRecording -RecordTo C:\temp\Defender-scans.etl
# Analyze
Get-MpPerformanceReport -Path C:\temp\Defender-scans.etl -TopFiles 20 -TopProcesses 10 -TopScans 50
# Raw data with SkipReason column
Get-MpPerformanceReport -Path $etl -TopScans 200 -Raw
```

## WPR Fallback (Non-Interactive)
```powershell
$wprpPath = "C:\WINDOWS\system32\WindowsPowerShell\v1.0\Modules\ConfigDefenderPerformance\MSFT_MpPerformanceRecording.wprp"
wpr.exe -start $wprpPath -filemode
Start-Sleep -Seconds 30
wpr.exe -stop C:\temp\Defender-gaming.etl "description"
Get-MpPerformanceReport -Path C:\temp\Defender-gaming.etl -TopScans 100 -Raw
```

## Verify Exclusions
```cmd
MpCmdRun.exe -CheckExclusion -Path "C:\Path\To\Check"
```

## Key Findings (2026-04-10 Session)
- Fortnite game files: correctly excluded (zero in scan report)
- EAC drops `eac_usermode_*.dll` into System32: NOT excluded by path (22ms scan)
- Claude Code temp files (.jsonl, LevelDB, IndexedDB): NOT excluded (71ms scan, #1 target)
- Process exclusions only exclude files OPENED BY that process, not the binary itself
- EAC opens game files from ITS process, not Fortnite's - need EAC process exclusion

## Common Scan Targets During Gaming
- Game assets (.pak, .ucas, .utoc) - if accessed by non-excluded process (EAC)
- Shader cache: %LOCALAPPDATA%\D3DSCache, NVIDIA\DXCache
- Game logs: FortniteGame\Saved\Logs
- Anti-cheat binaries loaded fresh each launch
- Prefetch files in C:\Windows\Prefetch
- Any temp files in AppData not covered by exclusion paths
