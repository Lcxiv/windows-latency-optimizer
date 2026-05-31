#requires -Version 5.1
<#
.SYNOPSIS
  P1 fix: make the next freeze/crash diagnosable.
  Backs up current values FIRST (timestamped rollback file with restore commands),
  then enables Automatic kernel dumps + manual crash trigger (CrashOnCtrlScroll).
.NOTES
  Requires elevation. Keys 4-5 (CrashOnCtrlScroll) arm after the next reboot.
  Use -WhatIf to preview without writing.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$BackupDir = "$PSScriptRoot\..\captures",
  [switch]$NoAutoRebootChange  # skip flipping AutoReboot to 0 if you want silent recovery kept
)
$ErrorActionPreference = 'Stop'

# --- elevation guard ---
$pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
  throw 'Must run elevated (admin). Writes to HKLM\SYSTEM.'
}

$stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$backup = Join-Path $BackupDir "backup_pre_crashdump_$stamp.txt"
$bk = New-Object System.Text.StringBuilder
function BK { param($t) [void]$bk.AppendLine([string]$t) }

$ccPath  = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
$ccReg   = 'HKLM\SYSTEM\CurrentControlSet\Control\CrashControl'

# desired changes: PSpath, regPath, name, newValue
$changes = @(
  @{ ps=$ccPath; reg=$ccReg; name='CrashDumpEnabled';     val=7 }
  @{ ps=$ccPath; reg=$ccReg; name='AlwaysKeepMemoryDump'; val=1 }
)
if (-not $NoAutoRebootChange) {
  $changes += @{ ps=$ccPath; reg=$ccReg; name='AutoReboot'; val=0 }
}
foreach ($svc in 'kbdhid','i8042prt') {
  $changes += @{
    ps  = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc\Parameters"
    reg = "HKLM\SYSTEM\CurrentControlSet\Services\$svc\Parameters"
    name= 'CrashOnCtrlScroll'; val=1
  }
}

# --- BACKUP current state + build restore commands ---
BK "# Crash-dump P1 backup  $stamp"
BK "# Restore: run scripts\rollback_crashdump.ps1 -BackupFile <this file>, or paste the reg commands below (elevated)."
BK ''
foreach ($c in $changes) {
  $exists = Test-Path $c.ps
  $cur = $null
  if ($exists) { $cur = (Get-ItemProperty -Path $c.ps -Name $c.name -ErrorAction SilentlyContinue).$($c.name) }
  if ($null -eq $cur) {
    BK ("UNSET`t{0}`t{1}" -f $c.reg, $c.name)
    BK ("  RESTORE: reg delete `"{0}`" /v {1} /f" -f $c.reg, $c.name)
  } else {
    BK ("VALUE`t{0}`t{1}`t{2}" -f $c.reg, $c.name, $cur)
    BK ("  RESTORE: reg add `"{0}`" /v {1} /t REG_DWORD /d {2} /f" -f $c.reg, $c.name, $cur)
  }
}
# pagefile note
$acs = (Get-CimInstance Win32_ComputerSystem).AutomaticManagedPagefile
BK ''
BK ("# AutomaticManagedPagefile=$acs  (Automatic dump needs a pagefile on C:)")
[IO.File]::WriteAllText($backup, $bk.ToString(), (New-Object System.Text.UTF8Encoding($true)))
Write-Host "Backup written: $backup"

# --- APPLY ---
foreach ($c in $changes) {
  if (-not (Test-Path $c.ps)) {
    if ($PSCmdlet.ShouldProcess($c.ps, 'create key')) { New-Item -Path $c.ps -Force | Out-Null }
  }
  if ($PSCmdlet.ShouldProcess(("{0}\{1}" -f $c.reg, $c.name), ("set = {0}" -f $c.val))) {
    New-ItemProperty -Path $c.ps -Name $c.name -PropertyType DWord -Value $c.val -Force | Out-Null
  }
}

# --- VERIFY ---
Write-Host ''
Write-Host '=== Verify ==='
$ok = $true
foreach ($c in $changes) {
  $got = (Get-ItemProperty -Path $c.ps -Name $c.name -ErrorAction SilentlyContinue).$($c.name)
  $pass = ($got -eq $c.val)
  if (-not $pass) { $ok = $false }
  Write-Host ("  [{0}] {1}\{2} = {3} (want {4})" -f $(if($pass){'OK'}else{'FAIL'}), $c.reg, $c.name, $got, $c.val)
}
Write-Host ''
if ($ok) { Write-Host 'P1 applied. CrashDumpEnabled=7 (Automatic kernel dump), AutoReboot=0.' }
Write-Host 'CrashOnCtrlScroll arms after NEXT REBOOT.'
Write-Host 'Force a dump from a hung machine: hold RIGHT Ctrl, press ScrollLock twice.'
Write-Host "Rollback: scripts\rollback_crashdump.ps1 -BackupFile `"$backup`""
