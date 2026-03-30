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
                $json.label | Should Not BeNullOrEmpty
                $json.description | Should Not BeNullOrEmpty
                $json.capturedAt | Should Not BeNullOrEmpty
                $json.durationSec | Should BeGreaterThan 0
                $json.hostname | Should Not BeNullOrEmpty
            }

            It 'has performance data' {
                $json.performance | Should Not BeNullOrEmpty
            }

            It 'has DPC time data' {
                $dpcKey = $json.performance.PSObject.Properties.Name | Where-Object { $_ -match 'dpc time.*_total' }
                $dpcKey | Should Not BeNullOrEmpty
            }

            It 'has interrupt time data' {
                $intKey = $json.performance.PSObject.Properties.Name | Where-Object { $_ -match 'interrupt time.*_total' }
                $intKey | Should Not BeNullOrEmpty
            }

            It 'has cpuData array with 16 entries (9800X3D)' {
                $json.cpuData | Should Not BeNullOrEmpty
                $json.cpuData.Count | Should Be 16
            }

            It 'has cpuData with required fields per CPU' {
                $first = $json.cpuData[0]
                ($first.PSObject.Properties.Name -contains 'cpu') | Should Be $true
                ($first.PSObject.Properties.Name -contains 'dpcPct') | Should Be $true
                ($first.PSObject.Properties.Name -contains 'interruptPct') | Should Be $true
                ($first.PSObject.Properties.Name -contains 'intrPerSec') | Should Be $true
            }

            It 'has valid capturedAt timestamp' {
                $parsed = [DateTime]::MinValue
                $valid = [DateTime]::TryParse($json.capturedAt, [ref]$parsed)
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
