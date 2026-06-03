#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Driver health audit checks.
.DESCRIPTION
    Checks AMD chipset package, NVMe vendor drivers, event log driver errors,
    and scheduled task hygiene. Restored from commit 10d3481 after refactor 9eabc64
    dropped them during audit-checks.ps1 split.
#>

function Invoke-DriverHealthChecks {
    $results = @()

    # --- Check A: AMD Chipset Package ---
    $amdPpmPath = Join-Path $env:SystemRoot 'System32\drivers\amdppm.sys'
    $amdPpmExists = Test-Path $amdPpmPath

    $errorDevCount = 0
    try {
        $errorDevs = @(Get-WmiObject Win32_PnPEntity -ErrorAction SilentlyContinue |
            Where-Object { $_.ConfigManagerErrorCode -eq 28 })
        $errorDevCount = $errorDevs.Count
    } catch { }

    if ($amdPpmExists -and $errorDevCount -eq 0) {
        $results += New-CheckResult -Name 'AMD Chipset Package' -Category 'Drivers' -Tier 'Quick' -Severity 'CRITICAL' `
            -Status 'PASS' -Current 'Installed (amdppm.sys present, 0 Code-28 devices)' -Expected 'Installed' `
            -Message 'AMD Chipset Software present. PPM, GPIO, I2C, SFH, CCP/PSP all functional.'
    } else {
        $amdPpmYesNo = 'No'
        if ($amdPpmExists) { $amdPpmYesNo = 'Yes' }
        $currentStr = 'amdppm.sys=' + $amdPpmYesNo + ', Code-28 devices=' + $errorDevCount
        $results += New-CheckResult -Name 'AMD Chipset Package' -Category 'Drivers' -Tier 'Quick' -Severity 'CRITICAL' `
            -Status 'FAIL' -Current $currentStr -Expected 'Installed, 0 Code-28 devices' `
            -Message ('AMD Chipset Software missing. ' + $errorDevCount + ' devices without drivers (GPIO, I2C, SFH, CCP/PSP). P-state management uses generic cpu.inf.') `
            -Fix '.\fix_chipset_drivers.ps1 -OpenDownload' `
            -FixNote 'Download AMD Chipset Software and install. Reboot required.'
    }

    # --- Check B: NVMe Vendor Drivers ---
    $nvmeGeneric = 0
    $nvmeTotal = 0
    try {
        $nvmeDisks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.BusType -eq 'NVMe' })
        $nvmeTotal = $nvmeDisks.Count
        $nvmePnp = @(Get-WmiObject Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
            Where-Object { $_.Description -and $_.Description -like '*NVMe*' -and $_.DriverProviderName -eq 'Microsoft' })
        $nvmeGeneric = $nvmePnp.Count
    } catch { }

    if ($nvmeTotal -eq 0) {
        $results += New-CheckResult -Name 'NVMe Vendor Drivers' -Category 'Drivers' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'No NVMe drives' -Expected 'Vendor driver'
    } elseif ($nvmeGeneric -eq 0) {
        $results += New-CheckResult -Name 'NVMe Vendor Drivers' -Category 'Drivers' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'PASS' -Current ('All ' + $nvmeTotal + ' NVMe drive(s) use vendor drivers') -Expected 'Vendor driver'
    } else {
        $results += New-CheckResult -Name 'NVMe Vendor Drivers' -Category 'Drivers' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ([string]$nvmeGeneric + '/' + [string]$nvmeTotal + ' NVMe drive(s) use generic Microsoft driver') -Expected 'Vendor driver' `
            -Message 'Generic stornvme.sys lacks vendor APST tuning and optimized queue depth. Samsung and WD provide native NVMe drivers.' `
            -Fix '.\audit-drivers.ps1 -Html' `
            -FixNote 'Check audit report for specific drive recommendations.'
    }

    # --- Check C: Event Viewer Driver Errors (7 days) ---
    $driverErrors = 0
    try {
        $startDate = (Get-Date).AddDays(-7)
        $scmErrs = @(Get-WinEvent -FilterHashtable @{
            LogName      = 'System'
            ProviderName = 'Service Control Manager'
            Level        = @(1,2)
            StartTime    = $startDate
        } -MaxEvents 200 -ErrorAction SilentlyContinue)
        $driverErrors = $scmErrs.Count
    } catch { }

    if ($driverErrors -eq 0) {
        $results += New-CheckResult -Name 'Event Log Driver Errors' -Category 'Drivers' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'PASS' -Current '0 driver errors (7d)' -Expected '0'
    } elseif ($driverErrors -le 5) {
        $results += New-CheckResult -Name 'Event Log Driver Errors' -Category 'Drivers' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ([string]$driverErrors + ' driver errors (7d)') -Expected '0' `
            -Message 'Minor driver/service errors in event log. Run audit-drivers.ps1 for details.'
    } else {
        $results += New-CheckResult -Name 'Event Log Driver Errors' -Category 'Drivers' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'FAIL' -Current ([string]$driverErrors + ' driver errors (7d)') -Expected '0' `
            -Message 'Significant driver/service errors in event log.' `
            -Fix '.\audit-drivers.ps1 -Html' `
            -FixNote 'Run driver audit for full breakdown.'
    }

    # --- Check D: Scheduled Task Hygiene ---
    $hourlyEnabled = 0
    try {
        $allTasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Disabled' }
        foreach ($task in $allTasks) {
            foreach ($trig in $task.Triggers) {
                $rep = $trig.Repetition
                if ($rep -and $rep.Interval) {
                    $interval = $rep.Interval
                    if ($interval -match '^PT(\d+)M$' -and [int]$Matches[1] -le 60) {
                        $hourlyEnabled++
                        break
                    } elseif ($interval -eq 'PT1H') {
                        $hourlyEnabled++
                        break
                    }
                }
            }
        }
    } catch { }

    if ($hourlyEnabled -eq 0) {
        $results += New-CheckResult -Name 'Scheduled Task Hygiene' -Category 'Drivers' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'No hourly tasks enabled' -Expected '0 hourly tasks' `
            -Message 'No high-frequency scheduled tasks that could interrupt gaming.'
    } else {
        $results += New-CheckResult -Name 'Scheduled Task Hygiene' -Category 'Drivers' -Tier 'Quick' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ([string]$hourlyEnabled + ' hourly task(s) enabled') -Expected '0 hourly tasks' `
            -Message 'Tasks with hourly or more frequent intervals can cause CPU/disk spikes during gaming.' `
            -Fix '.\fix_scheduled_tasks.ps1' `
            -FixNote 'Disable non-essential hourly tasks. Rollback: -Restore flag.'
    }

    return $results
}
