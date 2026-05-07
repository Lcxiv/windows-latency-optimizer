# pktmon Tool Subagent

## Role

Tool subagent providing deep Packet Monitor (pktmon) expertise to the parent
network domain agent (`net.md`). Answers questions about pktmon CLI usage,
filter syntax, ETL capture flow, pcapng conversion, tshark integration, and
network-level evidence interpretation for this project's Intel I226-V / Windows
11 Build 26200 system.

---

## Tool Overview

pktmon is Windows 11's built-in kernel-mode packet monitor. It captures at
multiple network stack levels (NIC lower, NIC upper, protocol, WFP filter) with
less than 0.3% CPU overhead — no Wireshark install required. ETL output
integrates with the WPR/xperf timeline for correlating packet drops and bursts
against DPC spikes.

**Binary path:** `C:\Windows\System32\pktmon.exe` — present on Windows 10 2004+.
No installation; no driver install; no admin for `list`/`counters`, but admin
required for `start`/`stop`.

---

## Installation & Location

```powershell
# Verify availability at runtime
$pktmon = Get-Command pktmon.exe -ErrorAction SilentlyContinue
if ($null -eq $pktmon) { Write-Warning 'pktmon not found (requires Windows 10 2004+)' }
```

Always resolve via `Get-Command` rather than hardcoding — pktmon is in System32
but the PATH entry may be missing in some environments.

---

## CLI Reference

| Command | Purpose | Admin? |
|---------|---------|--------|
| `pktmon list` | List all network components (NICs, filters, protocols) | No |
| `pktmon start` | Begin packet capture | Yes |
| `pktmon stop` | End capture and flush ETL | Yes |
| `pktmon counters` | Show per-component packet/byte/drop counters | No |
| `pktmon filter add` | Add a pre-capture packet filter | Yes |
| `pktmon filter remove` | Remove all filters | Yes |
| `pktmon filter list` | Show active filters | No |
| `pktmon etl2pcap` | Convert ETL to pcapng for Wireshark/tshark | No |
| `pktmon reset` | Reset all counters and state | Yes |
| `pktmon status` | Show whether a capture session is active | No |

### `pktmon start` key flags

| Flag | Meaning |
|------|---------|
| `-c` / `--capture` | Packet logging mode (default is counter-only) |
| `--comp nics` | Component filter: NIC layer only (skips upper protocol stacks) |
| `--comp all` | Capture at every network stack level |
| `--pkt-size 128` | Truncate each packet to first 128 bytes (saves disk; headers only) |
| `--file-name <path>` | ETL output path (default: `%LOCALAPPDATA%\pktmon.etl`) |
| `--log-mode circular` | Overwrite oldest data (ring buffer, for long-running captures) |
| `--log-mode multi-file` | Roll to new ETL files periodically |

---

## Filter Syntax

Filters must be added before `pktmon start`. They are AND-combined per rule,
OR-combined across rules.

```powershell
# Filter by destination port (e.g. game server UDP traffic)
pktmon filter add -p 27015 --transport udp

# Filter by IP address
pktmon filter add --ip-address 203.0.113.5

# Filter by MAC address (useful for isolating I226-V traffic when multiple NICs present)
pktmon filter add --mac-address AA-BB-CC-DD-EE-FF

# Remove all filters (reset to capture-everything mode)
pktmon filter remove
```

For I226-V investigation: filter by IP to the game server or by the NIC's MAC
to exclude loopback / virtual adapters from the capture.

---

## Capture Flow

```powershell
# 1. Stop any stale session (idempotent — safe if nothing running)
try { pktmon stop 2>&1 | Out-Null } catch {}

# 2. (Optional) Add filters BEFORE starting
pktmon filter add -p 27015 --transport udp

# 3. Start capture — NICs only, 128-byte truncation, explicit path
$etlFile = Join-Path $OutDir 'pktmon_capture.etl'
$result = pktmon start -c --comp nics --pkt-size 128 --file-name $etlFile 2>&1
if ($LASTEXITCODE -ne 0) { Write-Warning ('pktmon start failed: ' + $result) }

# 4. Let the issue reproduce (or wait DurationSec)
Start-Sleep -Seconds $DurationSec

# 5. Stop and flush
pktmon stop 2>&1 | Out-Null

# 6. Convert to pcapng for tshark/Wireshark
$pcapFile = [System.IO.Path]::ChangeExtension($etlFile, '.pcapng')
pktmon etl2pcap $etlFile --out $pcapFile 2>&1 | Out-Null
```

This is the exact pattern used by `Start-PktMonCapture` and
`Stop-PktMonCapture` in `scripts/helpers/capture-tools.ps1`.

---

## Output Formats (ETL -> pcapng)

**ETL** — binary Windows event trace log. Can be:
- Opened in WPA (Timeline view) alongside a WPR ETL for temporal correlation
- Converted to pcapng with `pktmon etl2pcap`

**pcapng** — portable capture format. Supports:
- Wireshark GUI analysis
- tshark CLI analysis (see below)
- Frame timestamps align with WPR/xperf timeline when both captures run concurrently

Conversion notes:
- `pktmon etl2pcap` uses `--out` flag (not `-o`) for the output path
- `analyze_dropout.ps1` uses `[System.IO.Path]::ChangeExtension($EtlPath, '.pcapng')` as the pcapng path convention
- Conversion does not require admin

---

## tshark Integration

tshark is OPTIONAL. Scripts fall back to pktmon counters-only analysis when
tshark is not in PATH.

```powershell
$tshark = Get-Command tshark.exe -ErrorAction SilentlyContinue

# TCP conversation statistics
if ($tshark) { & $tshark.Source -r $pcapFile -q -z conv,tcp }

# Count TCP retransmissions
& $tshark.Source -r $pcapFile -Y 'tcp.analysis.retransmission' -T fields -e frame.number

# Slow DNS queries (>100ms)
& $tshark.Source -r $pcapFile -Y 'dns.time > 0.1' -T fields -e dns.qry.name -e dns.time

# Packet timing burst detection (inter-arrival gaps)
& $tshark.Source -r $pcapFile -T fields -e frame.time_relative -e frame.len
```

---

## Common Invocations

```powershell
# ── Quick counter snapshot (no capture session needed) ───────────────────────
pktmon counters
# Parse "Packets: N" from output to detect drop counts

# ── List NIC components (identify I226-V adapter index) ─────────────────────
pktmon list
# Look for "Intel(R) Ethernet Controller I226-V" line; note component ID

# ── 30s NIC burst capture for dropout investigation ──────────────────────────
pktmon stop 2>&1 | Out-Null
pktmon start --capture --pkt-size 128 --comp nics
Start-Sleep 30
pktmon stop
pktmon etl2pcap pktmon.etl -o burst_capture.pcapng

# ── ExitLag WFP filter diagnostics (fix_exitlag_filter.ps1 context) ──────────
# Discovery: pktmon counters showed NIC Lower Rx 907 -> Upper Rx 1,375 (+52%)
# with nt_ndextlag dropping 466 packets in 30s — indicative of WFP filter leak
pktmon counters   # compare Lower Rx vs Upper Rx per component

# ── Pipeline integration (via capture-tools.ps1) ─────────────────────────────
# Called automatically by pipeline.ps1 unless -SkipPktMon is passed
# Output: $OutDir\pktmon_capture.etl (and .pcapng after Stop-PktMonCapture)
```

---

## Pitfalls

1. **Session already active** — `pktmon start` fails if a session is running.
   Always `pktmon stop` first (wrapped in try/catch; harmless if nothing active).
2. **Admin required for start/stop** — scripts calling pktmon must include
   `#Requires -RunAsAdministrator` or elevate explicitly.
3. **`--out` vs `-o`** — `etl2pcap` uses `--out`, not `-o`. Using `-o` causes
   silent failure; check `Test-Path $pcapFile` after conversion.
4. **Default ETL location** — if `--file-name` is omitted, ETL goes to
   `%LOCALAPPDATA%\pktmon.etl`; the pipeline always passes an explicit path.
5. **Filters persist across sessions** — `pktmon filter remove` must be called
   explicitly when switching capture profiles; stale filters silently drop traffic.
6. **`--comp nics` misses WFP drops** — to catch ExitLag/nt_ndextlag drop
   events, use `--comp all` (higher overhead but sees all stack levels).
7. **ETL size grows fast without truncation** — always pass `--pkt-size 128`
   for header-only captures; full-packet 30s captures can exceed 1 GB on a
   2.5GbE link at line rate.
8. **PS 5.1 string concat** — `'pktmon failed: ' + $result` not
   `"pktmon failed: $result"` when `$result` may be a multi-line object.

---

## Result Interpretation

| Observation | Diagnosis | Action |
|-------------|-----------|--------|
| Lower Rx >> Upper Rx in `pktmon counters` | WFP filter dropping packets (e.g. ExitLag nt_ndextlag) | Run `fix_exitlag_filter.ps1` |
| Retransmissions > 0 with no NIC link drops | Upstream packet loss (eero / ISP) | Correlate with Event ID 27 in `analyze_dropout.ps1` |
| DNS time > 100ms on queries | DNS latency spike | Check ExitLag DNS redirect config |
| Packet gaps > 16ms at 60fps | Frame-paced NIC delivery (ITR coalescing) | Tune ITR via `exp12_nic_framepacing_apply.ps1` |
| No pcapng file after `etl2pcap` | Conversion failed silently | Check `$LASTEXITCODE`; re-run with `2>&1` to surface error |
| WFP component shows high drop count | VPN / anti-cheat WFP filter active | Identify driver name in `pktmon list`; check with `fix_exitlag_filter.ps1` |

**I226-V specifics:** look for the Intel I226-V adapter in `pktmon list` output.
Its Lower/Upper Rx delta exposes driver-level vs filter-level drop attribution.
EEE is already disabled on this rig (confirmed); link-drop events are eero-side.

---

## Integration

| Script | pktmon Role |
|--------|------------|
| `scripts/helpers/capture-tools.ps1` | `Start-PktMonCapture` / `Stop-PktMonCapture` / `Analyze-PktMonCapture` — primary capture lifecycle |
| `scripts/pipeline.ps1` | Runs pktmon in parallel with WPR; skipped with `-SkipPktMon` |
| `scripts/network_capture.ps1` | Dedicated network-only capture session |
| `scripts/diagnose-burst-pattern.ps1` | Prints pktmon guidance when NIC burst score > 0.3 |
| `scripts/fix_exitlag_filter.ps1` | Uses pktmon counters to confirm WFP drop source |
| `scripts/analyze_dropout.ps1` | Converts ETL to pcapng; uses tshark for retransmission / gap analysis; falls back to counters-only if tshark absent |
