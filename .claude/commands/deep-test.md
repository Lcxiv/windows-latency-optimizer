# Deep Latency Test

Run the full diagnostic suite: audit + mouse diagnostic + DPC analysis + pipeline capture + Nsight profile.

## Steps (run in order)

1. System audit:
```bash
powershell -ExecutionPolicy Bypass -File scripts/audit.ps1 -Mode Deep -Quiet
```

2. Mouse diagnostic (30s):
```bash
powershell -ExecutionPolicy Bypass -File scripts/diagnose-mouse.ps1 -DurationSec 30
```

3. Deep DPC analysis:
```bash
powershell -ExecutionPolicy Bypass -File scripts/analyze-dpc-deep.ps1
```

4. Full pipeline (2 min):
```bash
powershell -ExecutionPolicy Bypass -File scripts/pipeline.ps1 -Label "DEEP_TEST" -Description "Full diagnostic pass" -DurationSec 120 -WPRProfile "InputLatency" -SkipProcMon -SkipPktMon -SkipBufferbloat
```

5. Nsight GPU-CPU capture (30s):
```bash
powershell -ExecutionPolicy Bypass -File scripts/profile-nsight.ps1 -DurationSec 30
```

After all steps, compare results against baseline and generate a before/after report.
