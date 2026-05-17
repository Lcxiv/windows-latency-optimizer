<#
.SYNOPSIS
    JSON report persistence + monitor JS export for diagnose.ps1.
.DESCRIPTION
    Save-DiagnoseReport builds the structured report object, writes to
    captures\diagnostics\diagnose_<timestamp>.json, and optionally to
    monitor\data\diagnose_latest.js for the live dashboard.
#>

# Idempotency guard
if (Get-Command 'Save-DiagnoseReport' -ErrorAction SilentlyContinue) { return }

# ============================================================================
# Build + persist the JSON report (and optional monitor JS).
# Returns the JSON output path so callers can pass it into Write-Summary.
# ============================================================================
function Save-DiagnoseReport {
    param(
        [Parameter(Mandatory)][array]$Results,
        [Parameter(Mandatory)][string]$SelectedDomain,
        [hashtable]$Classification,
        [string]$Symptom,
        [bool]$Quick,
        [bool]$IsAdmin,
        [int]$TotalMs,
        [string]$Severity,
        [array]$Recommendations,
        [string]$OutputDir,
        [string]$Timestamp,
        [string]$TimestampIso,
        [bool]$MonitorOutput,
        [string]$ProjectRoot
    )

    $diagnosticEntries = @()
    foreach ($r in $Results) {
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
    if ($null -ne $Classification) {
        $matchedKws = @()
        if ($Classification.matchedKeywords -is [array]) { $matchedKws = $Classification.matchedKeywords }
        $classificationOutput = [ordered]@{
            domain          = $Classification.domain
            confidence      = $Classification.confidence
            matchedKeywords = $matchedKws
        }
    }

    $report = [ordered]@{
        timestamp       = $TimestampIso
        domain          = $SelectedDomain
        symptomText     = $Symptom
        isAdmin         = $IsAdmin
        quickMode       = $Quick
        totalDurationMs = $TotalMs
        classification  = $classificationOutput
        diagnostics     = $diagnosticEntries
        severity        = $Severity
        recommendations = $Recommendations
    }

    $jsonPath = Join-Path $OutputDir ('diagnose_' + $Timestamp + '.json')
    $report | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding utf8
    Write-Host ''
    Write-Host ('JSON report saved: ' + $jsonPath) -ForegroundColor DarkGray

    if ($MonitorOutput) {
        $monitorDir = Join-Path $ProjectRoot 'monitor\data'
        if (Test-Path $monitorDir) {
            $jsPath = Join-Path $monitorDir 'diagnose_latest.js'
            ('window.DIAGNOSE_LATEST = ' + ($report | ConvertTo-Json -Depth 10) + ';') | Out-File -FilePath $jsPath -Encoding utf8
            Write-Host ('Monitor JS updated: ' + $jsPath) -ForegroundColor DarkGray
        } else {
            Write-Host ('Monitor directory not found, skipping JS output: ' + $monitorDir) -ForegroundColor DarkGray
        }
    }

    return $jsonPath
}
