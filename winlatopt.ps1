<#
.SYNOPSIS
    Windows Latency Optimizer — unified CLI for gaming system analysis.
.DESCRIPTION
    One command to diagnose, optimize, and monitor your gaming PC.

    Commands:
      health     60-second system health audit with score and HTML report
      capture    Full pipeline capture (perf counters, GPU, network, SMI, xperf)
      fix        Apply safe optimizations (kill bloat, lock VRAM, audit Defender)
      audit-bios Compare BIOS settings against optimal gaming profile via SCEWIN
      compare    Compare two experiment captures side-by-side

.EXAMPLE
    .\winlatopt.ps1 health
    .\winlatopt.ps1 capture -Label "GAMING_TEST" -Mode Quick
    .\winlatopt.ps1 fix
    .\winlatopt.ps1 audit-bios
    .\winlatopt.ps1 compare -Baseline captures\experiments\EXP00 -Latest captures\experiments\EXP22
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('health', 'capture', 'fix', 'audit-bios', 'compare', '')]
    [string]$Command = '',

    # Capture params (forwarded to pipeline.ps1)
    [string]$Label = '',
    [string]$Description = '',
    [ValidateSet('Quick','Standard','Deep','')]
    [string]$Mode = '',
    [string]$GameProcess = '',
    [switch]$SkipWPR,
    [switch]$SkipNetworkLatency,
    [switch]$SkipPresentMon,

    # Compare params
    [string]$Baseline = '',
    [string]$Latest = '',

    # Fix params
    [switch]$SkipRazer,
    [switch]$SkipLauncher,
    [switch]$SkipVramLock,

    # General
    [switch]$Help
)

$projectRoot = $PSScriptRoot
$scriptsDir  = Join-Path $projectRoot 'scripts'

# ── Help ────────────────────────────────────────────────────────────────────
if ($Help -or $Command -eq '') {
    Write-Host ''
    Write-Host '  Windows Latency Optimizer' -ForegroundColor Cyan
    Write-Host '  ========================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Commands:' -ForegroundColor Yellow
    Write-Host '    health       60-second system health check with score + HTML report'
    Write-Host '    capture      Full pipeline capture (perf, GPU, network, SMI)'
    Write-Host '    fix          Apply safe optimizations (kill bloat, lock VRAM)'
    Write-Host '    audit-bios   Compare BIOS settings against optimal profile'
    Write-Host '    compare      Compare two experiment captures'
    Write-Host ''
    Write-Host '  Examples:' -ForegroundColor Yellow
    Write-Host '    .\winlatopt.ps1 health'
    Write-Host '    .\winlatopt.ps1 capture -Label "BASELINE" -Mode Quick'
    Write-Host '    .\winlatopt.ps1 fix'
    Write-Host '    .\winlatopt.ps1 audit-bios'
    Write-Host ''
    exit 0
}

# ── Route to subcommand ─────────────────────────────────────────────────────
switch ($Command) {

    'health' {
        $healthScript = Join-Path $scriptsDir 'health-check.ps1'
        if (-not (Test-Path $healthScript)) {
            Write-Host 'health-check.ps1 not found.' -ForegroundColor Red
            exit 1
        }
        & $healthScript
    }

    'capture' {
        $pipelineScript = Join-Path $scriptsDir 'pipeline.ps1'
        if ($Label -eq '') {
            $Label = 'CAPTURE_' + (Get-Date -Format 'HHmmss')
        }
        if ($Description -eq '') {
            $Description = 'winlatopt capture ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')
        }
        $captureArgs = @('-Label', $Label, '-Description', $Description)
        if ($Mode -ne '')        { $captureArgs += @('-Mode', $Mode) }
        if ($GameProcess -ne '') { $captureArgs += @('-GameProcess', $GameProcess) }
        if ($SkipWPR)            { $captureArgs += '-SkipWPR' }
        if ($SkipNetworkLatency) { $captureArgs += '-SkipNetworkLatency' }
        if ($SkipPresentMon)     { $captureArgs += '-SkipPresentMon' }
        & $pipelineScript @captureArgs
    }

    'fix' {
        $fixScript = Join-Path $scriptsDir 'optimize-game.ps1'
        $fixArgs = @()
        if ($SkipRazer)    { $fixArgs += '-SkipRazer' }
        if ($SkipLauncher) { $fixArgs += '-SkipLauncher' }
        & $fixScript @fixArgs

        # Also lock VRAM if nvidia-smi available
        if (-not $SkipVramLock) {
            $nvSmi = 'C:\Windows\System32\nvidia-smi.exe'
            if (Test-Path $nvSmi) {
                Write-Host ''
                Write-Host '--- VRAM Clock Lock ---' -ForegroundColor Yellow
                $currentMem = & $nvSmi --query-gpu=clocks.current.memory --format=csv,noheader 2>&1
                if ($currentMem -match '405 MHz') {
                    $lockResult = & $nvSmi -lmc 810,14001 2>&1 | Out-String
                    if ($lockResult -match 'set to') {
                        Write-Host 'VRAM floor locked at 810 MHz (was 405 MHz)' -ForegroundColor Green
                    } else {
                        Write-Host 'VRAM lock failed (may not be supported)' -ForegroundColor Yellow
                    }
                } else {
                    Write-Host ('VRAM already at ' + $currentMem.Trim() + ' (no lock needed)') -ForegroundColor Green
                }
            }
        }
    }

    'audit-bios' {
        $biosScript = Join-Path $scriptsDir 'optimize-bios.ps1'
        if (-not (Test-Path $biosScript)) {
            Write-Host 'optimize-bios.ps1 not found.' -ForegroundColor Red
            exit 1
        }
        & $biosScript -Audit
    }

    'compare' {
        $compareScript = Join-Path $scriptsDir 'analyze-comparison.ps1'
        if (-not (Test-Path $compareScript)) {
            Write-Host 'analyze-comparison.ps1 not found.' -ForegroundColor Red
            exit 1
        }
        $cmpArgs = @()
        if ($Baseline -ne '') { $cmpArgs += @('-Baseline', $Baseline) }
        if ($Latest -ne '')   { $cmpArgs += @('-Latest', $Latest) }
        & $compareScript @cmpArgs
    }
}
