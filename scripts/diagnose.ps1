<#
.SYNOPSIS
    Diagnostic dispatcher — triage symptoms and run domain-specific diagnostics.
.DESCRIPTION
    Entrypoint shim. Classification logic lives in scripts\diagnose\classify.ps1;
    script dispatch in dispatch.ps1; summary + scoring in summary.ps1.

    No args → interactive menu. -Symptom for keyword classification or -Domain
    to skip classification and run a specific domain directly.
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

if ($OutputDir -eq '') {
    $OutputDir = Join-Path $script:ProjectRoot 'captures\diagnostics'
}
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$script:OutputDir = $OutputDir

# Dot-source helpers (idempotency-guarded internally)
. (Join-Path $PSScriptRoot 'diagnose\classify.ps1')
. (Join-Path $PSScriptRoot 'diagnose\dispatch.ps1')
. (Join-Path $PSScriptRoot 'diagnose\summary.ps1')

# ============================================================================
# Determine domain
# ============================================================================
$classification = $null
$selectedDomain = ''

if ($Domain -ne '') {
    $selectedDomain = $Domain
    $classification = @{ domain = $Domain; confidence = 'explicit'; matchedKeywords = @(); allMatches = @{}; ambiguous = $false }
}
elseif ($Symptom -ne '') {
    $classification = Classify-Symptom $Symptom
    Write-Host ''
    Write-Host ('Classified symptom -> ' + $classification.domain.ToUpper() + ' (confidence: ' + $classification.confidence + ')') -ForegroundColor Cyan
    if ($classification.matchedKeywords.Count -gt 0) {
        Write-Host ('  Matched keywords: ' + ($classification.matchedKeywords -join ', ')) -ForegroundColor DarkGray
    }
    if ($classification.ambiguous) { $selectedDomain = Resolve-Ambiguity $classification }
    else                            { $selectedDomain = $classification.domain }
}
else {
    $menuResult = Show-Menu
    if ($menuResult -eq '') { return }
    if ($menuResult -eq '__classify__') {
        $classification = Classify-Symptom $script:Symptom
        Write-Host ''
        Write-Host ('Classified symptom -> ' + $classification.domain.ToUpper() + ' (confidence: ' + $classification.confidence + ')') -ForegroundColor Cyan
        if ($classification.matchedKeywords.Count -gt 0) {
            Write-Host ('  Matched keywords: ' + ($classification.matchedKeywords -join ', ')) -ForegroundColor DarkGray
        }
        if ($classification.ambiguous) { $selectedDomain = Resolve-Ambiguity $classification }
        else                            { $selectedDomain = $classification.domain }
    } else {
        $selectedDomain = $menuResult
        $classification = @{ domain = $menuResult; confidence = 'menu'; matchedKeywords = @(); allMatches = @{}; ambiguous = $false }
    }
}

if ($selectedDomain -eq '') { Write-Host 'No domain selected. Exiting.' -ForegroundColor Red; return }

# ============================================================================
# Admin banner
# ============================================================================
Write-Host ''
if ($script:IsAdmin) { Write-Host '  Elevated: YES (full diagnostics available)' -ForegroundColor Green }
else {
    Write-Host '  Elevated: NO (some diagnostics will be skipped)' -ForegroundColor Yellow
    Write-Host '  Tip: Run as Administrator for full diagnostics' -ForegroundColor DarkGray
}
if ($Quick) { Write-Host '  Mode: QUICK (admin-required scripts skipped)' -ForegroundColor Yellow }
Write-Host ''

# ============================================================================
# Collect + run scripts
# ============================================================================
$allScripts = @()
if ($selectedDomain -eq 'all') {
    foreach ($d in @('dpc','gpu','net','system')) { $allScripts += @(Get-DomainScripts $d) }
} else {
    $allScripts = @(Get-DomainScripts $selectedDomain)
}
if ($allScripts.Count -eq 0) { Write-Host ('No diagnostic scripts defined for domain: ' + $selectedDomain) -ForegroundColor Red; return }

$totalSw = [System.Diagnostics.Stopwatch]::StartNew()
$results = @()
foreach ($scriptDef in $allScripts) { $results += (Invoke-DiagnosticScript $scriptDef) }
$totalSw.Stop()

$severity = Get-Severity $results
$recommendations = @(Get-Recommendations $results $selectedDomain)

# ============================================================================
# Build + write JSON report
# ============================================================================
$diagnosticEntries = @()
foreach ($r in $results) {
    $diagnosticEntries += [ordered]@{
        script        = $r.script
        domain        = $r.domain
        status        = $r.status
        exitCode      = $r.exitCode
        durationMs    = $r.durationMs
        summary       = $r.summary
        statusLabel   = (Get-StatusLabel $r)
        requiresAdmin = $r.requiresAdmin
    }
}

$classificationOutput = $null
if ($null -ne $classification) {
    $matchedKws = @()
    if ($classification.matchedKeywords -is [array]) { $matchedKws = $classification.matchedKeywords }
    $classificationOutput = [ordered]@{ domain = $classification.domain; confidence = $classification.confidence; matchedKeywords = $matchedKws }
}

$report = [ordered]@{
    timestamp       = $script:TimestampIso
    domain          = $selectedDomain
    symptomText     = $script:Symptom
    isAdmin         = $script:IsAdmin
    quickMode       = [bool]$Quick
    totalDurationMs = [int]$totalSw.ElapsedMilliseconds
    classification  = $classificationOutput
    diagnostics     = $diagnosticEntries
    severity        = $severity
    recommendations = $recommendations
}

$jsonPath = Join-Path $script:OutputDir ('diagnose_' + $script:Timestamp + '.json')
$report | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding utf8
Write-Host ''
Write-Host ('JSON report saved: ' + $jsonPath) -ForegroundColor DarkGray

if ($MonitorOutput) {
    $monitorDir = Join-Path $script:ProjectRoot 'monitor\data'
    if (Test-Path $monitorDir) {
        $jsPath = Join-Path $monitorDir 'diagnose_latest.js'
        ('window.DIAGNOSE_LATEST = ' + ($report | ConvertTo-Json -Depth 10) + ';') | Out-File -FilePath $jsPath -Encoding utf8
        Write-Host ('Monitor JS updated: ' + $jsPath) -ForegroundColor DarkGray
    } else {
        Write-Host ('Monitor directory not found, skipping JS output: ' + $monitorDir) -ForegroundColor DarkGray
    }
}

Write-Summary $results $selectedDomain $severity $recommendations $jsonPath
