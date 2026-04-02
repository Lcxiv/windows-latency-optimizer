#Requires -RunAsAdministrator
<#
.SYNOPSIS
    System latency audit — detects known Windows gaming latency issues.
.DESCRIPTION
    Checks 32 OS, NIC, GPU, memory, peripheral, and network settings.
    Outputs JSON + self-contained HTML report. Optionally generates fix script.
.EXAMPLE
    .\audit.ps1 -Mode Quick
    .\audit.ps1 -Mode Deep -GenerateFix
#>
param(
    [ValidateSet('Quick','Deep')]
    [string]$Mode = 'Quick',

    [switch]$GenerateFix,

    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent

if ($OutDir -eq '') { $OutDir = Join-Path $projectRoot 'captures\audits' }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

# Dot-source helpers
. (Join-Path $PSScriptRoot 'audit-checks.ps1')
. (Join-Path $PSScriptRoot 'audit-report.ps1')

$timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$auditedAt  = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'

Write-Host '=== System Latency Audit ===' -ForegroundColor Cyan
Write-Host ('Mode: ' + $Mode + ' | Timestamp: ' + $timestamp)
Write-Host ''

Write-Host 'Collecting system information...' -ForegroundColor Yellow
$sysInfo = Get-SystemInfo

Write-Host ('  CPU: ' + $sysInfo.cpu)
Write-Host ('  GPU: ' + $sysInfo.gpu + ' (driver ' + $sysInfo.gpuDriver + ')')
Write-Host ('  RAM: ' + $sysInfo.ram)
Write-Host ('  NIC: ' + $sysInfo.nic + ' (driver ' + $sysInfo.nicDriver + ')')
Write-Host ''

# --- Run checks (Tasks 2-5 populate these functions) ---
$allChecks = @()
# Quick tier
$allChecks += Invoke-OsChecks
$allChecks += Invoke-NicChecks
$allChecks += Invoke-GpuChecks
# Deep tier
if ($Mode -eq 'Deep') {
    $allChecks += Invoke-MemoryChecks
    $allChecks += Invoke-PeripheralChecks
    $allChecks += Invoke-NetworkChecks
}

# --- Aggregate results ---
$pass  = ($allChecks | Where-Object { $_.status -eq 'PASS'  }).Count
$warn  = ($allChecks | Where-Object { $_.status -eq 'WARN'  }).Count
$fail  = ($allChecks | Where-Object { $_.status -eq 'FAIL'  }).Count
$skip  = ($allChecks | Where-Object { $_.status -eq 'SKIP'  }).Count
$errCount = ($allChecks | Where-Object { $_.status -eq 'ERROR' }).Count
$denom = $allChecks.Count - $skip - $errCount
$score = 0
if ($denom -gt 0) { $score = [math]::Round(($pass / $denom) * 100) }

$summary = [ordered]@{
    total = $allChecks.Count
    pass  = $pass
    warn  = $warn
    fail  = $fail
    skip  = $skip
    error = $errCount
    score = $score
}

Write-Host ('Score: ' + $score + '% (' + $pass + ' pass, ' + $warn + ' warn, ' + $fail + ' fail, ' + $skip + ' skip)')
Write-Host ''

# --- Write JSON ---
$jsonPath = Join-Path $OutDir ('audit_' + $timestamp + '.json')
$result = [ordered]@{
    schemaVersion = 1
    auditedAt     = $auditedAt
    mode          = $Mode
    system        = $sysInfo
    summary       = $summary
    checks        = $allChecks
    fixScriptPath = ''
}
($result | ConvertTo-Json -Depth 8) | Out-File -FilePath $jsonPath -Encoding UTF8
Write-Host ('JSON:  ' + $jsonPath) -ForegroundColor Green

# --- Write HTML ---
$htmlPath = Join-Path $OutDir ('audit_' + $timestamp + '.html')
$html = New-AuditHtmlReport -Summary $summary -Checks $allChecks -SystemInfo $sysInfo -AuditedAt $auditedAt -Mode $Mode
$html | Out-File -FilePath $htmlPath -Encoding UTF8
Write-Host ('HTML:  ' + $htmlPath) -ForegroundColor Green

# --- Fix script (Task 8) ---
if ($GenerateFix) {
    Write-Host 'Fix script generation: implemented in Task 8'
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Cyan
