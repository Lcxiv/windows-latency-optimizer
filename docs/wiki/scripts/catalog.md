---
tags: [scripts, catalog, index]
date: 2026-04-27
status: complete
aliases: [Script Catalog, Scripts Index, catalog]
---

# Script Catalog

95+ PowerShell scripts for Windows latency optimization. All in `scripts/`.

## Experiments (16)

| Script | Purpose | Admin? | Related |
|--------|---------|--------|---------|
| exp05_nvidia_apply.ps1 | NVIDIA Reflex 2 + NVCP low latency | Yes | |
| exp07_cstates_guide.ps1 | Enable C-States in BIOS (guide) | Yes | |
| exp08_tcp_tuning_apply.ps1 | TCP stack low-latency tuning | Yes | |
| exp09_hpet_apply.ps1 | Disable HPET, force TSC | Yes | |
| exp10_memcompression_apply.ps1 | Disable memory compression | Yes | |
| exp11_stutter_fixes_apply.ps1 | FSO + MPO + Hyper-V + Shader stutter fixes | Yes | [[dwm-mpo-crash-pattern]] |
| exp12_nic_framepacing_apply.ps1 | I226-V NIC stabilization + frame pacing | Yes | [[ping-regression]] |
| exp12_nic_retuning_apply.ps1 | Post-driver-update NIC re-tuning (Nagle) | Yes | [[ping-regression]] |
| exp13_fso_mitigation_apply.ps1 | Disable FSO for detected games | Yes | [[dwm-mpo-crash-pattern]] |
| exp15_latency_mitigations_apply.ps1 | ETW autologgers + Defender exclusions + GPU power | Yes | [[performance-findings]] |
| exp16_dns_optimize_apply.ps1 | Switch DNS to Cloudflare 1.1.1.1 | Yes | |
| exp19_defender_gaming_exclusions.ps1 | Comprehensive Defender gaming exclusions | Yes | [[chrome-render-latency]] |
| exp20_disable_hags.ps1 | Disable HAGS to reduce nvlddmkm DPC | Yes | [[gpu-affinity-discovery]] |
| exp21_msi_gpu_clocks.ps1 | Lock GPU clocks to reduce P-state DPC | Yes | [[gpu-affinity-discovery]] |
| exp22_network_deep_optimize.ps1 | Deep network stack optimization (TCP/DNS/NIC/bindings) | Yes | [[burst-pattern-analysis]], [[ping-regression]] |
| exp23_fortnite_firewall.ps1 | Fortnite/Epic firewall allow rules (30 port + 6 program) | Yes | |

## Diagnostics (30)

| Script | Purpose | Admin? | Related |
|--------|---------|--------|---------|
| pipeline.ps1 | End-to-end experiment capture pipeline | Yes | |
| run_experiment.ps1 | Lightweight perf counters + registry capture | Yes | |
| baseline_capture.ps1 | Quick 10s baseline snapshot | Yes | |
| baseline_full_capture.ps1 | 5-phase full-suite baseline capture | Yes | |
| audit.ps1 | System latency audit (36 checks, HTML report) | Yes | |
| audit-checks.ps1 | Audit check functions (dot-sourced) | Yes | |
| audit-report.ps1 | HTML report generator (dot-sourced) | No | |
| health-check.ps1 | 60s system health check with scored report | Yes | |
| diagnose-burst-pattern.ps1 | Multi-source burst pattern detection + correlation | Yes | [[burst-pattern-analysis]] |
| diagnose-mouse.ps1 | Mouse stutter diagnostic (HID gap analysis) | Yes | [[gpu-affinity-discovery]] |
| diagnose_audio_clock.ps1 | HDMI audio pitch-warble diagnostic | No | |
| diagnose_chrome_render.ps1 | Chrome rendering diagnostic for Twitch/YouTube | Yes | [[chrome-render-latency]] |
| analyze-input-latency.ps1 | ETL trace input-to-display pipeline analysis | Yes | |
| analyze-dpc-deep.ps1 | Deep per-CPU DPC analysis + temporal patterns | Yes | |
| analyze_procmon.ps1 | ProcMon CSV event analysis | No | |
| analyze_procmon_idle.ps1 | ProcMon idle I/O analysis with CLI noise exclusion | Yes | [[system-polling-storms]] |
| analyze_affinity_overlap.ps1 | IRQ affinity overlap analysis + recommendations | No | |
| analyze_capframex.ps1 | CapFrameX side-by-side frame-timing comparison | No | [[rtss-reflex-caps]] |
| capframex_hitches.ps1 | Per-frame hitch table + cluster detection | No | [[rtss-reflex-caps]] |
| capframex_steady_state.ps1 | Trimmed gameplay-window recompute | No | |
| capframex_correlate_sensors.ps1 | Correlate hitches with GPU/CPU sensor readings | No | |
| profile-nsight.ps1 | Nsight Systems GPU-CPU correlation capture | Yes | |
| parse_xperf_trace.ps1 | xperf DPC/ISR trace parser (audio) | No | |
| reboot_capture.ps1 | Before/after reboot capture (DPC + xperf + GPU) | Yes | |
| build_master_report.ps1 | Build single-file MASTER.html from baseline dir | No | |
| aggregate_baseline_to_dashboard_entry.ps1 | Aggregate baseline to dashboard JSON | No | |
| _reaggregate_baseline.ps1 | Re-parse xperf + rebuild entry + MASTER.html | No | |
| synthetic_load.ps1 | CPU+disk synthetic load for baseline stress | No | |
| audit-drivers.ps1 | Driver health audit (chipset, NVMe, event log) | Yes | [[driver-health-audit]] |
| analyze-task-trace.ps1 | ETL task + GPU correlation analysis | Yes | [[scheduled-task-optimization]] |

## Hardware (9)

| Script | Purpose | Admin? | Related |
|--------|---------|--------|---------|
| run_hwdiag.ps1 | Top-level hardware diagnostic orchestrator | Yes | |
| hw_pcie_state.ps1 | PCIe link state snapshot (GPU + NVMe) | Yes | |
| hw_storage_smart.ps1 | SMART snapshot for all physical disks | Yes | |
| hw_gpu_ecc.ps1 | GPU ECC + clocks + temps continuous capture | Yes | |
| hw_whea_summary.ps1 | WHEA event log summarizer + decoder | Yes | |
| hw_kill_test.ps1 | Process kill test (slow state debug) | Yes | |
| hw_nic_errors.ps1 | NIC error statistics with delta support | Yes | |
| hw_voltage_sensors.ps1 | Voltage/temp sensors from HWiNFO64 CSV | Yes | [[hardware-voltages]], [[known-good-baseline]] |
| compare_to_reference.ps1 | Compare hwdiag run vs reference JSON | No | [[known-good-baseline]] |

## Fixes (18)

| Script | Purpose | Admin? | Related |
|--------|---------|--------|---------|
| fix_system_polling.ps1 | Fix 8 system polling storms | Yes | [[system-polling-storms]] |
| enable_system_polling.ps1 | Rollback system polling fixes | Yes | [[system-polling-storms]] |
| fix_gpu_affinity.ps1 | Route GPU interrupts off CPU 0 | Yes | [[gpu-affinity-discovery]] |
| apply_deconflict_affinity.ps1 | Deconflict GPU/NIC/audio interrupts | Yes | [[gpu-affinity-discovery]] |
| disable_defender.ps1 | Fully disable Defender real-time protection | Yes | [[chrome-render-latency]] |
| enable_defender.ps1 | Re-enable Defender real-time protection | Yes | |
| defender_disable_boot.ps1 | Boot persistence: re-apply Defender disable | Yes | |
| fix_razer_polling.ps1 | Download Razer Synapse for polling config | Yes | |
| fix_nic_power_mgmt.ps1 | Disable NIC power management | Yes | [[ping-regression]] |
| fix_audio_warble.ps1 | Fix HDMI audio pitch-warble | Yes | |
| audio_fix_and_audit.ps1 | Audio fix + audit (MMCSS, affinity, DPC) | Yes | |
| audio_diag.ps1 | Quick audio diagnostic scan | No | |
| disable_razer_startup.ps1 | Permanently disable Razer startup services | Yes | |
| post_reboot_verify_audio.ps1 | Post-reboot verify audio-warble fix | Yes | |
| fix_exitlag_filter.ps1 | Toggle ExitLag NDIS filter (disable idle, enable gaming) | Yes | [[burst-pattern-analysis]], [[ping-regression]] |
| fix_scheduled_tasks.ps1 | Disable latency-impacting scheduled tasks for gaming | Yes | [[scheduled-task-optimization]] |
| fix_chipset_drivers.ps1 | AMD chipset driver remediation guide | Yes | [[driver-health-audit]] |

## Utilities (22)

| Script | Purpose | Admin? | Related |
|--------|---------|--------|---------|
| rollback.ps1 | Restore registry from backup file | No | |
| generate_dashboard_data.ps1 | Regenerate experiments_generated.js | No | |
| optimize-game.ps1 | Game affinity + bloatware kill + launcher close | Yes | |
| optimize-bios.ps1 | Audit/apply BIOS settings via SCEWIN | Yes | [[scewin-bios]], [[9800x3d-architecture]] |
| config.ps1 | Central configuration (dot-sourced) | No | |
| topology.ps1 | CPU topology discovery (dot-sourced) | No | [[9800x3d-architecture]] |
| gpu-vendor.ps1 | GPU vendor detection (dot-sourced) | No | |
| pipeline-helpers.ps1 | Helper module loader shim (dot-sourced) | No | |
| invoke-elevated.ps1 | Run any script with admin elevation | No | |
| test-all.ps1 | Test harness: parse-check all PS scripts | No | |
| cleanup-captures.ps1 | Archive/compress old experiment data | No | |
| boot_inventory_watchdog.ps1 | Boot-time service/program/driver/task inventory + diff | Yes | [[registry-drift-log]] |
| boot_registry_watchdog.ps1 | Boot-time registry snapshot + drift alert | Yes | [[registry-drift-log]] |
| registry_watchdog_daily.ps1 | Daily registry drift trend analysis | Yes | [[registry-drift-log]] |
| vram-clock-lock.bat | Lock VRAM clocks via nvidia-smi | No | [[multi-monitor-vram]] |
| helpers/logging.ps1 | Core logging + statistics functions | No | |
| helpers/capture-core.ps1 | WPR, perf counters, GPU, xperf functions | No | |
| helpers/capture-tools.ps1 | ProcMon, PktMon, Defender recording tools | No | |
| helpers/network.ps1 | Network latency + bufferbloat + quality | No | |
| helpers/experiment.ps1 | Frame parsing, registry, analysis, JSON gen | No | |
| helpers/smi-detect.ps1 | SMI blackout detection via ETW gap analysis | No | |
| helpers/chrome.ps1 | Chrome-specific diagnostic functions | No | [[chrome-render-latency]] |

## Deprecated (5)

| Script | Purpose | Replaced By |
|--------|---------|-------------|
| _deprecated/run_audio_audit.ps1 | Wrapper for audio_fix_and_audit.ps1 | audio_fix_and_audit.ps1 |
| _deprecated/before_reboot_capture.ps1 | Pre-reboot capture | reboot_capture.ps1 |
| _deprecated/after_reboot_capture.ps1 | Post-reboot capture | reboot_capture.ps1 |
| _deprecated/run_after_reboot.ps1 | Launcher | reboot_capture.ps1 |
| _deprecated/run_disable_razer.ps1 | Launcher | disable_razer_startup.ps1 |
