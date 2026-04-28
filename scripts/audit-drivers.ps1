#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Comprehensive driver health audit: device errors, chipset, NVMe, GPU, NIC, event log.
.DESCRIPTION
    Scans for devices with error codes, checks AMD chipset package presence,
    audits NVMe vendor drivers vs generic, checks critical driver versions,
    and summarizes driver-related event viewer errors.
.PARAMETER Html
    Generate HTML report in captures/.
.PARAMETER FixLuafv
    Disable the luafv (UAC Virtualization Filter) service to stop boot errors.
.PARAMETER EventDays
    Number of days to scan in event viewer (default: 7).
.NOTES
    Reboot: NO (unless -FixLuafv applied, then recommended)
    Non-destructive audit unless -FixLuafv specified
#>

param(
    [switch]$Html,
    [switch]$FixLuafv,
    [int]$EventDays = 7
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$captureDir  = Join-Path $projectRoot 'captures'
$timestamp   = Get-Date -Format 'yyyyMMdd_HHmmss'

Write-Host '=== Driver Health Audit ===' -ForegroundColor Cyan
Write-Host ''

$results = @{
    timestamp       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    deviceErrors    = @()
    chipsetStatus   = @{}
    storageDrivers  = @()
    criticalDrivers = @()
    eventSummary    = @()
    luafvStatus     = @{}
    overallScore    = 'UNKNOWN'
}
$criticalCount = 0
$warnCount     = 0

# ─── Phase 1: Device Error Scan ──────────────────────────────────────────────
Write-Host 'Phase 1: Scanning for device errors...' -ForegroundColor Yellow

$errorDevices = Get-WmiObject Win32_PnPEntity -ErrorAction SilentlyContinue |
    Where-Object { $_.ConfigManagerErrorCode -ne 0 }

$errorCodeMap = @{
    1  = 'Not configured'
    3  = 'Driver corrupt'
    10 = 'Cannot start'
    12 = 'Resource conflict'
    22 = 'Disabled'
    28 = 'No driver installed'
    31 = 'Not working properly'
    43 = 'Stopped by Windows'
}

# Known intentionally disabled devices — skip
$knownDisabled = @('AURA LED Controller', 'ASUS System Product Name')

foreach ($dev in $errorDevices) {
    $code = $dev.ConfigManagerErrorCode
    $codeName = $errorCodeMap[[int]$code]
    if (-not $codeName) { $codeName = 'Error ' + $code }

    $skip = $false
    foreach ($kd in $knownDisabled) {
        if ($dev.Name -and $dev.Name.Contains($kd)) { $skip = $true; break }
    }

    $severity = 'WARN'
    if ($code -eq 28) { $severity = 'CRITICAL'; if (-not $skip) { $criticalCount++ } }
    elseif ($code -eq 22 -and $skip) { $severity = 'INFO' }
    elseif ($code -eq 22) { $severity = 'INFO' }
    elseif ($code -eq 10 -or $code -eq 43) { $severity = 'CRITICAL'; if (-not $skip) { $criticalCount++ } }

    $entry = @{
        Name      = if ($dev.Name) { $dev.Name } else { '(Unknown)' }
        DeviceID  = if ($dev.DeviceID) { $dev.DeviceID } else { '' }
        ErrorCode = [int]$code
        ErrorName = $codeName
        Severity  = $severity
        Skipped   = $skip
    }
    $results.deviceErrors += $entry

    $color = 'Yellow'
    if ($severity -eq 'CRITICAL' -and -not $skip) { $color = 'Red' }
    elseif ($skip) { $color = 'DarkGray' }
    elseif ($severity -eq 'INFO') { $color = 'Gray' }

    $prefix = '  '
    if ($skip) { $prefix = '  [SKIP] ' }
    Write-Host ($prefix + '[Code ' + $code + ' - ' + $codeName + '] ' + $entry.Name) -ForegroundColor $color
    if ($severity -eq 'CRITICAL' -and -not $skip) {
        Write-Host ('           ' + $entry.DeviceID) -ForegroundColor DarkGray
    }
}

if ($results.deviceErrors.Count -eq 0) {
    Write-Host '  No device errors found.' -ForegroundColor Green
}
Write-Host ''

# ─── Phase 2: AMD Chipset Package Detection ──────────────────────────────────
Write-Host 'Phase 2: Checking AMD chipset package...' -ForegroundColor Yellow

$chipsetInstalled = $false
$amdPpmLoaded = $false

# Check for amdppm.sys driver file
$amdPpmPath = Join-Path $env:SystemRoot 'System32\drivers\amdppm.sys'
if (Test-Path $amdPpmPath) {
    $amdPpmLoaded = $true
    $chipsetInstalled = $true
}

# Check install directory
$chipsetDir = 'C:\Program Files\AMD\Chipset_Software'
$chipsetDirExists = Test-Path $chipsetDir

# Check registry for AMD Chipset Software
$chipsetRegFound = $false
$uninstallPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
foreach ($regPath in $uninstallPaths) {
    $found = Get-ItemProperty $regPath -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and $_.DisplayName -like '*AMD Chipset*' }
    if ($found) { $chipsetRegFound = $true; break }
}

if (-not $chipsetRegFound) { $chipsetInstalled = $false }

# Check AMD processor driver
$procDriver = Get-WmiObject Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
    Where-Object { $_.DeviceClass -eq 'Processor' } |
    Select-Object -First 1
$procInf = ''
if ($procDriver) { $procInf = $procDriver.InfName }

$results.chipsetStatus = @{
    ChipsetInstalled = $chipsetInstalled
    AmdPpmLoaded     = $amdPpmLoaded
    ChipsetDirExists = $chipsetDirExists
    ChipsetRegFound  = $chipsetRegFound
    ProcessorInf     = $procInf
}

if ($chipsetInstalled -and $amdPpmLoaded) {
    Write-Host '  AMD Chipset Software: INSTALLED' -ForegroundColor Green
    Write-Host ('  Processor driver: ' + $procInf) -ForegroundColor Green
} else {
    $criticalCount++
    Write-Host '  AMD Chipset Software: NOT INSTALLED' -ForegroundColor Red
    Write-Host '  Processor driver: Microsoft generic (cpu.inf)' -ForegroundColor Red
    Write-Host '  Impact: No AMD PPM, GPIO, I2C, SFH, CCP/PSP drivers' -ForegroundColor Yellow
    Write-Host '  Fix: Install AMD Chipset Software from:' -ForegroundColor Yellow
    Write-Host '       https://www.amd.com/en/support/download/drivers.html' -ForegroundColor White
}
Write-Host ''

# ─── Phase 3: Storage Driver Audit ───────────────────────────────────────────
Write-Host 'Phase 3: Auditing storage drivers...' -ForegroundColor Yellow

$disks = Get-PhysicalDisk -ErrorAction SilentlyContinue
foreach ($disk in $disks) {
    $model = $disk.FriendlyName
    $mediaType = $disk.MediaType
    $busType = $disk.BusType

    # Find matching PNP device for driver info
    $driverInf = 'Unknown'
    $driverName = 'Unknown'
    $isGeneric = $false

    # Match via disk number to partition/volume to PNP
    $diskNum = $disk.DeviceId
    $nvmePnp = Get-WmiObject Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DeviceClass -eq 'DiskDrive' -or
            $_.DeviceClass -eq 'SCSIAdapter' -or
            ($_.Description -and $_.Description -like '*NVMe*')
        }

    # Try to match by model in PNP description
    foreach ($pnp in $nvmePnp) {
        if ($pnp.Description -and $model -and $pnp.Description.Contains('NVMe')) {
            $driverInf = if ($pnp.InfName) { $pnp.InfName } else { 'Unknown' }
            $driverName = if ($pnp.DriverProviderName) { $pnp.DriverProviderName } else { 'Unknown' }
            break
        }
    }

    # Check if using generic stornvme
    if ($driverInf -eq 'stornvme.inf' -or $driverName -eq 'Microsoft') {
        $isGeneric = $true
    }

    $recommendation = ''
    if ($isGeneric -and $busType -eq 'NVMe') {
        if ($model -like '*Samsung*' -or $model -like '*990*' -or $model -like '*9100*' -or $model -like '*980*' -or $model -like '*970*') {
            $recommendation = 'Install Samsung NVMe Driver (APST tuning, better queue depth)'
            $warnCount++
        } elseif ($model -like '*WD*' -or $model -like '*SanDisk*' -or $model -like '*SN850*' -or $model -like '*SN770*') {
            $recommendation = 'WD Dashboard driver available (low priority — minimal benefit)'
        }
    }

    $entry = @{
        Model          = $model
        MediaType      = $mediaType.ToString()
        BusType        = $busType.ToString()
        DriverInf      = $driverInf
        DriverProvider = $driverName
        IsGeneric      = $isGeneric
        Recommendation = $recommendation
    }
    $results.storageDrivers += $entry

    $color = if ($isGeneric -and $recommendation) { 'Yellow' } else { 'Green' }
    Write-Host ('  ' + $model + ' (' + $busType + ')') -ForegroundColor $color
    Write-Host ('    Driver: ' + $driverInf + ' (' + $driverName + ')') -ForegroundColor $(if ($isGeneric) { 'Yellow' } else { 'Green' })
    if ($recommendation) {
        Write-Host ('    Recommend: ' + $recommendation) -ForegroundColor Yellow
    }
}
Write-Host ''

# ─── Phase 4: Critical Driver Version Check ──────────────────────────────────
Write-Host 'Phase 4: Checking critical driver versions...' -ForegroundColor Yellow

$signedDrivers = Get-WmiObject Win32_PnPSignedDriver -ErrorAction SilentlyContinue

# GPU
$gpuDriver = $signedDrivers | Where-Object { $_.DeviceClass -eq 'Display' -and $_.DriverProviderName -like '*NVIDIA*' } | Select-Object -First 1
if ($gpuDriver) {
    $gpuVer = $gpuDriver.DriverVersion
    $gpuDate = $gpuDriver.DriverDate
    # Parse WMI date (yyyymmdd000000.000000+000)
    $gpuDateStr = ''
    if ($gpuDate -and $gpuDate.Length -ge 8) {
        $gpuDateStr = $gpuDate.Substring(0,4) + '-' + $gpuDate.Substring(4,2) + '-' + $gpuDate.Substring(6,2)
    }
    $results.criticalDrivers += @{ Component = 'GPU (NVIDIA)'; Version = $gpuVer; Date = $gpuDateStr; Status = 'OK' }
    Write-Host ('  GPU: NVIDIA ' + $gpuVer + ' (' + $gpuDateStr + ')') -ForegroundColor Green
} else {
    $results.criticalDrivers += @{ Component = 'GPU'; Version = 'Not found'; Date = ''; Status = 'WARN' }
    Write-Host '  GPU: NVIDIA driver not detected' -ForegroundColor Yellow
}

# NIC
$nicDriver = $signedDrivers | Where-Object { $_.DeviceClass -eq 'Net' -and $_.Description -like '*I226*' } | Select-Object -First 1
if ($nicDriver) {
    $results.criticalDrivers += @{ Component = 'NIC (I226-V)'; Version = $nicDriver.DriverVersion; Date = ''; Status = 'OK' }
    Write-Host ('  NIC: Intel I226-V ' + $nicDriver.DriverVersion) -ForegroundColor Green
} else {
    $nicDriver2 = $signedDrivers | Where-Object { $_.DeviceClass -eq 'Net' -and $_.Description -like '*Ethernet*' } | Select-Object -First 1
    if ($nicDriver2) {
        $results.criticalDrivers += @{ Component = 'NIC'; Version = $nicDriver2.DriverVersion; Date = ''; Status = 'OK' }
        Write-Host ('  NIC: ' + $nicDriver2.Description + ' ' + $nicDriver2.DriverVersion) -ForegroundColor Green
    }
}

# Audio
$audioDriver = $signedDrivers | Where-Object { $_.DeviceClass -eq 'AudioEndpoint' -or ($_.DeviceClass -eq 'MEDIA' -and $_.Description -like '*Realtek*') } | Select-Object -First 1
if ($audioDriver) {
    $results.criticalDrivers += @{ Component = 'Audio'; Version = $audioDriver.DriverVersion; Date = ''; Status = 'OK' }
    Write-Host ('  Audio: ' + $audioDriver.Description + ' ' + $audioDriver.DriverVersion) -ForegroundColor Green
}

# USB (AMD xHCI)
$usbDriver = $signedDrivers | Where-Object { $_.Description -like '*USB*xHCI*' -or $_.Description -like '*AMD USB*' } | Select-Object -First 1
if ($usbDriver) {
    $results.criticalDrivers += @{ Component = 'USB (xHCI)'; Version = $usbDriver.DriverVersion; Date = ''; Status = 'OK' }
    Write-Host ('  USB: ' + $usbDriver.Description + ' ' + $usbDriver.DriverVersion) -ForegroundColor Green
}
Write-Host ''

# ─── Phase 5: Event Viewer Driver Errors ──────────────────────────────────────
Write-Host ('Phase 5: Scanning event viewer (' + $EventDays + ' days)...') -ForegroundColor Yellow

$startDate = (Get-Date).AddDays(-$EventDays)

# Service Control Manager — driver/service load failures
$scmEvents = @()
try {
    $scmEvents = @(Get-WinEvent -FilterHashtable @{
        LogName   = 'System'
        ProviderName = 'Service Control Manager'
        Level     = @(1,2,3)  # Critical, Error, Warning
        StartTime = $startDate
    } -MaxEvents 100 -ErrorAction SilentlyContinue)
} catch { }

# Kernel driver not loaded (Event 219)
$kernelEvents = @()
try {
    $kernelEvents = @(Get-WinEvent -FilterHashtable @{
        LogName   = 'System'
        Id        = 219
        StartTime = $startDate
    } -MaxEvents 50 -ErrorAction SilentlyContinue)
} catch { }

# WHEA hardware errors
$wheaEvents = @()
try {
    $wheaEvents = @(Get-WinEvent -FilterHashtable @{
        LogName   = 'System'
        ProviderName = 'Microsoft-Windows-WHEA-Logger'
        StartTime = $startDate
    } -MaxEvents 50 -ErrorAction SilentlyContinue)
} catch { }

# Summarize by source
$eventGroups = @{}
foreach ($evt in ($scmEvents + $kernelEvents + $wheaEvents)) {
    $key = $evt.ProviderName + ' (ID ' + $evt.Id + ')'
    if (-not $eventGroups.ContainsKey($key)) {
        $eventGroups[$key] = @{ Count = 0; Level = $evt.LevelDisplayName; Sample = '' }
    }
    $eventGroups[$key].Count++
    if (-not $eventGroups[$key].Sample -and $evt.Message) {
        $msg = $evt.Message
        if ($msg.Length -gt 120) { $msg = $msg.Substring(0,120) + '...' }
        $eventGroups[$key].Sample = $msg
    }
}

foreach ($key in $eventGroups.Keys) {
    $g = $eventGroups[$key]
    $results.eventSummary += @{ Source = $key; Count = $g.Count; Level = $g.Level; Sample = $g.Sample }

    $color = 'Yellow'
    if ($g.Level -eq 'Error' -or $g.Level -eq 'Critical') { $color = 'Red' }
    Write-Host ('  ' + $key + ': ' + $g.Count + 'x') -ForegroundColor $color
    if ($g.Sample) {
        Write-Host ('    ' + $g.Sample) -ForegroundColor DarkGray
    }
}

if ($wheaEvents.Count -gt 0) {
    $criticalCount++
    Write-Host '  WHEA hardware errors detected!' -ForegroundColor Red
} elseif ($eventGroups.Count -eq 0) {
    Write-Host '  No driver-related errors in event log.' -ForegroundColor Green
}
Write-Host ''

# ─── luafv Fix ────────────────────────────────────────────────────────────────
$luafvSvc = Get-Service 'luafv' -ErrorAction SilentlyContinue
$luafvStart = $null
try {
    $luafvStart = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\luafv' -ErrorAction SilentlyContinue).Start
} catch { }

$results.luafvStatus = @{
    ServiceExists = ($null -ne $luafvSvc)
    StartType     = $luafvStart
    Status        = if ($luafvSvc) { $luafvSvc.Status.ToString() } else { 'N/A' }
}

if ($FixLuafv) {
    Write-Host 'Fixing luafv service...' -ForegroundColor Yellow
    if ($luafvStart -ne 4) {
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\luafv' -Name 'Start' -Value 4 -Type DWord
        Write-Host '  luafv disabled (Start=4). Reboot recommended.' -ForegroundColor Green
        $results.luafvStatus.Fixed = $true
    } else {
        Write-Host '  luafv already disabled.' -ForegroundColor Green
        $results.luafvStatus.Fixed = $false
    }
    Write-Host ''
}

# ─── Overall Score ────────────────────────────────────────────────────────────
if ($criticalCount -gt 0) {
    $results.overallScore = 'CRITICAL'
} elseif ($warnCount -gt 0) {
    $results.overallScore = 'WARN'
} else {
    $results.overallScore = 'PASS'
}

Write-Host '════════════════════════════════════════════' -ForegroundColor Cyan
$scoreColor = switch ($results.overallScore) {
    'CRITICAL' { 'Red' }
    'WARN'     { 'Yellow' }
    'PASS'     { 'Green' }
    default    { 'White' }
}
Write-Host ('Overall: ' + $results.overallScore + ' (' + $criticalCount + ' critical, ' + $warnCount + ' warnings)') -ForegroundColor $scoreColor
Write-Host '════════════════════════════════════════════' -ForegroundColor Cyan

# ─── Save JSON ────────────────────────────────────────────────────────────────
if (-not (Test-Path $captureDir)) {
    New-Item -Path $captureDir -ItemType Directory -Force | Out-Null
}
$jsonPath = Join-Path $captureDir ('driver_audit_' + $timestamp + '.json')
$results | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding UTF8
Write-Host ''
Write-Host ('JSON: ' + $jsonPath) -ForegroundColor Green

# ─── HTML Report ──────────────────────────────────────────────────────────────
if ($Html) {
    $htmlPath = Join-Path $captureDir ('driver_audit_' + $timestamp + '.html')

    $htmlContent = @'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Driver Health Audit</title>
<style>
body{font-family:Consolas,monospace;background:#0d1117;color:#c9d1d9;padding:20px;max-width:1200px;margin:0 auto}
h1{color:#58a6ff;border-bottom:1px solid #30363d;padding-bottom:10px}
h2{color:#79c0ff;margin-top:30px}
table{border-collapse:collapse;width:100%;margin:10px 0}
th,td{border:1px solid #30363d;padding:8px 12px;text-align:left}
th{background:#161b22;color:#58a6ff}
.critical{color:#f85149;font-weight:bold}
.warn{color:#d29922}
.ok{color:#3fb950}
.info{color:#8b949e}
.skip{color:#484f58}
.score-box{padding:15px;border-radius:8px;font-size:1.2em;font-weight:bold;text-align:center;margin:20px 0}
.score-critical{background:#3d1113;border:2px solid #f85149;color:#f85149}
.score-warn{background:#3d2e00;border:2px solid #d29922;color:#d29922}
.score-pass{background:#0d2712;border:2px solid #3fb950;color:#3fb950}
</style></head><body>
'@

    $htmlContent += '<h1>Driver Health Audit</h1>'
    $htmlContent += '<p>Generated: ' + $results.timestamp + '</p>'

    $scoreClass = switch ($results.overallScore) {
        'CRITICAL' { 'score-critical' }
        'WARN'     { 'score-warn' }
        'PASS'     { 'score-pass' }
        default    { '' }
    }
    $htmlContent += '<div class="score-box ' + $scoreClass + '">' + $results.overallScore + ' (' + $criticalCount + ' critical, ' + $warnCount + ' warnings)</div>'

    # Device Errors
    $htmlContent += '<h2>Device Errors</h2>'
    if ($results.deviceErrors.Count -eq 0) {
        $htmlContent += '<p class="ok">No device errors found.</p>'
    } else {
        $htmlContent += '<table><tr><th>Device</th><th>Error</th><th>Device ID</th><th>Severity</th></tr>'
        foreach ($de in $results.deviceErrors) {
            $cls = switch ($de.Severity) { 'CRITICAL' { 'critical' }; 'WARN' { 'warn' }; 'INFO' { 'info' }; default { '' } }
            if ($de.Skipped) { $cls = 'skip' }
            $htmlContent += '<tr class="' + $cls + '"><td>' + $de.Name + '</td><td>Code ' + $de.ErrorCode + ' - ' + $de.ErrorName + '</td><td style="font-size:0.85em">' + $de.DeviceID + '</td><td>' + $de.Severity + '</td></tr>'
        }
        $htmlContent += '</table>'
    }

    # Chipset
    $htmlContent += '<h2>AMD Chipset Package</h2>'
    if ($results.chipsetStatus.ChipsetInstalled) {
        $htmlContent += '<p class="ok">AMD Chipset Software installed. Processor driver: ' + $results.chipsetStatus.ProcessorInf + '</p>'
    } else {
        $htmlContent += '<p class="critical">AMD Chipset Software NOT INSTALLED</p>'
        $htmlContent += '<p>Download: <a href="https://www.amd.com/en/support/download/drivers.html" style="color:#58a6ff">AMD Driver Support</a></p>'
    }

    # Storage
    $htmlContent += '<h2>Storage Drivers</h2>'
    $htmlContent += '<table><tr><th>Model</th><th>Bus</th><th>Driver</th><th>Provider</th><th>Note</th></tr>'
    foreach ($sd in $results.storageDrivers) {
        $cls = if ($sd.IsGeneric -and $sd.Recommendation) { 'warn' } else { 'ok' }
        $htmlContent += '<tr class="' + $cls + '"><td>' + $sd.Model + '</td><td>' + $sd.BusType + '</td><td>' + $sd.DriverInf + '</td><td>' + $sd.DriverProvider + '</td><td>' + $sd.Recommendation + '</td></tr>'
    }
    $htmlContent += '</table>'

    # Critical Drivers
    $htmlContent += '<h2>Critical Driver Versions</h2>'
    $htmlContent += '<table><tr><th>Component</th><th>Version</th><th>Date</th><th>Status</th></tr>'
    foreach ($cd in $results.criticalDrivers) {
        $cls = switch ($cd.Status) { 'OK' { 'ok' }; 'WARN' { 'warn' }; default { 'info' } }
        $htmlContent += '<tr class="' + $cls + '"><td>' + $cd.Component + '</td><td>' + $cd.Version + '</td><td>' + $cd.Date + '</td><td>' + $cd.Status + '</td></tr>'
    }
    $htmlContent += '</table>'

    # Event Summary
    $htmlContent += '<h2>Event Viewer (' + $EventDays + ' days)</h2>'
    if ($results.eventSummary.Count -eq 0) {
        $htmlContent += '<p class="ok">No driver-related errors.</p>'
    } else {
        $htmlContent += '<table><tr><th>Source</th><th>Count</th><th>Level</th><th>Sample</th></tr>'
        foreach ($es in $results.eventSummary) {
            $cls = if ($es.Level -eq 'Error' -or $es.Level -eq 'Critical') { 'critical' } else { 'warn' }
            $htmlContent += '<tr class="' + $cls + '"><td>' + $es.Source + '</td><td>' + $es.Count + '</td><td>' + $es.Level + '</td><td style="font-size:0.85em">' + $es.Sample + '</td></tr>'
        }
        $htmlContent += '</table>'
    }

    $htmlContent += '</body></html>'
    $htmlContent | Out-File -FilePath $htmlPath -Encoding UTF8
    Write-Host ('HTML: ' + $htmlPath) -ForegroundColor Green
    Start-Process $htmlPath
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Cyan
