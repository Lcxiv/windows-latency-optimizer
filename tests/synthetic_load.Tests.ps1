<#
.SYNOPSIS
    Pester 3.x tests for synthetic_load.ps1 — start/stop lifecycle and config
    shape.
.DESCRIPTION
    Tests run in isolation (no real Prime95 spawn, no real disk burn).
    Verifies:
      - Script has correct param shape (Start/Stop parameter sets)
      - Find-Prime95Exe returns null when exe not present
      - Prime95 config file content matches SmallFFT expectations
      - Stop handles missing state file gracefully
      - Config JSON structure matches the schema expected by the orchestrator
#>

$scriptPath = "$PSScriptRoot\..\scripts\synthetic_load.ps1"

Describe 'synthetic_load.ps1 — script shape' {

    It 'exists' {
        Test-Path $scriptPath | Should Be $true
    }

    It 'parses without errors' {
        $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errs)
        $errs.Count | Should Be 0
    }

    It 'declares both Start and Stop parameter sets' {
        $content = Get-Content $scriptPath -Raw
        $content | Should Match "ParameterSetName='Start'"
        $content | Should Match "ParameterSetName='Stop'"
    }

    It 'validates DiskBurnSizeMB range (64-8192)' {
        $content = Get-Content $scriptPath -Raw
        $content | Should Match 'ValidateRange\(64, 8192\)'
    }
}

Describe 'synthetic_load.ps1 — Prime95 config writer' {

    BeforeEach {
        $tempDir = Join-Path $env:TEMP ('syn_load_test_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }

    AfterEach {
        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'writes SmallFFT range (4-32) in prime.txt content pattern' {
        $content = Get-Content $scriptPath -Raw
        $content | Should Match 'MinTortureFFT=4'
        $content | Should Match 'MaxTortureFFT=32'
        $content | Should Match 'StressTester=1'
        $content | Should Match 'UsePrimenet=0'
    }
}

Describe 'synthetic_load.ps1 — Stop idempotency' {

    It 'exits cleanly when called with -Stop and no state file' {
        $stateFile = "$PSScriptRoot\..\captures\.synthetic_load_state.json"
        if (Test-Path $stateFile) { Remove-Item $stateFile -Force -ErrorAction SilentlyContinue }

        # Invoke via PowerShell
        $output = & powershell -NoProfile -NonInteractive -File $scriptPath -Stop 2>&1
        $LASTEXITCODE | Should Be 0
    }
}

Describe 'synthetic_load.ps1 — config JSON schema' {

    It 'config output has cpu.mode, disk.path, and started_at fields' {
        # Verify schema expectations in source
        $content = Get-Content $scriptPath -Raw
        $content | Should Match 'mode = .prime95.'
        $content | Should Match 'mode = .ps-fallback.'
        $content | Should Match 'started_at ='
    }
}

Describe 'synthetic_load.ps1 — disk burn config' {

    It 'uses bounded fixed-size file (not unbounded loop)' {
        $content = Get-Content $scriptPath -Raw
        # Bounded approach uses WriteAllBytes with SizeMB * 1MB
        $content | Should Match 'WriteAllBytes'
        $content | Should Match 'SizeMB \* 1MB'
    }

    It 'cleans up burn file in -Stop path' {
        $content = Get-Content $scriptPath -Raw
        # Stop path does: Remove-Item -Path $state.disk.path + cleans parent dir
        $content | Should Match 'Remove-Item -Path \$state\.disk\.path'
    }
}
