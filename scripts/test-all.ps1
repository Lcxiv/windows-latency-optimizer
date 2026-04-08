<#
.SYNOPSIS
    Test harness — parse-check all PS scripts, validate WPRP, verify Rust builds.
.DESCRIPTION
    Smoke tests every script in the project without executing them.
    Parse-checks all .ps1 files, validates XML for .wprp profiles,
    and runs cargo check for the Tauri backend.
.EXAMPLE
    .\scripts\test-all.ps1
    .\scripts\test-all.ps1 -SkipRust
#>
param(
    [switch]$SkipRust
)

$ErrorActionPreference = 'Continue'
$failed = 0
$passed = 0
$total  = 0

Write-Host '=== LatencyGuard Test Harness ===' -ForegroundColor Cyan
Write-Host ''

# --- PS Script Parse Check ---
Write-Host '[1/3] PowerShell script parse check...' -ForegroundColor Yellow
$psFiles = Get-ChildItem scripts -Filter '*.ps1' -ErrorAction SilentlyContinue
foreach ($f in $psFiles) {
    $total++
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        Write-Host ('  FAIL: ' + $f.Name + ' (' + $errors.Count + ' errors)') -ForegroundColor Red
        foreach ($e in $errors) { Write-Host ('    ' + $e.Message) -ForegroundColor Red }
        $failed++
    } else {
        Write-Host ('  PASS: ' + $f.Name) -ForegroundColor Green
        $passed++
    }
}

# --- WPR Profile Validation ---
Write-Host ''
Write-Host '[2/3] WPR profile XML validation...' -ForegroundColor Yellow
$wprpFiles = Get-ChildItem scripts -Filter '*.wprp' -ErrorAction SilentlyContinue
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

# --- Rust Build Check ---
if (-not $SkipRust) {
    Write-Host ''
    Write-Host '[3/3] Rust cargo check...' -ForegroundColor Yellow
    $total++
    $cargoDir = 'latencyguard\src-tauri'
    if (Test-Path (Join-Path $cargoDir 'Cargo.toml')) {
        Push-Location $cargoDir
        $cargoOutput = cargo check 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            Write-Host '  PASS: cargo check' -ForegroundColor Green
            $passed++
        } else {
            Write-Host '  FAIL: cargo check' -ForegroundColor Red
            Write-Host $cargoOutput
            $failed++
        }
        Pop-Location
    } else {
        Write-Host '  SKIP: Cargo.toml not found' -ForegroundColor Yellow
        $total--
    }
} else {
    Write-Host ''
    Write-Host '[3/3] Rust cargo check... SKIPPED' -ForegroundColor Yellow
}

# --- Summary ---
Write-Host ''
Write-Host '=== RESULTS ===' -ForegroundColor Cyan
Write-Host ('  Total:  ' + $total)
Write-Host ('  Passed: ' + $passed) -ForegroundColor Green
Write-Host ('  Failed: ' + $failed) -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })
Write-Host ''

if ($failed -gt 0) {
    Write-Host 'TESTS FAILED' -ForegroundColor Red
    exit 1
} else {
    Write-Host 'ALL TESTS PASSED' -ForegroundColor Green
}
