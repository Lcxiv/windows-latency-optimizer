<#
.SYNOPSIS
    Phase 3 rollback: restore background services paused by gamemode_quiet_apply.
.DESCRIPTION
    Reads state JSON, restores OneDrive, Steam.cfg prior content, Backblaze service.
    Discord overlay manual-only (apply did not mutate it).

.PARAMETER StateFile
    Path to quiet_state_<timestamp>.json from apply.

.EXAMPLE
    .\eac_phase3_gamemode_quiet_rollback.ps1 -StateFile "captures\backups\gamemode\quiet_state_20260507_120000.json"
#>
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$StateFile
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $StateFile)) {
    Write-Error ('State file not found: ' + $StateFile)
    exit 1
}

Write-Host '=== Phase 3: GameMode Quiet Rollback ===' -ForegroundColor Cyan
$state = Get-Content $StateFile -Raw | ConvertFrom-Json

# ---- OneDrive: restart ----
if ($state.actions.oneDriveStopped -and $state.actions.oneDriveExePath -and (Test-Path $state.actions.oneDriveExePath)) {
    if ($PSCmdlet.ShouldProcess('OneDrive', 'Start-Process')) {
        try {
            Start-Process -FilePath $state.actions.oneDriveExePath
            Write-Host 'OneDrive: restarted' -ForegroundColor Green
        } catch {
            Write-Warning ('OneDrive restart failed: ' + $_.Exception.Message)
        }
    }
} else {
    Write-Host 'OneDrive: was not stopped (skip)' -ForegroundColor DarkGray
}

# ---- Steam.cfg: restore prior content ----
if ($state.actions.steamUpdateRegionPaused -and $state.actions.steamCfgPath) {
    $steamCfg = $state.actions.steamCfgPath
    if ($PSCmdlet.ShouldProcess($steamCfg, 'Restore Steam.cfg')) {
        try {
            if ($state.actions.steamCfgPriorContent) {
                Set-Content -Path $steamCfg -Value $state.actions.steamCfgPriorContent -Encoding ASCII -NoNewline
                Write-Host ('Steam: ' + $steamCfg + ' restored') -ForegroundColor Green
            } else {
                # File didn't exist before — remove it
                if (Test-Path $steamCfg) {
                    Remove-Item -Path $steamCfg -Force
                    Write-Host ('Steam: ' + $steamCfg + ' removed (did not exist pre-apply)') -ForegroundColor Green
                }
            }
        } catch {
            Write-Warning ('Steam.cfg restore failed: ' + $_.Exception.Message)
        }
    }
} else {
    Write-Host 'Steam: was not modified (skip)' -ForegroundColor DarkGray
}

# ---- Backblaze: restart ----
if ($state.actions.backblazePaused) {
    $bz = Get-Service -Name 'Backblaze*' -ErrorAction SilentlyContinue
    if ($bz) {
        if ($PSCmdlet.ShouldProcess($bz.Name, 'Start-Service')) {
            try {
                Start-Service -Name $bz.Name -ErrorAction Stop
                Write-Host ('Backblaze: ' + $bz.Name + ' started') -ForegroundColor Green
            } catch {
                Write-Warning ('Backblaze start failed: ' + $_.Exception.Message)
            }
        }
    }
} else {
    Write-Host 'Backblaze: was not paused (skip)' -ForegroundColor DarkGray
}

# ---- Receipt ----
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$receiptFile = Join-Path (Split-Path $StateFile -Parent) ('rollback_receipt_' + $timestamp + '.json')
$receipt = [ordered]@{
    rolledBackAt = $timestamp
    sourceState  = $StateFile
}
$receipt | ConvertTo-Json -Depth 4 | Out-File -FilePath $receiptFile -Encoding utf8

Write-Host ''
Write-Host '=== Rollback Complete ===' -ForegroundColor Green
Write-Host ('Receipt: ' + $receiptFile)
