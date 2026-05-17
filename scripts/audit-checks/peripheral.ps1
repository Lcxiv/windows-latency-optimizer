#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Peripheral audit checks (Deep Tier).
.DESCRIPTION
    Mouse polling rate, USB controller topology, capture card detection,
    overlay processes.
#>

# ---------------------------------------------------------------------------
# Deep Tier: Peripheral Checks (21-23)
# ---------------------------------------------------------------------------
function Invoke-PeripheralChecks {
    $results = @()

    # --- Check 21: Mouse Polling Rate Risk ---
    # Known Razer PIDs for model detection
    $razerMice = @{
        '00C1' = 'Viper V3 Pro (Wireless)'; '00C0' = 'Viper V3 Pro (Wired)'
        '00B6' = 'Viper V3 HyperSpeed';     '00AA' = 'Basilisk V3 Pro'
        '008A' = 'Viper Ultimate';           '007A' = 'Viper'
        '0078' = 'DeathAdder V2';            '0084' = 'DeathAdder V2 Pro'
        '009C' = 'DeathAdder V3';            '00B2' = 'DeathAdder V3 Pro'
        '0098' = 'Basilisk V3';              '00A5' = 'Cobra Pro'
    }
    $knownMouseVIDs = @('VID_1532', 'VID_046D', 'VID_1038', 'VID_093A', 'VID_258A')
    $mouseFound  = $false
    $mouseDesc   = ''
    $mouseBrand  = ''
    $mouseModel  = ''
    try {
        $hidDevices = Get-WmiObject Win32_PnPEntity -Filter "Service='HidUsb' OR Service='mouhid'" -ErrorAction Stop
        foreach ($dev in $hidDevices) {
            if ($dev.DeviceID -like '*VID_1532*') {
                $mouseFound = $true
                $mouseBrand = 'Razer'
                $mouseDesc  = $dev.Description
                if ($dev.DeviceID -match 'PID_([0-9A-F]+)') {
                    $mousePid = $Matches[1]
                    if ($razerMice.ContainsKey($mousePid)) { $mouseModel = 'Razer ' + $razerMice[$mousePid] }
                    else { $mouseModel = 'Razer Mouse (PID ' + $mousePid + ')' }
                }
                break
            }
            foreach ($vid in $knownMouseVIDs) {
                if ($dev.DeviceID -like ('*' + $vid + '*')) {
                    $mouseFound = $true
                    $mouseDesc  = $dev.Description
                    if ($vid -eq 'VID_046D') { $mouseBrand = 'Logitech' }
                    elseif ($vid -eq 'VID_1038') { $mouseBrand = 'SteelSeries' }
                    else { $mouseBrand = 'Gaming mouse' }
                    break
                }
            }
            if ($mouseFound) { break }
        }
    } catch {}

    if (-not $mouseFound) {
        $results += New-CheckResult -Name 'Mouse Polling Rate' -Category 'Peripheral' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'SKIP' -Current 'No known gaming mouse VID detected' -Expected 'Razer/Logitech/SteelSeries/etc.'
    } else {
        $displayName = $mouseModel
        if ($displayName -eq '') { $displayName = $mouseBrand + ' ' + $mouseDesc }

        # Check if companion software is installed or running
        $companionProcs = @('RazerCentralService','Razer Synapse','LGHUB','SteelSeriesEngine','GHub','iCUE','GHUB')
        $running = $false
        foreach ($proc in $companionProcs) {
            if (Get-Process -Name $proc -ErrorAction SilentlyContinue) { $running = $true; break }
        }

        # Also check if Synapse/GHUB is installed (even if not running — polling saved to firmware)
        $companionInstalled = $false
        $installedApps = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
        $installedApps += Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
        foreach ($app in $installedApps) {
            if ($app.DisplayName -like '*Razer*Synapse*' -or $app.DisplayName -like '*Logitech*G*HUB*' -or $app.DisplayName -like '*SteelSeries*') {
                $companionInstalled = $true
                break
            }
        }

        if ($running -or $companionInstalled) {
            $status = 'configured'
            if ($running) { $status = 'running' }
            $results += New-CheckResult -Name 'Mouse Polling Rate' -Category 'Peripheral' -Tier 'Deep' -Severity 'HIGH' `
                -Status 'PASS' -Current ($displayName + ' — companion software ' + $status) -Expected 'Polling rate configured'
        } else {
            $fixCmd = '.\scripts\fix_razer_polling.ps1'
            $fixNote = 'Downloads Razer Synapse, set polling to 1000Hz+, save to onboard memory, then uninstall Synapse.'
            if ($mouseBrand -eq 'Logitech') {
                $fixCmd = ''
                $fixNote = 'Install Logitech G Hub from https://www.logitechg.com/en-us/innovation/g-hub.html, set 1000Hz, save to onboard.'
            } elseif ($mouseBrand -eq 'SteelSeries') {
                $fixCmd = ''
                $fixNote = 'Install SteelSeries GG from https://steelseries.com/gg, set 1000Hz, save to onboard.'
            }
            $results += New-CheckResult -Name 'Mouse Polling Rate' -Category 'Peripheral' -Tier 'Deep' -Severity 'HIGH' `
                -Status 'WARN' -Current ($displayName + ' — no companion software') -Expected 'Polling rate set to 1000Hz+' `
                -Message ('Without companion software, ' + $mouseBrand + ' mice default to 125Hz (8ms input delay vs 1ms at 1000Hz).') `
                -Fix $fixCmd -FixNote $fixNote
        }
    }

    # --- Check 21b: Mouse USB Controller Topology ---
    if ($mouseFound) {
        $mouseControllerStatus = 'SKIP'
        $mouseControllerCurrent = 'Could not determine USB controller'
        $mouseControllerMsg = ''
        $mouseControllerFix = ''
        $mouseControllerFixNote = ''
        try {
            # Find the mouse's USB device entry and trace its parent controller
            $mouseDevId = ''
            foreach ($dev in $hidDevices) {
                if ($dev.DeviceID -like '*VID_1532*' -or ($mouseBrand -ne '' -and $dev.DeviceID -like ('*' + $dev.DeviceID.Substring(0,17) + '*'))) {
                    $mouseDevId = $dev.DeviceID
                    break
                }
            }

            # Walk up the PnP device tree to find the USB host controller
            $controllerName = ''
            $controllerShared = $false
            $sharedWith = ''
            if ($mouseDevId -ne '') {
                # Get all USB host controllers
                $usbControllers = Get-WmiObject Win32_PnPEntity -ErrorAction SilentlyContinue |
                    Where-Object { $_.DeviceID -like 'PCI\VEN_1022&DEV_15B*' -or $_.DeviceID -like 'PCI\VEN_1022&DEV_43F*' }

                # Check which USB controller tree contains the mouse device
                $usbChildren = Get-WmiObject Win32_PnPEntity -ErrorAction SilentlyContinue |
                    Where-Object { $_.DeviceID -like 'USB\*VID_1532*' }
                if ($usbChildren) {
                    $usbChild = $usbChildren | Select-Object -First 1
                    $usbPath = $usbChild.DeviceID

                    # Determine USB version from controller PCI ID
                    $isUsb3 = $false
                    foreach ($ctrl in $usbControllers) {
                        # Check if device is a descendant by matching root hub pattern
                        if ($ctrl.DeviceID -like '*DEV_15B6*') { $controllerName = 'USB 3.1 xHCI (DEV_15B6)' }
                        elseif ($ctrl.DeviceID -like '*DEV_15B7*') { $controllerName = 'USB 3.1 xHCI (DEV_15B7)' }
                        elseif ($ctrl.DeviceID -like '*DEV_43F7*') { $controllerName = 'USB 3.2 xHCI (DEV_43F7)'; $isUsb3 = $true }
                        elseif ($ctrl.DeviceID -like '*DEV_15B8*') { $controllerName = 'USB 3.1 xHCI (DEV_15B8)' }
                    }

                    # Check if GPU or NIC uses same controller affinity CPUs
                    # Read interrupt affinities from registry to detect sharing
                    $mouseOnCpus = ''
                    $gpuOnCpus = ''
                    $nicOnCpus = ''
                    $usbAffKeys = @('USB_15B6','USB_15B7','USB_43F7','USB_15B8')
                    foreach ($uKey in $usbAffKeys) {
                        $uPat = $uKey.Replace('USB_','VEN_1022&DEV_')
                        $dk = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -ErrorAction SilentlyContinue |
                            Where-Object { $_.PSChildName -like ('*' + $uPat + '*') } | Select-Object -First 1
                        if ($dk) {
                            $affPath = Join-Path $dk.PSPath 'Device Parameters\Interrupt Management\Affinity Policy'
                            if (Test-Path $affPath) {
                                $v = Get-ItemProperty $affPath -ErrorAction SilentlyContinue
                                if ($v.AssignmentSetOverride) {
                                    $mask = '0x' + $v.AssignmentSetOverride[0].ToString('X2')
                                    $mouseOnCpus = $mask
                                }
                            }
                        }
                    }
                    # Get GPU affinity
                    $gpuKey = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -ErrorAction SilentlyContinue |
                        Where-Object { $_.PSChildName -like '*VEN_10DE*' } | Select-Object -First 1
                    if ($gpuKey) {
                        $affPath = Join-Path $gpuKey.PSPath 'Device Parameters\Interrupt Management\Affinity Policy'
                        if (Test-Path $affPath) {
                            $v = Get-ItemProperty $affPath -ErrorAction SilentlyContinue
                            if ($v.AssignmentSetOverride) { $gpuOnCpus = '0x' + $v.AssignmentSetOverride[0].ToString('X2') }
                        }
                    }
                    # Get NIC affinity
                    $nicKey = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -ErrorAction SilentlyContinue |
                        Where-Object { $_.PSChildName -like '*VEN_8086&DEV_125C*' } | Select-Object -First 1
                    if ($nicKey) {
                        $affPath = Join-Path $nicKey.PSPath 'Device Parameters\Interrupt Management\Affinity Policy'
                        if (Test-Path $affPath) {
                            $v = Get-ItemProperty $affPath -ErrorAction SilentlyContinue
                            if ($v.AssignmentSetOverride) { $nicOnCpus = '0x' + $v.AssignmentSetOverride[0].ToString('X2') }
                        }
                    }

                    if ($mouseOnCpus -ne '' -and ($mouseOnCpus -eq $gpuOnCpus -or $mouseOnCpus -eq $nicOnCpus)) {
                        $controllerShared = $true
                        if ($mouseOnCpus -eq $gpuOnCpus) { $sharedWith = 'GPU' }
                        if ($mouseOnCpus -eq $nicOnCpus) {
                            if ($sharedWith -ne '') { $sharedWith = $sharedWith + ' and NIC' }
                            else { $sharedWith = 'NIC' }
                        }
                    }

                    if ($controllerShared) {
                        $mouseControllerStatus = 'WARN'
                        $mouseControllerCurrent = 'Mouse shares interrupt CPUs (' + $mouseOnCpus + ') with ' + $sharedWith
                        $mouseControllerMsg = 'Mouse USB controller shares CPUs with ' + $sharedWith + '. High DPC load from ' + $sharedWith + ' can stall mouse input processing.'
                        $mouseControllerFixNote = 'Move the mouse dongle to a USB port on a different controller, or reassign interrupt affinity so mouse and ' + $sharedWith + ' use separate CPUs.'
                    } else {
                        $mouseControllerStatus = 'PASS'
                        $detail = 'dedicated controller'
                        if ($mouseOnCpus -ne '') { $detail = $detail + ' (CPUs ' + $mouseOnCpus + ')' }
                        $mouseControllerCurrent = $displayName + ' on ' + $detail
                    }
                } else {
                    $mouseControllerCurrent = 'Mouse USB device not found in PnP tree'
                }
            }
        } catch {
            $mouseControllerCurrent = 'Detection failed: ' + $_.Exception.Message
        }

        $results += New-CheckResult -Name 'Mouse USB Controller' -Category 'Peripheral' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status $mouseControllerStatus -Current $mouseControllerCurrent -Expected 'Mouse on dedicated USB controller, not shared with GPU/NIC' `
            -Message $mouseControllerMsg -Fix $mouseControllerFix -FixNote $mouseControllerFixNote
    }

    # --- Check 22: Capture Card Present ---
    $captureVIDs = @('VID_07CA', 'VID_0FD9', 'VID_1CEA')  # AVerMedia, Elgato, Magewell
    $captureFound = $false
    $captureDesc  = ''
    try {
        $usbDevs = Get-WmiObject Win32_PnPEntity -ErrorAction Stop
        foreach ($dev in $usbDevs) {
            foreach ($vid in $captureVIDs) {
                if ($dev.DeviceID -like ('*' + $vid + '*')) {
                    $captureFound = $true
                    $captureDesc  = $dev.Description
                    break
                }
            }
            if ($captureFound) { break }
        }
    } catch {}

    if ($captureFound) {
        $results += New-CheckResult -Name 'Capture Card Present' -Category 'Peripheral' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ('Found: ' + $captureDesc) -Expected 'Disconnected when not streaming' `
            -Message 'Active capture cards add DPC overhead from continuous frame processing. Disconnect when not streaming.' `
            -Fix '' -FixNote 'Physically disconnect USB capture card when gaming without streaming.'
    } else {
        $results += New-CheckResult -Name 'Capture Card Present' -Category 'Peripheral' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'No capture card detected' -Expected 'Not present'
    }

    # --- Check 23: Overlay Processes ---
    $overlayProcs = @(
        @{ Name='Discord';        Exe='Discord' },
        @{ Name='GeForce Overlay';Exe='NVTMRMON' },
        @{ Name='Xbox Game Bar';  Exe='GameBar' },
        @{ Name='Steam Overlay';  Exe='GameOverlayUI' },
        @{ Name='NZXT CAM';       Exe='NZXT CAM' }
    )
    $foundOverlays = @()
    foreach ($o in $overlayProcs) {
        if (Get-Process -Name $o.Exe -ErrorAction SilentlyContinue) {
            $foundOverlays += $o.Name
        }
    }
    if ($foundOverlays.Count -eq 0) {
        $results += New-CheckResult -Name 'Overlay Processes' -Category 'Peripheral' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'No overlay processes detected' -Expected 'None running'
    } else {
        $results += New-CheckResult -Name 'Overlay Processes' -Category 'Peripheral' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ('Running: ' + ($foundOverlays -join ', ')) -Expected 'None during gaming' `
            -Message 'Overlay processes hook into the graphics pipeline and can cause frame-time spikes.' `
            -Fix '' -FixNote 'Close listed processes before gaming. Disable auto-start in each app settings.'
    }

    return $results
}
