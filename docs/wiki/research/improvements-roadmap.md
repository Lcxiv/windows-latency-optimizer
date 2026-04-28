---
tags: [research, roadmap, planning, features]
date: 2026-04-06
status: complete
aliases: [Improvements Roadmap]
---

## Completed This Session
- [x] Razer Synapse Apply button — fixed (script path routing through run_ps)
- [x] pktmon network capture integrated into pipeline
- [x] Bufferbloat detection (Test-Bufferbloat with BITS saturation)
- [x] Connection quality score (0-100 composite)
- [x] Network Health panel in HTML report
- [x] Bufferbloat audit check (38 total checks now)
- [x] DNS optimization test (router DNS is already fastest)
- [x] Gaming network packet analysis guide (10 sections)
- [x] WCAG 2.1 AA accessibility fixes (14 issues)
- [x] PS 5.1 pitfall: $host is reserved (added to rules)

## Remaining Items

### HIGH PRIORITY — Immediate Value

#### 1. Gaming Capture During Gameplay
- **What:** Run pipeline.ps1 during an actual Fortnite session
- **Why:** ALL captures so far are idle desktop. Real stutter diagnosis needs gameplay data.
- **Effort:** 5 minutes — just run the command while playing
- **Command:** `pipeline.ps1 -Label GAMING_FN -Description "Fortnite gameplay" -DurationSec 30 -WPRProfile InputLatency`
- **Impact:** CRITICAL — validates the entire diagnostic stack under real load

#### 2. Phase 3: Live Monitor in LatencyGuard App
- **What:** Real-time frame time graph + CPU heatmap + DPC panel during gameplay
- **Why:** The most valuable feature for diagnosing live stutter
- **Effort:** HIGH — new Rust perf_stream.rs + frontend streaming
- **Plan:** docs/superpowers/plans/2026-04-02-latencyguard-app.md (Tasks 8-9)

#### 3. ProcMon Duration Column
- **What:** Create scripts/procmon_gaming.pmc via ProcMon GUI with Duration enabled
- **Why:** Without Duration, can't measure which operations take >1ms during gameplay
- **Effort:** 5 min manual GUI step, code already supports /LoadConfig
- **Impact:** Unlocks "which file/registry operations are blocking game threads" analysis

### MEDIUM PRIORITY — Polish

#### 4. Tauri App Rebuild + Deploy
- **What:** Rebuild app to pick up all new pipeline features (bufferbloat, pktmon, network panel)
- **Effort:** Close app + cargo tauri build (30 seconds)

#### 5. tshark Installation for Deep Packet Analysis
- **What:** Install Wireshark to enable tshark for TCP conversation analysis, retransmission counting, DNS timing
- **Why:** pktmon captures packets but can't analyze them deeply without tshark
- **Effort:** Download + install Wireshark
- **Impact:** Unlocks RTT per-connection, packet loss %, retransmission rate from pcapng files

#### 6. Merge PR to Master
- **What:** 37 commits on feat/audit-tool, PR #1 is open
- **Why:** Get changes into master for clean baseline
- **Impact:** Clean git history, enables new feature branches

### LOW PRIORITY — Future

#### 7. System Tray Integration
- Tauri tray icon, background scheduled scans, popup with score

#### 8. Auto-Update
- Tauri built-in updater plugin, code signing needed

#### 9. Installer / MSI Packaging
- Currently portable .exe, MSI for proper Windows integration

#### 10. Shader Compilation Stutter Detection
- Detect via ProcMon: ReadFile on shader cache during stutter window
- Fix: enable shader pre-caching in NVIDIA Control Panel

#### 11. DWM Present Mode Detection
- Track Independent Flip vs Composed mode via PresentMon
- Alert when overlays break Independent Flip

## Technical Debt

### audit-report.ps1 too large (~600 lines)
- All panel builders in one file. Should split.
- Low urgency — works fine.

### Duplicate DPC histogram parsing
- Same logic in pipeline-helpers.ps1 AND analyze-input-latency.ps1
- Risk of divergence.

### No automated tests
- Zero Pester tests for any PS script
- Parse validation catches syntax but not logic

## Learnings

### Network is already optimal
- Router DNS (192.168.4.1) is faster than Cloudflare (1.1.1.1) or Google (8.8.8.8) for this system
- Bufferbloat: 1.3x (none). Connection quality: 100/100.
- 27ms to Fortnite NAW is physics — speed of light to server. No OS tweak can change it.
- The only remaining network improvement would be ISP change or gaming VPN for route optimization.

### PS 5.1 Reserved Variables (6 total now)
$error, $pid, $host, $input, $args, $this — never use as variable names
