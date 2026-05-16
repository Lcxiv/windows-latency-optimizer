<#
.SYNOPSIS
    Test harness — parse-check all PS scripts and validate WPR profile XML.
.DESCRIPTION
    Smoke tests every script in the project without executing them.
    Parse-checks all .ps1 files under scripts/ (recursive) and validates
    XML for .wprp profiles. Pester suites under tests/ are run separately
    via `Invoke-Pester -Path tests`.
.EXAMPLE
    .\scripts\test-all.ps1
#>

$ErrorActionPreference = 'Continue'
$failed = 0
$passed = 0
$total  = 0

Write-Host '=== Windows Latency Optimizer — Test Harness ===' -ForegroundColor Cyan
Write-Host ''

# --- PS Script Parse Check (recursive across scripts/) ---
Write-Host '[1/2] PowerShell script parse check...' -ForegroundColor Yellow
$psFiles = Get-ChildItem scripts -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue
foreach ($f in $psFiles) {
    $total++
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        $rel = $f.FullName.Substring($PWD.Path.Length + 1)
        Write-Host ('  FAIL: ' + $rel + ' (' + $errors.Count + ' errors)') -ForegroundColor Red
        foreach ($e in $errors) { Write-Host ('    ' + $e.Message) -ForegroundColor Red }
        $failed++
    } else {
        $passed++
    }
}
Write-Host ('  ' + $passed + ' / ' + $total + ' PowerShell files parse cleanly.') -ForegroundColor Green

# --- WPR Profile Validation ---
Write-Host ''
Write-Host '[2/2] WPR profile XML validation...' -ForegroundColor Yellow
$wprpFiles = Get-ChildItem scripts -Recurse -Filter '*.wprp' -ErrorAction SilentlyContinue
foreach ($f in $wprpFiles) {
    $total++
    try {
        [xml](Get-Content $f.FullName) | Out-Null
        Write-Host ('  PASS: ' + $f.Name) -ForegroundColor Green
        $passed++
    } catch {
        Write-Host ('  FAIL: ' + $f.Name + ' — ' + $_.Exception.Message) -ForegroundColor Red
        $failed++
    }
}

# --- Summary ---
Write-Host ''
Write-Host '=== RESULTS ===' -ForegroundColor Cyan
Write-Host ('  Total:  ' + $total)
Write-Host ('  Passed: ' + $passed) -ForegroundColor Green
$failColor = if ($failed -gt 0) { 'Red' } else { 'Green' }
Write-Host ('  Failed: ' + $failed) -ForegroundColor $failColor
Write-Host ''

if ($failed -gt 0) {
    Write-Host 'TESTS FAILED' -ForegroundColor Red
    exit 1
} else {
    Write-Host 'ALL TESTS PASSED' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Run Pester suite with:  Invoke-Pester -Path tests' -ForegroundColor DarkGray
}
