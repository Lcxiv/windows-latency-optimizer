# PSScriptAnalyzer Lint Baseline

**Captured:** 2026-05-17T20:40:51Z (post-T4 refactor)
**Commit:** `03a6a0d` (refactor diagnose.ps1 split)
**Scope:** `scripts/` (excludes `tests/`, `spike/`, `_deprecated/`)
**Settings:** [`PSScriptAnalyzerSettings.psd1`](../PSScriptAnalyzerSettings.psd1)
**PSScriptAnalyzer version:** matches CI `env.PSSA_VERSION = 1.21.0`

---

## Summary

| Severity | Count |
|---|---|
| Error | **0** |
| Warning | 360 |
| Information | 0 |

Files scanned: **144**.

CI gates on Error severity only (`scripts/lint-all.ps1 -Errors_Only`). Warnings are tracked here for regression visibility.

---

## Warnings by rule

| Count | Rule |
|---|---|
| 117 | `PSAvoidUsingEmptyCatchBlock` |
| 101 | `PSUseBOMForUnicodeEncodedFile` |
| 41 | `PSAvoidUsingWMICmdlet` |
| 36 | `PSUseDeclaredVarsMoreThanAssignments` |
| 27 | `PSUseUsingScopeModifierInNewRunspaces` |
| 18 | `PSReviewUnusedParameter` |
| 17 | `PSPossibleIncorrectComparisonWithNull` |
| 3 | `PSAvoidAssignmentToAutomaticVariable` |

### Notes on top rules

- **`PSAvoidUsingEmptyCatchBlock` (117)** — Common pattern in capture scripts: `try { Get-WmiObject ... } catch { }` to suppress one-off WMI errors when probing hardware. Many are intentional. Cleanup opportunity: replace silent catches with `-ErrorAction SilentlyContinue` where applicable.
- **`PSUseBOMForUnicodeEncodedFile` (101)** — Most `scripts/*.ps1` files lack BOM. Per [CLAUDE.md pitfall #7](../.claude/CLAUDE.md), PS 5.1 reads BOM-less `.ps1` as Windows-1252 → UTF-8 em-dashes mangle. **High-value cleanup:** bulk-apply BOM via `spike/tests/_add-bom-all.ps1`.
- **`PSAvoidUsingWMICmdlet` (41)** — `Get-WmiObject` calls. Should migrate to `Get-CimInstance` (PS 3.0+, lower overhead, CIM not WMI). Larger refactor; defer.
- **`PSUseDeclaredVarsMoreThanAssignments` (36)** — Variables assigned but never read. Probably dead code from iterative development. Per-file review needed.

---

## Files with most warnings

(Truncated to top 20. Full list via `pwsh -File scripts/lint-all.ps1`.)

| Count | File |
|---|---|
| 1 | `scripts\helpers\smi-detect.ps1` |
| 1 | `scripts\analyze-dpc-deep.ps1` |
| 1 | `scripts\helpers\burst-detect.ps1` |
| 1 | `scripts\guard\deep-optimize.ps1` |
| 1 | `scripts\config.ps1` |
| 1 | `scripts\compare_to_reference.ps1` |
| 1 | `scripts\guard\usb-power.ps1` |
| 1 | `scripts\helpers\wmi-cache.ps1` |
| 1 | `scripts\wifi_diagnostic.ps1` |
| ... | (most files have 1-3 warnings — distribution is wide and shallow) |

---

## Regression policy

- **Error severity = CI gate.** Any new commit introducing `Severity=Error` blocks merge via `.github/workflows/test.yml` `lint` job.
- **Warning count = informational floor.** Bumping warnings is allowed; tracking only.
- **Re-snapshot when:** large refactor lands, PSScriptAnalyzer version bumps, settings change.

## How to re-measure

```powershell
pwsh -File scripts\lint-all.ps1                  # default: warnings + counts
pwsh -File scripts\lint-all.ps1 -Errors_Only     # CI mode, exits 1 iff any Error
```

## Cleanup roadmap (out of scope for current adoption phase)

1. **BOM bulk-apply** — 101 warnings → 0 via one helper run. ~5 min, zero risk.
2. **Empty catch block sweep** — 117 warnings. Per-file judgment; some legitimately suppress one-off WMI errors. ~2 hours.
3. **WMI → CIM migration** — 41 warnings. Larger refactor. ~4 hours, regression risk.
4. **Dead variable cleanup** — 36 warnings. Per-file. ~3 hours.
