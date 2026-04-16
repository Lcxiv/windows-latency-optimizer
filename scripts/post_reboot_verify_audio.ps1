<#
.SYNOPSIS
    Post-reboot verification for the audio-warble fix set.

.DESCRIPTION
    Confirms that all pre-reboot changes landed after boot:
      - NVIDIA HDMI Audio MSI active (not legacy IRQ)
      - PerfLevelSrc = 0x2222 (persistent)
      - HDMI audio pinned to CPUs 6-7
      - NIC pinned to CPUs 6-7
      - AMD HD Audio still disabled
      - Razer processes still dead
    Then runs a short pipeline capture to baseline the post-fix system,
    so the dashboard shows the improvement.

.PARAMETER SkipCapture
    Skip the pipeline capture step (verification only).

.PARAMETER DurationSec
    Pipeline capture duration (default 15s; use 30+ for real comparison).
#>
[CmdletBinding()]
param(
    [switch]$SkipCapture,
    [int]$DurationSec = 15
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
Set-Location $repoRoot

Write-Host ''
Write-Host '=====================================================================' -ForegroundColor DarkCyan
Write-Host '   POST-REBOOT AUDIO-WARBLE FIX VERIFICATION' -ForegroundColor Cyan
Write-Host '=====================================================================' -ForegroundColor DarkCyan
Write-Host ''

$results = @()
function Check {
    param([string]$Name, [scriptblock]$Test, [string]$ExpectStr)
    try {
        $pass = & $Test
        $status = if ($pass) { 'PASS' } else { 'FAIL' }
        $color = if ($pass) { 'Green' } else { 'Red' }
    } catch {
        $status = 'ERROR'
        $pass = $false
        $color = 'Red'
    }
    Write-Host ('  [' + $status + '] ' + $Name + '  (expect: ' + $ExpectStr + ')') -ForegroundColor $color
    $script:results += [pscustomobject]@{ Name = $Name; Pass = $pass; Status = $status }
}

Write-Host '[1] Registry state checks' -ForegroundColor Yellow

# NVIDIA HDMI Audio MSI
$nvAudio = Get-PnpDevice -Class MEDIA -Status OK -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match 'VEN_10DE' -and $_.InstanceId -match 'HDAUDIO' } |
    Select-Object -First 1
Check 'NVIDIA HDMI Audio MSI' {
    if (-not $nvAudio) { return $false }
    $k = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $nvAudio.InstanceId + '\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties'
    $m = Get-ItemProperty $k -ErrorAction SilentlyContinue
    return ($m.MsiSupported -eq 1)
} 'MsiSupported=1'

# PerfLevelSrc
Check 'GPU PerfLevelSrc=0x2222' {
    $p = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\NVTweak' -ErrorAction SilentlyContinue).PerfLevelSrc
    return ($p -eq 0x2222)
} 'persistent P0'

# HDMI audio affinity
Check 'HDMI Audio affinity -> 6-7' {
    if (-not $nvAudio) { return $false }
    $k = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $nvAudio.InstanceId + '\Device Parameters\Interrupt Management\Affinity Policy'
    $a = Get-ItemProperty $k -ErrorAction SilentlyContinue
    if (-not $a.AssignmentSetOverride) { return $false }
    $padded = New-Object byte[] 8
    [Array]::Copy($a.AssignmentSetOverride, 0, $padded, 0, [Math]::Min($a.AssignmentSetOverride.Length, 8))
    $mask = [BitConverter]::ToUInt64($padded, 0)
    return ($a.DevicePolicy -eq 3 -and $mask -eq 0xC0)
} 'Policy=3, mask 0xC0'

# NIC affinity
$wmi = Get-CimInstance Win32_NetworkAdapter -Filter "NetEnabled=True" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'I226' } | Select-Object -First 1
Check 'NIC affinity -> 6-7' {
    if (-not $wmi) { return $false }
    $k = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $wmi.PNPDeviceID + '\Device Parameters\Interrupt Management\Affinity Policy'
    $a = Get-ItemProperty $k -ErrorAction SilentlyContinue
    if (-not $a.AssignmentSetOverride) { return $false }
    $padded = New-Object byte[] 8
    [Array]::Copy($a.AssignmentSetOverride, 0, $padded, 0, [Math]::Min($a.AssignmentSetOverride.Length, 8))
    $mask = [BitConverter]::ToUInt64($padded, 0)
    return ($a.DevicePolicy -eq 3 -and $mask -eq 0xC0)
} 'Policy=3, mask 0xC0'

# AMD audio disabled
Check 'AMD HD Audio disabled' {
    $amd = Get-PnpDevice -Class MEDIA -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match 'VEN_1002' -and $_.InstanceId -match 'HDAUDIO' } |
        Select-Object -First 1
    if (-not $amd) { return $true }
    return ($amd.Status -ne 'OK')
} 'Status=Error or absent'

# Razer processes
Check 'No RazerAppEngine processes' {
    return (-not (Get-Process -Name 'RazerAppEngine' -ErrorAction SilentlyContinue))
} '0 processes'

# NIC *SelectiveSuspend (should still be 0)
Check 'NIC *SelectiveSuspend=0' {
    $nicDriver = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}\0009'
    $v = (Get-ItemProperty $nicDriver -Name '*SelectiveSuspend' -ErrorAction SilentlyContinue).'*SelectiveSuspend'
    return ($v -eq '0')
} '0'

# NIC link state
Check 'NIC up at 1 Gbps+' {
    $n = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'I226' } | Select-Object -First 1
    return ($n.Status -eq 'Up' -and $n.LinkSpeed -match 'Gbps')
} 'Up / Gbps'

# Internet reachability
Check 'Internet reachable (1.1.1.1)' {
    $t = Test-Connection -ComputerName 1.1.1.1 -Count 1 -ErrorAction SilentlyContinue -Quiet
    return $t
} 'ping responds'

# ---------- Summary ----------
Write-Host ''
Write-Host '=====================================================================' -ForegroundColor DarkCyan
$passed = ($results | Where-Object { $_.Pass }).Count
$total = $results.Count
$score = if ($total -gt 0) { [math]::Round(($passed / $total) * 100) } else { 0 }
$color = if ($score -ge 90) { 'Green' } elseif ($score -ge 70) { 'Yellow' } else { 'Red' }
Write-Host ('  Score: ' + $passed + '/' + $total + ' (' + $score + '%)') -ForegroundColor $color

$failed = $results | Where-Object { -not $_.Pass }
if ($failed) {
    Write-Host ''
    Write-Host '  Failed checks:' -ForegroundColor Red
    $failed | ForEach-Object { Write-Host ('    - ' + $_.Name) -ForegroundColor Red }
}
Write-Host '=====================================================================' -ForegroundColor DarkCyan

# ---------- Optional capture ----------
if (-not $SkipCapture) {
    Write-Host ''
    Write-Host '[2] Baseline pipeline capture...' -ForegroundColor Yellow
    Write-Host ('    Duration: ' + $DurationSec + 's  (use pipeline.ps1 manually for longer)') -ForegroundColor Gray
    Write-Host ''
    & (Join-Path $PSScriptRoot 'pipeline.ps1') `
        -Label 'POST_REBOOT_AUDIO_FIX' `
        -Description 'After MSI + PerfLevelSrc + HDMI audio 6-7 pinning + AMD audio disable' `
        -DurationSec $DurationSec `
        -SkipWPR
}

Write-Host ''
Write-Host 'Next step to verify the warble is actually gone:' -ForegroundColor Magenta
Write-Host '  1. Open a game that previously caused warble.' -ForegroundColor Gray
Write-Host '  2. Start network activity (Discord voice, Twitch stream, or download).' -ForegroundColor Gray
Write-Host '  3. Listen for the pitch-warble symptom for 2-3 minutes.' -ForegroundColor Gray
Write-Host '  4. If it does not reproduce: fix confirmed.' -ForegroundColor Gray
Write-Host '     If it still reproduces: capture with pipeline.ps1 during the symptom' -ForegroundColor Gray
Write-Host '     and we can dig deeper (LatencyMon, xperf dpcisr).' -ForegroundColor Gray
