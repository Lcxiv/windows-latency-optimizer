# Windows Latency Optimizer v2 — Architecture Spec (Revised)

> Draft 2 · 2026-05-16 · Status: post-roast revisions applied. Pending 5-day spike before commit.

---

## Roast outcome summary

Initial draft scored **REVISE** in adversarial review. Three structural issues drove the verdict:

1. **NormalizedEvent granularity collapse** — events (DPC, ISR, packets) and time-series samples (perfcounter, frame_time) flattened into one schema; analyzers read multi-GB JSONL in single-threaded PS 5.1.
2. **yaml-mini.ps1 underestimate** — claimed ~200 LOC; realistic 600-1400 LOC once `when:` clauses and interpolation are required.
3. **Cross-source clock alignment hand-waved** — input-gap analyzer needs sub-ms alignment between WPR (QPC), PresentMon (QPC-rel), procmon (FILETIME), perfcounter (wall-clock), CapFrameX (monotonic). Spec said "clock_anchor.json" but never specified how it's computed/verified.

Plus 7 smaller wounds. See `Revisions applied` below.

---

## Revisions applied (10 non-negotiable changes)

| # | Change | Rationale |
|---|---|---|
| 1 | Add `recordType: 'event'\|'sample'` discriminator to NormalizedEvent | Separates unbounded event streams from fixed-cadence samples. Different storage + iteration patterns. |
| 2 | **Drop YAML. Use `.psd1`** | `Import-PowerShellDataFile -SafeOptions` is native, parser-free, error reporting includes line numbers. Pipeline DSL becomes nested hashtables + arrays. |
| 3 | Structured `fix:` instead of string `fix_command` | `{ verb, target, params }` with allowlisted verbs. Eliminates eval-by-stealth + injection risk. Allowlist matches existing `rollback.ps1` cmdlet allowlist. |
| 4 | Add `Test-AdapterPreconditions` to adapter contract | Runtime preflight detecting EAC/Vanguard/active kernel sessions. Static `cannotParallelWith` declarations are not enough. |
| 5 | `clock_anchor` is computed + verified, not stored | Pipeline runner samples QPC/FILETIME/monotonic at each adapter start, computes drift, emits Finding if drift > 50ms for any cross-source pair. Cross-source analyzers gated on drift result. |
| 6 | Phase 3 acceptance: import-mode parity (deterministic), then live-capture parity loose (±10%) | Old test compared two live captures on the same machine within minutes — workload non-stationary, test structurally flaky. |
| 7 | Drop LatencyMon adapter; treat as a renderer | No headless export, only fixed-width text dump. Same data available from xperf + WPA. One less adapter = one less lie. |
| 8 | Add abandonment-risk mitigation: every phase ships a user-visible artifact | Solo refactor over 10+ weeks needs visible payoff signals to survive. |
| 9 | Replace cross-cutting "v3 side-effect" with single `dashboard-shim` adapter | One adapter projects NormalizedEvents → v3 `experiment.json`. Decouples adapters from dashboard. One place to delete in Phase 6. |
| 10 | Add Phase 5.5 (test migration) — or explicitly accept ~75% Pester coverage loss | 768 existing tests bound to v1 surface. Phase 6 deletion strands them. Honest accounting required. |

---

## Three contracts (revised)

### NormalizedEvent — with recordType discriminator

```ts
interface NormalizedEvent {
  schemaVersion: 1;
  recordType: 'event' | 'sample';   // NEW: discriminates unbounded vs cadenced
  ts: number;                        // int64: ns since Unix epoch (UTC)
  source: string;                    // adapter id
  kind: EventKind;
  cpu?: number;
  pid?: number;
  process?: string;
  driver?: string;
  durationNs?: number;
  device?: string;
  threadId?: number;
  sessionId?: string;
  severity?: 'info'|'low'|'medium'|'high';
  payload?: Record<string, primitive | primitive[]>;  // arrays allowed (stacks, frame_time bursts)
}
```

**Storage**: Sharded by `recordType` and `kind`:

```
captures/experiments/<run-id>/
  events/
    raw/                              # per-adapter raw output (etl, csv, pml)
    streams/
      event/                          # unbounded streams, JSONL per kind
        dpc.jsonl
        isr.jsonl
        context_switch.jsonl
        net_packet.jsonl
        ...
      sample/                         # fixed-cadence time-series, columnar JSONL
        perfcounter.jsonl
        gpu_util.jsonl
        frame_time.jsonl
        ...
  findings.jsonl
  clock_anchor.json                   # computed at capture start, verified
  report/
    summary.html
    findings.json
```

Why sharded: a `dpc-attribution` analyzer reads only `event/dpc.jsonl`, not the full 8 GB run. `frame-pacing` reads only `sample/frame_time.jsonl`.

### Adapter contract — with preflight gate

```powershell
# adapters/<id>/adapter.ps1

function Test-AdapterPreconditions {                    # NEW
    param(
        [Parameter(Mandatory)][string]$RunDir,
        [hashtable]$Options
    )
    # Runtime checks: tool installed, no conflicting sessions, EAC/Vanguard not blocking
    # Returns: [pscustomobject]@{ Ok=$bool; Reasons=@(...); Severity='block'|'warn' }
}

function Start-Adapter { ... }                          # unchanged
function Stop-Adapter { ... }
function Import-Adapter { ... }

function ConvertTo-NormalizedEvents {
    param([Parameter(Mandatory)][string]$RunDir)
    # MUST write sharded JSONL under events/streams/{event|sample}/<kind>.jsonl
    # MUST stream — no in-memory buffering of full output
    # RETURNS: [pscustomobject]@{ EventCount, SampleCount, Success, Warnings, ClockAnchor }
}
```

### Analyzer contract (unchanged shape, gated on clock_anchor for cross-source)

```powershell
function Invoke-Analyzer {
    param(
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][hashtable]$Thresholds,
        [hashtable]$PriorFindings = @{}
    )
    # Reads events/streams/{event|sample}/<kind>.jsonl
    # If manifest declares cross-source dependency, runner verifies clock_anchor drift
    # before invocation; if drift too high, emits a 'low-confidence' Finding tag
    # Writes findings.jsonl
}
```

### Finding — structured fix

```ts
interface Finding {
  schemaVersion: 1;
  id: string;
  analyzer: string;
  ts: number;
  severity: 'info'|'low'|'medium'|'high'|'critical';
  category: FindingCategory;
  what: string;
  evidence: Evidence[];
  affected: { components?, processes?, drivers?, cpus? };

  fix?: {
    verb: FixVerb;                // allowlisted enum, NOT free string
    target?: string;              // driver name, process, device
    params: Record<string, primitive>;
    requiresAdmin: boolean;
    requiresReboot: boolean;
    riskLevel: 'low'|'medium'|'high';
    rollback?: {
      verb: FixVerb;
      target?: string;
      params: Record<string, primitive>;
      verification: string;       // shell command to verify rollback applied
    };
  };
}

type FixVerb =
  | 'set-msi-affinity' | 'unset-msi-affinity'
  | 'set-registry' | 'unset-registry'
  | 'enable-service' | 'disable-service'
  | 'add-defender-exclusion' | 'remove-defender-exclusion'
  | 'set-power-plan'
  | 'set-nic-property'
  | 'apply-experiment' | 'rollback-experiment';
```

Renderer maps `verb` → known cmdlet from `scripts/rollback.ps1` allowlist. No string templating.

### Pipeline DSL — .psd1 not YAML

```powershell
# pipelines/standard.psd1
@{
    schemaVersion = 1
    id            = 'standard'
    displayName   = 'Standard 120s capture'

    run = @{
        durationSec = 120
        outDir      = 'captures/experiments'
        label       = '${LABEL}'
        description = '${DESCRIPTION}'
    }

    captures = @(
        @{ adapter = 'perfcounter'; options = @{ sampleIntervalSec = 1 } }
        @{ adapter = 'wpr';         options = @{ profile = 'GeneralProfile'; detail = 'Verbose' } }
        @{ adapter = 'nvidia-smi';  options = @{ sampleIntervalMs = 500 } }
        @{ adapter = 'registry';    options = @{ snapshotKeys = @('mmcss', 'defender', 'gpu', 'affinity') } }
        @{ adapter = 'presentmon';  enabled = '${env.GAME_PROCESS -ne ""}'
           options = @{ processName = '${env.GAME_PROCESS}' } }
    )

    analyzers = @(
        @{ analyzer = 'registry-drift' }
        @{ analyzer = 'dpc-attribution'
           thresholds = @{ dpcPctThreshold = 5.0; perCpuConcentrationPct = 30.0 } }
        @{ analyzer = 'gpu-saturation' }
        @{ analyzer = 'frame-pacing'; enabled = '${captures.presentmon.enabled}' }
        @{ analyzer = 'polling-storm' }
    )

    report = @{
        formats  = @('html', 'json')
        sections = @('summary', 'findings_table', 'charts', 'rollback_script')
    }

    onAdapterFailure   = 'continue'
    onAnalyzerFailure  = 'continue'
    maxDurationSec     = 300
}
```

Loaded via `Import-PowerShellDataFile -LiteralPath x.psd1`. Interpolation `${...}` is post-processed by a small (~50 LOC) interpolator that walks the hashtable and substitutes env + run-context vars. No expression evaluator beyond simple equality (`-eq`, `-ne`, `-gt`, `-lt`).

---

## Phase plan (revised)

| # | Goal | Duration | User-visible artifact (abandonment-risk hedge) |
|---|---|---|---|
| 0 | Schema + .psd1 validator + sharded JSONL writer | 3-4 days | New `winlatopt validate` CLI; works against existing `pipelines/` |
| 1 | 12 adapters (LatencyMon dropped, dashboard-shim added) | 8 days | Each adapter shipped with `winlatopt run --capture <name> --import <file>` testable from CLI |
| 2 | 10 analyzers | 7 days | Each analyzer runnable standalone: `winlatopt analyze --import <run-dir> --analyze <name>` |
| 3 | Pipeline runner + .psd1 DSL + 7 named pipelines | 5 days | `winlatopt run pipelines/quick.psd1` replaces `baseline_capture.ps1` |
| 4 | CLI entrypoint complete | 3 days | `winlatopt.ps1` becomes the documented top-level entry |
| 5 | Monitor compose UI (file:// compatible) | 5 days | Toggleable picker UI in monitor/, writes .psd1 pipeline files |
| **5.5** | **Test migration: port v1 Pester tests → v2 surface** | **5-7 days (NEW)** | **Coverage maintained; CI gate restored** |
| 6 | Cull 145 → ~30 scripts | 5 days | Repo size drops, contributor onboarding doc shortens |

**Total: ~50 days** (was 45 — added Phase 5.5).

---

## Risk register (updated post-roast)

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| R1 | Schema can't represent all tool outputs | HIGH | Sharded by kind, `payload` allows primitive arrays, opaque keys documented per-adapter |
| R2 | DSL parser blow-up | RESOLVED | Switched to `.psd1` — native parser |
| R3 | Event volume OOM | HIGH | Sharded JSONL by kind, never read full run unless analyzer needs all kinds |
| R4 | Dashboard back-compat | RESOLVED | Single `dashboard-shim` adapter, decoupled |
| R5 | Adapter timeouts / hung processes | MED | `Test-AdapterPreconditions` + hard timeout in pipeline runner |
| R6 | Analyzer dependency cycles | MED | Manifest `requires` declarations; preflight resolver |
| R7 | DSL drift from registered names | MED | Pre-flight name resolution before any capture starts |
| R8 | Plugin pollution (third-party adapter) | MED | All adapters in-repo, no dynamic loading in v2.0 |
| R9 | Monitor compose UI complexity | MED | Default presets shown first, "custom" drawer collapsible |
| R10 | Cross-source clock drift | HIGH | `clock_anchor` computed + verified at capture start; cross-source analyzers gated on drift |
| R11 | PS job marshalling drops typed objects | MED | Adapters communicate via files, not job return values |
| R12 | Undocumented v1 behaviors lost in cull | HIGH | Phase 0 inventory tags every script (keep/wrap/delete) |
| R13 | LatencyMon / HWiNFO64 GUI-only | RESOLVED | LatencyMon dropped; HWiNFO64 stays import-only with explicit UX |
| R14 | EAC blocks ETW during gaming | HIGH | `Test-AdapterPreconditions` detects EAC, emits Finding instead of silent failure |
| R15 | Dashboard file:// constraint | MED | `dashboard-shim` adapter writes JS-globals as before |
| **R16** | **Pester coverage loss in cull** | **HIGH** | **Phase 5.5 added — explicit port budget** |
| **R17** | **Solo abandonment over 10+ weeks** | **HIGH** | **Every phase ships a user-visible artifact (table above). Phase order intentionally surfaces value early.** |
| **R18** | **Anti-cheat detection of v2 capture chain** | **MED** | **`Test-AdapterPreconditions` declares anti-cheat state; pipelines refuse to start incompatible captures** |
| **R19** | **Windows Update changes ETW provider availability** | **MED** | **Adapter manifest declares min OS build; preflight check fails fast** |
| **R20** | **Schema version drift across adapter/analyzer/pipeline manifests** | **MED** | **All three contracts share `schemaVersion: 1` field; runner refuses mixed-version runs in v2.0; bumping requires global migration** |

---

## 5-day spike — go/no-go gate before commit

Replaces the 2-day spike in draft 1. Hard go/no-go decisions at end of each day.

| Day | Goal | Go/no-go criterion |
|---|---|---|
| 1 | Schema + perfcounter adapter — JSONL streaming write | Peak memory <50 MB on 5-min capture. **NO-GO:** redesign storage to columnar/parquet before Phase 1. |
| 2 | `.psd1` pipeline parser + interpolator | Total parser <150 LOC, round-trips all 7 named pipeline shapes. **NO-GO:** fall back to JSON DSL. |
| 3 | WPR adapter live + sharded JSONL by kind | 30s WPR capture → events/streams/event/dpc.jsonl, isr.jsonl, etc. ConvertFrom-Json on dpc.jsonl alone <30s. **NO-GO:** introduce SQLite or msgpack store. |
| 4 | Cross-source clock alignment dry run | perfcounter + WPR + PresentMon simultaneously. `clock_anchor` drift <50ms for all three. **NO-GO:** cut 4 cross-correlation analyzers (input-gap, audio-glitch, eac-fingerprint, network-hitch) from v2 scope. v2 becomes 5-week project. |
| 5 | Stub `dpc-attribution` analyzer over Day 3 events | Findings within 10% of v1 `analyze-dpc-deep.ps1` output on same xperf input. **NO-GO:** payload schema needs xperf-specific keys; expand schema and re-spike. |

**After spike:**

- All 5 GO → commit to 10-week plan with revisions in this spec
- Any 1 NO-GO → redesign affected layer, then re-spike that layer only (2 days)
- ≥2 NO-GOs → reject v2 architecture; consider lighter refactor (just extract analyzers, keep pipeline.ps1 monolithic)

---

## Open questions (still unresolved)

1. **Findings persistence model.** Per-run only, or aggregated across runs for trend dashboard? Recommendation: per-run JSONL + `dashboard/data/findings_history.js` computed by `dashboard-shim`.
2. **JSONL vs SQLite vs msgpack.** Day 3 spike decides. JSONL is default; fallback options sequenced.
3. **Threshold user-overrides.** `~/.winlatopt/profile.psd1` merged at runtime. Document in Phase 4.
4. **Fix application engine.** Keep one script per fix (current pattern) vs. generic `Apply-Fix -Verb x -Params @{...}`. v2.0 keeps scripts; engine in v2.1.
5. **Monitor live streaming.** Today the monitor refreshes every 2s. Should this read sharded JSONL incrementally? Out of scope v2.0.

---

## Concrete next move

Run the 5-day spike. Then redecide.

**Do not** start Phase 1 wrapping before all 5 spike days GO. The spike costs 5 days. The 10-week plan costs ~50 days. Skipping the spike to "save time" is the canonical solo-refactor failure mode.

---

## References

- `docs/case-study.md` — v1 project narrative, what v1 already solves
- `scripts/pipeline.ps1` — current capture orchestrator (will become deprecation shim Phase 3 → deleted Phase 6)
- `scripts/audit-checks/` — current 9 audit modules (will become `registry-drift` analyzer)
- `monitor/views/` — current 8-view UI (will gain `compose.js` Phase 5)
- `tests/*.Tests.ps1` — 768 existing Pester tests (will be ported in Phase 5.5)
