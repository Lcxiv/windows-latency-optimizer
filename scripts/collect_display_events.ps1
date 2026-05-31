<#
.SYNOPSIS
  Phase 1 — Collect display/GPU/power events in the incident window to JSON.
  4101 (TDR), 4097/117 (display reset/timeout), 41 (Kernel-Power), DWM 1000/1001.
.NOTES
  PowerShell 5.1, UTF-8 + BOM. [non-admin] — event-log reads do not need elevation.
#>
if (Get-Command 'Invoke-CollectDisplayEvents' -ErrorAction SilentlyContinue) { return }

function Invoke-CollectDisplayEvents {
    [CmdletBinding()]
    param(
        [datetime] $StartUtc = (Get-Date '2026-05-31 00:45:00Z'),
        [datetime] $EndUtc = (Get-Date '2026-05-31 01:30:00Z'),
        [string]   $OutFile = 'captures\inc_20260530_1800\display_events.json'
    )

    $start = $StartUtc.ToLocalTime()
    $end = $EndUtc.ToLocalTime()

    $out = [ordered]@{}

    # 4101 = canonical TDR marker (nvlddmkm stopped responding and recovered).
    $out.tdr_4101 = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 4101; StartTime = $start; EndTime = $end } -ErrorAction SilentlyContinue |
        ForEach-Object { [pscustomobject]@{ time = $_.TimeCreated.ToString('o'); provider = $_.ProviderName; msg = $_.Message } })

    # 4097/117 = display driver reset / timeout secondary markers.
    $out.display_reset = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = @(4097, 117); StartTime = $start; EndTime = $end } -ErrorAction SilentlyContinue |
        ForEach-Object { [pscustomobject]@{ time = $_.TimeCreated.ToString('o'); id = $_.Id; provider = $_.ProviderName; msg = $_.Message } })

    # 41 = Kernel-Power (dirty shutdown / no recovery). Presence => ESCALATE to hard-hang.
    $out.kernel_power_41 = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41; ProviderName = 'Microsoft-Windows-Kernel-Power'; StartTime = $start; EndTime = $end } -ErrorAction SilentlyContinue |
        ForEach-Object { [pscustomobject]@{ time = $_.TimeCreated.ToString('o'); msg = $_.Message } })

    # DWM crash markers.
    $out.dwm_app_1000_1001 = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = @(1000, 1001); StartTime = $start; EndTime = $end } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'dwm' } |
        ForEach-Object { [pscustomobject]@{ time = $_.TimeCreated.ToString('o'); id = $_.Id; msg = $_.Message } })

    $dir = Split-Path $OutFile -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $out | ConvertTo-Json -Depth 5 | Set-Content $OutFile -Encoding UTF8

    Write-Host ('4101 TDR events:        ' + $out.tdr_4101.Count)
    Write-Host ('display reset (4097/117): ' + $out.display_reset.Count)
    Write-Host ('Kernel-Power 41:        ' + $out.kernel_power_41.Count)
    Write-Host ('DWM crash (1000/1001):  ' + $out.dwm_app_1000_1001.Count)

    [pscustomobject]@{
        out             = $OutFile
        tdr_4101        = $out.tdr_4101.Count
        display_reset   = $out.display_reset.Count
        kernel_power_41 = $out.kernel_power_41.Count
        dwm_crash       = $out.dwm_app_1000_1001.Count
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-CollectDisplayEvents
}
