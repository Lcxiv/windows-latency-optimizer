#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Nsight Systems GPU-CPU correlation capture for latency diagnosis.
.DESCRIPTION
    Automates nsys profiling with DPC/ISR + WDDM GPU scheduling events.
    Captures a unified GPU-CPU timeline that shows exactly which GPU operations
    trigger DPC stalls affecting mouse input. Exports results to SQLite and JSON.
    Requires Nsight Systems installed (free from NVIDIA Developer).
.EXAMPLE
    .\profile-nsight.ps1
    .\profile-nsight.ps1 -DurationSec 30 -GameProcess "FortniteClient-Win64-Shipping_EAC_EOS.exe"
#>
param(
    [int]$DurationSec = 15,
    [string]$GameProcess = ''
)

$ErrorActionPreference = 'Stop'
$scriptsDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$projectDir = Split-Path $scriptsDir -Parent

Write-Host ''
Write-Host '=== Nsight Systems GPU-CPU Profile ===' -ForegroundColor Cyan
Write-Host ('Duration: ' + $DurationSec + 's')
Write-Host ''

# --- Step 1: Find nsys ---
Write-Host '[1/4] Locating Nsight Systems...' -ForegroundColor Yellow
$nsysPath = $null
$nsightBase = 'C:\Program Files\NVIDIA Corporation'
$nsightDirs = @(Get-ChildItem -Path $nsightBase -Filter 'Nsight Systems*' -Directory -ErrorAction SilentlyContinue)
foreach ($d in $nsightDirs) {
    $candidate = Join-Path $d.FullName 'target-windows-x64\nsys.exe'
    if (Test-Path $candidate) {
        $nsysPath = $candidate
        break
    }
}

if (-not $nsysPath) {
    Write-Host '  Nsight Systems not found.' -ForegroundColor Red
    Write-Host '  Download (free): https://developer.nvidia.com/nsight-systems/get-started' -ForegroundColor Yellow
    Write-Host '  Install, then re-run this script.' -ForegroundColor Yellow
    return @{ error = 'Nsight Systems not installed' }
}

$versionOutput = & $nsysPath --version 2>&1
Write-Host ('  Found: ' + $nsysPath) -ForegroundColor Green
Write-Host ('  Version: ' + $versionOutput)

# --- Step 2: Capture ---
Write-Host ''
Write-Host '[2/4] Starting capture...' -ForegroundColor Yellow

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outDir = Join-Path $projectDir ('captures\experiments\' + $timestamp + '_NSIGHT')
if (-not (Test-Path $outDir)) { New-Item -Path $outDir -ItemType Directory -Force | Out-Null }

$outputBase = Join-Path $outDir 'nsight_profile'

$nsysArgs = @(
    'profile',
    '--trace=wddm,dx12',
    '--isr=true',
    '--wddm-additional-events=true',
    '--wddm-memory-trace=false',
    '--sample=system-wide',
    ('--duration=' + $DurationSec),
    '--stats=true',
    '--export=sqlite',
    ('--output=' + $outputBase),
    '--force-overwrite=true',
    '--system-wide=true'
)

if ($GameProcess -ne '') {
    Write-Host ('  Target: ' + $GameProcess) -ForegroundColor Cyan
    # nsys will profile system-wide but can focus stats on the game
}

Write-Host '  Running nsys profile... (move mouse, play game during capture)' -ForegroundColor Cyan
$nsysOutput = & $nsysPath $nsysArgs 2>&1
$nsysOutputText = $nsysOutput | Out-String
# Show output lines (filter progress bars)
foreach ($line in ($nsysOutput | Where-Object { $_ -notmatch '^\s*\[[\d/]+\]\s*\[' })) {
    Write-Host ('  ' + $line)
}
# Check for fatal errors (not SKIPPED warnings about NVTX)
if ($LASTEXITCODE -ne 0 -and $nsysOutputText -notmatch 'SKIPPED.*NVTX') {
    Write-Host ('  nsys failed (exit ' + $LASTEXITCODE + ')') -ForegroundColor Red
    return @{ error = ($nsysOutputText -replace '\s+', ' ').Trim() }
}

# --- Step 3: Parse results ---
Write-Host ''
Write-Host '[3/4] Parsing results...' -ForegroundColor Yellow

$result = [ordered]@{
    tool        = 'nsight-systems'
    version     = $versionOutput
    capturedAt  = (Get-Date).ToString('o')
    durationSec = $DurationSec
    outputDir   = $outDir
    nsysRep     = ''
    sqliteDb    = ''
    stats       = @{}
}

# Find output files
$repFile = $outputBase + '.nsys-rep'
$sqlFile = $outputBase + '.sqlite'
if (Test-Path $repFile) {
    $result.nsysRep = $repFile
    $repSize = [math]::Round((Get-Item $repFile).Length / 1MB, 1)
    Write-Host ('  Report: ' + $repFile + ' (' + $repSize + ' MB)') -ForegroundColor Green
}
if (Test-Path $sqlFile) {
    $result.sqliteDb = $sqlFile
    Write-Host ('  SQLite: ' + $sqlFile) -ForegroundColor Green
}

# Try to extract stats from nsys stats output
$statsFile = Join-Path $outDir 'nsight_stats.txt'
try {
    $statsOutput = & $nsysPath stats $repFile 2>&1
    $statsOutput | Out-File -FilePath $statsFile -Encoding UTF8
    Write-Host ('  Stats: ' + $statsFile) -ForegroundColor Green

    # Parse key metrics from stats output
    $statsText = $statsOutput | Out-String
    if ($statsText -match 'GPU Utilization.*?(\d+\.?\d*)%') {
        $result.stats['gpuUtilization'] = $Matches[1]
    }
} catch {
    Write-Host '  Stats extraction failed (non-critical)' -ForegroundColor Yellow
}

# --- Step 4: Summary ---
Write-Host ''
Write-Host '[4/4] Summary' -ForegroundColor Yellow

$jsonPath = Join-Path $outDir 'nsight_profile.json'
($result | ConvertTo-Json -Depth 6) | Out-File -FilePath $jsonPath -Encoding UTF8
Write-Host ('  JSON: ' + $jsonPath) -ForegroundColor Green

Write-Host ''
Write-Host '=== RESULTS ===' -ForegroundColor Cyan
Write-Host ('  Profile saved to: ' + $outDir)
Write-Host ''
Write-Host '  To analyze visually:' -ForegroundColor Cyan

# Find nsight GUI
$nsightGuiDirs = @(Get-ChildItem -Path $nsightBase -Filter 'Nsight Systems*' -Directory -ErrorAction SilentlyContinue)
$guiPath = ''
foreach ($d in $nsightGuiDirs) {
    $candidate = Join-Path $d.FullName 'host-windows-x64\nsight-sys.exe'
    if (Test-Path $candidate) { $guiPath = $candidate; break }
}
if ($guiPath -ne '' -and $result.nsysRep -ne '') {
    Write-Host ('    "' + $guiPath + '" "' + $result.nsysRep + '"') -ForegroundColor Cyan
} else {
    Write-Host '    Open .nsys-rep file in Nsight Systems GUI'
}

Write-Host ''
Write-Host '  Key things to check in the timeline:' -ForegroundColor Yellow
Write-Host '    1. GPU Hardware Queue — look for preemption DMA packets (black)'
Write-Host '    2. ISR/DPC rows — correlate with GPU work completion'
Write-Host '    3. Frame Health row — auto-flagged slow/stuttery frames'
Write-Host '    4. WDDM HW Scheduler — context switch timing'
Write-Host ''
Write-Host 'Done.' -ForegroundColor Cyan

return $result
