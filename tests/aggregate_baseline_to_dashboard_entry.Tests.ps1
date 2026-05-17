<#
.SYNOPSIS
    Pester 3.x tests for aggregate_baseline_to_dashboard_entry.ps1 — verifies
    output JSON matches dashboard v3 schema.
.DESCRIPTION
    Creates a fixture input directory with minimal JSONs and runs the aggregator
    against it. Validates that the output JSON contains all required fields and
    that missing inputs are handled gracefully (fields set to null or empty
    structures, not exceptions).
#>

$scriptPath = "$PSScriptRoot\..\scripts\aggregate_baseline_to_dashboard_entry.ps1"

Describe 'aggregate_baseline_to_dashboard_entry.ps1 — shape' {

    It 'exists' {
        Test-Path $scriptPath | Should Be $true
    }

    It 'parses without errors' {
        $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errs)
        $errs.Count | Should Be 0
    }

    It 'requires InputDir + OutputPath params' {
        $content = Get-Content $scriptPath -Raw
        $content | Should Match '\[Parameter\(Mandatory=\$true\)\][\s\S]*\$InputDir'
        $content | Should Match '\[Parameter\(Mandatory=\$true\)\][\s\S]*\$OutputPath'
    }
}

Describe 'aggregate_baseline_to_dashboard_entry.ps1 — schema validation' {

    BeforeEach {
        $fixtureDir = Join-Path $env:TEMP ('agg_test_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $runDir = Join-Path $fixtureDir 'BASELINE_TEST_20260422-100000'
        New-Item -ItemType Directory -Path (Join-Path $runDir '20_idle') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $runDir '30_loaded') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $runDir '40_aggregate') -Force | Out-Null

        # Fixture: minimal pipeline_idle.json matching real pipeline.ps1 shape
        # (performance.'% dpc time[_total]'.avg, not flat top-level DPCTimePct)
        @{
            schemaVersion = 4
            label = 'BASELINE_IDLE'
            durationSec = 60
            performance = @{
                '% dpc time[_total]' = @{ avg = 0.1; min = 0.05; max = 0.3; stdev = 0.02 }
                '% interrupt time[_total]' = @{ avg = 0.2; min = 0.1; max = 0.5; stdev = 0.05 }
                'interrupts/sec[_total]' = @{ avg = 1500; min = 1000; max = 2500; stdev = 200 }
            }
            cpuData = @(@{ cpu = 0; interruptPct = 0.3; dpcPct = 0.1; intrPerSec = 100 })
        } | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $runDir '20_idle\pipeline_idle.json')

        # Fixture: minimal xperf_idle.json matching orchestrator's new format
        # (top_drivers use total_usec/total_pct from CPU Usage By Module parse)
        @{
            phase = 'idle'
            top_drivers = @(@{ driver = 'ndis.sys'; total_usec = 50000; total_pct = 0.5 })
            total_dpcs = $null
            total_isrs = $null
            parse_source = 'CPU Usage Summing By Module'
        } | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $runDir '20_idle\xperf_idle.json')

        $outputPath = Join-Path $runDir '40_aggregate\experiment_entry.json'
    }

    AfterEach {
        if (Test-Path $fixtureDir) { Remove-Item $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'produces output JSON with all required top-level fields' {
        & $scriptPath -InputDir $runDir -OutputPath $outputPath -Label 'BASELINE_TEST' 2>&1 | Out-Null
        Test-Path $outputPath | Should Be $true
        $entry = Get-Content $outputPath -Raw | ConvertFrom-Json
        $entry.id | Should Not BeNullOrEmpty
        $entry.name | Should Be 'BASELINE_TEST'
        $entry.date | Should Match '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
        $entry.performance | Should Not BeNullOrEmpty
        $entry.systemInfo | Should Not BeNullOrEmpty
        $entry.smiAnalysis | Should Not BeNullOrEmpty
    }

    It 'populates performance.DPCTimePct from fixture' {
        & $scriptPath -InputDir $runDir -OutputPath $outputPath -Label 'BASELINE_TEST' 2>&1 | Out-Null
        $entry = Get-Content $outputPath -Raw | ConvertFrom-Json
        $entry.performance.DPCTimePct.avg | Should Be 0.1
        $entry.performance.DPCTimePct.max | Should Be 0.3
    }

    It 'populates dpcIsrAnalysis with top drivers from xperf fixture' {
        & $scriptPath -InputDir $runDir -OutputPath $outputPath -Label 'BASELINE_TEST' 2>&1 | Out-Null
        $entry = Get-Content $outputPath -Raw | ConvertFrom-Json
        $entry.dpcIsrAnalysis.topDrivers.Count | Should BeGreaterThan 0
    }

    It 'tags include baseline and generated' {
        & $scriptPath -InputDir $runDir -OutputPath $outputPath -Label 'BASELINE_TEST' 2>&1 | Out-Null
        $entry = Get-Content $outputPath -Raw | ConvertFrom-Json
        $entry.tags -contains 'baseline' | Should Be $true
        $entry.tags -contains 'generated' | Should Be $true
    }
}

Describe 'aggregate_baseline_to_dashboard_entry.ps1 — missing inputs' {

    BeforeEach {
        $fixtureDir = Join-Path $env:TEMP ('agg_empty_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $runDir = Join-Path $fixtureDir 'EMPTY_RUN_20260422-110000'
        New-Item -ItemType Directory -Path (Join-Path $runDir '20_idle') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $runDir '30_loaded') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $runDir '40_aggregate') -Force | Out-Null
        $outputPath = Join-Path $runDir '40_aggregate\experiment_entry.json'
    }

    AfterEach {
        if (Test-Path $fixtureDir) { Remove-Item $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'does not throw when all phase inputs missing' {
        { & $scriptPath -InputDir $runDir -OutputPath $outputPath 2>&1 | Out-Null } | Should Not Throw
        Test-Path $outputPath | Should Be $true
    }

    It 'latencymon is null when report missing' {
        & $scriptPath -InputDir $runDir -OutputPath $outputPath 2>&1 | Out-Null
        $entry = Get-Content $outputPath -Raw | ConvertFrom-Json
        $entry.latencymon | Should Be $null
    }
}
