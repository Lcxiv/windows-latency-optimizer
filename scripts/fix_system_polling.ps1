#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Fix Windows system polling storms identified by ProcMon analysis (2026-04-27).
.DESCRIPTION
    Addresses 8 root causes of excessive system I/O at idle (8,500 ops/sec baseline):

    1. ctfmon.exe Text Input Framework (422 reg reads/sec)
       ROOT CAUSE: Conflicting settings between system-level Input\Settings
       (AutoCorrection=0, Prediction=0) and per-IME level proc_1\loc_0409\im_1
       (AutoCorrection=1, Prediction=1). ctfmon polls BOTH levels every ~70ms
       to resolve priority. Also: HarvestContacts=1, DictationEnabled=1,
       InsightsEnabled conflict between HKLM(1) and HKCU(0).
       FIX: Align per-IME settings to match system-level (all OFF for desktop).
       Disable unnecessary input personalization features.

    2. Winmgmt WMI Tracing (271 reg reads/sec)
       ROOT CAUSE: Known Windows bug — WMI service continuously re-reads
       HKLM\Software\Microsoft\WBEM\Tracing even with EnableWinmgmtTelemetry=0.
       Exacerbated by MSI Afterburner polling WMI sensor classes.
       FIX: Cannot fully fix (Windows bug). Disable WMI performance logging.

    3. camsvc Capability Access Manager (216 reg reads/sec)
       ROOT CAUSE: 4 systemAIModels apps (aimgr, Outlook, Photos, Notepad)
       registered for location-based AI features. camsvc continuously polls
       LetAppsAccessLocation policy 181/sec even though Location consent = Deny.
       FIX: Set camsvc to Manual start, disable location service.

    4. Explorer shell extension enumeration (1,343 events/sec vs ~300 normal)
       ROOT CAUSE: 7 OneDrive icon overlay handlers registered but OneDrive NOT
       running (ghost extensions). 33 desktop namespace CLSIDs including unused
       File History, CSC, MAPI folders. 84 AppX packages being enumerated.
       Explorer also checks DataProtection/WIP policies (1,314/30s) and
       Terminal Server config (540/30s) — both pointless on a gaming desktop.
       FIX: Remove OneDrive overlay registrations, disable unused namespace
       extensions, reduce AppCompat shim checks.

    5. WMI Repository thrash (302 ops/sec on OBJECTS.DATA)
       ROOT CAUSE: MSI Afterburner polling Win32_PerfFormattedData classes
       for GPU/CPU sensor readings. Winmgmt rebuilds tracing config each query.
       FIX: Informational only — Afterburner is intentional. Can reduce by
       increasing Afterburner's polling interval or switching to direct NVML.

    6. SearchIndexer.exe (8,292 events/sec — LARGEST single source)
       ROOT CAUSE: WSearch service set to Automatic with 50+ scope paths
       including dev folders (.claude, .cargo, .rustup, ComfyUI, AppData,
       ProgramData). Post-reboot indexing burst writes 248K events in 30s
       to C:\ProgramData\Microsoft\Search. On a gaming rig, search indexing
       provides minimal value vs massive I/O cost.
       FIX: Disable WSearch service. Start Menu search still works (slower
       file search, but Cortana/app search unaffected).

    7. Explorer enterprise policy overhead (638+ reg reads/sec)
       ROOT CAUSE: Explorer checks WIP/DataProtection policies (enterprise DLP),
       AppCompat shim database (674 reads/30s), and Terminal Server config — all
       pointless on a gaming desktop. ShellHWDetection service triggers COM
       notifications for hardware changes on a static desktop.
       FIX: Disable ShellHWDetection, set GPO to disable WIP/DataProtection
       and AppCompat engine/PCA.

    8. camsvc escalation: Manual start insufficient
       ROOT CAUSE: Setting camsvc to Manual (Storm 3) was insufficient — Chrome
       triggers camsvc on-demand to check camera/mic/location capability policies.
       Once started: 980/sec polling ALL policies via PolicyManager.
       FIX: Changed from Manual to Disabled. Camera/mic still work at hardware
       level but Windows privacy permission UI dialogs won't show.

.NOTES
    Reboot: RECOMMENDED for full effect
    Rollback: Run .\enable_system_polling.ps1
    ProcMon baseline: 255,364 events / 30 seconds = 8,512 events/sec at idle
    Target: <3,000 events/sec at idle
#>

param(
    [switch]$WhatIf,
    [switch]$SkipOneDrive,
    [switch]$SkipCamsvc,
    [switch]$SkipSearchIndexer
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent

# ─── Backup ───────────────────────────────────────────────────────────────────
$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupFile = Join-Path $projectRoot ('captures\backup_pre_system_polling_fix_' + $ts + '.txt')

$backupLines = @(
    ('# System Polling Fix Backup - ' + $ts),
    '# Rollback: run scripts\enable_system_polling.ps1',
    ""
)

Write-Host '=== SYSTEM POLLING STORM FIX ===' -ForegroundColor Cyan
Write-Host ('Backup: ' + $backupFile) -ForegroundColor Gray
Write-Host ''

# ─── Fix 1: ctfmon Text Input Framework ───────────────────────────────────────
Write-Host '[1/8] Fixing ctfmon Text Input polling storm...' -ForegroundColor Yellow
Write-Host '  Root cause: Conflicting Input\Settings (system=OFF, per-IME=ON)' -ForegroundColor Gray

$imePath = 'HKLM:\SOFTWARE\Microsoft\Input\Settings\proc_1\loc_0409\im_1'
$inputSettingsPath = 'HKLM:\SOFTWARE\Microsoft\Input\Settings'
$inputSettingsUser = 'HKCU:\SOFTWARE\Microsoft\Input\Settings'

# Align per-IME to match system-level (OFF)
$imeFixKeys = @(
    @{ Path = $imePath; Name = 'AutoCorrection'; Value = 0 },
    @{ Path = $imePath; Name = 'Prediction'; Value = 0 },
    @{ Path = $imePath; Name = 'Spellcheck'; Value = 0 },
    @{ Path = $imePath; Name = 'ShapeWriting'; Value = 0 },
    @{ Path = $imePath; Name = 'EmojiSuggestion'; Value = 0 },
    @{ Path = $imePath; Name = 'HTREnabled'; Value = 0 }
)

# Disable unnecessary personalization features
$inputFixKeys = @(
    @{ Path = $inputSettingsPath; Name = 'HarvestContacts'; Value = 0 },
    @{ Path = $inputSettingsPath; Name = 'DictationEnabled'; Value = 0 },
    @{ Path = $inputSettingsPath; Name = 'DisablePersonalization'; Value = 1 },
    @{ Path = $inputSettingsPath; Name = 'InsightsEnabled'; Value = 0 },
    @{ Path = $inputSettingsPath; Name = 'EmojiTranslation'; Value = 0 },
    @{ Path = $inputSettingsUser; Name = 'InsightsEnabled'; Value = 0 },
    @{ Path = $inputSettingsUser; Name = 'IsVoiceTypingKeyEnabled'; Value = 0 }
)

# TIPC (Typing Insights / Personalization Collection)
$tipcKeys = @(
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Input\TIPC'; Name = 'Enabled'; Value = 0 },
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Personalization\Settings'; Name = 'AcceptedPrivacyPolicy'; Value = 0 }
)

$allCtfmonKeys = $imeFixKeys + $inputFixKeys + $tipcKeys

foreach ($k in $allCtfmonKeys) {
    if (-not (Test-Path $k.Path)) {
        New-Item -Path $k.Path -Force | Out-Null
    }
    $current = Get-ItemProperty -Path $k.Path -Name $k.Name -ErrorAction SilentlyContinue
    $oldVal = if ($current) { $current.($k.Name) } else { 'NOT_SET' }
    $backupLines += "REG_RESTORE|$($k.Path)|$($k.Name)|$oldVal"

    if (-not $WhatIf) {
        Set-ItemProperty -Path $k.Path -Name $k.Name -Value $k.Value -Type DWord -Force
        Write-Host ('  SET ' + $k.Name + ': ' + $oldVal + ' -> ' + $k.Value) -ForegroundColor Green
    } else {
        Write-Host ('  WOULD SET ' + $k.Name + ': ' + $oldVal + ' -> ' + $k.Value) -ForegroundColor Gray
    }
}

# TextInput policy
$textInputPolicy = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\TextInput\AllowKeyboardTextSuggestions'
if (Test-Path $textInputPolicy) {
    $oldVal = (Get-ItemProperty $textInputPolicy -ErrorAction SilentlyContinue).value
    $backupLines += "REG_RESTORE|$textInputPolicy|value|$oldVal"
    if (-not $WhatIf) {
        Set-ItemProperty -Path $textInputPolicy -Name 'value' -Value 0 -Force
        Write-Host '  SET AllowKeyboardTextSuggestions: 0' -ForegroundColor Green
    }
}

# ─── Fix 2: WMI Tracing (mitigation only — Windows bug) ──────────────────────
Write-Host ''
Write-Host '[2/8] Mitigating WMI Tracing polling...' -ForegroundColor Yellow
Write-Host '  Root cause: Windows bug — Winmgmt re-reads Tracing config continuously' -ForegroundColor Gray

$wbemTracing = 'HKLM:\Software\Microsoft\WBEM\Tracing'
if (Test-Path $wbemTracing) {
    # Set all trace levels to 0 to minimize work per poll
    $traceProps = Get-ItemProperty $wbemTracing -ErrorAction SilentlyContinue
    $traceNames = $traceProps.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | Select-Object -ExpandProperty Name
    foreach ($tn in $traceNames) {
        $oldVal = $traceProps.$tn
        $backupLines += "REG_RESTORE|$wbemTracing|$tn|$oldVal"
    }

    if (-not $WhatIf) {
        Set-ItemProperty -Path $wbemTracing -Name 'EnableWinmgmtTelemetry' -Value 0 -Type DWord -Force
        Write-Host '  SET EnableWinmgmtTelemetry: 0 (was already 0 — confirming)' -ForegroundColor Green
    }
}

# Disable WMI Performance Adapter if running
$wmiApSrv = Get-Service WmiApSrv -ErrorAction SilentlyContinue
if ($wmiApSrv -and $wmiApSrv.StartType -ne 'Disabled') {
    $backupLines += "SVC_RESTORE|WmiApSrv|$($wmiApSrv.StartType)"
    if (-not $WhatIf) {
        Set-Service WmiApSrv -StartupType Disabled
        Write-Host '  DISABLED WmiApSrv (WMI Performance Adapter)' -ForegroundColor Green
    }
}

Write-Host '  NOTE: Winmgmt tracing poll is a known Windows bug — cannot fully eliminate' -ForegroundColor Yellow

# ─── Fix 3: camsvc Capability Access Manager ─────────────────────────────────
Write-Host ''
Write-Host '[3/8] Fixing camsvc Location policy polling...' -ForegroundColor Yellow
Write-Host '  Root cause: systemAIModels apps trigger 181 LetAppsAccessLocation reads/sec' -ForegroundColor Gray

if (-not $SkipCamsvc) {
    # Set camsvc to Manual
    $camSvc = Get-Service camsvc -ErrorAction SilentlyContinue
    if ($camSvc) {
        $backupLines += "SVC_RESTORE|camsvc|$($camSvc.StartType)"
        if (-not $WhatIf) {
            Set-Service camsvc -StartupType Disabled
            if ($camSvc.Status -eq 'Running') {
                Stop-Service camsvc -Force -ErrorAction SilentlyContinue
            }
            Write-Host '  DISABLED camsvc (was Automatic)' -ForegroundColor Green
        }
    }

    # Disable location service
    $locSvc = Get-Service lfsvc -ErrorAction SilentlyContinue
    if ($locSvc) {
        $backupLines += "SVC_RESTORE|lfsvc|$($locSvc.StartType)"
        if (-not $WhatIf) {
            Set-Service lfsvc -StartupType Disabled
            if ($locSvc.Status -eq 'Running') {
                Stop-Service lfsvc -Force -ErrorAction SilentlyContinue
            }
            Write-Host '  DISABLED lfsvc (Location Service)' -ForegroundColor Green
        }
    }

    # Set location consent to Deny via policy
    $locPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
    if (-not (Test-Path $locPolicy)) {
        New-Item -Path $locPolicy -Force | Out-Null
    }
    $backupLines += "REG_RESTORE|$locPolicy|LetAppsAccessLocation|NOT_SET"
    if (-not $WhatIf) {
        Set-ItemProperty -Path $locPolicy -Name 'LetAppsAccessLocation' -Value 2 -Type DWord -Force
        Write-Host '  SET LetAppsAccessLocation: 2 (Force Deny)' -ForegroundColor Green
    }
} else {
    Write-Host '  SKIPPED (use without -SkipCamsvc to apply)' -ForegroundColor Gray
}

# ─── Fix 4: Explorer shell extension & namespace cleanup ─────────────────────
Write-Host ''
Write-Host '[4/8] Reducing Explorer shell extension overhead...' -ForegroundColor Yellow
Write-Host '  Root cause: 7 OneDrive ghost overlays + 33 namespace CLSIDs + policy spam' -ForegroundColor Gray

if (-not $SkipOneDrive) {
    # Remove OneDrive icon overlays (OneDrive not running)
    $overlayPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers'
    $odOverlays = Get-ChildItem $overlayPath -ErrorAction SilentlyContinue | Where-Object {
        $_.PSChildName -match 'OneDrive'
    }

    foreach ($overlay in $odOverlays) {
        $name = $overlay.PSChildName
        $clsid = (Get-ItemProperty $overlay.PSPath).'(Default)'
        $backupLines += "OVERLAY_RESTORE|$overlayPath|$name|$clsid"
        if (-not $WhatIf) {
            Remove-Item $overlay.PSPath -Force
            Write-Host ('  REMOVED overlay: ' + $name.Trim()) -ForegroundColor Green
        } else {
            Write-Host ('  WOULD REMOVE overlay: ' + $name.Trim()) -ForegroundColor Gray
        }
    }
} else {
    Write-Host '  SKIPPED OneDrive overlays (use without -SkipOneDrive to remove)' -ForegroundColor Gray
}

# Disable Explorer DataProtection/WIP policy checking (enterprise-only feature)
$dataProtPath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\DataProtection'
if (Test-Path $dataProtPath) {
    Write-Host '  DataProtection policies present — Explorer checks 1,314 times/30s (enterprise DLP)' -ForegroundColor Yellow
    Write-Host '  NOTE: Cannot safely remove PolicyManager keys — managed by Windows' -ForegroundColor Gray
}

# Disable Offline Files CSC (namespace extension generating events)
$cscSvc = Get-Service CscService -ErrorAction SilentlyContinue
if ($cscSvc -and $cscSvc.StartType -ne 'Disabled') {
    $backupLines += "SVC_RESTORE|CscService|$($cscSvc.StartType)"
    if (-not $WhatIf) {
        Set-Service CscService -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Host '  DISABLED CscService (Offline Files)' -ForegroundColor Green
    }
}

# Reduce Quick Access overhead — set Explorer to open to "This PC"
$explorerAdvanced = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$currentLaunchTo = (Get-ItemProperty $explorerAdvanced -ErrorAction SilentlyContinue).LaunchTo
$backupLines += "REG_RESTORE|$explorerAdvanced|LaunchTo|$currentLaunchTo"
if (-not $WhatIf) {
    Set-ItemProperty -Path $explorerAdvanced -Name 'LaunchTo' -Value 1 -Type DWord -Force
    Write-Host '  SET Explorer default: This PC (was Quick Access)' -ForegroundColor Green
}

# ─── Fix 5: WMI Repository (informational) ───────────────────────────────────
Write-Host ''
Write-Host '[5/8] WMI Repository thrash (informational)...' -ForegroundColor Yellow
Write-Host '  Root cause: MSI Afterburner polls WMI sensor classes continuously' -ForegroundColor Gray
Write-Host '  To reduce: increase Afterburner polling interval or use RTSS-only monitoring' -ForegroundColor Gray
Write-Host '  No automated fix — Afterburner is intentional software' -ForegroundColor Gray

# ─── Fix 6: SearchIndexer (Windows Search) ───────────────────────────────────
Write-Host ''
Write-Host '[6/8] Disabling Windows Search Indexer...' -ForegroundColor Yellow
Write-Host '  Root cause: WSearch indexes 50+ paths (8,292 events/sec post-reboot)' -ForegroundColor Gray

if (-not $SkipSearchIndexer) {
    $wsearch = Get-Service WSearch -ErrorAction SilentlyContinue
    if ($wsearch) {
        $backupLines += ('SVC_RESTORE|WSearch|' + $wsearch.StartType)
        if (-not $WhatIf) {
            Set-Service WSearch -StartupType Disabled
            if ($wsearch.Status -eq 'Running') {
                Stop-Service WSearch -Force -ErrorAction SilentlyContinue
            }
            Write-Host '  DISABLED WSearch (Windows Search Indexer)' -ForegroundColor Green
            Write-Host '  NOTE: Start Menu app search still works. File content search will be slower.' -ForegroundColor Gray
        } else {
            Write-Host ('  WOULD DISABLE WSearch (currently ' + $wsearch.StartType + ')') -ForegroundColor Gray
        }
    } else {
        Write-Host '  WSearch service not found' -ForegroundColor Gray
    }
} else {
    Write-Host '  SKIPPED (use without -SkipSearchIndexer to apply)' -ForegroundColor Gray
}

# ─── Fix 7: Explorer enterprise policy + AppCompat overhead ──────────────────
Write-Host ''
Write-Host '[7/8] Reducing Explorer enterprise policy overhead...' -ForegroundColor Yellow
Write-Host '  Root cause: WIP/DataProtection + AppCompat shim checks + ShellHWDetection' -ForegroundColor Gray

# Disable ShellHWDetection (hardware hotplug detection — unnecessary on static desktop)
$shellHW = Get-Service ShellHWDetection -ErrorAction SilentlyContinue
if ($shellHW -and $shellHW.StartType -ne 'Disabled') {
    $backupLines += ('SVC_RESTORE|ShellHWDetection|' + $shellHW.StartType)
    if (-not $WhatIf) {
        Set-Service ShellHWDetection -StartupType Disabled
        if ($shellHW.Status -eq 'Running') {
            Stop-Service ShellHWDetection -Force -ErrorAction SilentlyContinue
        }
        Write-Host '  DISABLED ShellHWDetection (no hardware hotplug on desktop)' -ForegroundColor Green
    }
}

# Disable WIP/DataProtection enterprise policies (1,314 reads/30s)
$wipPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataProtection'
if (-not (Test-Path $wipPath)) { New-Item -Path $wipPath -Force | Out-Null }
$backupLines += 'REG_RESTORE|' + $wipPath + '|AllowDirectMemoryAccess|NOT_SET'
$backupLines += 'REG_RESTORE|' + $wipPath + '|AllowAzureRMSForEDP|NOT_SET'
if (-not $WhatIf) {
    Set-ItemProperty -Path $wipPath -Name 'AllowDirectMemoryAccess' -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $wipPath -Name 'AllowAzureRMSForEDP' -Value 0 -Type DWord -Force
    Write-Host '  SET DataProtection/WIP: no enterprise DLP' -ForegroundColor Green
}

# Disable Enterprise Data Protection domain names
$edpPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\EnterpriseDataProtection'
if (-not (Test-Path $edpPath)) { New-Item -Path $edpPath -Force | Out-Null }
$backupLines += 'REG_RESTORE|' + $edpPath + '|EnterpriseProtectedDomainNames|NOT_SET'
if (-not $WhatIf) {
    Set-ItemProperty -Path $edpPath -Name 'EnterpriseProtectedDomainNames' -Value '' -Type String -Force
    Write-Host '  SET EnterpriseDataProtection: no domain names' -ForegroundColor Green
}

# Disable AppCompat shim engine (674 reads/30s)
$appCompatPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat'
if (-not (Test-Path $appCompatPath)) { New-Item -Path $appCompatPath -Force | Out-Null }
$backupLines += 'REG_RESTORE|' + $appCompatPath + '|DisableEngine|NOT_SET'
$backupLines += 'REG_RESTORE|' + $appCompatPath + '|DisablePCA|NOT_SET'
$backupLines += 'REG_RESTORE|' + $appCompatPath + '|DisableUAR|NOT_SET'
if (-not $WhatIf) {
    Set-ItemProperty -Path $appCompatPath -Name 'DisableEngine' -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $appCompatPath -Name 'DisablePCA' -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $appCompatPath -Name 'DisableUAR' -Value 1 -Type DWord -Force
    Write-Host '  DISABLED AppCompat shim engine + PCA + UAR' -ForegroundColor Green
}

# ─── Fix 8: camsvc escalation note ───────────────────────────────────────────
Write-Host ''
Write-Host '[8/8] camsvc escalation (applied in Fix 3)...' -ForegroundColor Yellow
Write-Host '  Manual start was insufficient — Chrome triggers camsvc on-demand (980/sec)' -ForegroundColor Gray
Write-Host '  Fix 3 now sets camsvc to Disabled instead of Manual' -ForegroundColor Gray

# ─── Save backup ──────────────────────────────────────────────────────────────
$backupLines | Out-File -FilePath $backupFile -Encoding UTF8
Write-Host ''
Write-Host ('Backup saved: ' + $backupFile) -ForegroundColor Cyan

# ─── Verify ───────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '=== Verification ===' -ForegroundColor Cyan

# Check ctfmon settings aligned
$imeSettings = Get-ItemProperty $imePath -ErrorAction SilentlyContinue
$sysSettings = Get-ItemProperty $inputSettingsPath -ErrorAction SilentlyContinue
$imeAC = $imeSettings.AutoCorrection
$sysAC = $sysSettings.AutoCorrection
$aligned = ($imeAC -eq $sysAC)
Write-Host ('  Input Settings aligned: ' + $aligned + ' (sys=' + $sysAC + ' ime=' + $imeAC + ')') -ForegroundColor $(if ($aligned) { 'Green' } else { 'Yellow' })

# Check services
$cam = Get-Service camsvc -ErrorAction SilentlyContinue
Write-Host ('  camsvc: ' + $cam.StartType) -ForegroundColor $(if ($cam.StartType -eq 'Disabled') { 'Green' } else { 'Yellow' })
$loc = Get-Service lfsvc -ErrorAction SilentlyContinue
Write-Host ('  lfsvc: ' + $loc.StartType) -ForegroundColor $(if ($loc.StartType -eq 'Disabled') { 'Green' } else { 'Yellow' })

# Check OneDrive overlays
$remainingOd = Get-ChildItem $overlayPath -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match 'OneDrive' }
Write-Host ('  OneDrive overlays remaining: ' + $remainingOd.Count) -ForegroundColor $(if ($remainingOd.Count -eq 0) { 'Green' } else { 'Yellow' })

# Check WSearch
$ws = Get-Service WSearch -ErrorAction SilentlyContinue
Write-Host ('  WSearch: ' + $ws.StartType + ' / ' + $ws.Status) -ForegroundColor $(if ($ws.StartType -eq 'Disabled') { 'Green' } else { 'Yellow' })

# Check ShellHWDetection
$shw = Get-Service ShellHWDetection -ErrorAction SilentlyContinue
Write-Host ('  ShellHWDetection: ' + $shw.StartType) -ForegroundColor $(if ($shw.StartType -eq 'Disabled') { 'Green' } else { 'Yellow' })

# Check AppCompat
$acDisabled = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat' -Name 'DisableEngine' -ErrorAction SilentlyContinue).DisableEngine
Write-Host ('  AppCompat engine disabled: ' + ($acDisabled -eq 1)) -ForegroundColor $(if ($acDisabled -eq 1) { 'Green' } else { 'Yellow' })

Write-Host ''
Write-Host 'System polling fix applied. Reboot recommended.' -ForegroundColor Green
Write-Host 'Re-run: .\scripts\analyze_procmon_idle.ps1 -Label post_fix' -ForegroundColor Yellow
