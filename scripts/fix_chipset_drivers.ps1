#Requires -RunAsAdministrator
<#
.SYNOPSIS
    AMD Chipset Driver remediation guide — detect missing devices, guide install, verify.
.DESCRIPTION
    Detects which AMD chipset devices are missing (Error Code 28), checks if AMD
    Chipset Software is installed, provides download link, and after install
    verifies all devices have proper drivers.
.PARAMETER Verify
    Skip the guide and just verify current driver state.
.PARAMETER OpenDownload
    Open AMD download page in browser.
.NOTES
    Reboot: YES (after chipset install)
    This script does NOT auto-install — chipset packages require interactive setup.
#>

param(
    [switch]$Verify,
    [switch]$OpenDownload
)

$ErrorActionPreference = 'Stop'

Write-Host '=== AMD Chipset Driver Remediation ===' -ForegroundColor Cyan
Write-Host ''

# Known AMD chipset device IDs that should have drivers
$expectedDevices = @(
    @{ Pattern = 'AMDI_F031'; Description = 'AMD I2C Controller'; Purpose = 'USB/sensor communication' }
    @{ Pattern = 'AMDI_0101'; Description = 'AMD I3C Controller'; Purpose = 'Low-power device bus' }
    @{ Pattern = 'AMDI_0204'; Description = 'AMD Sensor Fusion Hub'; Purpose = 'Power management sensors' }
    @{ Pattern = 'AMDI_0052'; Description = 'AMD GPIO Controller'; Purpose = 'Pin control / interrupt routing' }
    @{ Pattern = 'DEV_1649';  Description = 'AMD CCP/PSP (Crypto Co-Processor)'; Purpose = 'fTPM, hardware RNG, crypto acceleration' }
    @{ Pattern = 'DEV_14DE';  Description = 'AMD Sensor Fusion Hub (PCI)'; Purpose = 'Hardware power state transitions' }
)

# ─── Step 1: Detect Current State ────────────────────────────────────────────
Write-Host 'Step 1: Detecting device state...' -ForegroundColor Yellow

$allPnp = Get-WmiObject Win32_PnPEntity -ErrorAction SilentlyContinue
$missingDevices = @()
$okDevices = @()

foreach ($ed in $expectedDevices) {
    $found = $allPnp | Where-Object {
        $_.DeviceID -and $_.DeviceID.Contains($ed.Pattern)
    }

    if (-not $found) {
        # Device not even enumerated — might not be on this board
        continue
    }

    foreach ($dev in $found) {
        $code = $dev.ConfigManagerErrorCode
        $entry = @{
            Name        = $dev.Name
            DeviceID    = $dev.DeviceID
            Description = $ed.Description
            Purpose     = $ed.Purpose
            ErrorCode   = [int]$code
            HasDriver   = ($code -eq 0)
        }

        if ($code -ne 0) {
            $missingDevices += $entry
        } else {
            $okDevices += $entry
        }
    }
}

Write-Host ''
Write-Host ('  Devices with drivers:    ' + $okDevices.Count) -ForegroundColor Green
Write-Host ('  Devices missing drivers: ' + $missingDevices.Count) -ForegroundColor $(if ($missingDevices.Count -gt 0) { 'Red' } else { 'Green' })
Write-Host ''

if ($missingDevices.Count -gt 0) {
    Write-Host '  Missing driver devices:' -ForegroundColor Red
    foreach ($md in $missingDevices) {
        Write-Host ('    [Code ' + $md.ErrorCode + '] ' + $md.Description) -ForegroundColor Red
        Write-Host ('             ' + $md.Purpose) -ForegroundColor DarkGray
        Write-Host ('             ' + $md.DeviceID) -ForegroundColor DarkGray
    }
    Write-Host ''
}

if ($okDevices.Count -gt 0) {
    Write-Host '  Devices with drivers:' -ForegroundColor Green
    foreach ($od in $okDevices) {
        Write-Host ('    [OK] ' + $od.Description + ' (' + $od.Name + ')') -ForegroundColor Green
    }
    Write-Host ''
}

# ─── Step 2: Check Chipset Software Installation ─────────────────────────────
Write-Host 'Step 2: Checking chipset software...' -ForegroundColor Yellow

$chipsetFound = $false
$chipsetVersion = ''

# Registry check
$uninstallPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
foreach ($regPath in $uninstallPaths) {
    $apps = Get-ItemProperty $regPath -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and $_.DisplayName -like '*AMD Chipset*' }
    if ($apps) {
        $chipsetFound = $true
        $chipsetVersion = $apps[0].DisplayVersion
        break
    }
}

# Driver file check
$amdPpmExists = Test-Path (Join-Path $env:SystemRoot 'System32\drivers\amdppm.sys')

# Processor driver check
$procDriver = Get-WmiObject Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
    Where-Object { $_.DeviceClass -eq 'Processor' } |
    Select-Object -First 1

Write-Host ''
if ($chipsetFound) {
    Write-Host ('  AMD Chipset Software: v' + $chipsetVersion) -ForegroundColor Green
} else {
    Write-Host '  AMD Chipset Software: NOT FOUND' -ForegroundColor Red
}
Write-Host ('  amdppm.sys present:  ' + $(if ($amdPpmExists) { 'Yes' } else { 'No' })) -ForegroundColor $(if ($amdPpmExists) { 'Green' } else { 'Red' })
if ($procDriver) {
    $isGeneric = ($procDriver.InfName -eq 'cpu.inf')
    Write-Host ('  Processor driver:    ' + $procDriver.InfName + ' (' + $(if ($isGeneric) { 'GENERIC' } else { 'AMD' }) + ')') -ForegroundColor $(if ($isGeneric) { 'Red' } else { 'Green' })
}
Write-Host ''

# ─── Verify-only mode ────────────────────────────────────────────────────────
if ($Verify) {
    if ($missingDevices.Count -eq 0 -and $amdPpmExists) {
        Write-Host 'PASS: All AMD chipset devices have drivers.' -ForegroundColor Green
    } else {
        Write-Host 'FAIL: Missing drivers detected.' -ForegroundColor Red
    }
    exit $(if ($missingDevices.Count -eq 0) { 0 } else { 1 })
}

# ─── Step 3: Installation Guide ──────────────────────────────────────────────
if ($missingDevices.Count -eq 0 -and $amdPpmExists) {
    Write-Host 'All AMD chipset devices have drivers. No action needed.' -ForegroundColor Green
    exit 0
}

Write-Host '═══════════════════════════════════════════════════════' -ForegroundColor Yellow
Write-Host '  AMD Chipset Software Installation Guide' -ForegroundColor Yellow
Write-Host '═══════════════════════════════════════════════════════' -ForegroundColor Yellow
Write-Host ''
Write-Host '  1. Download AMD Chipset Software from:' -ForegroundColor White
Write-Host '     https://www.amd.com/en/support/download/drivers.html' -ForegroundColor Cyan
Write-Host ''
Write-Host '  2. Select your processor:' -ForegroundColor White
Write-Host '     Processors > AMD Ryzen Processors > AMD Ryzen 7 Desktop Processors' -ForegroundColor Gray
Write-Host '     > AMD Ryzen 7 9800X3D' -ForegroundColor Gray
Write-Host ''
Write-Host '  3. Download "AMD Chipset Software" (NOT the processor driver alone)' -ForegroundColor White
Write-Host ''
Write-Host '  4. Run the installer as Administrator' -ForegroundColor White
Write-Host '     - Choose "Full Install" to get all chipset components' -ForegroundColor Gray
Write-Host '     - Components installed: AMD PPM, GPIO, I2C, I3C, SFH, PSP/CCP' -ForegroundColor Gray
Write-Host ''
Write-Host '  5. REBOOT when prompted' -ForegroundColor White
Write-Host ''
Write-Host '  6. After reboot, verify:' -ForegroundColor White
Write-Host '     .\fix_chipset_drivers.ps1 -Verify' -ForegroundColor Cyan
Write-Host ''

# ─── Open download page ──────────────────────────────────────────────────────
if ($OpenDownload) {
    Write-Host 'Opening AMD download page...' -ForegroundColor Yellow
    Start-Process 'https://www.amd.com/en/support/download/drivers.html'
} else {
    Write-Host 'Tip: Run with -OpenDownload to open the AMD page in your browser.' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host 'Expected improvements after install:' -ForegroundColor Yellow
Write-Host '  - AMD PPM replaces generic cpu.inf (better P-state management)' -ForegroundColor White
Write-Host '  - GPIO controller enables proper interrupt routing' -ForegroundColor White
Write-Host '  - CCP/PSP provides hardware-accelerated fTPM + crypto' -ForegroundColor White
Write-Host '  - SFH enables hardware power state transitions' -ForegroundColor White
Write-Host '  - I2C/I3C enables sensor communication for thermal management' -ForegroundColor White
Write-Host ''
Write-Host 'Done.' -ForegroundColor Cyan
