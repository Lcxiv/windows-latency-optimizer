<#
.SYNOPSIS
    Add UTF-8 BOM to every .ps1 / .psd1 file containing non-ASCII bytes.
.DESCRIPTION
    PS 5.1 reads BOM-less .ps1 files as Windows-1252. UTF-8 multi-byte chars
    (em-dash, smart quotes, box-drawing) become garbage tokens that wreck the
    parser. This helper finds files with non-ASCII content but no BOM, and
    re-saves them as UTF-8 with BOM. See .claude/CLAUDE.md pitfall #7.

    Skipped by default: _deprecated/, node_modules/, captures/, .git/.
.PARAMETER Root
    Directory to scan. Defaults to repo root (parent of scripts/).
.PARAMETER DryRun
    Report files that would be modified, but make no changes.
.EXAMPLE
    pwsh -File scripts/_add-bom-all.ps1
    pwsh -File scripts/_add-bom-all.ps1 -DryRun
    pwsh -File scripts/_add-bom-all.ps1 -Root scripts/
.NOTES
    PowerShell 5.1 compatible. Idempotent — running twice is a no-op.
    Originally written for spike branch; ported to master per audit follow-up.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [switch]$DryRun
)

$Root = (Resolve-Path $Root).Path
Write-Host ('Scanning: ' + $Root) -ForegroundColor Cyan
if ($DryRun) { Write-Host '(DryRun — no files will be modified)' -ForegroundColor Yellow }

$excludePatterns = @(
    '\\_deprecated\\',
    '\\node_modules\\',
    '\\captures\\',
    '\\\.git\\',
    '\\\.chrome-test-profile\\'
)

$files = Get-ChildItem -Path $Root -Recurse -Include *.ps1, *.psd1 -File |
    Where-Object {
        $path = $_.FullName
        $excluded = $false
        foreach ($p in $excludePatterns) {
            if ($path -match $p) { $excluded = $true; break }
        }
        -not $excluded
    }

$count = 0
$candidates = 0
foreach ($f in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $hasNonAscii = $false
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -gt 127) { $hasNonAscii = $true; break }
    }
    if ($hasNonAscii -and -not $hasBom) {
        $candidates++
        $rel = $f.FullName.Substring($Root.Length + 1)
        if ($DryRun) {
            Write-Host ('WOULD ADD BOM: ' + $rel) -ForegroundColor Yellow
        } else {
            $content = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
            $enc = New-Object System.Text.UTF8Encoding($true)
            [System.IO.File]::WriteAllText($f.FullName, $content, $enc)
            Write-Host ('BOM added: ' + $rel) -ForegroundColor Green
            $count++
        }
    }
}

Write-Host ''
if ($DryRun) {
    Write-Host ('Candidates: ' + $candidates + ' (no changes made)') -ForegroundColor Yellow
} else {
    Write-Host ('Total BOMs added: ' + $count) -ForegroundColor Green
}
