---
tags: [reference, etw, registry, tools, diagnostics]
date: 2026-04-05
status: complete
aliases: [Windows Latency, ETW Providers]
---

## ETW Providers for Input Pipeline

| Provider | GUID | Purpose |
|----------|------|---------|
| Win32k | {8C416C79-D49B-4F01-A467-E56D3AA8234C} | Input processing, MousePacketLatency |
| DWM Core | {9E9BBA3C-2E38-40CB-99F4-9E8281425164} | Compositor timing |
| DxgKrnl | {802EC45A-1E99-4B83-9920-87C98277BA9D} | GPU flips, VSync, presents |
| DXGI | {CA11C036-0102-4A2D-A6AD-F03CFED5D3C9} | Present operations |
| D3D11 | {DB6F6DDB-AC77-4E88-8253-819DF9BBF140} | D3D11 API calls |
| D3D12 | {5D8087DD-3A9B-4F56-90DF-49196CDC4F11} | D3D12 API calls |
| HID Class | {6465DA78-E7A0-4F39-B084-8F53C7C30DC6} | HID input arrival |
| USB Hub | {AC52AD17-CC01-4F85-8DF5-4DCE4333C99B} | USB completion |

## Stutter Diagnosis Signatures

| Symptom | Root Cause | Detection | Fix |
|---------|-----------|-----------|-----|
| Rhythmic stutter (fixed interval) | KB5077181 FSO scheduling | PresentMon periodic spikes | Disable FSO per-game |
| First-encounter-only spikes | Shader compilation | ProcMon ReadFile on shader cache | Enable shader pre-caching |
| Random frame spikes | DPC/ISR driver stall | xperf dpcisr >500μs | Driver rollback / DDU |
| Desktop UI micro-stutter | RTX 5070 Ti bus load | GPU-Z 20% idle bus load | PerfLevelSrc=0x2222 |
| Correlated with disk activity | Defender scan | New-MpPerformanceRecording | Game folder exclusions |

## Key Registry Paths

| Setting | Path | Optimal |
|---------|------|---------|
| MPO | HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\DisableOverlays | 1 |
| MMCSS Responsiveness | HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\SystemResponsiveness | 0 |
| HAGS | HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\HwSchMode | 2 |
| NVIDIA Power | HKLM:\SYSTEM\...\Class\{4d36e968-...}\000X\PerfLevelSrc | 0x2222 |
| FSO Disable | HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers\[exe path] | DISABLEDXMAXIMIZEDWINDOWEDMODE |

## Tool Commands

```powershell
# Audit
.\scripts\audit.ps1 -Mode Deep -Threshold 80

# Pipeline capture (with game auto-detect)
.\scripts\pipeline.ps1 -Label "GAMING" -Description "test" -DurationSec 30 -WPRProfile InputLatency

# Input latency analysis
.\scripts\analyze-input-latency.ps1 -EtlFile captures\experiments\...\trace.etl

# Defender profiling
New-MpPerformanceRecording -RecordTo defender.etl
Get-MpPerformanceReport -Path defender.etl -TopFiles 20 -TopProcesses 10

# xperf DPC/ISR
xperf -i trace.etl -o dpcisr.txt -a dpcisr
```

## Network Packet Analysis

### pktmon (built-in, zero-install)
```powershell
# Start capture (all NICs, full packets)
pktmon start -c --pkt-size 0 -f capture.etl
# Stop
pktmon stop
# Convert to pcapng (for Wireshark/tshark)
pktmon etl2pcap capture.etl -o capture.pcapng
```

### tshark (requires Wireshark install)
```powershell
# Capture 30s on interface 1
dumpcap -i 1 -a duration:30 -w capture.pcapng

# Post-capture: TCP RTT stats
tshark -r capture.pcapng -q -z conv,tcp

# Post-capture: per-packet CSV with timestamps + retransmissions
tshark -r capture.pcapng -T fields -E separator=, -e frame.time_relative -e ip.src -e ip.dst -e udp.dstport -e tcp.analysis.retransmission -e frame.len

# Filter game traffic only (Fortnite example)
tshark -r capture.pcapng -Y "udp.port >= 5795 and udp.port <= 5847"

# DNS resolution delays
tshark -r capture.pcapng -Y "dns.time > 0.1" -T fields -e dns.qry.name -e dns.time
```

### Game Port Ranges
| Game | Protocol | Ports |
|------|----------|-------|
| Fortnite | UDP | 5222, 5795-5847, 9011 |
| Valorant | UDP | 5000-5500 |
| CS2 | UDP | 27015-27050 |
| Apex Legends | UDP | 37000-40000 |
| CoD | UDP | 3074, 27000-27031 |

## Razer Mouse PIDs

| PID | Model |
|-----|-------|
| 00C1 | Viper V3 Pro (Wireless) |
| 00C0 | Viper V3 Pro (Wired) |
| 00B6 | Viper V3 HyperSpeed |
| 00AA | Basilisk V3 Pro |
| 009C | DeathAdder V3 |
| 00B2 | DeathAdder V3 Pro |
