<#
.SYNOPSIS
    Guard: NVIDIA GPU max performance settings.
.DESCRIPTION
    Verifies registry-level NVIDIA performance mode (dynamic P-state disabled,
    max perf source, PowerMizer) and applies nvidia-smi clock lock for the
    RTX 5070 Ti at 3090 MHz boost.
#>
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Continue'

# Dot-source logging helper if not already loaded
if (-not (Get-Command 'Log' -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '..\helpers\logging.ps1')
}

function Invoke-NvidiaPerfGuard {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $fixes = 0
    $checks = 0
    $passed = 0

    Log '--- NVIDIA GPU Performance ---'

    $nvRegPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000'
    $nvChecks = @(
        @{ Name = 'DisableDynamicPstate'; Value = 1; Label = 'Dynamic P-state disabled' },
        @{ Name = 'PerfLevelSrc';         Value = 13090; Label = 'Max performance mode (0x3322)' },
        @{ Name = 'PowerMizerEnable';     Value = 1; Label = 'PowerMizer enabled' },
        @{ Name = 'PowerMizerLevel';      Value = 1; Label = 'PowerMizer high perf' }
    )

    $nvDrift = 0
    if (Test-Path $nvRegPath) {
        foreach ($nv in $nvChecks) {
            $checks++
            $current = (Get-ItemProperty $nvRegPath -Name $nv.Name -ErrorAction SilentlyContinue).$($nv.Name)
            if ($null -ne $current -and [int]$current -eq $nv.Value) {
                $passed++
            } else {
                $fromStr = if ($null -eq $current) { '<null>' } else { [string]$current }
                if ($PSCmdlet.ShouldProcess(($nvRegPath + '\' + $nv.Name), ('Set ' + $fromStr + ' -> ' + [string]$nv.Value))) {
                    Set-ItemProperty $nvRegPath -Name $nv.Name -Value $nv.Value -Type DWord
                }
                Log ($nv.Name + ': ' + $fromStr + ' -> ' + [string]$nv.Value + ' (' + $nv.Label + ')') 'FIX'
                $fixes++
                $nvDrift++
            }
        }
        if ($nvDrift -eq 0) {
            Log ('All ' + $nvChecks.Count + ' NVIDIA settings intact') 'PASS'
        }

        # Apply nvidia-smi clock lock (immediate effect, no reboot needed)
        $nvsmi = 'C:\Windows\System32\nvidia-smi.exe'
        if (Test-Path $nvsmi) {
            if ($PSCmdlet.ShouldProcess('GPU 0', 'Lock clocks to 3090 MHz')) {
                $lockResult = & $nvsmi -lgc 3090,3090 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Log 'GPU clock locked to 3090 MHz' 'PASS'
                } else {
                    Log ('nvidia-smi clock lock failed: ' + $lockResult) 'WARN'
                }
            }
        }
    } else {
        Log 'NVIDIA GPU registry key not found' 'WARN'
    }

    return @{ Checks = $checks; Passed = $passed; Fixes = $fixes }
}

# Allow standalone execution
if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-NvidiaPerfGuard
    Log ('NVIDIA Perf: Checks=' + $result.Checks + ' Passed=' + $result.Passed + ' Fixes=' + $result.Fixes)
}
