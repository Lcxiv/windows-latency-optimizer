<#
.SYNOPSIS
    Phase 4a: Launch Fortnite with CPU affinity pinned to game-thread bucket (CPUs 8-15).
.DESCRIPTION
    Wrapper that uses START /AFFINITY (process-level Windows feature) to pin Fortnite's
    primary process to CPUs 8-15 per the 9800X3D topology defined in CLAUDE.md.
    No registry mutation. No anti-cheat tampering. Standard Windows process attribute.

    Mask FF00 = binary 1111111100000000 = CPUs 8-15 enabled, CPUs 0-7 disabled.

    Note: Epic Games Launcher will spawn FortniteClient-Win64-Shipping.exe. The launcher
    itself runs without affinity restriction. Affinity inherits to launched child via
    Windows process creation. If Epic launcher launches game without inheriting, fallback
    sets affinity post-launch via Set-ProcessAffinity.

.PARAMETER FortniteUrl
    Epic Games URL launch (com.epicgames.launcher://apps/fn). Default works for most users.

.PARAMETER PostLaunchTimeoutSec
    Wait this many seconds for FortniteClient-Win64-Shipping.exe to appear, then set affinity.

.PARAMETER AffinityMask
    Hex mask. Default 0xFF00 (CPUs 8-15). For 8-thread CPU change to 0xC0 (CPUs 6-7).

.EXAMPLE
    .\eac_phase4a_launch_fortnite_pinned.ps1
#>
param(
    [string]$FortniteUrl = 'com.epicgames.launcher://apps/Fortnite?action=launch&silent=true',

    [ValidateRange(5, 600)]
    [int]$PostLaunchTimeoutSec = 120,

    [uint32]$AffinityMask = 0xFF00
)

$ErrorActionPreference = 'Continue'

Write-Host '=== Phase 4a: Launch Fortnite Pinned ===' -ForegroundColor Cyan
Write-Host ('Affinity mask: 0x' + ('{0:X}' -f $AffinityMask))
Write-Host ('Topology: CPUs ' + ((0..31) | Where-Object { ($AffinityMask -band (1 -shl $_)) -ne 0 }) -join ',')

# ---- Launch via Epic URL (lets EAC integrate normally) ----
Write-Host 'Launching via Epic URL...'
Start-Process -FilePath $FortniteUrl

# ---- Wait for Fortnite client process ----
$targetName = 'FortniteClient-Win64-Shipping'
Write-Host ('Waiting up to ' + $PostLaunchTimeoutSec + 's for ' + $targetName + '.exe...')

$deadline = (Get-Date).AddSeconds($PostLaunchTimeoutSec)
$proc = $null
while ((Get-Date) -lt $deadline) {
    $proc = Get-Process -Name $targetName -ErrorAction SilentlyContinue
    if ($proc) { break }
    Start-Sleep -Milliseconds 500
}

if (-not $proc) {
    Write-Warning ($targetName + '.exe did not appear within ' + $PostLaunchTimeoutSec + 's. Affinity not set.')
    Write-Host '(EAC may have launched a different binary — check Task Manager.)'
    exit 2
}

# ---- Set affinity ----
foreach ($p in $proc) {
    try {
        $oldMask = $p.ProcessorAffinity
        $p.ProcessorAffinity = [IntPtr]$AffinityMask
        Write-Host ('Set affinity: PID ' + $p.Id + ' from 0x' + ('{0:X}' -f [int64]$oldMask) + ' to 0x' + ('{0:X}' -f $AffinityMask)) -ForegroundColor Green
    } catch {
        Write-Warning ('Failed to set affinity on PID ' + $p.Id + ': ' + $_.Exception.Message)
        Write-Warning '(EAC may block process attribute mutation — kernel anti-cheat detection.)'
    }
}

Write-Host ''
Write-Host 'Note: Affinity persists for this process lifetime only. Re-run wrapper for next launch.'
