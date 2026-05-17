# helpers/monitor-processes.ps1
# Process snapshot helper: top processes by thread count, gaming overhead flags, audit score.
# Dot-sourced by monitor_collector.ps1.
# PowerShell 5.1 compatible — no ternary, no null-coalescing, no Join-String,
# no -StandardDeviation on Measure-Object. $error and $pid are reserved.

# ---------------------------------------------------------------------------
# Helper: Get-OverheadGroupName
# Returns a human-readable group name for a matched process, or $null.
# Uses -like wildcard matching against known gaming-overhead process names.
# ---------------------------------------------------------------------------
function Get-OverheadGroupName {
    param([string]$ProcessName)

    $pLower = $ProcessName.ToLower()

    if ($pLower -like '*wispr*')                                   { return 'WisprFlow' }
    if ($pLower -like '*afterburner*' -or $pLower -like '*rtss*') { return 'MSIAfterburner' }
    if ($pLower -like '*discord*')                                 { return 'Discord' }
    if ($pLower -like '*steamwebhelper*')                          { return 'SteamWebHelper' }
    if ($pLower -like '*displaywidget*')                           { return 'DisplayWidgetCenter' }
    if ($pLower -like '*searchhost*')                              { return 'SearchHost' }
    if ($pLower -like '*searchindexer*')                           { return 'SearchIndexer' }
    if ($pLower -like '*onedrive*')                                { return 'OneDrive' }
    if ($pLower -like '*teams*')                                   { return 'Teams' }
    if ($pLower -like '*slack*')                                   { return 'Slack' }
    if ($pLower -like '*spotify*')                                 { return 'Spotify' }
    if ($pLower -like '*chrome*')                                  { return 'Chrome' }
    if ($pLower -like '*firefox*')                                 { return 'Firefox' }
    if ($pLower -like '*msedge*')                                  { return 'Edge' }
    if ($pLower -like '*claude*')                                  { return 'Claude' }

    return $null
}

# ---------------------------------------------------------------------------
# Main function: Get-MonitorProcessSnapshot
# ---------------------------------------------------------------------------
function Get-MonitorProcessSnapshot {
    <#
    .SYNOPSIS
        Snapshot top 20 processes by thread count and compute a gaming pre-flight audit score.
    .DESCRIPTION
        Retrieves all running processes (excluding PID 0 and PID 4), sorts by thread count
        descending, and returns the top 20. Also scans ALL processes for known gaming-overhead
        names and aggregates per-group counts. The auditScore is the number of distinct
        overhead groups currently running.
    .OUTPUTS
        Hashtable with keys:
            timestamp  [datetime]
            processes  [array]    — top 20 by thread count:
                                    @{ name; pid; threads; handles; cpuSec; workingSetMB }
            flagged    [array]    — overhead groups running:
                                    @{ group; count; totalThreads; totalWorkingSetMB }
            auditScore [int]      — count of distinct overhead groups running (0 = clean)
    #>

    # ------------------------------------------------------------------
    # Collect all processes
    # ------------------------------------------------------------------
    $allProcs = @(Get-Process -ErrorAction SilentlyContinue)

    # Filter out Idle (PID 0) and System (PID 4)
    $filtered = New-Object System.Collections.ArrayList
    foreach ($proc in $allProcs) {
        $procId = $proc.Id
        if ($procId -eq 0 -or $procId -eq 4) { continue }
        [void]$filtered.Add($proc)
    }

    # ------------------------------------------------------------------
    # Sort by thread count descending, take top 20
    # ------------------------------------------------------------------
    $sorted = @($filtered | Sort-Object { $_.Threads.Count } -Descending)
    $top20  = @($sorted | Select-Object -First 20)

    # ------------------------------------------------------------------
    # Build the top-20 result array
    # ------------------------------------------------------------------
    $processes = New-Object System.Collections.ArrayList
    foreach ($proc in $top20) {
        # CPU seconds: TotalProcessorTime is not always accessible — wrap in try/catch
        $cpuSec = 0.0
        try {
            $cpuSec = [math]::Round($proc.TotalProcessorTime.TotalSeconds, 2)
        } catch {
            $cpuSec = 0.0
        }

        $workingSetMB = [math]::Round($proc.WorkingSet64 / 1MB, 1)

        # Handle count: also not always accessible
        $handleCount = 0
        try {
            $handleCount = $proc.HandleCount
        } catch {
            $handleCount = 0
        }

        [void]$processes.Add(@{
            name         = $proc.ProcessName
            pid          = $proc.Id
            threads      = $proc.Threads.Count
            handles      = $handleCount
            cpuSec       = $cpuSec
            workingSetMB = $workingSetMB
        })
    }

    # ------------------------------------------------------------------
    # Scan ALL processes for gaming overhead (not just top 20)
    # ------------------------------------------------------------------
    # Accumulate per-group: group -> @{ count; totalThreads; totalWorkingSetMB }
    $groupMap = @{}

    foreach ($proc in $filtered) {
        $groupName = Get-OverheadGroupName -ProcessName $proc.ProcessName
        if ($null -eq $groupName) { continue }

        if (-not $groupMap.ContainsKey($groupName)) {
            $groupMap[$groupName] = @{
                count            = 0
                totalThreads     = 0
                totalWorkingSetMB = 0.0
            }
        }

        $groupMap[$groupName].count += 1
        $groupMap[$groupName].totalThreads += $proc.Threads.Count

        $wsMB = 0.0
        try { $wsMB = [math]::Round($proc.WorkingSet64 / 1MB, 1) } catch {}
        $groupMap[$groupName].totalWorkingSetMB += $wsMB
    }

    # Flatten groupMap into a sorted array
    $flagged = New-Object System.Collections.ArrayList
    foreach ($groupName in ($groupMap.Keys | Sort-Object)) {
        $entry = $groupMap[$groupName]
        [void]$flagged.Add(@{
            group            = $groupName
            count            = $entry.count
            totalThreads     = $entry.totalThreads
            totalWorkingSetMB = [math]::Round($entry.totalWorkingSetMB, 1)
        })
    }

    # auditScore = number of distinct overhead groups currently running
    $auditScore = $flagged.Count

    # ------------------------------------------------------------------
    # Return structured result
    # ------------------------------------------------------------------
    return @{
        timestamp  = (Get-Date -Format 'o')
        processes  = $processes.ToArray()
        flagged    = $flagged.ToArray()
        auditScore = $auditScore
    }
}
