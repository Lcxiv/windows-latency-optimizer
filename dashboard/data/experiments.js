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
  }

  // ---------------------------------------------------------------------------
  // ADD NEW EXPERIMENTS BELOW THIS LINE
  // ---------------------------------------------------------------------------
  // Example:
  // {
  //   id: "exp02_hpet_disable",
  //   name: "Exp 02 — HPET Disabled",
  //   shortName: "Exp 02",
  //   date: "2026-XX-XXTXX:XX:XX",
  //   description: "Disabled HPET via bcdedit /set useplatformclock false",
  //   tags: ["hpet", "timer"],
  //   registry: { ... },
  //   performance: { ... },
  //   latencymon: { ... },
  //   cpuData: [ ... ]
  // },
];
