#Requires -RunAsAdministrator
<#
.SYNOPSIS
    EXP16: Switch DNS to Cloudflare (1.1.1.1) for faster game server resolution.
.DESCRIPTION
    Changes the primary NIC's DNS servers from router/ISP default to Cloudflare
    (1.1.1.1 / 1.0.0.1) for lower DNS latency. Also flushes DNS cache and
    pre-resolves common game server hostnames.
.NOTES
    Reboot: NO
    Rollback: Run rollback.ps1 -BackupFile <backupFile>
#>

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent

Write-Host '=== EXP16: DNS Optimization ===' -ForegroundColor Cyan
Write-Host ''

# Detect primary NIC
$nic = Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
if ($null -eq $nic) { Write-Host 'No active NIC found.' -ForegroundColor Red; exit 1 }
Write-Host ('NIC: ' + $nic.InterfaceDescription)
Write-Host ''

# --- Backup ---
$timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupFile = Join-Path $projectRoot ('captures\backup_pre_exp16_dns_' + $timestamp + '.txt')
$lines = @()
$lines += '# EXP16 Backup: DNS configuration pre-change state'
$lines += ('# Captured: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$lines += ('# Interface: ' + $nic.Name + ' (' + $nic.InterfaceDescription + ')')
$lines += ''

# Current DNS servers
$currentDns = (Get-DnsClientServerAddress -InterfaceAlias $nic.Name -AddressFamily IPv4).ServerAddresses
$lines += ('# Current DNS: ' + ($currentDns -join ', '))
$lines += ''
$lines += '=== Rollback Commands ==='
if ($currentDns.Count -gt 0) {
    $lines += ('Set-DnsClientServerAddress -InterfaceAlias "' + $nic.Name + '" -ServerAddresses @("' + ($currentDns -join '","') + '")')
} else {
    $lines += ('Set-DnsClientServerAddress -InterfaceAlias "' + $nic.Name + '" -ResetServerAddresses')
}
$lines | Out-File -FilePath $backupFile -Encoding UTF8
Write-Host ('Backup: ' + $backupFile) -ForegroundColor Green

# --- BEFORE: DNS benchmark ---
Write-Host ''
Write-Host '=== BEFORE ===' -ForegroundColor Yellow
$gameHosts = @('ping-naw.ds.on.epicgames.com', 'epicgames.com', 'google.com')

# Flush cache to get cold lookup times
ipconfig /flushdns 2>&1 | Out-Null

$beforeTimes = @{}
foreach ($dnsTarget in $gameHosts) {
    $times = @()
    1..3 | ForEach-Object {
        ipconfig /flushdns 2>&1 | Out-Null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try { [System.Net.Dns]::GetHostAddresses($dnsTarget) | Out-Null } catch {}
        $sw.Stop()
        $times += $sw.ElapsedMilliseconds
    }
    $avg = [math]::Round(($times | Measure-Object -Average).Average, 1)
    $beforeTimes[$dnsTarget] = $avg
    Write-Host ('  DNS ' + $dnsTarget.PadRight(40) + $avg + 'ms (cold)')
}

# --- Apply: Set Cloudflare DNS ---
Write-Host ''
Write-Host 'Applying Cloudflare DNS (1.1.1.1, 1.0.0.1)...' -ForegroundColor Yellow
Set-DnsClientServerAddress -InterfaceAlias $nic.Name -ServerAddresses @('1.1.1.1', '1.0.0.1')

# Flush DNS cache
ipconfig /flushdns 2>&1 | Out-Null
Start-Sleep -Seconds 2

# --- Verify ---
$newDns = (Get-DnsClientServerAddress -InterfaceAlias $nic.Name -AddressFamily IPv4).ServerAddresses
Write-Host ('  New DNS: ' + ($newDns -join ', '))

if ($newDns -contains '1.1.1.1') {
    Write-Host '  Cloudflare DNS set successfully' -ForegroundColor Green
} else {
    Write-Host '  WARNING: DNS change may not have applied' -ForegroundColor Red
}

# --- AFTER: DNS benchmark ---
Write-Host ''
Write-Host '=== AFTER ===' -ForegroundColor Yellow

# Flush again for cold lookups
ipconfig /flushdns 2>&1 | Out-Null

$afterTimes = @{}
foreach ($dnsTarget in $gameHosts) {
    $times = @()
    1..3 | ForEach-Object {
        ipconfig /flushdns 2>&1 | Out-Null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try { [System.Net.Dns]::GetHostAddresses($dnsTarget) | Out-Null } catch {}
        $sw.Stop()
        $times += $sw.ElapsedMilliseconds
    }
    $avg = [math]::Round(($times | Measure-Object -Average).Average, 1)
    $afterTimes[$dnsTarget] = $avg
    Write-Host ('  DNS ' + $dnsTarget.PadRight(40) + $avg + 'ms (cold)')
}

# --- Pre-resolve common game hostnames (warm the cache) ---
Write-Host ''
Write-Host 'Pre-resolving game server hostnames...' -ForegroundColor Yellow
$gameServers = @(
    'ping-naw.ds.on.epicgames.com',
    'ping-nac.ds.on.epicgames.com',
    'ping-nae.ds.on.epicgames.com',
    'epicgames.com',
    'fortnite.com',
    'valorant.secure.dyn.riotcdn.net',
    'playvalorant.com'
)
foreach ($srv in $gameServers) {
    try { [System.Net.Dns]::GetHostAddresses($srv) | Out-Null; Write-Host ('  Cached: ' + $srv) -ForegroundColor Green }
    catch { Write-Host ('  Failed: ' + $srv) -ForegroundColor Yellow }
}

# --- Comparison ---
Write-Host ''
Write-Host '=== COMPARISON ===' -ForegroundColor Cyan
Write-Host ''
Write-Host ('  ' + 'Host'.PadRight(42) + 'Before'.PadRight(12) + 'After'.PadRight(12) + 'Delta')
Write-Host ('  ' + ('-' * 78))
foreach ($dnsTarget in $gameHosts) {
    $before = $beforeTimes[$dnsTarget]
    $after  = $afterTimes[$dnsTarget]
    $delta  = [math]::Round($after - $before, 1)
    $sign   = '+'
    if ($delta -lt 0) { $sign = '' }
    $color  = 'Green'
    if ($delta -gt 0) { $color = 'Red' }
    elseif ($delta -eq 0) { $color = 'Yellow' }
    Write-Host ('  ' + $dnsTarget.PadRight(42) + ($before.ToString() + 'ms').PadRight(12) + ($after.ToString() + 'ms').PadRight(12) + $sign + $delta + 'ms') -ForegroundColor $color
}

Write-Host ''
Write-Host 'Done. DNS is now using Cloudflare (1.1.1.1).' -ForegroundColor Cyan
Write-Host 'Game server hostnames pre-cached in DNS resolver.' -ForegroundColor Cyan
