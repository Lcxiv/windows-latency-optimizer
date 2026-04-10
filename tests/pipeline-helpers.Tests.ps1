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

Describe 'Get-Stats edge cases' {
    It 'handles all identical values' {
        $result = Get-Stats @(5, 5, 5, 5)
        $result.avg | Should Be 5
        $result.min | Should Be 5
        $result.max | Should Be 5
        $result.stdev | Should Be 0
    }

    It 'handles negative values' {
        $result = Get-Stats @(-1, -2, -3)
        $result.avg | Should Be -2
        $result.min | Should Be -3
        $result.max | Should Be -1
    }

    It 'handles very small floating point values' {
        $result = Get-Stats @(0.0001, 0.0002, 0.0003)
        $result.avg | Should Be 0.0002
        $result.min | Should Be 0.0001
        $result.max | Should Be 0.0003
    }

    It 'handles large values' {
        $result = Get-Stats @(1000000, 2000000, 3000000)
        $result.avg | Should Be 2000000
    }

    It 'handles two values' {
        $result = Get-Stats @(10, 20)
        $result.avg | Should Be 15
        $result.min | Should Be 10
        $result.max | Should Be 20
        $result.stdev | Should BeGreaterThan 0
    }
}

Describe 'Parse-FrameCSV' {
    $tempCsvDir = Join-Path $env:TEMP 'pester_framecsv'

    BeforeEach {
        New-Item -ItemType Directory -Path $tempCsvDir -Force | Out-Null
    }

    AfterEach {
        Remove-Item $tempCsvDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'returns null for nonexistent file' {
        $result = Parse-FrameCSV -CsvPath (Join-Path $tempCsvDir 'nope.csv')
        $result | Should BeNullOrEmpty
    }

    It 'returns null for empty CSV' {
        $csvPath = Join-Path $tempCsvDir 'empty.csv'
        '' | Out-File $csvPath
        $result = Parse-FrameCSV -CsvPath $csvPath
        $result | Should BeNullOrEmpty
    }

    It 'parses MsBetweenPresents column correctly' {
        $csvPath = Join-Path $tempCsvDir 'frames.csv'
        $lines = @(
            'MsBetweenPresents,Dropped'
            '10.0,0'
            '12.0,0'
            '14.0,0'
            '16.0,0'
            '20.0,0'
        )
        $lines -join "`n" | Out-File $csvPath -Encoding UTF8
        $result = Parse-FrameCSV -CsvPath $csvPath -GameProcess 'TestGame'
        $result | Should Not BeNullOrEmpty
        $result.totalFrames | Should Be 5
        $result.processName | Should Be 'TestGame'
        $result.frameTimeMs.avg | Should BeGreaterThan 10
        $result.frameTimeMs.avg | Should BeLessThan 16
        $result.fps.avg | Should BeGreaterThan 60
    }

    It 'computes percentiles correctly' {
        $csvPath = Join-Path $tempCsvDir 'pctl.csv'
        # Generate 100 uniform frame times from 10 to 20ms
        $lines = @('MsBetweenPresents')
        for ($i = 0; $i -lt 100; $i++) {
            $ft = 10.0 + ($i * 0.1)
            $lines += "$ft"
        }
        $lines -join "`n" | Out-File $csvPath -Encoding UTF8
        $result = Parse-FrameCSV -CsvPath $csvPath

        $result.frameTimeMs.p50 | Should BeGreaterThan 14
        $result.frameTimeMs.p50 | Should BeLessThan 16
        $result.frameTimeMs.p95 | Should BeGreaterThan 18
        $result.frameTimeMs.p99 | Should BeGreaterThan 19
        $result.frameTimeMs.min | Should BeLessThan 11
    }

    It 'calculates FPS from frame times' {
        $csvPath = Join-Path $tempCsvDir 'fps.csv'
        # All 10ms frames = 100 FPS
        $lines = @('MsBetweenPresents')
        for ($i = 0; $i -lt 50; $i++) { $lines += '10.0' }
        $lines -join "`n" | Out-File $csvPath -Encoding UTF8
        $result = Parse-FrameCSV -CsvPath $csvPath

        $result.fps.avg | Should Be 100
    }

    It 'filters out invalid frame times (<=0 or >=1000)' {
        $csvPath = Join-Path $tempCsvDir 'filter.csv'
        $lines = @(
            'MsBetweenPresents'
            '10.0'
            '-5.0'
            '0'
            '1500.0'
            '12.0'
        )
        $lines -join "`n" | Out-File $csvPath -Encoding UTF8
        $result = Parse-FrameCSV -CsvPath $csvPath

        $result.totalFrames | Should Be 2
    }

    It 'detects dropped frames' {
        $csvPath = Join-Path $tempCsvDir 'dropped.csv'
        $lines = @(
            'MsBetweenPresents,Dropped'
            '10.0,0'
            '12.0,1'
            '14.0,0'
            '16.0,1'
        )
        $lines -join "`n" | Out-File $csvPath -Encoding UTF8
        $result = Parse-FrameCSV -CsvPath $csvPath

        $result.droppedFrames | Should Be 2
        $result.droppedPct | Should Be 50
    }

    It 'handles alternative column name ms_between_presents' {
        $csvPath = Join-Path $tempCsvDir 'alt.csv'
        $lines = @(
            'ms_between_presents'
            '8.0'
            '10.0'
            '12.0'
        )
        $lines -join "`n" | Out-File $csvPath -Encoding UTF8
        $result = Parse-FrameCSV -CsvPath $csvPath

        $result | Should Not BeNullOrEmpty
        $result.totalFrames | Should Be 3
    }

    It 'returns coefficient of variation' {
        $csvPath = Join-Path $tempCsvDir 'cv.csv'
        $lines = @('MsBetweenPresents')
        for ($i = 0; $i -lt 50; $i++) { $lines += '10.0' }
        $lines -join "`n" | Out-File $csvPath -Encoding UTF8
        $result = Parse-FrameCSV -CsvPath $csvPath

        # All same frame time = 0% CV
        $result.frameTimeMs.cv | Should Be 0
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
