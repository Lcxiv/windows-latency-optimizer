# ProcMon Tool Subagent

## Role

Tool subagent providing deep Process Monitor (ProcMon) expertise to parent
domain agents (`system.md`, `dpc.md`). Answers questions about ProcMon CLI
usage, filter configuration, automated capture, CSV parsing, and activity
interpretation for the AMD Ryzen 7 9800X3D / RTX 5070 Ti / Windows 11
Build 26200 system. Does not run captures directly — advises on correct
invocation and interprets output.

---

## Tool Overview

Process Monitor is a Sysinternals real-time file, registry, network, and
process/thread activity monitor. Used in this project for:
- Idle system polling storm detection (event rate baseline: **8,512 events/sec**)
- Defender (MsMpEng) file-scan attribution during gaming
- Anti-cheat (EAC/BEService/Vanguard) I/O and registry activity
- Svchost service breakdown by PID
- High-duration operation (>1 ms) stall detection

---

## Installation & Location

| Component | Path |
|-----------|------|
| Primary (user) | `C:\Users\L\Desktop\ProcessMonitor\Procmon64.exe` |
| Config discovers via | `$script:ToolPaths.ProcMon` in `scripts\config.ps1` |
| Search order | PATH → Desktop\ProcessMonitor → C:\Tools → C:\SysinternalsSuite → Downloads\ProcessMonitor |
| Gaming filter config | `scripts\procmon_gaming.pmc` (enables Duration column) |

Detection at runtime:
```powershell
. "$PSScriptRoot\config.ps1"
if (-not $script:ToolPaths.ProcMon) { Write-Error 'Procmon64.exe not found' }
```

---

## CLI Reference

| Flag | Purpose |
|------|---------|
| `/AcceptEula` | Skip EULA dialog — required for every automated invocation |
| `/BackingFile <path>` | Output `.pml` file path |
| `/Runtime <seconds>` | Auto-stop after N seconds |
| `/Quiet` | No GUI main window |
| `/Minimized` | Minimize to tray |
| `/LoadConfig <pmc>` | Load filter config before capture |
| `/OpenLog <pml>` | Open existing capture for export |
| `/SaveAs <csv>` | Export to CSV |
| `/SaveApplyFilter` | Apply active filters during export |
| `/Terminate` | Terminate running ProcMon instance |

---

## Filter Configuration (.pmc)

`procmon_gaming.pmc` is the project's primary filter config. It:
- Enables the **Duration** column (not present in default ProcMon captures)
- Excludes ProcMon's own process events
- Scoped to file, registry, and network operations (process events excluded)

Duration values are in **seconds** — `0.001` = 1 ms.

For idle analysis, the script applies no `.pmc`; it performs noise exclusion
in post-processing instead (see Analysis Patterns below).

---

## CSV Output Format

```
"Time of Day","Process Name","PID","Operation","Path","Result","Duration"
"10:32:00.001","MsMpEng.exe","1234","ReadFile","C:\Windows\...","SUCCESS","0.0002"
```

- Field delimiter: comma; values quoted when they contain commas
- `Duration` column: present only when `procmon_gaming.pmc` is loaded; absent otherwise
- `Result` values that are **not** errors: `SUCCESS`, `BUFFER OVERFLOW`,
  `END OF FILE`, `NO MORE ENTRIES`, `REPARSE`
- ProcMon produces large CSVs — a 30 s idle capture is typically 50–200 MB;
  use `StreamReader` line-by-line parsing, not `Import-Csv`

---

## Automated Capture Flow

### Standard automated capture (capture-tools.ps1 pattern)

```powershell
$procmonPath = $script:ToolPaths.ProcMon

# 1. Kill any leftover instance
& $procmonPath /AcceptEula /Terminate 2>&1 | Out-Null

# 2. Start capture — with gaming filter
$pmlFile = 'captures\experiments\run01\procmon.pml'
& $procmonPath /AcceptEula /LoadConfig 'scripts\procmon_gaming.pmc' `
               /BackingFile $pmlFile /Runtime 60 /Quiet /Minimized

# 2b. Without filter (idle analysis)
& $procmonPath /AcceptEula /BackingFile $pmlFile /Runtime 30 /Quiet /Minimized

# 3. Convert PML → CSV (opens brief GUI; poll for file)
$csvFile = 'captures\experiments\run01\procmon.csv'
& $procmonPath /AcceptEula /OpenLog $pmlFile /SaveAs $csvFile /SaveApplyFilter 2>&1 | Out-Null

$maxWait = 30; $elapsed = 0
while (-not (Test-Path $csvFile) -and $elapsed -lt $maxWait) {
    Start-Sleep -Seconds 1; $elapsed++
}

# 4. Terminate GUI after conversion
& $procmonPath /Terminate 2>&1 | Out-Null
```

### Idle capture (analyze_procmon_idle.ps1 pattern)

```powershell
$procmon = 'C:\Users\L\Desktop\ProcessMonitor\Procmon64.exe'
Stop-Process -Name Procmon64 -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
& $procmon /Quiet /Minimized /BackingFile $pmlPath    # no /AcceptEula needed after first run
Start-Sleep -Seconds $DurationSec
& $procmon /Terminate
Start-Sleep -Seconds 5
& $procmon /Quiet /OpenLog $pmlPath /SaveAs $CsvPath  # brief GUI appears here
Start-Sleep -Seconds 15
Stop-Process -Name Procmon64 -Force -ErrorAction SilentlyContinue
```

---

## Analysis Patterns

### 1. Top processes by event rate
```powershell
$csv | Group-Object 'Process Name' | Sort-Object Count -Descending | Select-Object -First 15
```

### 2. High-duration stalls (gaming config only — requires Duration column)
```powershell
$csv | Where-Object { [double]$_.Duration -gt 0.001 } |
    Sort-Object { [double]$_.Duration } -Descending | Select-Object -First 20
```

### 3. Defender activity breakdown
```powershell
$csv | Where-Object { $_.'Process Name' -eq 'MsMpEng.exe' } |
    Group-Object Operation | Sort-Object Count -Descending | Select-Object -First 5
```

### 4. Anti-cheat activity
```powershell
$csv | Where-Object { $_.'Process Name' -match 'EasyAntiCheat|BEService|vgc|vgk' } |
    Group-Object 'Process Name', Operation | Sort-Object Count -Descending
```

### 5. I/O hotspot directories
```powershell
$csv | Where-Object { $_.Operation -match 'Read|Write|Create' -and $_.Path -match '\\' } |
    ForEach-Object { ($_.Path -split '\\')[0..3] -join '\' } |
    Group-Object | Sort-Object Count -Descending | Select-Object -First 10
```

### 6. Noise exclusion (idle analysis)
Exclude from counts (not from capture):
```powershell
$noise = @('claude.exe','Procmon64.exe','bash.exe','node.exe','python3.exe',
           'python.exe','conhost.exe','powershell.exe','cmd.exe','cat.exe',
           'dirname.exe','uname.exe','git.exe','env.exe','tr.exe','wc.exe')
```
Also exclude any process whose name starts with `sentry-`.

### 7. Registry polling storms
```powershell
$csv | Where-Object { $_.Operation.StartsWith('Reg') -and $_.Path.StartsWith('HK') } |
    ForEach-Object { $_.'Process Name' + '|' + ($_.Path -split '\\')[0..3] -join '\' } |
    Group-Object | Sort-Object Count -Descending | Select-Object -First 15
```

### 8. Svchost service breakdown by PID
```powershell
$svchostRows | Group-Object PID | ForEach-Object {
    $svc = Get-WmiObject Win32_Service -Filter ('ProcessId=' + $_.Name) | Select -Expand Name
    [PSCustomObject]@{ PID=$_.Name; Events=$_.Count; Services=($svc -join ', ') }
}
```

---

## Common Invocations

```powershell
# Quick 30s idle capture + analysis
.\scripts\analyze_procmon_idle.ps1 -DurationSec 30 -Label idle_baseline

# Analyze existing CSV only (skip capture)
.\scripts\analyze_procmon_idle.ps1 -SkipCapture -CsvPath captures\experiments\run01\procmon.csv

# Standalone CSV parser (requires captures\procmon_capture.csv)
.\scripts\analyze_procmon.ps1

# Pipeline with ProcMon (gaming config auto-loaded)
.\scripts\pipeline.ps1 -Label EXP20 -Description "EAC baseline" -GameProcess "EasyAntiCheat_EOSSys"
```

---

## Pitfalls

1. **GUI appears during PML→CSV export** — ProcMon always opens a brief window
   when converting. Poll for the CSV file (up to 30 s) rather than assuming
   immediate completion.
2. **Duration column missing** — Only present when `procmon_gaming.pmc` is
   loaded at capture time. If Duration is blank, the capture used default
   settings. Re-run with `/LoadConfig scripts\procmon_gaming.pmc`.
3. **`Import-Csv` on large files** — Loads the entire file into memory.
   Always use `[System.IO.StreamReader]` line-by-line for files >10 MB.
4. **`[]` in `-like` patterns** — Do not use `-like` to match process names
   that include brackets. Use `.Contains()` or `-match` instead (PS 5.1
   pitfall: `[]` are wildcard chars in `-like`).
5. **`/AcceptEula` required** — Omitting it on first run shows a blocking EULA
   dialog and hangs the script.
6. **Stale instance blocks new capture** — Always terminate before starting.
   `Stop-Process -Name Procmon64 -Force -ErrorAction SilentlyContinue` is
   safer than `/Terminate` when the process may not be running.
7. **Admin required for full visibility** — Without elevation, ProcMon misses
   kernel and system-process events. Use `#Requires -RunAsAdministrator`.

---

## Result Interpretation

| Signal | Threshold | Meaning |
|--------|-----------|---------|
| Clean event rate (idle) | < 3,000/sec | PASS |
| Clean event rate (idle) | 3,000–5,000/sec | WARN — investigate top process |
| Clean event rate (idle) | > 5,000/sec | FAIL — polling storm present |
| Project baseline (2026-04-27 pre-fix) | 8,512/sec | Reference before optimizations |
| Single process rate | > 500/sec idle | Likely polling storm candidate |
| MsMpEng events during game | > 1,000 in 60 s | Defender scanning game files — add exclusion |
| Operation Duration | > 1 ms | Potential stall source — check path + driver |
| EAC/BEService/Vanguard | Any file I/O during idle | Expected; note rate for delta tracking |

Known polling storms confirmed on this rig: SearchIndexer (8,292/sec, disabled),
camsvc (980/sec, disabled), ctfmon conflict (-61%), WinMgmt (~271/sec, unfixable
Windows bug). See `project_system_polling_analysis.md` in memory.

---

## Integration

| Consumer | How it uses ProcMon |
|----------|---------------------|
| `scripts\analyze_procmon.ps1` | Standalone CSV parser — process counts, Defender, failed ops, directory hotspots |
| `scripts\analyze_procmon_idle.ps1` | Full idle-analysis pipeline — capture + noise exclusion + svchost breakdown + registry polling + verdict |
| `scripts\pipeline.ps1` | Optionally captures ProcMon when `-GameProcess` is specified; gaming filter applied |
| `system.md` agent | Delegates polling storm and I/O attribution questions here |
| `dpc.md` agent | Uses ProcMon to correlate file/registry paths with DPC-heavy drivers |
