#requires -Version 5.1
<#
.SYNOPSIS
  Restore crash-dump / CrashOnCtrlScroll registry values from a backup file
  produced by enable_crashdump.ps1. Parses the embedded RESTORE reg commands.
.NOTES
  Requires elevation. Use -WhatIf to preview.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory = $true)][string]$BackupFile
)
$ErrorActionPreference = 'Stop'
$pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
  throw 'Must run elevated (admin).'
}
if (-not (Test-Path $BackupFile)) { throw "Backup not found: $BackupFile" }

# allowlist: only reg add / reg delete on the two expected key roots
$allowRoots = @(
  'HKLM\SYSTEM\CurrentControlSet\Control\CrashControl',
  'HKLM\SYSTEM\CurrentControlSet\Services\kbdhid\Parameters',
  'HKLM\SYSTEM\CurrentControlSet\Services\i8042prt\Parameters'
)
$lines = Get-Content $BackupFile | Where-Object { $_ -match '^\s*RESTORE:\s*reg\s+(add|delete)\s' }
if (-not $lines) { throw 'No RESTORE commands found in backup.' }

foreach ($l in $lines) {
  $cmd = ($l -replace '^\s*RESTORE:\s*', '').Trim()
  $okRoot = $false
  foreach ($r in $allowRoots) { if ($cmd -like "*`"$r`"*") { $okRoot = $true } }
  if (-not $okRoot) { Write-Warning "SKIP (not allowlisted): $cmd"; continue }
  if ($PSCmdlet.ShouldProcess($cmd, 'restore')) {
    Write-Host "RUN: $cmd"
    & cmd.exe /c $cmd | Out-Null
  }
}
Write-Host 'Rollback complete. Reboot for CrashOnCtrlScroll change to fully revert.'
