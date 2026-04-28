---
tags: [research, architecture, tauri, powershell]
date: 2026-04-05
status: complete
aliases: [LatencyGuard Architecture]
---

## Project Structure

Three layers, each independently useful:

### Layer 1: PowerShell Core Engine (scripts/)
- `audit.ps1` — Entry point: 37 checks, -Mode Quick/Deep, -Threshold, -Quiet, -GenerateFix
- `audit-checks.ps1` — All check functions (Invoke-OsChecks, Invoke-NicChecks, etc.)
- `audit-report.ps1` — HTML report generator with panel builder architecture
- `pipeline.ps1` — Orchestrator: WPR + ProcMon + PresentMon + perf counters + Defender recording
- `pipeline-helpers.ps1` — Parse-FrameCSV, Stop-WprAndAnalyze, Find-ForegroundGame, ProcMon capture
- `analyze-input-latency.ps1` — ETL parser: DWM frame extraction, DPC-stutter correlation
- `input-latency.wprp` — Custom WPR profile (8 ETW providers)
- `exp*.ps1` — Experiment apply scripts with backup/rollback

### Layer 2: HTML Reports (generated)
- Self-contained HTML with inline CSS+JS, file:// compatible
- 3-tab structure: Overview (hero P95 + 4 panels + checklist), Advanced, Compare
- Adaptive: audit-only = checklist mode, pipeline data = full diagnostics

### Layer 3: LatencyGuard Tauri App (latencyguard/)
- Rust backend (`src-tauri/src/`) spawns PS scripts via IPC
- Vanilla JS frontend (`src/`) — Simple Mode + Expert Mode
- Commands: run_audit, apply_fix, get_pipeline_data, get_experiments, get_history

## Data Flow

```
User clicks Scan → Rust invoke('run_audit') → powershell audit.ps1
  → audit-checks.ps1 (37 checks) → audit-report.ps1 (HTML)
  → audit_*.json written to captures/audits/
  → Rust reads JSON, sends to frontend
  → Frontend renders score + categorized settings
```

## Key Patterns
- Every PS script validated with [Parser]::ParseFile() before commit
- Check results are [ordered]@{} hashtables with 11 fields (name, category, tier, severity, status, current, expected, message, source, fix, fixNote)
- Experiment apply scripts follow: backup → apply → verify → rollback commands pattern
- HTML report uses string concatenation in PS (not here-strings) for PS 5.1 compat
