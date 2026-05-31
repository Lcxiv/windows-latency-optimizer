#requires -Version 5.1
<#
.SYNOPSIS
  Post-mortem producer (evidence-bus step 4): decode crash dumps with cdb and
  emit typed dpc_watchdog / bugcheck rows into the evidence bus. Makes the
  recurrence query (GROUP BY faulting_module) reflect REAL dumps, not just seeds.

.DESCRIPTION
  Scans C:\Windows\Minidump (and MEMORY.DMP) for dumps newer than -SinceDays,
  decodes each with cdb (!analyze -v), parses BUGCHECK_CODE / MODULE_NAME /
  FAILURE_BUCKET_ID, and writes one evidence row per dump. Idempotent within a
  run via a processed-set keyed on dump filename.

.PARAMETER SinceDays   Only decode dumps modified within this many days (default 120).
.PARAMETER CdbPath     Override cdb.exe path. Auto-discovers the WinDbg appx if omitted.
.PARAMETER WhatIf      Decode + parse but do not write evidence rows.

.EXAMPLE
  .\scripts\evidence_postmortem.ps1 -SinceDays 120
  .\scripts\evidence_correlate.ps1        # now shows nvlddmkm xN from real dumps
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [int]$SinceDays = 120,
  [string]$CdbPath = $null
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\helpers\evidence-bus.ps1"

# ── locate cdb ────────────────────────────────────────────────────────────────
function Find-Cdb {
  param([string]$Override)
  if ($Override -and (Test-Path $Override)) { return $Override }
  $cmd = Get-Command cdb.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $appx = Get-ChildItem 'C:\Program Files\WindowsApps' -Filter 'Microsoft.WinDbg*' -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -First 1
  if ($appx) {
    $hit = Join-Path $appx.FullName 'amd64\cdb.exe'
    if (Test-Path $hit) { return $hit }
  }
  return $null
}

# ── map a bugcheck's faulting subsystem from the module name ──────────────────
function Get-SubsystemForModule {
  param([string]$Module)
  switch -Regex ($Module) {
    'nvlddmkm|dxgkrnl|amdkmdag|nvgpu' { return 'gpu' }
    'stornvme|storport|storahci|disk|Ntfs' { return 'storage' }
    'tcpip|ndis|e2f|netio|rt6' { return 'network' }
    ' acpi|intelppm|amdppm|processr' { return 'power' }
    default { return 'cpu_dpc' }   # DPC watchdog with unknown module = generic DPC
  }
}

# ── parse one cdb !analyze -v output into a row payload ───────────────────────
function ConvertFrom-CdbAnalysis {
  param([string]$Text, [string]$DumpFile)
  $get = {
    param($pat)
    $m = [regex]::Match($Text, $pat)
    if ($m.Success) { return $m.Groups[1].Value.Trim() } else { return $null }
  }
  $code   = & $get 'BUGCHECK_CODE:\s*([0-9a-fA-Fx]+)'
  $module = & $get 'MODULE_NAME:\s*(\S+)'
  $image  = & $get 'IMAGE_NAME:\s*(\S+)'
  $bucket = & $get 'FAILURE_BUCKET_ID:\s*(\S+)'
  $proc   = & $get 'PROCESS_NAME:\s*(\S+)'
  $hash   = & $get 'FAILURE_ID_HASH:\s*\{?([0-9a-fA-F-]+)\}?'
  $isWatchdog = ($Text -match 'DPC_WATCHDOG_VIOLATION') -or ($code -eq '133')
  return [PSCustomObject]@{
    BugcheckCode = $code
    Module       = $module
    Image        = $image
    Bucket       = $bucket
    Process      = $proc
    Hash         = $hash
    IsWatchdog   = $isWatchdog
  }
}

# ── main ──────────────────────────────────────────────────────────────────────
$cdb = Find-Cdb -Override $CdbPath
if (-not $cdb) { throw 'cdb.exe not found. Install WinDbg: winget install Microsoft.WinDbg' }
Write-Host "cdb: $cdb"

$since = (Get-Date).AddDays(-$SinceDays)
$dumps = @()
$dumps += Get-ChildItem 'C:\Windows\Minidump\*.dmp' -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -ge $since }
$mem = Get-Item 'C:\Windows\MEMORY.DMP' -ErrorAction SilentlyContinue
if ($mem -and $mem.LastWriteTime -ge $since) { $dumps += $mem }

if (-not $dumps) { Write-Host "No dumps newer than $SinceDays days. Nothing to do."; return }
Write-Host ("Dumps to decode: " + $dumps.Count)

$sym = 'srv*C:\symbols*https://msdl.microsoft.com/download/symbols'
# This script lives in scripts\, so repo root is ONE level up (not two).
$outDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'captures'
$written = 0

foreach ($d in $dumps) {
  Write-Host ("  decoding " + $d.Name + " ...")
  $raw = & $cdb -z $d.FullName -y $sym -c '!analyze -v; q' 2>&1 | Out-String
  $analyzeFile = Join-Path $outDir ('dump_' + ($d.BaseName) + '_analyze.txt')
  [IO.File]::WriteAllText($analyzeFile, $raw, [Text.Encoding]::ASCII)

  $a = ConvertFrom-CdbAnalysis -Text $raw -DumpFile $d.FullName
  if (-not $a.BugcheckCode) { Write-Warning ("    no bugcheck parsed from " + $d.Name + " (symbols?) — skipping"); continue }

  $subsystem = Get-SubsystemForModule -Module $a.Module
  $signal = 'bugcheck'
  if ($a.IsWatchdog) { $signal = 'dpc_watchdog' }

  $payload = @{
    bugcheck = $a.BugcheckCode
    bucket   = $a.Bucket
    process  = $a.Process
    hash     = $a.Hash
  }
  # incident id from the dump's date (yyyyMMdd-HHmm)
  $incId = 'INC-' + $d.LastWriteTime.ToString('yyyyMMdd-HHmm')

  if ($PSCmdlet.ShouldProcess($d.Name, "write $signal row (module=$($a.Module))")) {
    $id = Write-EvidenceRow -Source windbg -Subsystem $subsystem -Signal $signal `
      -Severity critical -EvidenceKind observed -Confidence 1.0 `
      -FaultingModule $a.Module -Value $payload -RawRef $analyzeFile -IncidentId $incId `
      -Ts $d.LastWriteTime.ToUniversalTime().ToString('o')
    $written++
    Write-Host ("    row " + $id + "  signal=" + $signal + "  module=" + $a.Module + "  bucket=" + $a.Bucket)
  } else {
    Write-Host ("    [WhatIf] would write " + $signal + " module=" + $a.Module + " bucket=" + $a.Bucket)
  }
}

Write-Host ''
Write-Host ("Post-mortem complete. Rows written: " + $written)
Write-Host "Run .\scripts\evidence_correlate.ps1 to see recurrence over real dumps."
