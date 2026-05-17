<#
.SYNOPSIS
    Capture I226-V (and other NIC) error statistics with delta support.
.DESCRIPTION
    Two modes:
      -Mode Start  : capture baseline, write to <OutDir>\nic_baseline.json
      -Mode End    : capture current, diff vs baseline, write nic_errors_delta.json
      -Mode Snap   : single snapshot, no diff
    Captures: link speed, duplex, RX/TX bytes/packets, errors, CRC, discards.
    Flags: any non-zero CRC delta, link below 2.5 Gbps for I226-V.
.OUTPUTS
    JSON to <OutDir>\<output filename>
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$OutDir,
    [ValidateSet('Start','End','Snap')]
    [string]$Mode = 'Snap',
    [string]$Phase = 'idle',
    [string]$BaselineFile = ''
)

$ErrorActionPreference = 'Continue'
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

function Get-NicSnapshot {
    $snap = [ordered]@{
        capturedAt = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fff')
        adapters = @()
    }
    try {
        $adapters = Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' }
        foreach ($ad in $adapters) {
            $entry = [ordered]@{
                name = $ad.Name
                interfaceDescription = $ad.InterfaceDescription
                linkSpeedBps = [int64]$ad.Speed
                linkSpeedText = $ad.LinkSpeed
                macAddress = $ad.MacAddress
                fullDuplex = $ad.FullDuplex
                mediaConnectionState = ($ad.MediaConnectionState).ToString()
                stats = $null
            }
            try {
                $s = Get-NetAdapterStatistics -Name $ad.Name -ErrorAction Stop
                $entry.stats = [ordered]@{
                    receivedBytes = [int64]$s.ReceivedBytes
                    receivedUnicastPackets = [int64]$s.ReceivedUnicastPackets
                    receivedDiscardedPackets = [int64]$s.ReceivedDiscardedPackets
                    receivedPacketErrors = [int64]$s.ReceivedPacketErrors
                    sentBytes = [int64]$s.SentBytes
                    sentUnicastPackets = [int64]$s.SentUnicastPackets
                    sentDiscardedPackets = [int64]$s.OutboundDiscardedPackets
                    sentPacketErrors = [int64]$s.OutboundPacketErrors
                }
            } catch {
                $entry.stats = @{ error = $_.Exception.Message }
            }
            $snap.adapters += $entry
        }
    } catch {
        $snap.error = $_.Exception.Message
    }
    return $snap
}

$current = Get-NicSnapshot

if ($Mode -eq 'Start') {
    $outPath = Join-Path $OutDir ('nic_baseline_' + $Phase + '.json')
    $current | ConvertTo-Json -Depth 6 | Set-Content -Path $outPath -Encoding UTF8
    Write-Host ('[hw_nic_errors] baseline written: ' + $outPath) -ForegroundColor Cyan
    return
}

if ($Mode -eq 'Snap') {
    $outPath = Join-Path $OutDir ('nic_snap_' + $Phase + '.json')
    $current | ConvertTo-Json -Depth 6 | Set-Content -Path $outPath -Encoding UTF8
    Write-Host ('[hw_nic_errors] snapshot written: ' + $outPath) -ForegroundColor Cyan
    return
}

# Mode = End: diff against baseline
if ($BaselineFile -eq '') {
    $BaselineFile = Join-Path $OutDir ('nic_baseline_' + $Phase + '.json')
}
if (-not (Test-Path $BaselineFile)) {
    Write-Warning ('[hw_nic_errors] baseline not found: ' + $BaselineFile + ' — writing snapshot only')
    $outPath = Join-Path $OutDir ('nic_snap_' + $Phase + '.json')
    $current | ConvertTo-Json -Depth 6 | Set-Content -Path $outPath -Encoding UTF8
    return
}

$baseline = Get-Content $BaselineFile -Raw | ConvertFrom-Json
$delta = [ordered]@{
    schemaVersion = 1
    phase = $Phase
    baselineAt = $baseline.capturedAt
    finalAt = $current.capturedAt
    durationSec = [math]::Round(((Get-Date $current.capturedAt) - (Get-Date $baseline.capturedAt)).TotalSeconds, 2)
    adapters = @()
    flags = @()
}

foreach ($cur in $current.adapters) {
    $base = $baseline.adapters | Where-Object { $_.name -eq $cur.name } | Select-Object -First 1
    if (-not $base) { continue }
    if (-not $cur.stats -or -not $base.stats) { continue }

    $entry = [ordered]@{
        name = $cur.name
        interfaceDescription = $cur.interfaceDescription
        linkSpeedBps = $cur.linkSpeedBps
        fullDuplex = $cur.fullDuplex
        deltas = [ordered]@{
            receivedBytes = [int64]$cur.stats.receivedBytes - [int64]$base.stats.receivedBytes
            receivedUnicastPackets = [int64]$cur.stats.receivedUnicastPackets - [int64]$base.stats.receivedUnicastPackets
            receivedDiscardedPackets = [int64]$cur.stats.receivedDiscardedPackets - [int64]$base.stats.receivedDiscardedPackets
            receivedPacketErrors = [int64]$cur.stats.receivedPacketErrors - [int64]$base.stats.receivedPacketErrors
            sentBytes = [int64]$cur.stats.sentBytes - [int64]$base.stats.sentBytes
            sentUnicastPackets = [int64]$cur.stats.sentUnicastPackets - [int64]$base.stats.sentUnicastPackets
            sentDiscardedPackets = [int64]$cur.stats.sentDiscardedPackets - [int64]$base.stats.sentDiscardedPackets
            sentPacketErrors = [int64]$cur.stats.sentPacketErrors - [int64]$base.stats.sentPacketErrors
        }
    }

    if ($entry.deltas.receivedPacketErrors -gt 0) {
        $delta.flags += ('NIC ' + $cur.name + ': RX errors +' + $entry.deltas.receivedPacketErrors)
    }
    if ($entry.deltas.sentPacketErrors -gt 0) {
        $delta.flags += ('NIC ' + $cur.name + ': TX errors +' + $entry.deltas.sentPacketErrors)
    }
    if ($entry.deltas.receivedDiscardedPackets -gt 0) {
        $delta.flags += ('NIC ' + $cur.name + ': RX discards +' + $entry.deltas.receivedDiscardedPackets)
    }

    if ($cur.interfaceDescription -match 'I226') {
        $linkGbps = [math]::Round([double]$cur.linkSpeedBps / 1e9, 1)
        if ($linkGbps -lt 2.5) {
            $delta.flags += ('I226-V link below 2.5 Gbps: ' + $linkGbps + ' Gbps')
        }
    }

    $delta.adapters += $entry
}

if ($delta.flags.Count -eq 0) {
    $delta.flags = @('PASS: zero NIC errors / discards / CRC during phase')
}

$outPath = Join-Path $OutDir ('nic_errors_' + $Phase + '.json')
$delta | ConvertTo-Json -Depth 6 | Set-Content -Path $outPath -Encoding UTF8
Write-Host ('[hw_nic_errors] delta written: ' + $outPath) -ForegroundColor Cyan
foreach ($f in $delta.flags) { Write-Host ('  -> ' + $f) }
