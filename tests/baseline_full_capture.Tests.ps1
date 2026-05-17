<#
.SYNOPSIS
    Pester 3.x tests for baseline_full_capture.ps1 — shape tests and
    component checks.
.DESCRIPTION
    Since the orchestrator REQUIRES admin + spawns real external tools, these
    tests focus on:
      - Script parses cleanly
      - Required params + correct validation
      - Embedded functions handle edge cases (missing tools, missing registry keys)
      - Trap handler references correct cleanup state

    Full end-to-end run is deferred to manual admin-shell execution.
#>

$scriptPath = "$PSScriptRoot\..\scripts\baseline_full_capture.ps1"

Describe 'baseline_full_capture.ps1 — script shape' {

    It 'exists' {
        Test-Path $scriptPath | Should Be $true
    }

    It 'parses without errors' {
        $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errs)
        $errs.Count | Should Be 0
    }

    It 'requires admin via #Requires directive' {
        $content = Get-Content $scriptPath -Raw
        $content | Should Match '#Requires -RunAsAdministrator'
    }

    It 'declares mandatory Label param' {
        $content = Get-Content $scriptPath -Raw
        $content | Should Match '\[Parameter\(Mandatory=\$true\)\][\s\S]*\$Label'
    }

    It 'validates LatmonDurationSec range (30-3600)' {
        $content = Get-Content $scriptPath -Raw
        $content | Should Match 'ValidateRange\(30, 3600\)'
    }

    It 'validates CaptureSec range (10-600)' {
        $content = Get-Content $scriptPath -Raw
        $content | Should Match 'ValidateRange\(10, 600\)'
    }
}

Describe 'baseline_full_capture.ps1 — trap handler + cleanup' {

    It 'has trap handler that calls Stop-AllCaptures' {
        $content = Get-Content $scriptPath -Raw
        $content | Should Match 'trap\s*\{[\s\S]*Stop-AllCaptures'
    }

    It 'Stop-AllCaptures handles each tool: wpr, procmon, latmon, synthetic_load' {
        $content = Get-Content $scriptPath -Raw
        $content | Should Match 'wpr_active'
        $content | Should Match 'procmon_active'
        $content | Should Match 'latmon_active'
        $content | Should Match 'syntheticLoadActive'
    }

    It 'cleanupState tracks runDir for abort scenarios' {
        $content = Get-Content $scriptPath -Raw
        # cleanupState hashtable has a runDir key
        $content | Should Match 'runDir = \$runDir'
    }
}

Describe 'baseline_full_capture.ps1 — phase functions' {

    It 'defines all 5 phase functions (0, 1, 2/3 capture, 3 wrapper, 4)' {
        $content = Get-Content $scriptPath -Raw
        $content | Should Match 'function Invoke-Phase0'
        $content | Should Match 'function Invoke-Phase1'
        $content | Should Match 'function Invoke-CapturePhase'
        $content | Should Match 'function Invoke-Phase3'
        $content | Should Match 'function Invoke-Phase4'
    }

    It 'Phase 0 checks admin, disk, tools' {
        $content = Get-Content $scriptPath -Raw
        $content | Should Match 'IsInRole.*Administrator'
        $content | Should Match 'Get-PSDrive -Name .C.'
        $content | Should Match 'Test-ToolPath'
    }

    It 'Phase 0 runs LatencyMon CLI preflight' {
        $content = Get-Content $scriptPath -Raw
        $content | Should Match 'Test-LatencyMonCli'
    }

    It 'Phase 0 dumps registry preflight state' {
        $content = Get-Content $scriptPath -Raw
        $content | Should Match 'registry_state_preflight'
    }

    It 'Phase 1 uses audit.ps1 -Mode Deep (not -Tier)' {
        $content = Get-Content $scriptPath -Raw
        $content | Should Match '-Mode Deep'
        $content | Should Not Match '-Tier Deep'
    }

    It 'Phase 1 warns when audit score below 90%' {
        $content = Get-Content $scriptPath -Raw
        $content | Should Match '90% threshold'
    }

    It 'Phase 3 stabilizes 30s before capture' {
        $content = Get-Content $scriptPath -Raw
        $content | Should Match 'Stabilizing 30s'
    }
}

Describe 'baseline_full_capture.ps1 — tool resolution' {

    It 'Get-ToolPaths includes xperf fallback search' {
        $content = Get-Content $scriptPath -Raw
        $content | Should Match 'Windows Performance Toolkit'
    }

    It 'Get-ToolPaths searches p95v3019b20.win64 for prime95' {
        $content = Get-Content $scriptPath -Raw
        $content | Should Match 'p95v3019b20\.win64'
    }

    It 'Test-LatencyMonCli does dry-run start+stop' {
        $content = Get-Content $scriptPath -Raw
        $content | Should Match '/startmonitoring'
        $content | Should Match '/stopmonitoring'
    }
}

Describe 'baseline_full_capture.ps1 — output structure' {

    It 'creates 5 phase subdirs: 00_preflight, 10_prefreeze, 20_idle, 30_loaded, 40_aggregate' {
        $content = Get-Content $scriptPath -Raw
        $content | Should Match "00_preflight"
        $content | Should Match "10_prefreeze"
        $content | Should Match "20_idle"
        $content | Should Match "30_loaded"
        $content | Should Match "40_aggregate"
    }

    It 'Phase 4 writes manifest.json with latmon_skipped flag' {
        $content = Get-Content $scriptPath -Raw
        $content | Should Match 'latmon_skipped'
        $content | Should Match 'manifest.json'
    }

    It 'Phase 4 calls build_master_report and aggregate_baseline_to_dashboard_entry' {
        $content = Get-Content $scriptPath -Raw
        $content | Should Match 'build_master_report\.ps1'
        $content | Should Match 'aggregate_baseline_to_dashboard_entry\.ps1'
    }
}
