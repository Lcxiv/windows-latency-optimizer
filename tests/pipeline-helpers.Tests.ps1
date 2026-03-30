<#
.SYNOPSIS
    Pester 3.x tests for pipeline-helpers.ps1 functions.
.DESCRIPTION
    Tests Get-Stats, Log, and core helper functions.
    Run: Invoke-Pester .\tests\pipeline-helpers.Tests.ps1
#>

# Dot-source the helpers (requires $script:logLines to exist)
$script:logLines = @()
. "$PSScriptRoot\..\scripts\pipeline-helpers.ps1"

Describe 'Get-Stats' {
    It 'computes avg, min, max for simple values' {
        $result = Get-Stats @(1, 2, 3, 4, 5)
        $result.avg | Should Be 3
        $result.min | Should Be 1
        $result.max | Should Be 5
    }

    It 'computes stdev correctly' {
        $result = Get-Stats @(2, 4, 4, 4, 5, 5, 7, 9)
        # Mean = 5, stdev ~ 2.0
        $result.avg | Should Be 5
        $result.stdev | Should BeGreaterThan 1.5
        $result.stdev | Should BeLessThan 2.5
    }

    It 'handles single value' {
        $result = Get-Stats @(42)
        $result.avg | Should Be 42
        $result.min | Should Be 42
        $result.max | Should Be 42
        $result.stdev | Should Be 0
    }

    It 'rounds to 4 decimal places' {
        $result = Get-Stats @(1.123456789, 2.987654321)
        # avg = 2.0556 (rounded to 4 dp)
        $result.avg | Should Be 2.0556
    }
}

Describe 'Log' {
    It 'appends to logLines buffer' {
        $script:logLines = @()
        Log 'test message'
        $script:logLines.Count | Should BeGreaterThan 0
        $script:logLines[-1] | Should Match 'test message'
    }

    It 'includes level in output' {
        $script:logLines = @()
        Log 'warning test' 'WARN'
        $script:logLines[-1] | Should Match 'WARN'
        $script:logLines[-1] | Should Match 'warning test'
    }

    It 'defaults to INFO level' {
        $script:logLines = @()
        Log 'info test'
        $script:logLines[-1] | Should Match 'INFO'
    }
}

Describe 'Test-SystemIdle' {
    It 'returns a numeric CPU average' {
        Mock Get-Counter {
            $sample = New-Object PSObject -Property @{
                CounterSamples = @(
                    (New-Object PSObject -Property @{ CookedValue = 5.0 }),
                    (New-Object PSObject -Property @{ CookedValue = 3.0 }),
                    (New-Object PSObject -Property @{ CookedValue = 4.0 })
                )
            }
            return $sample
        }

        $script:logLines = @()
        $result = Test-SystemIdle
        $result | Should BeGreaterThan 0
    }
}
