param(
    [Parameter(Mandatory=$true)]
    [string]$BackupFile,

    [switch]$WhatIf
)

# =============================================================================
# rollback.ps1
# Re-apply registry settings from a backup_pre_*.txt file.
#
# The backup files contain a "=== Rollback Commands ===" section with
# PowerShell commands that are validated against a safe cmdlet allowlist
# before execution.
#
# Usage:
#   .\rollback.ps1 -BackupFile ..\captures\backup_pre_fix2.txt
#   .\rollback.ps1 -BackupFile ..\captures\backup_pre_fix2.txt -WhatIf
# =============================================================================

$ErrorActionPreference = 'Stop'

# Only these cmdlets are allowed in rollback commands
$allowedCmdlets = @(
    'New-Item',
    'New-ItemProperty',
    'Set-ItemProperty',
    'Remove-ItemProperty',
    'Remove-Item',
    'Set-MpPreference',
    'Add-MpPreference',
    'Remove-MpPreference'
)

if (-not (Test-Path $BackupFile)) {
    Write-Error "Backup file not found: $BackupFile"
    exit 1
}

$lines   = Get-Content $BackupFile
$inBlock = $false
$commands = @()

foreach ($line in $lines) {
    if ($line -match '=== Rollback') {
        $inBlock = $true
        continue
    }
    if ($inBlock -and $line -match '^===' -and $line -notmatch 'Rollback') {
        $inBlock = $false
        continue
    }
    if (-not $inBlock) { continue }

    $trimmed = $line.Trim()
    if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }

    $commands += $trimmed
}

if ($commands.Count -eq 0) {
    Write-Error "No rollback commands found in: $BackupFile"
    Write-Host "Expected a section starting with '=== Rollback Commands'"
    exit 1
}

# Validate every command against the allowlist before executing any
$rejected = @()
foreach ($cmd in $commands) {
    # Extract the first token (cmdlet name), ignoring leading pipes
    $firstToken = ($cmd.TrimStart() -split '\s+')[0]
    # Strip any module prefix (e.g., Microsoft.PowerShell.Management\New-Item)
    $cmdletName = $firstToken.Split('\')[-1]

    $safe = $false
    foreach ($allowed in $allowedCmdlets) {
        if ($cmdletName -eq $allowed) { $safe = $true; break }
    }
    if (-not $safe) {
        $rejected += "  BLOCKED: $cmd"
        $rejected += "    Reason: '$cmdletName' is not in the safe cmdlet allowlist"
    }
}

if ($rejected.Count -gt 0) {
    Write-Host '=== SECURITY: Unsafe commands detected ===' -ForegroundColor Red
    $rejected | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    Write-Host ''
    Write-Host 'Allowed cmdlets:' -ForegroundColor Yellow
    $allowedCmdlets | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    Write-Host ''
    Write-Error 'Rollback aborted. All commands must use allowed cmdlets only.'
    exit 1
}

Write-Host "=== Rollback: $BackupFile ==="
Write-Host "Found $($commands.Count) commands (all validated safe)."
Write-Host ''

if ($WhatIf) {
    Write-Host '--- WhatIf mode: commands that would be executed ---'
    $commands | ForEach-Object { Write-Host "  $_" }
    Write-Host ''
    Write-Host 'Run without -WhatIf to apply.'
    exit 0
}

Write-Host 'Applying rollback commands...'
Write-Host ''

$ok   = 0
$fail = 0
foreach ($cmd in $commands) {
    try {
        Write-Host "  > $cmd"
        # Safe to execute: all commands validated against allowlist above
        Invoke-Expression $cmd
        $ok++
    } catch {
        Write-Warning "  FAILED: $($_.Exception.Message)"
        $fail++
    }
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host "[OK] Rollback complete: $ok commands applied, 0 failures."
    Write-Host '     Reboot required for interrupt affinity changes to take effect.'
} else {
    Write-Warning "Rollback finished with $fail failure(s) out of $($ok + $fail) commands."
    Write-Host '     Review warnings above. Some settings may not have been restored.'
}
