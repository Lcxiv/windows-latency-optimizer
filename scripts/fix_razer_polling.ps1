#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Download and launch Razer Synapse installer for polling rate configuration.
.DESCRIPTION
    Detects Razer mouse model via USB PID, downloads Razer Synapse installer,
    launches it, and guides user to set 1000Hz+ polling rate and save to onboard memory.
    After configuration, Synapse can be uninstalled — settings persist in mouse firmware.
.NOTES
    Reboot: NO
    This script downloads from Razer's official CDN only.
#>

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent

Write-Host '=== Razer Mouse Polling Rate Fix ===' -ForegroundColor Cyan
Write-Host ''

# --- Detect Razer mouse ---
Write-Host 'Detecting Razer mouse...' -ForegroundColor Yellow
$razerMouse = $null
$razerPID   = ''

$hidDevices = Get-WmiObject Win32_PnPEntity -Filter "Service='HidUsb' OR Service='mouhid'" -ErrorAction SilentlyContinue
foreach ($dev in $hidDevices) {
    if ($dev.DeviceID -match 'VID_1532&PID_([0-9A-F]+)') {
        $razerPID   = $Matches[1]
        $razerMouse = $dev
        break
    }
}

if ($null -eq $razerMouse) {
    Write-Host 'No Razer mouse detected.' -ForegroundColor Red
    exit 1
}

# Known Razer mouse PIDs (subset — add more as needed)
$knownMice = @{
    '00C1' = 'Viper V3 Pro (Wireless)'
    '00C0' = 'Viper V3 Pro (Wired)'
    '00B6' = 'Viper V3 HyperSpeed'
    '00AA' = 'Basilisk V3 Pro'
    '008A' = 'Viper Ultimate'
    '008B' = 'Viper Ultimate (Wireless)'
    '007A' = 'Viper'
    '0078' = 'DeathAdder V2'
    '0084' = 'DeathAdder V2 Pro'
    '004F' = 'DeathAdder Elite'
    '0043' = 'DeathAdder Chroma'
    '0098' = 'Basilisk V3'
    '006B' = 'Basilisk Ultimate'
    '00A5' = 'Cobra Pro'
    '009C' = 'DeathAdder V3'
    '00B2' = 'DeathAdder V3 Pro'
    '00B5' = 'DeathAdder V3 HyperSpeed'
}

$modelName = 'Unknown Razer Mouse'
if ($knownMice.ContainsKey($razerPID)) {
    $modelName = 'Razer ' + $knownMice[$razerPID]
}
Write-Host ('  Found: ' + $modelName + ' (PID: ' + $razerPID + ')') -ForegroundColor Green
Write-Host ''

# --- Check if Synapse is already installed ---
$synapseInstalled = $false
$synapseApps = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like '*Razer*Synapse*' -or $_.DisplayName -like '*Razer*Central*' }
if (-not $synapseApps) {
    $synapseApps = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*Razer*Synapse*' -or $_.DisplayName -like '*Razer*Central*' }
}
if ($synapseApps) {
    $synapseInstalled = $true
    $appName = ($synapseApps | Select-Object -First 1).DisplayName
    Write-Host ('Synapse already installed: ' + $appName) -ForegroundColor Green
}

# --- Download Synapse if not installed ---
if (-not $synapseInstalled) {
    Write-Host 'Razer Synapse not installed. Downloading installer...' -ForegroundColor Yellow

    $installerUrl  = 'https://rzr.to/synapse-3-pc-download'
    $installerPath = Join-Path $env:TEMP 'RazerSynapseInstaller.exe'

    try {
        # Use BITS for reliable download
        Start-BitsTransfer -Source $installerUrl -Destination $installerPath -ErrorAction Stop
        Write-Host ('  Downloaded to: ' + $installerPath) -ForegroundColor Green
    } catch {
        # Fallback to WebClient
        try {
            $wc = New-Object System.Net.WebClient
            $wc.DownloadFile($installerUrl, $installerPath)
            Write-Host ('  Downloaded to: ' + $installerPath) -ForegroundColor Green
        } catch {
            Write-Host ('  Download failed: ' + $_.Exception.Message) -ForegroundColor Red
            Write-Host '  Please download manually from: https://www.razer.com/synapse-3' -ForegroundColor Yellow
            exit 1
        }
    }

    Write-Host ''
    Write-Host 'Launching Razer Synapse installer...' -ForegroundColor Yellow
    Start-Process -FilePath $installerPath -Wait:$false
    Write-Host 'Installer launched.' -ForegroundColor Green
}

# --- Guide user ---
Write-Host ''
Write-Host '=== Next Steps ===' -ForegroundColor Cyan
Write-Host ''
Write-Host ('  1. Complete the Synapse installation (may require restart)') -ForegroundColor White
Write-Host ('  2. Open Razer Synapse') -ForegroundColor White
Write-Host ('  3. Go to: Devices -> ' + $modelName) -ForegroundColor White
Write-Host ('  4. Set Polling Rate to 1000Hz (or 4000Hz/8000Hz if supported)') -ForegroundColor White
Write-Host ('  5. Click "Save to Onboard Memory" (if available)') -ForegroundColor White
Write-Host ('  6. Settings are saved to the mouse firmware') -ForegroundColor White
Write-Host ''
Write-Host '  After saving to onboard memory, you can uninstall Synapse:' -ForegroundColor Yellow
Write-Host '    Settings -> Apps -> Razer Synapse -> Uninstall' -ForegroundColor Yellow
Write-Host '    The polling rate stays in the mouse hardware.' -ForegroundColor Yellow
Write-Host ''
Write-Host 'Done.' -ForegroundColor Cyan
