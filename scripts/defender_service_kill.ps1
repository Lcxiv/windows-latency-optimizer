<#
.SYNOPSIS
    Disable WinDefend/WdNisSvc services via TrustedInstaller token impersonation.
.DESCRIPTION
    Win11 24H2 protects Defender service registry keys with kernel callbacks
    AND TrustedInstaller ACLs. Simple ownership takeover fails.

    This script impersonates the TrustedInstaller service token — the same
    technique Sordum Defender Control uses — then modifies registry keys
    while running AS TrustedInstaller.

    Flow:
      1. Start TrustedInstaller service
      2. Open its process token
      3. Duplicate token + impersonate on current thread
      4. Modify service Start registry values
      5. Revert impersonation

    Requires: Admin + Tamper Protection OFF.
    Reversible: Run with -Restore to set Start back to defaults.
.PARAMETER Restore
    Restore WinDefend (Start=2) and WdNisSvc (Start=3) to defaults.
#>
#Requires -RunAsAdministrator
param(
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'

# ── P/Invoke: Token impersonation primitives ────────────────────────────────

Add-Type @'
using System;
using System.Runtime.InteropServices;

public class TrustedInstallerHelper {
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    static extern bool DuplicateTokenEx(
        IntPtr hExistingToken,
        uint dwDesiredAccess,
        IntPtr lpTokenAttributes,
        int ImpersonationLevel,       // 2 = SecurityImpersonation
        int TokenType,                 // 1 = TokenImpersonation
        out IntPtr phNewToken);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool ImpersonateLoggedOnUser(IntPtr hToken);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool RevertToSelf();

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out long lpLuid);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges,
        ref TOKEN_PRIVILEGES NewState, int BufferLength, IntPtr PreviousState, IntPtr ReturnLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr hObject);

    struct TOKEN_PRIVILEGES {
        public int PrivilegeCount;
        public long Luid;
        public int Attributes;
    }

    const uint TOKEN_DUPLICATE = 0x0002;
    const uint TOKEN_IMPERSONATE = 0x0004;
    const uint TOKEN_QUERY = 0x0008;
    const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
    const uint TOKEN_ALL_ACCESS = 0xF01FF;
    const uint PROCESS_QUERY_INFORMATION = 0x0400;

    public static void EnablePrivilege(string privilege) {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token))
            throw new Exception("OpenProcessToken failed: " + Marshal.GetLastWin32Error());

        TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
        tp.PrivilegeCount = 1;
        tp.Attributes = 2; // SE_PRIVILEGE_ENABLED
        if (!LookupPrivilegeValue(null, privilege, out tp.Luid))
            throw new Exception("LookupPrivilegeValue failed: " + Marshal.GetLastWin32Error());

        if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero))
            throw new Exception("AdjustTokenPrivileges failed: " + Marshal.GetLastWin32Error());
        CloseHandle(token);
    }

    public static IntPtr GetTrustedInstallerToken(int pid) {
        IntPtr hProcess = OpenProcess(PROCESS_QUERY_INFORMATION, false, pid);
        if (hProcess == IntPtr.Zero)
            throw new Exception("OpenProcess(TI) failed: " + Marshal.GetLastWin32Error());

        IntPtr hToken;
        if (!OpenProcessToken(hProcess, TOKEN_DUPLICATE | TOKEN_IMPERSONATE | TOKEN_QUERY, out hToken)) {
            CloseHandle(hProcess);
            throw new Exception("OpenProcessToken(TI) failed: " + Marshal.GetLastWin32Error());
        }

        IntPtr hDupToken;
        // SecurityImpersonation=2, TokenImpersonation=2
        if (!DuplicateTokenEx(hToken, TOKEN_ALL_ACCESS, IntPtr.Zero, 2, 2, out hDupToken)) {
            CloseHandle(hToken);
            CloseHandle(hProcess);
            throw new Exception("DuplicateTokenEx failed: " + Marshal.GetLastWin32Error());
        }

        CloseHandle(hToken);
        CloseHandle(hProcess);
        return hDupToken;
    }

    public static bool Impersonate(IntPtr hToken) {
        return ImpersonateLoggedOnUser(hToken);
    }

    public static bool Revert() {
        return RevertToSelf();
    }
}
'@

# ── Functions ───────────────────────────────────────────────────────────────

function Start-TrustedInstallerImpersonation {
    # Enable required privileges on our process
    [TrustedInstallerHelper]::EnablePrivilege('SeDebugPrivilege')
    [TrustedInstallerHelper]::EnablePrivilege('SeImpersonatePrivilege')

    # Start TrustedInstaller service if not running
    $tiSvc = Get-Service TrustedInstaller -ErrorAction SilentlyContinue
    if ($null -eq $tiSvc) {
        Write-Host 'TrustedInstaller service not found!' -ForegroundColor Red
        return $null
    }
    if ($tiSvc.Status -ne 'Running') {
        Write-Host 'Starting TrustedInstaller service...' -ForegroundColor Gray
        Start-Service TrustedInstaller
        Start-Sleep -Seconds 2
    }

    # Get TrustedInstaller PID
    $tiProc = Get-Process -Name TrustedInstaller -ErrorAction SilentlyContinue
    if ($null -eq $tiProc) {
        Write-Host 'Cannot find TrustedInstaller process!' -ForegroundColor Red
        return $null
    }
    $tiPid = $tiProc.Id
    Write-Host ('TrustedInstaller PID: ' + $tiPid) -ForegroundColor Gray

    # Get duplicated token
    $token = [TrustedInstallerHelper]::GetTrustedInstallerToken($tiPid)
    if ($token -eq [IntPtr]::Zero) {
        Write-Host 'Failed to duplicate TrustedInstaller token!' -ForegroundColor Red
        return $null
    }

    # Impersonate
    $ok = [TrustedInstallerHelper]::Impersonate($token)
    if (-not $ok) {
        Write-Host 'ImpersonateLoggedOnUser failed!' -ForegroundColor Red
        return $null
    }

    Write-Host 'Now running as TrustedInstaller' -ForegroundColor Green
    return $token
}

function Stop-TrustedInstallerImpersonation {
    [TrustedInstallerHelper]::Revert() | Out-Null
    Write-Host 'Reverted to admin identity' -ForegroundColor Green
}

function Set-ServiceStart {
    param(
        [string]$ServiceName,
        [int]$StartValue
    )

    $keyPath = 'SYSTEM\CurrentControlSet\Services\' + $ServiceName

    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($keyPath, $true)
        if ($null -eq $key) {
            Write-Host ($ServiceName + ': cannot open key (even as TI)') -ForegroundColor Red
            return $false
        }

        $oldValue = $key.GetValue('Start')
        if ($oldValue -eq $StartValue) {
            Write-Host ($ServiceName + ': already Start=' + $StartValue) -ForegroundColor Green
            $key.Close()
            return $true
        }

        $key.SetValue('Start', $StartValue, [Microsoft.Win32.RegistryValueKind]::DWord)
        $newValue = $key.GetValue('Start')
        $key.Close()

        if ($newValue -eq $StartValue) {
            Write-Host ($ServiceName + ': Start ' + $oldValue + ' -> ' + $StartValue + ' [SUCCESS]') -ForegroundColor Cyan
            return $true
        } else {
            Write-Host ($ServiceName + ': write appeared OK but readback=' + $newValue + ' (kernel callback blocked?)') -ForegroundColor Red
            return $false
        }
    } catch {
        Write-Host ($ServiceName + ': ' + $_.Exception.Message) -ForegroundColor Red
        return $false
    }
}

# ── Main ────────────────────────────────────────────────────────────────────

Write-Host ''

# Verify Tamper Protection is OFF
$tpValue = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Name 'TamperProtection' -ErrorAction SilentlyContinue).TamperProtection
if ($tpValue -ne 4 -and $tpValue -ne 0) {
    Write-Host ('ABORT: Tamper Protection is ON (value=' + $tpValue + ')') -ForegroundColor Red
    Write-Host 'Disable TP first: Windows Security > Virus & threat protection > Manage settings > Tamper Protection OFF' -ForegroundColor Yellow
    exit 1
}
Write-Host ('Tamper Protection: OFF (value=' + $tpValue + ')') -ForegroundColor Green

# Impersonate TrustedInstaller
$token = Start-TrustedInstallerImpersonation
if ($null -eq $token) {
    Write-Host 'Failed to impersonate TrustedInstaller. Aborting.' -ForegroundColor Red
    exit 1
}

try {
    if ($Restore) {
        Write-Host '=== Restoring Defender Services ===' -ForegroundColor Yellow
        $ok1 = Set-ServiceStart -ServiceName 'WinDefend' -StartValue 2
        $ok2 = Set-ServiceStart -ServiceName 'WdNisSvc' -StartValue 3
        Write-Host ''
        if ($ok1 -and $ok2) {
            Write-Host 'Services restored to defaults. Reboot to apply.' -ForegroundColor Green
        }
    } else {
        Write-Host '=== Disabling Defender Services ===' -ForegroundColor Red
        $ok1 = Set-ServiceStart -ServiceName 'WinDefend' -StartValue 4
        $ok2 = Set-ServiceStart -ServiceName 'WdNisSvc' -StartValue 4
        Write-Host ''
        if ($ok1 -and $ok2) {
            Write-Host 'Both services disabled. Reboot required.' -ForegroundColor Green
            Write-Host 'MsMpEng.exe will NOT load after reboot.' -ForegroundColor Green
        } else {
            Write-Host 'Some services could not be disabled.' -ForegroundColor Yellow
            Write-Host 'Kernel callback may be blocking. Try Safe Mode as last resort.' -ForegroundColor Yellow
        }
        Write-Host ''
        Write-Host 'To restore: .\defender_service_kill.ps1 -Restore' -ForegroundColor DarkCyan
    }
} finally {
    # Always revert impersonation
    Stop-TrustedInstallerImpersonation
}
