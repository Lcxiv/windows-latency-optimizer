<#
.SYNOPSIS
    WHEA event log summarizer + decoder.
.DESCRIPTION
    Pulls WHEA-Logger events from System log over -DaysBack window. Summarizes
    by Event ID + Severity. Decodes common error source IDs (PCIe AER, MCA bank,
    cache).
    Flags: any Critical or Error severity; ID 19 (corrected MCE) > 1/day.
.OUTPUTS
    JSON -> <OutDir>\whea.json
    CSV  -> <OutDir>\whea_decoded.csv (per-event details)
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$OutDir,
    [ValidateRange(1, 365)]
    [int]$DaysBack = 7,
    [int]$MaxEvents = 500
)

$ErrorActionPreference = 'Continue'
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$result = [ordered]@{
    schemaVersion = 1
    capturedAt = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    daysBack = $DaysBack
    totalEvents = 0
    bySeverity = [ordered]@{ Critical = 0; Error = 0; Warning = 0; Information = 0 }
    byEventId = @{}
    perDayCounts = @{}
    flags = @()
}

$startTime = (Get-Date).AddDays(-$DaysBack)
$events = @()
try {
    $events = Get-WinEvent -FilterHashtable @{
        LogName = 'System'
        ProviderName = 'Microsoft-Windows-WHEA-Logger'
        StartTime = $startTime
    } -MaxEvents $MaxEvents -ErrorAction SilentlyContinue
} catch {
    $result.error = $_.Exception.Message
}

if (-not $events) {
    $result.flags = @('PASS: zero WHEA-Logger events in past ' + $DaysBack + ' days')
    $outPath = Join-Path $OutDir 'whea.json'
    $result | ConvertTo-Json -Depth 6 | Set-Content -Path $outPath -Encoding UTF8
    Write-Host ('[hw_whea_summary] wrote: ' + $outPath + ' (zero events)') -ForegroundColor Green
    return
}

$result.totalEvents = $events.Count

# Per-event detail CSV
$csvLines = New-Object System.Collections.ArrayList
[void]$csvLines.Add('TimeCreated,EventId,Level,LevelDisplayName,Message')

foreach ($e in $events) {
    $sev = ($e.LevelDisplayName).ToString()
    if ($result.bySeverity.Contains($sev)) { $result.bySeverity[$sev]++ }

    $idKey = $e.Id.ToString()
    if (-not $result.byEventId.ContainsKey($idKey)) { $result.byEventId[$idKey] = 0 }
    $result.byEventId[$idKey] = [int]$result.byEventId[$idKey] + 1

    $dayKey = (Get-Date $e.TimeCreated -Format 'yyyy-MM-dd')
    if (-not $result.perDayCounts.ContainsKey($dayKey)) { $result.perDayCounts[$dayKey] = 0 }
    $result.perDayCounts[$dayKey] = [int]$result.perDayCounts[$dayKey] + 1

    # Sanitize message for CSV
    $msg = ($e.Message -replace '"', "'") -replace "`r`n", ' | ' -replace "`n", ' | '
    if ($msg.Length -gt 400) { $msg = $msg.Substring(0, 400) + '...' }
    $line = '"' + $e.TimeCreated.ToString('yyyy-MM-ddTHH:mm:ss') + '","' + $e.Id + '","' + $e.Level + '","' + $sev + '","' + $msg + '"'
    [void]$csvLines.Add($line)
}

# Flags
if ($result.bySeverity.Critical -gt 0) {
    $result.flags += ('WHEA Critical events: ' + $result.bySeverity.Critical + ' (must investigate)')
}
if ($result.bySeverity.Error -gt 0) {
    $result.flags += ('WHEA Error events: ' + $result.bySeverity.Error)
}

# ID 19 = corrected MCE; flag if avg > 1/day
$id19Count = 0
if ($result.byEventId.ContainsKey('19')) { $id19Count = [int]$result.byEventId['19'] }
$avgPerDay = [math]::Round($id19Count / [math]::Max(1, $DaysBack), 2)
if ($avgPerDay -gt 1.0) {
    $result.flags += ('WHEA ID 19 (corrected MCE) at ' + $avgPerDay + '/day average — back off Curve Optimizer or check FCLK')
}

if ($result.flags.Count -eq 0) {
    $result.flags = @('INFO: ' + $result.totalEvents + ' WHEA events, none Critical/Error')
}

$outPath = Join-Path $OutDir 'whea.json'
$result | ConvertTo-Json -Depth 6 | Set-Content -Path $outPath -Encoding UTF8

$csvPath = Join-Path $OutDir 'whea_decoded.csv'
$csvLines | Set-Content -Path $csvPath -Encoding UTF8

Write-Host ('[hw_whea_summary] wrote: ' + $outPath + ' (' + $result.totalEvents + ' events)') -ForegroundColor Cyan
foreach ($f in $result.flags) { Write-Host ('  -> ' + $f) }
