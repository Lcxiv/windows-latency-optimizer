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
    .\audit.ps1 -Mode Quick -Threshold 80 -Quiet
#>
param(
    [ValidateSet('Quick','Deep')]
    [string]$Mode = 'Quick',

    [switch]$GenerateFix,

    [int]$Threshold = -1,

    [switch]$Quiet,

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

if (-not $Quiet) {
    Write-Host '=== System Latency Audit ===' -ForegroundColor Cyan
    Write-Host ('Mode: ' + $Mode + ' | Timestamp: ' + $timestamp)
    Write-Host ''
}

if (-not $Quiet) { Write-Host 'Collecting system information...' -ForegroundColor Yellow }
$sysInfo = Get-SystemInfo

if (-not $Quiet) {
    Write-Host ('  CPU: ' + $sysInfo.cpu)
    Write-Host ('  GPU: ' + $sysInfo.gpu + ' (driver ' + $sysInfo.gpuDriver + ')')
    Write-Host ('  RAM: ' + $sysInfo.ram)
    Write-Host ('  NIC: ' + $sysInfo.nic + ' (driver ' + $sysInfo.nicDriver + ')')
    Write-Host ''
}

# --- Run checks ---
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
    $allChecks += Invoke-AntiCheatChecks
    $allChecks += Invoke-NvidiaDpcHealthCheck
}

# --- Aggregate results ---
$pass     = @($allChecks | Where-Object { $_.status -eq 'PASS'  }).Count
$warn     = @($allChecks | Where-Object { $_.status -eq 'WARN'  }).Count
$fail     = @($allChecks | Where-Object { $_.status -eq 'FAIL'  }).Count
$skip     = @($allChecks | Where-Object { $_.status -eq 'SKIP'  }).Count
$errCount = @($allChecks | Where-Object { $_.status -eq 'ERROR' }).Count
$denom    = $allChecks.Count - $skip - $errCount
$score    = 0
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

if ($Quiet) {
    Write-Host ('Score: ' + $score + '%')
} else {
    Write-Host ('Score: ' + $score + '% (' + $pass + ' pass, ' + $warn + ' warn, ' + $fail + ' fail, ' + $skip + ' skip)')
    Write-Host ''
}

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
if (-not $Quiet) { Write-Host ('JSON:  ' + $jsonPath) -ForegroundColor Green }

# --- Append to history CSV ---
$historyPath = Join-Path $OutDir 'history.csv'
if (-not (Test-Path $historyPath)) {
    'timestamp,mode,score,pass,warn,fail,skip' | Out-File -FilePath $historyPath -Encoding UTF8
}
$histLine = $auditedAt + ',' + $Mode + ',' + $score + ',' + $pass + ',' + $warn + ',' + $fail + ',' + $skip
$histLine | Out-File -FilePath $historyPath -Encoding UTF8 -Append

# --- Load history for HTML sparkline ---
$historyData = @()
try {
    $histRows = Import-Csv $historyPath -ErrorAction Stop
    foreach ($row in $histRows) {
        $historyData += [ordered]@{
            timestamp = $row.timestamp
            score     = [int]$row.score
        }
    }
} catch {}

# --- Load latest pipeline data for report ---
$pipelineData = $null
$expRoot = Join-Path $projectRoot 'captures\experiments'
if (Test-Path $expRoot) {
    $expDirs = @(Get-ChildItem $expRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($expDirs.Count -gt 0) {
        $latestJson = Join-Path $expDirs[0].FullName 'experiment.json'
        if (Test-Path $latestJson) {
            $expAge = (Get-Date) - (Get-Item $latestJson).LastWriteTime
            if ($expAge.TotalHours -lt 24) {
                try {
                    $expData = Get-Content $latestJson -Raw | ConvertFrom-Json -ErrorAction Stop
                    $pipelineData = @{
                        label             = $expData.label
                        capturedAt        = $expData.capturedAt
                        dpcIsrAnalysis    = $expData.dpcIsrAnalysis
                        frameTiming       = $expData.frameTiming
                        cpuData           = $expData.cpuData
                        cpuTotal          = $expData.cpuTotal
                        interruptTopology = $expData.interruptTopology
                        gpuUtilization    = $expData.gpuUtilization
                    }
                    # Also load input latency analysis if present
                    $inputJson = Join-Path $expDirs[0].FullName 'input_latency_analysis.json'
                    if (Test-Path $inputJson) {
                        $inputData = Get-Content $inputJson -Raw | ConvertFrom-Json -ErrorAction Stop
                        $pipelineData['inputLatency'] = $inputData
                    }
                    if (-not $Quiet) { Write-Host ('Pipeline: loaded from ' + $expDirs[0].Name) -ForegroundColor Cyan }
                } catch {
                    if (-not $Quiet) { Write-Host ('Pipeline: failed to load — ' + $_.Exception.Message) -ForegroundColor Yellow }
                }
            }
        }
    }
}

# --- Write HTML ---
$htmlPath = Join-Path $OutDir ('audit_' + $timestamp + '.html')
$html = New-AuditHtmlReport -Summary $summary -Checks $allChecks -SystemInfo $sysInfo -AuditedAt $auditedAt -Mode $Mode -History $historyData -PipelineData $pipelineData
$html | Out-File -FilePath $htmlPath -Encoding UTF8
if (-not $Quiet) { Write-Host ('HTML:  ' + $htmlPath) -ForegroundColor Green }

# --- Fix script ---
if ($GenerateFix) {
    $fixItems = @($allChecks | Where-Object { ($_.status -eq 'FAIL' -or $_.status -eq 'WARN') -and $_.fix -ne '' -and $null -ne $_.fix })
    if ($fixItems.Count -eq 0) {
        if (-not $Quiet) { Write-Host 'No fixable items found — fix script not generated.' -ForegroundColor Yellow }
    } else {
        $fixPath  = Join-Path $OutDir ('fix_' + $timestamp + '.ps1')
        $fixLines = @()
        $fixLines += '#Requires -RunAsAdministrator'
        $fixLines += '<#'
        $fixLines += '.SYNOPSIS'
        $fixLines += '    Generated fix script from system latency audit.'
        $fixLines += '.DESCRIPTION'
        $fixLines += '    Auto-generated by audit.ps1 on ' + $auditedAt
        $fixLines += '    Applies fixes for ' + $fixItems.Count + ' FAIL/WARN items.'
        $fixLines += '    Run rollback.ps1 -BackupFile <backupFile> to undo all changes.'
        $fixLines += '#>'
        $fixLines += ''
        $fixLines += '$ErrorActionPreference = "Stop"'
        $fixLines += ''
        $fixLines += '# === Rollback Commands ==='
        $fixLines += '# (populated below alongside each fix; extracted by rollback.ps1)'
        $fixLines += ''
        foreach ($item in $fixItems) {
            $fixLines += ('# --- ' + $item.name + ' [' + $item.severity + '] ---')
            $fixLines += ('# Current: ' + $item.current)
            $fixLines += ('# Expected: ' + $item.expected)
            if ($item.message -ne '') { $fixLines += ('# Reason: ' + $item.message) }
            $fixLines += $item.fix
            if ($item.fixNote -ne '' -and $null -ne $item.fixNote) {
                $fixLines += ('# NOTE: ' + $item.fixNote)
            }
            $fixLines += ''
        }
        $fixLines += 'Write-Host "Fix script complete. Review notes above for reboot requirements." -ForegroundColor Green'
        $fixLines | Out-File -FilePath $fixPath -Encoding UTF8
        $result['fixScriptPath'] = $fixPath
        ($result | ConvertTo-Json -Depth 8) | Out-File -FilePath $jsonPath -Encoding UTF8
        if (-not $Quiet) { Write-Host ('Fix:   ' + $fixPath) -ForegroundColor Green }
    }
}

if (-not $Quiet) {
    Write-Host ''
    Write-Host 'Done.' -ForegroundColor Cyan
}

# --- Threshold gate (must be last — controls exit code) ---
if ($Threshold -ge 0 -and $score -lt $Threshold) {
    Write-Host ('FAIL: Score ' + $score + '% below threshold ' + $Threshold + '%') -ForegroundColor Red
    exit 1
}
