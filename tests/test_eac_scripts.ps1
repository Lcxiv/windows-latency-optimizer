<#
.SYNOPSIS
    Smoke tests for EAC mitigation scripts. Plain PowerShell — no Pester dependency.
.DESCRIPTION
    Tests:
      - Parse cleanly (PS AST)
      - Help block present
      - Required parameters declared
      - Idempotency contract (apply scripts re-run safely on -WhatIf)
      - Manifest/state file shape

    Run from repo root:
      .\tests\test_eac_scripts.ps1
#>

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$results = New-Object System.Collections.Generic.List[object]

function Test-Case {
    param(
        [string]$Name,
        [scriptblock]$Block
    )
    try {
        & $Block
        $script:results.Add([pscustomobject]@{ Name=$Name; Status='PASS'; Detail='' })
        Write-Host ('  PASS: ' + $Name) -ForegroundColor Green
    } catch {
        $script:results.Add([pscustomobject]@{ Name=$Name; Status='FAIL'; Detail=$_.Exception.Message })
        Write-Host ('  FAIL: ' + $Name) -ForegroundColor Red
        Write-Host ('         ' + $_.Exception.Message) -ForegroundColor DarkRed
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message = 'Assertion failed')
    if (-not $Condition) { throw $Message }
}

function Assert-Contains {
    param([string]$Haystack, [string]$Needle, [string]$Message = '')
    if (-not $Haystack.Contains($Needle)) {
        throw ($Message + ' (expected to contain "' + $Needle + '")')
    }
}

# ---- Discover scripts ----
$scripts = @(
    'scripts\eac_baseline_capture.ps1',
    'scripts\analyze_eac_dpcs.ps1',
    'scripts\eac_phase2_defender_apply.ps1',
    'scripts\eac_phase2_defender_rollback.ps1',
    'scripts\eac_phase3_gamemode_quiet_apply.ps1',
    'scripts\eac_phase3_gamemode_quiet_rollback.ps1',
    'scripts\eac_phase4a_launch_fortnite_pinned.ps1',
    'scripts\eac_phase5_storage_path_bench.ps1',
    'scripts\eac_orchestrator.ps1'
)

# ---- Parse cleanly ----
Write-Host ''
Write-Host '== AST Parse ==' -ForegroundColor Cyan
foreach ($s in $scripts) {
    Test-Case -Name ('parse: ' + $s) -Block {
        Assert-True (Test-Path $s) ('Script missing: ' + $s)
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $s).Path, [ref]$null, [ref]$errs)
        Assert-True ($errs.Count -eq 0) ('Parse errors: ' + ($errs | Out-String))
    }
}

# ---- Help block present ----
Write-Host ''
Write-Host '== Help Block ==' -ForegroundColor Cyan
foreach ($s in $scripts) {
    Test-Case -Name ('help: ' + $s) -Block {
        $content = Get-Content $s -Raw
        Assert-Contains $content '.SYNOPSIS' 'Missing .SYNOPSIS'
        Assert-Contains $content '.DESCRIPTION' 'Missing .DESCRIPTION'
    }
}

# ---- Apply scripts must declare ShouldProcess ----
Write-Host ''
Write-Host '== ShouldProcess (apply scripts) ==' -ForegroundColor Cyan
$applyScripts = $scripts | Where-Object { $_ -match 'apply\.ps1$' }
foreach ($s in $applyScripts) {
    Test-Case -Name ('shouldprocess: ' + $s) -Block {
        $content = Get-Content $s -Raw
        Assert-Contains $content 'SupportsShouldProcess' 'Missing SupportsShouldProcess attribute'
        Assert-Contains $content 'ShouldProcess' 'Missing $PSCmdlet.ShouldProcess() call'
    }
}

# ---- Rollback scripts must declare ManifestFile or StateFile parameter ----
Write-Host ''
Write-Host '== Rollback Parameter Contract ==' -ForegroundColor Cyan
$rollbackScripts = $scripts | Where-Object { $_ -match 'rollback\.ps1$' }
foreach ($s in $rollbackScripts) {
    Test-Case -Name ('rollback param: ' + $s) -Block {
        $content = Get-Content $s -Raw
        $hasManifest = $content -match '\$ManifestFile'
        $hasStateFile = $content -match '\$StateFile'
        Assert-True ($hasManifest -or $hasStateFile) 'Rollback must take -ManifestFile or -StateFile'
        Assert-Contains $content 'Mandatory=$true' 'Rollback parameter must be Mandatory'
    }
}

# ---- Apply scripts must persist a manifest/state file ----
Write-Host ''
Write-Host '== Apply Persists Manifest ==' -ForegroundColor Cyan
foreach ($s in $applyScripts) {
    Test-Case -Name ('manifest: ' + $s) -Block {
        $content = Get-Content $s -Raw
        Assert-Contains $content 'ConvertTo-Json' 'Apply must serialize state via ConvertTo-Json'
        $writesFile = ($content -match 'Out-File|Set-Content')
        Assert-True $writesFile 'Apply must write manifest/state file'
    }
}

# ---- PS 5.1 pitfalls absent ----
Write-Host ''
Write-Host '== PS 5.1 Pitfalls ==' -ForegroundColor Cyan
foreach ($s in $scripts) {
    Test-Case -Name ('ps5.1: ' + $s) -Block {
        $content = Get-Content $s -Raw
        # ternary
        if ($content -match '\$\w+\s*\?\s*\S+\s*:\s*\S+') { throw 'Ternary operator detected (PS 7 only)' }
        # null-coalescing
        if ($content -match '\?\?') { throw 'Null-coalescing detected (PS 7 only)' }
        # Measure-Object -StandardDeviation
        if ($content -match 'Measure-Object[^\r\n]*-StandardDeviation') { throw '-StandardDeviation not in PS 5.1' }
        # Reserved automatic variables as user vars
        if ($content -match '\$error\s*=\s*[^=]') { throw 'Assigning $error (reserved automatic variable)' }
    }
}

# ---- Idempotency: apply -WhatIf does not error or mutate ----
Write-Host ''
Write-Host '== Idempotency (-WhatIf smoke) ==' -ForegroundColor Cyan
# Skipping live -WhatIf invocation: requires admin + Defender mock.
# Static check: -WhatIf advertised in CmdletBinding
foreach ($s in $applyScripts) {
    Test-Case -Name ('whatif advertised: ' + $s) -Block {
        $content = Get-Content $s -Raw
        $hasCmdletBinding = ($content -match '\[CmdletBinding\(SupportsShouldProcess')
        Assert-True $hasCmdletBinding '[CmdletBinding(SupportsShouldProcess=$true)] missing — -WhatIf wont propagate'
    }
}

# ---- Summary ----
Write-Host ''
Write-Host '== Summary ==' -ForegroundColor Cyan
$pass = ($results | Where-Object { $_.Status -eq 'PASS' }).Count
$fail = ($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$failColor = 'Green'
if ($fail -gt 0) { $failColor = 'Red' }
Write-Host ('PASS: ' + $pass) -ForegroundColor Green
Write-Host ('FAIL: ' + $fail) -ForegroundColor $failColor

if ($fail -gt 0) {
    Write-Host ''
    Write-Host 'Failed tests:' -ForegroundColor Red
    $results | Where-Object { $_.Status -eq 'FAIL' } | ForEach-Object {
        Write-Host ('  - ' + $_.Name + ': ' + $_.Detail) -ForegroundColor Red
    }
    exit 1
}

exit 0
