# Quick Mouse Diagnostic

Run a 10-second mouse stutter diagnostic and report results.

```bash
powershell -ExecutionPolicy Bypass -File scripts/diagnose-mouse.ps1 -DurationSec 10
```

Then run deep DPC analysis on the results:

```bash
powershell -ExecutionPolicy Bypass -File scripts/analyze-dpc-deep.ps1
```

Compare gap count, max gap, and top DPC driver against the baseline:
- Pre-fix baseline: 103 gaps, 703ms max, nvlddmkm.sys 256us
- Post-MSI baseline: 25 gaps, 11ms max, dxgkrnl.sys 256us
