# Evidence Bus — Schema + Paper Proof

**Purpose:** the keystone artifact for LatencyGuard's move toward the "installed sentinel" (B) product.
One typed, append-only timeline that **every instrument** writes to, so analysis becomes a *query over a shared substrate* instead of a human holding correlations in their head.

This doc does two things:
1. Defines the schema (v0).
2. **Proves or breaks it on paper** by retro-fitting the 2026-05-30 freeze and the 2026-05-11 dump into rows — including the two hard cases (cross-month join, no-dump-inferred-from-sibling).

> If the schema can represent both incidents *and* the link between them, it's the substrate. If it can't, we learned that on paper for the cost of an hour instead of after wiring 15 collectors.

---

## 1. The schema (v0)

One row = one observation from one instrument at one instant.

| Field | Type | Notes |
|---|---|---|
| `row_id` | string | stable unique id |
| `ts` | ISO8601 UTC | when the **signal occurred** (not when collected) |
| `collected_ts` | ISO8601 UTC | when the collector wrote it |
| `source` | enum | the **instrument**: `eventlog` · `windbg` · `perfcounter` · `nvidia-smi` · `wpr` · `xperf` · `capframex` · `presentmon` · `wireshark` · `pktmon` · `procmon` · `hwinfo` · `pnputil` · `scewin` · `audit` |
| `subsystem` | enum | `cpu_dpc` · `gpu` · `storage` · `network` · `power` · `memory` · `display` · `input` · `firmware` |
| `signal` | string | typed signal name (controlled vocabulary — see §3) |
| `severity` | enum | `info` · `warn` · `error` · `critical` |
| `value` | object | signal-specific payload |
| `faulting_module` | string \| null | attribution when known (`nvlddmkm`, `stornvme`, …) |
| `cpu` | int \| null | **per-CPU** index where relevant (CPU 0 is the whole game) |
| `confidence` | 0.0–1.0 | 1.0 = observed fact; <1.0 = inferred |
| `evidence_kind` | enum | **`observed`** · **`inferred`** · **`absent`** ← the three states that make forensics work |
| `raw_ref` | path \| null | pointer to the raw artifact (dump, csv, etxl) |
| `incident_id` | string \| null | groups rows into one incident |
| `links` | [row_id] | cross-references — **this is how a 05-30 verdict points at a 05-11 dump** |

**The one non-obvious design decision:** `evidence_kind` has three values, not two.
- `observed` — the instrument saw it. (a dirty-shutdown event, a dump bucket, a P-state sample)
- `absent` — **the absence is itself evidence.** The 6-minute logging silence before the freeze is not "missing data" — it's the single most diagnostic fact in the case. Schemas that can't represent absence force the analyst to notice the gap by eye. This one stores it as a row.
- `inferred` — a derived conclusion the analyzer wrote, with `confidence < 1.0` and `links` to the evidence it leaned on.

---

## 2. Paper proof — retro-fit two real incidents

### Incident A — 2026-05-11 09:15  (the dump exists)
`incident_id: INC-20260511-0915`

```jsonc
{ row_id:"a1", ts:"2026-05-11T16:14:30Z", source:"eventlog", subsystem:"power",
  signal:"dirty_shutdown", severity:"critical", evidence_kind:"observed", confidence:1.0,
  value:{event_id:6008}, faulting_module:null, incident_id:"INC-20260511-0915" }

{ row_id:"a2", ts:"2026-05-11T16:14:42Z", source:"windbg", subsystem:"gpu",
  signal:"dpc_watchdog", severity:"critical", evidence_kind:"observed", confidence:1.0,
  faulting_module:"nvlddmkm", cpu:null,
  value:{ bugcheck:"0x133", bucket:"0x133_DPC_nvlddmkm!unknown_function",
          timeout_type:"SINGLE_DPC_TIMEOUT_EXCEEDED" },
  raw_ref:"captures/dump_0x133_051126_analyze.txt", incident_id:"INC-20260511-0915" }
```

### Incident B — 2026-05-30 10:19  (NO dump — the hard case)
`incident_id: INC-20260530-1019`

```jsonc
// --- observed breadcrumbs, last activity before silence ---
{ row_id:"b1", ts:"2026-05-30T17:13:44Z", source:"eventlog", subsystem:"storage",
  signal:"storport_perf_summary", severity:"info", evidence_kind:"observed", confidence:1.0,
  value:{port:3}, incident_id:"INC-20260530-1019" }

{ row_id:"b2", ts:"2026-05-30T17:14:06Z", source:"eventlog", subsystem:"network",
  signal:"wns_keepalive", severity:"info", evidence_kind:"observed", confidence:1.0,
  value:{}, incident_id:"INC-20260530-1019" }

// --- ABSENCE AS EVIDENCE: the 6-min logging gap ---
{ row_id:"b3", ts:"2026-05-30T17:14:06Z", source:"eventlog", subsystem:"power",
  signal:"log_silence", severity:"critical", evidence_kind:"absent", confidence:1.0,
  value:{ duration_s:349, expected_min_events:20, observed_events:0,
          note:"no event in ANY enabled log — scheduler stop" },
  incident_id:"INC-20260530-1019" }

// --- the dirty stop with the tell-tale KP41 bugcheck=0 ---
{ row_id:"b4", ts:"2026-05-30T17:19:55Z", source:"eventlog", subsystem:"power",
  signal:"dirty_shutdown", severity:"critical", evidence_kind:"observed", confidence:1.0,
  value:{ event_id:6008, kp41_bugcheck:0, power_button_ts:0 },
  incident_id:"INC-20260530-1019" }

{ row_id:"b5", ts:"2026-05-30T19:20:43Z", source:"eventlog", subsystem:"power",
  signal:"manual_reset", severity:"warn", evidence_kind:"observed", confidence:1.0,
  value:{ gap_to_recovery_s:7248 }, incident_id:"INC-20260530-1019" }

// --- negative findings that RULE OUT alternatives (also observed!) ---
{ row_id:"b6", ts:"2026-05-30T17:19:55Z", source:"eventlog", subsystem:"memory",
  signal:"whea_error", severity:"info", evidence_kind:"absent", confidence:1.0,
  value:{ window_days:14, count:0, note:"no hardware fault" },
  incident_id:"INC-20260530-1019" }

// --- THE VERDICT: inferred, links to the 05-11 sibling ---
{ row_id:"b7", ts:"2026-05-30T17:19:55Z", source:"audit", subsystem:"gpu",
  signal:"dpc_watchdog_hang", severity:"critical", evidence_kind:"inferred", confidence:0.7,
  faulting_module:"nvlddmkm",
  value:{ reasoning:"idle-onset + KP41 bugcheck=0 + no dump (scheduler stop past bugcheck path) "+
                    "+ same nvlddmkm watchdog family as INC-20260511-0915",
          attribution:"by-association (no 05-30 dump)" },
  links:["a2"], incident_id:"INC-20260530-1019" }
```

---

## 3. What the proof demonstrates

**Cross-month join works.** Row `b7.links → a2`. The correlator that found "this is the nvlddmkm pattern again" is now a query, not a memory:

```sql
SELECT faulting_module, count(DISTINCT incident_id) AS hits
FROM evidence
WHERE subsystem IN ('gpu','cpu_dpc')
  AND signal = 'dpc_watchdog' OR signal = 'dpc_watchdog_hang'
  AND ts > now() - 90d
GROUP BY faulting_module ORDER BY hits DESC;
-- nvlddmkm | 3   (04-11, 05-11, 05-30)   <-- the months-long pattern, as one query
```

**Absence is first-class.** Rows `b3` (silence) and `b6` (no WHEA) carry `evidence_kind:absent`. The most diagnostic facts in this case were *things that didn't happen*. A two-state schema would have dropped them on the floor.

**Inference is auditable.** Row `b7` is a conclusion, not a fact — `confidence:0.7`, `links:[a2]`, reasoning inline. Anyone (or any model) can re-derive or challenge it. This is the difference between "the tool said GPU" and "here is the chain."

**Verdict: schema holds.** It represents observed facts, absence-as-evidence, and inference-by-linkage across months. Build the bus.

---

## 4. Riskiest-assumption test — is the signal vocabulary small & stable?

The bus only stabilizes if the diagnostic vocabulary is finite. Union of signals across the last ~6 real RCAs in memory:

| Signal | Subsystem | Cracked which case |
|---|---|---|
| `dirty_shutdown` | power | 05-30, 05-11 |
| `dpc_watchdog` / `_hang` | gpu / cpu_dpc | 05-30, 05-11, 04-11 |
| `pstate_sample` | gpu | 05-30 fix verify |
| `cpu0_dpc_pct` (per-CPU!) | cpu_dpc | 04-23, 05-20 |
| `whea_error` | memory/firmware | 05-30 (ruled out), VSOC |
| `driverstore_state` | gpu | 05-30 orphan |
| `storport_perf` / `cache_latency` | storage | 05-30 breadcrumb |
| `hypervisor_state` / `vbs_state` | cpu_dpc | 05-20 |
| `kernel_power_109` | power | 05-20 |
| `ping_rtt` / `jitter` / `bufferbloat` | network | 05-20 |
| `gpu_util` (per-process) | gpu | 04-23 |
| `minifilter_altitude` | storage | EAC |
| `link_drop` / `eee_state` | network | I226-V |
| `bios_setting_change` | firmware | VSOC |
| `frametime_hitch` | gpu | (CapFrameX, ready) |
| `log_silence` | power | 05-30 |

**~16 signal types, ~9 subsystems, heavy overlap on `dpc_watchdog` / `dirty_shutdown` / `pstate` / `cpu0_dpc`.**
Under the ~20 threshold, and the recurring few are the spine of nearly every case → **assumption holds. The vocabulary is small and stable. Safe to build the bus.**

---

## 5. Instrument → signal coverage (the "ensemble" made literal)

The strength you named — many instruments covering every layer — becomes real only when each is a *bus producer*. Map:

| Instrument | Feeds subsystem(s) | Example signals |
|---|---|---|
| Event Log | power, all | dirty_shutdown, log_silence, link_drop |
| WinDbg / cdb | any (post-mortem) | dpc_watchdog, bugcheck bucket |
| perf counters | cpu_dpc (per-CPU) | cpu0_dpc_pct, intr_per_sec |
| WPR / xperf | cpu_dpc, kernel | dpc_isr_attribution |
| CapFrameX / PresentMon | gpu | frametime_hitch, fps_pct |
| nvidia-smi / Nsight | gpu | pstate_sample, clocks, gpu_util |
| Wireshark / pktmon | network | retransmit, rtt, packet_loss |
| ProcMon | storage | file_io_duration, registry_poll |
| HWiNFO | firmware/thermal | rail_voltage, tdie_temp |
| pnputil | gpu | driverstore_state |
| SCEWIN | firmware | bios_setting_change |

Every layer of the machine has a sensor. The bus is the universal adapter that lets them be read **conjointly** — which is the entire point.

---

## 5b. STRESS TEST — the cross-subsystem misdirection (2026-05-20)

The §2 proof used the nvlddmkm family the schema was designed around — weak proof. Real test: a case where the **symptom subsystem ≠ the cause subsystem**. The 05-20 "Fortnite network lag" is exactly that — user/symptom said *network*, root cause was *cpu_dpc* (Hyper-V/VBS interrupt tax). If the bus can represent that misdirection **and** make the "ruled-out network / blamed DPC" reasoning queryable, it generalizes beyond GPU hangs.

`incident_id: INC-20260519-1600`

```jsonc
// --- the SYMPTOM, as the user/operator perceived it (subsystem=network) ---
{ row_id:"c1", ts:"2026-05-20T01:00:00Z", source:"audit", subsystem:"network",
  signal:"user_reported_symptom", severity:"warn", evidence_kind:"observed", confidence:1.0,
  value:{ complaint:"network lag during FNCS", perceived_subsystem:"network" },
  incident_id:"INC-20260519-1600" }

// --- network RULED OUT — negative findings carry the same weight as positive ---
{ row_id:"c2", ts:"2026-05-20T01:00:00Z", source:"perfcounter", subsystem:"network",
  signal:"ping_rtt", severity:"info", evidence_kind:"observed", confidence:1.0,
  value:{ target:"aws-us-east-1", rtt_ms:68, jitter_ms:1, note:"clean" },
  incident_id:"INC-20260519-1600" }
{ row_id:"c3", ts:"2026-05-20T01:00:00Z", source:"eventlog", subsystem:"network",
  signal:"link_drop", severity:"info", evidence_kind:"absent", confidence:1.0,
  value:{ window:"session", count:0, note:"I226-V clean, eero clean" },
  incident_id:"INC-20260519-1600" }

// --- the REAL cause, a DIFFERENT subsystem (cpu_dpc) ---
{ row_id:"c4", ts:"2026-05-20T01:00:00Z", source:"perfcounter", subsystem:"cpu_dpc",
  signal:"cpu0_dpc_pct", severity:"warn", evidence_kind:"observed", confidence:1.0,
  cpu:0, value:{ pct:4.5, baseline_pct:0.5, note:"crept back up post-EXP15" },
  incident_id:"INC-20260519-1600" }
{ row_id:"c5", ts:"2026-05-20T01:00:00Z", source:"audit", subsystem:"cpu_dpc",
  signal:"hypervisor_state", severity:"error", evidence_kind:"observed", confidence:1.0,
  value:{ hypervisorlaunchtype:"Auto", vbs_status:2, mechanism:"every IRQ VM-exits to root partition ~1-3us" },
  incident_id:"INC-20260519-1600" }

// --- the 109 RED HERRING — looked like a crash, was user rage-quit. Link to the disproof. ---
{ row_id:"c6", ts:"2026-05-19T23:06:29Z", source:"eventlog", subsystem:"power",
  signal:"kernel_power_109", severity:"warn", evidence_kind:"observed", confidence:1.0,
  value:{ looks_like:"crash" }, links:["c7"], incident_id:"INC-20260519-1600" }
{ row_id:"c7", ts:"2026-05-19T23:06:29Z", source:"eventlog", subsystem:"power",
  signal:"initiated_shutdown", severity:"info", evidence_kind:"observed", confidence:1.0,
  value:{ event_id:1074, user:"L", process:"StartMenuExperienceHost.exe", reason:"user rage-quit, NOT crash" },
  incident_id:"INC-20260519-1600" }

// --- the VERDICT: symptom subsystem != cause subsystem, recorded explicitly ---
{ row_id:"c8", ts:"2026-05-20T01:00:00Z", source:"audit", subsystem:"cpu_dpc",
  signal:"misdiagnosis_correction", severity:"critical", evidence_kind:"inferred", confidence:0.85,
  value:{ perceived:"network", actual:"cpu_dpc",
          reasoning:"network clean (c2,c3) + CPU0 DPC 9x baseline (c4) + hypervisor Auto (c5) "+
                    "=> interrupt tax felt as lag at sub-frame granularity, not packets" },
  links:["c1","c2","c3","c4","c5"], incident_id:"INC-20260519-1600" }
```

**What this proves the schema can do that a naive one can't:**

1. **Symptom and cause live in different subsystems, both first-class.** `c1` is `network` (what the user felt), `c8` is `cpu_dpc` (what was true). The schema doesn't force the symptom's subsystem onto the cause. A schema keyed only on "the problem area" would have filed this under network forever.
2. **Negative findings are queryable evidence.** `c2`/`c3` (network ruled out) are rows, not footnotes. The misdiagnosis-correction (`c8`) *links to its own disproof*. The chain "why it's NOT network" is reconstructable.
3. **Red-herring disambiguation is structural.** `c6` (109, looks-like-crash) links to `c7` (1074, user-initiated) — the "always cross-reference 109 with 1074" rule from memory becomes a *link in the data*, not tribal knowledge.

**The misdirection query** — "how often did a network-perceived complaint turn out to be cpu_dpc?":
```sql
SELECT a.value.perceived AS felt, a.value.actual AS truth, count(*) AS n
FROM evidence a
WHERE a.signal = 'misdiagnosis_correction'
GROUP BY felt, truth;
-- network | cpu_dpc | 2   (05-20, and 04-23 mouse-stutter = GPU-sat-felt-as-input)
```
**That row is the product.** It's the institutional memory of "the symptom is almost always wrong" turned into a lookup. A new incident reporting "network lag" can be greeted with *"last 2 times this was actually CPU0 DPC — check the hypervisor first."* That's the symptom-translation layer, and it's just a query over this schema.

**Verdict: schema survives the cross-subsystem stress test.** It represents symptom≠cause, negative findings, red-herring disambiguation, and turns the meta-pattern itself into a query. Strong proof, not weak. **Build the bus.**

---

## 5c. STRESS TEST 2 — a non-DPC subsystem (storage / firmware)

Both prior incidents resolved to DPC. Risk: the vocabulary might be DPC-shaped and break on a genuinely different fault class. Test against two non-DPC incidents from memory: the **05-11 storage angle** and the **2026-04-25 VSOC under-volt boot-fail** (firmware/IMC corruption — a fundamentally different subsystem and failure mode).

`incident_id: INC-20260425-VSOC`

```jsonc
// firmware change is the action; the schema must represent a CONFIG MUTATION as evidence
{ row_id:"d1", ts:"2026-04-25T00:00:00Z", source:"scewin", subsystem:"firmware",
  signal:"bios_setting_change", severity:"warn", evidence_kind:"observed", confidence:1.0,
  value:{ setting:"VSOC", from_v:1.24, to_v:1.1, method:"SCEWIN" },
  incident_id:"INC-20260425-VSOC" }

// the consequence — boot corruption, a DIFFERENT subsystem (memory/IMC) than the cause (firmware)
{ row_id:"d2", ts:"2026-04-25T00:05:00Z", source:"eventlog", subsystem:"memory",
  signal:"boot_corruption", severity:"critical", evidence_kind:"observed", confidence:1.0,
  value:{ artifact:"ntoskrnl corruption on next boot", recovery:"CMOS reset required" },
  links:["d1"], incident_id:"INC-20260425-VSOC" }

// the learned safe-floor — an inferred constraint, not a one-time fact
{ row_id:"d3", ts:"2026-04-25T00:10:00Z", source:"audit", subsystem:"firmware",
  signal:"safe_constraint", severity:"info", evidence_kind:"inferred", confidence:0.9,
  value:{ param:"VSOC", safe_floor_v:1.18, note:"NOT the 1.05 JEDEC theoretical for this rig" },
  links:["d1","d2"], incident_id:"INC-20260425-VSOC" }
```

**What this proves:**
- **A new subsystem (`firmware`) and new signals (`bios_setting_change`, `boot_corruption`, `safe_constraint`) drop in additively** — no schema change, just new strings + value blobs. The vocabulary is *extensible*, not DPC-locked.
- **Config-mutation-as-evidence** (`d1`) and **cause-subsystem ≠ consequence-subsystem** (`d1` firmware → `d2` memory) work the same way the network→cpu_dpc case did. The pattern generalizes.
- **A learned constraint** (`d3` safe-floor 1.18V) is an `inferred` row that a future audit can *query before applying a BIOS change* — "has this rig ever failed below this VSOC?" That's institutional memory as a guardrail.

**Verdict: schema holds across DPC, hardware/firmware, and config-mutation classes.** Three distinct fault families, one substrate. The riskiest assumption (vocabulary small, stable, *and general*) survives all three tests.

---

## 6. Build order (why bus-first is non-negotiable)
1. **Evidence bus** (schema above) — the substrate. ~16 signals, append-only store.
2. **Collector as flight recorder** — repoint `monitor_collector.ps1` from "dashboard feed every 2s" to "append typed evidence 24/7" so the next freeze already has a body.
3. **Instrument adapters** — wrap the existing tools as bus producers (start with the ~6 that crack most cases).
4. **Correlator / verdict** — query + LLM reasoning over the timeline. *Cheap once 1–3 exist; impossible before.*
5. **Verdict UI** — the push product: "what killed my PC," with the evidence chain.
6. *(deferred)* remediation-for-others — gated, reversible, expert-only (liability).
