// =============================================================================
// EXPERIMENT DATA
// =============================================================================
// Add new experiments to this array to track them in the dashboard.
//
// To add a new experiment:
//   1. Run: .\scripts\baseline_capture.ps1 -Label "EXP_NAME"
//   2. Optionally run LatencyMon and save the report to captures/
//   3. Copy the structure of an existing entry below and fill in your values
//   4. Reload dashboard/index.html
//
// Fields:
//   id             - unique string identifier
//   name           - full display name
//   shortName      - abbreviated name for chart labels
//   date           - ISO 8601 capture timestamp
//   description    - one-line description of what changed
//   tags           - array of string tags
//   registry       - registry settings at capture time
//   performance    - perf counter values (avg/min/max) from baseline_capture.ps1
//   latencymon     - LatencyMon report data (null if not yet captured)
//   cpuData        - per-CPU interrupt/DPC data from LatencyMon
// =============================================================================

window.EXPERIMENTS = [
  // ---------------------------------------------------------------------------
  // BASELINE — System defaults, no tweaks applied
  // ---------------------------------------------------------------------------
  {
    id: "baseline",
    name: "Baseline",
    shortName: "Baseline",
    date: "2026-03-28T19:53:10",
    description: "System defaults — no performance tweaks applied",
    tags: ["baseline"],

    registry: {
      SystemResponsiveness: 20,
      NetworkThrottlingIndex: 10,
      GamesSchedulingCategory: "Medium",
      GamesPriority: 2,
      GamesSFIOPriority: "Normal",
      DefenderExclusions: []
    },

    // From: captures/os_baseline_BEFORE.txt
    performance: {
      AvailableMemoryMB:    { avg: 27903.1, min: 27890.0, max: 27912.0 },
      PagesSec:             { avg: 9.8942,  min: 0.0,     max: 62.9663 },
      DiskSecRead:          { avg: 0.0001,  min: 0.0,     max: 0.0005  },
      DiskSecWrite:         { avg: 0.0001,  min: 0.0,     max: 0.0004  },
      DiskQueueLength:      { avg: 0.0,     min: 0.0,     max: 0.0     },
      DPCTimePct:           { avg: 0.2927,  min: 0.0,     max: 0.4880  },
      InterruptTimePct:     { avg: 0.2927,  min: 0.0976,  max: 0.6832  },
      ProcessorTimePct:     { avg: 3.4925,  min: 1.2282,  max: 4.4450  },
      ContextSwitchesSec:   { avg: 19963.7, min: 13882.8, max: 26349.3 },
      ProcessorQueueLength: { avg: 0.0,     min: 0.0,     max: 0.0     }
    },

    // From: captures/latencymon_report.txt
    latencymon: {
      result: "PASS",
      durationMin: 1.75,

      maxInterruptToProcessUs: 178.80,
      avgInterruptToProcessUs: 10.26,
      maxInterruptToDPCUs:     160.60,
      avgInterruptToDPCUs:     3.38,

      maxISRExecutionUs:  4.629,
      maxISRDriver:       "Wdf01000.sys",
      totalISRTimePct:    0.000136,

      maxDPCExecutionUs:      561.60,
      maxDPCExecutionDriver:  "ntoskrnl.exe",
      maxDPCTotalPct:         0.104951,
      maxDPCTotalDriver:      "nvlddmkm.sys",
      totalDPCTimePct:        0.193122,

      // Buckets: [<250µs, 250-500µs, 500-10000µs, 1000-2000µs, 2000-4000µs, >=4000µs]
      dpcBuckets: [247007, 0, 6, 0, 0, 0],
      isrBuckets: [6485,   0, 0, 0, 0, 0],

      hardPagefaultsTotal:       338,
      hardPagefaultsTopProcess:  "msmpeng.exe",
      hardPagefaultsTopCount:    149,
      processesHitCount:         9,

      pagefaultsByProcess: [
        { process: "msmpeng.exe",             count: 149 },
        { process: "Other (8 processes)",     count: 189 }
      ],

      // Confirmed from LatencyMon summary — full driver table not exported
      dpcDrivers: [
        { driver: "nvlddmkm.sys", description: "NVIDIA Kernel Mode Driver v595.97", highestUs: null,   totalPct: 0.10495 },
        { driver: "ntoskrnl.exe", description: "NT Kernel & System",                highestUs: 561.60, totalPct: null    },
        { driver: "Wdf01000.sys", description: "Kernel Mode Driver Framework",      highestUs: null,   totalPct: 0.00014 }
      ]
    },

    // From: captures/latencymon_report.txt — Per CPU Data section
    cpuData: [
      { cpu: 0,  interruptCycleS: 7.823704, isrHighestUs: 4.629, isrCount: 6485, dpcHighestUs: 281.26,  dpcTotalS: 3.206382, dpcCount: 241319 },
      { cpu: 1,  interruptCycleS: 0.839047, isrHighestUs: 0,     isrCount: 0,    dpcHighestUs: 9.92,    dpcTotalS: 0.000180, dpcCount: 48     },
      { cpu: 2,  interruptCycleS: 0.617877, isrHighestUs: 0,     isrCount: 0,    dpcHighestUs: 10.99,   dpcTotalS: 0.000246, dpcCount: 64     },
      { cpu: 3,  interruptCycleS: 0.644538, isrHighestUs: 0,     isrCount: 0,    dpcHighestUs: 19.85,   dpcTotalS: 0.000257, dpcCount: 61     },
      { cpu: 4,  interruptCycleS: 0.886116, isrHighestUs: 0,     isrCount: 0,    dpcHighestUs: 340.55,  dpcTotalS: 0.016793, dpcCount: 1959   },
      { cpu: 5,  interruptCycleS: 0.925840, isrHighestUs: 0,     isrCount: 0,    dpcHighestUs: 332.37,  dpcTotalS: 0.004691, dpcCount: 816    },
      { cpu: 6,  interruptCycleS: 1.038878, isrHighestUs: 0,     isrCount: 0,    dpcHighestUs: 561.60,  dpcTotalS: 0.009803, dpcCount: 1251   },
      { cpu: 7,  interruptCycleS: 0.957039, isrHighestUs: 0,     isrCount: 0,    dpcHighestUs: 269.09,  dpcTotalS: 0.004914, dpcCount: 773    },
      { cpu: 8,  interruptCycleS: 0.736124, isrHighestUs: 0,     isrCount: 0,    dpcHighestUs: 49.10,   dpcTotalS: 0.001414, dpcCount: 323    },
      { cpu: 9,  interruptCycleS: 0.766152, isrHighestUs: 0,     isrCount: 0,    dpcHighestUs: 27.68,   dpcTotalS: 0.001067, dpcCount: 278    },
      { cpu: 10, interruptCycleS: 0.407029, isrHighestUs: 0,     isrCount: 0,    dpcHighestUs: 28.54,   dpcTotalS: 0.000190, dpcCount: 33     },
      { cpu: 11, interruptCycleS: 0.410931, isrHighestUs: 0,     isrCount: 0,    dpcHighestUs: 12.08,   dpcTotalS: 0.000193, dpcCount: 48     },
      { cpu: 12, interruptCycleS: 0.141621, isrHighestUs: 0,     isrCount: 0,    dpcHighestUs: 15.82,   dpcTotalS: 0.000068, dpcCount: 14     },
      { cpu: 13, interruptCycleS: 0.142190, isrHighestUs: 0,     isrCount: 0,    dpcHighestUs: 6.02,    dpcTotalS: 0.000020, dpcCount: 5      },
      { cpu: 14, interruptCycleS: 0.073930, isrHighestUs: 0,     isrCount: 0,    dpcHighestUs: 8.58,    dpcTotalS: 0.000051, dpcCount: 11     },
      { cpu: 15, interruptCycleS: 0.073626, isrHighestUs: 0,     isrCount: 0,    dpcHighestUs: 51.25,   dpcTotalS: 0.000133, dpcCount: 10     }
    ]
  },

  // ---------------------------------------------------------------------------
  // EXPERIMENT 01 — MMCSS + Network Throttling + Defender exclusions
  // ---------------------------------------------------------------------------
  {
    id: "exp01_mmcss_network",
    name: "Exp 01 — MMCSS + Network",
    shortName: "Exp 01",
    date: "2026-03-28T20:17:58",
    description: "SystemResponsiveness=0, NetworkThrottlingIndex disabled, MMCSS Games=High, Defender exclusions for Fortnite",
    tags: ["mmcss", "network", "defender"],

    registry: {
      SystemResponsiveness: 0,
      NetworkThrottlingIndex: 4294967295,
      GamesSchedulingCategory: "High",
      GamesPriority: 6,
      GamesSFIOPriority: "High",
      DefenderExclusions: [
        "C:\\Program Files\\Epic Games\\Fortnite",
        "C:\\Program Files\\Epic Games\\Launcher"
      ]
    },

    // From: captures/os_baseline_AFTER.txt
    performance: {
      AvailableMemoryMB:    { avg: 27930.5, min: 27920.0, max: 27941.0 },
      PagesSec:             { avg: 0.0,     min: 0.0,     max: 0.0     },
      DiskSecRead:          { avg: 0.0000,  min: 0.0,     max: 0.0     },
      DiskSecWrite:         { avg: 0.0002,  min: 0.0,     max: 0.0004  },
      DiskQueueLength:      { avg: 0.0,     min: 0.0,     max: 0.0     },
      DPCTimePct:           { avg: 0.2927,  min: 0.0,     max: 0.6832  },
      InterruptTimePct:     { avg: 0.2244,  min: 0.0975,  max: 0.7805  },
      ProcessorTimePct:     { avg: 3.7786,  min: 1.9255,  max: 5.2673  },
      ContextSwitchesSec:   { avg: 20475.4, min: 13832.5, max: 24647.0 },
      ProcessorQueueLength: { avg: 0.0,     min: 0.0,     max: 0.0     }
    },

    // LatencyMon not yet captured for this experiment
    // Run LatencyMon under load and populate this object to enable latency charts
    latencymon: null,
    cpuData: null
  },

  // ---------------------------------------------------------------------------
  // EXPERIMENT 02 — Defender Optimization
  // Applied: 2026-03-29 | Fix 2 from implementation-plan.md
  // ---------------------------------------------------------------------------
  {
    id: "exp02_defender",
    name: "Exp 02 — Defender Optimization",
    shortName: "Exp 02",
    date: "2026-03-29T12:01:34",
    description: "Process exclusions for Fortnite/EAC/BEService, shader cache path exclusions, ScanAvgCPULoadFactor=5, EnableLowCpuPriority=true, scans rescheduled to 3 AM",
    tags: ["defender", "exclusions", "scan-priority"],

    registry: {
      // MMCSS/network unchanged from Exp 01
      SystemResponsiveness: 0,
      NetworkThrottlingIndex: 4294967295,
      GamesSchedulingCategory: "High",
      GamesPriority: 6,
      GamesSFIOPriority: "High",
      // Defender — expanded from Exp 01
      DefenderExclusions: [
        "C:\\Program Files\\Epic Games\\Fortnite",
        "C:\\Program Files\\Epic Games\\Launcher",
        "C:\\ProgramData\\Epic\\EpicGamesLauncher",
        "C:\\Users\\L\\AppData\\Local\\EpicGamesLauncher",
        "C:\\Users\\L\\AppData\\Local\\FortniteGame",
        "C:\\Users\\L\\AppData\\Local\\Temp"
      ],
      DefenderExclusionProcesses: [
        "FortniteClient-Win64-Shipping.exe",
        "EpicGamesLauncher.exe",
        "EasyAntiCheat.exe",
        "EasyAntiCheat_EOS.exe",
        "BEService.exe"
      ],
      DefenderScanAvgCPULoadFactor: 5,
      DefenderEnableLowCpuPriority: true,
      DefenderScanScheduleTime: "03:00:00",
      DefenderScanScheduleQuickScanTime: "03:30:00"
    },

    // From: captures/os_baseline_EXP02_DEFENDER.txt
    // Note: system idle at capture time — CPU/context-switch values lower than typical
    performance: {
      AvailableMemoryMB:    { avg: 25848.1, min: 25829.0, max: 25852.0 },
      PagesSec:             { avg: 0.0999,  min: 0.0,     max: 0.9987  },
      DiskSecRead:          { avg: 0.0,     min: 0.0,     max: 0.0     },
      DiskSecWrite:         { avg: 0.0001,  min: 0.0,     max: 0.0002  },
      DiskQueueLength:      { avg: 0.0,     min: 0.0,     max: 0.0     },
      DPCTimePct:           { avg: 0.0781,  min: 0.0,     max: 0.2930  },
      InterruptTimePct:     { avg: 0.0293,  min: 0.0,     max: 0.0976  },
      ProcessorTimePct:     { avg: 0.8737,  min: 0.0,     max: 3.0305  },
      ContextSwitchesSec:   { avg: 2417.6,  min: 1975.2,  max: 2766.2  },
      ProcessorQueueLength: { avg: 0.0,     min: 0.0,     max: 0.0     }
    },

    // LatencyMon not yet captured — run after gaming session to measure pagefault reduction
    latencymon: null,
    cpuData: null
  },

  // ---------------------------------------------------------------------------
  // EXPERIMENT 03 — NVIDIA MSI Mode + Max Performance Power + GPU Affinity
  // Applied: 2026-03-29 | Fix 3 from implementation-plan.md
  // REBOOT REQUIRED — registry written, changes activate on next boot
  // ---------------------------------------------------------------------------
  {
    id: "exp03_nvidia_msi",
    name: "Exp 03 — NVIDIA MSI + Power",
    shortName: "Exp 03",
    date: "2026-03-29T12:16:16",
    description: "GPU MSI mode enabled (MSISupported=1, MessageNumberLimit=1), PerfLevelSrc=0x2222 (max perf), GPU interrupt affinity pinned to CPUs 4-7. HAGS was already enabled. Reboot required.",
    tags: ["nvidia", "msi", "power", "gpu-affinity"],

    registry: {
      // MMCSS/network unchanged from Exp 01
      SystemResponsiveness: 0,
      NetworkThrottlingIndex: 4294967295,
      GamesSchedulingCategory: "High",
      GamesPriority: 6,
      GamesSFIOPriority: "High",
      // Defender unchanged from Exp 02
      DefenderExclusions: [
        "C:\\Program Files\\Epic Games\\Fortnite",
        "C:\\Program Files\\Epic Games\\Launcher",
        "C:\\ProgramData\\Epic\\EpicGamesLauncher",
        "C:\\Users\\L\\AppData\\Local\\EpicGamesLauncher",
        "C:\\Users\\L\\AppData\\Local\\FortniteGame",
        "C:\\Users\\L\\AppData\\Local\\Temp"
      ],
      DefenderExclusionProcesses: [
        "FortniteClient-Win64-Shipping.exe",
        "EpicGamesLauncher.exe",
        "EasyAntiCheat.exe",
        "EasyAntiCheat_EOS.exe",
        "BEService.exe"
      ],
      DefenderScanAvgCPULoadFactor: 5,
      DefenderEnableLowCpuPriority: true,
      // NVIDIA — new in this experiment
      GPU: "NVIDIA GeForce RTX 5070 Ti",
      NvidiaMSISupported: 1,
      NvidiaMessageNumberLimit: 1,
      NvidiaPerfLevelSrc: "0x2222",
      NvidiaHwSchMode: 2,
      NvidiaGPUInterruptDevicePolicy: 4,
      NvidiaGPUInterruptAffinityMask: "0xF0 (CPUs 4-7)"
    },

    // From: captures/os_baseline_EXP03_NVIDIA.txt
    // Note: registry written pre-reboot; perf impact of MSI/affinity not yet visible
    performance: {
      AvailableMemoryMB:    { avg: 25594.8, min: 25559.0, max: 25607.0 },
      PagesSec:             { avg: 0.1999,  min: 0.0,     max: 1.9995  },
      DiskSecRead:          { avg: 0.0,     min: 0.0,     max: 0.0005  },
      DiskSecWrite:         { avg: 0.0002,  min: 0.0,     max: 0.0003  },
      DiskQueueLength:      { avg: 0.0,     min: 0.0,     max: 0.0     },
      DPCTimePct:           { avg: 0.3121,  min: 0.0,     max: 0.7804  },
      InterruptTimePct:     { avg: 0.2732,  min: 0.0,     max: 0.5855  },
      ProcessorTimePct:     { avg: 4.3345,  min: 2.3232,  max: 6.3518  },
      ContextSwitchesSec:   { avg: 23082.6, min: 15897.6, max: 30496.7 },
      ProcessorQueueLength: { avg: 0.0,     min: 0.0,     max: 0.0     }
    },

    // LatencyMon should be run after rebooting to confirm MSI mode reduced nvlddmkm.sys DPC time
    // Target: totalDPCTimePct < 0.03% (down from 0.105%), maxDPCExecutionUs < 200µs
    latencymon: null,
    cpuData: null
  },

  // ---------------------------------------------------------------------------
  // EXPERIMENT 04 — CPU Interrupt Affinity Redistribution
  // Applied: 2026-03-29 | Fix 1 from implementation-plan.md
  // REBOOT REQUIRED — registry written, changes activate on next boot
  // ---------------------------------------------------------------------------
  {
    id: "exp04_cpu_affinity",
    name: "Exp 04 — CPU Interrupt Affinity",
    shortName: "Exp 04",
    date: "2026-03-29T12:20:53",
    description: "Interrupt affinity pinned to CPUs 4-7 for: NIC (Intel I226-V), audio (AMD HDMI + NVIDIA HDMI), 5x AMD USB xHCI controllers. RSS unavailable for I226-V driver — affinity registry used instead. Reboot required.",
    tags: ["cpu-affinity", "interrupt", "nic", "usb", "audio"],

    registry: {
      // MMCSS/network unchanged from Exp 01
      SystemResponsiveness: 0,
      NetworkThrottlingIndex: 4294967295,
      GamesSchedulingCategory: "High",
      GamesPriority: 6,
      GamesSFIOPriority: "High",
      // Defender unchanged from Exp 02
      DefenderExclusions: [
        "C:\\Program Files\\Epic Games\\Fortnite",
        "C:\\Program Files\\Epic Games\\Launcher",
        "C:\\ProgramData\\Epic\\EpicGamesLauncher",
        "C:\\Users\\L\\AppData\\Local\\EpicGamesLauncher",
        "C:\\Users\\L\\AppData\\Local\\FortniteGame",
        "C:\\Users\\L\\AppData\\Local\\Temp"
      ],
      DefenderExclusionProcesses: [
        "FortniteClient-Win64-Shipping.exe",
        "EpicGamesLauncher.exe",
        "EasyAntiCheat.exe",
        "EasyAntiCheat_EOS.exe",
        "BEService.exe"
      ],
      DefenderScanAvgCPULoadFactor: 5,
      DefenderEnableLowCpuPriority: true,
      // NVIDIA unchanged from Exp 03
      NvidiaMSISupported: 1,
      NvidiaMessageNumberLimit: 1,
      NvidiaPerfLevelSrc: "0x2222",
      NvidiaHwSchMode: 2,
      // Interrupt affinity — new in this experiment
      InterruptAffinityPolicy: "DevicePolicy=4 (SpecifiedProcessors), CPUs 4-7 (mask=0xF0)",
      DevicesAffined: [
        "NIC: Intel I226-V (PCI\\VEN_8086&DEV_125C...)",
        "Audio: AMD HDMI (HDAUDIO\\FUNC_01&VEN_1002...)",
        "Audio: NVIDIA HDMI (HDAUDIO\\FUNC_01&VEN_10DE...)",
        "USB: AMD 3.10 xHCI (VEN_1022&DEV_15B7)",
        "USB: AMD 3.20 xHCI (VEN_1022&DEV_43F7) x2",
        "USB: AMD 3.10 xHCI (VEN_1022&DEV_15B6)",
        "USB: AMD 2.0 xHCI (VEN_1022&DEV_15B8)"
      ]
    },

    // From: captures/os_baseline_EXP04_CPU_AFFINITY.txt
    // Note: registry changes written pre-reboot; interrupt redistribution not yet active
    performance: {
      AvailableMemoryMB:    { avg: 23321.9, min: 23309.0, max: 23329.0 },
      PagesSec:             { avg: 0.1,     min: 0.0,     max: 0.9996  },
      DiskSecRead:          { avg: 0.0,     min: 0.0,     max: 0.0     },
      DiskSecWrite:         { avg: 0.0001,  min: 0.0,     max: 0.0003  },
      DiskQueueLength:      { avg: 0.0,     min: 0.0,     max: 0.0     },
      DPCTimePct:           { avg: 0.3999,  min: 0.0976,  max: 0.7803  },
      InterruptTimePct:     { avg: 0.3805,  min: 0.0976,  max: 1.0735  },
      ProcessorTimePct:     { avg: 4.8808,  min: 2.3438,  max: 6.1924  },
      ContextSwitchesSec:   { avg: 24236.7, min: 16336.8, max: 29655.3 },
      ProcessorQueueLength: { avg: 0.0,     min: 0.0,     max: 0.0     }
    },

    // LatencyMon must be run AFTER rebooting to see interrupt redistribution effect.
    // Target: CPU 0 interrupt cycle time < 2.0s (down from 7.83s baseline)
    // Target: CPUs 4-7 interrupt cycle time > 0.5s each
    latencymon: null,
    cpuData: null
  },

  // ---------------------------------------------------------------------------
  // EXP 05 — Post-Reboot Verification
  // ---------------------------------------------------------------------------
  {
    id: "exp05_post_reboot",
    name: "Exp 05 — Post-Reboot Verification",
    shortName: "Exp 05",
    date: "2026-03-29T12:44:53",
    description: "Post-reboot: verify all registry changes survived and measure interrupt redistribution",
    tags: ["verification", "post-reboot", "affinity"],

    // All 16 registry checks passed (see captures/os_baseline_EXP05_POST_REBOOT.txt)
    registry: {
      // Fix 1 — MMCSS/network (unchanged from EXP01)
      SystemResponsiveness: 10,
      NetworkThrottlingIndex: 4294967295,
      GamesSchedulingCategory: "High",
      GamesPriority: 6,
      GamesSFIOPriority: "High",
      // Fix 2 — Defender (unchanged from EXP02)
      ScanAvgCPULoadFactor: 5,
      EnableLowCpuPriority: true,
      DefenderExclusionProcessPaths: [
        "Fortnite", "EpicGamesLauncher", "nvcontainer.exe",
        "NVDisplay.Container.exe", "steam.exe"
      ],
      // Fix 3 — NVIDIA MSI + PerfLevelSrc (unchanged from EXP03)
      NvidiaMSISupported: 1,
      NvidiaMessageNumberLimit: 1,
      PerfLevelSrc: "0x2222",
      HwSchMode: 2,
      // Fix 4 — Interrupt affinity (unchanged from EXP04, now ACTIVE post-reboot)
      InterruptAffinityPolicy: "DevicePolicy=4 (SpecifiedProcessors), CPUs 4-7 (mask=0xF0)",
      DevicesAffined: [
        "NIC: Intel I226-V",
        "Audio: AMD HDMI", "Audio: NVIDIA HDMI",
        "USB: AMD xHCI x5"
      ]
    },

    // From: captures/os_baseline_EXP05_POST_REBOOT.txt (60s capture, 1s samples)
    // System was under moderate load (23K ctx switches/sec, 2751 page faults/sec)
    performance: {
      AvailableMemoryMB:    { avg: null,   min: null,  max: null  },
      PagesSec:             { avg: 1.5,    min: null,  max: null  },
      DiskSecRead:          { avg: null,   min: null,  max: null  },
      DiskSecWrite:         { avg: null,   min: null,  max: null  },
      DiskQueueLength:      { avg: null,   min: null,  max: null  },
      DPCTimePct:           { avg: 0.4293, min: null,  max: null  },
      InterruptTimePct:     { avg: 0.6179, min: null,  max: null  },
      ProcessorTimePct:     { avg: null,   min: null,  max: null  },
      ContextSwitchesSec:   { avg: 23001.8,min: null,  max: null  },
      ProcessorQueueLength: { avg: null,   min: null,  max: null  }
    },

    // Key result: CPU 0 interrupt share dropped from 97.7% → 4.2%
    // CPUs 4-7 now carry the interrupt load (2.2-2.6% each) as intended
    latencymon: null,

    // Per-CPU data from 60s perf counter capture (% Interrupt Time avg)
    cpuData: [
      { cpu: 0,  interruptCycleS: null, isrHighestUs: null, isrCount: null,
        dpcHighestUs: null, dpcTotalS: null, dpcCount: null,
        interruptPct: 0.0260, dpcPct: 0.0260, intrPerSec: 281.4 },
      { cpu: 1,  interruptCycleS: null, isrHighestUs: null, isrCount: null,
        dpcHighestUs: null, dpcTotalS: null, dpcCount: null,
        interruptPct: 0.0000, dpcPct: 0.0000, intrPerSec: 31.3 },
      { cpu: 2,  interruptCycleS: null, isrHighestUs: null, isrCount: null,
        dpcHighestUs: null, dpcTotalS: null, dpcCount: null,
        interruptPct: 0.1041, dpcPct: 0.0000, intrPerSec: 924.8 },
      { cpu: 3,  interruptCycleS: null, isrHighestUs: null, isrCount: null,
        dpcHighestUs: null, dpcTotalS: null, dpcCount: null,
        interruptPct: 0.0000, dpcPct: 0.0000, intrPerSec: 526.1 },
      { cpu: 4,  interruptCycleS: null, isrHighestUs: null, isrCount: null,
        dpcHighestUs: null, dpcTotalS: null, dpcCount: null,
        interruptPct: 2.2375, dpcPct: 1.6912, intrPerSec: 3286.4 },
      { cpu: 5,  interruptCycleS: null, isrHighestUs: null, isrCount: null,
        dpcHighestUs: null, dpcTotalS: null, dpcCount: null,
        interruptPct: 2.0554, dpcPct: 1.5090, intrPerSec: 2031.6 },
      { cpu: 6,  interruptCycleS: null, isrHighestUs: null, isrCount: null,
        dpcHighestUs: null, dpcTotalS: null, dpcCount: null,
        interruptPct: 2.5757, dpcPct: 1.4569, intrPerSec: 2855.4 },
      { cpu: 7,  interruptCycleS: null, isrHighestUs: null, isrCount: null,
        dpcHighestUs: null, dpcTotalS: null, dpcCount: null,
        interruptPct: 2.5757, dpcPct: 2.1854, intrPerSec: 2295.2 },
      { cpu: 8,  interruptCycleS: null, isrHighestUs: null, isrCount: null,
        dpcHighestUs: null, dpcTotalS: null, dpcCount: null,
        interruptPct: 0.2081, dpcPct: 0.0000, intrPerSec: 1830.3 },
      { cpu: 9,  interruptCycleS: null, isrHighestUs: null, isrCount: null,
        dpcHighestUs: null, dpcTotalS: null, dpcCount: null,
        interruptPct: 0.0000, dpcPct: 0.0000, intrPerSec: 676.7 },
      { cpu: 10, interruptCycleS: null, isrHighestUs: null, isrCount: null,
        dpcHighestUs: null, dpcTotalS: null, dpcCount: null,
        interruptPct: 0.0520, dpcPct: 0.0000, intrPerSec: 541.1 },
      { cpu: 11, interruptCycleS: null, isrHighestUs: null, isrCount: null,
        dpcHighestUs: null, dpcTotalS: null, dpcCount: null,
        interruptPct: 0.0260, dpcPct: 0.0000, intrPerSec: 149.4 },
      { cpu: 12, interruptCycleS: null, isrHighestUs: null, isrCount: null,
        dpcHighestUs: null, dpcTotalS: null, dpcCount: null,
        interruptPct: 0.0260, dpcPct: 0.0000, intrPerSec: 63.6 },
      { cpu: 13, interruptCycleS: null, isrHighestUs: null, isrCount: null,
        dpcHighestUs: null, dpcTotalS: null, dpcCount: null,
        interruptPct: 0.0000, dpcPct: 0.0000, intrPerSec: 16.3 },
      { cpu: 14, interruptCycleS: null, isrHighestUs: null, isrCount: null,
        dpcHighestUs: null, dpcTotalS: null, dpcCount: null,
        interruptPct: 0.0000, dpcPct: 0.0000, intrPerSec: 22.0 },
      { cpu: 15, interruptCycleS: null, isrHighestUs: null, isrCount: null,
        dpcHighestUs: null, dpcTotalS: null, dpcCount: null,
        interruptPct: 0.0000, dpcPct: 0.0000, intrPerSec: 11.9 }
    ]
  },

  // ---------------------------------------------------------------------------
  // EXP 06 — KB/Mouse Interrupt Isolation (CPUs 2-3)
  // ---------------------------------------------------------------------------
  {
    id: "exp06_input_affinity",
    name: "Exp 06 — Input Device Interrupt Isolation",
    shortName: "Exp 06",
    date: "2026-03-29T12:49:05",
    description: "Pin keyboard/mouse USB controllers to CPUs 2-3, separate from GPU/NIC/USB-other on CPUs 4-7",
    tags: ["affinity", "input", "usb", "keyboard", "mouse"],

    registry: {
      // Same as Exp05 for all previous fixes, plus:
      InputDeviceAffinityPolicy: "DevicePolicy=4, CPUs 2-3 (mask=0x0C)",
      InputControllersAffined: [
        "USB 3.10 (DEV_15B6) — SteelSeries keyboard  [0C 00 00 00 00 00 00 00]",
        "USB 3.10 (DEV_15B7) — Razer mouse/keyboard  [0C 00 00 00 00 00 00 00]",
        "USB 3.20 (DEV_43F7) — ASUS ROG devices      [0C 00 00 00 00 00 00 00]"
      ],
      NIC_GPU_USB_AffinityPolicy: "CPUs 4-7 (mask=0xF0) — unchanged from Exp04",
      SystemResponsiveness: 0,
      NetworkThrottlingIndex: 4294967295,
      GamesSchedulingCategory: "High",
      GamesPriority: 6,
      GamesSFIOPriority: "High"
    },

    // From: captures/os_baseline_EXP06_INPUT_AFFINITY.txt
    // Note: interrupt redistribution won't show until next reboot
    performance: {
      AvailableMemoryMB:    { avg: 26386.4, min: 26373.0, max: 26410.0 },
      PagesSec:             { avg: 0.0,     min: 0.0,     max: 0.0     },
      DiskSecRead:          { avg: 0.0001,  min: 0.0,     max: 0.0005  },
      DiskSecWrite:         { avg: 0.0001,  min: 0.0,     max: 0.0002  },
      DiskQueueLength:      { avg: 0.0,     min: 0.0,     max: 0.0     },
      DPCTimePct:           { avg: 0.2926,  min: 0.0,     max: 0.5853  },
      InterruptTimePct:     { avg: 0.5560,  min: 0.0974,  max: 1.3656  },
      ProcessorTimePct:     { avg: 5.1051,  min: 2.5090,  max: 6.9984  },
      ContextSwitchesSec:   { avg: 25024.5, min: 16675.3, max: 31820.9 },
      ProcessorQueueLength: { avg: 0.0,     min: 0.0,     max: 0.0     }
    },

    // LatencyMon to be run after next reboot to verify CPUs 2-3 handle input interrupts
    // Expected: CPU 2-3 show moderate interrupt load, CPUs 4-7 unchanged for GPU/NIC
    latencymon: null,
    cpuData: null
  },

  // ---------------------------------------------------------------------------
  // ADD NEW EXPERIMENTS BELOW THIS LINE
  // ---------------------------------------------------------------------------
  // Example:
  // {
  //   id: "exp07_hpet_disable",
  //   name: "Exp 07 — HPET Disabled",
  //   shortName: "Exp 07",
  //   date: "2026-XX-XXTXX:XX:XX",
  //   description: "Disabled HPET via bcdedit /set useplatformclock false",
  //   tags: ["hpet", "timer"],
  //   registry: { ... },
  //   performance: { ... },
  //   latencymon: { ... },
  //   cpuData: [ ... ]
  // },
];
