# Hardware Diagnostic Runbook (`run_hwdiag.ps1`)

End-to-end runbook for the hwdiag sweep — built 2026-04-25.

## Prerequisites (one-time)

1. **HWiNFO64 CSV logging** must be active before running, or voltages won't be captured:
   - Launch HWiNFO64 (`C:\Program Files\HWiNFO64\HWiNFO64.EXE`)
   - Choose Sensors-only mode
   - In the Sensors window, right-click the trash icon → **Logging Start** → CSV
   - Default path: `%USERPROFILE%\Documents\HWiNFO64\HWiNFO64.CSV`
   - Leave HWiNFO64 running. The hwdiag script auto-detects and parses the latest active log.
2. **AIDA64** (already installed at `C:\Program Files\FinalWire\AIDA64 Extreme\`) — fallback if HWiNFO64 unavailable.
3. **Admin shell** — `run_hwdiag.ps1` requires elevation.
4. **Plug in / disable battery saver** — forces full HW state.
5. **Close non-essential apps** before run (especially browsers; one Claude Code session OK for orchestration).

## Run

### Preflight + idle audit (no load, no kill, ~3 min)

```powershell
# From admin PowerShell at the project root:
.\scripts\run_hwdiag.ps1 -Label "preflight_only"
```

### Full sweep + 4/24 investigation (snapshot kill test only, ~5 min)

```powershell
.\scripts\run_hwdiag.ps1 -Label "hwdiag_full" -InvestigateSlowState24
```

### Full sweep + execute kill test + Prime95 load (~30 min)

```powershell
.\scripts\run_hwdiag.ps1 -Label "hwdiag_full" -InvestigateSlowState24 -ExecuteKill -RunLoad
```

> ⚠ `-ExecuteKill` will terminate Claude.exe processes whose cumulative CPU > 1 hour (default; tunable via `-KillCpuThresholdSec`). It will NOT kill the current Claude Code session host. Do not use during real work.

> ⚠ `-RunLoad` runs Prime95 SmallFFT for 5 min. CPU will hit 80-95 °C briefly. Make sure cooling is OK.

## Outputs

Run produces:

```
captures\hwdiag\<Label>_<YYYYMMDD_HHMMSS>\
  preflight\
    pcie_state.json
    smart.json
    whea.json
    whea_decoded.csv
    [if -InvestigateSlowState24: kill_before.csv, kill_decision.json]
  audit\
    audit_<ts>.json, audit_<ts>.html  (existing audit.ps1 deep-mode output)
  idle\
    voltages_idle.csv, voltages_idle.summary.json
    gpu_ecc_idle.csv, gpu_ecc_idle.summary.json
    nic_baseline_idle.json, nic_errors_idle.json
  kill_test\  (only if -InvestigateSlowState24 -ExecuteKill)
    kill_before.csv
    kill_after.csv
    percpu_pre_kill.csv
    percpu_post_kill.csv
    kill_decision.json
  loaded\  (only if -RunLoad)
    voltages_load.csv, voltages_load.summary.json
    gpu_ecc_loaded.csv, gpu_ecc_loaded.summary.json
    nic_baseline_loaded.json, nic_errors_loaded.json
  manifest.json
  anomalies.json
  hwdiag_rollup.html  ← auto-opens in browser
```

## Reading the rollup

`hwdiag_rollup.html` shows a verdict banner (PASS / N WARN / N CRITICAL) plus a per-rail table classified green/yellow/red against `docs\reference_hardware_diagnostic_voltages.md`.

If the banner is RED:
1. Open `anomalies.json` for the structured list of red findings.
2. Cross-reference each finding's `source` field with the markdown reference for context.
3. Memory promote: any confirmed anomaly should be written to `~/.claude/projects/.../memory/project_hw_anomalies_<YYYYMMDD>.md`.

## Triaging the 4/24 slow state (Claude.exe leak)

`kill_decision.json` has the verdict:
- `software_leak_CONFIRMED` → cores 6-9 dropped to <10% post-kill, software-side leak. Mitigation: periodic Claude restart or upstream bug report.
- `software_leak_ELIMINATED` → cores 6-9 stayed >25% post-kill, software not the cause. Investigate HW (escalate to Phase 3 voltages + WHEA).
- `inconclusive` → mid-range. Re-run with longer `-PostCaptureSec`.
- `no_candidates` → no Claude.exe procs above threshold. Phenomenon resolved or thresholds need adjusting.

## Common gotchas

- **SMART nulls** without admin → run as Admin. Get-StorageReliabilityCounter requires elevation for full data.
- **Voltages missing** → HWiNFO64 CSV logging not active. See prerequisites.
- **GPU ECC values [N/A]** → consumer Blackwell (RTX 5070 Ti) lacks ECC. Comparator tolerates.
- **NIC link speed string** → `Get-NetAdapter` returns "2.5 Gbps" string; the script also stores numeric `Speed` as `linkSpeedBps`.
- **ACPI thermal zones "Not supported"** on AMD AM5 — common. We rely on HWiNFO64.

## Reference docs

- `docs\reference_hardware_diagnostic_voltages.md` — narrative voltage/temp/clock reference with citations
- `docs\reference_hardware_diagnostic_voltages.json` — comparator-consumed schema
