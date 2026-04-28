<#
.SYNOPSIS
    Toggle ExitLag NDIS LightWeight Filter on Ethernet adapter.

.DESCRIPTION
    ExitLag installs an NDIS LightWeight Filter driver (nt_ndextlag) that
    intercepts ALL network traffic — even when ExitLag is not routing any game.
    Measured impact: +52% packet multiplication on receive path, 466 packet
    drops per 30s capture, 262MB RAM for the ExitLag process.

    This script disables the filter when not gaming and re-enables before
    gaming sessions. The ExitLag app continues to work — the filter just
    stops intercepting packets at the NDIS layer.

    Use -Enable to re-enable before launching a game through ExitLag.

.PARAMETER Enable
    Re-enable the ExitLag filter (default: disable it).

.PARAMETER NicName
    Adapter name (default: 'Ethernet').

.PARAMETER Verify
    Run a quick before/after packet rate measurement to confirm impact.

.EXAMPLE
    .\fix_exitlag_filter.ps1                  # Disable filter (daily use)
    .\fix_exitlag_filter.ps1 -Enable          # Re-enable (before gaming)
    .\fix_exitlag_filter.ps1 -Verify          # Disable + measure impact

.NOTES
    Related: [[ping-regression]], [[burst-pattern-analysis]]
    Discovery: pktmon capture showed NIC Lower Rx 907 -> Upper Rx 1,375 (+52%)
    with nt_ndextlag dropping 466 packets in 30s.
#>
[CmdletBinding()]
param(
    [switch]$Enable,
    [string]$NicName = 'Ethernet',
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'

# Admin check
$current = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '[FATAL] Run as Administrator' -ForegroundColor Red
    exit 1
}

$componentId = 'nt_ndextlag'
$filterName  = 'ExitLag LightWeight Filter'

Write-Host '=== ExitLag NDIS Filter Toggle ===' -ForegroundColor Cyan
Write-Host ''

# Check adapter exists
$nic = Get-NetAdapter -Name $NicName -ErrorAction SilentlyContinue
if (-not $nic) {
    Write-Host ('[FAIL] Adapter "' + $NicName + '" not found') -ForegroundColor Red
    Write-Host 'Available adapters:' -ForegroundColor Yellow
    Get-NetAdapter | Select-Object Name, InterfaceDescription, Status | Format-Table -AutoSize
    exit 1
}

# Check binding exists
$binding = Get-NetAdapterBinding -Name $NicName -ComponentId $componentId -ErrorAction SilentlyContinue
if (-not $binding) {
    Write-Host ('[INFO] ExitLag filter not installed on "' + $NicName + '"') -ForegroundColor Yellow
    Write-Host 'No action needed.' -ForegroundColor Green
    exit 0
}

$currentState = $binding.Enabled
Write-Host ('Adapter:       ' + $nic.InterfaceDescription + ' (' + $NicName + ')') -ForegroundColor White
Write-Host ('Filter:        ' + $filterName) -ForegroundColor White
Write-Host ('Component ID:  ' + $componentId) -ForegroundColor Gray
Write-Host ('Current state: ' + $(if ($currentState) { 'ENABLED' } else { 'DISABLED' })) -ForegroundColor $(if ($currentState) { 'Yellow' } else { 'Green' })
Write-Host ''

# Measure baseline if -Verify
$baselineRx = $null
if ($Verify) {
    Write-Host 'Measuring baseline packet rate (5s)...' -ForegroundColor Cyan
    $stat1 = Get-NetAdapterStatistics -Name $NicName
    Start-Sleep -Seconds 5
    $stat2 = Get-NetAdapterStatistics -Name $NicName
    $rxDelta = $stat2.ReceivedUnicastPackets - $stat1.ReceivedUnicastPackets
    $baselineRx = [math]::Round($rxDelta / 5, 1)
    Write-Host ('  Baseline Rx rate: ' + $baselineRx + ' pkt/s') -ForegroundColor White
    Write-Host ''
}

if ($Enable) {
    # RE-ENABLE the filter
    if ($currentState) {
        Write-Host '[SKIP] Filter already enabled' -ForegroundColor Yellow
    } else {
        Write-Host 'Enabling ExitLag NDIS filter...' -ForegroundColor Cyan
        Enable-NetAdapterBinding -Name $NicName -ComponentId $componentId
        Write-Host '[OK] ExitLag filter ENABLED' -ForegroundColor Green
        Write-Host 'ExitLag game routing is now active.' -ForegroundColor White
    }
} else {
    # DISABLE the filter
    if (-not $currentState) {
        Write-Host '[SKIP] Filter already disabled' -ForegroundColor Yellow
    } else {
        Write-Host 'Disabling ExitLag NDIS filter...' -ForegroundColor Cyan
        Disable-NetAdapterBinding -Name $NicName -ComponentId $componentId
        Write-Host '[OK] ExitLag filter DISABLED' -ForegroundColor Green
        Write-Host ''
        Write-Host 'Impact removed:' -ForegroundColor White
        Write-Host '  - No more +52% packet multiplication on Rx path' -ForegroundColor Gray
        Write-Host '  - No more packet drops from filter processing' -ForegroundColor Gray
        Write-Host '  - ExitLag app still runs, just no NDIS interception' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Re-enable before gaming: .\fix_exitlag_filter.ps1 -Enable' -ForegroundColor Yellow
    }
}

# Verify after change
$afterBinding = Get-NetAdapterBinding -Name $NicName -ComponentId $componentId
Write-Host ''
Write-Host ('Final state: ' + $(if ($afterBinding.Enabled) { 'ENABLED' } else { 'DISABLED' })) -ForegroundColor $(if ($afterBinding.Enabled) { 'Yellow' } else { 'Green' })

# Measure after if -Verify
if ($Verify -and $null -ne $baselineRx) {
    Write-Host ''
    Write-Host 'Measuring post-change packet rate (5s)...' -ForegroundColor Cyan
    Start-Sleep -Seconds 2  # brief settle
    $stat3 = Get-NetAdapterStatistics -Name $NicName
    Start-Sleep -Seconds 5
    $stat4 = Get-NetAdapterStatistics -Name $NicName
    $rxDelta2 = $stat4.ReceivedUnicastPackets - $stat3.ReceivedUnicastPackets
    $afterRx = [math]::Round($rxDelta2 / 5, 1)
    Write-Host ('  After Rx rate: ' + $afterRx + ' pkt/s') -ForegroundColor White

    if ($baselineRx -gt 0) {
        $changePct = [math]::Round(($afterRx - $baselineRx) / $baselineRx * 100, 1)
        $sign = if ($changePct -ge 0) { '+' } else { '' }
        Write-Host ('  Change: ' + $sign + $changePct + '%') -ForegroundColor $(if ($changePct -lt 0) { 'Green' } else { 'Yellow' })
    }
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Cyan
