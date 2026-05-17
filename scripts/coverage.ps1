<#
.SYNOPSIS
    Pester code-coverage report wrapper.
.DESCRIPTION
    Runs Invoke-Pester with -CodeCoverage over all scripts/*.ps1 (excludes
    _deprecated/). Prints a coverage table; first-run baseline is
    report-only (no floor gate).
.PARAMETER OutFile
    Path to write summary text file. CI uploads this as an artifact.
.EXAMPLE
    pwsh -File scripts/coverage.ps1
    pwsh -File scripts/coverage.ps1 -OutFile coverage-summary.txt
.NOTES
    PowerShell 5.1 + Pester 3.4.0. No ternary, no Join-String.
#>
#Requires -Version 5.1
[CmdletBinding()]
param([string]$OutFile = 'coverage-summary.txt')

$ErrorActionPreference = 'Continue'

# Idempotency: re-import Pester at pinned version (avoid v5 syntax mismatch)
Get-Module -Name Pester | Remove-Module -Force -ErrorAction SilentlyContinue
if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.ToString() -eq '3.4.0' })) {
    Write-Host 'Pester 3.4.0 not found locally — installing...' -ForegroundColor Yellow
    Install-Module -Name Pester -RequiredVersion 3.4.0 -Force -Scope CurrentUser -SkipPublisherCheck -AllowClobber
}
Import-Module -Name Pester -RequiredVersion 3.4.0 -Force

$repoRoot = Split-Path -Parent $PSScriptRoot
$testsDir = Join-Path $repoRoot 'tests'

# Scope: scripts/ recursive, exclude _deprecated
$ps1 = Get-ChildItem (Join-Path $repoRoot 'scripts') -Filter *.ps1 -Recurse -File |
    Where-Object { $_.FullName -notmatch '\\_deprecated\\' } |
    Select-Object -ExpandProperty FullName

Write-Host ('Coverage scope: ' + $ps1.Count + ' scripts under scripts/') -ForegroundColor Cyan
Write-Host ('Tests dir:      ' + $testsDir) -ForegroundColor Cyan
Write-Host ''

# Pester 3.4.0 accepts -CodeCoverage as string[]
$r = Invoke-Pester -Path $testsDir -CodeCoverage $ps1 -PassThru -Quiet

$total = 0
$hit   = 0
if ($null -ne $r.CodeCoverage) {
    $total = [int]$r.CodeCoverage.NumberOfCommandsAnalyzed
    $hit   = [int]$r.CodeCoverage.NumberOfCommandsExecuted
}

$pct = 0
if ($total -gt 0) {
    $pct = [Math]::Round(($hit * 100.0) / $total, 1)
}

# Per-file breakdown
$perFile = @()
if ($null -ne $r.CodeCoverage -and $null -ne $r.CodeCoverage.HitCommands) {
    $hitByFile = $r.CodeCoverage.HitCommands  | Group-Object File
    $missByFile = $r.CodeCoverage.MissedCommands | Group-Object File

    $allFiles = @{}
    foreach ($g in $hitByFile)  { $allFiles[$g.Name] = @{ Hit = $g.Count;  Miss = 0 } }
    foreach ($g in $missByFile) {
        if ($allFiles.ContainsKey($g.Name)) { $allFiles[$g.Name].Miss = $g.Count }
        else                                 { $allFiles[$g.Name] = @{ Hit = 0; Miss = $g.Count } }
    }

    foreach ($file in ($allFiles.Keys | Sort-Object)) {
        $f = $allFiles[$file]
        $fileTotal = $f.Hit + $f.Miss
        $filePct = 0
        if ($fileTotal -gt 0) { $filePct = [Math]::Round(($f.Hit * 100.0) / $fileTotal, 1) }
        $rel = $file
        if ($rel.StartsWith($repoRoot)) { $rel = $rel.Substring($repoRoot.Length + 1) }
        $perFile += [pscustomobject]@{
            File    = $rel
            Hit     = $f.Hit
            Missed  = $f.Miss
            Total   = $fileTotal
            Percent = $filePct
        }
    }
}

# Write summary file
$lines = New-Object System.Collections.ArrayList
[void]$lines.Add('# Pester Coverage Summary')
[void]$lines.Add('')
[void]$lines.Add('Generated: ' + (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ'))
[void]$lines.Add('Tests:      ' + $r.PassedCount + ' passed / ' + $r.FailedCount + ' failed / ' + $r.TotalCount + ' total')
[void]$lines.Add('')
[void]$lines.Add(('Coverage: {0}% ({1}/{2} commands)' -f $pct, $hit, $total))
[void]$lines.Add('')
[void]$lines.Add('## Per-file (files with any tested commands)')
[void]$lines.Add('')
[void]$lines.Add('| File | Hit | Missed | % |')
[void]$lines.Add('|---|---:|---:|---:|')
foreach ($pf in ($perFile | Sort-Object Percent -Descending)) {
    [void]$lines.Add(('| {0} | {1} | {2} | {3}% |' -f $pf.File, $pf.Hit, $pf.Missed, $pf.Percent))
}

$lines | Set-Content -Path $OutFile -Encoding UTF8

Write-Host ('Coverage: ' + $pct + '% (' + $hit + '/' + $total + ' commands)') -ForegroundColor Green
Write-Host ('Summary written: ' + $OutFile) -ForegroundColor DarkGray

exit 0
