---
tags: [research, nic, i226v, ping, network, rca]
date: 2026-04-24
status: complete
aliases: [Ping Regression, NIC Speed Lock]
---

# 2026-04-24 Ping Regression RCA (Intel I226-V Speed Lock + Link Flaps)

## Symptom
Game felt laggy, ping 30 -> 50 ms. User on Fortnite, session running since 6:05 AM.

## Root Cause
**Intel I226-V NIC was manually locked to `1.0 Gbps Full Duplex` instead of Auto Negotiation.** NIC capable of 2.5 Gbps. After each link flap (2 events same day: 12:58:05, 13:11:58), link came back at 1G because setting forced it. Combined with Interrupt Moderation = Enabled/Medium, added baseline input-to-wire latency. TCP retransmit rate at 1.17% (56896 / 4854313 segments) consistent with flap-induced retransmits.

**Not the ISP.** Tracert Frontier -> LA -> Google = 4 ms clean. LAN ping 0 ms, 8.8.8.8 ping 3-4 ms. ICMP path healthy. The "50 ms in-game" is Fortnite server RTT, server-side selection.

## Fix
Three one-liners, no reboot:
```powershell
Set-NetAdapterAdvancedProperty -Name Ethernet -DisplayName 'Speed & Duplex' -DisplayValue 'Auto Negotiation'
Set-NetAdapterAdvancedProperty -Name Ethernet -DisplayName 'Interrupt Moderation' -DisplayValue 'Disabled' -NoRestart
Add-MpPreference -ExclusionProcess 'EpicWebHelper.exe','FortniteLauncher.exe','steam.exe'
```
Result: link came up at 2.5 Gbps immediately. Cable + switch port both 2.5G-capable.

## Lesson / Reusable Pattern
- **Always check Speed & Duplex is `Auto Negotiation`, not a specific value.** A manual lock overrides link-partner capability. Prior experiments may leave NIC locked.
- **Link flap events live in System event log under Intel I226-V provider (Event IDs 27 = disconnect, 32 = established).** Each flap = TCP retransmit burst + per-game-session re-handshake. Visible as ping jumps in running games.
- **I226-V driver 2.x stability is version-sensitive.** 2.1.5.7 (Sep 2025) shipped with known link-flap edge cases. Check Intel.com for newer PROSet; requires reboot.
- **ICMP ping != game ping.** If local ping healthy but game ping jumps, suspect NIC offloads / moderation / speed lock, or game's server-side matchmaking region.
- **Interrupt Moderation should be Disabled for competitive gaming.** Rate setting (Low/Medium/High/Extreme) is secondary when Moderation itself is off.

## Related
- Backup of pre-fix state: `C:\Users\L\Desktop\windows-latency-optimizer\captures\backup_nic_pnp_20260424_133900_pre_ping_fix.txt`
- Experiment entry: `C:\Users\L\Desktop\windows-latency-optimizer\captures\experiments\20260424_ping_regression\SUMMARY.md`
- Prior NIC backup from 4/16 experiment: `C:\Users\L\Desktop\windows-latency-optimizer\captures\backup_nic_pnp_20260416_120222.txt` (likely when the 1G lock was introduced)

## Open Items
- Intel PROSet driver update (user task, reboot required): `https://www.intel.com/content/www/us/en/download/15084/intel-ethernet-adapter-complete-driver-pack.html`
- User should restart Fortnite to re-match server region — fixes above don't change Fortnite's server selection.
