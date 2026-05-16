<#
.SYNOPSIS
    Pester 3.x tests for topology.ps1 CPU topology detection.
.DESCRIPTION
    Tests Get-CpuTopology, ConvertTo-AffinityMask, Get-GroupShareFromCpuData.
    Run: Invoke-Pester .\tests\topology.Tests.ps1
#>

$script:logLines = @()
. "$PSScriptRoot\..\scripts\config.ps1"

Describe 'ConvertTo-AffinityMask' {
    It 'creates correct mask for CPU 0' {
        $mask = ConvertTo-AffinityMask @(0) 16
        $mask[0] | Should Be 0x01
        $mask[1] | Should Be 0x00
    }

    It 'creates correct mask for CPUs 4-7' {
        $mask = ConvertTo-AffinityMask @(4,5,6,7) 16
        $mask[0] | Should Be 0xF0
        $mask[1] | Should Be 0x00
    }

    It 'creates correct mask for CPUs 8-15' {
        $mask = ConvertTo-AffinityMask @(8,9,10,11,12,13,14,15) 16
        $mask[0] | Should Be 0x00
        $mask[1] | Should Be 0xFF
    }

    It 'creates correct mask for CPUs 2-3' {
        $mask = ConvertTo-AffinityMask @(2,3) 16
        $mask[0] | Should Be 0x0C
        $mask[1] | Should Be 0x00
    }

    It 'handles single CPU correctly' {
        $mask = ConvertTo-AffinityMask @(7) 16
        $mask[0] | Should Be 0x80
    }

    It 'handles CPUs beyond 16 (CPU 24)' {
        $mask = ConvertTo-AffinityMask @(24) 32
        $mask.Count | Should Be 4
        $mask[3] | Should Be 0x01
    }

    It 'skips out-of-range CPUs' {
        $mask = ConvertTo-AffinityMask @(0, 99) 16
        $mask[0] | Should Be 0x01
    }

    It 'returns minimum 2-byte array' {
        $mask = ConvertTo-AffinityMask @(0) 4
        $mask.Count | Should BeGreaterThan 1
    }
}

Describe 'Get-GroupShareFromCpuData' {
    It 'computes correct share for known data' {
        $cpuData = @(
            @{ cpu = 0; interruptPct = 10 },
            @{ cpu = 1; interruptPct = 20 },
            @{ cpu = 2; interruptPct = 30 },
            @{ cpu = 3; interruptPct = 40 }
        )
        $share = Get-GroupShareFromCpuData -CpuData $cpuData -GroupCpus @(0)
        $share | Should Be 10.0
    }

    It 'computes multi-CPU group share' {
        $cpuData = @(
            @{ cpu = 0; interruptPct = 10 },
            @{ cpu = 1; interruptPct = 10 },
            @{ cpu = 2; interruptPct = 10 },
            @{ cpu = 3; interruptPct = 10 }
        )
        $share = Get-GroupShareFromCpuData -CpuData $cpuData -GroupCpus @(0,1)
        $share | Should Be 50.0
    }

    It 'returns 0 for empty CpuData' {
        $share = Get-GroupShareFromCpuData -CpuData @() -GroupCpus @(0)
        $share | Should Be 0
    }

    It 'returns 0 when total interrupt is 0' {
        $cpuData = @(
            @{ cpu = 0; interruptPct = 0 },
            @{ cpu = 1; interruptPct = 0 }
        )
        $share = Get-GroupShareFromCpuData -CpuData $cpuData -GroupCpus @(0)
        $share | Should Be 0
    }

    It 'handles CPUs not in group' {
        $cpuData = @(
            @{ cpu = 0; interruptPct = 100 },
            @{ cpu = 5; interruptPct = 50 }
        )
        $share = Get-GroupShareFromCpuData -CpuData $cpuData -GroupCpus @(99)
        $share | Should Be 0
    }
}

Describe 'Get-CpuTopology' {
    $topo = Get-CpuTopology -Force

    It 'returns a hashtable' {
        $topo | Should Not BeNullOrEmpty
        $topo.GetType().Name | Should Be 'Hashtable'
    }

    It 'detects CPU model' {
        $topo.cpuModel | Should Not BeNullOrEmpty
        $topo.cpuModel.Length | Should BeGreaterThan 5
    }

    It 'detects manufacturer as AMD or Intel' {
        ($topo.manufacturer -eq 'AMD' -or $topo.manufacturer -eq 'Intel' -or $topo.manufacturer -eq 'Unknown') | Should Be $true
    }

    It 'detects correct logical processor count' {
        $topo.totalLogical | Should BeGreaterThan 0
        $topo.totalLogical | Should Be ([int]$env:NUMBER_OF_PROCESSORS)
    }

    It 'has exactly 4 groups' {
        $topo.groups.Count | Should Be 4
    }

    It 'has groups named preferred, input, bulk, game' {
        $names = @($topo.groups | ForEach-Object { $_.name })
        ($names -contains 'preferred') | Should Be $true
        ($names -contains 'input') | Should Be $true
        ($names -contains 'bulk') | Should Be $true
        ($names -contains 'game') | Should Be $true
    }

    It 'preferred group has exactly 1 CPU' {
        $pref = $topo.groups | Where-Object { $_.name -eq 'preferred' }
        $pref.cpus.Count | Should Be 1
    }

    It 'assigns all CPUs to exactly one group (no gaps)' {
        $allAssigned = @()
        foreach ($g in $topo.groups) { $allAssigned += $g.cpus }
        $allAssigned = $allAssigned | Sort-Object -Unique
        $allAssigned.Count | Should Be $topo.totalLogical
    }

    It 'no CPU appears in multiple groups (no overlap)' {
        $allCpus = @()
        foreach ($g in $topo.groups) { $allCpus += $g.cpus }
        $uniqueCount = ($allCpus | Sort-Object -Unique).Count
        $uniqueCount | Should Be $allCpus.Count
    }

    It 'generates affinity masks for each non-empty group' {
        # On smaller hosts (e.g. CI runners) some groups may be empty.
        # affinityMasks excludes empty groups by design.
        $nonEmptyGroups = @($topo.groups | Where-Object { $_.cpus.Count -gt 0 })
        $topo.affinityMasks.Keys.Count | Should Be $nonEmptyGroups.Count
    }

    It 'caches result on second call' {
        $first  = Get-CpuTopology
        $second = Get-CpuTopology
        # Same object reference (cached)
        [object]::ReferenceEquals($first, $second) | Should Be $true
    }

    It 'refreshes on -Force' {
        $cached = Get-CpuTopology
        $fresh  = Get-CpuTopology -Force
        # Different object (new hashtable)
        [object]::ReferenceEquals($cached, $fresh) | Should Be $false
        # But same data
        $fresh.totalLogical | Should Be $cached.totalLogical
    }
}
