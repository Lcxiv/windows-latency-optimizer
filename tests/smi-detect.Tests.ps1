# tests/smi-detect.Tests.ps1
# Pester tests for SMI blackout detection (Find-SmiBlackouts, Get-SmiCorrelation).
# PowerShell 5.1 / Pester 3.x compatible.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $here

# Load helpers (config -> logging -> smi-detect)
. "$projectRoot\scripts\config.ps1"
. "$projectRoot\scripts\helpers\logging.ps1"
. "$projectRoot\scripts\helpers\smi-detect.ps1"

# Shared log buffer for Log calls
$script:logLines = @()

# ────────────────────────────────────────────────────────────────────────────
# Helper: write a mock dpcisr report to a temp file
# ────────────────────────────────────────────────────────────────────────────
function New-MockDpcIsrReport {
    param([string[]]$Lines)
    $tmp = [System.IO.Path]::GetTempFileName()
    $Lines | Out-File $tmp -Encoding UTF8
    return $tmp
}

# ============================================================================
# Find-SmiBlackouts
# ============================================================================
Describe 'Find-SmiBlackouts' {

    Context 'Clean system (no high-latency DPCs)' {
        $report = New-MockDpcIsrReport @(
            '--------------------------'
            'DPC Info'
            '--------------------------'
            'CPU Usage from 0 us to 10000000 us:'
            ''
            'Total = 5000'
            'Elapsed Time, >        0 usecs AND <=        1 usecs,   2000, or  40.00%'
            'Elapsed Time, >        1 usecs AND <=        2 usecs,   1000, or  20.00%'
            'Elapsed Time, >        2 usecs AND <=        4 usecs,    800, or  16.00%'
            'Elapsed Time, >        4 usecs AND <=        8 usecs,    600, or  12.00%'
            'Elapsed Time, >        8 usecs AND <=       16 usecs,    400, or   8.00%'
            'Elapsed Time, >       16 usecs AND <=       32 usecs,    150, or   3.00%'
            'Elapsed Time, >       32 usecs AND <=       64 usecs,     40, or   0.80%'
            'Elapsed Time, >       64 usecs AND <=      128 usecs,     10, or   0.20%'
            'Total,                                                  5000'
            ''
            'Total = 3000 for module ntoskrnl.exe'
            'Elapsed Time, >        0 usecs AND <=        1 usecs,   1500, or  50.00%'
            'Elapsed Time, >        4 usecs AND <=        8 usecs,   1000, or  33.33%'
            'Elapsed Time, >       16 usecs AND <=       32 usecs,    500, or  16.67%'
            'Total,                                                  3000'
        )

        $result = Find-SmiBlackouts -ReportPath $report

        It 'Should return PASS verdict' {
            $result.verdict | Should Be 'PASS'
        }
        It 'Should detect zero high-latency DPCs' {
            $result.highLatencyDpcCount | Should Be 0
        }
        It 'Should have zero affected drivers' {
            $result.driversWithHighDpc | Should Be 0
        }
        It 'Should have maxBucketUs = 0' {
            $result.maxBucketUs | Should Be 0
        }
        It 'Should parse trace duration' {
            $result.traceDurationUs | Should Be 10000000
        }

        Remove-Item $report -Force -ErrorAction SilentlyContinue
    }

    Context 'Single driver with >1024us DPCs (REVIEW)' {
        $report = New-MockDpcIsrReport @(
            'CPU Usage from 0 us to 10000000 us:'
            ''
            'Total = 1000'
            'Elapsed Time, >        0 usecs AND <=        1 usecs,    900, or  90.00%'
            'Elapsed Time, >     1024 usecs AND <=     2048 usecs,      3, or   0.30%'
            'Total,                                                  1000'
            ''
            'Total = 500 for module nvlddmkm.sys'
            'Elapsed Time, >        0 usecs AND <=        1 usecs,    497, or  99.40%'
            'Elapsed Time, >     1024 usecs AND <=     2048 usecs,      3, or   0.60%'
            'Total,                                                   500'
        )

        $result = Find-SmiBlackouts -ReportPath $report

        It 'Should return REVIEW verdict' {
            $result.verdict | Should Be 'REVIEW'
        }
        It 'Should detect 3 high-latency DPCs (per-module only, no double-count)' {
            $result.highLatencyDpcCount | Should Be 3
        }
        It 'Should have maxBucketUs = 2048' {
            $result.maxBucketUs | Should Be 2048
        }
        It 'Should list nvlddmkm.sys as affected' {
            @($result.affectedDrivers | Where-Object { $_.driver -eq 'nvlddmkm.sys' }).Count | Should Be 1
        }

        Remove-Item $report -Force -ErrorAction SilentlyContinue
    }

    Context 'Multiple drivers with >1024us DPCs (FAIL)' {
        $report = New-MockDpcIsrReport @(
            'CPU Usage from 0 us to 10000000 us:'
            ''
            'Total = 2000'
            'Elapsed Time, >        0 usecs AND <=        1 usecs,   1990, or  99.50%'
            'Elapsed Time, >     1024 usecs AND <=     2048 usecs,      5, or   0.25%'
            'Elapsed Time, >     2048 usecs AND <=     4096 usecs,      3, or   0.15%'
            'Elapsed Time, >     4096 usecs AND <=     8192 usecs,      2, or   0.10%'
            'Total,                                                  2000'
            ''
            'Total = 800 for module nvlddmkm.sys'
            'Elapsed Time, >        0 usecs AND <=        1 usecs,    796, or  99.50%'
            'Elapsed Time, >     1024 usecs AND <=     2048 usecs,      2, or   0.25%'
            'Elapsed Time, >     2048 usecs AND <=     4096 usecs,      2, or   0.25%'
            'Total,                                                   800'
            ''
            'Total = 600 for module ndis.sys'
            'Elapsed Time, >        0 usecs AND <=        1 usecs,    597, or  99.50%'
            'Elapsed Time, >     1024 usecs AND <=     2048 usecs,      2, or   0.33%'
            'Elapsed Time, >     2048 usecs AND <=     4096 usecs,      1, or   0.17%'
            'Total,                                                   600'
            ''
            'Total = 400 for module dxgkrnl.sys'
            'Elapsed Time, >        0 usecs AND <=        1 usecs,    398, or  99.50%'
            'Elapsed Time, >     1024 usecs AND <=     2048 usecs,      1, or   0.25%'
            'Elapsed Time, >     4096 usecs AND <=     8192 usecs,      1, or   0.25%'
            'Total,                                                   400'
        )

        $result = Find-SmiBlackouts -ReportPath $report

        It 'Should return FAIL verdict (3+ drivers affected)' {
            $result.verdict | Should Be 'FAIL'
        }
        It 'Should have 3 affected drivers' {
            $result.driversWithHighDpc | Should Be 3
        }
        It 'Should track max bucket = 8192' {
            $result.maxBucketUs | Should Be 8192
        }

        Remove-Item $report -Force -ErrorAction SilentlyContinue
    }

    Context 'Extreme SMI (>8192us DPC in single driver = FAIL)' {
        $report = New-MockDpcIsrReport @(
            'CPU Usage from 0 us to 10000000 us:'
            ''
            'Total = 100'
            'Elapsed Time, >        0 usecs AND <=        1 usecs,     98, or  98.00%'
            'Elapsed Time, >     8192 usecs AND <=    16384 usecs,      2, or   2.00%'
            'Total,                                                   100'
            ''
            'Total = 100 for module ntoskrnl.exe'
            'Elapsed Time, >        0 usecs AND <=        1 usecs,     98, or  98.00%'
            'Elapsed Time, >     8192 usecs AND <=    16384 usecs,      2, or   2.00%'
            'Total,                                                   100'
        )

        $result = Find-SmiBlackouts -ReportPath $report

        It 'Should return FAIL verdict (>8192us)' {
            $result.verdict | Should Be 'FAIL'
        }
        It 'Should have maxBucketUs = 16384' {
            $result.maxBucketUs | Should Be 16384
        }

        Remove-Item $report -Force -ErrorAction SilentlyContinue
    }

    Context 'Missing report file' {
        $result = Find-SmiBlackouts -ReportPath 'C:\nonexistent\fake.txt'

        It 'Should return PASS verdict (graceful fallback)' {
            $result.verdict | Should Be 'PASS'
        }
        It 'Should have zero high-latency DPCs' {
            $result.highLatencyDpcCount | Should Be 0
        }
    }

    Context 'Report with ISR section boundary' {
        $report = New-MockDpcIsrReport @(
            'CPU Usage from 0 us to 5000000 us:'
            ''
            'Total = 200'
            'Elapsed Time, >        0 usecs AND <=        1 usecs,    198, or  99.00%'
            'Elapsed Time, >     1024 usecs AND <=     2048 usecs,      2, or   1.00%'
            'Total,                                                   200'
            ''
            'Total = 200 for module winhvr.sys'
            'Elapsed Time, >        0 usecs AND <=        1 usecs,    198, or  99.00%'
            'Elapsed Time, >     1024 usecs AND <=     2048 usecs,      2, or   1.00%'
            'Total,                                                   200'
            ''
            '--------------------------'
            'ISR Info'
            '--------------------------'
            'CPU Usage from 0 us to 5000000 us:'
            ''
            'Total = 100 for module hal.dll'
            'Elapsed Time, >        0 usecs AND <=        1 usecs,    100, or 100.00%'
            'Total,                                                   100'
        )

        $result = Find-SmiBlackouts -ReportPath $report

        It 'Should parse DPC section before ISR boundary' {
            @($result.affectedDrivers | Where-Object { $_.driver -eq 'winhvr.sys' }).Count | Should Be 1
        }
        It 'Should not include ISR-only modules as DPC affected drivers' {
            @($result.affectedDrivers | Where-Object { $_.driver -eq 'hal.dll' }).Count | Should Be 0
        }

        Remove-Item $report -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================================
# Get-SmiCorrelation
# ============================================================================
Describe 'Get-SmiCorrelation' {

    Context 'Normal system (DPCs on few cores)' {
        $cpuData = @(
            @{ cpu = 0; dpcPct = 8.1 }
            @{ cpu = 1; dpcPct = 0.0 }
            @{ cpu = 2; dpcPct = 0.0 }
            @{ cpu = 3; dpcPct = 0.0 }
            @{ cpu = 4; dpcPct = 0.05 }
            @{ cpu = 5; dpcPct = 0.05 }
            @{ cpu = 6; dpcPct = 0.1 }
            @{ cpu = 7; dpcPct = 0.05 }
            @{ cpu = 8; dpcPct = 0.0 }
            @{ cpu = 9; dpcPct = 0.0 }
            @{ cpu = 10; dpcPct = 0.0 }
            @{ cpu = 11; dpcPct = 0.0 }
            @{ cpu = 12; dpcPct = 0.0 }
            @{ cpu = 13; dpcPct = 0.0 }
            @{ cpu = 14; dpcPct = 0.0 }
            @{ cpu = 15; dpcPct = 0.0 }
        )

        $score = Get-SmiCorrelation -CpuData $cpuData

        It 'Should return low correlation score (DPCs on few cores)' {
            $score | Should BeLessThan 30
        }
    }

    Context 'Suspicious system (DPCs on most cores)' {
        $cpuData = @(
            @{ cpu = 0; dpcPct = 0.5 }
            @{ cpu = 1; dpcPct = 0.4 }
            @{ cpu = 2; dpcPct = 0.3 }
            @{ cpu = 3; dpcPct = 0.3 }
            @{ cpu = 4; dpcPct = 0.2 }
            @{ cpu = 5; dpcPct = 0.2 }
            @{ cpu = 6; dpcPct = 0.1 }
            @{ cpu = 7; dpcPct = 0.1 }
            @{ cpu = 8; dpcPct = 0.1 }
            @{ cpu = 9; dpcPct = 0.1 }
            @{ cpu = 10; dpcPct = 0.1 }
            @{ cpu = 11; dpcPct = 0.1 }
            @{ cpu = 12; dpcPct = 0.1 }
            @{ cpu = 13; dpcPct = 0.1 }
            @{ cpu = 14; dpcPct = 0.1 }
            @{ cpu = 15; dpcPct = 0.1 }
        )

        $score = Get-SmiCorrelation -CpuData $cpuData

        It 'Should return high correlation score (DPCs on all cores)' {
            $score | Should BeGreaterThan 40
        }
    }

    Context 'Null or empty cpuData' {
        It 'Should return 0 for null' {
            (Get-SmiCorrelation -CpuData $null) | Should Be 0
        }
        It 'Should return 0 for empty array' {
            (Get-SmiCorrelation -CpuData @()) | Should Be 0
        }
        It 'Should return 0 for single CPU' {
            (Get-SmiCorrelation -CpuData @(@{ cpu = 0; dpcPct = 5.0 })) | Should Be 0
        }
    }
}
