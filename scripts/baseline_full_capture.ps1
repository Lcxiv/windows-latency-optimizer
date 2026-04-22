<#
.SYNOPSIS
    End-to-end full-suite baseline capture orchestrator.
.DESCRIPTION
    Runs a 5-phase forensic baseline capture:

      Phase 0 — Preflight (admin check, disk space, tool paths, WPR session,
                 registry state, tool versions)
      Phase 1 — Pre-freeze state snapshot (audit Deep, registry snapshot)
      Phase 2 — Idle baseline (WPR + xperf + perf + GPU + ProcMon + LatencyMon
                 + PresentMon, all sequential to avoid measurement interference)
      Phase 3 — Synthetic load baseline (Prime95 SmallFFT + bounded disk burn,
                 repeat Phase 2 capture steps)
      Phase 4 — Aggregation (MASTER.html, dashboard entry, regen dashboard data)

    Output: captures/baselines/<Label>_<YYYYMMDD-HHMMSS>/ with phase subdirs
    and a single MASTER.html + manifest.json.

    LatencyMon is CLI-preflighted once in Phase 0. If CLI flags don't work,
    the run SKIPS LatencyMon cleanly and sets manifest.latmon_skipped = true.
    No interactive prompts — clean auto-execution for Mode 7.
.EXAMPLE
    .\baseline_full_capture.ps1 -Label BASELINE_POST_REBOOT_CLEAN
.EXAMPLE
    .\baseline_full_capture.ps1 -Label BASELINE_POST_REBOOT_CLEAN -SkipLoad -LatmonDurationSec 60
#>
#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$Label,

    [switch]$SkipLoad,

    [ValidateRange(30, 3600)]
    [int]$LatmonDurationSec = 300,

    [ValidateRange(10, 600)]
    [int]$CaptureSec = 60,

    [string]$OutputRoot = '',

    [string]$Prime95Dir = ''
)

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot
$projectRoot = Split-Path $scriptRoot -Parent

if ($OutputRoot -eq '') {
    $OutputRoot = Join-Path $projectRoot 'captures\baselines'
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDir = Join-Path $OutputRoot ($Label + '_' + $timestamp)

# State for trap handler cleanup
$script:cleanupState = @{
    wpr_active = $false
    procmon_active = $false
    latmon_active = $false
    syntheticLoadActive = $false
    runDir = $runDir
}

# ── Utility functions ──────────────────────────────────────────────────────

function Write-Phase {
    param([string]$Msg)
    Write-Host ('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Msg) -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Msg)
    Write-Host ('  -> ' + $Msg) -ForegroundColor Yellow
}

function Test-ToolPath {
    param([string]$Path, [string]$Name, [switch]$Required)
    if (Test-Path $Path) { return $true }
    if ($Required) {
        throw ('Required tool not found: ' + $Name + ' at ' + $Path)
    }
    Write-Warning ('Optional tool missing: ' + $Name + ' at ' + $Path)
    return $false
}

function Stop-AllCaptures {
    Write-Warning 'Cleanup triggered — stopping any active captures.'
    if ($script:cleanupState.wpr_active) {
        try { & wpr.exe -cancel 2>&1 | Out-Null } catch {}
    }
    if ($script:cleanupState.procmon_active) {
        try { Get-Process -Name 'Procmon64' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
    }
    if ($script:cleanupState.latmon_active) {
        try { Get-Process -Name 'LatMon' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
    }
    if ($script:cleanupState.syntheticLoadActive) {
        try { & (Join-Path $scriptRoot 'synthetic_load.ps1') -Stop 2>&1 | Out-Null } catch {}
    }
}

function Get-ToolPaths {
    $paths = @{
        wpr = Join-Path $env:SystemRoot 'System32\wpr.exe'
        xperf = ''
        procmon = 'C:\Users\L\Desktop\ProcessMonitor\Procmon64.exe'
        latmon = 'C:\Program Files\LatencyMon\LatMon.exe'
        presentmon = 'C:\Program Files\NVIDIA Corporation\FrameView\bin\PresentMon_x64.exe'
        prime95 = ''
    }

    # Find xperf
    $xperfCandidates = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Windows Performance Toolkit\xperf.exe",
        "$env:ProgramFiles\Windows Kits\10\Windows Performance Toolkit\xperf.exe"
    )
    foreach ($p in $xperfCandidates) {
        if (Test-Path $p) { $paths.xperf = $p; break }
    }

    # Find Prime95
    if ($Prime95Dir -ne '') {
        $candidate = Join-Path $Prime95Dir 'prime95.exe'
        if (Test-Path $candidate) { $paths.prime95 = $candidate }
    }
    if ($paths.prime95 -eq '') {
        $candidate = Join-Path $projectRoot 'p95v3019b20.win64\prime95.exe'
        if (Test-Path $candidate) { $paths.prime95 = $candidate }
    }

    return $paths
}

function Test-LatencyMonCli {
    param([string]$LatMonExe)

    if (-not (Test-Path $LatMonExe)) { return $false }

    # Dry-run test: start + 2s sleep + stop. If any step fails, return false.
    try {
        $proc = Start-Process -FilePath $LatMonExe -ArgumentList '/startmonitoring' -PassThru -WindowStyle Hidden -ErrorAction Stop
        Start-Sleep -Seconds 2
        Start-Process -FilePath $LatMonExe -ArgumentList '/stopmonitoring' -Wait -WindowStyle Hidden -ErrorAction Stop
        Get-Process -Name 'LatMon' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        Get-Process -Name 'LatMon' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        return $false
    }
}

# ── Phase 0: Preflight ─────────────────────────────────────────────────────

function Invoke-Phase0 {
    param([hashtable]$Tools)

    Write-Phase 'Phase 0: Preflight checks'

    # Admin (already required by #Requires, but verify explicitly)
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw 'Must run as Administrator.' }
    Write-Step 'Admin: OK'

    # Disk space
    $drive = Get-PSDrive -Name 'C'
    $freeGb = [Math]::Round($drive.Free / 1GB, 1)
    if ($freeGb -lt 10) { throw ('Insufficient disk space. Need 10 GB, have ' + $freeGb + ' GB.') }
    Write-Step ('Disk: ' + $freeGb + ' GB free')

    # Tool paths — hard-fail on required
    $wprOk = Test-ToolPath -Path $Tools.wpr -Name 'wpr.exe' -Required
    $xperfOk = Test-ToolPath -Path $Tools.xperf -Name 'xperf.exe' -Required
    $prime95Ok = $SkipLoad -or (Test-ToolPath -Path $Tools.prime95 -Name 'prime95.exe')
    $procmonOk = Test-ToolPath -Path $Tools.procmon -Name 'Procmon64.exe'
    $latmonOk = Test-ToolPath -Path $Tools.latmon -Name 'LatMon.exe'
    $presentmonOk = Test-ToolPath -Path $Tools.presentmon -Name 'PresentMon_x64.exe'

    # Active WPR session check
    $wprStatus = & wpr.exe -status 2>&1
    if ($wprStatus -match 'profile is on') {
        throw ('Existing WPR session detected. Run "wpr -cancel" first.')
    }
    Write-Step 'WPR: no active session'

    # Create tree
    $subdirs = @('00_preflight', '10_prefreeze', '20_idle', '30_loaded', '40_aggregate')
    foreach ($sd in $subdirs) {
        $p = Join-Path $runDir $sd
        New-Item -ItemType Directory -Path $p -Force | Out-Null
    }
    Write-Step ('Output tree created: ' + $runDir)

    # Registry pre-flight snapshot
    $regOut = Join-Path $runDir '00_preflight\registry_state_preflight.txt'
    $regKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\Dwm',
        'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    )
    $regContent = New-Object System.Text.StringBuilder
    [void]$regContent.AppendLine('# Registry state preflight — ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    [void]$regContent.AppendLine('')
    foreach ($key in $regKeys) {
        [void]$regContent.AppendLine('## ' + $key)
        if (Test-Path $key) {
            $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
            if ($props) {
                foreach ($name in ($props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | Select-Object -ExpandProperty Name)) {
                    [void]$regContent.AppendLine(('  ' + $name + ' = ' + $props.$name))
                }
            } else {
                [void]$regContent.AppendLine('  (key exists, no named values)')
            }
        } else {
            [void]$regContent.AppendLine('  (key does not exist)')
        }
        [void]$regContent.AppendLine('')
    }
    Set-Content -Path $regOut -Value $regContent.ToString() -Encoding UTF8
    Write-Step ('Registry preflight dumped to ' + $regOut)

    # Tool versions
    $versionsOut = Join-Path $runDir '00_preflight\tool_versions.json'
    $versions = @{
        wpr = if ($wprOk) { try { (& wpr.exe -help 2>&1 | Select-Object -First 1) } catch { 'unknown' } } else { 'missing' }
        xperf = if ($xperfOk) { try { ((& $Tools.xperf 2>&1) -join "`n" | Select-String -Pattern 'Version \S+' | Select-Object -First 1).Matches.Value } catch { 'unknown' } } else { 'missing' }
        prime95 = if ($Tools.prime95 -and (Test-Path $Tools.prime95)) { 'prime95.exe present' } else { 'missing' }
        procmon = if ($procmonOk) { 'Procmon64.exe present' } else { 'missing' }
        latmon = if ($latmonOk) { 'LatMon.exe present' } else { 'missing' }
        presentmon = if ($presentmonOk) { 'PresentMon_x64.exe present' } else { 'missing' }
    }
    $versions | ConvertTo-Json -Depth 5 | Set-Content -Path $versionsOut -Encoding UTF8

    # Disk space record
    $dsOut = Join-Path $runDir '00_preflight\disk_space.json'
    @{ drive = 'C:'; free_gb = $freeGb; total_gb = [Math]::Round(($drive.Used + $drive.Free) / 1GB, 1) } | ConvertTo-Json | Set-Content -Path $dsOut -Encoding UTF8

    # Admin check record
    $adminOut = Join-Path $runDir '00_preflight\admin_check.txt'
    Set-Content -Path $adminOut -Value 'Administrator: TRUE' -Encoding UTF8

    # LatencyMon CLI preflight
    $latmonCliOk = $false
    if ($latmonOk) {
        Write-Step 'Testing LatencyMon CLI flags...'
        $latmonCliOk = Test-LatencyMonCli -LatMonExe $Tools.latmon
        if ($latmonCliOk) {
            Write-Step 'LatencyMon CLI: OK'
        } else {
            Write-Warning 'LatencyMon CLI test failed. LatencyMon will be SKIPPED for this run.'
        }
    }

    return @{
        latmonAvailable = $latmonCliOk
        presentmonAvailable = $presentmonOk
        procmonAvailable = $procmonOk
    }
}

# ── Phase 1: Pre-freeze ────────────────────────────────────────────────────

function Invoke-Phase1 {
    Write-Phase 'Phase 1: Pre-freeze state snapshot'

    $prefreezeDir = Join-Path $runDir '10_prefreeze'
    $auditScript = Join-Path $scriptRoot 'audit.ps1'

    if (Test-Path $auditScript) {
        Write-Step 'Running audit.ps1 -Mode Deep...'
        & $auditScript -Mode Deep -OutDir $prefreezeDir -Quiet
        # audit.ps1 writes audit_<timestamp>.json/html — copy to expected name
        $auditJson = Get-ChildItem -Path $prefreezeDir -Filter 'audit_*.json' | Sort-Object Name -Descending | Select-Object -First 1
        $auditHtml = Get-ChildItem -Path $prefreezeDir -Filter 'audit_*.html' | Sort-Object Name -Descending | Select-Object -First 1
        if ($auditJson) {
            Copy-Item -Path $auditJson.FullName -Destination (Join-Path $prefreezeDir 'audit_deep.json') -Force
            $auditData = Get-Content $auditJson.FullName -Raw | ConvertFrom-Json
            $score = if ($auditData.score) { $auditData.score } elseif ($auditData.summary -and $auditData.summary.score) { $auditData.summary.score } else { -1 }
            Write-Step ('Audit score: ' + $score + '%')
            if ($score -ge 0 -and $score -lt 90) {
                Write-Warning ('Audit score below 90% threshold (' + $score + '%). Baseline may be polluted.')
            }
        }
        if ($auditHtml) {
            Copy-Item -Path $auditHtml.FullName -Destination (Join-Path $prefreezeDir 'audit_deep.html') -Force
        }
    } else {
        Write-Warning 'audit.ps1 not found — skipping pre-freeze audit.'
    }

    # Registry full snapshot (richer than preflight)
    $regSnap = Join-Path $prefreezeDir 'registry_snapshot.txt'
    $keys = @(
        'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers',
        'HKLM:\SOFTWARE\Microsoft\Windows\Dwm',
        'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl',
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile',
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# Pre-freeze registry snapshot — ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    foreach ($k in $keys) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('## ' + $k)
        if (Test-Path $k) {
            try {
                $props = Get-ItemProperty -Path $k -ErrorAction Stop
                foreach ($name in ($props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | Select-Object -ExpandProperty Name)) {
                    [void]$sb.AppendLine(('  ' + $name + ' = ' + $props.$name))
                }
            } catch {
                [void]$sb.AppendLine('  (read failed: ' + $_.Exception.Message + ')')
            }
        } else {
            [void]$sb.AppendLine('  (key not present)')
        }
    }
    Set-Content -Path $regSnap -Value $sb.ToString() -Encoding UTF8
    Write-Step ('Registry snapshot written: ' + $regSnap)
}

# ── Phase 2/3: Capture (parameterized by phase name) ────────────────────────

function Invoke-CapturePhase {
    param(
        [string]$PhaseName,     # 'idle' or 'loaded'
        [string]$PhaseDir,
        [hashtable]$Tools,
        [hashtable]$PhaseFlags
    )

    Write-Phase ('Phase 2/3: ' + $PhaseName + ' capture')

    # 1. WPR trace
    Write-Step ('WPR trace (' + $CaptureSec + 's)...')
    $etlPath = Join-Path $PhaseDir ('wpr_' + $PhaseName + '.etl')
    $script:cleanupState.wpr_active = $true
    & wpr.exe -start CPU -start GPU -start DiskIO -start Network -filemode 2>&1 | Out-Null
    Start-Sleep -Seconds $CaptureSec
    & wpr.exe -stop $etlPath 2>&1 | Out-Null
    $script:cleanupState.wpr_active = $false

    # 2. xperf DPC/ISR extract — parses "CPU Usage Summing By Module" table
    # from xperf -a dpcisr output (the DPC Info section is empty for default
    # WPR GeneralProfile captures; CPU Usage By Module is richer).
    Write-Step 'xperf DPC/ISR analysis...'
    $xperfJsonPath = Join-Path $PhaseDir ('xperf_' + $PhaseName + '.json')
    $xperfRawPath = Join-Path $PhaseDir ('xperf_' + $PhaseName + '_raw.txt')
    try {
        $xperfOut = & $Tools.xperf -i $etlPath -a dpcisr 2>&1
        Set-Content -Path $xperfRawPath -Value $xperfOut -Encoding UTF8

        # Parse "CPU Usage Summing By Module" — each data row is 16 per-CPU
        # "usec %," columns then a final ", driver_name". Module name on the
        # RIGHT, not left. We sum the usec column across all 16 CPUs to rank.
        $topDrivers = @()
        $inTable = $false
        foreach ($ln in Get-Content $xperfRawPath) {
            if ($ln -match 'CPU Usage Summing By Module') { $inTable = $true; continue }
            if ($inTable -and ($ln -match '^Total\s*=') ) { $inTable = $false; continue }
            if (-not $inTable) { continue }
            if ($ln -match ',\s*([A-Za-z0-9_\-\.]+\.(sys|exe|dll))\s*$') {
                $drv = $Matches[1]
                # Extract all "usec %" pairs from the line
                $cpuMatches = [regex]::Matches($ln, '(\d+)\s+(\d+\.\d+),')
                $usecSum = 0
                $pctSum = 0.0
                foreach ($m in $cpuMatches) {
                    $usecSum += [int64]$m.Groups[1].Value
                    $pctSum += [double]$m.Groups[2].Value
                }
                $topDrivers += [PSCustomObject]@{ driver = $drv; total_usec = $usecSum; total_pct = [Math]::Round($pctSum, 3) }
            }
        }
        @{
            phase = $PhaseName
            top_drivers = @($topDrivers | Sort-Object -Property total_usec -Descending | Select-Object -First 15)
            total_dpcs = $null
            total_isrs = $null
            parse_source = 'CPU Usage Summing By Module'
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $xperfJsonPath -Encoding UTF8
    } catch {
        Write-Warning ('xperf extraction failed: ' + $_.Exception.Message)
        @{ phase = $PhaseName; error = $_.Exception.Message } | ConvertTo-Json | Set-Content -Path $xperfJsonPath -Encoding UTF8
    }

    # 3. Perf + GPU (pipeline.ps1 with skips, reuse existing)
    Write-Step 'Perf counters + GPU...'
    $perfJsonPath = Join-Path $PhaseDir ('pipeline_' + $PhaseName + '.json')
    $pipelineScript = Join-Path $scriptRoot 'pipeline.ps1'
    if (Test-Path $pipelineScript) {
        # Use Mode Quick equivalent: short capture, skip WPR (already have it), skip ProcMon (do separately)
        try {
            & $pipelineScript -Label ('BASELINE_' + $PhaseName.ToUpper()) `
                -Description ('Baseline phase ' + $PhaseName) `
                -DurationSec $CaptureSec `
                -SkipWPR -SkipProcMon -SkipPresentMon -SkipDashboardUpdate `
                -SkipDefenderRecording -SkipPktMon -SkipBufferbloat -SkipNetworkLatency 2>&1 | Out-Null
            # Find latest experiment JSON it wrote
            $expDir = Join-Path $projectRoot 'captures\experiments'
            $latest = Get-ChildItem -Path $expDir -Filter 'experiment.json' -Recurse -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latest) {
                Copy-Item -Path $latest.FullName -Destination $perfJsonPath -Force
            }
        } catch {
            Write-Warning ('pipeline.ps1 failed: ' + $_.Exception.Message)
        }
    }
    if (-not (Test-Path $perfJsonPath)) {
        @{ phase = $PhaseName; note = 'pipeline output unavailable' } | ConvertTo-Json | Set-Content -Path $perfJsonPath -Encoding UTF8
    }

    # 4. ProcMon
    if ($PhaseFlags.procmonAvailable) {
        Write-Step ('ProcMon trace (' + $CaptureSec + 's)...')
        $pmlPath = Join-Path $PhaseDir ('procmon_' + $PhaseName + '.pml')
        $csvPath = Join-Path $PhaseDir ('procmon_' + $PhaseName + '.csv')
        $script:cleanupState.procmon_active = $true
        try {
            Start-Process -FilePath $Tools.procmon -ArgumentList ('/Quiet', '/Minimized', '/BackingFile', $pmlPath, '/RunTime', $CaptureSec) -Wait -NoNewWindow
            Start-Process -FilePath $Tools.procmon -ArgumentList ('/OpenLog', $pmlPath, '/SaveAs', $csvPath, '/SaveApplyFilter') -Wait -NoNewWindow
            # analyze_procmon on the CSV
            $analyzeScript = Join-Path $scriptRoot 'analyze_procmon.ps1'
            $analyzeOutPath = Join-Path $PhaseDir ('procmon_' + $PhaseName + '_analyzed.json')
            if ((Test-Path $analyzeScript) -and (Test-Path $csvPath)) {
                # analyze_procmon.ps1 currently reads from fixed path — wrap in tmp-symlink-free approach
                $csv = Import-Csv $csvPath
                $total = $csv.Count
                $topProcs = $csv | Group-Object 'Process Name' | Sort-Object Count -Descending | Select-Object -First 10
                $topProcsArr = @($topProcs | ForEach-Object {
                    @{
                        name = $_.Name
                        count = $_.Count
                        pct = [Math]::Round(($_.Count / $total * 100), 2)
                    }
                })
                @{
                    phase = $PhaseName
                    total_events = $total
                    duration_sec = $CaptureSec
                    events_per_sec = [Math]::Round($total / $CaptureSec, 1)
                    top_processes = $topProcsArr
                } | ConvertTo-Json -Depth 10 | Set-Content -Path $analyzeOutPath -Encoding UTF8
            }
        } catch {
            Write-Warning ('ProcMon capture failed: ' + $_.Exception.Message)
        } finally {
            $script:cleanupState.procmon_active = $false
        }
    }

    # 5. LatencyMon
    if ($PhaseFlags.latmonAvailable) {
        Write-Step ('LatencyMon (' + $LatmonDurationSec + 's)...')
        $latmonOut = Join-Path $PhaseDir ('latmon_' + $PhaseName + '_report.txt')
        $script:cleanupState.latmon_active = $true
        try {
            Start-Process -FilePath $Tools.latmon -ArgumentList '/startmonitoring' -WindowStyle Hidden
            Start-Sleep -Seconds $LatmonDurationSec
            Start-Process -FilePath $Tools.latmon -ArgumentList ('/stopmonitoring', '/export', $latmonOut) -Wait -WindowStyle Hidden
        } catch {
            Write-Warning ('LatencyMon capture failed: ' + $_.Exception.Message)
        } finally {
            Get-Process -Name 'LatMon' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            $script:cleanupState.latmon_active = $false
        }
    }

    # 6. PresentMon
    if ($PhaseFlags.presentmonAvailable) {
        Write-Step ('PresentMon (' + $CaptureSec + 's)...')
        $pmCsv = Join-Path $PhaseDir ('presentmon_' + $PhaseName + '.csv')
        try {
            Start-Process -FilePath $Tools.presentmon -ArgumentList ('-timed', $CaptureSec, '-output_file', $pmCsv, '-terminate_existing_session') -Wait -WindowStyle Hidden
        } catch {
            Write-Warning ('PresentMon capture failed: ' + $_.Exception.Message)
        }
    }

    Write-Step ('Phase ' + $PhaseName + ' capture complete')
}

# ── Phase 3 wrapper: start load + capture + stop ──────────────────────────

function Invoke-Phase3 {
    param([hashtable]$Tools, [hashtable]$PhaseFlags)

    Write-Phase 'Phase 3: Synthetic load baseline'

    $loadedDir = Join-Path $runDir '30_loaded'
    $loadConfigPath = Join-Path $loadedDir 'synthetic_load_config.json'

    Write-Step 'Starting synthetic load (Prime95 SmallFFT + disk burn)...'
    $loadScript = Join-Path $scriptRoot 'synthetic_load.ps1'
    & $loadScript -Start -OutputConfigPath $loadConfigPath -Prime95Exe $Tools.prime95 2>&1 | Write-Host
    $script:cleanupState.syntheticLoadActive = $true

    Write-Step 'Stabilizing 30s before capture...'
    Start-Sleep -Seconds 30

    Invoke-CapturePhase -PhaseName 'loaded' -PhaseDir $loadedDir -Tools $Tools -PhaseFlags $PhaseFlags

    Write-Step 'Stopping synthetic load...'
    & $loadScript -Stop 2>&1 | Write-Host
    $script:cleanupState.syntheticLoadActive = $false
}

# ── Phase 4: Aggregation ──────────────────────────────────────────────────

function Invoke-Phase4 {
    param([hashtable]$PhaseFlags)

    Write-Phase 'Phase 4: Aggregation'

    $aggregateDir = Join-Path $runDir '40_aggregate'

    # Compute delta between idle and loaded
    $deltaPath = Join-Path $aggregateDir 'delta_idle_vs_loaded.json'
    $idlePerf = $null
    $loadedPerf = $null
    try {
        $idlePerfPath = Join-Path $runDir '20_idle\pipeline_idle.json'
        $loadedPerfPath = Join-Path $runDir '30_loaded\pipeline_loaded.json'
        if (Test-Path $idlePerfPath) { $idlePerf = Get-Content $idlePerfPath -Raw | ConvertFrom-Json }
        if (Test-Path $loadedPerfPath) { $loadedPerf = Get-Content $loadedPerfPath -Raw | ConvertFrom-Json }
    } catch {}

    $delta = @{}
    if ($idlePerf -and $loadedPerf -and $idlePerf.performance -and $loadedPerf.performance) {
        $dpcIdleVal = $idlePerf.performance.'% dpc time[_total]'
        $dpcLoadedVal = $loadedPerf.performance.'% dpc time[_total]'
        if ($dpcIdleVal -and $dpcLoadedVal) {
            $delta['dpc_pct'] = @{
                idle = $dpcIdleVal.avg
                loaded = $dpcLoadedVal.avg
                delta = [Math]::Round(($dpcLoadedVal.avg - $dpcIdleVal.avg), 3)
            }
        }
        $intIdleVal = $idlePerf.performance.'% interrupt time[_total]'
        $intLoadedVal = $loadedPerf.performance.'% interrupt time[_total]'
        if ($intIdleVal -and $intLoadedVal) {
            $delta['interrupt_pct'] = @{
                idle = $intIdleVal.avg
                loaded = $intLoadedVal.avg
                delta = [Math]::Round(($intLoadedVal.avg - $intIdleVal.avg), 3)
            }
        }
        $ipsIdleVal = $idlePerf.performance.'interrupts/sec[_total]'
        $ipsLoadedVal = $loadedPerf.performance.'interrupts/sec[_total]'
        if ($ipsIdleVal -and $ipsLoadedVal) {
            $delta['interrupts_per_sec'] = @{
                idle = $ipsIdleVal.avg
                loaded = $ipsLoadedVal.avg
                delta = [Math]::Round(($ipsLoadedVal.avg - $ipsIdleVal.avg), 1)
            }
        }
    }
    $delta | ConvertTo-Json -Depth 10 | Set-Content -Path $deltaPath -Encoding UTF8

    # Dashboard entry
    Write-Step 'Building dashboard entry...'
    $entryPath = Join-Path $aggregateDir 'experiment_entry.json'
    & (Join-Path $scriptRoot 'aggregate_baseline_to_dashboard_entry.ps1') -InputDir $runDir -OutputPath $entryPath -Label $Label 2>&1 | Write-Host

    # Copy entry to experiments/ for dashboard regen pickup
    $expDir = Join-Path $projectRoot ('captures\experiments\' + (Split-Path $runDir -Leaf))
    New-Item -ItemType Directory -Path $expDir -Force | Out-Null
    Copy-Item -Path $entryPath -Destination (Join-Path $expDir 'experiment.json') -Force

    # Regen dashboard
    Write-Step 'Regenerating dashboard data...'
    $genScript = Join-Path $scriptRoot 'generate_dashboard_data.ps1'
    if (Test-Path $genScript) {
        & $genScript 2>&1 | Write-Host
    }

    # MASTER report
    Write-Step 'Building MASTER.html...'
    $masterPath = Join-Path $runDir 'MASTER.html'
    & (Join-Path $scriptRoot 'build_master_report.ps1') -InputDir $runDir -OutputPath $masterPath 2>&1 | Write-Host

    # Manifest
    $manifestPath = Join-Path $runDir 'manifest.json'
    $manifest = @{
        label = $Label
        run_dir = $runDir
        started_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        capture_sec = $CaptureSec
        latmon_sec = $LatmonDurationSec
        latmon_skipped = (-not $PhaseFlags.latmonAvailable)
        presentmon_skipped = (-not $PhaseFlags.presentmonAvailable)
        procmon_skipped = (-not $PhaseFlags.procmonAvailable)
        skip_load = [bool]$SkipLoad
        master_html = $masterPath
        dashboard_entry = $entryPath
    }
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8
    Write-Step ('Manifest: ' + $manifestPath)
}

# ── Main ──────────────────────────────────────────────────────────────────

trap {
    Stop-AllCaptures
    Write-Error $_
    exit 1
}

Write-Host ''
Write-Host '===================================================================' -ForegroundColor Cyan
Write-Host (' Baseline Full Capture: ' + $Label) -ForegroundColor Cyan
Write-Host (' Run dir: ' + $runDir) -ForegroundColor Cyan
Write-Host '===================================================================' -ForegroundColor Cyan
Write-Host ''

$tools = Get-ToolPaths
$phaseFlags = Invoke-Phase0 -Tools $tools
Invoke-Phase1

$idleDir = Join-Path $runDir '20_idle'
Invoke-CapturePhase -PhaseName 'idle' -PhaseDir $idleDir -Tools $tools -PhaseFlags $phaseFlags

if (-not $SkipLoad) {
    Invoke-Phase3 -Tools $tools -PhaseFlags $phaseFlags
} else {
    Write-Phase 'Phase 3 SKIPPED (-SkipLoad set)'
}

Invoke-Phase4 -PhaseFlags $phaseFlags

Write-Host ''
Write-Host '===================================================================' -ForegroundColor Green
Write-Host (' Baseline capture complete. Open: ' + (Join-Path $runDir 'MASTER.html')) -ForegroundColor Green
Write-Host '===================================================================' -ForegroundColor Green
