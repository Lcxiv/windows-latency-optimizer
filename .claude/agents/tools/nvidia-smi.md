# nvidia-smi Tool Subagent

## Role
Tool subagent providing deep nvidia-smi expertise for parent domain agents (`gpu.md`, `system.md`). Answers questions about structured GPU queries, clock lock commands, streaming poll setup, output parsing, and threshold classification for this rig. Does not run scripts directly — advises on correct invocation and interprets output values.

---

## Tool Overview
nvidia-smi (NVIDIA System Management Interface) is the primary programmatic interface to the NVIDIA GPU driver. In this project it serves two distinct roles:

1. **Structured telemetry** — streamed at 1 Hz via `--query-gpu` + `-lms` into `hw_gpu_ecc.ps1` for ECC error detection, P-state monitoring, and thermal/power checks.
2. **Clock lock commands** — `-lgc`/`-lmc` used in `vram-clock-lock.bat` and `exp21_msi_gpu_clocks.ps1` to pin GPU and VRAM clocks, preventing nvlddmkm.sys DPC spikes caused by P-state transitions.

---

## Installation & Location
- **Binary:** `C:\Windows\System32\nvidia-smi.exe`
- Ships with the NVIDIA display driver; no separate install
- Verify: `nvidia-smi --version` — returns driver version and NVML library version
- RTX 5070 Ti is fully supported; all query fields below are available except where noted `[N/A]`

---

## Query Reference (--query-gpu)

Fields are passed as a comma-separated list to `--query-gpu`. Output is `[N/A]` for unsupported fields — always handle this in parsing.

### Clocks
| Field | Unit | Notes |
|---|---|---|
| `clocks.current.graphics` | MHz | Current shader/core clock |
| `clocks.current.memory` | MHz | Current VRAM clock; floor check: <810 MHz = P-state drop |
| `clocks.current.sm` | MHz | Streaming multiprocessor clock (matches graphics on RTX 5070 Ti) |
| `clocks.current.video` | MHz | Video decode engine clock |
| `clocks.max.graphics` | MHz | Boost cap at current power limit |
| `clocks.max.memory` | MHz | RTX 5070 Ti: 10501 MHz (GDDR7) |

### Temperatures
| Field | Unit | Notes |
|---|---|---|
| `temperature.gpu` | °C | GPU edge/die temp; warn >88 °C, throttle onset |
| `temperature.memory` | °C | GDDR7 junction temp; warn >95 °C |

### Power
| Field | Unit | Notes |
|---|---|---|
| `power.draw` | W | Instantaneous package power |
| `power.limit` | W | Current enforced TDP limit |
| `power.default_limit` | W | Factory default TDP |
| `power.max_limit` | W | Maximum settable TDP |

Power clamp flag: `power.draw / power.limit > 0.98` for >5% of samples = power-limited.

### P-state & PCIe
| Field | Notes |
|---|---|
| `pstate` | `P0`=max performance, `P2`=mid, `P8`=idle VRAM. P-state transitions drive DPC spikes |
| `pcie.link.gen.current` | Expected: `5` (PCIe Gen 5 x16 on this rig) |
| `pcie.link.width.current` | Expected: `16`; `8` or lower = slot or driver issue |

### Utilization
| Field | Unit | Notes |
|---|---|---|
| `utilization.gpu` | % | 3D engine; not useful alone — check per-engine via DeviceManager |
| `utilization.memory` | % | VRAM bandwidth utilization |

### ECC Errors (GDDR7 / RTX 5070 Ti)
| Field | Notes |
|---|---|
| `ecc.errors.corrected.volatile.total` | Since last driver load; single-bit, auto-corrected |
| `ecc.errors.uncorrected.volatile.total` | Since last driver load; multi-bit — **critical flag** |
| `ecc.errors.corrected.aggregate.total` | Lifetime; stored in driver |
| `ecc.errors.uncorrected.aggregate.total` | Lifetime uncorrected — any nonzero = investigate VRAM |

**Note:** Consumer RTX cards have ECC in "SRAM ECC" mode (SMs only). GDDR7 VRAM ECC behavior differs from data-center cards. `[N/A]` is possible if ECC is disabled in driver settings.

### Other Useful Fields
| Field | Notes |
|---|---|
| `timestamp` | ISO datetime of the sample |
| `name` | GPU model string |
| `driver_version` | Active driver version |
| `vbios_version` | VBIOS string |
| `memory.used` | VRAM used (MB) |
| `memory.total` | Total VRAM (MB) |
| `memory.free` | Free VRAM (MB) |
| `fan.speed` | % fan speed (RTX 5070 Ti: returns value when fan spinning, else `[N/A]`) |

---

## Clock Lock Commands

### Lock Graphics Clock
```batch
nvidia-smi -lgc <min_mhz>,<max_mhz>
```
Sets a range; driver stays within it. To pin a single value use `<mhz>,<mhz>`.

### Lock Memory Clock
```batch
nvidia-smi -lmc <min_mhz>,<max_mhz>
```
RTX 5070 Ti GDDR7 max: `10501`. Lock command from `vram-clock-lock.bat`:
```batch
nvidia-smi -lgc 0,2625
nvidia-smi -lmc 0,10501
```
Setting min=0 allows the driver to clock down under low load while preventing upward P-state transitions past the max.

### Reset Locks
```batch
nvidia-smi -rgc   # reset graphics clock lock
nvidia-smi -rmc   # reset memory clock lock
```
Always run both resets before re-locking to a new value. Driver state persists until reset or reboot.

### Verify Lock Applied
```batch
nvidia-smi --query-gpu=clocks.current.graphics,clocks.current.memory,pstate --format=csv,noheader,nounits
```
After `-lmc 0,10501`, memory clock should read 10501. After reboot the lock is lost — reapply via startup task.

---

## Streaming Mode (-lms)

```powershell
nvidia-smi --query-gpu=<fields> --format=csv,noheader,nounits -lms <milliseconds>
```

- `-lms 1000` = 1 Hz polling (used in `hw_gpu_ecc.ps1`)
- Output: one CSV line per interval, streamed to stdout until process is killed
- `noheader` suppresses column names; `nounits` strips unit strings from values
- In PowerShell, redirect stdout via `ProcessStartInfo` with `RedirectStandardOutput=$true`; read with `StandardOutput.ReadLine()` in a loop
- `[N/A]` appears when a field is unsupported for the GPU or when ECC is disabled

**PS 5.1 streaming pattern** (from `hw_gpu_ecc.ps1`):
```powershell
$pinfo = New-Object System.Diagnostics.ProcessStartInfo
$pinfo.FileName = 'C:\Windows\System32\nvidia-smi.exe'
$pinfo.Arguments = '--query-gpu=' + $query + ' --format=csv,noheader,nounits -lms 1000'
$pinfo.RedirectStandardOutput = $true
$pinfo.UseShellExecute = $false
$p = [System.Diagnostics.Process]::Start($pinfo)
while (-not $p.StandardOutput.EndOfStream) {
    $line = $p.StandardOutput.ReadLine()
    # parse $line.Split(',')
}
```

---

## Common Invocations

```powershell
# Single one-shot query (all key fields)
nvidia-smi --query-gpu=timestamp,pstate,clocks.current.graphics,clocks.current.memory,temperature.gpu,temperature.memory,power.draw,power.limit,utilization.gpu,utilization.memory,pcie.link.gen.current,pcie.link.width.current --format=csv,noheader,nounits

# Check ECC error counts
nvidia-smi --query-gpu=ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total,ecc.errors.corrected.aggregate.total,ecc.errors.uncorrected.aggregate.total --format=csv,noheader,nounits

# GPU identity and driver version
nvidia-smi --query-gpu=name,driver_version,vbios_version,memory.total --format=csv,noheader

# Live streaming at 1 Hz (Ctrl+C to stop)
nvidia-smi --query-gpu=timestamp,pstate,clocks.current.memory,temperature.gpu,power.draw --format=csv,noheader,nounits -lms 1000

# Lock VRAM to max (eliminate P-state DPC spikes)
nvidia-smi -lgc 0,2625 && nvidia-smi -lmc 0,10501

# Reset all clock locks
nvidia-smi -rgc && nvidia-smi -rmc

# PCIe link state (used by hw_pcie_state.ps1)
nvidia-smi --query-gpu=pcie.link.gen.current,pcie.link.width.current --format=csv,noheader,nounits
```

---

## Threshold Reference (RTX 5070 Ti)

| Metric | Floor / Warn | Critical | Action |
|---|---|---|---|
| VRAM clock | <810 MHz = P-state floor | — | Apply `-lmc 0,10501` lock |
| GPU edge temp | >88 °C | >93 °C | Check case airflow, GPU power limit, MPO/DWM overhead |
| GPU memory temp | >95 °C | >100 °C | Check GDDR7 cooling; reduce power limit |
| Power draw / limit | >98% for >5% of samples | sustained 100% | Power-limited; reduce clocks or accept |
| PCIe link gen | <5 = degraded | <4 = investigate | Check slot, BIOS PCIe setting, GPU seating |
| PCIe link width | <16 = degraded | <8 = investigate | Check physical slot; may indicate bifurcation issue |
| ECC uncorrected volatile | Any nonzero | — | Reseat card; stress test VRAM; RMA if recurring |
| ECC uncorrected aggregate | Any nonzero | — | Document; track across reboots; escalate if growing |
| P-state during game | P2 or higher = unexpected | — | Apply clock lock; check power plan |

---

## Pitfalls

1. **`[N/A]` in output** — Always split on comma and check each field for `[N/A]` before parsing as a number. ECC fields return `[N/A]` if ECC reporting is disabled in the driver (NVCP → Manage 3D settings → no direct ECC toggle on consumer cards; may require `nvidia-smi -e 0/1` on Quadro-class, not available on RTX consumer).
2. **Clock lock lost on reboot** — `-lgc`/`-lmc` are volatile; they reset on driver restart or reboot. `startup_guard.ps1` and `exp21_msi_gpu_clocks.ps1` must reapply on every boot via scheduled task.
3. **`-lms` blocks PowerShell** — Streaming mode blocks the calling thread. Always launch via `ProcessStartInfo` with `RedirectStandardOutput`; never call `nvidia-smi -lms` inline in a script without async handling.
4. **Memory clock at 810 MHz = P8 transition** — VRAM downclocks to 810 MHz when GPU drops to P8 (deep idle). During a game session this transition generates nvlddmkm.sys DPC spikes. The symptom is a burst of DPC latency spikes correlated with GPU utilization dips. Fix: apply `-lmc` lock.
5. **`utilization.gpu` misleads** — This field reports 3D engine utilization, not overall GPU busyness. A game using compute or video decode will show low `utilization.gpu` while the GPU is actually busy. Use CapFrameX + HWiNFO shared memory for per-engine breakdown.
6. **Concurrent nvidia-smi instances** — Running multiple `nvidia-smi -lms` processes simultaneously is harmless (NVML handles concurrency) but wastes CPU. `hw_gpu_ecc.ps1` tracks its child PID and kills it on script exit.

---

## Result Interpretation

**P-state `P0`:** Max performance mode. Expected during gaming.
**P-state `P2`:** Mid clock. Observed briefly during scene transitions. Persistent P2 during active gameplay with clock lock applied = lock not effective (verify with clock query).
**P-state `P8`:** Deep idle. VRAM clock drops to ~810 MHz. Should not occur during active gaming.

**ECC corrected volatile > 0:** Single-bit errors auto-corrected by driver. Expected occasionally on consumer GDDR7 under heat/voltage stress. Log and watch trend.
**ECC uncorrected volatile > 0:** Multi-bit errors that could not be corrected. Indicates possible VRAM instability. Reseat GPU, check power delivery, run VRAM stress test (OCCT VRAM).

**Power draw at 98%+ of limit for extended periods:** GPU is power-limited. Frame rate may be capped by TDP, not compute. Raising the power limit in NVCP (if available) or accepting the cap is the correct response — not overclocking.

---

## Integration

| Consumer | How it uses nvidia-smi |
|---|---|
| `hw_gpu_ecc.ps1` | Streams telemetry at 1 Hz; writes `gpu_ecc.summary.json` with ECC counts, P-state histogram, thermal/power flags |
| `vram-clock-lock.bat` | Applies `-lgc`/`-lmc` at session start to prevent DPC spikes |
| `exp21_msi_gpu_clocks.ps1` | Clock lock for latency experiment; records before/after DPC rates |
| `hw_pcie_state.ps1` | Queries `pcie.link.gen.current` / `pcie.link.width.current` for PCIe negotiation check |
| `gpu-vendor.ps1` | Queries `name` to detect NVIDIA vs AMD for branching script logic |
| `diagnose-burst-pattern.ps1` | Spot-checks GPU pstate + clocks during a DPC burst window |
| `diagnose_chrome_render.ps1` | Checks GPU utilization during Chrome rendering to isolate Defender vs GPU saturation |
| `startup_guard.ps1` | Boot-time check: verifies clock lock applied and PCIe link at Gen 5 x16 |
| `health-check.ps1` | GPU component of health score: temp, pstate, ECC, PCIe flags aggregated into score |
| `gpu.md` agent | Primary consumer; delegates all nvidia-smi queries and interpretation here |
| `system.md` agent | Delegates GPU health questions to `gpu.md`, which delegates here |
