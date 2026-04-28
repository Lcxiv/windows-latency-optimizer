---
tags: [reference, ram, ddr5, timings, expo]
date: 2026-04-10
status: complete
aliases: [DDR5 Timings, RAM Tuning]
---

# DDR5 RAM Timing Optimization Reference (AM5 / 9800X3D)

## User's RAM: Team Group UD5-6000, 2x16GB, EXPO DDR5-6000 CL30-36-36-76 @ 1.35V

## Timing Hierarchy (Impact Order)
1. **CL (CAS Latency)** — most impactful. CL30 at 6000 = 10.0ns true latency
2. **tRCD / tRP** — second most impactful. Hynix M-die: 36-38, A-die: 34-36
3. **tRFC** — highest-impact secondary. Controls bank refresh lockout time
4. **tREFI** — higher = less frequent refresh = more bandwidth. Temperature-sensitive
5. **tRAS** — less individual impact. Typical: 68-76
6. **tRRD_S/L, tFAW** — affect bank activation parallelism

## Optimal Values at DDR5-6000 (Safe Daily)
| Timing | Stock EXPO | Safe Tuned | Aggressive | Notes |
|--------|-----------|------------|------------|-------|
| CL | 30 | 30 | 28 | Hard to improve on EXPO |
| tRCD | 36 | 36 | 34 | Die-dependent |
| tRP | 36 | 36 | 34 | Die-dependent |
| tRAS | 76 | 76 | 68 | Moderate impact |
| tRC | Auto | 112 (tRAS+tRP) | 104 | Must be >= tRAS+tRP |
| tRFC | Auto (~560) | 480 | 380-420 | BIG impact, test carefully |
| tRFC2 | Auto | 80% of tRFC | 80% of tRFC | |
| tRFCsb | Auto | 60% of tRFC | 60% of tRFC | DDR5 same-bank refresh |
| tREFI | Auto (~32K) | 65535 | 131071 | Needs RAM cooling above 65K |
| tRRD_S | Auto | 8 | 4 | JEDEC min is 8 |
| tRRD_L | Auto | 12 | 8 | |
| tFAW | Auto | 32 | 16-20 | Must be >= 4x tRRD_S |
| tWR | Auto | 48 | 48 | Multiple of 6 |
| tRTP | Auto | 16 | 12 | |
| tCWL | Auto | CL-2 (28) | CL-2 | |
| Power Down | Auto | Disabled | Disabled | 1-2ns latency reduction |

## AIDA64 Latency Targets
- Stock EXPO: 78-85ns
- Basic subtiming tuning: 67-72ns
- Aggressive tuning: 60-65ns
- Best daily-stable: ~57-60ns

## FCLK Sweet Spot
- DDR5-6000 = FCLK 2000MHz = UCLK:MCLK 1:1 = optimal
- Above DDR5-6600: forces 1:2 ratio, adds 10-15ns latency
- Need DDR5-8000+ to overcome 1:2 penalty (impractical)

## tRFC Safe Values by Die Type
- Hynix A-die: start 460, target 360-400
- Hynix M-die: start 500, target 420-480
- Samsung: start 520-560, cautious below 480
- Micron: start 560+, worst tRFC scaling

## V-Cache Masking Effect
The 96MB L3 cache dramatically reduces cache misses reaching RAM.
10% RAM speed improvement yields <2% real gaming gain.
However, tRFC/tREFI optimization still helps frame time consistency
during cache misses (large worlds, texture streaming, level loads).

## Stability Testing
1. TestMem5 anta777 Extreme (3 cycles, ~2 hours)
2. y-cruncher (1 hour, case closed, GPU loaded)
3. OCCT memory (30min SSE + 30min AVX)
4. tRFC too low = silent data corruption risk (most dangerous)
5. tREFI too high + heat = intermittent bit flips

## Tools
- ZenTimings: read all active timings from OS
- AIDA64: bandwidth + latency benchmark
- Thaiphoon Burner: read SPD/EXPO from DIMM
- TestMem5: stability testing
