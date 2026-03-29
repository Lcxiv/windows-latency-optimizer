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
# PowerShell commands that can be extracted and executed directly.
#
# Usage:
#   .\rollback.ps1 -BackupFile ..\captures\backup_pre_fix2.txt
#   .\rollback.ps1 -BackupFile ..\captures\backup_pre_fix2.txt -WhatIf
#
# The -WhatIf flag prints the commands that would be run without executing them.
# =============================================================================

$ErrorActionPreference = "Stop"

if (-not (Test-Path $BackupFile)) {
    Write-Error "Backup file not found: $BackupFile"
    exit 1
}

$lines   = Get-Content $BackupFile
$inBlock = $false
$commands = @()

foreach ($line in $lines) {
    # Detect start of rollback section
    if ($line -match '=== Rollback') {
        $inBlock = $true
        continue
    }
    # Stop at next === section header (if any)
    if ($inBlock -and $line -match '^===' -and $line -notmatch 'Rollback') {
        $inBlock = $false
        continue
    }
    if (-not $inBlock) { continue }

    # Skip blank lines and comment lines
    $trimmed = $line.Trim()
    if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }

    $commands += $trimmed
}

if ($commands.Count -eq 0) {
    Write-Error "No rollback commands found in: $BackupFile"
    Write-Host "Expected a section starting with '=== Rollback Commands'"
    exit 1
}

Write-Host "=== Rollback: $BackupFile ==="
Write-Host "Found $($commands.Count) commands."
Write-Host ""

if ($WhatIf) {
    Write-Host "--- WhatIf mode: commands that would be executed ---"
    $commands | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
    Write-Host "Run without -WhatIf to apply."
    exit 0
}

Write-Host "Applying rollback commands..."
Write-Host ""

$ok    = 0
$fail  = 0
foreach ($cmd in $commands) {
    try {
        Write-Host "  > $cmd"
        Invoke-Expression $cmd
        $ok++
    } catch {
        Write-Warning "  FAILED: $($_.Exception.Message)"
        $fail++
    }
}

Write-Host ""
if ($fail -eq 0) {
    Write-Host "[OK] Rollback complete: $ok commands applied, 0 failures."
    Write-Host "     Reboot required for interrupt affinity changes to take effect."
} else {
    Write-Warning "Rollback finished with $fail failure(s) out of $($ok+$fail) commands."
    Write-Host "     Review warnings above. Some settings may not have been restored."
}
