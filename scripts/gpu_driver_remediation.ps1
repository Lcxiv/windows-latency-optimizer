#requires -Version 5.1
<#
.SYNOPSIS
  P2 remediation for the confirmed nvlddmkm DPC-watchdog hang.
  Root cause: docs\boot-freeze-rca-findings.md (FAILURE_BUCKET_ID 0x133_DPC_nvlddmkm).

  Scripts every safely-automatable step of a clean NVIDIA driver reinstall and
  gates the one step that cannot be automated (the DDU wipe runs in Safe Mode,
  GUI-only). Phase-based, backup-first, -WhatIf on every mutating phase.

.PARAMETER Phase
  Backup | Orphan | StageDDU | ClockTest | ClockReset | Verify | All
  Default Backup (writes only a backup file).

.PARAMETER OrphanInf
  Published-name of the unbound DriverStore package to remove. Default oem0.inf
  (verified unbound 2026-05-30: active device binds oem73.inf). Re-verified
  unbound before deletion; refuses if it is the active driver.

.EXAMPLE
  .\gpu_driver_remediation.ps1 -Phase Backup
  .\gpu_driver_remediation.ps1 -Phase Orphan -WhatIf
  .\gpu_driver_remediation.ps1 -Phase Orphan
  .\gpu_driver_remediation.ps1 -Phase StageDDU
  .\gpu_driver_remediation.ps1 -Phase ClockTest
  .\gpu_driver_remediation.ps1 -Phase ClockReset
  .\gpu_driver_remediation.ps1 -Phase Verify
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [ValidateSet('All','Backup','Orphan','StageDDU','ClockTest','ClockReset','Verify')]
  [string]$Phase = 'Backup',
  [string]$OrphanInf  = 'oem0.inf',
  [string]$StageDir   = "$env:USERPROFILE\Desktop\gpu_reinstall",
  [string]$DriverUrl  = '',
  [string]$CaptureDir = "$PSScriptRoot\..\captures"
)
$ErrorActionPreference = 'Stop'
$smi   = 'C:\Windows\System32\nvidia-smi.exe'
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

function Assert-Admin {
  $pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $pr.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    throw 'Must run elevated (admin). pnputil + driver ops require it.'
  }
}
function Get-GpuDevice {
  Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -match 'NVIDIA|RTX|GeForce' } | Select-Object -First 1
}
function Get-BoundInf {
  param($dev)
  if (-not $dev) { return $null }
  (Get-PnpDeviceProperty -InstanceId $dev.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction SilentlyContinue).Data
}

function Invoke-Backup {
  $out = Join-Path $CaptureDir "gpu_remediation_backup_$stamp.txt"
  $sb  = New-Object System.Text.StringBuilder
  $dev = Get-GpuDevice
  [void]$sb.AppendLine("# GPU remediation backup $stamp")
  [void]$sb.AppendLine("Device     : $($dev.FriendlyName)  status=$($dev.Status)")
  [void]$sb.AppendLine("InstanceId : $($dev.InstanceId)")
  [void]$sb.AppendLine("Bound INF  : $(Get-BoundInf $dev)")
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('=== pnputil display packages ===')
  [void]$sb.AppendLine((pnputil /enum-drivers | Out-String))
  if (Test-Path $smi) {
    [void]$sb.AppendLine('=== nvidia-smi ===')
    [void]$sb.AppendLine((& $smi --query-gpu=name,driver_version,pstate,vbios_version --format=csv 2>&1 | Out-String))
  }
  $drv = Get-CimInstance Win32_SystemDriver -Filter "Name='nvlddmkm'"
  [void]$sb.AppendLine("=== loaded nvlddmkm ===")
  [void]$sb.AppendLine("State=$($drv.State) Path=$($drv.PathName)")
  [IO.File]::WriteAllText($out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
  Write-Host "Backup written: $out"
}

function Invoke-Orphan {
  Assert-Admin
  $dev   = Get-GpuDevice
  $bound = Get-BoundInf $dev
  Write-Host "Active GPU binds: $bound"
  if ($bound -ieq $OrphanInf) {
    throw "REFUSING: $OrphanInf is the ACTIVE bound driver, not an orphan."
  }
  $enum = pnputil /enum-drivers | Out-String
  if ($enum -notmatch [regex]::Escape($OrphanInf)) {
    Write-Host "Package $OrphanInf not present. Nothing to remove."
    return
  }
  if ($PSCmdlet.ShouldProcess($OrphanInf, 'pnputil /delete-driver /uninstall')) {
    Write-Host "Removing orphan package $OrphanInf ..."
    & pnputil /delete-driver $OrphanInf /uninstall 2>&1 | ForEach-Object { Write-Host "  $_" }
    $again = pnputil /enum-drivers | Out-String
    if ($again -match [regex]::Escape($OrphanInf)) {
      Write-Warning "  $OrphanInf still listed (in use). Reboot then retry."
    } else {
      Write-Host "  $OrphanInf removed."
    }
  }
}

function Invoke-StageDDU {
  if (-not (Test-Path $StageDir)) { New-Item -ItemType Directory -Path $StageDir -Force | Out-Null }
  Write-Host "Stage dir: $StageDir"

  $dduRoots = @("$env:USERPROFILE\Desktop", "$env:USERPROFILE\Downloads", 'C:\Program Files (x86)\Display Driver Uninstaller', $StageDir)
  $ddu = $null
  foreach ($r in $dduRoots) {
    $hit = Get-ChildItem $r -Recurse -Filter 'Display Driver Uninstaller.exe' -Depth 4 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { $ddu = $hit; break }
  }
  if ($ddu) {
    Write-Host "DDU found: $($ddu.FullName)"
  } else {
    Write-Host "DDU not found. Download from wagnardsoft (official) and extract into $StageDir"
  }

  if (Test-Path $smi) {
    $gpu = (& $smi --query-gpu=name,driver_version --format=csv,noheader) -join ' / '
    Write-Host "Detected GPU: $gpu"
  }

  if ($DriverUrl) {
    $dst = Join-Path $StageDir 'nvidia_driver.exe'
    if ($PSCmdlet.ShouldProcess($DriverUrl, "download to $dst")) {
      Start-BitsTransfer -Source $DriverUrl -Destination $dst -ErrorAction Stop
      Write-Host "Saved: $dst"
    }
  } else {
    Write-Host "No -DriverUrl given. Get the latest Game Ready/Studio driver for RTX 5070 Ti"
    Write-Host "from nvidia.com/Download (or the NVIDIA App) and save it into $StageDir"
  }

  Write-Host ''
  Write-Host '=== SAFE-MODE CLEAN REINSTALL (manual; cannot be automated) ==='
  Write-Host ' 1. Disconnect internet (stop Windows Update auto-pushing a driver mid-wipe).'
  Write-Host ' 2. Boot Safe Mode: msconfig > Boot > Safe boot (Minimal) > reboot.'
  Write-Host ' 3. Run DDU > GPU = NVIDIA > "Clean and do NOT restart".'
  Write-Host ' 4. Uncheck Safe boot in msconfig, reboot normally.'
  Write-Host ' 5. Run the NVIDIA installer > Custom > Clean install. Driver + PhysX only.'
  Write-Host ' 6. Reconnect internet. Reboot.'
  Write-Host ' 7. Run: .\gpu_driver_remediation.ps1 -Phase Verify'
  Write-Host '==============================================================='
}

function Invoke-ClockTest {
  if (-not (Test-Path $smi)) { throw 'nvidia-smi not found.' }
  Write-Host 'Current:'
  & $smi --query-gpu=pstate,clocks.gr,clocks.mem --format=csv
  $maxClk = (& $smi --query-gpu=clocks.max.gr --format=csv,noheader) -replace '[^0-9]', ''
  if (-not $maxClk) { Write-Warning 'Could not read clocks.max.gr; skipping lock.'; return }
  if ($PSCmdlet.ShouldProcess('GPU graphics clock', "lock to $maxClk MHz (non-persistent)")) {
    Write-Host "Locking graphics clock to $maxClk MHz to suppress idle P-state transitions (TEST)..."
    & $smi -lgc "$maxClk,$maxClk" 2>&1 | ForEach-Object { Write-Host "  $_" }
    Write-Host 'Locked. Resets on reboot or via -Phase ClockReset.'
    Write-Host 'If the hang does NOT recur while locked, idle clock-state DPC is confirmed.'
    Write-Host 'If -lgc errors on this GeForce/driver, set NVCP Power Mgmt = Prefer Maximum'
    Write-Host 'Performance (global) instead - that is the persistent fix.'
  }
}

function Invoke-ClockReset {
  if (-not (Test-Path $smi)) { throw 'nvidia-smi not found.' }
  if ($PSCmdlet.ShouldProcess('GPU graphics clock', 'reset to default')) {
    & $smi -rgc 2>&1 | ForEach-Object { Write-Host "  $_" }
    Write-Host 'GPU clocks reset to driver default.'
  }
}

function Invoke-Verify {
  $dev   = Get-GpuDevice
  $bound = Get-BoundInf $dev
  Write-Host '=== Post-reinstall verification ==='
  Write-Host "Device : $($dev.FriendlyName)  status=$($dev.Status)  problem=$($dev.ProblemCode)"
  Write-Host "Bound  : $bound"
  if (Test-Path $smi) {
    Write-Host "Driver : $((& $smi --query-gpu=driver_version,pstate --format=csv,noheader))"
  }
  $pkgs = @()
  foreach ($blk in ((pnputil /enum-drivers | Out-String) -split "`r?`n`r?`n")) {
    if ($blk -match 'Published Name\s*:\s*(\S+)' -and $blk -match 'nv_disp') { $pkgs += $Matches[1] }
  }
  Write-Host "NVIDIA display packages in store: $($pkgs.Count)  [$($pkgs -join ', ')]"
  if ($pkgs.Count -gt 1) {
    Write-Warning '  >1 package - orphan residue remains. Re-run -Phase Orphan on the unbound one.'
  } else {
    Write-Host '  Clean: single package.'
  }
  $recent = Get-ChildItem 'C:\Windows\Minidump\*.dmp' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-1) }
  if ($recent) {
    Write-Warning '  New minidump(s) in last 24h - decode with cdb; hang may persist.'
  } else {
    Write-Host '  No new dumps in last 24h.'
  }
  Write-Host ''
  Write-Host 'Next: re-baseline DPC -> .\pipeline.ps1 -SkipWPR -DurationSec 5 (watch per-CPU nvlddmkm DPC)'
  Write-Host 'Confirm NVCP Power Management Mode = Prefer Maximum Performance (global).'
}

switch ($Phase) {
  'Backup'     { Invoke-Backup }
  'Orphan'     { Invoke-Backup; Invoke-Orphan }
  'StageDDU'   { Invoke-StageDDU }
  'ClockTest'  { Invoke-ClockTest }
  'ClockReset' { Invoke-ClockReset }
  'Verify'     { Invoke-Verify }
  'All'        { Invoke-Backup; Invoke-Orphan; Invoke-StageDDU }
}
