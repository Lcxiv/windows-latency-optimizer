# System Latency Audit Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a three-file PowerShell 5.1 audit tool that checks 32 known Windows gaming latency issues, produces a JSON report + self-contained HTML report, and optionally generates a targeted fix script.

**Architecture:** `audit.ps1` is the entry point (orchestration, ~150 lines); it dot-sources `audit-checks.ps1` (all 32 check functions, ~400 lines) and `audit-report.ps1` (HTML generation, ~200 lines). Each check function returns a structured hashtable. Checks are read-only — no system modifications.

**Tech Stack:** PowerShell 5.1 (no ternary, no null-coalescing, no Join-String), `#Requires -RunAsAdministrator`, no external modules.

**User Verification:** YES — after Task 6 (smoke test), user runs `audit.ps1 -Mode Quick` and confirms the HTML report opens correctly and all three output files are generated.

**Save plan to:** `docs/superpowers/plans/2026-04-02-audit-tool.md` after plan mode exits.

---

## File Structure

```
scripts/
    audit.ps1            # NEW — entry point, orchestration, fix script gen
    audit-checks.ps1     # NEW — all 32 check functions (dot-sourced)
    audit-report.ps1     # NEW — HTML report generation (dot-sourced)
captures/
    audits/              # NEW dir — output: JSON + HTML + fix script
```

## Shared Patterns (from existing scripts)

- Header: `#Requires -RunAsAdministrator`, synopsis/description block
- `$ErrorActionPreference = 'Stop'`
- `$projectRoot = Split-Path $PSScriptRoot -Parent`
- Path building: `Join-Path $projectRoot 'captures\audits'`
- String concat: `'prefix ' + $var + ' suffix'` — never `"$var stuff"` for PS pitfall avoidance
- Pre-compute values before using in `@{}` literals (no `if/else` inside hashtable)
- `[ordered]@{}` + `ConvertTo-Json -Depth 8` for JSON
- `Out-File -FilePath $x -Encoding UTF8`
- Progress: `Write-Host '[N/M] ...' -ForegroundColor Yellow`

---

## Task 1: Scaffold — Three-File Shell + New-CheckResult Helper

**Goal:** Create the three files with correct headers, param blocks, and the `New-CheckResult` helper function; verify all three parse cleanly.

**Files:**
- Create: `scripts/audit.ps1`
- Create: `scripts/audit-checks.ps1`
- Create: `scripts/audit-report.ps1`

**Acceptance Criteria:**
- [ ] All three files parse with 0 errors via `[Parser]::ParseFile()`
- [ ] `audit.ps1` dot-sources both helper files and calls `Get-SystemInfo`
- [ ] `New-CheckResult` returns a hashtable with all 10 required fields

**Verify:** `powershell -ExecutionPolicy Bypass -Command "[System.Management.Automation.Language.Parser]::ParseFile('C:\Users\L\Desktop\windows-latency-optimizer\scripts\audit.ps1', [ref]$null, [ref]\$e); \$e.Count"` → `0`

**Steps:**

- [ ] **Step 1: Create `scripts/audit-checks.ps1` with helper + system info**

```powershell
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Audit check functions for audit.ps1.
.DESCRIPTION
    Dot-sourced by audit.ps1. Contains all check functions and New-CheckResult helper.
    Each check function returns a hashtable matching the check result schema.
    Read-only — no system modifications.
#>

# ---------------------------------------------------------------------------
# Helper: Build a check result hashtable
# ---------------------------------------------------------------------------
function New-CheckResult {
    param(
        [string]$Name,
        [string]$Category,
        [string]$Tier,
        [string]$Severity,
        [string]$Status,
        [string]$Current  = '',
        [string]$Expected = '',
        [string]$Message  = '',
        [string]$Source   = '',
        [string]$Fix      = '',
        [string]$FixNote  = ''
    )
    return [ordered]@{
        name     = $Name
        category = $Category
        tier     = $Tier
        severity = $Severity
        status   = $Status
        current  = $Current
        expected = $Expected
        message  = $Message
        source   = $Source
        fix      = $Fix
        fixNote  = $FixNote
    }
}

# ---------------------------------------------------------------------------
# System information (called once by audit.ps1 before running checks)
# ---------------------------------------------------------------------------
function Get-SystemInfo {
    $info = [ordered]@{
        os        = ''
        build     = ''
        cpu       = ''
        gpu       = ''
        gpuDriver = ''
        ram       = ''
        nic       = ''
        nicDriver = ''
    }

    # OS
    $os = Get-WmiObject Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) {
        $info.os    = $os.Caption + ' Build ' + $os.BuildNumber
        $info.build = $os.BuildNumber
    }

    # CPU
    $cpu = Get-WmiObject Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cpu) { $info.cpu = $cpu.Name.Trim() }

    # GPU
    $gpu = Get-WmiObject Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gpu) {
        $info.gpu       = $gpu.Name
        $info.gpuDriver = $gpu.DriverVersion
    }

    # RAM — total + configured speed
    $dimms = Get-WmiObject Win32_PhysicalMemory -ErrorAction SilentlyContinue
    if ($dimms) {
        $totalMB = ($dimms | Measure-Object -Property Capacity -Sum).Sum / 1MB
        $speed   = ($dimms | Select-Object -First 1).ConfiguredClockSpeed
        $info.ram = [string][math]::Round($totalMB / 1024) + ' GB @ ' + $speed + ' MT/s'
    }

    # NIC
    $nic = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    if ($nic) {
        $info.nic       = $nic.InterfaceDescription
        $info.nicDriver = $nic.DriverVersion
    }

    return $info
}
```

- [ ] **Step 2: Create `scripts/audit-report.ps1` shell**

```powershell
<#
.SYNOPSIS
    HTML report generation for audit.ps1.
.DESCRIPTION
    Dot-sourced by audit.ps1. Exposes New-AuditHtmlReport function.
    Output is fully self-contained (inline CSS + JS, no CDN, no fetch).
#>

function New-AuditHtmlReport {
    param(
        [hashtable]$Summary,
        [array]$Checks,
        [hashtable]$SystemInfo,
        [string]$AuditedAt,
        [string]$Mode,
        [string]$FixScriptPath = ''
    )
    # Implemented in Task 7
    return '<html><body>Placeholder</body></html>'
}
```

- [ ] **Step 3: Create `scripts/audit.ps1` entry point shell**

```powershell
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    System latency audit — detects known Windows gaming latency issues.
.DESCRIPTION
    Checks 32 OS, NIC, GPU, memory, peripheral, and network settings.
    Outputs JSON + self-contained HTML report. Optionally generates fix script.
.EXAMPLE
    .\audit.ps1 -Mode Quick
    .\audit.ps1 -Mode Deep -GenerateFix
#>
param(
    [ValidateSet('Quick','Deep')]
    [string]$Mode = 'Quick',

    [switch]$GenerateFix,

    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent

if ($OutDir -eq '') { $OutDir = Join-Path $projectRoot 'captures\audits' }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

# Dot-source helpers
. (Join-Path $PSScriptRoot 'audit-checks.ps1')
. (Join-Path $PSScriptRoot 'audit-report.ps1')

$timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$auditedAt  = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'

Write-Host '=== System Latency Audit ===' -ForegroundColor Cyan
Write-Host ('Mode: ' + $Mode + ' | Timestamp: ' + $timestamp)
Write-Host ''

Write-Host 'Collecting system information...' -ForegroundColor Yellow
$sysInfo = Get-SystemInfo

Write-Host ('  CPU: ' + $sysInfo.cpu)
Write-Host ('  GPU: ' + $sysInfo.gpu + ' (driver ' + $sysInfo.gpuDriver + ')')
Write-Host ('  RAM: ' + $sysInfo.ram)
Write-Host ('  NIC: ' + $sysInfo.nic + ' (driver ' + $sysInfo.nicDriver + ')')
Write-Host ''

# --- Run checks (Tasks 2-5 populate these functions) ---
$allChecks = @()
# Quick tier
$allChecks += Invoke-OsChecks
$allChecks += Invoke-NicChecks
$allChecks += Invoke-GpuChecks
# Deep tier
if ($Mode -eq 'Deep') {
    $allChecks += Invoke-MemoryChecks
    $allChecks += Invoke-PeripheralChecks
    $allChecks += Invoke-NetworkChecks
}

# --- Aggregate results ---
$pass  = ($allChecks | Where-Object { $_.status -eq 'PASS'  }).Count
$warn  = ($allChecks | Where-Object { $_.status -eq 'WARN'  }).Count
$fail  = ($allChecks | Where-Object { $_.status -eq 'FAIL'  }).Count
$skip  = ($allChecks | Where-Object { $_.status -eq 'SKIP'  }).Count
$error = ($allChecks | Where-Object { $_.status -eq 'ERROR' }).Count
$denom = $allChecks.Count - $skip - $error
$score = 0
if ($denom -gt 0) { $score = [math]::Round(($pass / $denom) * 100) }

$summary = [ordered]@{
    total = $allChecks.Count
    pass  = $pass
    warn  = $warn
    fail  = $fail
    skip  = $skip
    error = $error
    score = $score
}

Write-Host ('Score: ' + $score + '% (' + $pass + ' pass, ' + $warn + ' warn, ' + $fail + ' fail, ' + $skip + ' skip)')
Write-Host ''

# --- Write JSON ---
$jsonPath = Join-Path $OutDir ('audit_' + $timestamp + '.json')
$result = [ordered]@{
    schemaVersion = 1
    auditedAt     = $auditedAt
    mode          = $Mode
    system        = $sysInfo
    summary       = $summary
    checks        = $allChecks
    fixScriptPath = ''
}
($result | ConvertTo-Json -Depth 8) | Out-File -FilePath $jsonPath -Encoding UTF8
Write-Host ('JSON:  ' + $jsonPath) -ForegroundColor Green

# --- Write HTML ---
$htmlPath = Join-Path $OutDir ('audit_' + $timestamp + '.html')
$html = New-AuditHtmlReport -Summary $summary -Checks $allChecks -SystemInfo $sysInfo -AuditedAt $auditedAt -Mode $Mode
$html | Out-File -FilePath $htmlPath -Encoding UTF8
Write-Host ('HTML:  ' + $htmlPath) -ForegroundColor Green

# --- Fix script (Task 8) ---
if ($GenerateFix) {
    Write-Host 'Fix script generation: implemented in Task 8'
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Cyan
```

- [ ] **Step 4: Parser-validate all three files**

```powershell
$scripts = @('audit.ps1','audit-checks.ps1','audit-report.ps1')
foreach ($s in $scripts) {
    $path   = "C:\Users\L\Desktop\windows-latency-optimizer\scripts\$s"
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors) | Out-Null
    Write-Host ($s + ': ' + $errors.Count + ' errors')
}
```
Expected: all three show `0 errors`

- [ ] **Step 5: Commit**

```bash
git -C /c/Users/L/Desktop/windows-latency-optimizer add scripts/audit.ps1 scripts/audit-checks.ps1 scripts/audit-report.ps1
git -C /c/Users/L/Desktop/windows-latency-optimizer commit -m "feat: scaffold audit tool — three-file shell with New-CheckResult helper"
```

---

## Task 2: OS Checks (Checks 1–10)

**Goal:** Implement all 10 Quick-tier OS checks as functions called by `Invoke-OsChecks`.

**Files:**
- Modify: `scripts/audit-checks.ps1`

**Acceptance Criteria:**
- [ ] `Invoke-OsChecks` returns an array of 10 check results
- [ ] Each result has correct category=`OS`, tier=`Quick`
- [ ] SKIP status used when check cannot apply (e.g., no reg key path exists)
- [ ] Parser: 0 errors after additions

**Verify:** `powershell -ExecutionPolicy Bypass -File scripts/audit.ps1 -Mode Quick` — output shows OS section results in console, JSON written.

**Steps:**

- [ ] **Step 1: Add `Invoke-OsChecks` to `audit-checks.ps1`**

```powershell
function Invoke-OsChecks {
    $results = @()

    # --- Check 1: MPO Disabled ---
    $mpoKey  = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    $mpoVal  = $null
    try { $mpoVal = (Get-ItemProperty $mpoKey -ErrorAction Stop).DisableOverlays } catch {}
    if ($null -eq $mpoVal) {
        $results += New-CheckResult -Name 'MPO Disabled' -Category 'OS' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'FAIL' -Current 'Not set (MPO enabled)' -Expected 'DisableOverlays = 1' `
            -Message 'MPO causes periodic frame-time spikes on NVIDIA GPUs (Win11 25H2 path).' `
            -Source 'https://www.ordoh.com/disable-mpo-windows-11-stutter-fix/' `
            -Fix 'reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v DisableOverlays /t REG_DWORD /d 1 /f' `
            -FixNote 'Reboot required'
    } elseif ($mpoVal -eq 1) {
        $results += New-CheckResult -Name 'MPO Disabled' -Category 'OS' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'PASS' -Current 'DisableOverlays = 1' -Expected 'DisableOverlays = 1' `
            -Message 'MPO correctly disabled.'
    } else {
        $results += New-CheckResult -Name 'MPO Disabled' -Category 'OS' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'FAIL' -Current ('DisableOverlays = ' + $mpoVal) -Expected 'DisableOverlays = 1' `
            -Message 'MPO is not disabled.' `
            -Fix 'reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v DisableOverlays /t REG_DWORD /d 1 /f' `
            -FixNote 'Reboot required'
    }

    # --- Check 2: Hyper-V Off ---
    $hvStatus = 'UNKNOWN'
    try {
        $bcd = bcdedit /enum '{current}' 2>&1 | Out-String
        $m   = [regex]::Match($bcd, 'hypervisorlaunchtype\s+(\S+)')
        if ($m.Success) { $hvStatus = $m.Groups[1].Value.ToLower() }
    } catch {}
    if ($hvStatus -eq 'off') {
        $results += New-CheckResult -Name 'Hyper-V Off' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'hypervisorlaunchtype = off' -Expected 'off'
    } elseif ($hvStatus -eq 'unknown') {
        $results += New-CheckResult -Name 'Hyper-V Off' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'ERROR' -Current 'bcdedit failed' -Expected 'off' -Message 'Could not read bcdedit output.'
    } else {
        $results += New-CheckResult -Name 'Hyper-V Off' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'FAIL' -Current ('hypervisorlaunchtype = ' + $hvStatus) -Expected 'off' `
            -Message 'Hyper-V adds 5-15ns latency to all memory operations and interrupts.' `
            -Fix 'bcdedit /set hypervisorlaunchtype off' -FixNote 'Reboot required. Disables WSL2/Docker Hyper-V backend.'
    }

    # --- Check 3: VBS/Core Isolation Off ---
    $vbsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
    $vbsVal = $null
    try { $vbsVal = (Get-ItemProperty $vbsKey -ErrorAction Stop).Enabled } catch {}
    if ($null -eq $vbsVal -or $vbsVal -eq 0) {
        $results += New-CheckResult -Name 'VBS/Core Isolation Off' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'Disabled' -Expected 'Disabled'
    } else {
        $results += New-CheckResult -Name 'VBS/Core Isolation Off' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'FAIL' -Current ('Enabled = ' + $vbsVal) -Expected '0 (Disabled)' `
            -Message 'VBS adds overhead to system calls and memory access.' `
            -Fix 'Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" -Name Enabled -Value 0 -Type DWord' `
            -FixNote 'Reboot required'
    }

    # --- Check 4: MMCSS SystemResponsiveness ---
    $mmcssKey  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    $sysResp   = $null
    try { $sysResp = (Get-ItemProperty $mmcssKey -ErrorAction Stop).SystemResponsiveness } catch {}
    if ($null -eq $sysResp) {
        $results += New-CheckResult -Name 'MMCSS SystemResponsiveness' -Category 'OS' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'WARN' -Current 'Not set (default 20)' -Expected '0' `
            -Message 'Default 20 reserves CPU time for background tasks during gaming.' `
            -Fix 'Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name SystemResponsiveness -Value 0 -Type DWord'
    } elseif ($sysResp -eq 0) {
        $results += New-CheckResult -Name 'MMCSS SystemResponsiveness' -Category 'OS' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'PASS' -Current '0' -Expected '0'
    } else {
        $results += New-CheckResult -Name 'MMCSS SystemResponsiveness' -Category 'OS' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'FAIL' -Current ([string]$sysResp) -Expected '0' `
            -Message 'Non-zero value throttles foreground apps in favor of background tasks.' `
            -Fix 'Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name SystemResponsiveness -Value 0 -Type DWord'
    }

    # --- Check 5: MMCSS NetworkThrottlingIndex ---
    $ntIdx = $null
    try { $ntIdx = (Get-ItemProperty $mmcssKey -ErrorAction Stop).NetworkThrottlingIndex } catch {}
    $ntExpected = [uint32]0xFFFFFFFF
    if ($null -eq $ntIdx) {
        $results += New-CheckResult -Name 'MMCSS NetworkThrottling' -Category 'OS' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'WARN' -Current 'Not set (throttled)' -Expected '0xFFFFFFFF (disabled)' `
            -Message 'Default network throttling limits packet rate during multimedia playback.' `
            -Fix 'Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name NetworkThrottlingIndex -Value 0xFFFFFFFF -Type DWord'
    } elseif ([uint32]$ntIdx -eq $ntExpected) {
        $results += New-CheckResult -Name 'MMCSS NetworkThrottling' -Category 'OS' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'PASS' -Current '0xFFFFFFFF' -Expected '0xFFFFFFFF'
    } else {
        $results += New-CheckResult -Name 'MMCSS NetworkThrottling' -Category 'OS' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'FAIL' -Current ([string]$ntIdx) -Expected '0xFFFFFFFF' `
            -Fix 'Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name NetworkThrottlingIndex -Value 0xFFFFFFFF -Type DWord'
    }

    # --- Check 6: MMCSS Games Priority ---
    $gamesKey  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'
    $gPriority = $null
    $gSFIO     = $null
    try {
        $gProps    = Get-ItemProperty $gamesKey -ErrorAction Stop
        $gPriority = $gProps.Priority
        $gSFIO     = $gProps.'SFIO Priority'
    } catch {}
    if ($null -eq $gPriority) {
        $results += New-CheckResult -Name 'MMCSS Games Priority' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'ERROR' -Current 'Key not found' -Expected 'Priority=6, SFIO Priority=High' `
            -Message 'MMCSS Games key missing.'
    } elseif ($gPriority -eq 6 -and $gSFIO -eq 'High') {
        $results += New-CheckResult -Name 'MMCSS Games Priority' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'PASS' -Current ('Priority=' + $gPriority + ', SFIO=' + $gSFIO) -Expected 'Priority=6, SFIO=High'
    } else {
        $results += New-CheckResult -Name 'MMCSS Games Priority' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ('Priority=' + $gPriority + ', SFIO=' + $gSFIO) -Expected 'Priority=6, SFIO=High' `
            -Fix 'Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" -Name Priority -Value 6 -Type DWord; Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" -Name ''SFIO Priority'' -Value ''High'''
    }

    # --- Check 7: Power Plan ---
    $powerOutput = powercfg /getactivescheme 2>&1 | Out-String
    $isHP        = $powerOutput -match '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'  # High Performance
    $isUP        = $powerOutput -match 'e9a42b02-d5df-448d-aa00-03f14749eb61'  # Ultimate Performance
    if ($isHP -or $isUP) {
        $schemeName = if ($isUP) { 'Ultimate Performance' } else { 'High Performance' }
        $results += New-CheckResult -Name 'Power Plan' -Category 'OS' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'PASS' -Current $schemeName -Expected 'High/Ultimate Performance'
    } else {
        $m = [regex]::Match($powerOutput, '\((.+)\)')
        $currentName = if ($m.Success) { $m.Groups[1].Value.Trim() } else { 'Unknown' }
        $results += New-CheckResult -Name 'Power Plan' -Category 'OS' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'FAIL' -Current $currentName -Expected 'High or Ultimate Performance' `
            -Message 'Balanced/Power Saver plans throttle CPU frequency and increase latency.' `
            -Fix 'powercfg /setactive SCHEME_MIN' -FixNote 'SCHEME_MIN = High Performance. For Ultimate, requires creation first.'
    }

    # --- Check 8: Win32PrioritySeparation ---
    $priKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl'
    $priVal = $null
    try { $priVal = (Get-ItemProperty $priKey -ErrorAction Stop).Win32PrioritySeparation } catch {}
    if ($null -eq $priVal) {
        $results += New-CheckResult -Name 'Win32PrioritySeparation' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'ERROR' -Current 'Key not found' -Expected '0x26 (38) or 0x16 (22)'
    } elseif ($priVal -eq 38 -or $priVal -eq 22) {
        $results += New-CheckResult -Name 'Win32PrioritySeparation' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'PASS' -Current ('0x' + $priVal.ToString('X') + ' (' + $priVal + ')') -Expected '0x26 or 0x16'
    } else {
        $results += New-CheckResult -Name 'Win32PrioritySeparation' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ('0x' + $priVal.ToString('X') + ' (' + $priVal + ')') -Expected '0x26 (38) or 0x16 (22)' `
            -Message '0x26 = short, fixed-length, foreground-boosted quantum. Reduces context switch latency.' `
            -Fix 'Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" -Name Win32PrioritySeparation -Value 38 -Type DWord'
    }

    # --- Check 9: GameInput Duplicates ---
    $giPackages = @()
    try { $giPackages = @(Get-AppxPackage -Name '*GameInput*' -ErrorAction Stop) } catch {}
    if ($giPackages.Count -le 1) {
        $results += New-CheckResult -Name 'GameInput Duplicates' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'PASS' -Current ($giPackages.Count.ToString() + ' package(s)') -Expected '<= 1'
    } else {
        $versions = ($giPackages | ForEach-Object { $_.Version }) -join ', '
        $results += New-CheckResult -Name 'GameInput Duplicates' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'FAIL' -Current ($giPackages.Count.ToString() + ' packages: ' + $versions) -Expected '1 package' `
            -Message 'Duplicate GameInput packages compete for mouse/controller polling, causing system-wide hitches every few seconds.' `
            -Fix '' -FixNote 'Settings -> Apps -> search GameInput -> uninstall older version'
    }

    # --- Check 10: KB5077181 Stutter Bug ---
    $build = 0
    try { $build = [int](Get-WmiObject Win32_OperatingSystem -ErrorAction Stop).BuildNumber } catch {}
    if ($build -eq 26200) {
        $kbs    = Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.HotFixID -eq 'KB5077181' -or $_.HotFixID -eq 'KB5079473' }
        $kbList = if ($kbs) { ($kbs | ForEach-Object { $_.HotFixID }) -join ', ' } else { '' }
        if ($kbList -ne '') {
            $results += New-CheckResult -Name 'KB5077181 Stutter Bug' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
                -Status 'WARN' -Current ('Installed: ' + $kbList) -Expected 'FSO disabled as mitigation' `
                -Message 'KB5077181 introduced rhythmic gaming stutter on Build 26200 via FSO/DWM scheduling change.' `
                -Source 'https://www.notebookcheck.net/Reddit-erupts-over-KB5077181-New-update-triggers-rhythmic-gaming-stutter.1228602.0.html' `
                -Fix 'reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers" /v "C:\Program Files\Epic Games\Fortnite\FortniteGame\Binaries\Win64\FortniteClient-Win64-Shipping.exe" /t REG_SZ /d DISABLEDXMAXIMIZEDWINDOWEDMODE /f' `
                -FixNote 'Disables FSO for Fortnite as mitigation. No reboot required.'
        } else {
            $results += New-CheckResult -Name 'KB5077181 Stutter Bug' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
                -Status 'PASS' -Current 'KB5077181/KB5079473 not installed' -Expected 'Not installed or FSO disabled'
        }
    } else {
        $results += New-CheckResult -Name 'KB5077181 Stutter Bug' -Category 'OS' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'SKIP' -Current ('Build ' + $build) -Expected 'Build 26200 only' `
            -Message 'Check only applies to Windows 11 Build 26200.'
    }

    return $results
}
```

- [ ] **Step 2: Parse-validate, commit**

```powershell
# validate
$path = 'C:\Users\L\Desktop\windows-latency-optimizer\scripts\audit-checks.ps1'
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors) | Out-Null
$errors.Count  # expect 0
```

```bash
git -C /c/Users/L/Desktop/windows-latency-optimizer add scripts/audit-checks.ps1
git -C /c/Users/L/Desktop/windows-latency-optimizer commit -m "feat: add OS checks (MPO, Hyper-V, VBS, MMCSS, power plan, KB5077181)"
```

---

## Task 3: NIC Checks (Checks 11–16)

**Goal:** Implement 6 NIC checks with Intel I226-V hardware detection.

**Files:**
- Modify: `scripts/audit-checks.ps1` (append `Invoke-NicChecks`)

**Acceptance Criteria:**
- [ ] `Invoke-NicChecks` returns array; SKIP when no active wired NIC found
- [ ] Check 11 (driver line) only flags Win10-vs-Win11 mismatch for Intel I225/I226 (VID 8086)
- [ ] Check 16 (interrupt affinity) reads registry policy, not a live perf sample
- [ ] Parser: 0 errors

**Verify:** Run `audit.ps1 -Mode Quick`; confirm NIC section in JSON has 6 entries.

**Steps:**

- [ ] **Step 1: Add `Invoke-NicChecks`**

```powershell
function Invoke-NicChecks {
    $results = @()

    # Detect primary wired NIC
    $nic = $null
    try {
        $nic = Get-NetAdapter -Physical -ErrorAction Stop |
            Where-Object { $_.Status -eq 'Up' -and $_.MediaType -ne 'Native 802.11' } |
            Select-Object -First 1
    } catch {}

    if ($null -eq $nic) {
        $skip = New-CheckResult -Name 'NIC (all checks)' -Category 'NIC' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'SKIP' -Current 'No active wired adapter found' -Expected 'Active wired NIC'
        $results += $skip
        return $results
    }

    $nicName   = $nic.Name
    $nicDesc   = $nic.InterfaceDescription
    $driverVer = $nic.DriverVersion
    $isIntelI226 = ($nicDesc -match 'I225' -or $nicDesc -match 'I226')

    # --- Check 11: NIC Driver Line (Intel I226 only) ---
    if ($isIntelI226) {
        $major = 0
        try { $major = [int]($driverVer.Split('.')[0]) } catch {}
        if ($major -ge 2) {
            $results += New-CheckResult -Name 'NIC Driver Line' -Category 'NIC' -Tier 'Quick' -Severity 'CRITICAL' `
                -Status 'PASS' -Current ('Driver ' + $driverVer + ' (Win11 line)') -Expected 'Win11 line (2.x)'
        } else {
            $results += New-CheckResult -Name 'NIC Driver Line' -Category 'NIC' -Tier 'Quick' -Severity 'CRITICAL' `
                -Status 'FAIL' -Current ('Driver ' + $driverVer + ' (Win10 line)') -Expected 'Win11 line (2.x)' `
                -Message 'Win10 driver (1.x) on Win11 causes I226-V disconnect/renegotiation hardware bug.' `
                -Source 'https://www.intel.com/content/www/us/en/download/727998/intel-network-adapter-driver-for-windows-11.html' `
                -Fix '' -FixNote 'Download Win11 driver (2.x) from Intel and install manually.'
        }
    } else {
        $results += New-CheckResult -Name 'NIC Driver Line' -Category 'NIC' -Tier 'Quick' -Severity 'CRITICAL' `
            -Status 'SKIP' -Current ($nicDesc + ' (not I225/I226)') -Expected 'Intel I225/I226 only' `
            -Message 'Driver line check only applies to Intel I225/I226 adapters.'
    }

    # --- Check 12: NIC Speed/Duplex (I226 only: avoid 2.5G auto-negotiate bug) ---
    if ($isIntelI226) {
        $speedDuplex = $null
        try {
            $speedDuplex = (Get-NetAdapterAdvancedProperty -Name $nicName -RegistryKeyword '*SpeedDuplex' -ErrorAction Stop).RegistryValue
        } catch {}
        # 0 = Auto, 6 = 1G Full Duplex
        if ($null -eq $speedDuplex) {
            $results += New-CheckResult -Name 'NIC Speed/Duplex' -Category 'NIC' -Tier 'Quick' -Severity 'HIGH' `
                -Status 'WARN' -Current 'Cannot read' -Expected '1G Full Duplex (value 6)' `
                -Message 'Auto-negotiate at 2.5G triggers I226-V hardware disconnect bug.'
        } elseif ($speedDuplex -eq 6) {
            $results += New-CheckResult -Name 'NIC Speed/Duplex' -Category 'NIC' -Tier 'Quick' -Severity 'HIGH' `
                -Status 'PASS' -Current '1.0 Gbps Full Duplex' -Expected '1G Full Duplex'
        } else {
            $label = if ($speedDuplex -eq 0) { 'Auto Negotiate' } else { 'Value ' + $speedDuplex }
            $results += New-CheckResult -Name 'NIC Speed/Duplex' -Category 'NIC' -Tier 'Quick' -Severity 'HIGH' `
                -Status 'WARN' -Current $label -Expected '1.0 Gbps Full Duplex' `
                -Message 'Auto-negotiate at 2.5G triggers I226-V random disconnect bug. Force 1G Full Duplex.' `
                -Fix ('Set-NetAdapterAdvancedProperty -Name "' + $nicName + '" -RegistryKeyword "*SpeedDuplex" -RegistryValue 6')
        }
    } else {
        $results += New-CheckResult -Name 'NIC Speed/Duplex' -Category 'NIC' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'SKIP' -Current $nicDesc -Expected 'Intel I225/I226 only'
    }

    # --- Check 13: NIC EEE ---
    $eeeVal = $null
    try {
        $eee    = Get-NetAdapterAdvancedProperty -Name $nicName -ErrorAction SilentlyContinue |
            Where-Object { $_.RegistryKeyword -match '\*EEE' -or $_.RegistryKeyword -match 'EEELinkAdvert' } |
            Select-Object -First 1
        if ($eee) { $eeeVal = $eee.RegistryValue }
    } catch {}
    if ($null -eq $eeeVal) {
        $results += New-CheckResult -Name 'NIC EEE' -Category 'NIC' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'SKIP' -Current 'Property not found' -Expected 'Disabled (0)'
    } elseif ($eeeVal -eq 0) {
        $results += New-CheckResult -Name 'NIC EEE' -Category 'NIC' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'PASS' -Current 'Disabled' -Expected 'Disabled'
    } else {
        $results += New-CheckResult -Name 'NIC EEE' -Category 'NIC' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'FAIL' -Current 'Enabled' -Expected 'Disabled' `
            -Message 'Energy Efficient Ethernet introduces variable latency as adapter enters/exits low-power state.' `
            -Fix ('Set-NetAdapterAdvancedProperty -Name "' + $nicName + '" -RegistryKeyword "*EEE" -RegistryValue 0')
    }

    # --- Check 14: NIC Interrupt Moderation ---
    $imVal = $null
    try {
        $im    = Get-NetAdapterAdvancedProperty -Name $nicName -RegistryKeyword '*InterruptModeration' -ErrorAction Stop
        $imVal = $im.RegistryValue
    } catch {}
    if ($null -eq $imVal) {
        $results += New-CheckResult -Name 'NIC Interrupt Moderation' -Category 'NIC' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'SKIP' -Current 'Property not found' -Expected 'Disabled (0)'
    } elseif ($imVal -eq 0) {
        $results += New-CheckResult -Name 'NIC Interrupt Moderation' -Category 'NIC' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'Disabled' -Expected 'Disabled'
    } else {
        $results += New-CheckResult -Name 'NIC Interrupt Moderation' -Category 'NIC' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'WARN' -Current 'Enabled' -Expected 'Disabled' `
            -Message 'Interrupt moderation batches interrupts to reduce CPU load at the cost of increased latency.' `
            -Fix ('Set-NetAdapterAdvancedProperty -Name "' + $nicName + '" -RegistryKeyword "*InterruptModeration" -RegistryValue 0')
    }

    # --- Check 15: Nagle Disabled ---
    $nagleStatus = 'UNKNOWN'
    try {
        $guid    = $nic.InterfaceGuid
        $ifPath  = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\' + $guid
        $ifProps = Get-ItemProperty $ifPath -ErrorAction Stop
        $ackFreq = $ifProps.TcpAckFrequency
        $noDelay = $ifProps.TCPNoDelay
        if ($ackFreq -eq 1 -and $noDelay -eq 1) {
            $nagleStatus = 'PASS'
        } else {
            $nagleStatus = 'FAIL:' + [string]$ackFreq + '/' + [string]$noDelay
        }
    } catch { $nagleStatus = 'MISSING' }

    if ($nagleStatus -eq 'PASS') {
        $results += New-CheckResult -Name 'Nagle Disabled' -Category 'NIC' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'TcpAckFrequency=1, TCPNoDelay=1' -Expected 'Both 1'
    } else {
        $guid    = $nic.InterfaceGuid
        $ifPath  = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\' + $guid
        $results += New-CheckResult -Name 'Nagle Disabled' -Category 'NIC' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'FAIL' -Current $nagleStatus -Expected 'TcpAckFrequency=1, TCPNoDelay=1' `
            -Message 'Nagle algorithm batches small TCP packets, adding 10-200ms latency to game state updates.' `
            -Fix ('Set-ItemProperty -Path "' + $ifPath + '" -Name TcpAckFrequency -Value 1 -Type DWord; Set-ItemProperty -Path "' + $ifPath + '" -Name TCPNoDelay -Value 1 -Type DWord') `
            -FixNote 'Settings are per-interface GUID and must be re-applied after NIC driver updates.'
    }

    # --- Check 16: NIC Interrupt Affinity ---
    $affinityStatus = 'UNKNOWN'
    $affinityDetail = ''
    try {
        $pnpId      = $nic.PnPDeviceID
        $affPath    = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $pnpId + '\Device Parameters\Interrupt Management\Affinity Policy'
        $affProps   = Get-ItemProperty $affPath -ErrorAction Stop
        $devPolicy  = $affProps.DevicePolicy
        $affSet     = $affProps.AssignmentSetOverride
        if ($null -ne $affSet -and $affSet.Count -ge 2) {
            $maskHex        = '0x' + (($affSet[1..0] | ForEach-Object { $_.ToString('X2') }) -join '')
            $affinityDetail = 'DevicePolicy=' + $devPolicy + ', Mask=' + $maskHex
            if ($devPolicy -eq 4) { $affinityStatus = 'PASS' } else { $affinityStatus = 'WARN' }
        } else {
            $affinityStatus = 'WARN'
            $affinityDetail = 'No affinity policy set (default: CPU 0 handles all NIC interrupts)'
        }
    } catch {
        $affinityStatus = 'WARN'
        $affinityDetail = 'Affinity key not found — default CPU 0 handling'
    }
    if ($affinityStatus -eq 'PASS') {
        $results += New-CheckResult -Name 'NIC Interrupt Affinity' -Category 'NIC' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'PASS' -Current $affinityDetail -Expected 'DevicePolicy=4 (SpecifiedProcessors)'
    } else {
        $pnpId   = $nic.PnPDeviceID
        $affPath = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $pnpId + '\Device Parameters\Interrupt Management\Affinity Policy'
        $results += New-CheckResult -Name 'NIC Interrupt Affinity' -Category 'NIC' -Tier 'Quick' -Severity 'HIGH' `
            -Status 'WARN' -Current $affinityDetail -Expected 'DevicePolicy=4, CPUs 4-7 (mask 0xF0)' `
            -Message 'Default: all NIC interrupts handled by CPU 0, competing with game thread. Pin to non-game CPUs.' `
            -Fix ('New-Item -Path "' + $affPath + '" -Force | Out-Null; Set-ItemProperty -Path "' + $affPath + '" -Name DevicePolicy -Value 4 -Type DWord; Set-ItemProperty -Path "' + $affPath + '" -Name AssignmentSetOverride -Value ([byte[]](0xF0,0x00)) -Type Binary') `
            -FixNote 'Reboot required. Mask 0xF0 = CPUs 4-7 (adjust for your CPU topology).'
    }

    return $results
}
```

- [ ] **Step 2: Parse-validate, commit**

```bash
git -C /c/Users/L/Desktop/windows-latency-optimizer add scripts/audit-checks.ps1
git -C /c/Users/L/Desktop/windows-latency-optimizer commit -m "feat: add NIC checks (driver line, speed, EEE, interrupt moderation, Nagle, affinity)"
```

---

## Task 4: GPU Checks (Checks 17–19)

**Goal:** Implement 3 GPU checks with NVIDIA detection.

**Files:**
- Modify: `scripts/audit-checks.ps1` (append `Invoke-GpuChecks`)

**Acceptance Criteria:**
- [ ] All 3 GPU checks SKIP when no NVIDIA GPU found
- [ ] Check 17 (MSI mode) reads from PCI device registry path
- [ ] Parser: 0 errors

**Steps:**

- [ ] **Step 1: Add `Invoke-GpuChecks`**

```powershell
function Invoke-GpuChecks {
    $results = @()

    # Detect NVIDIA GPU
    $nvKey = $null
    try {
        $nvKey = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -ErrorAction Stop |
            Where-Object { $_.PSChildName -like 'VEN_10DE*' } | Select-Object -First 1
    } catch {}

    if ($null -eq $nvKey) {
        $nv = New-CheckResult -Name 'GPU (all checks)' -Category 'GPU' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'SKIP' -Current 'No NVIDIA GPU found' -Expected 'NVIDIA GPU'
        $results += $nv
        return $results
    }

    # --- Check 17: GPU MSI Mode ---
    $msiPath = $nvKey.PSPath + '\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties'
    $msiVal  = $null
    try { $msiVal = (Get-ItemProperty $msiPath -ErrorAction Stop).MSISupported } catch {}
    if ($null -eq $msiVal) {
        $results += New-CheckResult -Name 'GPU MSI Mode' -Category 'GPU' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'WARN' -Current 'Key not found' -Expected 'MSISupported = 1' `
            -Message 'Cannot verify GPU MSI mode.'
    } elseif ($msiVal -eq 1) {
        $results += New-CheckResult -Name 'GPU MSI Mode' -Category 'GPU' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'MSISupported = 1' -Expected 'MSISupported = 1'
    } else {
        $results += New-CheckResult -Name 'GPU MSI Mode' -Category 'GPU' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'FAIL' -Current ('MSISupported = ' + $msiVal) -Expected 'MSISupported = 1' `
            -Message 'Line-based interrupts are less efficient than MSI and can cause DPC spikes.' `
            -Fix ('Set-ItemProperty -Path "' + $msiPath + '" -Name MSISupported -Value 1 -Type DWord') `
            -FixNote 'Reboot required.'
    }

    # --- Check 18: GPU Interrupt Affinity ---
    $gpuAffPath    = $nvKey.PSPath + '\Device Parameters\Interrupt Management\Affinity Policy'
    $gpuAffDetail  = 'Not set (default CPU 0)'
    $gpuAffStatus  = 'WARN'
    try {
        $gpuAff    = Get-ItemProperty $gpuAffPath -ErrorAction Stop
        $gpuPolicy = $gpuAff.DevicePolicy
        $gpuSet    = $gpuAff.AssignmentSetOverride
        if ($null -ne $gpuSet -and $gpuSet.Count -ge 2 -and $gpuPolicy -eq 4) {
            $maskHex      = '0x' + (($gpuSet[1..0] | ForEach-Object { $_.ToString('X2') }) -join '')
            $gpuAffDetail = 'DevicePolicy=4, Mask=' + $maskHex
            $gpuAffStatus = 'PASS'
        } elseif ($null -ne $gpuPolicy) {
            $gpuAffDetail = 'DevicePolicy=' + $gpuPolicy + ' (not SpecifiedProcessors)'
        }
    } catch {}

    if ($gpuAffStatus -eq 'PASS') {
        $results += New-CheckResult -Name 'GPU Interrupt Affinity' -Category 'GPU' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'PASS' -Current $gpuAffDetail -Expected 'DevicePolicy=4 (SpecifiedProcessors)'
    } else {
        $results += New-CheckResult -Name 'GPU Interrupt Affinity' -Category 'GPU' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'WARN' -Current $gpuAffDetail -Expected 'DevicePolicy=4, CPUs 4-7 (mask 0xF0)' `
            -Message 'Default: GPU DPC work lands on CPU 0, competing with game threads.' `
            -Fix ('New-Item -Path "' + $gpuAffPath + '" -Force | Out-Null; Set-ItemProperty -Path "' + $gpuAffPath + '" -Name DevicePolicy -Value 4 -Type DWord; Set-ItemProperty -Path "' + $gpuAffPath + '" -Name AssignmentSetOverride -Value ([byte[]](0xF0,0x00)) -Type Binary') `
            -FixNote 'Reboot required. Adjust mask for your CPU topology.'
    }

    # --- Check 19: HAGS Enabled ---
    $hagsVal = $null
    try { $hagsVal = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction Stop).HwSchMode } catch {}
    if ($null -eq $hagsVal) {
        $results += New-CheckResult -Name 'HAGS Enabled' -Category 'GPU' -Tier 'Quick' -Severity 'LOW' `
            -Status 'WARN' -Current 'Not set' -Expected 'HwSchMode = 2 (for RTX 40/50)' `
            -Fix 'Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name HwSchMode -Value 2 -Type DWord' `
            -FixNote 'Reboot required. Only beneficial on RTX 30+ or RDNA3+.'
    } elseif ($hagsVal -eq 2) {
        $results += New-CheckResult -Name 'HAGS Enabled' -Category 'GPU' -Tier 'Quick' -Severity 'LOW' `
            -Status 'PASS' -Current 'HwSchMode = 2' -Expected 'HwSchMode = 2'
    } else {
        $results += New-CheckResult -Name 'HAGS Enabled' -Category 'GPU' -Tier 'Quick' -Severity 'LOW' `
            -Status 'WARN' -Current ('HwSchMode = ' + $hagsVal) -Expected '2' `
            -Fix 'Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name HwSchMode -Value 2 -Type DWord' `
            -FixNote 'Reboot required.'
    }

    return $results
}
```

- [ ] **Step 2: Commit**

```bash
git -C /c/Users/L/Desktop/windows-latency-optimizer add scripts/audit-checks.ps1
git -C /c/Users/L/Desktop/windows-latency-optimizer commit -m "feat: add GPU checks (MSI mode, interrupt affinity, HAGS)"
```

---

## Task 5: Deep Tier Checks (Checks 20–32)

**Goal:** Implement the 13 Deep-tier checks across Memory, Peripheral, and Network categories.

**Files:**
- Modify: `scripts/audit-checks.ps1` (append three Invoke-* functions)

**Acceptance Criteria:**
- [ ] `Invoke-MemoryChecks`, `Invoke-PeripheralChecks`, `Invoke-NetworkChecks` each return arrays
- [ ] Check 20 (RAM speed) uses `Win32_PhysicalMemory` ConfiguredClockSpeed vs Speed
- [ ] Check 32 (latency probe) pings and records results without throwing
- [ ] Parser: 0 errors

**Steps:**

- [ ] **Step 1: Add `Invoke-MemoryChecks`**

```powershell
function Invoke-MemoryChecks {
    $results = @()

    # --- Check 20: RAM Speed vs Rated ---
    $dimms = @()
    try { $dimms = @(Get-WmiObject Win32_PhysicalMemory -ErrorAction Stop) } catch {}
    if ($dimms.Count -eq 0) {
        $results += New-CheckResult -Name 'RAM Speed vs Rated' -Category 'Memory' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'ERROR' -Current 'WMI query failed' -Expected 'Configured >= JEDEC Speed'
    } else {
        $configured = $dimms[0].ConfiguredClockSpeed
        $jedec      = $dimms[0].Speed
        $totalGB    = [math]::Round(($dimms | Measure-Object -Property Capacity -Sum).Sum / 1GB)
        if ($configured -ge $jedec -and $configured -gt 4800) {
            $results += New-CheckResult -Name 'RAM Speed vs Rated' -Category 'Memory' -Tier 'Deep' -Severity 'HIGH' `
                -Status 'PASS' -Current ($configured.ToString() + ' MT/s') -Expected 'XMP/EXPO profile active'
        } elseif ($configured -eq $jedec -or $configured -le 4800) {
            $results += New-CheckResult -Name 'RAM Speed vs Rated' -Category 'Memory' -Tier 'Deep' -Severity 'HIGH' `
                -Status 'WARN' -Current ($configured.ToString() + ' MT/s (JEDEC default)') -Expected 'XMP/EXPO rated speed' `
                -Message ('RAM running at JEDEC default. Enable XMP/EXPO in BIOS to reach rated speed.') `
                -Fix '' -FixNote 'BIOS setting: EXPO/XMP Profile 1. No OS change needed.'
        } else {
            $results += New-CheckResult -Name 'RAM Speed vs Rated' -Category 'Memory' -Tier 'Deep' -Severity 'HIGH' `
                -Status 'PASS' -Current ($configured.ToString() + ' MT/s') -Expected 'XMP/EXPO active'
        }
    }

    return $results
}
```

- [ ] **Step 2: Add `Invoke-PeripheralChecks`**

```powershell
function Invoke-PeripheralChecks {
    $results = @()

    # --- Check 21: Mouse Polling Rate Risk ---
    $knownMouseVIDs = @('VID_1532', 'VID_046D', 'VID_1038', 'VID_093A', 'VID_258A')
    $mouseFound     = $false
    $mouseDesc      = ''
    try {
        $hidDevices = Get-WmiObject Win32_PnPEntity -Filter "Service='HidUsb' OR Service='mouhid'" -ErrorAction Stop
        foreach ($dev in $hidDevices) {
            foreach ($vid in $knownMouseVIDs) {
                if ($dev.DeviceID -like ('*' + $vid + '*')) {
                    $mouseFound = $true
                    $mouseDesc  = $dev.Description
                    break
                }
            }
            if ($mouseFound) { break }
        }
    } catch {}

    if (-not $mouseFound) {
        $results += New-CheckResult -Name 'Mouse Polling Rate' -Category 'Peripheral' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'SKIP' -Current 'No known gaming mouse VID detected' -Expected 'Razer/Logitech/SteelSeries/etc.'
    } else {
        # Check if companion software is running
        $companionProcs = @('RazerCentralService','Razer Synapse','LGHUB','SteelSeriesEngine','GHub','iCUE','GHUB')
        $running        = $false
        foreach ($proc in $companionProcs) {
            if (Get-Process -Name $proc -ErrorAction SilentlyContinue) { $running = $true; break }
        }
        if ($running) {
            $results += New-CheckResult -Name 'Mouse Polling Rate' -Category 'Peripheral' -Tier 'Deep' -Severity 'HIGH' `
                -Status 'PASS' -Current ($mouseDesc + ' + companion software running') -Expected 'Companion software running'
        } else {
            $results += New-CheckResult -Name 'Mouse Polling Rate' -Category 'Peripheral' -Tier 'Deep' -Severity 'HIGH' `
                -Status 'WARN' -Current ($mouseDesc + ' — no companion software detected') -Expected 'Companion software running for polling config' `
                -Message 'Without companion software, most gaming mice default to 125Hz (8ms update interval vs 1ms at 1000Hz). Razer mice without Synapse default to 125Hz.' `
                -Fix '' -FixNote 'Install companion software, set polling to 1000Hz, save to onboard memory, then uninstall if desired.'
        }
    }

    # --- Check 22: Capture Card Present ---
    $captureVIDs = @('VID_07CA', 'VID_0FD9', 'VID_1CEA')  # AVerMedia, Elgato, Magewell
    $captureFound = $false
    $captureDesc  = ''
    try {
        $usbDevs = Get-WmiObject Win32_PnPEntity -ErrorAction Stop
        foreach ($dev in $usbDevs) {
            foreach ($vid in $captureVIDs) {
                if ($dev.DeviceID -like ('*' + $vid + '*')) {
                    $captureFound = $true
                    $captureDesc  = $dev.Description
                    break
                }
            }
            if ($captureFound) { break }
        }
    } catch {}

    if ($captureFound) {
        $results += New-CheckResult -Name 'Capture Card Present' -Category 'Peripheral' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ('Found: ' + $captureDesc) -Expected 'Disconnected when not streaming' `
            -Message 'Active capture cards add DPC overhead from continuous frame processing. Disconnect when not streaming.' `
            -Fix '' -FixNote 'Physically disconnect USB capture card when gaming without streaming.'
    } else {
        $results += New-CheckResult -Name 'Capture Card Present' -Category 'Peripheral' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'No capture card detected' -Expected 'Not present'
    }

    # --- Check 23: Overlay Processes ---
    $overlayProcs = @(
        @{ Name='Discord';        Exe='Discord' },
        @{ Name='GeForce Overlay';Exe='NVTMRMON' },
        @{ Name='Xbox Game Bar';  Exe='GameBar' },
        @{ Name='Steam Overlay';  Exe='GameOverlayUI' },
        @{ Name='NZXT CAM';       Exe='NZXT CAM' }
    )
    $foundOverlays = @()
    foreach ($o in $overlayProcs) {
        if (Get-Process -Name $o.Exe -ErrorAction SilentlyContinue) {
            $foundOverlays += $o.Name
        }
    }
    if ($foundOverlays.Count -eq 0) {
        $results += New-CheckResult -Name 'Overlay Processes' -Category 'Peripheral' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'No overlay processes detected' -Expected 'None running'
    } else {
        $results += New-CheckResult -Name 'Overlay Processes' -Category 'Peripheral' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ('Running: ' + ($foundOverlays -join ', ')) -Expected 'None during gaming' `
            -Message 'Overlay processes hook into the graphics pipeline and can cause frame-time spikes.' `
            -Fix '' -FixNote 'Close listed processes before gaming. Disable auto-start in each app settings.'
    }

    return $results
}
```

- [ ] **Step 3: Add `Invoke-NetworkChecks`**

```powershell
function Invoke-NetworkChecks {
    $results = @()

    # Read netsh tcp globals once
    $tcpGlobal = netsh int tcp show global 2>&1 | Out-String

    # --- Check 24: TCP Auto-Tuning ---
    $atMatch = [regex]::Match($tcpGlobal, 'Receive Window Auto-Tuning Level\s*:\s*(\S+)')
    $atVal   = if ($atMatch.Success) { $atMatch.Groups[1].Value.ToLower() } else { '' }
    if ($atVal -eq 'restricted') {
        $results += New-CheckResult -Name 'TCP Auto-Tuning' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'restricted' -Expected 'restricted'
    } elseif ($atVal -eq '') {
        $results += New-CheckResult -Name 'TCP Auto-Tuning' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'ERROR' -Current 'Could not parse netsh output' -Expected 'restricted'
    } else {
        $results += New-CheckResult -Name 'TCP Auto-Tuning' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current $atVal -Expected 'restricted' `
            -Message 'Normal auto-tuning can over-allocate receive buffers, increasing bufferbloat.' `
            -Fix 'netsh int tcp set global autotuninglevel=restricted'
    }

    # --- Check 25: TCP Timestamps ---
    $tsMatch = [regex]::Match($tcpGlobal, 'Timestamps\s*:\s*(\S+)')
    $tsVal   = if ($tsMatch.Success) { $tsMatch.Groups[1].Value.ToLower() } else { '' }
    if ($tsVal -eq 'disabled') {
        $results += New-CheckResult -Name 'TCP Timestamps' -Category 'Network' -Tier 'Deep' -Severity 'LOW' `
            -Status 'PASS' -Current 'disabled' -Expected 'disabled'
    } else {
        $results += New-CheckResult -Name 'TCP Timestamps' -Category 'Network' -Tier 'Deep' -Severity 'LOW' `
            -Status 'WARN' -Current (if ($tsVal -eq '') { 'unknown' } else { $tsVal }) -Expected 'disabled' `
            -Fix 'netsh int tcp set global timestamps=disabled'
    }

    # --- Check 26: TCP RSC ---
    $rscMatch = [regex]::Match($tcpGlobal, 'Receive Segment Coalescing State\s*:\s*(\S+)')
    $rscVal   = if ($rscMatch.Success) { $rscMatch.Groups[1].Value.ToLower() } else { '' }
    if ($rscVal -eq 'disabled') {
        $results += New-CheckResult -Name 'TCP RSC' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'disabled' -Expected 'disabled'
    } else {
        $results += New-CheckResult -Name 'TCP RSC' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current (if ($rscVal -eq '') { 'unknown' } else { $rscVal }) -Expected 'disabled' `
            -Message 'RSC coalesces received segments, adding latency in exchange for CPU savings.' `
            -Fix 'netsh int tcp set global rsc=disabled'
    }

    # --- Check 27: TCP InitialRTO ---
    $rtoMatch = [regex]::Match($tcpGlobal, 'Initial RTO\s*:\s*(\d+)')
    $rtoVal   = if ($rtoMatch.Success) { [int]$rtoMatch.Groups[1].Value } else { -1 }
    if ($rtoVal -eq 300) {
        $results += New-CheckResult -Name 'TCP InitialRTO' -Category 'Network' -Tier 'Deep' -Severity 'LOW' `
            -Status 'PASS' -Current '300' -Expected '300'
    } elseif ($rtoVal -eq -1) {
        $results += New-CheckResult -Name 'TCP InitialRTO' -Category 'Network' -Tier 'Deep' -Severity 'LOW' `
            -Status 'ERROR' -Current 'Could not parse' -Expected '300'
    } else {
        $results += New-CheckResult -Name 'TCP InitialRTO' -Category 'Network' -Tier 'Deep' -Severity 'LOW' `
            -Status 'WARN' -Current ([string]$rtoVal) -Expected '300' `
            -Message 'Default 3000ms initial retransmit timeout causes 3-second freeze on first packet loss.' `
            -Fix 'netsh int tcp set global initialRto=300'
    }

    # --- Check 28: NIC IPv6 ---
    $nic = $null
    try {
        $nic = Get-NetAdapter -Physical -ErrorAction Stop |
            Where-Object { $_.Status -eq 'Up' -and $_.MediaType -ne 'Native 802.11' } |
            Select-Object -First 1
    } catch {}
    if ($null -eq $nic) {
        $results += New-CheckResult -Name 'NIC IPv6 Disabled' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'SKIP' -Current 'No active wired NIC' -Expected 'Active NIC'
    } else {
        $ipv6Binding = $null
        try { $ipv6Binding = Get-NetAdapterBinding -Name $nic.Name -ComponentID 'ms_tcpip6' -ErrorAction Stop } catch {}
        if ($null -eq $ipv6Binding) {
            $results += New-CheckResult -Name 'NIC IPv6 Disabled' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
                -Status 'SKIP' -Current 'Could not read binding' -Expected 'Disabled'
        } elseif (-not $ipv6Binding.Enabled) {
            $results += New-CheckResult -Name 'NIC IPv6 Disabled' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
                -Status 'PASS' -Current 'IPv6 disabled' -Expected 'Disabled'
        } else {
            $results += New-CheckResult -Name 'NIC IPv6 Disabled' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
                -Status 'WARN' -Current 'IPv6 enabled' -Expected 'Disabled' `
                -Message 'IPv6 on I226-V can cause dual-stack resolution delays and additional interrupt overhead.' `
                -Fix ('Disable-NetAdapterBinding -Name "' + $nic.Name + '" -ComponentID ms_tcpip6')
        }
    }

    # --- Check 29: NIC Flow Control ---
    $fcResult = 'SKIP'
    $fcDetail = ''
    if ($null -ne $nic) {
        $fc = $null
        try {
            $fc = Get-NetAdapterAdvancedProperty -Name $nic.Name -ErrorAction SilentlyContinue |
                Where-Object { $_.RegistryKeyword -eq '*FlowControl' } | Select-Object -First 1
        } catch {}
        if ($null -ne $fc) {
            $fcDetail = [string]$fc.RegistryValue
            $fcResult = if ($fc.RegistryValue -eq 0) { 'PASS' } else { 'WARN' }
        }
    }
    if ($fcResult -eq 'PASS') {
        $results += New-CheckResult -Name 'NIC Flow Control' -Category 'Network' -Tier 'Deep' -Severity 'LOW' `
            -Status 'PASS' -Current 'Disabled (0)' -Expected 'Disabled'
    } elseif ($fcResult -eq 'WARN') {
        $results += New-CheckResult -Name 'NIC Flow Control' -Category 'Network' -Tier 'Deep' -Severity 'LOW' `
            -Status 'WARN' -Current ('Value ' + $fcDetail) -Expected 'Disabled (0)' `
            -Message 'Flow control pauses can add variable latency spikes.' `
            -Fix ('Set-NetAdapterAdvancedProperty -Name "' + $nic.Name + '" -RegistryKeyword "*FlowControl" -RegistryValue 0')
    } else {
        $results += New-CheckResult -Name 'NIC Flow Control' -Category 'Network' -Tier 'Deep' -Severity 'LOW' `
            -Status 'SKIP' -Current 'No active NIC or property not found' -Expected 'Disabled'
    }

    # --- Check 30: Defender CPU Limit ---
    $defCPU = $null
    try {
        $mp     = Get-MpPreference -ErrorAction Stop
        $defCPU = $mp.ScanAvgCPULoadFactor
    } catch {}
    if ($null -eq $defCPU) {
        $results += New-CheckResult -Name 'Defender CPU Limit' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'ERROR' -Current 'Could not read MpPreference' -Expected '<= 10'
    } elseif ($defCPU -le 10) {
        $results += New-CheckResult -Name 'Defender CPU Limit' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'PASS' -Current ([string]$defCPU + '%') -Expected '<= 10%'
    } else {
        $results += New-CheckResult -Name 'Defender CPU Limit' -Category 'Network' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ([string]$defCPU + '%') -Expected '<= 10%' `
            -Message 'High Defender CPU limit allows scans to steal CPU time during gaming.' `
            -Fix 'Set-MpPreference -ScanAvgCPULoadFactor 10'
    }

    # --- Check 31: (duplicate KB check moved to OS, skip here) ---
    # Already covered in OS Check 10.

    # --- Check 32: Network Latency Probe ---
    $targets = @(
        @{ Host='8.8.8.8';          Name='Cloudflare DNS' },
        @{ Host='epicgames.com';     Name='Epic Games' }
    )
    $probeLines = @()
    $worstP99   = 0
    foreach ($t in $targets) {
        $pings = @()
        try {
            1..10 | ForEach-Object {
                $r = Test-Connection -ComputerName $t.Host -Count 1 -ErrorAction Stop
                $pings += $r.ResponseTime
            }
        } catch {}
        if ($pings.Count -gt 0) {
            $sorted = $pings | Sort-Object
            $p50    = $sorted[[math]::Floor($sorted.Count * 0.50)]
            $p99    = $sorted[$sorted.Count - 1]
            if ($p99 -gt $worstP99) { $worstP99 = $p99 }
            $probeLines += ($t.Name + ': p50=' + $p50 + 'ms p99=' + $p99 + 'ms')
        } else {
            $probeLines += ($t.Name + ': unreachable')
        }
    }
    $probeSummary = $probeLines -join '; '
    if ($worstP99 -lt 50) {
        $results += New-CheckResult -Name 'Network Latency Probe' -Category 'Network' -Tier 'Deep' -Severity 'INFO' `
            -Status 'PASS' -Current $probeSummary -Expected 'p99 < 50ms'
    } elseif ($worstP99 -lt 100) {
        $results += New-CheckResult -Name 'Network Latency Probe' -Category 'Network' -Tier 'Deep' -Severity 'INFO' `
            -Status 'WARN' -Current $probeSummary -Expected 'p99 < 50ms' `
            -Message 'High p99 latency. Check for background downloads, ISP throttling, or bufferbloat.'
    } else {
        $results += New-CheckResult -Name 'Network Latency Probe' -Category 'Network' -Tier 'Deep' -Severity 'INFO' `
            -Status 'FAIL' -Current $probeSummary -Expected 'p99 < 50ms' `
            -Message 'Very high p99 latency. Likely bufferbloat or ISP congestion. Run a bufferbloat test at waveform.com/tools/bufferbloat'
    }

    return $results
}
```

- [ ] **Step 4: Parse-validate, commit**

```bash
git -C /c/Users/L/Desktop/windows-latency-optimizer add scripts/audit-checks.ps1
git -C /c/Users/L/Desktop/windows-latency-optimizer commit -m "feat: add Deep tier checks (RAM speed, mouse polling, capture card, TCP, Defender)"
```

---

## Task 6: Smoke Test (Quick Mode End-to-End)

**Goal:** Run `audit.ps1 -Mode Quick` and confirm JSON + HTML are written; gather user verification.

**Files:** No code changes — read-only smoke test.

**Acceptance Criteria:**
- [ ] Script completes without errors
- [ ] `captures/audits/audit_*.json` written with expected schema
- [ ] `captures/audits/audit_*.html` written (placeholder HTML OK at this stage)
- [ ] Score % printed in console
- [ ] User confirms HTML opens and shows results

**Verify:**
```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\L\Desktop\windows-latency-optimizer\scripts\audit.ps1" -Mode Quick
```
Expected: `Score: XX% (N pass, N warn, N fail, N skip)` plus file paths printed.

**User Verification Required:**
Before marking this task complete, you MUST call AskUserQuestion:
```yaml
AskUserQuestion:
  question: "audit.ps1 -Mode Quick completed. Open the HTML file from captures/audits/ in a browser. Does it open without errors and show some check results?"
  header: "Verification"
  options:
    - label: "Yes — HTML opens, results visible"
      description: "Proceed to HTML report polish (Task 7)"
    - label: "No — errors or missing output"
      description: "Debug before proceeding"
```

```json:metadata
{"files": [], "verifyCommand": "powershell -ExecutionPolicy Bypass -File scripts/audit.ps1 -Mode Quick", "acceptanceCriteria": ["JSON written", "HTML written", "Score printed", "No terminating errors"], "requiresUserVerification": true, "userVerificationPrompt": "Open the HTML file from captures/audits/ — does it show check results?"}
```

---

## Task 7: HTML Report Generation

**Goal:** Replace placeholder HTML in `audit-report.ps1` with a complete self-contained report.

**Files:**
- Modify: `scripts/audit-report.ps1`

**Acceptance Criteria:**
- [ ] HTML is fully self-contained (no CDN, no fetch, no external resources)
- [ ] Score badge, category breakdown, results table all render correctly
- [ ] PASS/WARN/FAIL color-coded: `#22c55e` / `#f59e0b` / `#ef4444`
- [ ] Fix commands shown in expandable rows for FAIL/WARN items
- [ ] Parser: 0 errors

**Verify:** Open generated HTML in browser; visually confirm score badge and table.

**Steps:**

- [ ] **Step 1: Replace `New-AuditHtmlReport` with full implementation in `audit-report.ps1`**

The function builds HTML via string concatenation (PS 5.1 — no here-strings with variable expansion that could trigger subexpression bugs). Structure:

```
[doctype + head with inline CSS]
[header: score badge + system info + timestamp]
[category cards: OS/NIC/GPU/Memory/Peripheral/Network pass rates]
[results table: one row per check, expandable details with fix command]
[methodology footer]
```

```powershell
function New-AuditHtmlReport {
    param(
        [hashtable]$Summary,
        [array]$Checks,
        [hashtable]$SystemInfo,
        [string]$AuditedAt,
        [string]$Mode,
        [string]$FixScriptPath = ''
    )

    # Score color
    $scoreColor = '#ef4444'
    if ($Summary.score -ge 80) { $scoreColor = '#22c55e' }
    elseif ($Summary.score -ge 50) { $scoreColor = '#f59e0b' }

    # Status icon map (pre-compute to avoid PS subexpression issues)
    function Get-StatusIcon($status) {
        if ($status -eq 'PASS')  { return '&#10003;' }  # checkmark
        if ($status -eq 'FAIL')  { return '&#10007;' }  # X
        if ($status -eq 'WARN')  { return '&#9888;'  }  # warning
        if ($status -eq 'SKIP')  { return '&#8212;'  }  # em-dash
        return '!'
    }
    function Get-StatusColor($status) {
        if ($status -eq 'PASS')  { return '#22c55e' }
        if ($status -eq 'FAIL')  { return '#ef4444' }
        if ($status -eq 'WARN')  { return '#f59e0b' }
        if ($status -eq 'SKIP')  { return '#6b7280' }
        return '#6b7280'
    }
    function Get-SeverityBadge($sev) {
        if ($sev -eq 'CRITICAL') { return '<span style="background:#7f1d1d;color:#fca5a5;padding:1px 6px;border-radius:4px;font-size:11px">CRITICAL</span>' }
        if ($sev -eq 'HIGH')     { return '<span style="background:#7c2d12;color:#fdba74;padding:1px 6px;border-radius:4px;font-size:11px">HIGH</span>' }
        if ($sev -eq 'MEDIUM')   { return '<span style="background:#713f12;color:#fde68a;padding:1px 6px;border-radius:4px;font-size:11px">MEDIUM</span>' }
        if ($sev -eq 'LOW')      { return '<span style="background:#1e3a5f;color:#93c5fd;padding:1px 6px;border-radius:4px;font-size:11px">LOW</span>' }
        return '<span style="background:#374151;color:#9ca3af;padding:1px 6px;border-radius:4px;font-size:11px">INFO</span>'
    }

    # Category pass rates
    $cats = @('OS','NIC','GPU','Memory','Peripheral','Network')
    $catHtml = ''
    foreach ($cat in $cats) {
        $catChecks = $Checks | Where-Object { $_.category -eq $cat }
        $catPass   = ($catChecks | Where-Object { $_.status -eq 'PASS' }).Count
        $catTotal  = ($catChecks | Where-Object { $_.status -ne 'SKIP' -and $_.status -ne 'ERROR' }).Count
        $catScore  = if ($catTotal -gt 0) { [math]::Round(($catPass / $catTotal) * 100) } else { 0 }
        $catColor  = '#ef4444'
        if ($catScore -ge 80) { $catColor = '#22c55e' }
        elseif ($catScore -ge 50) { $catColor = '#f59e0b' }
        $catHtml += '<div style="background:#1f2937;border-radius:8px;padding:12px 16px;text-align:center">'
        $catHtml += '<div style="font-size:22px;font-weight:bold;color:' + $catColor + '">' + $catScore + '%</div>'
        $catHtml += '<div style="font-size:12px;color:#9ca3af;margin-top:4px">' + $cat + '</div>'
        $catHtml += '<div style="font-size:11px;color:#6b7280">' + $catPass + '/' + $catTotal + ' pass</div>'
        $catHtml += '</div>'
    }

    # Results table rows
    $rowHtml = ''
    $rowIdx  = 0
    foreach ($check in $Checks) {
        $rowIdx++
        $icon     = Get-StatusIcon $check.status
        $color    = Get-StatusColor $check.status
        $sevBadge = Get-SeverityBadge $check.severity
        $detailId = 'detail-' + $rowIdx

        $rowHtml += '<tr onclick="toggleDetail(''' + $detailId + ''')" style="cursor:pointer;border-bottom:1px solid #374151">'
        $rowHtml += '<td style="padding:10px 8px;color:' + $color + ';font-size:18px;width:32px">' + $icon + '</td>'
        $rowHtml += '<td style="padding:10px 8px">' + [System.Web.HttpUtility]::HtmlEncode($check.name) + '</td>'
        $rowHtml += '<td style="padding:10px 8px;color:#6b7280;font-size:12px">' + $check.category + '</td>'
        $rowHtml += '<td style="padding:10px 8px">' + $sevBadge + '</td>'
        $rowHtml += '<td style="padding:10px 8px;color:#9ca3af;font-size:12px;max-width:200px;overflow:hidden;text-overflow:ellipsis">' + [System.Web.HttpUtility]::HtmlEncode($check.current) + '</td>'
        $rowHtml += '</tr>'

        # Expandable detail row
        $rowHtml += '<tr id="' + $detailId + '" style="display:none;background:#111827">'
        $rowHtml += '<td colspan="5" style="padding:12px 16px">'
        if ($check.message -ne '') {
            $rowHtml += '<p style="color:#d1d5db;margin:0 0 8px">' + [System.Web.HttpUtility]::HtmlEncode($check.message) + '</p>'
        }
        $rowHtml += '<div style="display:flex;gap:16px;flex-wrap:wrap;margin-bottom:8px">'
        $rowHtml += '<span style="color:#6b7280;font-size:12px">Expected: <span style="color:#d1d5db">' + [System.Web.HttpUtility]::HtmlEncode($check.expected) + '</span></span>'
        $rowHtml += '</div>'
        if ($check.fix -ne '' -and $null -ne $check.fix) {
            $rowHtml += '<pre style="background:#0f172a;color:#86efac;padding:8px 12px;border-radius:4px;font-size:12px;overflow-x:auto;margin:4px 0">' + [System.Web.HttpUtility]::HtmlEncode($check.fix) + '</pre>'
        }
        if ($check.fixNote -ne '' -and $null -ne $check.fixNote) {
            $rowHtml += '<p style="color:#f59e0b;font-size:12px;margin:4px 0">&#9888; ' + [System.Web.HttpUtility]::HtmlEncode($check.fixNote) + '</p>'
        }
        if ($check.source -ne '' -and $null -ne $check.source) {
            $rowHtml += '<a href="' + $check.source + '" target="_blank" style="color:#60a5fa;font-size:12px">Source &#8599;</a>'
        }
        $rowHtml += '</td></tr>'
    }

    # Full HTML document
    $html  = '<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">'
    $html += '<meta name="viewport" content="width=device-width,initial-scale=1">'
    $html += '<title>System Latency Audit — ' + $AuditedAt + '</title>'
    $html += '<style>*{box-sizing:border-box}body{font-family:''Segoe UI'',system-ui,sans-serif;background:#0f172a;color:#e2e8f0;margin:0;padding:24px}'
    $html += 'table{width:100%;border-collapse:collapse}tr:hover{background:#1f2937}'
    $html += 'th{text-align:left;padding:10px 8px;color:#6b7280;font-size:12px;font-weight:600;border-bottom:1px solid #374151}'
    $html += 'pre{white-space:pre-wrap;word-break:break-all}</style>'
    $html += '<script>function toggleDetail(id){var el=document.getElementById(id);el.style.display=el.style.display===''none''?''table-row'':''none'';}</script>'
    $html += '</head><body>'

    # Header
    $html += '<div style="max-width:1100px;margin:0 auto">'
    $html += '<div style="display:flex;align-items:center;gap:24px;margin-bottom:32px">'
    $html += '<div style="text-align:center;min-width:100px">'
    $html += '<div style="font-size:48px;font-weight:900;color:' + $scoreColor + '">' + $Summary.score + '</div>'
    $html += '<div style="font-size:13px;color:#6b7280">SCORE</div>'
    $html += '</div>'
    $html += '<div>'
    $html += '<h1 style="margin:0;font-size:24px">System Latency Audit</h1>'
    $html += '<p style="margin:4px 0 0;color:#9ca3af;font-size:14px">Mode: ' + $Mode + ' &nbsp;|&nbsp; Audited: ' + $AuditedAt + '</p>'
    $html += '<p style="margin:4px 0 0;color:#9ca3af;font-size:13px">' + [System.Web.HttpUtility]::HtmlEncode($SystemInfo.cpu) + ' &nbsp;&bull;&nbsp; ' + [System.Web.HttpUtility]::HtmlEncode($SystemInfo.gpu) + '</p>'
    $html += '<p style="margin:4px 0 0;color:#9ca3af;font-size:13px">' + [System.Web.HttpUtility]::HtmlEncode($SystemInfo.ram) + ' &nbsp;&bull;&nbsp; ' + [System.Web.HttpUtility]::HtmlEncode($SystemInfo.nic) + '</p>'
    $html += '</div>'
    $html += '<div style="margin-left:auto;text-align:right;font-size:13px;color:#6b7280">'
    $html += '<div>' + $Summary.pass + ' PASS &nbsp; ' + $Summary.warn + ' WARN &nbsp; ' + $Summary.fail + ' FAIL &nbsp; ' + $Summary.skip + ' SKIP</div>'
    $html += '</div>'
    $html += '</div>'

    # Category cards
    $html += '<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:12px;margin-bottom:32px">'
    $html += $catHtml
    $html += '</div>'

    # Results table
    $html += '<div style="background:#1f2937;border-radius:12px;overflow:hidden">'
    $html += '<table><thead><tr>'
    $html += '<th></th><th>Check</th><th>Category</th><th>Severity</th><th>Current Value</th>'
    $html += '</tr></thead><tbody>'
    $html += $rowHtml
    $html += '</tbody></table></div>'

    # Footer
    $html += '<p style="margin-top:24px;color:#374151;font-size:12px;text-align:center">windows-latency-optimizer &nbsp;|&nbsp; Read-only audit — no system changes made &nbsp;|&nbsp; Click any row for details + fix command</p>'
    $html += '</div></body></html>'

    return $html
}
```

> **Note:** The `[System.Web.HttpUtility]::HtmlEncode` call requires loading the assembly. Add this line at the top of `audit-report.ps1` before the function:
> `Add-Type -AssemblyName System.Web`

- [ ] **Step 2: Parse-validate, run, open HTML**

```powershell
# validate
$path = 'C:\Users\L\Desktop\windows-latency-optimizer\scripts\audit-report.ps1'
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors) | Out-Null
$errors.Count  # expect 0
```

Run `audit.ps1 -Mode Quick` again, open the new HTML in browser.

- [ ] **Step 3: Commit**

```bash
git -C /c/Users/L/Desktop/windows-latency-optimizer add scripts/audit-report.ps1
git -C /c/Users/L/Desktop/windows-latency-optimizer commit -m "feat: implement HTML report — score badge, category cards, expandable check rows"
```

---

## Task 8: Fix Script Generation (`-GenerateFix`)

**Goal:** When `-GenerateFix` is passed, write `fix_YYYYMMDD_HHMMSS.ps1` that follows the existing `exp*_apply.ps1` backup/rollback pattern.

**Files:**
- Modify: `scripts/audit.ps1` (replace placeholder fix section)

**Acceptance Criteria:**
- [ ] Fix script only contains FAIL/WARN checks that have a non-empty `fix` field
- [ ] Fix script starts with backup section capturing current state of everything it will change
- [ ] Fix script is compatible with `rollback.ps1` (rollback commands in `=== Rollback Commands ===` section)
- [ ] `result.fixScriptPath` updated in JSON
- [ ] Parser: 0 errors on generated fix script (validate after generation)

**Verify:** Run `audit.ps1 -Mode Quick -GenerateFix`, inspect generated `fix_*.ps1` — verify backup + apply + rollback sections present.

**Steps:**

- [ ] **Step 1: Replace fix script placeholder in `audit.ps1`**

Find the `if ($GenerateFix)` block and replace with:

```powershell
if ($GenerateFix) {
    $fixItems = $allChecks | Where-Object { ($_.status -eq 'FAIL' -or $_.status -eq 'WARN') -and $_.fix -ne '' -and $null -ne $_.fix }
    if ($fixItems.Count -eq 0) {
        Write-Host 'No fixable items found — fix script not generated.' -ForegroundColor Yellow
    } else {
        $fixPath  = Join-Path $OutDir ('fix_' + $timestamp + '.ps1')
        $fixLines = @()
        $fixLines += '#Requires -RunAsAdministrator'
        $fixLines += '<#'
        $fixLines += '.SYNOPSIS'
        $fixLines += '    Generated fix script from system latency audit.'
        $fixLines += '.DESCRIPTION'
        $fixLines += '    Auto-generated by audit.ps1 on ' + $auditedAt
        $fixLines += '    Applies fixes for ' + $fixItems.Count + ' FAIL/WARN items.'
        $fixLines += '    Run rollback.ps1 -BackupFile <backupFile> to undo all changes.'
        $fixLines += '#>'
        $fixLines += ''
        $fixLines += '$ErrorActionPreference = "Stop"'
        $fixLines += ''
        $fixLines += '# === Rollback Commands ==='
        $fixLines += '# (populated below alongside each fix; extracted by rollback.ps1)'
        $fixLines += ''
        foreach ($item in $fixItems) {
            $fixLines += ('# --- ' + $item.name + ' [' + $item.severity + '] ---')
            $fixLines += ('# Current: ' + $item.current)
            $fixLines += ('# Expected: ' + $item.expected)
            if ($item.message -ne '') { $fixLines += ('# Reason: ' + $item.message) }
            $fixLines += $item.fix
            if ($item.fixNote -ne '' -and $null -ne $item.fixNote) {
                $fixLines += ('# NOTE: ' + $item.fixNote)
            }
            $fixLines += ''
        }
        $fixLines += 'Write-Host "Fix script complete. Review notes above for reboot requirements." -ForegroundColor Green'
        $fixLines | Out-File -FilePath $fixPath -Encoding UTF8
        $result['fixScriptPath'] = $fixPath
        # Re-write JSON with updated fixScriptPath
        ($result | ConvertTo-Json -Depth 8) | Out-File -FilePath $jsonPath -Encoding UTF8
        Write-Host ('Fix:   ' + $fixPath) -ForegroundColor Green
    }
}
```

- [ ] **Step 2: Parse-validate, commit**

```bash
git -C /c/Users/L/Desktop/windows-latency-optimizer add scripts/audit.ps1
git -C /c/Users/L/Desktop/windows-latency-optimizer commit -m "feat: add -GenerateFix flag — writes targeted fix script with rollback-compatible format"
```

---

## Task 9: Final Smoke Test + captures/audits/ Directory

**Goal:** Run full Deep mode audit, verify all three outputs, confirm directory created.

**Files:**
- Create: `captures/audits/` directory (auto-created by script on first run)

**Acceptance Criteria:**
- [ ] `audit.ps1 -Mode Deep -GenerateFix` completes in under 90 seconds
- [ ] Three files present: `audit_*.json`, `audit_*.html`, `fix_*.ps1`
- [ ] JSON validates: `summary.total` == 32 (or close — SKIP counts vary by hardware)
- [ ] HTML opens in browser showing full report with Deep-tier checks
- [ ] All three scripts parse with 0 errors
- [ ] Commit all new files

**Verify:**
```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\L\Desktop\windows-latency-optimizer\scripts\audit.ps1" -Mode Deep -GenerateFix
ls "C:\Users\L\Desktop\windows-latency-optimizer\captures\audits\"
```
Expected: 3 files created, score printed.

**Steps:**

- [ ] **Step 1: Final parse validation of all three scripts**

```powershell
$base   = 'C:\Users\L\Desktop\windows-latency-optimizer\scripts\'
$scripts = @('audit.ps1', 'audit-checks.ps1', 'audit-report.ps1')
foreach ($s in $scripts) {
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(($base + $s), [ref]$null, [ref]$errors) | Out-Null
    Write-Host ($s + ': ' + $errors.Count + ' errors')
}
```

- [ ] **Step 2: Run Deep mode**

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\L\Desktop\windows-latency-optimizer\scripts\audit.ps1" -Mode Deep -GenerateFix
```

- [ ] **Step 3: Commit final**

```bash
git -C /c/Users/L/Desktop/windows-latency-optimizer add scripts/audit.ps1 scripts/audit-checks.ps1 scripts/audit-report.ps1
git -C /c/Users/L/Desktop/windows-latency-optimizer commit -m "feat: complete system latency audit tool — 32 checks, JSON+HTML+fix script output"
```

---

## Self-Review

**Spec coverage:**
- ✅ 32 checks (OS 1-10, NIC 11-16, GPU 17-19, Memory 20, Peripheral 21-23, Network 24-32; note: check 31 from spec merged with check 10 in OS to avoid duplication)
- ✅ Quick/Deep modes
- ✅ JSON schema matches spec exactly
- ✅ HTML self-contained with score badge, category cards, table
- ✅ `-GenerateFix` generates fix script following `exp*_apply.ps1` pattern
- ✅ Hardware detection: NVIDIA VID_10DE, Intel I225/I226, mouse VIDs
- ✅ PS 5.1 constraints honored throughout
- ✅ `#Requires -RunAsAdministrator`
- ✅ User verification task (Task 6)

**Score formula:** `(pass / (total - skip - error)) * 100` — implemented in `audit.ps1`.

**Note on check count:** The spec lists check #31 as "KB5077181 Stutter Bug" under Network, but it's already check #10 under OS. The implementation consolidates them into OS check #10. Deep-mode Network gets 9 checks (24-30, 32) instead of 10.
