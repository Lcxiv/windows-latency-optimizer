# Network Dropout Diagnostic Research Report

*Generated: 2026-05-07 | Sources: 20+ | Confidence: High*

## Executive Summary

Investigation into multiple-times-daily network drops affecting all devices (wired and Wi-Fi) on an eero 7 mesh + Frontier fiber 2.5G setup. Three root cause candidates identified, ranked by likelihood:

1. **Intel I226-V EEE hardware bug** (HIGH — confirmed design flaw, affects your exact NIC)
2. **eero 7 firmware instability** (MEDIUM — firmware 7.0.x has known drop patterns matching yours)
3. **Frontier fiber WAN-side drops** (LOW — cannot isolate until #1 and #2 are ruled out)

**Immediate action**: Disable EEE on the I226-V (30-second fix, often resolves the issue entirely).

---

## 1. Intel I226-V — Confirmed EEE Hardware Bug

### The Problem

The I226-V has a confirmed design flaw in its Energy Efficient Ethernet (EEE) implementation. EEE activates even under load, causing the PHY to enter/exit low-power states at inappropriate times. This produces micro-interruptions that manifest as 1-5 second connection drops at random intervals.

Hardware revision history:
- **B0/B1 stepping** — most problematic (Z690/B660 boards)
- **B2 stepping** — shipped on Z790/B760 Raptor Lake boards, still affected
- **B3 stepping** — supposedly improved, but reports of continued issues

### Diagnostic Signatures

**Event Viewer** (`Windows Logs > System`, source `e2fnexpress`):
- **Event ID 27**: `"Network link is disconnected"` — the drop itself
- **Event ID 32**: `"Network link has been established at 1 Gbps full duplex"` — link renegotiates
- Pattern: Event 27 followed by Event 32 within 2-10 seconds = classic EEE drop
- If Event 32 shows 1 Gbps when expecting 2.5 Gbps → link renegotiated downward

**Wireshark**: Complete silence on capture (0 packets) because the NIC itself is down. Capture may show "interface went down" or just stops. After link restores: burst of ARP requests + DHCP DISCOVER.

### Fix (Priority Order)

1. **Disable EEE** — Device Manager > Network Adapters > I226-V > Properties > Advanced > "Energy Efficient Ethernet" > Disabled *(Intel's official stopgap)*
2. **Disable power management** — Same Properties > Power Management tab > Uncheck "Allow the computer to turn off this device to save power"
3. **Update NVM firmware** — Target NVM 2.22+. Intel didn't release publicly; must get from motherboard OEM. Community-sourced versions 2.29/2.32 at station-drivers.com
4. **Update driver** — Target 2.1.3.15+ for Win11. Get from Intel's Complete Driver Pack, not Windows Update
5. **Force 1 Gbps** — Last resort: Advanced > "Speed & Duplex" > "1.0 Gbps Full Duplex"

### PowerShell Diagnostics

```powershell
# Check current NIC state
Get-NetAdapter | Where-Object { $_.InterfaceDescription -like '*I226*' } |
    Format-List Name, InterfaceDescription, DriverVersion, LinkSpeed, Status

# Check EEE setting
Get-NetAdapterAdvancedProperty -Name "Ethernet" -DisplayName "Energy Efficient Ethernet"

# Check power management
Get-NetAdapterPowerManagement -Name "Ethernet"

# Recent link drops in event log
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='e2fnexpress'} -MaxEvents 50 |
    Format-Table TimeCreated, Id, Message -Wrap
```

---

## 2. eero 7 Firmware Issues

### Firmware 7.0.x Stability Regression

- Intermittent wireless disconnections with 20-120ms latency spikes (normal: 6-7ms)
- Red lights on all units during disconnect events
- Gateway overheating reported even at 21°C ambient

### Firmware 6.6.0-1080 Wired+Wireless Drops

- Both wired AND wireless connections drop simultaneously for 5-45 seconds
- Direct connection to modem (bypassing eero) eliminates drops entirely
- 0% packet loss to eero gateway, but 0.3% loss beyond it — indicating eero's WAN-side forwarding is the failure point

### Recurring Patterns

- Drops often follow firmware auto-updates (no user control over timing)
- Power cycling resolves for 30-45 minutes, then returns
- Extended shutdown (30+ min) + sequential restart (gateway first, 15-20 min between nodes) sometimes provides longer stability

### eero Diagnostic Limitations

**eero exposes**: device status, signal strength, device list, bandwidth, firmware version, speed test.

**eero does NOT expose**: channel selection, CPU/memory utilization, STP state, DHCP lease table, ARP table, packet capture, system logs, WAN-side error counters, per-port link status.

**Best diagnostic path**: Call eero support and ask them to pull device logs during an active dropout.

---

## 3. Packet Capture Strategy

### Recommended: pktmon (Windows 11 Built-in)

**Why pktmon over Wireshark:**
- Zero install, anti-cheat safe, lower overhead
- Unique **drop detection with reasons** — captures packets the OS drops and tells you *why*
- Native circular mode for multi-hour captures
- Already installed on your Win11 Build 26200

### Capture Architecture: Ping-Triggered Stop

**Strategy**: Always-on circular pktmon capture + ping-triggered stop/save.

```
[pktmon running in ring buffer mode, constantly overwriting]
    ↓
[Ping monitor detects 2+ consecutive failures]
    ↓
[Stop pktmon → save the last N minutes of capture]
    ↓
[Restart pktmon for next event]
```

This ensures you always have the ~5 minutes *before* a dropout, which is the critical window.

### pktmon Commands

```powershell
# Start circular capture (100MB ring, overwrite)
pktmon start --capture --file-name C:\captures\net_dropout.etl --file-size 100 --log-mode circular

# Stop and save
pktmon stop

# Convert to pcapng for Wireshark analysis
pktmon etl2pcap C:\captures\net_dropout.etl --out C:\captures\net_dropout.pcapng

# Show drop reasons (unique to pktmon)
pktmon start --capture --drop-reason
```

### Alternative: dumpcap (Wireshark CLI)

For when you need full packet decode or RTP stream analysis:

```powershell
# Ring buffer: 10 files × 100MB, overwrites oldest
dumpcap -i "Ethernet" -b filesize:102400 -b files:10 -w C:\captures\ring.pcapng

# tshark RTP stream analysis after capture
tshark -r dropout.pcapng -q -z rtp,streams
```

### Key Wireshark Filters for Dropout Analysis

| Filter | What It Catches |
|--------|-----------------|
| `arp.isgratuitous == true` | Gateway reboot (eero crash/restart) |
| `tcp.analysis.retransmission` | WAN-side failure (ISP drop) |
| `tcp.analysis.lost_segment` | Packets lost in transit |
| `dns.flags.rcode != 0` | DNS failures (WAN down) |
| `icmp.type == 3` | Router reporting WAN unreachable |
| `eth.dst == ff:ff:ff:ff:ff:ff` | Broadcast storm |
| `bootp` | DHCP handshake failures |

---

## 4. Dropout Signatures Cheat Sheet

| Symptom During Dropout | Gateway Ping | External Ping | Likely Cause |
|------------------------|-------------|---------------|--------------|
| Complete capture silence, Event 27 in Event Viewer | TIMEOUT | TIMEOUT | I226-V link drop (EEE bug) |
| LAN pings OK, external fails, TCP retransmissions | OK | TIMEOUT | Frontier/ISP outage |
| Gratuitous ARP burst, all traffic stops 30-90s | TIMEOUT (brief) | TIMEOUT | eero gateway reboot |
| Wireless clients drop, wired unaffected | OK | OK | eero mesh node failure |
| Thousands of broadcast frames/sec | TIMEOUT | TIMEOUT | Broadcast/ARP storm |
| DHCP DISCOVER with no OFFER | TIMEOUT | TIMEOUT | DHCP failure |

---

## 5. Frontier Fiber + eero Specific Notes

- Frontier uses DHCP (not PPPoE in most markets) — eero should work as direct replacement router
- No VLAN tagging support on eero — if Frontier requires VLAN tagging (some markets use VLAN 201), need intermediate managed switch
- MTU defaults to 1500. If PPPoE involved, effective MTU drops to 1492. eero has no MTU config
- Double NAT: if Frontier router stays in path, put it in bridge/passthrough mode
- DHCP lease stickiness: when swapping routers, power-cycle ONT for 5-10 minutes to release lease

---

## 6. Recommended Diagnostic Plan

### Phase A: Immediate (5 minutes)

1. **Check I226-V EEE** — run the PowerShell diagnostic commands above. Disable EEE if enabled
2. **Check Event Viewer** — filter for `e2fnexpress` events. If you see Event 27/32 pairs → confirmed NIC-level drops
3. **Check eero firmware version** via eero app

### Phase B: Continuous Monitoring (already built)

The monitor dashboard's Network tab (Phase 1-3 of our plan) already provides:
- Gateway vs external ping triage
- Packet loss %, jitter, RTT charts
- VoIP readiness assessment
- Automatic verdict: gateway-issue vs wan-issue vs stable

### Phase C: Packet Capture Tooling (next to build)

1. **`scripts/network_capture.ps1`** — pktmon circular capture + ping-triggered stop/save
2. **Integration with `network_longrun.ps1`** — trigger pktmon stop on burst detection
3. **Post-capture analysis** — convert ETL → pcapng, run Wireshark filters, generate dropout report

### Phase D: Deep Dive (if drops continue after EEE fix)

1. **eero bypass test** — connect PC directly to Frontier ONT for 24h. If no drops → eero confirmed
2. **eero support call** — ask them to pull device logs during active dropout
3. **Frontier support call** — bring evidence from Phase B/C showing WAN-side failure pattern

---

## Sources

### Intel I226-V
- [Intel I226-V Connection Issue (Intel official)](https://www.intel.com/content/www/us/en/support/articles/000095752/ethernet-products.html)
- [Intel I226 Random Connection Drops (Intel Community)](https://community.intel.com/t5/Ethernet-Products/Intel-Communication-Intel-Ethernet-Controller-I226-Series-Random/td-p/1453177)
- [I226-V Still Randomly Disconnecting (Intel Community)](https://community.intel.com/t5/Ethernet-Products/Intel-I226-V-is-still-randomly-disconnecting/td-p/1630534)
- [I226-V NVM Firmware Update Guide (hungvu.tech)](https://hungvu.tech/how-to-update-nvm-firmware-for-intel-i225-and-i226-ethernet-controllers/)
- [I226 NVM v2.29/2.32 (Station-Drivers)](https://www.station-drivers.com/index.php/en/forum/intel-lan-drivers-firmwares-utilities/996-intel-i226-v-lan-controllers-firmware-nvm-version-2-29-2-32)
- [The Fix for Intel Ethernet Dropout (PC Gamer)](https://www.pcgamer.com/the-fix-is-in-for-the-intel-ethernet-chip-that-keeps-dropping-out/)

### eero
- [eero Stability Issues After 7.0.0 (eero Community)](https://community.eero.com/t/p8yyha6/eero-stability-issues-after-upgrade-to-7-0-0)
- [eero Sporadic Connection Loss (eero Community)](https://community.eero.com/t/x2hjyga/sporadic-network-connection-loss-both-wired-and-wireless)
- [eero Keeps Dropping ISP Connection (eero Community)](https://community.eero.com/t/h7hz0z1/eero-keeps-dropping-connection-with-isp-modem)
- [eero Router Security Analysis (RouterSecurity.org)](https://routersecurity.org/eero.php)
- [Hacking eero 6 Internals (Markuta)](https://markuta.com/eero-6-hacking-part-1/)

### Packet Capture
- [pktmon Documentation (Microsoft Learn)](https://learn.microsoft.com/en-us/windows-server/networking/technologies/pktmon/pktmon)
- [Wireshark Gratuitous ARP Wiki](https://wiki.wireshark.org/Gratuitous_ARP)
- [dumpcap Man Page](https://www.wireshark.org/docs/man-pages/dumpcap.html)
- [tshark RTP Analysis](https://www.wireshark.org/docs/man-pages/tshark.html)

---

*Methodology: Searched 25+ queries across web, forums, vendor documentation. Analyzed 20+ sources. Sub-questions: I226-V hardware bugs, eero firmware stability, pktmon vs Wireshark, capture strategies for intermittent drops, packet signatures for router vs ISP failures, eero diagnostic capabilities.*
