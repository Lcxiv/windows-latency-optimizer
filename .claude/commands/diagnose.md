# Diagnostic Dispatcher

Triage latency symptoms and route to the right domain agent.

## Workflow

1. **Classify** — Parse the user's symptom description and map to a domain:
   - Mouse/input/stutter/polling/Razer/keyboard/HID → `@dpc`
   - Frame drops/hitches/GPU/NVIDIA/G-Sync/tearing/RTSS → `@gpu`
   - Ping/packet loss/DNS/TCP/WiFi/NIC/bufferbloat → `@net`
   - Audit/health/Defender/BIOS/services/registry → `@system`
   - Audio/warble/HDMI/crackle → `@dpc` (audio is DPC-rooted)
   - Capture/baseline/pipeline/WPR/xperf → `@capture`
   - No clear symptom → run quick audit first

2. **Quick audit** — Run the standalone dispatcher for baseline data:
   ```bash
   powershell -ExecutionPolicy Bypass -File scripts/diagnose.ps1 -Domain $DOMAIN -MonitorOutput
   ```

3. **Route** — Based on classification, invoke the specialist agent:
   - `@triage` for ambiguous symptoms (it will sub-route)
   - `@dpc` for input/DPC/audio
   - `@gpu` for frame timing/display
   - `@net` for network
   - `@system` for system health
   - `@capture` for capture pipeline

4. **Multi-domain** — If symptoms span domains (e.g., "mouse stutters AND ping spikes"):
   - Route sequentially: `@dpc` first, then `@net`
   - Wait for each to complete before starting next

## Quick Reference

| Symptom | Domain | Agent | PS Command |
|---------|--------|-------|------------|
| Mouse stutter | DPC | `@dpc` | `diagnose.ps1 -Domain dpc` |
| Frame drops | GPU | `@gpu` | `diagnose.ps1 -Domain gpu` |
| Ping spikes | Net | `@net` | `diagnose.ps1 -Domain net` |
| System sluggish | System | `@system` | `diagnose.ps1 -Domain system` |
| Audio warble | DPC | `@dpc` | `diagnose.ps1 -Symptom "audio"` |
| Everything | All | `@triage` | `diagnose.ps1 -Domain all` |

## Baselines

- Pre-fix: 103 gaps, 703ms max, nvlddmkm.sys 256µs
- Post-MSI: 25 gaps, 11ms max, dxgkrnl.sys 256µs

## Dashboard

Results appear in the **Command Center** tab of the Latency Monitor:
```
monitor/index.html#command
```
