<#
.SYNOPSIS
    Run any script with admin elevation and capture output to a file.
.DESCRIPTION
    Replaces the 5 separate run_*.ps1 wrapper scripts. Handles UAC elevation
    via Start-Process -Verb RunAs and redirects all output streams to a file.
.EXAMPLE
    .\invoke-elevated.ps1 -Script .\reboot_capture.ps1 -Arguments '-Phase After'
    .\invoke-elevated.ps1 -Script .\disable_razer_startup.ps1
    .\invoke-elevated.ps1 -Script .\audio_fix_and_audit.ps1 -Arguments '-All -CaptureDurationSec 10'
    .\invoke-elevated.ps1 -Script .\reboot_capture.ps1 -Arguments '-Phase Before' -OutputFile 'C:\custom\output.txt'
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$Script,

    [string]$Arguments = '',

    [string]$OutputFile = ''
)

# Resolve script path
if (-not [System.IO.Path]::IsPathRooted($Script)) {
    $Script = Join-Path $PWD $Script
}

if (-not (Test-Path $Script)) {
    Write-Host "ERROR: Script not found: $Script" -ForegroundColor Red
    exit 1
}

# Auto-generate output file name if not specified
if (-not $OutputFile) {
    $captureDir = Join-Path (Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent) 'captures'
    $scriptBaseName = [System.IO.Path]::GetFileNameWithoutExtension($Script)
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $OutputFile = Join-Path $captureDir ($scriptBaseName + '_output_' + $timestamp + '.txt')
}

# Ensure output directory exists
$outDir = Split-Path $OutputFile -Parent
if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

Write-Host "Running elevated: $Script $Arguments" -ForegroundColor Cyan
Write-Host "Output: $OutputFile" -ForegroundColor DarkGray

# Build the command to run elevated
$cmd = "& '$Script'"
if ($Arguments) {
    $cmd = "& '$Script' $Arguments"
}
$cmd = $cmd + " *>&1 | Out-File '$OutputFile' -Encoding UTF8"

# Launch elevated and wait
Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -Command `"$cmd`"" -Wait

if (Test-Path $OutputFile) {
    $size = [math]::Round((Get-Item $OutputFile).Length / 1KB, 1)
    Write-Host "Done. Results ($size KB): $OutputFile" -ForegroundColor Green
} else {
    Write-Host "WARNING: Output file not created. Script may have failed." -ForegroundColor Yellow
}
