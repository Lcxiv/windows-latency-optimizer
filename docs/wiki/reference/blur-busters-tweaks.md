---
tags: [reference, gsync, reflex, nvidia, frame-pacing]
date: 2026-04-10
status: complete
aliases: [Blur Busters, G-Sync]
---

# Blur Busters Gaming Optimization Reference

## Frame Delivery
- Consistent frame times > peak FPS. Capping FPS adds a "glass floor" that makes lag feel consistent
- Frame limiter hierarchy (best to worst latency): in-game/Reflex > NVCP limiter > RTSS > Special K
- RTSS Scanline Sync: tear-free without V-Sync by steering tearline to VBI
- Special K Latent Sync: superior to RTSS Scanline Sync, open source, two-phase limiter

## G-Sync Optimal Config (G-SYNC 101)
1. G-Sync ON in monitor OSD + NVCP
2. V-Sync ON in NVCP (acts as ceiling only, not traditional V-Sync)
3. V-Sync OFF in-game
4. Frame cap: 3-5% below max refresh (141 for 144Hz, 232 for 240Hz, 350 for 360Hz)
5. NVIDIA Reflex ON in all supported games (replaces Low Latency Mode entirely)

## Input Lag Chain
- USB polling -> driver -> OS scheduler -> game engine -> CPU render -> GPU render -> display scanout
- 4000Hz mouse polling = sweet spot (90% of 8000Hz benefit, 75% less CPU overhead)
- Mouse and keyboard on SEPARATE USB controllers (not just different ports)
- Assign each USB controller to separate CPU cores via interrupt affinity

## NVIDIA Control Panel
- G-Sync: Enabled
- V-Sync: ON (in NVCP only)
- Low Latency Mode: Ultra (if game lacks Reflex)
- Power Management: Optimal Performance
- Texture Filtering: High Performance
- Max Frame Rate: 3-5% below monitor Hz
- Reflex: Always ON in supported games

## Windows Settings
- HAGS: ON (confirmed beneficial on 9800X3D)
- Game Mode: ON (prevents updates during gaming)
- Win32PrioritySeparation: 22 (0x16) = short intervals, fixed quantum, 3:1 foreground
- Fullscreen Optimizations: same latency as exclusive fullscreen in modern Win11
- MPO: disable if flickering (OverlayTestMode=5 under HKLM\SOFTWARE\Microsoft\Windows\Dwm)

## Timer Resolution
- 0.5ms via ISLC: marginal benefit over 1ms, but helps frame delivery consistency
- `bcdedit /set disabledynamictick yes`: reduces input latency jitter but conflicts with variable WPS
- HPET: disable in BIOS + Device Manager (TSC is better on modern AMD)

## Latency Benchmarks (Competitive Grade)
- System/PC latency: 3-8ms excellent at 240Hz+
- Click-to-photon: 20-30ms competitive, sub-20ms elite
- Frame time stdev: under 1ms excellent
- DPC latency: consistently under 500us

## Debunked Myths (9800X3D Specific)
- Disabling SMT: no measurable gaming benefit, leave ON
- Disabling HPET via registry: Windows already chooses optimal timer
- Manual OC on X3D: worse than PBO due to clock stretching
- Spread Spectrum disable: zero gaming impact
- Most older registry "latency" guides target Win7/8 behavior, Win11 ignores them
