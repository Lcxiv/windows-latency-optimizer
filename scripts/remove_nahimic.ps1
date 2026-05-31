<#
.SYNOPSIS
  Full removal of Nahimic / A-Volute / Sonic Studio (ASUS-bundled audio bloatware).
  Removes the service, the kernel driver, the driver-store packages, the scheduled
  tasks, and leftover binaries. Dry-run by default; pass -Execute to act.

  Footprint removed (does NOT touch the Razer THX USB headset or base HD Audio):
    - Service   : NahimicService  (C:\Windows\System32\NahimicService.exe)
    - Driver    : AVoluteSS3Vad "Sonic Studio Virtual Mixer" (\drivers\AVoluteSS3Vad.sys)
    - DriverPkg : avolutess3ext.inf, a-volutenh3aposwc.inf, avolutess3vad.inf
    - Tasks     : NahimicTask32, NahimicTask64
    - Resurrect : disables AsusUpdateCheck (re-pushes Nahimic via ASUS/Realtek UAD)
.NOTES
  PowerShell 5.1, UTF-8 + BOM. [ADMIN REQUIRED]. Reboot after -Execute.
.EXAMPLE
  .\scripts\remove_nahimic.ps1            # dry-run (shows what it would do)
  .\scripts\remove_nahimic.ps1 -Execute   # actually remove (elevated)
#>
[CmdletBinding()]
param(
    [switch] $Execute
)

$ErrorActionPreference = 'Continue'
$mode = 'DRY-RUN'
if ($Execute) { $mode = 'EXECUTE' }
Write-Host ("=== remove_nahimic.ps1 [" + $mode + "] ===") -ForegroundColor Cyan

# Admin check
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
$elev = $pr.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if ($Execute -and -not $elev) {
    Write-Host 'ABORT: -Execute requires an elevated (admin) PowerShell.' -ForegroundColor Red
    return
}

function Do-Step {
    param([string] $Desc, [scriptblock] $Action)
    if ($Execute) {
        Write-Host ('[do]   ' + $Desc) -ForegroundColor Yellow
        try { & $Action } catch { Write-Host ('       ! ' + $_.Exception.Message) -ForegroundColor Red }
    } else {
        Write-Host ('[plan] ' + $Desc) -ForegroundColor Gray
    }
}

# 1. Stop + disable + delete the user-mode service ---------------------------
Do-Step 'Stop NahimicService'            { Stop-Service NahimicService -Force -ErrorAction SilentlyContinue }
Do-Step 'Disable NahimicService startup' { Set-Service NahimicService -StartupType Disabled -ErrorAction SilentlyContinue }
Do-Step 'Delete NahimicService'          { & sc.exe delete NahimicService | Out-Null }

# 2. Stop + delete the kernel driver -----------------------------------------
Do-Step 'Stop AVoluteSS3Vad driver'   { & sc.exe stop AVoluteSS3Vad   | Out-Null }
Do-Step 'Delete AVoluteSS3Vad driver' { & sc.exe delete AVoluteSS3Vad | Out-Null }

# 3. Scheduled tasks ----------------------------------------------------------
foreach ($t in @('NahimicTask32', 'NahimicTask64')) {
    $tn = $t
    Do-Step ('Unregister scheduled task ' + $tn) {
        Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
    }.GetNewClosure()
}

# 4. Driver-store packages (resolve oemNN.inf dynamically by Original Name) ---
$targets = @('avolutess3ext.inf', 'a-volutenh3aposwc.inf', 'avolutess3vad.inf')
$pnpText = @(pnputil /enum-drivers 2>$null)
$published = ''
$map = @{}
foreach ($ln in $pnpText) {
    if ($ln -match '^\s*Published Name:\s*(\S+)') { $published = $matches[1]; continue }
    if ($ln -match '^\s*Original Name:\s*(\S+)' -and $published) {
        $map[$matches[1].ToLower()] = $published
        $published = ''
    }
}
foreach ($t in $targets) {
    $oem = $map[$t.ToLower()]
    if ($oem) {
        $o = $oem
        Do-Step ('Delete driver package ' + $o + ' (' + $t + ') /uninstall /force') {
            & pnputil /delete-driver $o /uninstall /force | Out-Null
        }.GetNewClosure()
    } else {
        Write-Host ('[skip] driver package not found in store: ' + $t) -ForegroundColor DarkGray
    }
}

# 5. Leftover binaries --------------------------------------------------------
foreach ($f in @('C:\Windows\System32\NahimicService.exe', 'C:\Windows\System32\drivers\AVoluteSS3Vad.sys')) {
    $fp = $f
    if (Test-Path $fp) {
        Do-Step ('Remove leftover binary ' + $fp) {
            Remove-Item $fp -Force -ErrorAction SilentlyContinue
        }.GetNewClosure()
    }
}

# 6. Neutralize the resurrection vector --------------------------------------
Do-Step 'Disable AsusUpdateCheck (re-pushes Nahimic)' {
    Stop-Service AsusUpdateCheck -Force -ErrorAction SilentlyContinue
    Set-Service AsusUpdateCheck -StartupType Disabled -ErrorAction SilentlyContinue
}

Write-Host ''
if ($Execute) {
    Write-Host 'Done. REBOOT to fully unload the kernel driver + APO from audiodg.exe.' -ForegroundColor Green
    Write-Host 'Verify after reboot: Get-Service NahimicService  (should be "not found")' -ForegroundColor Green
} else {
    Write-Host 'Dry-run only. Re-run elevated with -Execute to remove.' -ForegroundColor Cyan
}
