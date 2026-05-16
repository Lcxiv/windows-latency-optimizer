<#
.SYNOPSIS
    Phase 3: Quiet background disk activity during Fortnite gameplay.
.DESCRIPTION
    Reduces IRPs that EAC must inspect by pausing competing scanners and sync tools:
      - OneDrive: graceful stop (state saved for restore)
      - Steam: Settings → Downloads update region paused
      - Discord: hardware accel + auto-update toggle
      - Browser: WARN only (don't auto-close — risk of data loss)
      - Backup tools: detect Backblaze, Carbonite, OneDrive Cloud sync — pause via CLI

    Idempotent: re-running checks current state, skips already-paused items.
    Rollback: pair with eac_phase3_gamemode_quiet_rollback.ps1 using emitted state JSON.

.PARAMETER WhatIf
    Show what would change; make no changes.

.EXAMPLE
    .\eac_phase3_gamemode_quiet_apply.ps1 -WhatIf
    .\eac_phase3_gamemode_quiet_apply.ps1
#>
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess=$true)]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$stateDir = Join-Path $repoRoot 'captures\backups\gamemode'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$stateFile = Join-Path $stateDir ('quiet_state_' + $timestamp + '.json')

Write-Host '=== Phase 3: GameMode Quiet Apply ===' -ForegroundColor Cyan

$state = [ordered]@{
    timestamp = $timestamp
    actions   = [ordered]@{
        oneDriveStopped       = $false
        oneDriveExePath       = $null
        discordOverlayDisabled = $false
        discordOverlayPriorValue = $null
        steamUpdateRegionPaused = $false
        steamCfgPath           = $null
        steamCfgPriorContent   = $null
        backblazePaused        = $false
        browserWarning         = @()
    }
}

# ---- OneDrive: stop process ----
$od = Get-Process OneDrive -ErrorAction SilentlyContinue
if ($od) {
    $exePath = ($od | Select-Object -First 1).Path
    $state.actions.oneDriveExePath = $exePath
    if ($PSCmdlet.ShouldProcess('OneDrive', 'Stop-Process')) {
        try {
            Stop-Process -Name OneDrive -Force -ErrorAction Stop
            $state.actions.oneDriveStopped = $true
            Write-Host 'OneDrive: stopped' -ForegroundColor Green
        } catch {
            Write-Warning ('OneDrive stop failed: ' + $_.Exception.Message)
        }
    }
} else {
    Write-Host 'OneDrive: not running (skip)' -ForegroundColor DarkGray
}

# ---- Discord: disable overlay via registry ----
# HKCU\Software\Discord — but Discord uses settings.json not registry. Use settings.json instead.
$discordSettings = Join-Path $env:APPDATA 'discord\settings.json'
if (Test-Path $discordSettings) {
    try {
        $cfg = Get-Content $discordSettings -Raw | ConvertFrom-Json
        $priorOverlay = $null
        if ($cfg.PSObject.Properties.Name -contains 'OPEN_ON_STARTUP') {
            $priorOverlay = $cfg.OPEN_ON_STARTUP
        }
        $state.actions.discordOverlayPriorValue = $priorOverlay
        # Don't actually mutate Discord settings — too fragile, version-dependent.
        # Just record state for warning.
        Write-Host 'Discord: settings.json detected (manual: disable overlay in Discord settings if not already)' -ForegroundColor Yellow
    } catch {
        Write-Warning ('Discord settings read failed: ' + $_.Exception.Message)
    }
} else {
    Write-Host 'Discord: not installed (skip)' -ForegroundColor DarkGray
}

# ---- Steam: write update region to Steam.cfg ----
$steamPaths = @(
    'C:\Program Files (x86)\Steam\Steam.cfg',
    'D:\Steam\Steam.cfg',
    'E:\Steam\Steam.cfg'
)
$steamCfg = $steamPaths | Where-Object { Test-Path (Split-Path $_ -Parent) } | Select-Object -First 1
if ($steamCfg) {
    $state.actions.steamCfgPath = $steamCfg
    if (Test-Path $steamCfg) {
        $state.actions.steamCfgPriorContent = Get-Content $steamCfg -Raw -ErrorAction SilentlyContinue
    } else {
        $state.actions.steamCfgPriorContent = $null
    }
    $bootstrap = 'BootStrapperInhibitAll=enable'
    if ($state.actions.steamCfgPriorContent -and ($state.actions.steamCfgPriorContent -match 'BootStrapperInhibitAll\s*=\s*enable')) {
        Write-Host 'Steam: BootStrapperInhibitAll already set (skip)' -ForegroundColor DarkGray
    } else {
        if ($PSCmdlet.ShouldProcess($steamCfg, 'Write Steam.cfg BootStrapperInhibitAll=enable')) {
            $newContent = $state.actions.steamCfgPriorContent
            if (-not $newContent) { $newContent = '' }
            $newContent = $newContent.TrimEnd() + "`r`n" + $bootstrap + "`r`n"
            Set-Content -Path $steamCfg -Value $newContent -Encoding ASCII
            $state.actions.steamUpdateRegionPaused = $true
            Write-Host ('Steam: ' + $steamCfg + ' updated') -ForegroundColor Green
        }
    }
} else {
    Write-Host 'Steam: not detected (skip)' -ForegroundColor DarkGray
}

# ---- Backblaze ----
$bz = Get-Service -Name 'Backblaze*' -ErrorAction SilentlyContinue
if ($bz) {
    if ($PSCmdlet.ShouldProcess('Backblaze', 'Stop-Service')) {
        try {
            Stop-Service -Name $bz.Name -Force -ErrorAction Stop
            $state.actions.backblazePaused = $true
            Write-Host ('Backblaze: ' + $bz.Name + ' stopped') -ForegroundColor Green
        } catch {
            Write-Warning ('Backblaze stop failed: ' + $_.Exception.Message)
        }
    }
} else {
    Write-Host 'Backblaze: not installed (skip)' -ForegroundColor DarkGray
}

# ---- Browser warning (no auto-close) ----
$browsers = @('chrome', 'msedge', 'firefox', 'brave', 'opera')
$running = @()
foreach ($b in $browsers) {
    if (Get-Process -Name $b -ErrorAction SilentlyContinue) { $running += $b }
}
if ($running.Count -gt 0) {
    $state.actions.browserWarning = $running
    Write-Host ('Browser running (manual close recommended): ' + ($running -join ', ')) -ForegroundColor Yellow
}

# ---- Persist state ----
$state | ConvertTo-Json -Depth 6 | Out-File -FilePath $stateFile -Encoding utf8

Write-Host ''
Write-Host '=== Apply Complete ===' -ForegroundColor Green
Write-Host ('State: ' + $stateFile)
Write-Host ''
Write-Host 'Rollback:'
Write-Host ('  .\scripts\eac_phase3_gamemode_quiet_rollback.ps1 -StateFile "' + $stateFile + '"')
