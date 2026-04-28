#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Rollback system polling fixes from fix_system_polling.ps1.
.DESCRIPTION
    Restores ctfmon Input settings, re-enables all disabled services,
    restores OneDrive icon overlays, re-enables Quick Access, restores
    enterprise policies and AppCompat engine.
.NOTES
    Reboot: RECOMMENDED for full effect
#>

$ErrorActionPreference = 'Stop'

Write-Host '=== RESTORE SYSTEM POLLING DEFAULTS ===' -ForegroundColor Green
Write-Host ''

# ─── Step 1: Restore ctfmon Input settings ────────────────────────────────────
Write-Host '[1/6] Restoring ctfmon Input settings...' -ForegroundColor Yellow

$imePath = 'HKLM:\SOFTWARE\Microsoft\Input\Settings\proc_1\loc_0409\im_1'
$inputSettingsPath = 'HKLM:\SOFTWARE\Microsoft\Input\Settings'
$inputSettingsUser = 'HKCU:\SOFTWARE\Microsoft\Input\Settings'

$restoreKeys = @(
    @{ Path = $imePath; Name = 'AutoCorrection'; Value = 1 },
    @{ Path = $imePath; Name = 'Prediction'; Value = 1 },
    @{ Path = $imePath; Name = 'Spellcheck'; Value = 1 },
    @{ Path = $imePath; Name = 'ShapeWriting'; Value = 1 },
    @{ Path = $imePath; Name = 'EmojiSuggestion'; Value = 1 },
    @{ Path = $imePath; Name = 'HTREnabled'; Value = 1 },
    @{ Path = $inputSettingsPath; Name = 'HarvestContacts'; Value = 1 },
    @{ Path = $inputSettingsPath; Name = 'DictationEnabled'; Value = 1 },
    @{ Path = $inputSettingsPath; Name = 'DisablePersonalization'; Value = 0 },
    @{ Path = $inputSettingsPath; Name = 'InsightsEnabled'; Value = 1 },
    @{ Path = $inputSettingsUser; Name = 'InsightsEnabled'; Value = 0 },
    @{ Path = $inputSettingsUser; Name = 'IsVoiceTypingKeyEnabled'; Value = 1 }
)

foreach ($k in $restoreKeys) {
    try {
        Set-ItemProperty -Path $k.Path -Name $k.Name -Value $k.Value -Type DWord -Force
        Write-Host ('  RESTORED ' + $k.Name + ' = ' + $k.Value) -ForegroundColor Green
    } catch {
        Write-Host ('  SKIP ' + $k.Name + ': ' + $_.Exception.Message) -ForegroundColor Yellow
    }
}

# ─── Step 2: Re-enable services ──────────────────────────────────────────────
Write-Host ''
Write-Host '[2/6] Re-enabling services...' -ForegroundColor Yellow

$services = @(
    @{ Name = 'camsvc'; StartType = 'Automatic' },
    @{ Name = 'lfsvc'; StartType = 'Manual' },
    @{ Name = 'WmiApSrv'; StartType = 'Manual' },
    @{ Name = 'CscService'; StartType = 'Manual' },
    @{ Name = 'WSearch'; StartType = 'Automatic' },
    @{ Name = 'ShellHWDetection'; StartType = 'Automatic' }
)

foreach ($svc in $services) {
    try {
        Set-Service -Name $svc.Name -StartupType $svc.StartType -ErrorAction Stop
        Write-Host ('  SET ' + $svc.Name + ': ' + $svc.StartType) -ForegroundColor Green
    } catch {
        Write-Host ('  SKIP ' + $svc.Name + ': ' + $_.Exception.Message) -ForegroundColor Yellow
    }
}

# ─── Step 3: Restore location policy ─────────────────────────────────────────
Write-Host ''
Write-Host '[3/6] Restoring location policy...' -ForegroundColor Yellow

$locPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
try {
    Remove-ItemProperty -Path $locPolicy -Name 'LetAppsAccessLocation' -ErrorAction SilentlyContinue
    Write-Host '  REMOVED LetAppsAccessLocation policy override' -ForegroundColor Green
} catch {
    Write-Host '  SKIP: policy not found' -ForegroundColor Gray
}

# ─── Step 4: Restore Explorer settings ────────────────────────────────────────
Write-Host ''
Write-Host '[4/6] Restoring Explorer settings...' -ForegroundColor Yellow

# Restore Quick Access as default
$explorerAdvanced = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Set-ItemProperty -Path $explorerAdvanced -Name 'LaunchTo' -Value 2 -Type DWord -Force
Write-Host '  SET Explorer default: Quick Access' -ForegroundColor Green

# Note about OneDrive overlays
Write-Host ''
Write-Host '  NOTE: OneDrive icon overlays must be re-registered manually if needed.' -ForegroundColor Yellow
Write-Host '  Reinstall OneDrive or run OneDriveSetup.exe to restore them.' -ForegroundColor Yellow

# ─── Step 5: Restore enterprise policies ─────────────────────────────────────
Write-Host ''
Write-Host '[5/6] Restoring enterprise policies...' -ForegroundColor Yellow

# Remove WIP/DataProtection policy overrides
$wipPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataProtection'
Remove-ItemProperty -Path $wipPath -Name 'AllowDirectMemoryAccess' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $wipPath -Name 'AllowAzureRMSForEDP' -ErrorAction SilentlyContinue
Write-Host '  REMOVED DataProtection policy overrides' -ForegroundColor Green

$edpPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\EnterpriseDataProtection'
Remove-ItemProperty -Path $edpPath -Name 'EnterpriseProtectedDomainNames' -ErrorAction SilentlyContinue
Write-Host '  REMOVED EnterpriseDataProtection overrides' -ForegroundColor Green

# ─── Step 6: Restore AppCompat engine ────────────────────────────────────────
Write-Host ''
Write-Host '[6/6] Restoring AppCompat engine...' -ForegroundColor Yellow

$appCompatPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat'
Remove-ItemProperty -Path $appCompatPath -Name 'DisableEngine' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $appCompatPath -Name 'DisablePCA' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $appCompatPath -Name 'DisableUAR' -ErrorAction SilentlyContinue
Write-Host '  REMOVED AppCompat disable overrides (engine re-enabled)' -ForegroundColor Green

Write-Host ''
Write-Host 'System polling defaults restored. Reboot recommended.' -ForegroundColor Green
