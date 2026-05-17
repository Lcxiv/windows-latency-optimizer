#Requires -RunAsAdministrator
<#
.SYNOPSIS
    DWM health audit checks (Deep Tier).
.DESCRIPTION
    DWM composition state, Themes service, TDR level, legacy Aero-disable keys,
    OverlayTestMode, UE launcher compatibility cross-check.
#>

# ---------------------------------------------------------------------------
# Deep Tier: DWM Health / UE Launcher Compatibility
# ---------------------------------------------------------------------------
# Rationale: EXP11/EXP13 mitigations + legacy Aero-disable keys + TDR disable
# can break UE-based launchers (Epic Games Launcher hard-asserts on
# DwmExtendFrameIntoClientArea at WindowsWindow.cpp:363).
# See: memory/project_dwm_mpo_ue_crash.md, exp11_stutter_fixes_apply.ps1:16
# ---------------------------------------------------------------------------
function Invoke-DWMHealthChecks {
    $results = @()

    # --- Check A: DWM Composition Enabled (live state via P/Invoke) ---
    $comp = $false
    $compChecked = $false
    try {
        if (-not ('DwmCheck.Api' -as [type])) {
            Add-Type -Namespace DwmCheck -Name Api -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmIsCompositionEnabled(out bool pfEnabled);
'@ -ErrorAction Stop
        }
        [DwmCheck.Api]::DwmIsCompositionEnabled([ref]$comp) | Out-Null
        $compChecked = $true
    } catch {}
    if (-not $compChecked) {
        $results += New-CheckResult -Name 'DWM Composition Enabled' -Category 'DWM' -Tier 'Deep' -Severity 'CRITICAL' `
            -Status 'ERROR' -Current 'P/Invoke failed' -Expected 'Enabled' `
            -Message 'Could not query DwmIsCompositionEnabled.'
    } elseif ($comp) {
        $results += New-CheckResult -Name 'DWM Composition Enabled' -Category 'DWM' -Tier 'Deep' -Severity 'CRITICAL' `
            -Status 'PASS' -Current 'Enabled' -Expected 'Enabled' `
            -Message 'DWM composition active. UE-based launchers initialize cleanly.'
    } else {
        $results += New-CheckResult -Name 'DWM Composition Enabled' -Category 'DWM' -Tier 'Deep' -Severity 'CRITICAL' `
            -Status 'FAIL' -Current 'Disabled' -Expected 'Enabled' `
            -Message 'DWM composition is off. Every UE-based launcher will assert on DwmExtendFrameIntoClientArea (WindowsWindow.cpp:363).' `
            -Fix 'Start-Service Themes; Stop-Process -Name dwm -Force' `
            -FixNote 'DWM auto-restarts after kill. No reboot required.'
    }

    # --- Check B: Themes Service Running + Automatic ---
    $themes = $null
    try { $themes = Get-Service Themes -ErrorAction Stop } catch {}
    if ($null -eq $themes) {
        $results += New-CheckResult -Name 'Themes Service' -Category 'DWM' -Tier 'Deep' -Severity 'CRITICAL' `
            -Status 'ERROR' -Current 'Service not found' -Expected 'Running/Automatic' `
            -Message 'Themes service missing. DWM composition will not start.'
    } elseif ($themes.Status -eq 'Running' -and $themes.StartType -eq 'Automatic') {
        $results += New-CheckResult -Name 'Themes Service' -Category 'DWM' -Tier 'Deep' -Severity 'CRITICAL' `
            -Status 'PASS' -Current 'Running/Automatic' -Expected 'Running/Automatic'
    } elseif ($themes.Status -ne 'Running') {
        $currentState = [string]$themes.Status + '/' + [string]$themes.StartType
        $results += New-CheckResult -Name 'Themes Service' -Category 'DWM' -Tier 'Deep' -Severity 'CRITICAL' `
            -Status 'FAIL' -Current $currentState -Expected 'Running/Automatic' `
            -Message 'Themes service stopped. DWM composition fails. UE apps assert on window init.' `
            -Fix 'Set-Service Themes -StartupType Automatic; Start-Service Themes'
    } else {
        $currentState = 'Running/' + [string]$themes.StartType
        $results += New-CheckResult -Name 'Themes Service' -Category 'DWM' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'WARN' -Current $currentState -Expected 'Running/Automatic' `
            -Message 'Themes running but not set to Automatic. Will fail to start after next reboot.' `
            -Fix 'Set-Service Themes -StartupType Automatic'
    }

    # --- Check C: TdrLevel Sanity ---
    $gdKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    $tdr = $null
    try { $tdr = (Get-ItemProperty $gdKey -ErrorAction Stop).TdrLevel } catch {}
    $tdrDisplay = 'Not set (default=3)'
    if ($null -ne $tdr) { $tdrDisplay = [string]$tdr }
    if ($null -eq $tdr -or $tdr -ge 2) {
        $results += New-CheckResult -Name 'TdrLevel Sanity' -Category 'DWM' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'PASS' -Current $tdrDisplay -Expected '>= 2 or absent' `
            -Message 'GPU TDR recovery enabled. DWM can recover from transient GPU hangs.'
    } elseif ($tdr -eq 0) {
        $results += New-CheckResult -Name 'TdrLevel Sanity' -Category 'DWM' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'FAIL' -Current '0 (detection off)' -Expected '>= 2 or absent' `
            -Message 'TdrLevel=0 disables GPU TDR recovery. Any GPU hang permanently wedges DWM.' `
            -Fix 'Remove-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name TdrLevel -ErrorAction SilentlyContinue' `
            -FixNote 'Reboot required'
    } else {
        $results += New-CheckResult -Name 'TdrLevel Sanity' -Category 'DWM' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current $tdrDisplay -Expected '>= 2 or absent' `
            -Message 'TdrLevel=1 detects hangs but does not recover. DWM may stay wedged after GPU hang.'
    }

    # --- Check D: Legacy Aero-Disable Registry (HKCU) ---
    # FAIL only if value=0 (actual Aero-disable). WARN on presence with non-zero value
    # (suspicious — usually set by debloat scripts — but not actively breaking).
    $dwmUser = 'HKCU:\Software\Microsoft\Windows\DWM'
    $legacyDisabled = @()
    $legacyPresent = @()
    try {
        $props = Get-ItemProperty $dwmUser -ErrorAction Stop
        foreach ($k in 'CompositionPolicy','Composition','ForceEffectMode') {
            $v = $props.$k
            if ($null -ne $v) {
                $legacyPresent += ($k + '=' + [string]$v)
                if ($v -eq 0) { $legacyDisabled += ($k + '=0') }
            }
        }
    } catch {}
    if ($legacyDisabled.Count -gt 0) {
        $results += New-CheckResult -Name 'Legacy Aero-Disable' -Category 'DWM' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'FAIL' -Current ($legacyDisabled -join '; ') -Expected 'None or enabled (=1)' `
            -Message 'Win7-era Aero-disable keys present under HKCU\...\DWM with value=0. UE honors these — WindowsWindow.cpp:363 will hard-assert on launch.' `
            -Fix 'Remove-ItemProperty "HKCU:\Software\Microsoft\Windows\DWM" -Name CompositionPolicy,Composition,ForceEffectMode -ErrorAction SilentlyContinue' `
            -FixNote 'Sign out / sign in required for HKCU policy to take effect.'
    } elseif ($legacyPresent.Count -gt 0) {
        $results += New-CheckResult -Name 'Legacy Aero-Disable' -Category 'DWM' -Tier 'Deep' -Severity 'LOW' `
            -Status 'WARN' -Current ($legacyPresent -join '; ') -Expected 'None present' `
            -Message 'Legacy HKCU DWM policy keys present but enabled (=1). Not actively breaking but suggests debloat-script residue. Safe to remove.' `
            -Fix 'Remove-ItemProperty "HKCU:\Software\Microsoft\Windows\DWM" -Name CompositionPolicy,Composition,ForceEffectMode -ErrorAction SilentlyContinue'
    } else {
        $results += New-CheckResult -Name 'Legacy Aero-Disable' -Category 'DWM' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'PASS' -Current 'None present' -Expected 'None present' `
            -Message 'No Win7-era Aero-disable keys found.'
    }

    # --- Check E: Legacy OverlayTestMode (UE-Compat Warning on 24H2/25H2) ---
    $dwmSys = 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm'
    $otm = $null
    try { $otm = (Get-ItemProperty $dwmSys -ErrorAction Stop).OverlayTestMode } catch {}
    if ($null -eq $otm) {
        $results += New-CheckResult -Name 'OverlayTestMode (Legacy)' -Category 'DWM' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'Absent' -Expected 'Absent on 24H2/25H2' `
            -Message 'No legacy OverlayTestMode value present. Modern DisableOverlays controls MPO.'
    } elseif ($otm -eq 5) {
        $results += New-CheckResult -Name 'OverlayTestMode (Legacy)' -Category 'DWM' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current 'OverlayTestMode=5' -Expected 'Absent on 24H2/25H2' `
            -Message 'Legacy MPO-disable key set. Does not control MPO on 24H2/25H2 (use DisableOverlays instead). Residual value may trigger UE launcher asserts on fullscreen-exclusive game launch.' `
            -Source 'exp11_stutter_fixes_apply.ps1:16' `
            -Fix 'Remove-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\Dwm" -Name OverlayTestMode -ErrorAction SilentlyContinue' `
            -FixNote 'Reboot required. Safe — MPO still controlled via GraphicsDrivers\DisableOverlays (EXP11 modern path).'
    } else {
        $results += New-CheckResult -Name 'OverlayTestMode (Legacy)' -Category 'DWM' -Tier 'Deep' -Severity 'LOW' `
            -Status 'WARN' -Current ('OverlayTestMode=' + [string]$otm) -Expected 'Absent on 24H2/25H2' `
            -Message 'Legacy key present with non-standard value.'
    }

    # --- Check F: UE Launcher Compatibility Cross-Check ---
    $compatRisks = @()
    if ($compChecked -and -not $comp) { $compatRisks += 'composition off' }
    if ($null -ne $themes -and $themes.Status -ne 'Running') { $compatRisks += 'Themes stopped' }
    if ($legacyDisabled.Count -gt 0) { $compatRisks += 'legacy Aero disable' }
    if ($null -ne $otm -and $otm -eq 5) { $compatRisks += 'OverlayTestMode=5' }

    if ($compatRisks.Count -eq 0) {
        $results += New-CheckResult -Name 'UE Launcher Compatibility' -Category 'DWM' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'PASS' -Current 'OK' -Expected 'OK' `
            -Message 'Epic Games Launcher / UE-based apps should initialize cleanly.'
    } else {
        $compatCurrent = $compatRisks -join '; '
        $results += New-CheckResult -Name 'UE Launcher Compatibility' -Category 'DWM' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'FAIL' -Current $compatCurrent -Expected 'OK' `
            -Message 'Epic Games Launcher will likely hard-assert at DwmExtendFrameIntoClientArea (WindowsWindow.cpp:363) on fullscreen-exclusive game launch (GRB, older AnvilNext, pre-UE5 titles). Workaround: Epic Settings -> "Exit after launch" = ON, or set games to Borderless Windowed.' `
            -Source 'memory/project_dwm_mpo_ue_crash.md' `
            -FixNote 'Address each listed risk via checks A-E above.'
    }

    return $results
}
