#requires -Version 5.1
<#
.SYNOPSIS
  Read-only root-cause collector for "computer froze on last boot".
  Triangulates >=2 INDEPENDENT sources so a cause is only accepted on agreement:
    1 Event Log power lifecycle (6005/6006/6008/6013/1074, Kernel-Power 41)
    2 Crash dumps (Minidump + MEMORY.DMP + WER 1001) + CrashControl config
    3 Reliability Monitor (Win32_ReliabilityRecords)
    4 Boot performance (Diagnostics-Performance 100-110)
    5 Hardware (WHEA-Logger) + storage errors (disk 7/11/51/153)
    6 Service Control Manager boot failures (7000/7026/7031/7034)
    7 Application crash/hang (1000/1002)
  No registry writes. Run elevated for full coverage.
#>
[CmdletBinding()]
param(
  [int]$Days = 14,
  [string]$OutDir = "$PSScriptRoot\..\captures"
)
$ErrorActionPreference = 'SilentlyContinue'
$stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$report = Join-Path $OutDir "boot_freeze_rca_$stamp.txt"
$sb = New-Object System.Text.StringBuilder
function W { param($t) [void]$sb.AppendLine([string]$t) }
function H { param($t) W ''; W ('=' * 70); W $t; W ('=' * 70) }
$since = (Get-Date).AddDays(-$Days)

H "BOOT FREEZE RCA | $(Get-Date) | lookback ${Days}d"
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
W "Host           : $($cs.Name)"
W "OS             : $($os.Caption) build $($os.BuildNumber)"
W "LastBootUpTime : $($os.LastBootUpTime)"
W "Now            : $(Get-Date)"
W ("Uptime (min)   : {0:N0}" -f ((Get-Date)-$os.LastBootUpTime).TotalMinutes)
$fast = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled).HiberbootEnabled
W "FastStartup    : $fast"

H "SOURCE 1  Power lifecycle (6005 start / 6006 clean-stop / 6008 unexpected / 6013 uptime / 1074 initiated)"
Get-WinEvent -FilterHashtable @{LogName='System';Id=6005,6006,6008,6013,1074;StartTime=$since} -MaxEvents 60 |
  Sort-Object TimeCreated | ForEach-Object { W ("{0}  [{1}]  {2}" -f $_.TimeCreated,$_.Id,(($_.Message -split "`r?`n")[0]).Trim()) }

H "SOURCE 1b  Kernel-Power 41 (dirty shutdown). BugcheckCode=0 => hang/power-loss; <>0 => BSOD"
Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-Kernel-Power';Id=41;StartTime=$since} -MaxEvents 10 |
  ForEach-Object {
    $x=[xml]$_.ToXml(); $d=@{}; $x.Event.EventData.Data | ForEach-Object { $d[$_.Name]=$_.'#text' }
    $bc=[int]$d['BugcheckCode']
    W ("{0}  BugcheckCode={1} (0x{2:x})  PowerButtonTS={3}  SleepInProgress={4}" -f $_.TimeCreated,$bc,$bc,$d['PowerButtonTimestamp'],$d['SleepInProgress'])
  }

H "SOURCE 2  BugCheck (WER 1001) + dumps on disk + CrashControl"
Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-WER-SystemErrorReporting';Id=1001;StartTime=$since} -MaxEvents 10 |
  ForEach-Object { W ("{0}  {1}" -f $_.TimeCreated,(($_.Message -split "`r?`n")[0]).Trim()) }
W ''; W "Minidumps:"
Get-ChildItem 'C:\Windows\Minidump\*.dmp' | Sort-Object LastWriteTime -Descending |
  ForEach-Object { W ("  {0}  {1,10:N0} B  {2}" -f $_.LastWriteTime,$_.Length,$_.Name) }
$mem = Get-Item 'C:\Windows\MEMORY.DMP'
if ($mem) { W ("  MEMORY.DMP  {0}  {1:N0} B" -f $mem.LastWriteTime,$mem.Length) } else { W "  (no MEMORY.DMP)" }
$cc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
W ("  CrashDumpEnabled={0}  AutoReboot={1}  DumpFile={2}" -f $cc.CrashDumpEnabled,$cc.AutoReboot,$cc.DumpFile)

H "SOURCE 3  Reliability Monitor (Win32_ReliabilityRecords)"
Get-CimInstance Win32_ReliabilityRecords | Where-Object { $_.TimeGenerated -ge $since } |
  Sort-Object TimeGenerated | Select-Object -Last 40 |
  ForEach-Object { W ("{0}  [{1}]  {2}  {3}" -f $_.TimeGenerated,$_.SourceName,$_.ProductName,$_.Message) }

H "SOURCE 4  Diagnostics-Performance boot timing (100 summary / 101-110 degradation)"
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Diagnostics-Performance/Operational';StartTime=$since} -MaxEvents 40 |
  Where-Object { $_.Id -ge 100 -and $_.Id -le 210 } | Sort-Object TimeCreated |
  ForEach-Object {
    $x=[xml]$_.ToXml(); $d=@{}; $x.Event.EventData.Data | ForEach-Object { $d[$_.Name]=$_.'#text' }
    $boot = ''; if ($d['BootTime']) { $boot = "BootTime=$([math]::Round([double]$d['BootTime']/1000,1))s" }
    $deg  = ''; if ($d['DegradationTime']) { $deg = "Degr=$([math]::Round([double]$d['DegradationTime']/1000,1))s" }
    W ("{0}  [{1}]  {2} {3} {4}" -f $_.TimeCreated,$_.Id,(($_.Message -split "`r?`n")[0]).Trim(),$boot,$deg)
  }

H "SOURCE 5  WHEA-Logger + storage errors (disk/Ntfs/volmgr/stornvme 7,11,51,153,140)"
W "WHEA-Logger:"
Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-WHEA-Logger';StartTime=$since} -MaxEvents 30 |
  Sort-Object TimeCreated | ForEach-Object { W ("  {0}  [{1}/{2}]  {3}" -f $_.TimeCreated,$_.Id,$_.LevelDisplayName,(($_.Message -split "`r?`n")[0]).Trim()) }
W "Storage:"
Get-WinEvent -FilterHashtable @{LogName='System';Id=7,11,51,153,140;StartTime=$since} -MaxEvents 30 |
  Where-Object { $_.ProviderName -match 'disk|Ntfs|volmgr|storahci|stornvme' } |
  Sort-Object TimeCreated | ForEach-Object { W ("  {0}  [{1}]  {2}  {3}" -f $_.TimeCreated,$_.Id,$_.ProviderName,(($_.Message -split "`r?`n")[0]).Trim()) }

H "SOURCE 6  Service Control Manager boot failures (7000/7026/7031/7034)"
Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Service Control Manager';Id=7000,7001,7026,7031,7034;StartTime=$since} -MaxEvents 30 |
  Sort-Object TimeCreated | ForEach-Object { W ("  {0}  [{1}]  {2}" -f $_.TimeCreated,$_.Id,(($_.Message -split "`r?`n")[0]).Trim()) }

H "SOURCE 7  Application crashes/hangs (1000 crash / 1002 hang)"
Get-WinEvent -FilterHashtable @{LogName='Application';ProviderName='Application Error','Application Hang';StartTime=$since} -MaxEvents 25 |
  Sort-Object TimeCreated | ForEach-Object { W ("  {0}  [{1}]  {2}" -f $_.TimeCreated,$_.Id,(($_.Message -split "`r?`n")[0]).Trim()) }

[IO.File]::WriteAllText($report, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
Write-Host "Report written: $report"
