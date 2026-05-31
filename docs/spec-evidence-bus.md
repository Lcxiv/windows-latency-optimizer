# Spec — Evidence Bus + Flight Recorder

**One-liner:** turn LatencyGuard's pile of independent instruments into one queryable timeline, recorded continuously, so any incident has a body and any correlation is a query.

**Status:** spec for build. Schema proven on paper (`evidence-bus-schema.md`) against 3 real incidents incl. cross-subsystem misdirection. Spike shipped (`helpers/evidence-bus.ps1`).

---

## 1. Problem

Today the 145 scripts / 8 views / 41 checks each emit their own format into their own file. Correlation happens **in a human's head** (or a model's, ad-hoc). Consequences observed this month:
- The 05-30 freeze had a forensic body only by Windows' luck — the collector wasn't recording typed evidence.
- The "this is the nvlddmkm pattern again" insight required a human to remember 04-11 + 05-11 across months.
- The "network lag = actually CPU0 DPC" correction (05-20, and again 04-23) is tribal knowledge, re-derived each time.

Root issue: **no shared substrate.** Analysis can't see across tools that don't speak one language.

## 2. Goal / non-goals

**Goal:** a typed, append-only event store every instrument writes to; a 24/7 recorder feeding it; correlation + verdict as queries/prompts on top.

**Non-goals (this phase):**
- No remediation-for-strangers (liability — read/verdict only until trust earned).
- No new instruments. Wrap the ~6 that already crack most cases.
- No cloud / multi-machine. Local store first.

## 3. Architecture

```
 instruments (producers)            substrate                 consumers
 ┌────────────────────┐
 │ perfcounter        │──┐
 │ eventlog           │  │      ┌──────────────────┐      ┌────────────────┐
 │ windbg (post-mort) │  ├────► │  EVIDENCE BUS     │ ───► │ correlator     │
 │ nvidia-smi         │  │      │  append-only      │      │ (SQL + LLM)    │
 │ wpr / xperf        │  │      │  JSONL today,     │      ├────────────────┤
 │ capframex          │──┘      │  SQLite later     │ ───► │ verdict UI     │
 └────────────────────┘         └──────────────────┘      │ "what killed   │
        ▲                              ▲                   │  my PC" +chain │
        │                              │                   └────────────────┘
 ┌──────┴───────────┐      writes typed rows 24/7
 │ FLIGHT RECORDER  │──────────────────┘
 │ (monitor_collector, repointed)      so a crash always leaves a body
 └──────────────────┘
```

## 4. The schema
Defined + proven in `evidence-bus-schema.md` §1. Row = one observation: `{ts, source, subsystem, signal, severity, value, faulting_module, cpu, confidence, evidence_kind ∈ {observed,inferred,absent}, raw_ref, incident_id, links[]}`. The three-state `evidence_kind` is the load-bearing design choice (absence is evidence).

## 5. Storage
- **Phase 1 (now):** JSONL, one row per line, append-only, file:// friendly. `captures/evidence/evidence_YYYYMMDD.jsonl`. Daily rotation. Honors PS 5.1 + StreamWriter hot-path rule (CLAUDE.md #8).
- **Phase 2:** SQLite for `GROUP BY faulting_module`-style correlation without loading the whole file. Migrate when query volume justifies it.

## 6. Vocabulary (frozen v0)
~16 signals across 9 subsystems — the union proven small & stable across 6 RCAs (`evidence-bus-schema.md` §4). New signals are additive, never schema-breaking (it's just a string + a `value` blob). Spine: `dpc_watchdog`, `dirty_shutdown`, `cpu0_dpc_pct`, `pstate_sample`, `log_silence`.

## 7. Build order (each step independently shippable)
1. **`helpers/evidence-bus.ps1`** — `Write-EvidenceRow` + `Read-EvidenceRows`. ✅ spike shipped.
2. **Flight recorder** — `monitor_collector.ps1` emits typed rows alongside snapshot.js (additive — dashboard unaffected). The `spikes.highDpcCpus`/`dpcPct`/`network.verdict` it already computes become rows.
3. **Post-mortem producer** — wrap the cdb decode (today's `boot_freeze_rca.ps1` + dump decode) to emit `dpc_watchdog` rows on any new dump.
4. **Correlator** — query layer first (the misdirection + recurrence queries from the schema doc), then point a model at the timeline for the inferred verdict rows.
5. **Verdict UI** — a monitor view that reads the JSONL and renders the incident + evidence chain.

## 8. Risks
- **Vocabulary churn** (riskiest). Mitigated: proven ~16 & additive. Re-test if a new incident needs a genuinely new *subsystem*.
- **Recorder overhead** — must be cheaper than the problem it watches. Budget: <0.5% CPU, StreamWriter not Add-Content per row.
- **Cold-start** — cross-time correlation is worthless on a new user's day 1. Accept for the n=1 owner-tool now; revisit when generalizing to others.
- **Liability on write-actions** — out of scope this phase by design.

## 9. Done-when
- Collector appends ≥1 typed row/cycle to dated JSONL, 24/7, parse-clean, <0.5% CPU.
- A new dump auto-emits a `dpc_watchdog` row linked into the timeline.
- The recurrence query (`GROUP BY faulting_module`) reproduces "nvlddmkm × 3" without human memory.
