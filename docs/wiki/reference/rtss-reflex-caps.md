---
tags: [reference, rtss, reflex, frame-limiter, gsync]
date: 2026-04-23
status: complete
aliases: [RTSS, Reflex, Frame Cap]
---

## Cap Hierarchy (best → worst latency, Overwatch LDAT @ 237fps/240Hz baseline)

| Rank | Method | Latency | Frametime flatness |
|------|--------|---------|---------------------|
| 1 | In-game limiter (native) | 16 ms | good |
| 1 | Reflex auto-cap | 16 ms | excellent |
| 3 | NVCP Max Frame Rate | 18 ms (+2) | good |
| 3 | RTSS async | 18 ms (+2) | excellent (flattest) |
| 5 | No cap → V-Sync fallback | 24 ms (+8) | poor |

Rule: in-game cap is 1/2–1 frame ahead of external caps. Reflex collapses that trade-off (in-engine precision + external flatness).

## Canonical Config for 360Hz G-Sync Rig (XG27ACDNG native 360Hz, not overclocked)

**Monitor OSD:** G-Sync/VRR ON, 360Hz
**NVCP global:** V-Sync **On**, Low Latency Mode **Ultra**, Power **Prefer Maximum Performance** (required for RTX 5070 Ti bus-load bug)

### Reflex-Native Game (Fortnite, Warzone, Apex, Valorant, CS2)
- In-game V-Sync: **OFF**
- Reflex: **On + Boost**
- Frame cap: **Unlimited** (Reflex auto-caps ~342 fps, 95% of 360)
- RTSS: OFF for this game

### Non-Reflex DX11/12 Game
- RTSS Limiter type: **NVIDIA Reflex**
- RTSS cap: 342 (or 0 for auto)
- NVCP: Ultra LLM + V-Sync On

### Non-Reflex Vulkan/OGL Fallback
- RTSS Limiter type: Async
- RTSS cap: **346** (4% below 360)
- NVCP: Ultra LLM + V-Sync On

## Cap Math at 360Hz
| % below | FPS | Use |
|---------|-----|-----|
| 3% | 349 | Tightest |
| 4% | **346** | Recommended for bursty titles |
| 5% | 342 | Matches Reflex auto-cap |

## Reflex Mechanism (NvAPI-level)
- `NvAPI_D3D_SetSleepMode` + `NvAPI_D3D_Sleep` called pre-input-sample
- PCL markers: Input Sample → Simulation → Render Submit → Present
- Examines last ~64 frames (`NvAPI_D3D_GetLatency`) to compute sleep
- Eliminates render queue by delaying CPU until GPU can catch up
- **Boost** = prevents GPU downclocking during CPU-bound scenes (Fortnite use case)
- **Reflex REPLACES NVCP Low Latency Mode** when active — LLM setting ignored

## RTSS Limiter Modes (v7.3.7)
| Mode | Mechanism | Latency |
|------|-----------|---------|
| Async (default) | Buffers 1 frame for flatness | +1 frame |
| Front Edge Sync | Aligns Present to VBlank front | +0.5–1 frame |
| Back Edge Sync | Aligns Present to VBlank back | +0.5–1 frame |
| NVIDIA Reflex | Disables own pacing, uses NvAPI Sleep | = native Reflex |
| Scanline Sync | Steers tearline to offscreen scanline | ~0 added |

## Scanline Sync Quick Reference
- Negative value = offset from last scanline (e.g. `-30` = 30 above bottom, panel-independent)
- Starting point: **-30** (try -20 at 360Hz since VBI narrower)
- Requires: game sustaining >110% refresh + GPU <80% util + stable frametimes
- At 1440p: VT ~1500 scanlines total; VBI ~40–60 at 360Hz
- NOT viable for Fortnite (build-mode spikes break steering)

## Special K Latent Sync
- Flip-model-native re-impl of Scanline Sync + Delay Bias
- Delay Bias = postpone render thread into late frame window (e.g. 75% input / 25% frame)
- Achieves latency of 4× uncapped FPS at correct bias
- **BLOCKED by EAC/BattleEye/Ricochet** — offline SP only
- Ctrl+Shift+Backspace for config; right-click framerate slider → Latent Sync

## Anti-Cheat Safety Matrix
| Tool | EAC/BattleEye/Ricochet | VAC |
|------|-----------------------|-----|
| RTSS (all modes) | ✅ MSI-signed, whitelisted | ✅ |
| NVIDIA Reflex | ✅ native in all BR titles | ✅ |
| NVCP Max Frame Rate | ✅ | ✅ |
| Special K / Latent Sync | ❌ blocks multiplayer | ⚠️ per-title |

## DXGI Flip Path Targets
Best → worst:
1. Hardware Composed Independent Flip (with MPO)
2. Independent Flip (DWM sleeps)
3. Direct Flip
4. Composed flip (DWM active)
5. Blt model (legacy — avoid)

Verify via PresentMon `PresentMode` column. Win11 FSO auto-converts borderless to flip model — no need to force exclusive fullscreen.

## Key Sources
- [Blur Busters G-SYNC 101](https://blurbusters.com/gsync/gsync101-input-lag-tests-and-settings/)
- [Blur Busters LDAT Reflex test](https://forums.blurbusters.com/viewtopic.php?t=9151)
- [NVIDIA Reflex Developer Blog](https://developer.nvidia.com/blog/optimizing-system-latency-for-esports-with-nvidia-reflex-sdk/)
- [Microsoft DXGI flip model](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/for-best-performance--use-dxgi-flip-model)
- Full doc: `C:\Users\L\Desktop\windows-latency-optimizer\docs\rtss-reflex-vsync-research.md`
