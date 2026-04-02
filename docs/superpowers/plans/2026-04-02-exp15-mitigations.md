# EXP15: Deep Latency Mitigations + Gaming Diagnostic Capture

> **For agentic workers:** Use superpowers-extended-cc:executing-plans to implement this plan.

**Goal:** Apply all research-backed mitigations, fix false positives in stutter detection, enable ProcMon Duration capture, and build a combined diagnostic capture script for gameplay testing.

**Branch:** `feat/audit-tool` (continue)

---

## Task 1: Fix Stutter Detector False Positives

**Goal:** Filter out DWM idle gaps (>50ms) from stutter detection so only real rendering stalls are flagged.

**Files:**
- Modify: `scripts/analyze-input-latency.ps1` (~line 178, stutter detection loop)
- Modify: `scripts/pipeline-helpers.ps1` (Parse-FrameCSV stutter detection, ~line 98)

**Acceptance Criteria:**
- [ ] Stutter detector ignores frame gaps >50ms (classified as "idle pause" not "stutter")
- [ ] Stutter count drops from 70 to ~0 on idle captures
- [ ] During gaming, real stutters (frame time 2x median but <50ms) are still detected
- [ ] Parser: 0 errors

**Steps:**

- [ ] **Step 1:** In `analyze-input-latency.ps1`, modify the stutter detection loop (~line 178). Add a max threshold: only flag frames where `$frameTimes[$i] -gt ($median * 2)` AND `$frameTimes[$i] -lt 50`. Frames >50ms are idle pauses, not stutters.

- [ ] **Step 2:** In `pipeline-helpers.ps1`, modify the `Parse-FrameCSV` stutter detection loop (~line 98). Same fix: add `$frameTimes[$i] -lt 50` condition.

- [ ] **Step 3:** Parse-validate both files.

**Verify:** Re-run `analyze-input-latency.ps1` on the existing EXP13 ETL — stutter count should be ~0.

```json:metadata
{"files": ["scripts/analyze-input-latency.ps1", "scripts/pipeline-helpers.ps1"], "verifyCommand": "powershell -ExecutionPolicy Bypass -File scripts/analyze-input-latency.ps1 -EtlFile captures\\experiments\\20260402_131351_EXP13_INPUT_LATENCY\\trace.etl", "acceptanceCriteria": ["Idle stutter count drops to ~0", "Frames >50ms filtered as idle", "0 parse errors"]}
```

---

## Task 2: EXP15 Mitigation Script — Autologgers + Defender + NVIDIA Power

**Goal:** Create `exp15_latency_mitigations_apply.ps1` that applies all research-backed fixes with backup/rollback.

**Files:**
- Create: `scripts/exp15_latency_mitigations_apply.ps1`

**Mitigations to apply:**

1. **Disable LwtNetLog autologger** (reduces DPC latency 5-15%)
   - Key: `HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\LwtNetLog`
   - Value: `Start` = 0

2. **Disable DiagTrack-Listener autologger** (cuts telemetry respawns)
   - Key: `HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\Diagtrack-Listener`
   - Value: `Start` = 0

3. **Add Defender game process exclusions** (reduces real-time scan overhead during gaming)
   - `Add-MpPreference -ExclusionProcess "FPSAimTrainer.exe"`
   - `Add-MpPreference -ExclusionProcess "cs2.exe"`
   - `Add-MpPreference -ExclusionProcess "dwm.exe"`

4. **Add Defender path exclusions** (shader cache + game directories)
   - NVIDIA shader cache: `$env:LOCALAPPDATA + '\NVIDIA\DXCache'`
   - D3D shader cache: `$env:LOCALAPPDATA + '\D3DSCache'`
   - Steam common: `C:\Program Files (x86)\Steam\steamapps\common`

5. **Set NVIDIA Power Management to Prefer Maximum Performance** (fixes RTX 5070 Ti bus load)
   - Key: `HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0001`
   - Value: `PerfLevelSrc` = 0x2222 (max performance all states)
   - Note: This is the registry equivalent of NVIDIA CP "Prefer Maximum Performance"

**Pattern:** Follow `exp13_fso_mitigation_apply.ps1` — backup → apply → verify → rollback commands.

**Acceptance Criteria:**
- [ ] Backup file captures pre-change state of all modified keys
- [ ] Rollback commands section allows reverting all changes
- [ ] LwtNetLog and DiagTrack disabled (Start=0)
- [ ] Defender exclusions added (verified via Get-MpPreference)
- [ ] Parser: 0 errors

**Verify:** Run the script, then `audit.ps1 -Mode Deep` to confirm no regression.

```json:metadata
{"files": ["scripts/exp15_latency_mitigations_apply.ps1"], "verifyCommand": "powershell -ExecutionPolicy Bypass -Command \"[System.Management.Automation.Language.Parser]::ParseFile('scripts\\exp15_latency_mitigations_apply.ps1',[ref]$null,[ref]$e);$e.Count\"", "acceptanceCriteria": ["Backup file created", "Autologgers disabled", "Defender exclusions added", "Rollback commands present", "0 parse errors"]}
```

---

## Task 3: ProcMon Duration Config + Enhanced Capture

**Goal:** Create a ProcMon config that includes the Duration column, and update the capture pipeline to use it.

**Files:**
- Modify: `scripts/pipeline-helpers.ps1` (Invoke-ProcMonCapture + Convert-ProcMonToCSV)

**Problem:** ProcMon's default export excludes the Duration column. We need to pass `/LoadConfig` with a config that has Duration enabled. Since PMC files are binary and can only be created via ProcMon GUI, the approach is:

1. Create the PMC file interactively (one-time setup step)
2. Store it at `scripts/procmon_gaming.pmc`
3. Update `Invoke-ProcMonCapture` to use `/LoadConfig` when the PMC exists

**Steps:**

- [ ] **Step 1:** Add a one-time PMC creation helper. Since we can't create binary PMC files from PowerShell, add a function `Initialize-ProcMonConfig` that launches ProcMon with instructions for the user to configure Duration column and save the config. If `scripts/procmon_gaming.pmc` already exists, skip.

- [ ] **Step 2:** Update `Invoke-ProcMonCapture` (~line 324) to pass `/LoadConfig` when `scripts/procmon_gaming.pmc` exists:
```powershell
$pmcFile = Join-Path $PSScriptRoot 'procmon_gaming.pmc'
$pmArgs = '/AcceptEula /BackingFile "' + $pmlFile + '" /Runtime ' + $DurationSec + ' /Quiet /Minimized'
if (Test-Path $pmcFile) {
    $pmArgs = '/AcceptEula /LoadConfig "' + $pmcFile + '" /BackingFile "' + $pmlFile + '" /Runtime ' + $DurationSec + ' /Quiet /Minimized'
}
```

- [ ] **Step 3:** Update `Analyze-ProcMonCSV` to properly handle the Duration column when present (it already tries to parse Duration but the column wasn't there). No code change needed — the existing Duration parsing at ~line 464 will work once the column is present in the CSV.

- [ ] **Step 4:** Parse-validate.

**Verify:** Check that ProcMon starts with config loaded (when PMC exists) or falls back cleanly (when it doesn't).

```json:metadata
{"files": ["scripts/pipeline-helpers.ps1"], "verifyCommand": "powershell -ExecutionPolicy Bypass -Command \"[System.Management.Automation.Language.Parser]::ParseFile('scripts\\pipeline-helpers.ps1',[ref]$null,[ref]$e);$e.Count\"", "acceptanceCriteria": ["Invoke-ProcMonCapture uses LoadConfig when PMC exists", "Falls back to default when no PMC", "0 parse errors"]}
```

---

## Task 4: Defender Performance Recording Integration

**Goal:** Add `New-MpPerformanceRecording` to the pipeline capture for measuring Defender's impact during gameplay.

**Files:**
- Modify: `scripts/pipeline-helpers.ps1` (new function)
- Modify: `scripts/pipeline.ps1` (call it alongside other captures)

**Steps:**

- [ ] **Step 1:** Add `Invoke-DefenderRecording` function to `pipeline-helpers.ps1`:
```powershell
function Invoke-DefenderRecording {
    param([string]$OutDir, [int]$DurationSec)
    $defEtl = Join-Path $OutDir 'defender_perf.etl'
    try {
        # Start recording (non-blocking — runs as a job)
        $job = Start-Job -ScriptBlock {
            param($path)
            New-MpPerformanceRecording -RecordTo $path
        } -ArgumentList $defEtl
        Log 'Defender performance recording started' 'PASS'
        return @{ job = $job; etlPath = $defEtl }
    } catch {
        Log ('Defender recording failed: ' + $_.Exception.Message) 'WARN'
        return $null
    }
}
```

- [ ] **Step 2:** Add `Stop-DefenderRecording` function that stops the job and analyzes:
```powershell
function Stop-DefenderRecording {
    param($RecordingInfo, [string]$OutDir)
    if ($null -eq $RecordingInfo) { return $null }
    Stop-Job $RecordingInfo.job -ErrorAction SilentlyContinue
    # Analyze if ETL was created
    if (Test-Path $RecordingInfo.etlPath) {
        try {
            $report = Get-MpPerformanceReport -Path $RecordingInfo.etlPath -TopFiles 20 -TopProcesses 10
            # Extract key metrics
            ...
        } catch { ... }
    }
}
```

- [ ] **Step 3:** Integrate into `pipeline.ps1` — start before perf counters, stop after WPR.

- [ ] **Step 4:** Parse-validate both files.

**Verify:** Run a short pipeline capture, confirm `defender_perf.etl` is generated.

```json:metadata
{"files": ["scripts/pipeline-helpers.ps1", "scripts/pipeline.ps1"], "verifyCommand": "powershell -ExecutionPolicy Bypass -Command \"[System.Management.Automation.Language.Parser]::ParseFile('scripts\\pipeline.ps1',[ref]$null,[ref]$e);$e.Count\"", "acceptanceCriteria": ["Defender recording starts/stops cleanly", "ETL generated when Defender active", "Report extractable via Get-MpPerformanceReport", "0 parse errors"]}
```

---

## Task 5: New Audit Checks from Research

**Goal:** Add audit checks for the newly discovered issues.

**Files:**
- Modify: `scripts/audit-checks.ps1`

**New checks:**

1. **Check 34: NVIDIA Power Management** (Quick tier)
   - Read `HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0001\PerfLevelSrc`
   - PASS if 0x2222 (max performance)
   - WARN if not set or other value
   - Fix: link to exp15 script

2. **Check 35: LwtNetLog Autologger** (Deep tier)
   - Read `HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\LwtNetLog\Start`
   - PASS if 0 (disabled)
   - WARN if 1 (enabled)
   - Fix: `Set-ItemProperty ... -Value 0`

3. **Check 36: DiagTrack Autologger** (Deep tier)
   - Same pattern for `Diagtrack-Listener`

4. **Check 37: Defender Shader Cache Exclusion** (Deep tier)
   - Check if NVIDIA DXCache and D3DSCache paths are in ExclusionPath
   - PASS if both excluded
   - WARN if missing

**Verify:** `audit.ps1 -Mode Deep` shows new checks.

```json:metadata
{"files": ["scripts/audit-checks.ps1", "scripts/audit.ps1"], "verifyCommand": "powershell -ExecutionPolicy Bypass -File scripts/audit.ps1 -Mode Deep", "acceptanceCriteria": ["4 new checks appear", "NVIDIA power check works", "Autologger checks work", "Shader cache exclusion check works", "0 parse errors"]}
```

---

## Task 6: End-to-End Test + Commit

**Goal:** Run all mitigations, capture, and verify.

**Steps:**

- [ ] **Step 1:** Parse-validate all modified scripts
- [ ] **Step 2:** Run `exp15_latency_mitigations_apply.ps1`
- [ ] **Step 3:** Run `audit.ps1 -Mode Deep` — verify new checks + mitigations applied
- [ ] **Step 4:** Run short pipeline capture: `pipeline.ps1 -Label EXP15_POST_MITIGATION -Description "Post-mitigation baseline" -DurationSec 15 -WPRProfile InputLatency`
- [ ] **Step 5:** Verify stutter count is ~0 at idle
- [ ] **Step 6:** Open HTML report — confirm new data panels
- [ ] **Step 7:** Commit all changes

```json:metadata
{"files": ["scripts/exp15_latency_mitigations_apply.ps1", "scripts/audit-checks.ps1", "scripts/audit.ps1", "scripts/pipeline-helpers.ps1", "scripts/pipeline.ps1", "scripts/analyze-input-latency.ps1"], "verifyCommand": "powershell -ExecutionPolicy Bypass -File scripts/audit.ps1 -Mode Deep", "acceptanceCriteria": ["All scripts parse clean", "Mitigations applied", "Stutter false positives fixed", "New audit checks pass", "HTML report opens correctly"], "requiresUserVerification": true, "userVerificationPrompt": "Run audit.ps1 -Mode Deep and check the HTML report. Do the new checks appear? Is the score still high?"}
```

---

## Dependency Order

```
Task 1 (fix stutter detector)  ─┐
Task 2 (EXP15 mitigations)     ─┼─> Task 5 (new audit checks) ─> Task 6 (test + commit)
Task 3 (ProcMon Duration)      ─┤
Task 4 (Defender recording)    ─┘
```

Tasks 1-4 can run in parallel. Task 5 depends on 2 (checks verify mitigation state). Task 6 is the final integration test.
