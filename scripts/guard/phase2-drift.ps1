<#
.SYNOPSIS
    Guard: Phase 2 drift detection (UCPD, Spectre mitigations, WdFilter).
.DESCRIPTION
    Checks for drift in Phase 2 deep optimizations: UCPD.sys disable,
    Spectre V2 retpoline override, and WdFilter kernel driver status.
    Auto-fixes UCPD and Spectre; WdFilter is read-only (requires WinRE).
#>
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Continue'

# Dot-source logging helper if not already loaded
if (-not (Get-Command 'Log' -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '..\helpers\logging.ps1')
}

function Invoke-Phase2DriftGuard {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $fixes = 0
    $checks = 0
    $passed = 0

    Log '--- Phase 2 Drift Detection ---'

    # UCPD.sys
    $checks++
    $ucpdStart = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\UCPD' -Name 'Start' -ErrorAction SilentlyContinue).Start
    if ($ucpdStart -eq 4) {
        Log 'UCPD.sys disabled (Start=4)' 'PASS'
        $passed++
    } else {
        if ($PSCmdlet.ShouldProcess('UCPD\Start', ('Set ' + $ucpdStart + ' -> 4'))) {
            Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\UCPD' -Name 'Start' -Value 4 -Type DWord
        }
        Log ('UCPD.sys: Start ' + $ucpdStart + ' -> 4 (re-disabled)') 'FIX'
        $fixes++
    }

    # Spectre override
    $checks++
    $memMgmt = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    $specOverride = (Get-ItemProperty $memMgmt -Name 'FeatureSettingsOverride' -ErrorAction SilentlyContinue).FeatureSettingsOverride
    if ($specOverride -eq 3) {
        Log 'Spectre V2 retpoline override intact (value=3)' 'PASS'
        $passed++
    } else {
        if ($PSCmdlet.ShouldProcess('Memory Management\FeatureSettingsOverride', ('Set ' + $specOverride + ' -> 3'))) {
            Set-ItemProperty $memMgmt -Name 'FeatureSettingsOverride' -Value 3 -Type DWord
            Set-ItemProperty $memMgmt -Name 'FeatureSettingsOverrideMask' -Value 3 -Type DWord
        }
        Log ('Spectre override: ' + $specOverride + ' -> 3 (re-applied)') 'FIX'
        $fixes++
    }

    # WdFilter kernel status (read-only, cannot auto-fix)
    $checks++
    $wdFilterStart = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\WdFilter' -Name 'Start' -ErrorAction SilentlyContinue).Start
    if ($wdFilterStart -eq 4) {
        Log 'WdFilter.sys disabled (Start=4)' 'PASS'
        $passed++
    } else {
        Log ('WdFilter.sys: Start=' + $wdFilterStart + ' (still active -- run defender_winre_kill.ps1)') 'WARN'
    }

    return @{ Checks = $checks; Passed = $passed; Fixes = $fixes }
}

# Allow standalone execution
if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-Phase2DriftGuard
    Log ('Phase 2 Drift: Checks=' + $result.Checks + ' Passed=' + $result.Passed + ' Fixes=' + $result.Fixes)
}
