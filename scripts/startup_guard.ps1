<#
.SYNOPSIS
    Startup guard — verify and auto-fix latency optimizations at every logon.
.DESCRIPTION
    Runs all verification checks at Windows logon. Auto-fixes any drift
    (e.g., Windows re-enabling USB EPM, registry values reset by updates).
    Logs results to the unified LatencyGuard log file.

    Designed to run as a Scheduled Task at logon with highest privileges.
    Register with: .\startup_guard.ps1 -Register
    Unregister with: .\startup_guard.ps1 -Unregister
.PARAMETER Register
    Create the scheduled task (requires admin).
.PARAMETER Unregister
    Remove the scheduled task.
.PARAMETER RunNow
    Execute all guards immediately (default if no switch specified).
.PARAMETER Quiet
    Suppress console output (log file only).
.EXAMPLE
    .\startup_guard.ps1 -Register
.EXAMPLE
    .\startup_guard.ps1
#>
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Register,
    [switch]$Unregister,
    [switch]$RunNow,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'

$scriptRoot = Split-Path $MyInvocation.MyCommand.Path -Parent
$projectRoot = Split-Path $scriptRoot -Parent
$logDir = Join-Path $projectRoot 'captures'
$taskName = 'LatencyGuard-StartupCheck'

# ── Load logging helper ─────────────────────────────────────────────────────
. (Join-Path $scriptRoot 'helpers\logging.ps1')

# ── Register / Unregister ────────────────────────────────────────────────────

if ($Register) {
    # Check if already registered
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host ('Task "' + $taskName + '" already exists. Updating...') -ForegroundColor Yellow
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    $scriptPath = $MyInvocation.MyCommand.Path
    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument ('-ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $scriptPath + '" -RunNow -Quiet')

    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

    # Run with highest privileges, don't stop if on battery
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    $principal = New-ScheduledTaskPrincipal `
        -UserId $env:USERNAME `
        -RunLevel Highest `
        -LogonType Interactive

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Description 'LatencyGuard: verify and auto-fix USB EPM, mouse input tweaks, and other latency optimizations at logon.' | Out-Null

    Write-Host '' -ForegroundColor Green
    Write-Host ('Scheduled task "' + $taskName + '" registered.') -ForegroundColor Green
    Write-Host '  Trigger: At logon (' + $env:USERNAME + ')' -ForegroundColor Cyan
    Write-Host '  Action:  Auto-fix USB EPM, mouse input, future guards' -ForegroundColor Cyan
    $logFile = Get-LogPath
    Write-Host ('  Log:     ' + $logFile) -ForegroundColor Cyan
    Write-Host '' -ForegroundColor Green
    Write-Host 'To test: .\startup_guard.ps1' -ForegroundColor DarkCyan
    Write-Host 'To remove: .\startup_guard.ps1 -Unregister' -ForegroundColor DarkCyan
    exit 0
}

if ($Unregister) {
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host ('Removed scheduled task "' + $taskName + '".') -ForegroundColor Green
    } else {
        Write-Host ('Task "' + $taskName + '" not found.') -ForegroundColor Yellow
    }
    exit 0
}

# ── Guard Execution ──────────────────────────────────────────────────────────

# Ensure log directory exists
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

Log '=== LatencyGuard Startup Check ==='

# Define guard modules in execution order
$guardModules = @(
    @{ Name = 'USB Power';         Script = 'guard\usb-power.ps1';         Function = 'Invoke-UsbPowerGuard' },
    @{ Name = 'Input Stack';       Script = 'guard\input-stack.ps1';       Function = 'Invoke-InputStackGuard' },
    @{ Name = 'Defender Settings'; Script = 'guard\defender-settings.ps1'; Function = 'Invoke-DefenderSettingsGuard' },
    @{ Name = 'Deep Optimize';     Script = 'guard\deep-optimize.ps1';     Function = 'Invoke-DeepOptimizeGuard' },
    @{ Name = 'NVIDIA Perf';       Script = 'guard\nvidia-perf.ps1';       Function = 'Invoke-NvidiaPerfGuard' },
    @{ Name = 'GPU Affinity';      Script = 'guard\gpu-affinity.ps1';      Function = 'Invoke-GpuAffinityGuard' },
    @{ Name = 'Phase 2 Drift';     Script = 'guard\phase2-drift.ps1';      Function = 'Invoke-Phase2DriftGuard' }
)

$totalChecks = 0
$totalPassed = 0
$totalFixes = 0
$modulesSucceeded = 0
$modulesFailed = 0

foreach ($guard in $guardModules) {
    $modulePath = Join-Path $scriptRoot $guard.Script
    try {
        # Dot-source the module to load its function
        . $modulePath

        # Invoke the guard function
        $result = & $guard.Function
        $totalChecks += $result.Checks
        $totalPassed += $result.Passed
        $totalFixes += $result.Fixes
        $modulesSucceeded++
    } catch {
        Log-Error ('Module "' + $guard.Name + '" failed') -ErrorRecord $_
        $modulesFailed++
        # Continue to next module — fault-isolated
    }
}

# ── Summary ──────────────────────────────────────────────────────────────────
$moduleTotal = $modulesSucceeded + $modulesFailed
$summary = 'Modules: ' + $modulesSucceeded + '/' + $moduleTotal + ' OK | Checks: ' + $totalChecks + ' | Passed: ' + $totalPassed + ' | Fixed: ' + $totalFixes
if ($modulesFailed -gt 0) {
    Log ($summary + ' | FAILED: ' + $modulesFailed) 'WARN'
} elseif ($totalFixes -eq 0) {
    Log ('All clear. ' + $summary) 'PASS'
} else {
    Log ('Applied ' + $totalFixes + ' fix(es). ' + $summary) 'FIX'
}
