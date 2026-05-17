<#
.SYNOPSIS
    Diagnostic dispatcher — triage symptoms and run domain-specific diagnostics.
.DESCRIPTION
    Entrypoint shim. Logic lives in scripts\diagnose\{classify,dispatch,summary}.ps1.
    No args → interactive menu. -Symptom for keyword classification or -Domain
    for direct selection.
.PARAMETER Symptom
    Free-text symptom description. Keywords are matched to domains automatically.
.PARAMETER Domain
    Direct domain selection: dpc, gpu, net, system, all.
.PARAMETER Quick
    Only run diagnostics that do not require admin elevation.
.PARAMETER Interactive
    Force interactive menu (default when no args are provided).
.PARAMETER OutputDir
    Override output directory (default: captures\diagnostics).
.PARAMETER MonitorOutput
    Also write diagnose_latest.js for the live monitoring dashboard.
.EXAMPLE
    .\diagnose.ps1
    .\diagnose.ps1 -Symptom "mouse stutters in Fortnite"
    .\diagnose.ps1 -Domain dpc -Quick
    .\diagnose.ps1 -Domain all
.NOTES
    PowerShell 5.1 compatible. Most full diagnostics require admin elevation.
#>
param(
    [string]$Symptom = '',
    [ValidateSet('','dpc','gpu','net','system','all')]
    [string]$Domain = '',
    [switch]$Quick,
    [switch]$Interactive,
    [string]$OutputDir = '',
    [switch]$MonitorOutput
)

$ErrorActionPreference = 'Continue'

# Script-scoped state — helpers read these via $script:* lookups
$script:Symptom      = $Symptom
$script:Quick        = $Quick
$script:IsAdmin      = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:ProjectRoot  = Split-Path $PSScriptRoot -Parent
$script:Timestamp    = Get-Date -Format 'yyyyMMdd_HHmmss'
$script:TimestampIso = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'

if ($OutputDir -eq '') { $OutputDir = Join-Path $script:ProjectRoot 'captures\diagnostics' }
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$script:OutputDir = $OutputDir

# Dot-source helpers (idempotency-guarded internally)
. (Join-Path $PSScriptRoot 'diagnose\classify.ps1')
. (Join-Path $PSScriptRoot 'diagnose\dispatch.ps1')
. (Join-Path $PSScriptRoot 'diagnose\summary.ps1')
. (Join-Path $PSScriptRoot 'diagnose\report.ps1')

# Resolve domain (CLI args / interactive menu)
$resolved = Resolve-SelectedDomain -Symptom $Symptom -Domain $Domain
$selectedDomain = $resolved.selectedDomain
$classification = $resolved.classification
if ($selectedDomain -eq '') { Write-Host 'No domain selected. Exiting.' -ForegroundColor Red; return }

# Admin banner
Write-Host ''
if ($script:IsAdmin) { Write-Host '  Elevated: YES (full diagnostics available)' -ForegroundColor Green }
else {
    Write-Host '  Elevated: NO (some diagnostics will be skipped)' -ForegroundColor Yellow
    Write-Host '  Tip: Run as Administrator for full diagnostics' -ForegroundColor DarkGray
}
if ($Quick) { Write-Host '  Mode: QUICK (admin-required scripts skipped)' -ForegroundColor Yellow }
Write-Host ''

# Run + score
$chain = Invoke-DiagnosticChain -SelectedDomain $selectedDomain
$results = $chain.Results
if ($results.Count -eq 0) { return }
$severity = Get-Severity $results
$recommendations = @(Get-Recommendations $results $selectedDomain)

# Persist + display
$jsonPath = Save-DiagnoseReport `
    -Results $results -SelectedDomain $selectedDomain -Classification $classification `
    -Symptom $script:Symptom -Quick ([bool]$Quick) -IsAdmin $script:IsAdmin `
    -TotalMs $chain.TotalMs -Severity $severity -Recommendations $recommendations `
    -OutputDir $script:OutputDir -Timestamp $script:Timestamp -TimestampIso $script:TimestampIso `
    -MonitorOutput ([bool]$MonitorOutput) -ProjectRoot $script:ProjectRoot

Write-Summary $results $selectedDomain $severity $recommendations $jsonPath
