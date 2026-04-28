# LatencyGuard: Re-apply Defender disable after Windows Update
$gpo = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
$rtp = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'
if (-not (Test-Path $gpo)) { New-Item -Path $gpo -Force | Out-Null }
if (-not (Test-Path $rtp)) { New-Item -Path $rtp -Force | Out-Null }
Set-ItemProperty -Path $gpo -Name 'DisableAntiSpyware' -Value 1 -Type DWord
Set-ItemProperty -Path $gpo -Name 'DisableAntiVirus' -Value 1 -Type DWord
Set-ItemProperty -Path $rtp -Name 'DisableRealtimeMonitoring' -Value 1 -Type DWord
Set-ItemProperty -Path $rtp -Name 'DisableBehaviorMonitoring' -Value 1 -Type DWord
Set-ItemProperty -Path $rtp -Name 'DisableOnAccessProtection' -Value 1 -Type DWord
Set-ItemProperty -Path $rtp -Name 'DisableScanOnRealtimeEnable' -Value 1 -Type DWord
Set-ItemProperty -Path $rtp -Name 'DisableIOAVProtection' -Value 1 -Type DWord
try {
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
    Set-MpPreference -DisableBehaviorMonitoring $true -ErrorAction SilentlyContinue
    Set-MpPreference -DisableIOAVProtection $true -ErrorAction SilentlyContinue
} catch {}
