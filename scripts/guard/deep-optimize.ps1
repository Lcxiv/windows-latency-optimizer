<#
.SYNOPSIS
    Guard: Deep Optimize settings (GameBar, GameDVR, CSRSS, Power Throttling).
.DESCRIPTION
    Verifies and auto-fixes GameBar/GameDVR disablement, CSRSS elevated
    priority, and power throttling override. These settings are frequently
    reverted by Windows Feature Updates.
#>
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Continue'

# Dot-source logging helper if not already loaded
if (-not (Get-Command 'Log' -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '..\helpers\logging.ps1')
}

function Invoke-DeepOptimizeGuard {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $fixes = 0
    $checks = 0
    $passed = 0

    Log '--- Deep Optimize Settings ---'

    $deepChecks = @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR';  Name = 'AllowGameDVR';           Value = 0; Type = 'DWord'; Label = 'GameBar policy disabled' },
        @{ Path = 'HKCU:\System\GameConfigStore';                        Name = 'GameDVR_Enabled';         Value = 0; Type = 'DWord'; Label = 'GameDVR disabled' },
        @{ Path = 'HKCU:\System\GameConfigStore';                        Name = 'GameDVR_FSEBehaviorMode'; Value = 0; Type = 'DWord'; Label = 'FSE behavior mode' },
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled';  Value = 0; Type = 'DWord'; Label = 'App capture disabled' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\csrss.exe\PerfOptions'; Name = 'CpuPriorityClass'; Value = 3; Type = 'DWord'; Label = 'CSRSS high priority' },
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'; Name = 'PowerThrottlingOff'; Value = 1; Type = 'DWord'; Label = 'Power throttling off' }
    )

    $deepDrift = 0
    foreach ($d in $deepChecks) {
        $checks++
        $current = $null
        try {
            $current = (Get-ItemProperty $d.Path -Name $d.Name -ErrorAction Stop).$($d.Name)
        } catch {}

        if ($null -ne $current -and [int]$current -eq $d.Value) {
            $passed++
        } else {
            if (-not (Test-Path $d.Path)) {
                New-Item -Path $d.Path -Force | Out-Null
            }
            $fromStr = if ($null -eq $current) { '<null>' } else { [string]$current }
            if ($PSCmdlet.ShouldProcess(($d.Path + '\' + $d.Name), ('Set ' + $fromStr + ' -> ' + [string]$d.Value))) {
                Set-ItemProperty $d.Path -Name $d.Name -Value $d.Value -Type $d.Type
            }
            Log ($d.Name + ': ' + $fromStr + ' -> ' + [string]$d.Value + ' (' + $d.Label + ')') 'FIX'
            $fixes++
            $deepDrift++
        }
    }

    if ($deepDrift -eq 0) {
        Log ('All ' + $deepChecks.Count + ' deep optimize settings intact') 'PASS'
    }

    return @{ Checks = $checks; Passed = $passed; Fixes = $fixes }
}

# Allow standalone execution
if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-DeepOptimizeGuard
    Log ('Deep Optimize: Checks=' + $result.Checks + ' Passed=' + $result.Passed + ' Fixes=' + $result.Fixes)
}
