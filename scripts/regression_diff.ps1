<#
.SYNOPSIS
  Phase 1 - Diff current GPU/display driver state against the afternoon
  GPU-remediation backups (15:33 / 15:51) to detect a live regression. READ-ONLY.

  v2 (scope-matched, structured): the v1 whole-text Compare-Object produced 207
  unreliable deltas from format noise, not real regressions:
    - header line "# GPU remediation backup <timestamp>" (volatile timestamp)
    - nvidia-smi "pstate" field (volatile: P0 under load, P8 at idle)
    - "=== nvidia-smi ===" / "=== loaded nvlddmkm ===" / "Bound INF" sections
      that the v1 current-state text never emitted
    - oemNN.inf "Published Name" renumbering after the DDU reinstall
    - unrelated AMD/Intel/Razer/Bluetooth driver enumeration order

  v2 parses BOTH sides into the SAME structured shape and compares only what a
  GPU remediation could actually regress:
    1. Display/NVIDIA driver records, keyed on Original-INF + Driver-Version
       (immune to oemNN renumber), filtered to the display subsystem.
    2. GPU scalars: device status, bound INF, nvidia-smi name/driver_version/vbios
       (pstate deliberately excluded), loaded nvlddmkm service state.
.NOTES
  PowerShell 5.1, UTF-8 + BOM. [non-admin]. Read-only - no registry/system writes.
#>
if (Get-Command 'Invoke-RegressionDiff' -ErrorAction SilentlyContinue) { return }

function ConvertTo-DriverRecords {
    # Parse pnputil /enum-drivers text (from a backup file OR a live run) into
    # per-driver records, filtered to the display subsystem. Same parser is used
    # on both sides => identical scope, no format-noise deltas.
    param([string[]] $Lines)
    $records = New-Object System.Collections.Generic.List[object]
    $cur = $null
    foreach ($ln in $Lines) {
        if ($ln -match '^\s*Published Name:\s*(.+?)\s*$') {
            if ($cur) { $records.Add($cur) }
            $cur = [pscustomobject]@{ Published = $matches[1]; Original = ''; Provider = ''; Class = ''; Version = '' }
            continue
        }
        if ($null -eq $cur) { continue }
        if ($ln -match '^\s*Original Name:\s*(.+?)\s*$')  { $cur.Original = $matches[1]; continue }
        if ($ln -match '^\s*Provider Name:\s*(.+?)\s*$')  { $cur.Provider = $matches[1]; continue }
        if ($ln -match '^\s*Class Name:\s*(.+?)\s*$')     { $cur.Class    = $matches[1]; continue }
        if ($ln -match '^\s*Driver Version:\s*(.+?)\s*$') { $cur.Version  = $matches[1]; continue }
    }
    if ($cur) { $records.Add($cur) }

    $records | Where-Object {
        $_.Class -eq 'Display' -or
        $_.Provider -match 'NVIDIA' -or
        $_.Original -match 'nvlddmkm|nv_disp|nvhda|nvpcf|nvppc'
    }
}

function Get-BackupScalars {
    # Pull GPU scalars out of a backup file's text.
    param([string[]] $Lines)
    $o = [pscustomobject]@{ DeviceStatus = ''; BoundInf = ''; SmiKey = ''; NvlddmkmState = '' }
    foreach ($ln in $Lines) {
        if ($ln -match 'status=(\S+)')                       { $o.DeviceStatus  = $matches[1]; continue }
        if ($ln -match '^\s*Bound INF\s*:\s*(.+?)\s*$')      { $o.BoundInf      = $matches[1]; continue }
        if ($ln -match '^\s*State=(\S+)\s+Path=')            { $o.NvlddmkmState = $matches[1]; continue }
        if ($ln -match '^\s*NVIDIA GeForce.*,.*,.*,.*')      { $o.SmiKey        = (Get-SmiKey $ln); continue }
    }
    $o
}

function Get-SmiKey {
    # name|driver_version|vbios  -- pstate (field 3) intentionally dropped (volatile).
    param([string] $SmiLine)
    if (-not $SmiLine) { return '' }
    $parts = $SmiLine -split ','
    $name = ''; $drv = ''; $vbios = ''
    if ($parts.Count -ge 1) { $name  = $parts[0].Trim() }
    if ($parts.Count -ge 2) { $drv   = $parts[1].Trim() }
    if ($parts.Count -ge 4) { $vbios = $parts[3].Trim() }
    $name + '|' + $drv + '|' + $vbios
}

function Get-CurrentState {
    # Live current state, built to match the backup structure exactly.
    $pnp = @(pnputil /enum-drivers 2>$null)
    $records = @(ConvertTo-DriverRecords -Lines $pnp)

    # Find the physical GPU by hardware ID (VEN_10DE), NOT by FriendlyName: once the
    # NVIDIA driver is gone the device reports as "Microsoft Basic Display Adapter".
    $dev = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match 'VEN_10DE' } | Select-Object -First 1
    $devStatus = ''
    if ($dev) { $devStatus = [string]$dev.Status }

    $boundInf = ''
    if ($dev) {
        $bi = (Get-PnpDeviceProperty -InstanceId $dev.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction SilentlyContinue).Data
        if ($bi) { $boundInf = [string]$bi }
    }

    $smiKey = ''
    try {
        $raw = @(& nvidia-smi --query-gpu=name,driver_version,pstate,vbios_version --format=csv,noheader 2>$null)
        if ($raw.Count -gt 0) { $smiKey = Get-SmiKey ($raw[0].Trim()) }
    } catch { $smiKey = '' }

    $nvState = ''
    try {
        $drv = Get-CimInstance Win32_SystemDriver -Filter "Name='nvlddmkm'" -ErrorAction SilentlyContinue
        if ($drv) { $nvState = [string]$drv.State }
    } catch { $nvState = '' }

    # Derived: is the NVIDIA display stack actually present/active right now?
    # Present requires BOTH a live NVIDIA driver record AND a registered nvlddmkm service.
    $hasNvRecord = @($records | Where-Object { $_.Provider -match 'NVIDIA' -or $_.Original -match 'nv_disp|nvlddmkm' }).Count -gt 0
    $nvPresent = ($hasNvRecord -and $nvState -ne '')

    [pscustomobject]@{
        records    = $records
        nv_present = $nvPresent
        scalars    = [pscustomobject]@{ DeviceStatus = $devStatus; BoundInf = $boundInf; SmiKey = $smiKey; NvlddmkmState = $nvState }
    }
}

function Compare-DriverSet {
    param($Ref, $Cur)
    $refKeys = @{}
    foreach ($r in $Ref) { $refKeys[($r.Original + '|' + $r.Version)] = $r }
    $curKeys = @{}
    foreach ($c in $Cur) { $curKeys[($c.Original + '|' + $c.Version)] = $c }

    $deltas = New-Object System.Collections.Generic.List[object]
    foreach ($k in $refKeys.Keys) {
        if (-not $curKeys.ContainsKey($k)) {
            $rr = $refKeys[$k]
            $deltas.Add([pscustomobject]@{ change = 'removed_since_backup'; driver = $rr.Original; version = $rr.Version; class = $rr.Class })
        }
    }
    foreach ($k in $curKeys.Keys) {
        if (-not $refKeys.ContainsKey($k)) {
            $cc = $curKeys[$k]
            $deltas.Add([pscustomobject]@{ change = 'added_since_backup'; driver = $cc.Original; version = $cc.Version; class = $cc.Class })
        }
    }
    $deltas
}

function Compare-Scalars {
    param($Ref, $Cur)
    $deltas = New-Object System.Collections.Generic.List[object]
    $fields = @('DeviceStatus', 'BoundInf', 'SmiKey', 'NvlddmkmState')
    foreach ($f in $fields) {
        $rv = [string]$Ref.$f
        $cv = [string]$Cur.$f
        # Only flag when the backup actually recorded a value; absent-in-backup is not a regression.
        if ($rv -ne '' -and $rv -ne $cv) {
            $deltas.Add([pscustomobject]@{ field = $f; backup = $rv; current = $cv })
        }
    }
    $deltas
}

function Invoke-RegressionDiff {
    [CmdletBinding()]
    param(
        [string[]] $Backups = @(
            'captures\gpu_remediation_backup_20260530_153355.txt',
            'captures\gpu_remediation_backup_20260530_155104.txt'
        ),
        [string] $OutFile = 'captures\inc_20260530_1800\regression_diff.json'
    )

    $cur = Get-CurrentState

    $results = foreach ($b in $Backups) {
        if (-not (Test-Path $b)) {
            [pscustomobject]@{ backup = $b; status = 'missing'; record_deltas = @(); scalar_deltas = @(); delta_count = 0; verdict = 'REGRESSION_INDETERMINATE_NO_BACKUP' }
            continue
        }
        $refLines     = @(Get-Content $b -ErrorAction SilentlyContinue)
        $refRecords   = @(ConvertTo-DriverRecords -Lines $refLines)
        $refScalars   = Get-BackupScalars -Lines $refLines

        $recordDeltas = @(Compare-DriverSet -Ref $refRecords -Cur $cur.records)
        $scalarDeltas = @(Compare-Scalars   -Ref $refScalars -Cur $cur.scalars)
        $count        = $recordDeltas.Count + $scalarDeltas.Count

        # If the backup recorded a healthy NVIDIA stack but it is absent now, that is a
        # CONFIRMED critical regression (driver unbound to Basic Display Adapter) - not a
        # mere version drift, and not a collection artifact.
        $refHadNv = ($refScalars.NvlddmkmState -ne '' -or @($refRecords | Where-Object { $_.Provider -match 'NVIDIA' }).Count -gt 0)
        $verdict = 'REGRESSION_ELIMINATED'
        if ($refHadNv -and -not $cur.nv_present) {
            $verdict = 'REGRESSION_CONFIRMED_NVIDIA_DRIVER_ABSENT'
        } elseif ($count -gt 0) {
            $verdict = 'REGRESSION_SUSPECTED'
        }

        [pscustomobject]@{
            backup            = $b
            status            = 'compared'
            ref_record_n      = $refRecords.Count
            cur_record_n      = $cur.records.Count
            nvidia_present_now = $cur.nv_present
            current_bound_inf = $cur.scalars.BoundInf
            record_deltas     = $recordDeltas
            scalar_deltas     = $scalarDeltas
            delta_count       = $count
            verdict           = $verdict
        }
    }

    $dir = Split-Path $OutFile -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $results | ConvertTo-Json -Depth 6 | Set-Content $OutFile -Encoding UTF8

    foreach ($r in $results) {
        Write-Host ($r.backup + ' -> ' + $r.status + ' deltas=' + $r.delta_count + ' verdict=' + $r.verdict)
    }
    $results
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-RegressionDiff
}
