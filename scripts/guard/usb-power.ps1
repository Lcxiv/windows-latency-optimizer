<#
.SYNOPSIS
    Guard: USB Enhanced Power Management & Selective Suspend.
.DESCRIPTION
    Checks Viper V3 Pro USB devices for EPM re-enablement and ensures
    global USB selective suspend stays disabled. Auto-fixes any drift.
#>
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Continue'

# Dot-source logging helper if not already loaded
if (-not (Get-Command 'Log' -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '..\helpers\logging.ps1')
}

function Invoke-UsbPowerGuard {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $fixes = 0
    $checks = 0
    $passed = 0

    # ── USB EnhancedPowerManagement (Viper V3 Pro) ──────────────────────────
    Log '--- USB EnhancedPowerManagement ---'

    $mouseUsb = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
        $_.FriendlyName -match 'Viper V3' -and $_.InstanceId -match '^USB' -and $_.Status -eq 'OK'
    })

    if ($mouseUsb.Count -eq 0) {
        Log 'No active Viper V3 USB devices found (mouse off or wireless?)' 'WARN'
    } else {
        foreach ($dev in $mouseUsb) {
            $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $dev.InstanceId + '\Device Parameters'
            $checks++
            if (Test-Path $regPath) {
                $epm = (Get-ItemProperty $regPath -Name 'EnhancedPowerManagementEnabled' -ErrorAction SilentlyContinue).EnhancedPowerManagementEnabled
                $shortId = $dev.InstanceId.Split('\')
                $shortId = $shortId[$shortId.Count - 1]

                if ($epm -eq 1) {
                    if ($PSCmdlet.ShouldProcess($shortId, 'Disable EPM')) {
                        Set-ItemProperty $regPath -Name 'EnhancedPowerManagementEnabled' -Value 0 -Type DWord
                    }
                    Log ('EPM 1->0 on ' + $shortId + ' (was adding input latency)') 'FIX'
                    $fixes++
                } elseif ($null -eq $epm -or $epm -eq 0) {
                    Log ('EPM=0 on ' + $shortId) 'PASS'
                    $passed++
                }

                # Also check SelectiveSuspend
                $ss = (Get-ItemProperty $regPath -Name 'SelectiveSuspendEnabled' -ErrorAction SilentlyContinue).SelectiveSuspendEnabled
                if ($ss -eq 1) {
                    $checks++
                    if ($PSCmdlet.ShouldProcess($shortId, 'Disable SelectiveSuspend')) {
                        Set-ItemProperty $regPath -Name 'SelectiveSuspendEnabled' -Value 0 -Type DWord
                    }
                    Log ('SelectiveSuspend 1->0 on ' + $shortId) 'FIX'
                    $fixes++
                }
            }
        }
    }

    # ── USB Selective Suspend (global) ──────────────────────────────────────
    Log '--- USB Selective Suspend ---'
    $checks++
    $usbRegPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\USB'
    $usbSS = (Get-ItemProperty $usbRegPath -Name 'DisableSelectiveSuspend' -ErrorAction SilentlyContinue).DisableSelectiveSuspend
    if ($usbSS -eq 1) {
        Log 'USB selective suspend disabled' 'PASS'
        $passed++
    } else {
        if (-not (Test-Path $usbRegPath)) { New-Item -Path $usbRegPath -Force | Out-Null }
        if ($PSCmdlet.ShouldProcess('USB\DisableSelectiveSuspend', 'Set to 1')) {
            Set-ItemProperty $usbRegPath -Name 'DisableSelectiveSuspend' -Value 1 -Type DWord
        }
        Log 'USB selective suspend: re-disabled (was reverted)' 'FIX'
        $fixes++
    }

    return @{ Checks = $checks; Passed = $passed; Fixes = $fixes }
}

# Allow standalone execution
if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-UsbPowerGuard
    Log ('USB Power: Checks=' + $result.Checks + ' Passed=' + $result.Passed + ' Fixes=' + $result.Fixes)
}
