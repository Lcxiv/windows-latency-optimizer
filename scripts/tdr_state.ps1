<#
.SYNOPSIS
  Phase 1 — Read current TDR registry state + nvlddmkm driver version. READ-ONLY.
.NOTES
  PowerShell 5.1, UTF-8 + BOM. [non-admin] for read. (Writes would need [admin] — not done here.)
#>
if (Get-Command 'Get-TdrState' -ErrorAction SilentlyContinue) { return }

function Get-TdrState {
    [CmdletBinding()]
    param(
        [string] $OutFile = 'captures\inc_20260530_1800\tdr_state.json'
    )

    $gd = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction SilentlyContinue

    # nvlddmkm driver file version (best-effort).
    $nvPath = 'C:\Windows\System32\DriverStore\FileRepository'
    $nvVer = 'unknown'
    try {
        $nvFile = Get-ChildItem $nvPath -Recurse -Filter 'nvlddmkm.sys' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($nvFile) { $nvVer = $nvFile.VersionInfo.FileVersion }
    } catch {
        $nvVer = 'lookup_failed'
    }

    $state = [pscustomobject]@{
        TdrLevel          = $gd.TdrLevel
        TdrDelay          = $gd.TdrDelay
        TdrDdiDelay       = $gd.TdrDdiDelay
        nvlddmkm_version  = $nvVer
        collected_ts_utc  = (Get-Date).ToUniversalTime().ToString('o')
    }

    $dir = Split-Path $OutFile -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $state | ConvertTo-Json | Set-Content $OutFile -Encoding UTF8

    $state
}

if ($MyInvocation.InvocationName -ne '.') {
    Get-TdrState
}
