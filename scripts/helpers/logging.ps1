# helpers/logging.ps1
# Core logging and statistics functions used by all other helper modules.
# PowerShell 5.1 compatible.

$script:logRotationChecked = $false

function Get-LogPath {
    if ($env:LATENCYGUARD_LOG) {
        return $env:LATENCYGUARD_LOG
    }
    return (Join-Path $PSScriptRoot '..\..\captures\latencyguard.log')
}

function Log {
    param([string]$msg, [string]$level = 'INFO')

    # Rotate if > 5MB (check once per session via script-scope flag)
    if (-not $script:logRotationChecked) {
        $script:logRotationChecked = $true
        $logPath = Get-LogPath
        try {
            if ((Test-Path $logPath) -and (Get-Item $logPath).Length -gt 5MB) {
                $bakPath = $logPath + '.bak'
                if (Test-Path $bakPath) { Remove-Item $bakPath -Force }
                Rename-Item $logPath $bakPath
            }
        } catch {
            # Non-fatal: rotation failure should not crash calling script
        }
    }

    $ts = Get-Date -Format 'HH:mm:ss'
    $line = '[' + $ts + '] [' + $level + '] ' + $msg
    $script:logLines += $line
    switch ($level) {
        'PASS' { Write-Host $line -ForegroundColor Green }
        'FAIL' { Write-Host $line -ForegroundColor Red }
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'INFO' { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line }
    }

    # Append to log file with full date timestamp
    try {
        $fileLine = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] [' + $level + '] ' + $msg
        Add-Content -Path (Get-LogPath) -Value $fileLine -Encoding UTF8
    } catch {
        # Non-fatal: file write failure should not crash calling script
    }
}

function Log-Error {
    param([string]$msg, [System.Management.Automation.ErrorRecord]$ErrorRecord)
    $detail = $msg
    if ($ErrorRecord) {
        $detail += ' | ' + $ErrorRecord.Exception.Message
        $detail += ' @ ' + $ErrorRecord.InvocationInfo.ScriptName + ':' + $ErrorRecord.InvocationInfo.ScriptLineNumber
    }
    Log $detail 'ERROR'
}

function Get-Stats($vals) {
    $m = $vals | Measure-Object -Average -Minimum -Maximum
    # Compute stdev manually (PS 5.1 lacks -StandardDeviation)
    $avg = $m.Average
    $sumSq = 0; foreach ($v in $vals) { $sumSq += ($v - $avg) * ($v - $avg) }
    $sd = [math]::Sqrt($sumSq / [math]::Max(1, $vals.Count - 1))
    return @{
        avg   = [math]::Round($m.Average, 4)
        min   = [math]::Round($m.Minimum, 4)
        max   = [math]::Round($m.Maximum, 4)
        stdev = [math]::Round($sd, 4)
    }
}
