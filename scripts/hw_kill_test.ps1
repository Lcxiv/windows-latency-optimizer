<#
.SYNOPSIS
    Targeted kill test for the 4/24 slow state — verifies whether long-running
    Claude.exe processes are causing cores 6-9 thrashing.
.DESCRIPTION
    Phase A: Snapshot all running Claude.exe processes (PID, parent, StartTime,
             cumulative CPU seconds, working set, thread count).
    Phase B: If -Execute is set, terminates processes whose cumulative CPU >
             -CpuThresholdSec (default 3600s = 1 CPU-hour). Skips PIDs in
             -Protect list (default: current Claude Code session host).
    Phase C: Wait 30s for the system to settle.
    Phase D: Re-capture per-CPU %processor time via Get-Counter for 60s.
    Phase E: Compare cores 6-9 average %CPU before-vs-after; emit decision
             ("software_leak_confirmed" / "software_leak_eliminated" / "inconclusive").
    Use -WhatIf for snapshot-only (no kills, no second capture).
.OUTPUTS
    <OutDir>\kill_before.csv          — Claude proc snapshot pre-kill
    <OutDir>\kill_after.csv           — Claude proc snapshot post-kill
    <OutDir>\percpu_pre_kill.csv      — per-CPU %CPU pre
    <OutDir>\percpu_post_kill.csv     — per-CPU %CPU post (only if -Execute)
    <OutDir>\kill_decision.json       — final hypothesis verdict
#>
#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory=$true)]
    [string]$OutDir,
    [switch]$Execute,
    [switch]$WhatIf,
    [int]$CpuThresholdSec = 3600,
    [int[]]$Protect = @(),
    [ValidateRange(15, 300)]
    [int]$PostCaptureSec = 60,
    [ValidateRange(5, 60)]
    [int]$SettleSec = 30
)

$ErrorActionPreference = 'Continue'
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# --- Phase A: snapshot Claude.exe processes ---
function Get-ClaudeProcs {
    $rows = @()
    Get-Process -Name 'Claude','claude' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $rows += [ordered]@{
                Id = $_.Id
                Name = $_.Name
                ParentId = (Get-CimInstance Win32_Process -Filter ('ProcessId=' + $_.Id) -ErrorAction SilentlyContinue).ParentProcessId
                StartTime = ($_.StartTime).ToString('yyyy-MM-ddTHH:mm:ss')
                CpuSec = [math]::Round($_.CPU, 2)
                WS_MB = [math]::Round($_.WorkingSet64 / 1MB, 1)
                Threads = $_.Threads.Count
                HandleCount = $_.HandleCount
                Path = $_.Path
            }
        } catch {}
    }
    return $rows
}

$beforeProcs = Get-ClaudeProcs
$beforeCsvPath = Join-Path $OutDir 'kill_before.csv'
if ($beforeProcs.Count -gt 0) {
    $beforeProcs | ForEach-Object { New-Object PSObject -Property $_ } | Export-Csv -Path $beforeCsvPath -NoTypeInformation -Encoding UTF8
} else {
    'Id,Name,ParentId,StartTime,CpuSec,WS_MB,Threads,HandleCount,Path' | Set-Content -Path $beforeCsvPath -Encoding UTF8
}
Write-Host ('[hw_kill_test] before snapshot: ' + $beforeCsvPath + ' (' + $beforeProcs.Count + ' procs)') -ForegroundColor Cyan

# --- Phase A2: pre-kill per-CPU capture (always, baseline) ---
$preCpuPath = Join-Path $OutDir 'percpu_pre_kill.csv'
$cpuCounters = @('\Processor(*)\% Processor Time', '\Processor(*)\% DPC Time')
Write-Host '[hw_kill_test] capturing pre-kill per-CPU baseline (60s)...' -ForegroundColor Cyan
try {
    & typeperf.exe ($cpuCounters[0], $cpuCounters[1]) -si 1 -sc 60 -f CSV -o $preCpuPath -y 2>&1 | Out-Null
} catch {
    Write-Warning ('[hw_kill_test] typeperf pre-capture failed: ' + $_.Exception.Message)
}

# --- Identify kill candidates ---
$candidates = @($beforeProcs | Where-Object {
    $_.CpuSec -gt $CpuThresholdSec -and ($Protect -notcontains $_.Id) -and ($PID -ne $_.Id)
})

$decision = [ordered]@{
    schemaVersion = 1
    capturedAt = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    cpuThresholdSec = $CpuThresholdSec
    candidatePids = @($candidates | ForEach-Object { $_.Id })
    candidateCount = $candidates.Count
    executed = $false
    killedPids = @()
    killErrors = @()
    cores69_pre_avg_pct = $null
    cores69_post_avg_pct = $null
    delta_pct = $null
    verdict = 'snapshot_only'
}

# --- Phase B: kill if -Execute and not -WhatIf ---
if ($Execute -and -not $WhatIf -and $candidates.Count -gt 0) {
    Write-Host ('[hw_kill_test] killing ' + $candidates.Count + ' Claude.exe procs (CpuSec > ' + $CpuThresholdSec + ')...') -ForegroundColor Yellow
    foreach ($c in $candidates) {
        try {
            Stop-Process -Id $c.Id -Force -ErrorAction Stop
            $decision.killedPids += $c.Id
            Write-Host ('  killed PID ' + $c.Id + ' (CpuSec=' + $c.CpuSec + ')')
        } catch {
            $decision.killErrors += ('PID ' + $c.Id + ': ' + $_.Exception.Message)
        }
    }
    $decision.executed = $true

    Write-Host ('[hw_kill_test] settling ' + $SettleSec + 's...') -ForegroundColor Cyan
    Start-Sleep -Seconds $SettleSec

    # Phase C: post-kill per-CPU capture
    $postCpuPath = Join-Path $OutDir 'percpu_post_kill.csv'
    Write-Host ('[hw_kill_test] capturing post-kill per-CPU (' + $PostCaptureSec + 's)...') -ForegroundColor Cyan
    try {
        & typeperf.exe ($cpuCounters[0], $cpuCounters[1]) -si 1 -sc $PostCaptureSec -f CSV -o $postCpuPath -y 2>&1 | Out-Null
    } catch {
        Write-Warning ('[hw_kill_test] typeperf post-capture failed: ' + $_.Exception.Message)
    }

    # Phase D: post-kill snapshot
    $afterProcs = Get-ClaudeProcs
    $afterCsvPath = Join-Path $OutDir 'kill_after.csv'
    if ($afterProcs.Count -gt 0) {
        $afterProcs | ForEach-Object { New-Object PSObject -Property $_ } | Export-Csv -Path $afterCsvPath -NoTypeInformation -Encoding UTF8
    } else {
        'Id,Name,ParentId,StartTime,CpuSec,WS_MB,Threads,HandleCount,Path' | Set-Content -Path $afterCsvPath -Encoding UTF8
    }

    # Phase E: compute cores 6-9 averages from both CSVs
    function Get-Cores69Avg {
        param([string]$Path)
        if (-not (Test-Path $Path)) { return $null }
        try {
            $rows = Import-Csv -Path $Path
            $cols69 = @('\\' + $env:COMPUTERNAME + '\Processor(6)\% Processor Time',
                         '\\' + $env:COMPUTERNAME + '\Processor(7)\% Processor Time',
                         '\\' + $env:COMPUTERNAME + '\Processor(8)\% Processor Time',
                         '\\' + $env:COMPUTERNAME + '\Processor(9)\% Processor Time')
            $vals = @()
            foreach ($r in $rows) {
                foreach ($c in $cols69) {
                    $v = $r.$c
                    if ($null -ne $v -and $v -ne '' -and $v -ne ' ') {
                        $num = 0.0
                        if ([double]::TryParse($v, [ref]$num)) { $vals += $num }
                    }
                }
            }
            if ($vals.Count -eq 0) { return $null }
            return [math]::Round(($vals | Measure-Object -Average).Average, 2)
        } catch { return $null }
    }

    $preAvg = Get-Cores69Avg -Path $preCpuPath
    $postAvg = Get-Cores69Avg -Path $postCpuPath
    $decision.cores69_pre_avg_pct = $preAvg
    $decision.cores69_post_avg_pct = $postAvg
    if ($null -ne $preAvg -and $null -ne $postAvg) {
        $decision.delta_pct = [math]::Round(($postAvg - $preAvg), 2)
        if ($postAvg -lt 10.0 -and $preAvg -gt 25.0) {
            $decision.verdict = 'software_leak_CONFIRMED'
        } elseif ($postAvg -gt 25.0) {
            $decision.verdict = 'software_leak_ELIMINATED — cores still hot post-kill'
        } else {
            $decision.verdict = 'inconclusive'
        }
    } else {
        $decision.verdict = 'capture_failed'
    }
} elseif ($candidates.Count -eq 0) {
    Write-Host '[hw_kill_test] no candidates above CPU threshold — no kill needed' -ForegroundColor Green
    $decision.verdict = 'no_candidates'
} else {
    Write-Host ('[hw_kill_test] WhatIf/snapshot-only mode — would kill ' + $candidates.Count + ' procs:') -ForegroundColor Yellow
    foreach ($c in $candidates) { Write-Host ('  PID ' + $c.Id + ' CpuSec=' + $c.CpuSec) }
}

$decisionPath = Join-Path $OutDir 'kill_decision.json'
$decision | ConvertTo-Json -Depth 6 | Set-Content -Path $decisionPath -Encoding UTF8
Write-Host ('[hw_kill_test] decision: ' + $decision.verdict) -ForegroundColor Cyan
Write-Host ('  cores 6-9 pre-avg: ' + $decision.cores69_pre_avg_pct + '%')
Write-Host ('  cores 6-9 post-avg: ' + $decision.cores69_post_avg_pct + '%')
