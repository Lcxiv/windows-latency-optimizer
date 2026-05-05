<#
.SYNOPSIS
    Guard: Windows Defender settings and exclusion paths.
.DESCRIPTION
    Ensures Defender real-time monitoring stays disabled (policy), scan CPU
    cap is low, and gaming exclusion paths remain applied. Handles Defender
    WMI being unavailable gracefully.
#>
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Continue'

# Dot-source logging helper if not already loaded
if (-not (Get-Command 'Log' -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '..\helpers\logging.ps1')
}

function Invoke-DefenderSettingsGuard {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $fixes = 0
    $checks = 0
    $passed = 0

    Log '--- Windows Defender Settings ---'

    $defenderPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
    $defenderScanPath   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Scan'

    $defenderChecks = @(
        @{ Path = $defenderPolicyPath; Name = 'DisableRealtimeMonitoring'; Value = 1; Type = 'DWord'; Label = 'Real-time monitoring disabled' },
        @{ Path = $defenderScanPath;   Name = 'ScanAvgCPULoadFactor';     Value = 5; Type = 'DWord'; Label = 'Scan CPU cap = 5%' }
    )

    foreach ($d in $defenderChecks) {
        $checks++
        $current = $null
        try {
            if (-not (Test-Path $d.Path)) {
                New-Item -Path $d.Path -Force | Out-Null
            }
            $current = (Get-ItemProperty $d.Path -Name $d.Name -ErrorAction Stop).$($d.Name)
        } catch {}

        if ($null -ne $current -and [int]$current -eq $d.Value) {
            Log ($d.Label + ' [OK]') 'PASS'
            $passed++
        } else {
            $fromStr = if ($null -eq $current) { '<null>' } else { [string]$current }
            if (-not (Test-Path $d.Path)) {
                New-Item -Path $d.Path -Force | Out-Null
            }
            if ($PSCmdlet.ShouldProcess(($d.Path + '\' + $d.Name), ('Set ' + $fromStr + ' -> ' + [string]$d.Value))) {
                Set-ItemProperty $d.Path -Name $d.Name -Value $d.Value -Type $d.Type
            }
            Log ($d.Name + ': ' + $fromStr + ' -> ' + [string]$d.Value + ' (' + $d.Label + ')') 'FIX'
            $fixes++
        }
    }

    # Exclusion paths — restore from config file (skip if Defender WMI is dead)
    $checks++
    $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $exclusionFile = Join-Path $projectRoot 'config\defender_exclusions.txt'
    if (Test-Path $exclusionFile) {
        $mpPrefError = $false
        try {
            $currentPaths = @((Get-MpPreference -ErrorAction Stop).ExclusionPath)
        } catch {
            $mpPrefError = $true
        }

        if ($mpPrefError) {
            # 0x800106ba = Defender AM not running / WMI dead — exclusions irrelevant
            Log 'Defender WMI unavailable (AM dormant) - exclusions N/A' 'PASS'
            $passed++
        } else {
            $expectedPaths = @(Get-Content $exclusionFile | Where-Object { $_.Trim().Length -gt 0 } | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) })
            $missing = @()
            foreach ($ep in $expectedPaths) {
                $found = $false
                foreach ($cp in $currentPaths) {
                    if ($cp -eq $ep) { $found = $true; break }
                }
                if (-not $found) { $missing += $ep }
            }
            if ($missing.Count -eq 0) {
                Log ($expectedPaths.Count.ToString() + ' exclusion paths intact') 'PASS'
                $passed++
            } else {
                foreach ($mp in $missing) {
                    $expandedPath = [Environment]::ExpandEnvironmentVariables($mp)
                    if ($PSCmdlet.ShouldProcess($expandedPath, 'Add Defender exclusion')) {
                        try { Add-MpPreference -ExclusionPath $expandedPath -ErrorAction Stop } catch {}
                    }
                }
                Log ('Restored ' + $missing.Count.ToString() + ' missing exclusion path(s)') 'FIX'
                $fixes++
            }
        }
    } else {
        Log ('Exclusion config not found: ' + $exclusionFile) 'WARN'
    }

    return @{ Checks = $checks; Passed = $passed; Fixes = $fixes }
}

# Allow standalone execution
if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-DefenderSettingsGuard
    Log ('Defender Settings: Checks=' + $result.Checks + ' Passed=' + $result.Passed + ' Fixes=' + $result.Fixes)
}
