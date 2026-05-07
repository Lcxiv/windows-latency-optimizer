# xperf Tool Subagent

## Role
Specialized subagent for xperf/WPA trace acquisition and analysis within the windows-latency-optimizer project. Called by domain agents (capture.md, dpc.md) when DPC/ISR attribution, context switch analysis, or per-CPU driver profiling is needed. All output format details and parsing patterns are embedded here — no external lookups required.

---

## Tool Overview
xperf is the command-line front-end for Windows Performance Toolkit (WPT), part of the Windows ADK. In this project it serves two distinct roles:

1. **Post-WPR analysis** — parse an ETL file produced by `wpr` into DPC/ISR histograms and context-switch tables. This is the primary path used by `pipeline.ps1` and `capture-core.ps1`.
2. **Standalone kernel tracing** — start its own kernel trace session (`-on PROC_THREAD+LOADER+DPC+INTERRUPT`), stop it to an ETL, then analyze in the same session. Used by `monitor-xperf.ps1` for live monitoring snapshots.

xperf does NOT replace WPR for long captures; it complements WPR by extracting structured per-driver data from ETLs WPR produces.

---

## Installation & Location

Primary path (hardcoded across project scripts):
```
${env:ProgramFiles(x86)}\Windows Kits\10\Windows Performance Toolkit\xperf.exe
```

Fallback (some scripts also check):
```
$env:ProgramFiles\Windows Kits\10\Windows Performance Toolkit\xperf.exe
```

Resolution pattern used in `parse_xperf_trace.ps1` and `monitor-xperf.ps1`:
```powershell
$tryPaths = @(
    "${env:ProgramFiles(x86)}\Windows Kits\10\Windows Performance Toolkit\xperf.exe",
    "$env:ProgramFiles\Windows Kits\10\Windows Performance Toolkit\xperf.exe"
)
foreach ($tp in $tryPaths) { if (Test-Path $tp) { $xperf = $tp; break } }
if (-not $xperf) {
    $cmd = Get-Command xperf -ErrorAction SilentlyContinue
    if ($cmd) { $xperf = $cmd.Source }
}
```

GPUView (related tool, same ADK install):
```
${env:ProgramFiles(x86)}\Windows Kits\10\Windows Performance Toolkit\GPUView\
```

---

## CLI Reference

| Flag | Purpose |
|------|---------|
| `-i <etl>` | Input ETL file to analyze |
| `-o <file>` | Output report file |
| `-a <action>` | Analysis action (see below) |
| `-on <providers>` | Start a kernel trace with given providers |
| `-d <etl>` | Stop active trace and flush to ETL file |
| `-stop` | Stop active trace (no ETL save — use to cancel) |
| `-loggers` | List active trace sessions (check for conflicts) |
| `-buffersize <KB>` | Per-CPU buffer size when starting trace |
| `-minbuffers <N>` | Minimum buffer count |
| `-maxbuffers <N>` | Maximum buffer count |
| `-summary` | Modifier to `-a dpcisr` — produces per-CPU table output |

---

## Analysis Actions (-a)

### `-a dpcisr`
DPC and ISR latency histograms per driver. Two output modes:

- **Default** (used with `-o file.txt`): per-module elapsed-time histograms. Primary format for `capture-core.ps1` parsing.
- **With `-summary`** (used by `monitor-xperf.ps1`): produces per-CPU per-driver table. Same histograms follow, but the table comes first.

### `-a cswitch`
Context switch analysis — thread preemption, wait reasons, scheduler interactions. Written to `cswitch_report.txt` by `capture-core.ps1`. Currently stored as a supplementary file; not parsed into structured data by any script yet.

### `-a stackwalk`
Stack trace attribution. Used in conjunction with WPR stacks profile. Not actively parsed in current scripts; available for manual WPA inspection.

---

## DPC/ISR Output Format (default `-a dpcisr`)

Produced when `xperf -i trace.etl -o dpcisr_report.txt -a dpcisr` is run.

### Per-module histogram block
```
Total = 1523 for module nvlddmkm.sys
Elapsed Time, > 0 usecs AND <= 1 usecs, 45, or 2.95%
Elapsed Time, > 1 usecs AND <= 2 usecs, 123, or 8.07%
Elapsed Time, > 2 usecs AND <= 4 usecs, 201, or 13.20%
...
Elapsed Time, > 512 usecs AND <= 1024 usecs, 3, or 0.20%
```

- Header line: `Total = (\d+) for module (\S+)` — regex captures count and module name
- Bucket line: `Elapsed Time.*<=\s+(\d+) usecs,\s+(\d+),` — captures upper-bound usecs and count
- Buckets are not contiguous; only non-zero buckets are printed
- Multiple driver blocks appear sequentially; a new `Total =` line starts the next driver

### Fields extracted by `capture-core.ps1` per driver
| Field | Source | Notes |
|-------|--------|-------|
| `Module` | `Total = N for module X` match group 2 | Driver filename |
| `Count` | `Total = N for module X` match group 1 | Total DPC count |
| `MaxUs` | Highest bucket upper-bound with count > 0 | Worst-case latency class |
| `HighLatCount` | Sum of counts for buckets where upper-bound >= 512 | DPCs over 512us |

---

## dpcisr -summary Output Format

Produced by `xperf -i etl -a dpcisr -summary`. Used by `monitor-xperf.ps1`.

### Section structure
```
DPC Info
CPU Usage from 0 us to 5000000 us:
     CPU 0 Usage,     CPU 1 Usage, ..., Module
     usec      %,     usec      %, ..., Module
   1624   0.05,    27   0.00, ..., nvlddmkm.sys
   ...
Total = 1523 for module nvlddmkm.sys
...
All Module = N, ...
Interrupt Info
```

### Parse state machine (`monitor-xperf.ps1`)
1. `DPC Info` → enter DPC section
2. `CPU Usage from \d+ us to (\d+) us` → capture `traceDurationUs`
3. `CPU \d+ Usage` header line → derive `$cpuCount` dynamically (count regex matches)
4. `^\s+usec\s+%` label line → open `$inDataTable`
5. Digit-leading line inside table → split on `, *`, take `[0..$cpuCount-1]` as "usec %" pairs, `[$cpuCount]` as module name
6. `Total = N for module X` inside table → populate `$dpcCountMap` (do NOT skip with `continue`)
7. `All Module =` → close `$inDataTable`
8. `Interrupt Info` → exit DPC section entirely

**Critical**: `Total = N for module X` lines appear while `$inDataTable` is still true (before `All Module`). The parser must not `continue` early on non-digit lines — it needs to fall through to the dpcCountMap capture.

---

## Common Invocations

### Post-WPR DPC/ISR analysis (capture-core.ps1 pattern)
```powershell
& $xperfPath -i $EtlFile -o $dpcIsrReport -a dpcisr 2>&1 | Out-Null
```

### Post-WPR context switch analysis
```powershell
& $xperfPath -i $EtlFile -o $cswitchReport -a cswitch 2>&1 | Out-Null
```

### Standalone short trace (monitor-xperf.ps1 pattern)
```powershell
# Start
& $xperf -on PROC_THREAD+LOADER+DPC+INTERRUPT -buffersize 1024 -minbuffers 256 -maxbuffers 512 2>&1
Start-Sleep -Seconds $DurationSec
# Stop
& $xperf -d $etlPath 2>&1 | Out-Null
# Analyze
$rawOutput = & $xperf -i $etlPath -a dpcisr -summary 2>&1
```

### Conflict check before standalone trace
```powershell
$sessionCheck = & $xperf -loggers 2>&1
if ($sessionCheck -match 'NT Kernel Logger') { <abort> }
```

### Raw dump to console (parse_xperf_trace.ps1 pattern)
```powershell
$dpcOut = & $xperf -i $traceFile -a dpcisr 2>&1
$dpcOut | ForEach-Object { Write-Output $_ }
```

---

## Parsing Patterns

### Extract all modules with their max-latency bucket
```powershell
$currentModule = ''; $currentTotal = 0; $currentMaxUs = 0; $highLatCount = 0
$dpcDrivers = @()
foreach ($line in (Get-Content $dpcIsrReport)) {
    if ($line -match 'Total = (\d+) for module (\S+)') {
        if ($currentModule -ne '' -and $currentTotal -gt 0) {
            $dpcDrivers += @{ Module=$currentModule; Count=$currentTotal; MaxUs=$currentMaxUs; HighLatCount=$highLatCount }
        }
        $currentModule = $Matches[2]; $currentTotal = [int]$Matches[1]; $currentMaxUs = 0; $highLatCount = 0
    }
    if ($line -match 'Elapsed Time.*<=\s+(\d+) usecs,\s+(\d+),') {
        $bucket = [int]$Matches[1]; $count = [int]$Matches[2]
        if ($count -gt 0 -and $bucket -gt $currentMaxUs) { $currentMaxUs = $bucket }
        if ($bucket -ge 512 -and $count -gt 0) { $highLatCount += $count }
    }
}
# Flush last module
if ($currentModule -ne '' -and $currentTotal -gt 0) {
    $dpcDrivers += @{ Module=$currentModule; Count=$currentTotal; MaxUs=$currentMaxUs; HighLatCount=$highLatCount }
}
```

### Per-CPU table: detect section start
```powershell
$inCpuTable = $false
foreach ($line in $lines) {
    if ($line -match 'CPU Usage from') { $inCpuTable = $true; continue }
    if ($inCpuTable -and $line -match ',\s+\S+$') {
        $parts = $line.Trim() -split ',\s*'
        if ($parts.Count -ge 17) { <extract 16 cpus + module> }
    }
    if ($inCpuTable -and ($line -match '^\s*$' -or $line -match '^Total =')) {
        if ($line -match '^Total =') { $inCpuTable = $false }
    }
}
```

---

## Pitfalls

- **NT Kernel Logger conflict**: Only one kernel trace session can run at a time. If WPR is recording, `xperf -on ...` will fail. Always check `-loggers` before starting a standalone trace. The "Circular Kernel Context Logger" is always running and is benign — ignore it.
- **Stderr mixed into stdout**: xperf writes errors to stdout, not stderr. Check `$LASTEXITCODE` AND scan output for error strings. Pipe with `2>&1` to capture both streams.
- **Admin required for tracing**: `xperf -on ...` and `wpr -stop` require elevation. Analysis of existing ETLs (`-i`) does not strictly require admin but can fail on ACL-restricted ETLs.
- **ETL cleanup**: Standalone traces write temp ETLs to `$env:TEMP`. Always delete them in a `finally` block; uncleaned ETLs accumulate.
- **`-summary` vs default**: `-summary` gives the per-CPU table; default gives histograms. Some scripts use one, some the other. The two output formats are not interchangeable.
- **PS 5.1 string interpolation**: `"${env:ProgramFiles(x86)}\..."` works in double-quoted strings. Do NOT use `$env:ProgramFiles(x86)` without braces — the parentheses confuse the parser.
- **`$Matches` scope**: `$Matches` is populated by `-match` on the same line. In a foreach loop, test one regex per `if` statement; chained conditions on `$Matches` may reference stale captures.

---

## Result Interpretation

| Observation | Diagnosis | Action |
|-------------|-----------|--------|
| `nvlddmkm.sys` MaxUs >= 512, HighLatCount > 0 | NVIDIA driver DPC spikes — severity HIGH | Check MSI interrupts (`exp21`), disable HAGS (`exp20`), lock GPU clocks |
| `nvlddmkm.sys` MaxUs < 128 | Normal NVIDIA DPC latency | No action |
| `EasyAntiCheat*.sys` / `BEService.sys` / `vgk.sys` present | Anti-cheat DPC activity — severity INFO | Baseline expected; flag for EAC investigation branch |
| DPC concentrated on CPU 0 | CPU 0 affinity leaking — should be idle | Re-verify interrupt affinity assignments |
| DPC on CPUs 4-7 for GPU/NIC | Correct — matches expected topology | Confirm affinity working |
| `storport.sys` or `dxgkrnl.sys` with high MaxUs | Storage or DXGK scheduling spike | Correlate with WPA stack trace |
| All drivers MaxUs < 64us | Clean baseline | Record in dashboard `dpcIsrAnalysis` field |

**Topology reminder**: CPU 0 = preferred core (keep idle), CPUs 2-3 = input devices, CPUs 4-7 = GPU/NIC/USB bulk DPC, CPUs 8-15 = game threads.

---

## Integration

| Script | xperf Role |
|--------|-----------|
| `scripts/helpers/capture-core.ps1` | `Stop-WprAndAnalyze`: post-WPR `-a dpcisr` + `-a cswitch`; parses histogram into `dpcIsrData` |
| `scripts/helpers/monitor-xperf.ps1` | `Get-MonitorXperfSnapshot`: standalone trace + `-a dpcisr -summary`; returns per-driver per-CPU usec table |
| `scripts/parse_xperf_trace.ps1` | Raw `-a dpcisr` dump to console for audio diagnostics |
| `scripts/analyze-dpc-deep.ps1` | Reads existing `dpcisr_report.txt`; Stage A parses per-CPU table, Stage B re-parses histogram; `-GpuViewCapture` mode uses `GPUView\log.cmd` |
| `scripts/eac_baseline_capture.ps1` | Standalone trace during Fortnite session; writes `xperf_dpc_summary.csv` |
| `scripts/analyze_eac_dpcs.ps1` | Parses `xperf_dpc_summary.csv` for EAC DPC share metrics |
| `scripts/health-check.ps1` | Checks xperf binary exists; warns if ADK not installed |

Output files written to experiment directories:
- `dpcisr_report.txt` — raw histogram report (primary artifact)
- `cswitch_report.txt` — context switch report (supplementary)
- `dpc_deep_analysis.json` — structured output from `analyze-dpc-deep.ps1`

Dashboard field populated: `dpcIsrAnalysis` (object with `hasReport`, `reportFile`, `dpcDrivers[]`, `dpcAlerts[]`, `cswitchFile`).
