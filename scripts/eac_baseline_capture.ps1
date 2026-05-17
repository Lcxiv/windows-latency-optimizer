<#
.SYNOPSIS
    Capture EAC DPC baseline during Fortnite gameplay (Phase 1 of mitigation plan).
.DESCRIPTION
    Orchestrates WPR (DPC + File-I/O), xperf (DPC/ISR by driver), per-CPU perf counters,
    and CapFrameX (manual side-trigger). Read-only — no system mutation.

    Output directory: captures/experiments/exp-eac-baseline-fortnite-{Tag}/

    Required: Run as Administrator. Fortnite session active during DurationSec window.

.PARAMETER Tag
    Capture tag (e.g. "pre-exclusion", "post-exclusion", "after-quietmode").

.PARAMETER DurationSec
    Capture window seconds. Default 300 (5 min). Use 600 for full match.

.PARAMETER SkipWPR
    Skip WPR trace (faster, smaller output). xperf + perf counters still captured.

.EXAMPLE
    .\eac_baseline_capture.ps1 -Tag pre-exclusion -DurationSec 300
#>
#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$Tag,

    [ValidateRange(60, 1800)]
    [int]$DurationSec = 300,

    [switch]$SkipWPR
)

$ErrorActionPreference = 'Stop'

# ---- Setup ----
$repoRoot = Split-Path -Parent $PSScriptRoot
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outDirName = 'exp-eac-baseline-fortnite-' + $Tag + '_' + $timestamp
$outDir = Join-Path $repoRoot ('captures\experiments\' + $outDirName)
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$wptRoot = 'C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit'
$xperfExe = Join-Path $wptRoot 'xperf.exe'
$wprExe = 'C:\Windows\System32\wpr.exe'

if (-not (Test-Path $xperfExe)) {
    Write-Error 'xperf.exe not found. Install Windows Performance Toolkit (Windows ADK).'
    exit 1
}

# ---- Run metadata ----
$meta = [ordered]@{
    tag             = $Tag
    timestamp       = $timestamp
    durationSec     = $DurationSec
    skipWPR         = [bool]$SkipWPR
    fortniteBuild   = $null
    eacVersion      = $null
    defenderSigDate = $null
    osBuild         = (Get-CimInstance Win32_OperatingSystem).BuildNumber
    cpu             = (Get-CimInstance Win32_Processor).Name
    gpu             = (Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic Display' } | Select-Object -First 1).Name
    machineName     = $env:COMPUTERNAME
}

# Detect Fortnite build
$fortniteVer = Get-ChildItem 'C:\Program Files\Epic Games\Fortnite\FortniteGame\Binaries\Win64\FortniteClient-Win64-Shipping.exe' -ErrorAction SilentlyContinue
if ($fortniteVer) {
    $meta.fortniteBuild = $fortniteVer.VersionInfo.FileVersion
}

# Detect EAC version
$eacExe = Get-ChildItem 'C:\Program Files (x86)\EasyAntiCheat_EOS\EasyAntiCheat_EOS.exe' -ErrorAction SilentlyContinue
if ($eacExe) {
    $meta.eacVersion = $eacExe.VersionInfo.FileVersion
}

# Defender sig date
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    $meta.defenderSigDate = $mp.AntivirusSignatureLastUpdated.ToString('o')
} catch {
    $meta.defenderSigDate = 'unavailable'
}

$meta | ConvertTo-Json -Depth 3 | Out-File -FilePath (Join-Path $outDir 'run_meta.json') -Encoding utf8
Write-Host '=== EAC Baseline Capture ===' -ForegroundColor Cyan
Write-Host ('Tag: ' + $Tag)
Write-Host ('Duration: ' + $DurationSec + 's')
Write-Host ('Output: ' + $outDir)
Write-Host ''

# ---- Pre-flight: minifilter snapshot ----
Write-Host 'Capturing minifilter snapshot...'
fltmc instances 2>&1 | Out-File -FilePath (Join-Path $outDir 'fltmc_instances.txt') -Encoding utf8
fltmc filters 2>&1 | Out-File -FilePath (Join-Path $outDir 'fltmc_filters.txt') -Encoding utf8

# ---- xperf trace start ----
Write-Host 'Starting xperf trace (DPC + ISR + FILE_IO + CSWITCH)...'
$xperfEtl = Join-Path $outDir 'xperf_trace.etl'
& $xperfExe -on PROC_THREAD+LOADER+DPC+INTERRUPT+CSWITCH+FILE_IO -BufferSize 1024 -MinBuffers 64 -MaxBuffers 256 -f $xperfEtl 2>&1 | Out-File -FilePath (Join-Path $outDir 'xperf_start.log') -Encoding utf8
if ($LASTEXITCODE -ne 0) {
    Write-Warning 'xperf start failed — check xperf_start.log'
}

# ---- WPR trace start (optional) ----
if (-not $SkipWPR) {
    Write-Host 'Starting WPR trace (CPU + DiskIO + FileIO + Minifilter)...'
    & $wprExe -start CPU -start DiskIO -start FileIO -start Minifilter -filemode 2>&1 | Out-File -FilePath (Join-Path $outDir 'wpr_start.log') -Encoding utf8
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'WPR start failed — check wpr_start.log'
    }
}

# ---- Per-CPU DPC counters ----
Write-Host 'Sampling per-CPU DPC counters...'
$cpuCount = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
$counters = @()
for ($i = 0; $i -lt $cpuCount; $i++) {
    $counters += '\Processor(' + $i + ')\% DPC Time'
    $counters += '\Processor(' + $i + ')\% Interrupt Time'
    $counters += '\Processor(' + $i + ')\DPCs Queued/sec'
    $counters += '\Processor(' + $i + ')\Interrupts/sec'
}
$counters += '\Processor(_Total)\% Processor Time'
$counters += '\Memory\Available MBytes'
$counters += '\PhysicalDisk(_Total)\Avg. Disk sec/Read'
$counters += '\PhysicalDisk(_Total)\Disk Reads/sec'

# Run sampling in background while xperf/WPR collect
$samplesPerSec = 1
$maxSamples = $DurationSec
Write-Host ('Sampling for ' + $DurationSec + 's... PLAY FORTNITE NOW.') -ForegroundColor Yellow
Write-Host '(Recommend: warmup -> mid-game -> endgame within capture window)'
Write-Host ''

$samples = Get-Counter -Counter $counters -SampleInterval $samplesPerSec -MaxSamples $maxSamples -ErrorAction SilentlyContinue

# Persist raw samples (CSV)
$csvPath = Join-Path $outDir 'percpu_counters.csv'
$rows = New-Object System.Collections.Generic.List[object]
foreach ($s in $samples) {
    foreach ($cs in $s.CounterSamples) {
        $row = [pscustomobject]@{
            Timestamp = $s.Timestamp
            Counter   = $cs.Path
            Value     = $cs.CookedValue
        }
        $rows.Add($row)
    }
}
$rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8

Write-Host ''
Write-Host 'Stopping traces...'

# ---- Stop traces ----
& $xperfExe -stop -d $xperfEtl 2>&1 | Out-File -FilePath (Join-Path $outDir 'xperf_stop.log') -Encoding utf8

if (-not $SkipWPR) {
    $wprEtl = Join-Path $outDir 'wpr_trace.etl'
    & $wprExe -stop $wprEtl 2>&1 | Out-File -FilePath (Join-Path $outDir 'wpr_stop.log') -Encoding utf8
}

# ---- Generate xperf summary ----
Write-Host 'Generating xperf DPC/ISR summary...'
$xperfDpcCsv = Join-Path $outDir 'xperf_dpc_summary.csv'
& $xperfExe -i $xperfEtl -o $xperfDpcCsv -a dpcisr 2>&1 | Out-File -FilePath (Join-Path $outDir 'xperf_dpc_action.log') -Encoding utf8

# ---- Done ----
Write-Host ''
Write-Host '=== Capture Complete ===' -ForegroundColor Green
Write-Host ('Output dir: ' + $outDir)
Write-Host ''
Write-Host 'Next steps:'
Write-Host ('  1. Run analyzer: .\scripts\analyze_eac_dpcs.ps1 -CaptureDir "' + $outDir + '"')
Write-Host ('  2. View xperf in WPA: wpa.exe "' + $xperfEtl + '"')
if (-not $SkipWPR) {
    Write-Host ('  3. View WPR in WPA: wpa.exe "' + (Join-Path $outDir 'wpr_trace.etl') + '"')
}
Write-Host '  4. Save CapFrameX recording (if active) to capture dir for correlation.'
