<#
.SYNOPSIS
    Guard: Mouse & Keyboard Input Stack tweaks.
.DESCRIPTION
    Verifies and auto-fixes input driver parameters: queue sizes, timestamp
    logging, cursor magnetism, and HID settings. Prevents Windows from
    reverting low-latency input configuration.
#>
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Continue'

# Dot-source logging helper if not already loaded
if (-not (Get-Command 'Log' -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '..\helpers\logging.ps1')
}

function Invoke-InputStackGuard {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $fixes = 0
    $checks = 0
    $passed = 0

    Log '--- Mouse/Keyboard Input Tweaks ---'

    $inputTweaks = @(
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters'; Name = 'MouseDataQueueSize'; Value = 32; Type = 'DWord' },
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters'; Name = 'WppRecorder_UseTimeStamp'; Value = 0; Type = 'DWord' },
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters'; Name = 'KeyboardDataQueueSize'; Value = 32; Type = 'DWord' },
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters'; Name = 'WppRecorder_UseTimeStamp'; Value = 0; Type = 'DWord' },
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters'; Name = 'SendOutputToAllPorts'; Value = 0; Type = 'DWord' },
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\mouhid\Parameters'; Name = 'TreatAbsolutePointerAsAbsolute'; Value = 1; Type = 'DWord' },
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\mouhid\Parameters'; Name = 'WppRecorder_UseTimeStamp'; Value = 0; Type = 'DWord' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Input\Settings\ControllerProcessor\CursorSpeed'; Name = 'CursorUpdateInterval'; Value = 1; Type = 'DWord' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Input\Settings\ControllerProcessor\CursorMagnetism'; Name = 'AttractionRectInsetInDIPS'; Value = 0; Type = 'DWord' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Input\Settings\ControllerProcessor\CursorMagnetism'; Name = 'DistanceThresholdInDIPS'; Value = 0; Type = 'DWord' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Input\Settings\ControllerProcessor\CursorMagnetism'; Name = 'MagnetismDelayInMilliseconds'; Value = 0; Type = 'DWord' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Input\Settings\ControllerProcessor\CursorMagnetism'; Name = 'MagnetismUpdateIntervalInMilliseconds'; Value = 0; Type = 'DWord' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Input\Settings\ControllerProcessor\CursorMagnetism'; Name = 'VelocityInDIPSPerSecond'; Value = 0; Type = 'DWord' }
    )

    foreach ($t in $inputTweaks) {
        $checks++
        $current = $null
        try {
            $current = (Get-ItemProperty $t.Path -Name $t.Name -ErrorAction Stop).$($t.Name)
        } catch {}

        if ($null -ne $current -and [int]$current -eq $t.Value) {
            $passed++
            # Don't log every PASS — too noisy for startup
        } else {
            if (-not (Test-Path $t.Path)) {
                New-Item -Path $t.Path -Force | Out-Null
            }
            $fromStr = if ($null -eq $current) { '(not set)' } else { [string]$current }
            if ($PSCmdlet.ShouldProcess(($t.Path + '\' + $t.Name), ('Set ' + $fromStr + ' -> ' + [string]$t.Value))) {
                Set-ItemProperty $t.Path -Name $t.Name -Value $t.Value -Type $t.Type
            }
            Log ($t.Name + ': ' + $fromStr + ' -> ' + [string]$t.Value) 'FIX'
            $fixes++
        }
    }

    if ($fixes -eq 0) {
        Log ('All ' + $inputTweaks.Count + ' input tweaks intact') 'PASS'
    }

    return @{ Checks = $checks; Passed = $passed; Fixes = $fixes }
}

# Allow standalone execution
if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-InputStackGuard
    Log ('Input Stack: Checks=' + $result.Checks + ' Passed=' + $result.Passed + ' Fixes=' + $result.Fixes)
}
