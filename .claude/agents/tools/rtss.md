# RTSS Tool Subagent

## Role
Specialized subagent for RivaTuner Statistics Server (RTSS) configuration, frame-rate cap selection, and latency analysis within the windows-latency-optimizer project. Called by domain agents (gpu.md, dpc.md) when RTSS limiter mode, scanline sync, or Reflex integration decisions are needed. Provides definitive latency-ranked cap hierarchy guidance, per-game config recommendations, and anti-cheat compatibility rulings without requiring any external lookups — all reference data is embedded here.

---

## Tool Overview
RTSS is a per-process frame-rate limiter and OSD overlay shipped with MSI Afterburner. Its primary latency role is injecting a sleep/stall between Present calls to pace frametimes and prevent render-queue buildup. It is NOT a replacement for Reflex in Reflex-native titles, but it is the correct limiter for DX11/DX12 non-Reflex games targeting G-Sync/VRR. Use RTSS when:
- Game lacks a built-in limiter and has no Reflex support
- In-game limiter produces uneven frametimes
- Scanline Sync is viable (CPU-bound, GPU < 80%, frametime stable)

Do NOT use RTSS when:
- Title has native Reflex support (Reflex self-paces; RTSS adds a frame)
- Vulkan/OpenGL with Scanline Sync needs (use Async instead)
- Anti-cheat blocks overlay injection (see matrix below)

---

## Installation & Location
- **Binary:** `C:\Program Files (x86)\RivaTuner Statistics Server\RTSS.exe`
- **Config dir:** `C:\Program Files (x86)\RivaTuner Statistics Server\Profiles\`
- **Global profile:** `Global` (fallback for unmatched executables)
- **Current version on this rig:** 7.3.7 (MSI-signed, passes all major anti-cheat scanners)
- **Autostart:** Registered as a startup item; runs as tray process
- **RivaTuner64.sys:** Kernel driver loaded at startup for low-level hook injection

---

## CLI Reference
RTSS has no documented CLI for latency-relevant settings; configuration is profile-file based.

Key profile INI fields (edit `Profiles\<game>.exe` directly when scripting):
```ini
FramerateLimit=342          ; target FPS (0 = off)
FramerateLimitMode=0        ; 0=Passive/Async, 1=Front Edge, 2=Back Edge
ScanlineLimit=-30           ; Scanline Sync offset (negative = below last scanline)
UseNvidiaReflex=1           ; 1 = NVIDIA Reflex limiter mode (disables own pacing)
```

Read current global limit via registry:
```powershell
Get-ItemProperty "HKCU:\Software\Unwinder\RTSS" -Name "FramerateLimit"
```

---

## Configuration Reference

### Limiter Modes (v7.3.7)
| Mode | RTSS Name | Added Latency | Notes |
|------|-----------|---------------|-------|
| 0 | Async (default) | +1 frame | Buffers 1 frame ahead; best frametime flatness |
| 1 | Front Edge Sync | +0.5–1 frame | Aligns Present to VBlank front edge |
| 2 | Back Edge Sync | +0.5–1 frame | Aligns Present to VBlank back edge |
| NVIDIA Reflex | NvAPI Sleep | = native Reflex | Delegates pacing to NvAPI; no own queue added |
| Scanline Sync | Tearline steering | ~0 added | Best case; see viability requirements below |

### Key NVCP Settings (interact with RTSS)
- **Low Latency Mode Ultra** — mandatory when using RTSS; prevents driver-side queue from negating RTSS pacing
- **V-Sync On (NVCP)** — required for G-Sync in windowed/borderless; do NOT also enable in-game V-Sync
- **Power Preference: Prefer Max Performance** — prevents GPU downclocking in CPU-bound scenes; required for Reflex Boost effectiveness

---

## Cap Hierarchy — Latency Ranking

Measured with LDAT @ 237fps target, 240Hz display (Overwatch). Lower = better.

| Rank | Method | Click-to-photon latency | Delta vs best |
|------|--------|------------------------|---------------|
| 1 (tie) | In-game limiter (native) | 16ms | baseline |
| 1 (tie) | Reflex auto-cap | 16ms | +0ms |
| 3 (tie) | NVCP Max Frame Rate | 18ms | +2ms |
| 3 (tie) | RTSS Async | 18ms | +2ms |
| 5 | No cap → V-Sync fallback | 24ms | +8ms |

Prefer in-game or Reflex first. RTSS Async and NVCP are equivalent; use RTSS when per-profile control is needed, NVCP when you want one global rule.

---

## Canonical Configs for This Rig (XG27ACDNG, 360Hz, 1440p)

### Monitor OSD (applies to all configs)
- G-Sync/VRR: **ON**
- Refresh rate: **360Hz**

### Config A — Reflex-native game (e.g., Overwatch, Valorant, Fortnite)
```
NVCP global:  V-Sync On, Low Latency Ultra, Power Max Perf
In-game:      V-Sync OFF, Reflex On+Boost, FPS Unlimited (Reflex auto-caps ~342)
RTSS:         DISABLED for this profile
```
Reflex auto-cap targets 5% below refresh = 342fps. No RTSS needed; it would add a frame.

### Config B — Non-Reflex DX11/DX12 game
```
NVCP global:  V-Sync On, Low Latency Ultra, Power Max Perf
In-game:      V-Sync OFF, no in-game limiter
RTSS:         Limiter = NVIDIA Reflex mode, cap = 342fps
```
NVIDIA Reflex mode in RTSS calls NvAPI Sleep identically to native Reflex. Use 342 (5% below 360) to match Reflex auto-cap math.

### Config C — Non-Reflex Vulkan/OpenGL game
```
NVCP global:  V-Sync On, Low Latency Ultra, Power Max Perf
In-game:      V-Sync OFF
RTSS:         Limiter = Async, cap = 346fps (4% below 360)
```
NVIDIA Reflex mode requires DX; use Async for Vulkan/OpenGL. 4% headroom accommodates burst frames without VRR dropout.

### Config D — Scanline Sync (GPU-limited, stable scene)
```
Viability gates: game FPS > 110% of refresh (>396), GPU util < 80%, frametimes < ±2ms
RTSS:         ScanlineLimit = -30 (start point; tune toward -50 if tearline visible)
```
At 1440p the vertical total (VT) is ~1500 scanlines; VBI is ~40–60 scanlines at 360Hz. Setting -30 places the tearline in the blanking interval. NOT viable for Fortnite (build-mode spikes blow past 80% GPU util).

### Cap Math Reference (360Hz)
| Headroom | FPS cap | Use case |
|----------|---------|----------|
| 3% (tightest) | 349 | Very stable titles, no burst |
| 4% (recommended) | 346 | Bursty non-Reflex titles |
| 5% (Reflex match) | 342 | RTSS Reflex mode, matches auto-cap |

---

## Reflex Mechanism (Embedded Reference)
`NvAPI_D3D_SetSleepMode` + `NvAPI_D3D_Sleep` are called by the driver pre-input-sample. Reflex examines the last ~64 frames to predict render time, then delays CPU work start until just before VBlank — eliminating the render queue while keeping GPU fed. **Boost** flag prevents GPU P-state downclocking in CPU-bound scenes where GPU would otherwise idle between presents. RTSS "NVIDIA Reflex" mode replicates this via the same NvAPI path; it is functionally equivalent to native Reflex for non-Reflex games.

---

## Anti-Cheat Compatibility Matrix
| Method | EAC | BattleEye | Ricochet | Notes |
|--------|-----|-----------|----------|-------|
| RTSS (all modes) | ✅ | ✅ | ✅ | MSI kernel driver is signed and whitelisted |
| NVCP frame limiter | ✅ | ✅ | ✅ | Driver-level, always safe |
| Native Reflex | ✅ | ✅ | ✅ | First-party NvAPI |
| Special K Latent Sync | ❌ | ❌ | ❌ | Blocked by all three; single-player only |

Special K Latent Sync combines flip-model Scanline Sync with a Delay Bias for sub-frame precision, but its injection method triggers multiplayer anti-cheat. Use only in offline/single-player titles.

---

## DXGI Flip Path Reference (Best → Worst Latency)
1. HW Composed Independent Flip — GPU composites without DWM copy
2. Independent Flip — DWM steps aside, app owns scanout
3. Direct Flip — DWM-managed but zero-copy
4. Composed Flip — DWM copy involved
5. Blt model — full copy, worst latency; avoid

RTSS OSD shows current flip model via "Flip" indicator. Target Independent Flip or better for minimum latency. Composed Flip often means a fullscreen-exclusive game is running borderless, or MPO is disabled. See MPO reference if stuck on Composed Flip.

---

## Pitfalls
- **RTSS + native Reflex = +1 frame**: Always disable RTSS profile for Reflex-capable titles. The two limiters stack, not replace.
- **Async mode adds a buffer frame**: In render-bound scenarios this can increase latency beyond the +2ms measured in CPU-bound Overwatch testing. Benchmark with LDAT if unsure.
- **Scanline Sync requires FPS headroom**: If the game dips to refresh rate or below, the tearline becomes visible. Always gate on GPU util < 80% AND FPS > 110% of refresh.
- **Profile inheritance**: Profiles that don't explicitly set `FramerateLimit=0` inherit from Global. An accidental global cap will affect all games — check Global profile after any change.
- **Version matters for Reflex mode**: NVIDIA Reflex limiter mode was added in RTSS 7.3.4. Older versions silently fall back to Async. Verify version is 7.3.7+.
- **OSD overhead**: The RTSS overlay itself adds ~0.1–0.3ms CPU overhead per frame for hook processing. Disable OSD in competitive play; limit scanning keeps the limiter active without the display cost.

---

## Result Interpretation
| Observation | Diagnosis |
|-------------|-----------|
| Frametimes flat, 1-2ms variance | RTSS Async working correctly |
| Frametimes spike every ~N frames | Cap too close to refresh; increase headroom |
| Tearline visible with Scanline Sync | Offset too shallow or FPS dropped below gate |
| LDAT latency 2ms above in-game cap | RTSS Async adding expected +1 frame; switch to Reflex mode |
| LDAT latency same as in-game cap | RTSS Reflex mode working; no overhead |
| GPU util > 80% with Scanline Sync | GPU no longer CPU-bound; switch to Async |

Baseline latency target for this rig at 342fps/360Hz: ≤16ms click-to-photon with Reflex, ≤18ms with RTSS Async.

---

## Integration — Project Scripts
No current scripts in `scripts/` invoke RTSS directly (RTSS has no CLI). Related touchpoints:

- `scripts/startup_guard.ps1` — verifies RTSS autostart entry is present; RTSS must be running before game launch for limiter to apply
- `scripts/pipeline.ps1` — captures GPU utilization via `nvidia-smi`; util reading is used to gate Scanline Sync viability decisions
- `captures/experiments/` — frame timing data from PresentMon (via FrameView) shows flip model and frametimes, which are the primary RTSS effectiveness signals
- Dashboard `data/experiments.js` field `frameTiming.p95FrameMs` — key metric for evaluating whether RTSS cap is producing flat frametimes

When a parent agent (gpu.md, dpc.md) requests RTSS config recommendations, this subagent returns a named config (A/B/C/D above) plus the specific INI values to set, requiring no further lookup.
