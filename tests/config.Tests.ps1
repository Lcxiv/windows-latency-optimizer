<#
.SYNOPSIS
    Pester 3.x tests for config.ps1 central configuration.
.DESCRIPTION
    Validates config.ps1 exports correct variables, Find-Tool works, and
    counter name mapping is complete.
    Run: Invoke-Pester .\tests\config.Tests.ps1
#>

# Dot-source config
$script:logLines = @()
. "$PSScriptRoot\..\scripts\config.ps1"

Describe 'Config: Project Paths' {
    It 'sets ProjectRoot to the repository root' {
        $script:ProjectRoot | Should Not BeNullOrEmpty
        Test-Path $script:ProjectRoot | Should Be $true
    }

    It 'sets CaptureRoot under ProjectRoot' {
        $script:CaptureRoot | Should Match 'captures'
    }

    It 'sets ExperimentsDir under CaptureRoot' {
        $script:ExperimentsDir | Should Match 'experiments'
    }

    It 'sets DashboardData to dashboard/data' {
        $script:DashboardData | Should Match 'dashboard'
        $script:DashboardData | Should Match 'data'
    }

    It 'ScriptsDir points to the scripts folder' {
        $script:ScriptsDir | Should Match 'scripts'
        Test-Path $script:ScriptsDir | Should Be $true
    }
}

Describe 'Config: Find-Tool' {
    It 'finds executables on PATH (cmd.exe always exists)' {
        $result = Find-Tool 'cmd.exe'
        $result | Should Not BeNullOrEmpty
        $result | Should Match 'cmd\.exe'
    }

    It 'returns null for nonexistent tools' {
        $result = Find-Tool 'definitely_not_a_real_tool_abc123.exe'
        $result | Should BeNullOrEmpty
    }

    It 'searches provided paths' {
        # Create a temp tool
        $tempDir = Join-Path $env:TEMP 'config_test_tool'
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $toolPath = Join-Path $tempDir 'fake_tool.exe'
        '' | Out-File $toolPath -Force

        $result = Find-Tool 'fake_tool.exe' @($tempDir)
        $result | Should Not BeNullOrEmpty
        $result | Should Be $toolPath

        Remove-Item $tempDir -Recurse -Force
    }
}

Describe 'Config: Tool Paths' {
    It 'ToolPaths hashtable is populated' {
        $script:ToolPaths | Should Not BeNullOrEmpty
        $script:ToolPaths.Keys.Count | Should BeGreaterThan 0
    }

    It 'has entries for ProcMon, WPR, Xperf, PresentMon' {
        $script:ToolPaths.ContainsKey('ProcMon') | Should Be $true
        $script:ToolPaths.ContainsKey('WPR') | Should Be $true
        $script:ToolPaths.ContainsKey('Xperf') | Should Be $true
        $script:ToolPaths.ContainsKey('PresentMon') | Should Be $true
    }

    It 'WPR is found (built-in to Windows)' {
        $script:ToolPaths.WPR | Should Not BeNullOrEmpty
    }
}

Describe 'Config: Performance Counters' {
    It 'has 14 performance counters' {
        $script:PerfCounters.Count | Should Be 14
    }

    It 'includes per-CPU interrupt and DPC counters' {
        ($script:PerfCounters -contains '\Processor(*)\% Interrupt Time') | Should Be $true
        ($script:PerfCounters -contains '\Processor(*)\% DPC Time') | Should Be $true
    }

    It 'includes total CPU time' {
        ($script:PerfCounters -contains '\Processor(_Total)\% Processor Time') | Should Be $true
    }

    It 'includes memory counters' {
        ($script:PerfCounters -contains '\Memory\Available MBytes') | Should Be $true
    }

    It 'includes disk counters' {
        ($script:PerfCounters -contains '\PhysicalDisk(_Total)\Current Disk Queue Length') | Should Be $true
    }
}

Describe 'Config: Counter Name Map' {
    It 'has 11 counter name mappings' {
        $script:CounterNameMap.Count | Should Be 11
    }

    It 'maps DPC time correctly' {
        $script:CounterNameMap['% dpc time[_total]'] | Should Be 'DPCTimePct'
    }

    It 'maps processor time correctly' {
        $script:CounterNameMap['% processor time[_total]'] | Should Be 'ProcessorTimePct'
    }

    It 'maps interrupt time correctly' {
        $script:CounterNameMap['% interrupt time[_total]'] | Should Be 'InterruptTimePct'
    }

    It 'maps context switches correctly' {
        $script:CounterNameMap['context switches/sec'] | Should Be 'ContextSwitchesSec'
    }

    It 'all values are unique (no duplicate target field names)' {
        $values = @($script:CounterNameMap.Values)
        $unique = $values | Select-Object -Unique
        $unique.Count | Should Be $values.Count
    }
}

Describe 'Config: Known Game Processes' {
    It 'has at least 5 game processes' {
        $script:KnownGameProcesses.Count | Should BeGreaterThan 4
    }

    It 'includes Fortnite' {
        ($script:KnownGameProcesses -contains 'FortniteClient-Win64-Shipping') | Should Be $true
    }

    It 'includes CS2' {
        ($script:KnownGameProcesses -contains 'cs2') | Should Be $true
    }
}

Describe 'Config: Ping Targets' {
    It 'has at least 5 ping targets' {
        $script:PingTargets.Count | Should BeGreaterThan 4
    }

    It 'includes google.com' {
        ($script:PingTargets -contains 'google.com') | Should Be $true
    }

    It 'includes Epic Games servers' {
        $epic = $script:PingTargets | Where-Object { $_ -match 'epicgames' }
        $epic | Should Not BeNullOrEmpty
    }
}

Describe 'Config: Affinity Device Checks' {
    It 'has at least 4 device checks' {
        $script:AffinityDeviceChecks.Count | Should BeGreaterThan 3
    }

    It 'includes GPU (NVIDIA)' {
        $gpu = $script:AffinityDeviceChecks | Where-Object { $_.Name -eq 'GPU' }
        $gpu | Should Not BeNullOrEmpty
        $gpu.Pattern | Should Be 'VEN_10DE'
    }

    It 'includes NIC (Intel I226-V)' {
        $nic = $script:AffinityDeviceChecks | Where-Object { $_.Name -eq 'NIC' }
        $nic | Should Not BeNullOrEmpty
        $nic.Pattern | Should Match 'VEN_8086'
    }

    It 'each entry has Name and Pattern keys' {
        foreach ($dc in $script:AffinityDeviceChecks) {
            $dc.Name | Should Not BeNullOrEmpty
            $dc.Pattern | Should Not BeNullOrEmpty
        }
    }
}
