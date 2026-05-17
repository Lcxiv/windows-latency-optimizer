<#
.SYNOPSIS
    PSScriptAnalyzer lint wrapper. Scopes to scripts/ only.
.DESCRIPTION
    Default mode prints Warning + Error summary, exits 0.
    -Errors_Only exits 1 iff any Severity=Error finding.
    Tests/, spike/, _deprecated/ are excluded by glob.
.PARAMETER Errors_Only
    Gate on Error severity. Used by CI.
.EXAMPLE
    pwsh -File scripts/lint-all.ps1
.EXAMPLE
    pwsh -File scripts/lint-all.ps1 -Errors_Only
#>
#Requires -Version 5.1
[CmdletBinding()]
param([switch]$Errors_Only)

$ErrorActionPreference = 'Stop'

# Idempotency: install only if missing
if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    Write-Host 'Installing PSScriptAnalyzer...' -ForegroundColor Yellow
    Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force -SkipPublisherCheck -AllowClobber
}
Import-Module PSScriptAnalyzer -Force

$repoRoot = Split-Path -Parent $PSScriptRoot
$settings = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'

if (-not (Test-Path $settings)) {
    Write-Host ('ERROR: settings file not found: ' + $settings) -ForegroundColor Red
    exit 2
}

$scriptsDir = Join-Path $repoRoot 'scripts'

$targets = Get-ChildItem -Path $scriptsDir -Filter *.ps1 -Recurse -File |
    Where-Object {
        $_.FullName -notmatch '\\_deprecated\\' -and
        $_.FullName -notmatch '\\spike\\' -and
        $_.FullName -notmatch '\\tests\\'
    }

Write-Host ('Linting ' + $targets.Count + ' files...') -ForegroundColor Cyan

# Invoke per file — Invoke-ScriptAnalyzer -Path takes a single string, not string[]
$results = New-Object System.Collections.ArrayList
foreach ($f in $targets) {
    $fileResults = Invoke-ScriptAnalyzer -Path $f.FullName -Settings $settings -ErrorAction Continue
    if ($fileResults) {
        foreach ($r in $fileResults) { [void]$results.Add($r) }
    }
}

$errors   = @($results | Where-Object { $_.Severity -eq 'Error' })
$warnings = @($results | Where-Object { $_.Severity -eq 'Warning' })
$info     = @($results | Where-Object { $_.Severity -eq 'Information' })

Write-Host ''
Write-Host ('Errors:   ' + $errors.Count)   -ForegroundColor $(if ($errors.Count -gt 0) { 'Red' } else { 'Green' })
Write-Host ('Warnings: ' + $warnings.Count) -ForegroundColor $(if ($warnings.Count -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ('Info:     ' + $info.Count)     -ForegroundColor Gray
Write-Host ''

if ($errors.Count -gt 0) {
    Write-Host '--- ERRORS ---' -ForegroundColor Red
    $errors | ForEach-Object {
        $rel = $_.ScriptPath.Substring($repoRoot.Length + 1)
        Write-Host ('  ' + $rel + ':' + $_.Line + ' [' + $_.RuleName + '] ' + $_.Message) -ForegroundColor Red
    }
}

if (-not $Errors_Only -and $warnings.Count -gt 0) {
    Write-Host '--- WARNINGS by file ---' -ForegroundColor Yellow
    $warnings | Group-Object ScriptPath | Sort-Object Count -Descending | ForEach-Object {
        $rel = $_.Name.Substring($repoRoot.Length + 1)
        Write-Host ('  ' + $_.Count.ToString().PadLeft(4) + '  ' + $rel) -ForegroundColor Yellow
    }
}

if ($Errors_Only -and $errors.Count -gt 0) { exit 1 }
exit 0
