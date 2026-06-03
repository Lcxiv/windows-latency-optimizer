<#
.SYNOPSIS
    Apply the network-side input-lag tweaks from the Gamesager Halo G-Sync+V-Sync
    guide and verify the rest are already in place.

.DESCRIPTION
    The guide's profile-inspector + Windows-VRR steps must be done by hand
    (no clean CLI for NVIDIA Profile Inspector). This script handles the
    machine-side settings:

      1. Windows VRR (DirectX VRROptimizeEnable) -> verify OFF
      2. NIC Interrupt Moderation              -> verify/force Disabled
      3. NIC Interrupt Moderation Rate (ITR)   -> verify/force Off
      4. NIC Receive/Transmit ring buffers     -> set to -BufferSize (guide: 1024)

    Buffers live in the adapter's class registry key (the inbox I226-V driver
    does not expose them through Get-NetAdapterAdvancedProperty), so changing
    them requires a NIC restart -- expect a ~2 second link drop on apply.

.PARAMETER AdapterName
    Target NIC. Defaults to the fastest Up adapter (the I226-V on this rig).

.PARAMETER BufferSize
    Ring buffer size in descriptors. Guide value 1024. Lower = less NIC-side
    queuing latency, higher = more drop headroom under burst.

.PARAMETER Rollback
    Restore buffer values from -BackupFile and re-restart the NIC.

.PARAMETER BackupFile
    Backup file produced by a prior apply run (required with -Rollback).

.PARAMETER WhatIf
    Print intended changes without writing anything.

.EXAMPLE
    .\halo_input_lag_tweaks.ps1
    Apply buffers=1024, verify the other three settings.

.EXAMPLE
    .\halo_input_lag_tweaks.ps1 -Rollback -BackupFile ..\captures\nic_buffers_pre_20260528_120000.txt
#>
[CmdletBinding()]
param(
    [string]$AdapterName,
    [int]$BufferSize = 1024,
    [switch]$Rollback,
    [string]$BackupFile,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$netClass = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TargetAdapter {
    param([string]$Name)
    if ($Name) {
        $a = Get-NetAdapter -Name $Name -ErrorAction Stop
    } else {
        $a = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } |
             Sort-Object -Property LinkSpeed -Descending | Select-Object -First 1
    }
    if (-not $a) { throw 'No active network adapter found.' }
    return $a
}

# Find the class registry subkey (e.g. 0009) whose DriverDesc matches the NIC.
function Get-AdapterClassKey {
    param([string]$InterfaceDescription)
    $hit = $null
    Get-ChildItem $netClass -ErrorAction SilentlyContinue | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($props -and $props.DriverDesc -eq $InterfaceDescription) { $hit = $_.PSPath }
    }
    if (-not $hit) { throw ('Class registry key not found for: ' + $InterfaceDescription) }
    return $hit
}

if (-not (Test-Admin)) { throw 'Run elevated (admin) -- registry + NIC restart require it.' }

$adapter   = Get-TargetAdapter -Name $AdapterName
$classKey  = Get-AdapterClassKey -InterfaceDescription $adapter.InterfaceDescription
$stamp     = Get-Date -Format 'yyyyMMdd_HHmmss'
$captures  = Join-Path $PSScriptRoot '..\captures'

Write-Host ('Adapter : ' + $adapter.Name + ' (' + $adapter.InterfaceDescription + ')')
Write-Host ('ClassKey: ' + $classKey)

# ---------------------------------------------------------------- ROLLBACK ----
if ($Rollback) {
    if (-not $BackupFile -or -not (Test-Path $BackupFile)) {
        throw 'Rollback needs a valid -BackupFile.'
    }
    $rx = $null; $tx = $null
    Get-Content $BackupFile | ForEach-Object {
        if ($_ -match '^\*ReceiveBuffers=(\d+)')  { $rx = $matches[1] }
        if ($_ -match '^\*TransmitBuffers=(\d+)') { $tx = $matches[1] }
    }
    if (-not $rx -or -not $tx) { throw 'Backup file missing buffer values.' }
    Write-Host ('Restoring ReceiveBuffers=' + $rx + ' TransmitBuffers=' + $tx)
    if ($WhatIf) { Write-Host '[WhatIf] no changes written'; return }
    Set-ItemProperty -Path $classKey -Name '*ReceiveBuffers'  -Value $rx
    Set-ItemProperty -Path $classKey -Name '*TransmitBuffers' -Value $tx
    Restart-NetAdapter -Name $adapter.Name -Confirm:$false
    Write-Host 'Rollback applied; NIC restarted.'
    return
}

# ------------------------------------------------------------------- APPLY ----
# 1. Windows VRR (verify only -- HKCU, user toggle)
$vrrKey = 'HKCU:\SOFTWARE\Microsoft\DirectX\UserGpuPreferences'
$vrr    = $null
if (Test-Path $vrrKey) { $vrr = (Get-ItemProperty $vrrKey).DirectXUserGlobalSettings }
if ($vrr -and $vrr -match 'VRROptimizeEnable=0') {
    Write-Host 'VRR        : OFF (ok)'
} else {
    Write-Host 'VRR        : NOT off -- set Settings > Display > Graphics > Default settings > Variable refresh rate = Off'
}

# 2 + 3. Interrupt Moderation + ITR (force to guide values; idempotent)
$imTargets = @(
    @{ Keyword = '*InterruptModeration'; Value = 0; Label = 'Interrupt Moderation -> Disabled' },
    @{ Keyword = 'ITR';                  Value = 0; Label = 'Interrupt Mod Rate -> Off' }
)
foreach ($t in $imTargets) {
    $cur = Get-NetAdapterAdvancedProperty -Name $adapter.Name -RegistryKeyword $t.Keyword -ErrorAction SilentlyContinue
    if ($null -eq $cur) { Write-Host ('  skip (not exposed): ' + $t.Keyword); continue }
    if ([int]$cur.RegistryValue[0] -eq $t.Value) {
        Write-Host ('  ok  : ' + $t.Label)
    } elseif ($WhatIf) {
        Write-Host ('  [WhatIf] would set ' + $t.Label)
    } else {
        Set-NetAdapterAdvancedProperty -Name $adapter.Name -RegistryKeyword $t.Keyword -RegistryValue $t.Value
        Write-Host ('  set : ' + $t.Label)
    }
}

# 4. Ring buffers (registry; needs NIC restart)
$curRx = [string](Get-ItemProperty -Path $classKey -Name '*ReceiveBuffers'  -ErrorAction SilentlyContinue).'*ReceiveBuffers'
$curTx = [string](Get-ItemProperty -Path $classKey -Name '*TransmitBuffers' -ErrorAction SilentlyContinue).'*TransmitBuffers'
Write-Host ('Buffers    : current Rx=' + $curRx + ' Tx=' + $curTx + ' -> target ' + $BufferSize)

if (($curRx -eq [string]$BufferSize) -and ($curTx -eq [string]$BufferSize)) {
    Write-Host '  ok  : buffers already at target -- no NIC restart needed'
    return
}

if (-not (Test-Path $captures)) { New-Item -ItemType Directory -Path $captures | Out-Null }
$backup = Join-Path $captures ('nic_buffers_pre_' + $stamp + '.txt')

if ($WhatIf) {
    Write-Host ('  [WhatIf] would back up to ' + $backup + ' then set buffers=' + $BufferSize + ' and restart NIC')
    return
}

@(
    '# NIC ring buffer backup ' + $stamp,
    '# Adapter: ' + $adapter.InterfaceDescription,
    '# ClassKey: ' + $classKey,
    '*ReceiveBuffers=' + $curRx,
    '*TransmitBuffers=' + $curTx,
    '# Rollback: .\halo_input_lag_tweaks.ps1 -Rollback -BackupFile "' + $backup + '"'
) | Set-Content -Path $backup -Encoding UTF8
Write-Host ('  backup saved: ' + $backup)

Set-ItemProperty -Path $classKey -Name '*ReceiveBuffers'  -Value ([string]$BufferSize)
Set-ItemProperty -Path $classKey -Name '*TransmitBuffers' -Value ([string]$BufferSize)
Write-Host '  registry written; restarting NIC (~2s link drop)...'
Restart-NetAdapter -Name $adapter.Name -Confirm:$false

Start-Sleep -Seconds 2
$newRx = [string](Get-ItemProperty -Path $classKey -Name '*ReceiveBuffers').'*ReceiveBuffers'
$newTx = [string](Get-ItemProperty -Path $classKey -Name '*TransmitBuffers').'*TransmitBuffers'
Write-Host ('  verify: Rx=' + $newRx + ' Tx=' + $newTx)
if (($newRx -eq [string]$BufferSize) -and ($newTx -eq [string]$BufferSize)) {
    Write-Host 'DONE.'
} else {
    Write-Host 'WARNING: buffers did not stick -- driver may have clamped the value.'
}
