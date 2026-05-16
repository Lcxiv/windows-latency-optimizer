# EAC + Fortnite Mitigation Runbook

> Plan: `PLAN-eac-fortnite-mitigation-v3` ([C:\Users\L\.claude\plans\PLAN-eac-fortnite-mitigation-v3.md](C:\Users\L\.claude\plans\PLAN-eac-fortnite-mitigation-v3.md))
> Constraint: EAC stays loaded. Mitigation only.
> Status: Phases 1, 2, 1', 0, 3, 4a, 5 implemented + tested. Phase 6 + optionals deferred.

## Phase Order (v3)

```
P1  measure (pre-exclusion)
 └─ P2  Defender exclusions
     └─ P1' measure (post-exclusion)
         └─ P0  hypothesis gate (verdict)
             └─ P3  background quiet
                 └─ P4a Fortnite process affinity
                     └─ P5  storage path empirical
                         └─ P6  anti-spike tuning      [NOT IMPLEMENTED]
                             └─ P7  docs + orchestrator
                                 └─ [optional] P4b EAC service affinity (smurf-gated)
                                     └─ [optional] P5b storage IRQ override (WinRE-gated)
```

## Quickstart — Drive via Orchestrator

```powershell
cd C:\Users\L\Desktop\windows-latency-optimizer

# See current state + next phase
.\scripts\eac_orchestrator.ps1 -DryRun

# Run next phase (interactive confirmation)
.\scripts\eac_orchestrator.ps1

# Or run a specific phase
.\scripts\eac_orchestrator.ps1 -Phase 1 -CaptureDuration 300
.\scripts\eac_orchestrator.ps1 -Phase 5 -StorageDriverLabel stornvme-inbox
```

State persists in `captures\backups\orchestrator\orchestrator_state.json`.

## Phase 1 — Capture Pre-Exclusion Baseline

**Pre-flight:** close non-essential apps. Fortnite session ready (Solo or Squad BR for reproducibility).

```powershell
.\scripts\eac_baseline_capture.ps1 -Tag pre-exclusion -DurationSec 300
```

Tab to Fortnite + play immediately. Script auto-stops after 300s.

**Output:** `captures\experiments\exp-eac-baseline-fortnite-pre-exclusion_<ts>\`
- `xperf_trace.etl`, `wpr_trace.etl`, `xperf_dpc_summary.csv`, `percpu_counters.csv`, `fltmc_*.txt`, `run_meta.json`

### Analyze

```powershell
.\scripts\analyze_eac_dpcs.ps1 -CaptureDir "captures\experiments\exp-eac-baseline-fortnite-pre-exclusion_<ts>"
```

## Phase 2 — Defender Exclusion Hygiene

```powershell
# Dry run
.\scripts\eac_phase2_defender_apply.ps1 -WhatIf

# Real apply
.\scripts\eac_phase2_defender_apply.ps1
```

Adds:
- Process exclusions: FortniteClient-Win64-Shipping.exe, EasyAntiCheat_EOS.exe, Epic launcher binaries
- Path exclusions: Fortnite + EAC install dirs, %LOCALAPPDATA% caches
- Extension exclusions: .pak, .utoc, .ucas, .sig

Verify:
```powershell
Get-MpPreference | Select-Object Exclusion*
```

Rollback (auto-runs Defender QuickScan after):
```powershell
.\scripts\eac_phase2_defender_rollback.ps1 -ManifestFile "captures\backups\defender\apply_manifest_<ts>.json"
```

## Phase 1' — Re-Capture Post-Exclusion

```powershell
.\scripts\eac_baseline_capture.ps1 -Tag post-exclusion -DurationSec 300
.\scripts\analyze_eac_dpcs.ps1 -CaptureDir "captures\experiments\exp-eac-baseline-fortnite-post-exclusion_<ts>"
```

## Phase 0 — Hypothesis Gate

Analyzer applies verdict logic on the **post-exclusion** capture:

| Condition | Verdict | Exit | Action |
|-----------|---------|------|--------|
| `eacDpcPct >= 0.50` AND `eacDpcTotalMs >= 100` | PROCEED | 0 | Continue plan |
| `eacDpcPct >= 0.30` OR `eacDpcTotalMs >= 50` | PROCEED_LOW_CONFIDENCE | 2 | Continue cautiously |
| Otherwise | HALT_INVESTIGATE_ALTERNATE | 3 | Branch to network/GPU/driver |

Compare pre vs post:
- Pre EAC% high, post EAC% low → Defender double-scan was issue. Already partly fixed.
- Pre + post both EAC dominant → continue plan, more wins ahead.
- Post collapsed but other DPCs rose → other minifilter / network. Branch.

## Phase 3 — Background Disk Quiet

```powershell
.\scripts\eac_phase3_gamemode_quiet_apply.ps1 -WhatIf
.\scripts\eac_phase3_gamemode_quiet_apply.ps1
```

Pauses:
- OneDrive (process stop, exe path saved)
- Steam updates (writes `BootStrapperInhibitAll=enable` to Steam.cfg, prior content backed up)
- Backblaze service (if installed)

Warns (no auto-close):
- Browsers running

Rollback:
```powershell
.\scripts\eac_phase3_gamemode_quiet_rollback.ps1 -StateFile "captures\backups\gamemode\quiet_state_<ts>.json"
```

## Phase 4a — Fortnite Process Affinity (zero ban risk)

Launch wrapper pins Fortnite client to CPUs 8-15 (mask `0xFF00`):

```powershell
.\scripts\eac_phase4a_launch_fortnite_pinned.ps1
```

Standard Windows `ProcessorAffinity` mutation — NOT registry, NOT kernel driver. Process attribute only.

Override mask if needed:
```powershell
.\scripts\eac_phase4a_launch_fortnite_pinned.ps1 -AffinityMask 0xFFFE  # all CPUs except 0
```

## Phase 5 — Storage Path Bench (empirical)

Run with current driver, then with alternate after swap. Compare.

```powershell
.\scripts\eac_phase5_storage_path_bench.ps1 -DriverLabel stornvme-inbox -DurationSec 60
# (optionally swap to vendor driver via Device Manager + DDU)
.\scripts\eac_phase5_storage_path_bench.ps1 -DriverLabel samsung-vendor -DurationSec 60
```

Output per run: `captures\experiments\exp-storage-bench-<label>_<ts>\bench_summary.json`

Compare `\PhysicalDisk(_Total)\Avg. Disk sec/Read` Avg + Max + StdDev. Pick lower latency + lower variance.

## Phase 6 — Anti-Spike Tuning (NOT YET IMPLEMENTED)

Per plan v3:
- Timer resolution lock 0.5ms (per-game-launch)
- C-state disable per-game-launch with `powercfg /restoredefaultschemes` rollback
- MSI mode verify on NIC/GPU/storage
- Driver bench
- DX12 + GPU hardware-accelerated GPU scheduling toggle

Scripts to write next.

## Phase 7 — Docs + Orchestrator

Already shipped:
- This runbook
- `eac_orchestrator.ps1` — phase driver
- `tests\test_eac_scripts.ps1` — smoke test runner (35 cases passing)

## Optional Phases (NOT auto-run)

### Phase 4b — EAC Service Affinity (HIGH ban risk)

NOT scripted yet. Per plan v3, gated behind:
- Smurf account
- 24h burn-in
- Manual TOS review

### Phase 5b — Storage IRQ Override (brick-boot risk)

NOT scripted yet. Per plan v3, gated behind:
- WinRE recovery USB pre-staged
- System restore point created
- Registry full backup

## Tests

```powershell
.\tests\test_eac_scripts.ps1
```

35 cases: AST parse, help blocks, ShouldProcess, rollback parameter contract, manifest persistence, PS 5.1 pitfalls, -WhatIf advertisement.

## Quick Reference — Files

| Path | Purpose |
|------|---------|
| [C:\Users\L\.claude\plans\PLAN-eac-fortnite-mitigation-v3.md](C:\Users\L\.claude\plans\PLAN-eac-fortnite-mitigation-v3.md) | Approved plan v3 |
| [C:\Users\L\Desktop\windows-latency-optimizer\scripts\eac_orchestrator.ps1](C:\Users\L\Desktop\windows-latency-optimizer\scripts\eac_orchestrator.ps1) | Phase driver |
| [C:\Users\L\Desktop\windows-latency-optimizer\scripts\eac_baseline_capture.ps1](C:\Users\L\Desktop\windows-latency-optimizer\scripts\eac_baseline_capture.ps1) | Phase 1 capture |
| [C:\Users\L\Desktop\windows-latency-optimizer\scripts\analyze_eac_dpcs.ps1](C:\Users\L\Desktop\windows-latency-optimizer\scripts\analyze_eac_dpcs.ps1) | Phase 1 analyzer + Phase 0 verdict |
| [C:\Users\L\Desktop\windows-latency-optimizer\scripts\eac_phase2_defender_apply.ps1](C:\Users\L\Desktop\windows-latency-optimizer\scripts\eac_phase2_defender_apply.ps1) | Phase 2 apply |
| [C:\Users\L\Desktop\windows-latency-optimizer\scripts\eac_phase2_defender_rollback.ps1](C:\Users\L\Desktop\windows-latency-optimizer\scripts\eac_phase2_defender_rollback.ps1) | Phase 2 rollback |
| [C:\Users\L\Desktop\windows-latency-optimizer\scripts\eac_phase3_gamemode_quiet_apply.ps1](C:\Users\L\Desktop\windows-latency-optimizer\scripts\eac_phase3_gamemode_quiet_apply.ps1) | Phase 3 apply |
| [C:\Users\L\Desktop\windows-latency-optimizer\scripts\eac_phase3_gamemode_quiet_rollback.ps1](C:\Users\L\Desktop\windows-latency-optimizer\scripts\eac_phase3_gamemode_quiet_rollback.ps1) | Phase 3 rollback |
| [C:\Users\L\Desktop\windows-latency-optimizer\scripts\eac_phase4a_launch_fortnite_pinned.ps1](C:\Users\L\Desktop\windows-latency-optimizer\scripts\eac_phase4a_launch_fortnite_pinned.ps1) | Phase 4a Fortnite launcher |
| [C:\Users\L\Desktop\windows-latency-optimizer\scripts\eac_phase5_storage_path_bench.ps1](C:\Users\L\Desktop\windows-latency-optimizer\scripts\eac_phase5_storage_path_bench.ps1) | Phase 5 storage bench |
| [C:\Users\L\Desktop\windows-latency-optimizer\tests\test_eac_scripts.ps1](C:\Users\L\Desktop\windows-latency-optimizer\tests\test_eac_scripts.ps1) | Smoke tests |
| [C:\Users\L\Desktop\windows-latency-optimizer\docs\eac-dpc-investigation.md](C:\Users\L\Desktop\windows-latency-optimizer\docs\eac-dpc-investigation.md) | Original investigation notes |
