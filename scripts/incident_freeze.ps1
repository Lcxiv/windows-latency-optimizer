<#
.SYNOPSIS
  Phase 0 — Freeze evidence for the 6PM black-screen incident (INC-20260530-1800).
  Copies in-window LiveKernelReports dumps (backup-mode), SHA256 source+copy, dumps
  CrashControl + LocalDumps + GraphicsDrivers TDR keys. READ-ONLY to system state.
.NOTES
  PowerShell 5.1, UTF-8 + BOM. [admin] — robocopy /b needs SeBackupPrivilege.
#>
if (Get-Command 'Invoke-IncidentFreeze' -ErrorAction SilentlyContinue) { return }

function Invoke-IncidentFreeze {
    [CmdletBinding()]
    param(
        [string] $Dst = 'captures\inc_20260530_1800',
        # Incident window in UTC. PT 17:45-18:30 on 5/30 = UTC 00:45-01:30 on 5/31.
        # Widened slightly for dump-file clock skew (00:30-01:45).
        [datetime] $IncLoUtc = (Get-Date '2026-05-31 00:30:00Z'),
        [datetime] $IncHiUtc = (Get-Date '2026-05-31 01:45:00Z')
    )

    $nowUtc = (Get-Date).ToUniversalTime()
    Write-Host ('Clock UTC: ' + $nowUtc.ToString('o'))

    $free = (Get-PSDrive C).Free
    if ($free -lt 2GB) {
        Write-Warning ('Low disk: ' + [math]::Round($free / 1GB, 1) + ' GB free - dump copy may fail')
    }

    New-Item -ItemType Directory -Force -Path $Dst | Out-Null

    $srcRoot = 'C:\Windows\LiveKernelReports'
    $srcDumps = @(Get-ChildItem $srcRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -ge $IncLoUtc -and $_.LastWriteTimeUtc -le $IncHiUtc })

    Write-Host ('In-window LiveKernel dumps found: ' + $srcDumps.Count)

    # SHA256 the SOURCE before copy (acceptance #3 requires source==copy match).
    $srcHashes = @{}
    foreach ($f in $srcDumps) {
        try {
            $srcHashes[$f.Name] = (Get-FileHash $f.FullName -Algorithm SHA256).Hash
        } catch {
            $srcHashes[$f.Name] = 'SOURCE_INACCESSIBLE'   # SYSTEM-locked; verify copy only, document gap
        }
    }

    # robocopy /b = backup-mode (SeBackupPrivilege) to read SYSTEM-locked dumps.
    $copyDst = Join-Path $Dst 'LiveKernelReports'
    robocopy $srcRoot $copyDst /b /e /copy:DAT /r:1 /w:1 | Out-Null
    $roboExit = $LASTEXITCODE

    # robocopy exit codes: < 8 = success/info; >= 8 = failure.
    if ($roboExit -ge 8) {
        Write-Warning ('robocopy FAILED exit=' + $roboExit + ' - LiveKernelReports inaccessible even with /b. Falling back to event-log-only (Phase 1). Documenting gap.')
        $gap = [pscustomobject]@{
            evidence_kind = 'absent'
            note          = 'LiveKernelReports inaccessible (robocopy exit ' + $roboExit + ')'
            robocopy_exit = $roboExit
        }
        $gap | ConvertTo-Json | Set-Content (Join-Path $Dst 'freeze_gap.json') -Encoding UTF8
    }

    # Manifest: compare SOURCE hash vs COPY hash. PS5.1 pitfall #3: no inline if in @{}.
    $copies = @(Get-ChildItem $copyDst -Recurse -File -ErrorAction SilentlyContinue)
    $manifest = foreach ($c in $copies) {
        $copyHash = (Get-FileHash $c.FullName -Algorithm SHA256).Hash
        $srcHash = $srcHashes[$c.Name]
        $verified = 'MISMATCH'
        if ($null -eq $srcHash) { $verified = 'no_source_record' }
        elseif ($srcHash -eq 'SOURCE_INACCESSIBLE') { $verified = 'copy_only_source_locked' }
        elseif ($srcHash -eq $copyHash) { $verified = 'match' }
        [pscustomobject]@{
            file          = $c.FullName
            copy_sha256   = $copyHash
            source_sha256 = $srcHash
            len           = $c.Length
            verified      = $verified
        }
    }
    $manifest | ConvertTo-Json | Set-Content (Join-Path $Dst 'manifest.json') -Encoding UTF8

    # Full CrashControl capture so a repeat is guaranteed-captured.
    $crashCtl = Join-Path $Dst 'crashcontrol.json'
    Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction SilentlyContinue |
        Select-Object CrashDumpEnabled, LogEvent, AlwaysKeepMemoryDump | ConvertTo-Json | Set-Content $crashCtl -Encoding UTF8
    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps' -ErrorAction SilentlyContinue |
        ConvertTo-Json | Add-Content $crashCtl -Encoding UTF8

    # TDR keys (READ only).
    Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction SilentlyContinue |
        Select-Object TdrLevel, TdrDelay, TdrDdiDelay | ConvertTo-Json | Set-Content (Join-Path $Dst 'tdr_keys.json') -Encoding UTF8

    [pscustomobject]@{
        dst             = $Dst
        dumps_in_window = $srcDumps.Count
        copies          = $copies.Count
        robocopy_exit   = $roboExit
        manifest        = (Join-Path $Dst 'manifest.json')
    }
}

# Auto-run when invoked directly (not dot-sourced into another script).
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-IncidentFreeze
}
