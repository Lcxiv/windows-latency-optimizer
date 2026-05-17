#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Optimize the gaming environment: set game affinity, kill bloatware, close launcher.
.DESCRIPTION
    Three-in-one gaming optimizer:
    1. Pins the detected (or specified) game to the "game" CPU group (CPUs 8-15 on 9800X3D)
    2. Sets game priority to High
    3. Kills Razer bloat processes (settings persist in mouse firmware)
    4. Closes Epic Games Launcher (not needed after game launch)
    5. Re-enables ExitLag NDIS filter (disabled during idle for latency)
    6. Reports before/after thread count and memory freed
.PARAMETER GameProcess
    Game process name (without .exe). Auto-detects from known list if omitted.
.PARAMETER Restore
    Reset game affinity to all CPUs and priority to Normal.
.PARAMETER SkipRazer
    Skip Razer cleanup.
.PARAMETER SkipLauncher
    Skip closing Epic Games Launcher.
.PARAMETER SkipExitLag
    Skip re-enabling ExitLag NDIS filter.
.EXAMPLE
    .\optimize-game.ps1
.EXAMPLE
    .\optimize-game.ps1 -GameProcess "FortniteClient-Win64-Shipping"
.EXAMPLE
    .\optimize-game.ps1 -Restore
#>
param(
    [string]$GameProcess = '',
    [switch]$Restore,
    [switch]$SkipRazer,
    [switch]$SkipLauncher,
    [switch]$SkipExitLag
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent

# Load topology for dynamic CPU group detection
. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\helpers\logging.ps1"
. "$PSScriptRoot\topology.ps1"
$script:logLines = @()

Write-Host ''
Write-Host '=== Gaming Environment Optimizer ===' -ForegroundColor Cyan
Write-Host ''

# ── Snapshot before ─────────────────────────────────────────────────────────
$beforeThreads = 0
Get-Process | ForEach-Object { $beforeThreads += $_.Threads.Count }
$beforeRazerMB = 0
Get-Process | Where-Object { $_.Name -match 'Razer' } | ForEach-Object { $beforeRazerMB += [math]::Round($_.WorkingSet64 / 1MB) }
$beforeRazerCount = @(Get-Process | Where-Object { $_.Name -match 'Razer' }).Count
$beforeEpicMB = 0
Get-Process | Where-Object { $_.Name -match 'Epic' } | ForEach-Object { $beforeEpicMB += [math]::Round($_.WorkingSet64 / 1MB) }
$beforeEpicCount = @(Get-Process | Where-Object { $_.Name -match 'Epic' }).Count

# ── Step 1: Detect game ─────────────────────────────────────────────────────
if ($GameProcess -eq '') {
    $knownGames = $script:KnownGameProcesses
    if (-not $knownGames) {
        $knownGames = @('FortniteClient-Win64-Shipping', 'cs2', 'r5apex',
                        'RocketLeague', 'OverwatchOW', 'FPSAimTrainer',
                        'VALORANT-Win64-Shipping')
    }
    foreach ($g in $knownGames) {
        $proc = Get-Process $g -ErrorAction SilentlyContinue
        if ($proc) {
            $GameProcess = $g
            break
        }
    }
}

if ($GameProcess -eq '') {
    Write-Host 'No game detected. Specify with -GameProcess "name"' -ForegroundColor Red
    exit 1
}

$gameProc = Get-Process $GameProcess -ErrorAction SilentlyContinue
if (-not $gameProc) {
    Write-Host ('Game process "' + $GameProcess + '" not running.') -ForegroundColor Red
    exit 1
}

Write-Host ('Game: ' + $GameProcess + ' (PID ' + $gameProc.Id + ')') -ForegroundColor Green

# ── Step 2: Set affinity ────────────────────────────────────────────────────
$topo = Get-CpuTopology
$gameGroup = $topo.groups | Where-Object { $_.name -eq 'game' }
$oldMask = [long]$gameProc.ProcessorAffinity

if ($Restore) {
    Write-Host ''
    Write-Host '--- Restoring defaults ---' -ForegroundColor Yellow
    $allMask = [long]([math]::Pow(2, $topo.totalLogical) - 1)
    $gameProc.ProcessorAffinity = $allMask
    $gameProc.PriorityClass = 'Normal'
    Write-Host ('Affinity: 0x' + $allMask.ToString('X') + ' (all CPUs)')
    Write-Host 'Priority: Normal'
    Write-Host ''
    Write-Host 'Restored.' -ForegroundColor Green
    exit 0
}

Write-Host ''
Write-Host '--- CPU Affinity ---' -ForegroundColor Yellow

if ($gameGroup) {
    $gameCpus = $gameGroup.cpus
    $newMask = [long]0
    foreach ($cpu in $gameCpus) { $newMask = $newMask -bor ([long]1 -shl $cpu) }
    try {
        $gameProc.ProcessorAffinity = [IntPtr]$newMask
        Write-Host ('Old affinity: 0x' + $oldMask.ToString('X') + ' (' + $topo.totalLogical + ' CPUs)')
        Write-Host ('New affinity: 0x' + $newMask.ToString('X') + ' (CPUs ' + ($gameCpus -join ',') + ' = game group)')
    } catch {
        Write-Host ('Cannot set affinity: ' + $_.Exception.InnerException.Message) -ForegroundColor Yellow
        Write-Host 'Anti-cheat (EAC/BattlEye) may be blocking process access.' -ForegroundColor Yellow
        Write-Host 'Workaround: set affinity in Task Manager manually, or use Process Lasso.' -ForegroundColor DarkGray
    }
} else {
    Write-Host 'Could not detect game CPU group from topology. Skipping affinity.' -ForegroundColor Yellow
}

# ── Step 3: Set priority ────────────────────────────────────────────────────
$oldPriority = $gameProc.PriorityClass
try {
    $gameProc.PriorityClass = 'High'
    Write-Host ('Priority: ' + $oldPriority + ' -> High')
} catch {
    Write-Host ('Cannot set priority: anti-cheat may be blocking access.') -ForegroundColor Yellow
}

# ── Step 4: Razer cleanup ───────────────────────────────────────────────────
if (-not $SkipRazer) {
    Write-Host ''
    Write-Host '--- Razer Cleanup ---' -ForegroundColor Yellow

    # Stop Game Manager Service (not needed for mouse function)
    $gameMgrSvc = Get-Service 'Razer Game Manager Service 3' -ErrorAction SilentlyContinue
    if ($gameMgrSvc -and $gameMgrSvc.Status -eq 'Running') {
        Stop-Service 'Razer Game Manager Service 3' -Force -ErrorAction SilentlyContinue
        Write-Host 'Stopped: Razer Game Manager Service 3'
    }

    # Kill excess RazerAppEngine processes (keep the primary one with highest CPU)
    $razerProcs = @(Get-Process 'RazerAppEngine' -ErrorAction SilentlyContinue)
    if ($razerProcs.Count -gt 1) {
        $primary = $razerProcs | Sort-Object CPU -Descending | Select-Object -First 1
        $toKill = $razerProcs | Where-Object { $_.Id -ne $primary.Id }
        $killedCount = 0
        foreach ($rp in $toKill) {
            try {
                Stop-Process -Id $rp.Id -Force -ErrorAction SilentlyContinue
                $killedCount++
            } catch {}
        }
        Write-Host ('Killed ' + $killedCount + ' excess RazerAppEngine processes (kept PID ' + $primary.Id + ')')
    } elseif ($razerProcs.Count -eq 1) {
        Write-Host 'Only 1 RazerAppEngine running. Nothing to kill.'
    } else {
        Write-Host 'No RazerAppEngine processes found.'
    }
} else {
    Write-Host ''
    Write-Host '--- Razer: skipped ---' -ForegroundColor DarkGray
}

# ── Step 5: Close Epic Launcher ─────────────────────────────────────────────
if (-not $SkipLauncher) {
    Write-Host ''
    Write-Host '--- Epic Games Launcher ---' -ForegroundColor Yellow

    $epicProcs = @(Get-Process | Where-Object { $_.Name -match 'EpicGames|EpicWebHelper' })
    if ($epicProcs.Count -gt 0) {
        foreach ($ep in $epicProcs) {
            try {
                Stop-Process -Id $ep.Id -Force -ErrorAction SilentlyContinue
            } catch {}
        }
        Write-Host ('Closed ' + $epicProcs.Count + ' Epic Games processes')
    } else {
        Write-Host 'Epic Games Launcher not running.'
    }
} else {
    Write-Host ''
    Write-Host '--- Epic Launcher: skipped ---' -ForegroundColor DarkGray
}

# ── Step 6: ExitLag NDIS filter ─────────────────────────────────────────────
if (-not $SkipExitLag) {
    Write-Host ''
    Write-Host '--- ExitLag NDIS Filter ---' -ForegroundColor Yellow

    $exitlagBinding = Get-NetAdapterBinding -Name 'Ethernet' -ComponentId 'nt_ndextlag' -ErrorAction SilentlyContinue
    if ($exitlagBinding) {
        if ($exitlagBinding.Enabled) {
            Write-Host 'ExitLag filter already enabled. Good for gaming.'
        } else {
            Enable-NetAdapterBinding -Name 'Ethernet' -ComponentId 'nt_ndextlag' -ErrorAction SilentlyContinue
            Write-Host 'Re-enabled ExitLag NDIS filter for game routing.'
        }
    } else {
        Write-Host 'ExitLag not installed. Skipping.'
    }
} else {
    Write-Host ''
    Write-Host '--- ExitLag: skipped ---' -ForegroundColor DarkGray
}

# ── Summary ─────────────────────────────────────────────────────────────────
Start-Sleep -Seconds 2  # Let processes die

$afterThreads = 0
Get-Process | ForEach-Object { $afterThreads += $_.Threads.Count }
$afterRazerMB = 0
Get-Process | Where-Object { $_.Name -match 'Razer' } | ForEach-Object { $afterRazerMB += [math]::Round($_.WorkingSet64 / 1MB) }
$afterRazerCount = @(Get-Process | Where-Object { $_.Name -match 'Razer' }).Count
$afterEpicMB = 0
Get-Process | Where-Object { $_.Name -match 'Epic' } | ForEach-Object { $afterEpicMB += [math]::Round($_.WorkingSet64 / 1MB) }
$afterEpicCount = @(Get-Process | Where-Object { $_.Name -match 'Epic' }).Count

Write-Host ''
Write-Host '=== Results ===' -ForegroundColor Cyan
Write-Host ('Threads:    ' + $beforeThreads + ' -> ' + $afterThreads + ' (-' + ($beforeThreads - $afterThreads) + ')')
Write-Host ('Razer:      ' + $beforeRazerCount + ' procs / ' + $beforeRazerMB + 'MB -> ' + $afterRazerCount + ' procs / ' + $afterRazerMB + 'MB')
Write-Host ('Epic:       ' + $beforeEpicCount + ' procs / ' + $beforeEpicMB + 'MB -> ' + $afterEpicCount + ' procs / ' + $afterEpicMB + 'MB')
Write-Host ('RAM freed:  ~' + (($beforeRazerMB - $afterRazerMB) + ($beforeEpicMB - $afterEpicMB)) + 'MB')
Write-Host ''
Write-Host ('Game affinity: CPUs ' + ($gameCpus -join ',') + ' | Priority: High') -ForegroundColor Green
Write-Host 'Run with -Restore to undo affinity/priority changes.' -ForegroundColor DarkGray
