# v2 Architecture — 5-Day Spike Plan

> 2026-05-16 · Gate before committing 10-week v2 build. Each day has a hard go/no-go criterion.

---

## Purpose

Validate the three structural assumptions in `docs/v2-spec.md` before committing 10 weeks of refactor:

1. Sharded JSONL streaming holds peak memory <50 MB on a 5-min capture
2. `.psd1` pipeline DSL parses + interpolates without growing past 150 LOC
3. Multi-source clock alignment is within 50 ms across WPR/PresentMon/perfcounter
4. Stub analyzer reproduces v1 findings within 10% on same input
5. NormalizedEvent schema captures real xperf payloads without lossy coercion

Outcome of spike = go/no-go on Phase 1+ of the 10-week plan.

---

## Day 1 — Schema + perfcounter adapter + JSONL streaming

### Build

1. Create `spike/core/normalized-event.psd1` declaring schema (hashtable, not JSON Schema yet)
2. Create `spike/core/event-writer.ps1` — `Write-NormalizedEvent` cmdlet appends JSONL line by line
3. Create `spike/adapters/perfcounter/adapter.ps1`:
   - `Start-Adapter` → starts `Get-Counter -Continuous` background job, writes raw CSV
   - `Stop-Adapter` → stops job
   - `ConvertTo-NormalizedEvents` → reads CSV, emits `recordType: sample`, `kind: perfcounter_sample` JSONL
4. Test: capture 5 min of `\Processor(*)\% DPC Time` + `\System\Context Switches/sec`
5. Measure: peak working set of `Stop-Adapter + ConvertTo-NormalizedEvents` via `Get-Process`

### Go/no-go

- **GO** if peak WS <50 MB and output JSONL parses cleanly via `Get-Content | ForEach-Object { ConvertFrom-Json $_ }`
- **NO-GO** if memory blows or PS dies on a 300-sample CSV
- **Action on NO-GO**: redesign storage to columnar (parquet via Apache.Arrow nuget) or msgpack; cost +3 days to Phase 0

---

## Day 2 — `.psd1` pipeline DSL parser + interpolator

### Build

1. Create `spike/core/pipeline-loader.ps1`:
   - `Import-Pipeline -Path x.psd1` → `Import-PowerShellDataFile -LiteralPath x.psd1`
   - Validate against schema (required keys: schemaVersion, id, run, captures, analyzers)
   - Apply interpolation: walk hashtable, replace `${VAR}` → `$env:VAR` or run-context lookup
   - Support conditional clauses: `enabled = '${captures.presentmon.enabled}'` → boolean
2. Write 7 fixture pipelines: `quick.psd1`, `standard.psd1`, `deep.psd1`, `audit-only.psd1`, `gaming.psd1`, `network-only.psd1`, `dpc-deep.psd1`
3. Round-trip test: load + serialize back to .psd1, diff against original

### Go/no-go

- **GO** if parser <150 LOC, all 7 fixtures load cleanly, interpolation handles env + run-context vars
- **NO-GO** if interpolation requires real expression eval (operators, function calls)
- **Action on NO-GO**: pin DSL to pure data (no `${...}` interpolation); CLI fills vars before load. Phase 0 unchanged.

---

## Day 3 — WPR adapter + sharded JSONL by kind

### Build

1. Create `spike/adapters/wpr/adapter.ps1`:
   - `Start-Adapter` → `wpr -start GeneralProfile -filemode`
   - `Stop-Adapter` → `wpr -stop <runid>.etl`
   - `ConvertTo-NormalizedEvents` → invokes `xperf -i <etl> -a dpcisr -o report.csv`, parses, emits sharded JSONL:
     - `events/streams/event/dpc.jsonl`
     - `events/streams/event/isr.jsonl`
     - `events/streams/event/context_switch.jsonl`
2. Test: 30s WPR capture during typical idle, count events per kind
3. Measure: time to ConvertFrom-Json all of `dpc.jsonl` alone
4. Verify: sharding works — `frame-pacing` analyzer reading only `sample/frame_time.jsonl` doesn't touch dpc.jsonl

### Go/no-go

- **GO** if `dpc.jsonl` parses in <30 seconds total (including ConvertFrom-Json)
- **NO-GO** if parse time exceeds 60 s for a 30-s WPR capture
- **Action on NO-GO**: introduce SQLite via `sqlite3.exe` shell or `System.Data.SQLite.dll` bundle. Phase 0 grows by 2 days; storage layer becomes SQLite-first JSONL-export-secondary.

---

## Day 4 — Cross-source clock alignment dry run

### Build

1. Create `spike/core/clock-anchor.ps1`:
   - At adapter start, sample QPC (`[System.Diagnostics.Stopwatch]::GetTimestamp()`) + FILETIME + monotonic
   - Each adapter writes its anchor to `events/clock_anchor_<adapter>.json`
   - Pipeline runner computes pairwise drift after all adapters started
2. Capture simultaneously: perfcounter + WPR + PresentMon (need a live game process for PresentMon — use FortniteClient or any DX12 app)
3. Measure: drift between three sources' first events
4. Verify: input-gap analyzer can correlate HID event (from procmon or WPR) with DPC event within ±1ms

### Go/no-go

- **GO** if all three sources align within 50 ms drift after `clock_anchor` correction
- **NO-GO** if drift exceeds 50 ms or sources can't be aligned at all
- **Action on NO-GO**: cut 4 cross-correlation analyzers from v2 scope (input-gap, audio-glitch, eac-fingerprint, network-hitch). v2 becomes 5-week project, focused on single-source analyzers.

---

## Day 5 — Stub `dpc-attribution` analyzer

### Build

1. Create `spike/analyzers/dpc-attribution/analyzer.ps1`:
   - Reads `events/streams/event/dpc.jsonl` from Day 3
   - Computes per-driver DPC time sum, per-CPU concentration %
   - Emits `Finding` for any driver >5% DPC time or CPU >30% concentration
2. Compare Findings against v1 output from existing `scripts/analyze-dpc-deep.ps1` on same xperf input
3. Diff: top-3 drivers should match, percentages within 10%

### Go/no-go

- **GO** if v1 and v2 findings agree on top-3 drivers + percentages within 10%
- **NO-GO** if v2 misses a driver v1 identifies, or percentages diverge >20%
- **Action on NO-GO**: schema needs xperf-specific payload keys (function symbol, module path, IRQL). Expand schema, re-spike Day 5 only (1 day).

---

## After spike

### Decision matrix

| GO count | Action |
|---|---|
| 5/5 | Commit to 10-week plan in `docs/v2-spec.md` as written. Start Phase 0 next week. |
| 4/5 | Identify which day failed. Apply the corresponding `Action on NO-GO`. Re-spike that day only (1-3 days). |
| 3/5 | At least one structural assumption is wrong. Revise spec, re-spike full 5 days. |
| ≤2/5 | v2 architecture is wrong shape. Reject v2 plan. Consider lighter alternatives: |
| | (a) extract analyzers only, keep monolithic pipeline.ps1 |
| | (b) sharded captures w/o normalization (each tool stays bespoke) |
| | (c) accept v1 as the right shape for a solo project |

### Cost of running the spike

- 5 days focused work
- 0 commits to master (spike directory `spike/` gitignored; can be moved to `feat/v2-spike` branch)
- Output: `docs/v2-spike-report.md` documenting GO/NO-GO per day with measurements

### Cost of skipping the spike

- Phase 1 starts on assumptions that may be wrong
- Typical refactor failure mode: discover bad assumption at Phase 3-4 (~weeks 4-5), redesign, lose 2-3 weeks
- Solo project + abandonment risk = very likely the refactor stalls at this point

---

## Implementation note

Spike code lives at `spike/` (gitignored by default; will create `feat/v2-spike` branch). Nothing in spike touches v1 production code paths. v1 stays fully operational throughout.

When spike completes, the report doc + decision are committed to master. Spike code itself is deleted or promoted to `core/` in Phase 0 if proven.
