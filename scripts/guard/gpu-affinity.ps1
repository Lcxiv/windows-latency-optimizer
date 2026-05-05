<#
.SYNOPSIS
    Guard: GPU Interrupt Affinity (RTX 5070 Ti -> CPUs 4-7).
.DESCRIPTION
    Ensures the RTX 5070 Ti interrupt affinity override is set to CPUs 4-7
    (mask 0xF0) via DevicePolicy=4 + AssignmentSetOverride. This prevents
    GPU DPC work from saturating CPU 0 (preferred core).
#>
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Continue'

# Dot-source logging helper if not already loaded
if (-not (Get-Command 'Log' -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '..\helpers\logging.ps1')
}

function Invoke-GpuAffinityGuard {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $fixes = 0
    $checks = 0
    $passed = 0

    Log '--- GPU Interrupt Affinity ---'

    $gpuBase = 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI\VEN_10DE&DEV_2C05&SUBSYS_417F1458&REV_A1\253C1C6A232DB04800'
    $gpuAffLocations = @(
        (Join-Path $gpuBase 'Interrupt Management\Affinity Policy'),
        (Join-Path $gpuBase 'Device Parameters\Interrupt Management\Affinity Policy')
    )

    $gpuAffOk = $false
    foreach ($affPath in $gpuAffLocations) {
        if (Test-Path $affPath) {
            $checks++
            $policy = (Get-ItemProperty $affPath -Name 'DevicePolicy' -ErrorAction SilentlyContinue).DevicePolicy
            $override = (Get-ItemProperty $affPath -Name 'AssignmentSetOverride' -ErrorAction SilentlyContinue).AssignmentSetOverride
            if ($policy -eq 4 -and $null -ne $override) {
                $bytes = [byte[]]$override
                $mask = 0
                for ($i = 0; $i -lt $bytes.Length; $i++) { $mask = $mask -bor ([int64]$bytes[$i] -shl ($i * 8)) }
                if ($mask -eq 0xF0) {
                    $gpuAffOk = $true
                    $passed++
                }
            }
        }
    }

    if ($gpuAffOk) {
        Log 'GPU affinity: CPUs 4-7 (mask 0xF0)' 'PASS'
    } else {
        $checks++
        foreach ($affPath in $gpuAffLocations) {
            $intMgmt = Split-Path $affPath -Parent
            if (-not (Test-Path $intMgmt)) { New-Item -Path $intMgmt -Force | Out-Null }
            if (-not (Test-Path $affPath)) { New-Item -Path $affPath -Force | Out-Null }
            if ($PSCmdlet.ShouldProcess($affPath, 'Set DevicePolicy=4, mask=0xF0')) {
                Set-ItemProperty $affPath -Name 'DevicePolicy' -Value 4 -Type DWord
                $maskBytes = [byte[]]@(0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
                Set-ItemProperty $affPath -Name 'AssignmentSetOverride' -Value $maskBytes -Type Binary
            }
        }
        Log 'GPU affinity: RESTORED to CPUs 4-7 (was missing or wrong)' 'FIX'
        $fixes++
    }

    return @{ Checks = $checks; Passed = $passed; Fixes = $fixes }
}

# Allow standalone execution
if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-GpuAffinityGuard
    Log ('GPU Affinity: Checks=' + $result.Checks + ' Passed=' + $result.Passed + ' Fixes=' + $result.Fixes)
}
