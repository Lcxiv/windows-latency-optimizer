<#
.SYNOPSIS
    Pester 3.x tests validating experiment.json schema and data integrity.
.DESCRIPTION
    Validates all captured experiment.json files have required fields,
    valid data types, and consistent structure.
    Run: Invoke-Pester .\tests\experiment-json.Tests.ps1
#>

$experimentsDir = "$PSScriptRoot\..\captures\experiments"

Describe 'Experiment JSON Schema Validation' {
    $jsonFiles = Get-ChildItem $experimentsDir -Recurse -Filter 'experiment.json' -ErrorAction SilentlyContinue

    It 'has at least one experiment capture' {
        $jsonFiles.Count | Should BeGreaterThan 0
    }

    foreach ($file in $jsonFiles) {
        $expName = Split-Path (Split-Path $file.FullName -Parent) -Leaf

        Context "Experiment: $expName" {
            $json = $null
            try {
                $content = Get-Content $file.FullName -Raw
                $json = $content | ConvertFrom-Json
            } catch {
                # Will fail in the It block below
            }

            It 'is valid JSON' {
                $json | Should Not BeNullOrEmpty
            }

            It 'has required top-level fields' {
                # Two schemas coexist in captures/experiments/:
                #   A) pipeline.ps1 per-experiment: { label, capturedAt, durationSec, hostname, ... }
                #   B) dashboard-entry / baseline aggregate: { name, date, systemInfo.hostname, ... }
                # Accept either — both are valid consumers of the dashboard.
                $labelOrName = if ($json.label) { $json.label } else { $json.name }
                $labelOrName | Should Not BeNullOrEmpty

                $json.description | Should Not BeNullOrEmpty

                $timestamp = if ($json.capturedAt) { $json.capturedAt } else { $json.date }
                $timestamp | Should Not BeNullOrEmpty

                $hostname = if ($json.hostname) { $json.hostname } else { $json.systemInfo.hostname }
                $hostname | Should Not BeNullOrEmpty

                # durationSec is Shape A only — conditional check
                if ($json.PSObject.Properties.Name -contains 'durationSec') {
                    $json.durationSec | Should BeGreaterThan 0
                }
            }

            It 'has performance data' {
                $json.performance | Should Not BeNullOrEmpty
            }

            It 'has DPC time data' {
                # Shape A: "% dpc time[_total]"  |  Shape B: "DPCTimePct"
                $dpcKey = $json.performance.PSObject.Properties.Name | Where-Object {
                    $_ -match 'dpc time.*_total' -or $_ -eq 'DPCTimePct'
                }
                $dpcKey | Should Not BeNullOrEmpty
            }

            It 'has interrupt time data' {
                # Shape A: "% interrupt time[_total]"  |  Shape B: "InterruptTimePct"
                $intKey = $json.performance.PSObject.Properties.Name | Where-Object {
                    $_ -match 'interrupt time.*_total' -or $_ -eq 'InterruptTimePct'
                }
                $intKey | Should Not BeNullOrEmpty
            }

            It 'has cpuData array with entries' {
                $json.cpuData | Should Not BeNullOrEmpty
                $json.cpuData.Count | Should BeGreaterThan 0
            }

            It 'has cpuData with required fields per CPU' {
                $first = $json.cpuData[0]
                ($first.PSObject.Properties.Name -contains 'cpu') | Should Be $true
                ($first.PSObject.Properties.Name -contains 'dpcPct') | Should Be $true
                ($first.PSObject.Properties.Name -contains 'interruptPct') | Should Be $true
                ($first.PSObject.Properties.Name -contains 'intrPerSec') | Should Be $true
            }

            It 'has valid capturedAt timestamp' {
                # Shape A uses capturedAt, Shape B uses date — parse whichever is present.
                $timestamp = if ($json.capturedAt) { $json.capturedAt } else { $json.date }
                $parsed = [DateTime]::MinValue
                $valid = [DateTime]::TryParse($timestamp, [ref]$parsed)
                $valid | Should Be $true
            }

            It 'has registry snapshot' {
                $json.registry | Should Not BeNullOrEmpty
            }

            It 'has no negative DPC/interrupt percentages' {
                foreach ($cpu in $json.cpuData) {
                    $cpu.dpcPct | Should BeGreaterThan -0.001
                    $cpu.interruptPct | Should BeGreaterThan -0.001
                }
            }
        }
    }
}
