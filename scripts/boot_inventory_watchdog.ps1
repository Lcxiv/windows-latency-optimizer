<#
.SYNOPSIS
    Boot-time system inventory watchdog. Snapshots all services, installed
    programs, and loaded drivers. Compares against previous boot to detect
    new, changed, or removed items.
.DESCRIPTION
    Run at every boot/logon via scheduled task (pair with boot_registry_watchdog).
    Captures:
      - All Windows services (name, startup type, status, image path)
      - All installed programs (from Uninstall registry keys, 64-bit + 32-bit)
      - All loaded kernel drivers (name, status, image path, version)
      - All scheduled tasks in root + common folders

    Output dir: captures\boot_inventory\
    Files per run:
      snapshot_<YYYYMMDD_HHMMSS>.json   - full inventory
      diff_<YYYYMMDD_HHMMSS>.json       - changes vs previous (only if diffs exist)
      diff_<YYYYMMDD_HHMMSS>.txt        - human-readable diff (only if diffs exist)
      latest.json                        - copy of most recent snapshot

    Exit codes: 0 = no changes, 1 = changes detected, 2 = first run (no prior)
.EXAMPLE
    .\boot_inventory_watchdog.ps1
    .\boot_inventory_watchdog.ps1 -AlertFile C:\Users\L\Desktop\BOOT_INVENTORY_DRIFT.txt
    .\boot_inventory_watchdog.ps1 -Categories Services,Drivers
.NOTES
    Requires admin for full driver enumeration. Runs fine without admin but
    driver list may be incomplete.
#>
[CmdletBinding()]
param(
    [string]$OutputDir = '',
    [string]$AlertFile = '',
    [ValidateSet('Services','Programs','Drivers','Tasks')]
    [string[]]$Categories = @('Services','Programs','Drivers','Tasks')
)

$ErrorActionPreference = 'Continue'
$projectRoot = Split-Path $PSScriptRoot -Parent

if ($OutputDir -eq '') {
    $OutputDir = Join-Path $projectRoot 'captures\boot_inventory'
}
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

# ============================================================================
# INVENTORY COLLECTORS
# ============================================================================

function Get-ServiceInventory {
    <#
    .SYNOPSIS
        Snapshot all Windows services with startup type and image path.
    #>
    $services = @()
    $allSvc = Get-WmiObject Win32_Service -ErrorAction SilentlyContinue
    foreach ($svc in $allSvc) {
        $services += [ordered]@{
            name        = $svc.Name
            displayName = $svc.DisplayName
            startMode   = $svc.StartMode
            state       = $svc.State
            pathName    = $svc.PathName
        }
    }
    return $services
}

function Get-ProgramInventory {
    <#
    .SYNOPSIS
        Snapshot installed programs from registry Uninstall keys (64+32 bit).
    #>
    $programs = @()
    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $seen = @{}
    foreach ($regPath in $uninstallPaths) {
        $items = Get-ItemProperty $regPath -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            $name = $item.DisplayName
            if ([string]::IsNullOrWhiteSpace($name)) { continue }

            # Deduplicate by name+version
            $key = $name + '|' + $item.DisplayVersion
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true

            $programs += [ordered]@{
                name       = $name
                version    = $item.DisplayVersion
                publisher  = $item.Publisher
                installDate = $item.InstallDate
                installLocation = $item.InstallLocation
            }
        }
    }

    # Sort by name for stable comparison
    $programs = $programs | Sort-Object { $_.name }
    return $programs
}

function Get-DriverInventory {
    <#
    .SYNOPSIS
        Snapshot all loaded kernel-mode drivers.
    #>
    $drivers = @()

    # Use driverquery for reliable enumeration
    try {
        $dqOutput = driverquery /v /fo csv 2>&1 | ConvertFrom-Csv -ErrorAction Stop
        foreach ($drv in $dqOutput) {
            $drivers += [ordered]@{
                name        = $drv.'Module Name'
                displayName = $drv.'Display Name'
                type        = $drv.'Driver Type'
                startMode   = $drv.'Start Mode'
                state       = $drv.State
                status      = $drv.Status
                linkDate    = $drv.'Link Date'
                path        = $drv.Path
            }
        }
    } catch {
        # Fallback: WMI
        $wmiDrivers = Get-WmiObject Win32_SystemDriver -ErrorAction SilentlyContinue
        foreach ($drv in $wmiDrivers) {
            $drivers += [ordered]@{
                name        = $drv.Name
                displayName = $drv.DisplayName
                type        = $drv.ServiceType
                startMode   = $drv.StartMode
                state       = $drv.State
                status      = $drv.Status
                linkDate    = $null
                path        = $drv.PathName
            }
        }
    }

    return $drivers
}

function Get-ScheduledTaskInventory {
    <#
    .SYNOPSIS
        Snapshot scheduled tasks (non-Microsoft) that could affect boot behavior.
    #>
    $tasks = @()
    try {
        $allTasks = Get-ScheduledTaskInfo -ErrorAction SilentlyContinue 2>$null
    } catch {
        $allTasks = $null
    }

    $schtasks = Get-ScheduledTask -ErrorAction SilentlyContinue
    foreach ($task in $schtasks) {
        # Skip deeply nested Microsoft maintenance tasks for signal-to-noise
        $path = $task.TaskPath
        if ($path -match '^\\Microsoft\\Windows\\' -and $path -notmatch 'Defrag|UpdateOrchestrator|WindowsUpdate|Maintenance') {
            continue
        }

        $actions = @()
        foreach ($action in $task.Actions) {
            if ($action.Execute) {
                $actionStr = $action.Execute
                if ($action.Arguments) {
                    $actionStr = $actionStr + ' ' + $action.Arguments
                }
                $actions += $actionStr
            }
        }

        $triggerTypes = @()
        foreach ($trigger in $task.Triggers) {
            $triggerTypes += $trigger.CimClass.CimClassName -replace 'MSFT_Task', '' -replace 'Trigger', ''
        }

        $tasks += [ordered]@{
            path       = $task.TaskPath + $task.TaskName
            state      = $task.State.ToString()
            actions    = ($actions -join ' | ')
            triggers   = ($triggerTypes -join ', ')
        }
    }

    return $tasks
}

# ============================================================================
# BUILD SNAPSHOT
# ============================================================================

Write-Host '=== Boot Inventory Watchdog ===' -ForegroundColor Cyan
Write-Host ''

$snapshot = [ordered]@{
    _meta = [ordered]@{
        capturedAt  = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        hostname    = $env:COMPUTERNAME
        buildNumber = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'CurrentBuildNumber' -ErrorAction SilentlyContinue).CurrentBuildNumber
        categories  = $Categories -join ','
    }
}

if ($Categories -contains 'Services') {
    Write-Host '  Collecting services...' -NoNewline
    $snapshot.services = Get-ServiceInventory
    Write-Host (' ' + $snapshot.services.Count + ' found') -ForegroundColor Green
}

if ($Categories -contains 'Programs') {
    Write-Host '  Collecting installed programs...' -NoNewline
    $snapshot.programs = Get-ProgramInventory
    Write-Host (' ' + $snapshot.programs.Count + ' found') -ForegroundColor Green
}

if ($Categories -contains 'Drivers') {
    Write-Host '  Collecting loaded drivers...' -NoNewline
    $snapshot.drivers = Get-DriverInventory
    Write-Host (' ' + $snapshot.drivers.Count + ' found') -ForegroundColor Green
}

if ($Categories -contains 'Tasks') {
    Write-Host '  Collecting scheduled tasks...' -NoNewline
    $snapshot.tasks = Get-ScheduledTaskInventory
    Write-Host (' ' + $snapshot.tasks.Count + ' found') -ForegroundColor Green
}

Write-Host ''

# ============================================================================
# SAVE SNAPSHOT
# ============================================================================

$snapshotPath = Join-Path $OutputDir ('snapshot_' + $timestamp + '.json')
$snapshot | ConvertTo-Json -Depth 5 | Set-Content -Path $snapshotPath -Encoding UTF8
Copy-Item $snapshotPath (Join-Path $OutputDir 'latest.json') -Force

# ============================================================================
# DIFF AGAINST PREVIOUS
# ============================================================================

function Compare-InventoryList {
    <#
    .SYNOPSIS
        Compare two lists of inventory items by a key field.
        Returns added, removed, and changed items.
    #>
    param(
        [string]$CategoryName,
        [string]$KeyField,
        [string[]]$CompareFields,
        [array]$Previous,
        [array]$Current
    )

    $result = [ordered]@{
        category = $CategoryName
        added    = @()
        removed  = @()
        changed  = @()
    }

    # Build lookup by key
    $prevMap = @{}
    foreach ($item in $Previous) {
        $k = $item.$KeyField
        if ($k) { $prevMap[$k] = $item }
    }

    $curMap = @{}
    foreach ($item in $Current) {
        $k = $item.$KeyField
        if ($k) { $curMap[$k] = $item }
    }

    # Find added
    foreach ($k in $curMap.Keys) {
        if (-not $prevMap.ContainsKey($k)) {
            $result.added += $curMap[$k]
        }
    }

    # Find removed
    foreach ($k in $prevMap.Keys) {
        if (-not $curMap.ContainsKey($k)) {
            $result.removed += $prevMap[$k]
        }
    }

    # Find changed (present in both but fields differ)
    foreach ($k in $curMap.Keys) {
        if (-not $prevMap.ContainsKey($k)) { continue }

        $cur = $curMap[$k]
        $prv = $prevMap[$k]
        $fieldDiffs = @()

        foreach ($f in $CompareFields) {
            $curVal = $cur.$f
            $prvVal = $prv.$f
            $curStr = if ($null -eq $curVal) { '' } else { $curVal.ToString() }
            $prvStr = if ($null -eq $prvVal) { '' } else { $prvVal.ToString() }

            if ($curStr -ne $prvStr) {
                $fieldDiffs += [ordered]@{
                    field    = $f
                    previous = $prvStr
                    current  = $curStr
                }
            }
        }

        if ($fieldDiffs.Count -gt 0) {
            $result.changed += [ordered]@{
                key     = $k
                changes = $fieldDiffs
            }
        }
    }

    return $result
}

$allSnapshots = Get-ChildItem $OutputDir -Filter 'snapshot_*.json' | Sort-Object Name -Descending
$exitCode = 2  # first run

if ($allSnapshots.Count -ge 2) {
    $prevPath = $allSnapshots[1].FullName
    $prev = Get-Content $prevPath -Raw | ConvertFrom-Json

    $categoryDiffs = @()
    $totalAdded = 0
    $totalRemoved = 0
    $totalChanged = 0

    # Services
    if ($Categories -contains 'Services' -and $prev.services) {
        $svcDiff = Compare-InventoryList -CategoryName 'Services' -KeyField 'name' `
            -CompareFields @('startMode','state','pathName') `
            -Previous $prev.services -Current $snapshot.services
        $totalAdded += $svcDiff.added.Count
        $totalRemoved += $svcDiff.removed.Count
        $totalChanged += $svcDiff.changed.Count
        if ($svcDiff.added.Count -gt 0 -or $svcDiff.removed.Count -gt 0 -or $svcDiff.changed.Count -gt 0) {
            $categoryDiffs += $svcDiff
        }
    }

    # Programs
    if ($Categories -contains 'Programs' -and $prev.programs) {
        $progDiff = Compare-InventoryList -CategoryName 'Programs' -KeyField 'name' `
            -CompareFields @('version','installDate') `
            -Previous $prev.programs -Current $snapshot.programs
        $totalAdded += $progDiff.added.Count
        $totalRemoved += $progDiff.removed.Count
        $totalChanged += $progDiff.changed.Count
        if ($progDiff.added.Count -gt 0 -or $progDiff.removed.Count -gt 0 -or $progDiff.changed.Count -gt 0) {
            $categoryDiffs += $progDiff
        }
    }

    # Drivers
    if ($Categories -contains 'Drivers' -and $prev.drivers) {
        $drvDiff = Compare-InventoryList -CategoryName 'Drivers' -KeyField 'name' `
            -CompareFields @('state','startMode','linkDate','path') `
            -Previous $prev.drivers -Current $snapshot.drivers
        $totalAdded += $drvDiff.added.Count
        $totalRemoved += $drvDiff.removed.Count
        $totalChanged += $drvDiff.changed.Count
        if ($drvDiff.added.Count -gt 0 -or $drvDiff.removed.Count -gt 0 -or $drvDiff.changed.Count -gt 0) {
            $categoryDiffs += $drvDiff
        }
    }

    # Scheduled Tasks
    if ($Categories -contains 'Tasks' -and $prev.tasks) {
        $taskDiff = Compare-InventoryList -CategoryName 'Tasks' -KeyField 'path' `
            -CompareFields @('state','actions','triggers') `
            -Previous $prev.tasks -Current $snapshot.tasks
        $totalAdded += $taskDiff.added.Count
        $totalRemoved += $taskDiff.removed.Count
        $totalChanged += $taskDiff.changed.Count
        if ($taskDiff.added.Count -gt 0 -or $taskDiff.removed.Count -gt 0 -or $taskDiff.changed.Count -gt 0) {
            $categoryDiffs += $taskDiff
        }
    }

    $totalChanges = $totalAdded + $totalRemoved + $totalChanged

    if ($totalChanges -gt 0) {
        $exitCode = 1  # changes detected

        # JSON diff
        $diffJsonPath = Join-Path $OutputDir ('diff_' + $timestamp + '.json')
        @{
            comparedAt       = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
            previousSnapshot = $allSnapshots[1].Name
            currentSnapshot  = ('snapshot_' + $timestamp + '.json')
            summary          = [ordered]@{
                added   = $totalAdded
                removed = $totalRemoved
                changed = $totalChanged
            }
            categories = $categoryDiffs
        } | ConvertTo-Json -Depth 8 | Set-Content -Path $diffJsonPath -Encoding UTF8

        # Human-readable diff
        $diffTxtPath = Join-Path $OutputDir ('diff_' + $timestamp + '.txt')
        $lines = @()
        $lines += '=== BOOT INVENTORY CHANGES DETECTED ==='
        $lines += ('Time: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        $lines += ('Previous: ' + $allSnapshots[1].Name)
        $lines += ('Added: ' + $totalAdded + '  Removed: ' + $totalRemoved + '  Changed: ' + $totalChanged)
        $lines += ''

        foreach ($catDiff in $categoryDiffs) {
            $lines += ('--- ' + $catDiff.category + ' ---')

            if ($catDiff.added.Count -gt 0) {
                $lines += '  ADDED:'
                foreach ($item in $catDiff.added) {
                    $keyField = 'name'
                    if ($catDiff.category -eq 'Tasks') { $keyField = 'path' }
                    $displayName = $item.$keyField
                    if ($item.displayName) {
                        $displayName = $displayName + ' (' + $item.displayName + ')'
                    }
                    $lines += ('    + ' + $displayName)
                    if ($item.pathName) { $lines += ('      path: ' + $item.pathName) }
                    if ($item.startMode) { $lines += ('      startMode: ' + $item.startMode) }
                    if ($item.version) { $lines += ('      version: ' + $item.version) }
                    if ($item.actions) { $lines += ('      actions: ' + $item.actions) }
                }
            }

            if ($catDiff.removed.Count -gt 0) {
                $lines += '  REMOVED:'
                foreach ($item in $catDiff.removed) {
                    $keyField = 'name'
                    if ($catDiff.category -eq 'Tasks') { $keyField = 'path' }
                    $displayName = $item.$keyField
                    if ($item.displayName) {
                        $displayName = $displayName + ' (' + $item.displayName + ')'
                    }
                    $lines += ('    - ' + $displayName)
                }
            }

            if ($catDiff.changed.Count -gt 0) {
                $lines += '  CHANGED:'
                foreach ($item in $catDiff.changed) {
                    $lines += ('    ~ ' + $item.key)
                    foreach ($c in $item.changes) {
                        $lines += ('        ' + $c.field + ': ' + $c.previous + ' -> ' + $c.current)
                    }
                }
            }
            $lines += ''
        }

        $lines | Set-Content -Path $diffTxtPath -Encoding UTF8

        # Console output
        Write-Host ('!!! BOOT INVENTORY CHANGES: +' + $totalAdded + ' -' + $totalRemoved + ' ~' + $totalChanged + ' !!!') -ForegroundColor Red
        Write-Host ''
        foreach ($catDiff in $categoryDiffs) {
            Write-Host ('  ' + $catDiff.category + ':') -ForegroundColor Yellow

            foreach ($item in $catDiff.added) {
                $keyField = 'name'
                if ($catDiff.category -eq 'Tasks') { $keyField = 'path' }
                Write-Host ('    + ' + $item.$keyField) -ForegroundColor Green
            }
            foreach ($item in $catDiff.removed) {
                $keyField = 'name'
                if ($catDiff.category -eq 'Tasks') { $keyField = 'path' }
                Write-Host ('    - ' + $item.$keyField) -ForegroundColor Red
            }
            foreach ($item in $catDiff.changed) {
                Write-Host ('    ~ ' + $item.key) -ForegroundColor DarkYellow
                foreach ($c in $item.changes) {
                    Write-Host ('        ' + $c.field + ': ') -NoNewline -ForegroundColor DarkGray
                    Write-Host ($c.previous) -NoNewline -ForegroundColor DarkGray
                    Write-Host ' -> ' -NoNewline
                    Write-Host ($c.current) -ForegroundColor White
                }
            }
        }
        Write-Host ''
        Write-Host ('Diff: ' + $diffTxtPath) -ForegroundColor Cyan

        # Optional desktop alert file
        if ($AlertFile -ne '') {
            $lines | Set-Content -Path $AlertFile -Encoding UTF8
            Write-Host ('Alert: ' + $AlertFile) -ForegroundColor Cyan
        }
    } else {
        $exitCode = 0
        Write-Host 'Boot inventory watchdog: no changes since last boot.' -ForegroundColor Green
    }
} else {
    Write-Host 'Boot inventory watchdog: first run - baseline inventory saved.' -ForegroundColor Yellow
    Write-Host ('  Tip: Run again after next reboot to see diffs.') -ForegroundColor DarkGray
}

Write-Host ('Snapshot: ' + $snapshotPath) -ForegroundColor Cyan
exit $exitCode
