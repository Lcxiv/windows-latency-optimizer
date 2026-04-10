# helpers/logging.ps1
# Core logging and statistics functions used by all other helper modules.
# PowerShell 5.1 compatible.

function Log {
    param([string]$msg, [string]$level = 'INFO')
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
