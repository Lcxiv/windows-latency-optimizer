$csvPath = Join-Path $PSScriptRoot "..\captures\procmon_capture.csv"
$csv = Import-Csv $csvPath
$total = $csv.Count

Write-Host "=== ProcMon Analysis ($total events in 30s) ==="
Write-Host ""

# Top processes by event count
Write-Host "--- Top 15 Processes by Event Count ---"
$csv | Group-Object 'Process Name' |
    Sort-Object Count -Descending |
    Select-Object -First 15 @{N='Process';E={$_.Name}}, Count,
        @{N='Pct';E={[math]::Round($_.Count/$total*100,1)}} |
    Format-Table -AutoSize

# Top processes doing file I/O specifically
Write-Host "--- Top 10 Processes by File I/O (Read/Write) ---"
$csv | Where-Object { $_.Operation -match 'Read|Write' -and $_.Path -match '\\' } |
    Group-Object 'Process Name' |
    Sort-Object Count -Descending |
    Select-Object -First 10 @{N='Process';E={$_.Name}}, Count |
    Format-Table -AutoSize

# Operations breakdown
Write-Host "--- Top 10 Operations ---"
$csv | Group-Object Operation |
    Sort-Object Count -Descending |
    Select-Object -First 10 @{N='Operation';E={$_.Name}}, Count |
    Format-Table -AutoSize

# Failed operations (potential stalls)
Write-Host "--- Results != SUCCESS (potential issues) ---"
$csv | Where-Object {
    $_.Result -ne 'SUCCESS' -and
    $_.Result -ne 'BUFFER OVERFLOW' -and
    $_.Result -ne 'END OF FILE' -and
    $_.Result -ne 'NO MORE ENTRIES' -and
    $_.Result -ne 'REPARSE' -and
    $_.Result -ne ''
} |
    Group-Object Result |
    Sort-Object Count -Descending |
    Select-Object -First 10 @{N='Result';E={$_.Name}}, Count |
    Format-Table -AutoSize

# MsMpEng (Defender) activity
Write-Host "--- Windows Defender (MsMpEng) Activity ---"
$defender = $csv | Where-Object { $_.'Process Name' -eq 'MsMpEng.exe' }
Write-Host "Total events: $($defender.Count)"
$defender | Group-Object Operation |
    Sort-Object Count -Descending |
    Select-Object -First 5 @{N='Operation';E={$_.Name}}, Count |
    Format-Table -AutoSize

# Paths most accessed (top hotspots)
Write-Host "--- Top 10 Most Accessed Directories ---"
$csv | Where-Object { $_.Path -match '\\' } |
    ForEach-Object { ($_.Path -split '\\')[0..3] -join '\' } |
    Group-Object |
    Sort-Object Count -Descending |
    Select-Object -First 10 @{N='Directory';E={$_.Name}}, Count |
    Format-Table -AutoSize
