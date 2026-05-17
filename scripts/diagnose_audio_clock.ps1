# Diagnose HDMI audio pitch-warble: PCIe ASPM, GPU P-state, NIC EEE, audio MSI
# Pitch warble = clock drift, not DPC latency. Focus on power states and clock sources.
[CmdletBinding()]
param(
    [switch]$Detailed
)

$OutputEncoding = [System.Text.UTF8Encoding]::new()

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
}

# ---------- 1. HDMI Audio device ----------
Write-Section '[1/6] NVIDIA HDMI Audio Device — MSI & Affinity'
$audioDevs = Get-PnpDevice -Class MEDIA -Status OK -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -match 'NVIDIA|High Definition' }

if (-not $audioDevs) {
    Write-Host '[FAIL] No NVIDIA HDMI audio device found in MEDIA class.' -ForegroundColor Red
} else {
    foreach ($d in $audioDevs) {
        Write-Host ''
        Write-Host ('>> ' + $d.FriendlyName) -ForegroundColor Yellow
        Write-Host ('   InstanceId: ' + $d.InstanceId)
        $base = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $d.InstanceId + '\Device Parameters\Interrupt Management'
        $msiKey = Join-Path $base 'MessageSignaledInterruptProperties'
        $affKey = Join-Path $base 'Affinity Policy'
        if (Test-Path $msiKey) {
            $msi = Get-ItemProperty $msiKey -ErrorAction SilentlyContinue
            Write-Host ('   MsiSupported       : ' + $msi.MsiSupported) -ForegroundColor $(if ($msi.MsiSupported -eq 1) {'Green'} else {'Red'})
            Write-Host ('   MessageNumberLimit : ' + $msi.MessageNumberLimit)
        } else {
            Write-Host '   [MSI key absent — using legacy line-based interrupts]' -ForegroundColor Red
        }
        if (Test-Path $affKey) {
            $aff = Get-ItemProperty $affKey -ErrorAction SilentlyContinue
            Write-Host ('   DevicePolicy       : ' + $aff.DevicePolicy)
            if ($aff.AssignmentSetOverride) {
                $hex = [BitConverter]::ToString($aff.AssignmentSetOverride) -replace '-',''
                Write-Host ('   AssignmentOverride : 0x' + $hex)
            }
        } else {
            Write-Host '   [No affinity policy — unrestricted]'
        }
    }
}

# ---------- 2. PCIe Power Management / ASPM ----------
Write-Section '[2/6] PCIe ASPM — Active State Power Management'
Write-Host 'ASPM L0s/L1 can cause micro-glitches on HDMI audio clock when lanes wake.' -ForegroundColor Gray
Write-Host ''
$pciPwrPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\501a4d13-42af-4429-9fd1-a8218c268e20'
if (Test-Path $pciPwrPath) {
    $p = Get-ItemProperty $pciPwrPath -ErrorAction SilentlyContinue
    Write-Host ('   GlobalSetting ACSettingIndex: ' + $p.ACSettingIndex)
    Write-Host '     0=Off, 1=Moderate, 2=Max power savings (bad for audio)' -ForegroundColor Gray
}

# Active power scheme — PCIe ASPM setting
$activeScheme = (powercfg /getactivescheme) -replace '.*GUID: ([0-9a-f-]+).*','$1'
$activeScheme = $activeScheme.Trim()
Write-Host ('   Active scheme GUID: ' + $activeScheme)
$pciSub = '501a4d13-42af-4429-9fd1-a8218c268e20'  # PCI Express subgroup
$aspmGuid = 'ee12f906-d277-404b-b6da-e5fa1a576df5'  # Link State Power Management
$q = powercfg /query $activeScheme $pciSub $aspmGuid 2>$null
if ($q) {
    $acLine = $q | Select-String 'Current AC Power Setting Index'
    $dcLine = $q | Select-String 'Current DC Power Setting Index'
    Write-Host ('   ASPM AC: ' + $acLine)
    Write-Host ('   ASPM DC: ' + $dcLine)
    Write-Host '     Value should be 0x0 (Off) for low-latency audio.' -ForegroundColor Gray
}

# ---------- 3. GPU P-state / clocks ----------
Write-Section '[3/6] GPU P-state and Clocks (nvidia-smi)'
$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($smi) {
    Write-Host 'Current query:' -ForegroundColor Gray
    & nvidia-smi --query-gpu=name,driver_version,pstate,power.draw,clocks.current.graphics,clocks.current.memory,clocks.current.video,temperature.gpu --format=csv
    Write-Host ''
    Write-Host 'Supported clocks (memory):' -ForegroundColor Gray
    $mem = & nvidia-smi --query-supported-clocks=memory --format=csv,noheader -i 0 2>$null | Select-Object -Unique
    Write-Host ('   ' + ($mem -join ', '))
    Write-Host ''
    Write-Host 'PerfLevelSrc registry value:' -ForegroundColor Gray
    $nvKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\NVTweak'
    if (Test-Path $nvKey) {
        $pls = Get-ItemProperty $nvKey -Name 'PerfLevelSrc' -ErrorAction SilentlyContinue
        if ($pls) {
            Write-Host ('   PerfLevelSrc: 0x' + [Convert]::ToString($pls.PerfLevelSrc,16).PadLeft(4,'0'))
            Write-Host '     0x2222 = Prefer max performance (no P-state drop)' -ForegroundColor Gray
        } else {
            Write-Host '   [PerfLevelSrc not set — adaptive P-state]' -ForegroundColor Yellow
        }
    }
} else {
    Write-Host '[SKIP] nvidia-smi not in PATH' -ForegroundColor Yellow
}

# ---------- 4. I226-V NIC EEE + Interrupt Moderation ----------
Write-Section '[4/6] I226-V Ethernet — EEE, Interrupt Moderation, Flow Control'
Write-Host 'EEE (Energy Efficient Ethernet) causes PHY resyncs that propagate to PCIe.' -ForegroundColor Gray
Write-Host ''
$nic = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'I226' -and $_.Status -eq 'Up' } | Select-Object -First 1
if ($nic) {
    Write-Host ('NIC: ' + $nic.InterfaceDescription + ' (' + $nic.Name + ')') -ForegroundColor Yellow
    $props = @(
        'Energy-Efficient Ethernet'
        'Ultra Low Power Mode'
        'System Idle Power Saver'
        'Gigabit Master Slave Mode'
        'Interrupt Moderation'
        'Interrupt Moderation Rate'
        'Flow Control'
        'Jumbo Packet'
        'Packet Priority & VLAN'
        'Receive Buffers'
        'Transmit Buffers'
        'Speed & Duplex'
        'Green Ethernet'
        'Large Send Offload V2 (IPv4)'
        'Large Send Offload V2 (IPv6)'
    )
    foreach ($p in $props) {
        $v = Get-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $p -ErrorAction SilentlyContinue
        if ($v) {
            Write-Host ('   ' + $p.PadRight(35) + ': ' + $v.DisplayValue)
        }
    }
    Write-Host ''
    Write-Host 'Power management:' -ForegroundColor Gray
    $pm = Get-NetAdapterPowerManagement -Name $nic.Name -ErrorAction SilentlyContinue
    if ($pm) {
        Write-Host ('   AllowComputerToTurnOffDevice: ' + $pm.AllowComputerToTurnOffDevice)
        Write-Host ('   SelectiveSuspend            : ' + $pm.SelectiveSuspend)
        Write-Host ('   DeviceSleepOnDisconnect     : ' + $pm.DeviceSleepOnDisconnect)
    }
} else {
    Write-Host '[FAIL] I226-V NIC not found or not up' -ForegroundColor Red
}

# ---------- 5. Windows Audio Sample Rate / Buffer ----------
Write-Section '[5/6] Windows Audio Format — Sample Rate Mismatch Check'
Write-Host 'If game audio is 48kHz but Windows mixer is 44.1kHz (or vice versa), SRC causes warble.' -ForegroundColor Gray
Write-Host ''
# Default render device format from registry
$audioRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
if (Test-Path $audioRoot) {
    $devices = Get-ChildItem $audioRoot -ErrorAction SilentlyContinue
    $count = 0
    foreach ($dev in $devices) {
        $propsKey = Join-Path $dev.PSPath 'Properties'
        if (Test-Path $propsKey) {
            $props = Get-ItemProperty $propsKey -ErrorAction SilentlyContinue
            $name = $props.'{a45c254e-df1c-4efd-8020-67d146a850e0},2'
            $state = (Get-ItemProperty $dev.PSPath -Name DeviceState -ErrorAction SilentlyContinue).DeviceState
            if ($state -eq 1 -and $name) {  # 1 = ACTIVE
                Write-Host ('>> ' + $name) -ForegroundColor Yellow
                # Device format blob (PKEY_AudioEngine_DeviceFormat)
                $fmtKey = $dev.PSPath
                $fmtProps = Get-ItemProperty (Join-Path $fmtKey 'Properties') -ErrorAction SilentlyContinue
                # Format is a binary WAVEFORMATEX — parse sample rate (bytes 4-7, little-endian DWORD)
                $formatBlob = $fmtProps.'{f19f064d-082c-4e27-bc73-6882a1bb8e4c},0'
                if ($formatBlob -is [byte[]] -and $formatBlob.Length -ge 18) {
                    $channels   = [BitConverter]::ToUInt16($formatBlob, 2)
                    $sampleRate = [BitConverter]::ToUInt32($formatBlob, 4)
                    $bytesPerSec= [BitConverter]::ToUInt32($formatBlob, 8)
                    $blockAlign = [BitConverter]::ToUInt16($formatBlob,12)
                    $bitsPerSample = [BitConverter]::ToUInt16($formatBlob,14)
                    Write-Host ('   Channels     : ' + $channels)
                    Write-Host ('   Sample Rate  : ' + $sampleRate + ' Hz')
                    Write-Host ('   Bit Depth    : ' + $bitsPerSample + '-bit')
                    Write-Host ('   BytesPerSec  : ' + $bytesPerSec)
                }
                $count++
            }
        }
    }
    if ($count -eq 0) { Write-Host '   [No active render devices found]' -ForegroundColor Yellow }
}

# ---------- 6. Razer residue check ----------
Write-Section '[6/6] Razer Process Residue Check'
$razerPatterns = @('Razer','rzr','rzagent','RzSync','RzGameManager','Chroma')
$found = @()
foreach ($p in $razerPatterns) {
    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $p -or $_.Description -match 'Razer' }
    if ($procs) { $found += $procs }
}
if ($found.Count -eq 0) {
    Write-Host '   [PASS] No Razer processes running' -ForegroundColor Green
} else {
    Write-Host '   [FAIL] Razer processes detected:' -ForegroundColor Red
    $found | Select-Object -Unique | ForEach-Object { Write-Host ('     - ' + $_.ProcessName + ' (PID ' + $_.Id + ')') }
}
# Razer services status
$razerSvcs = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Razer|Rzr' }
if ($razerSvcs) {
    Write-Host '   Razer services:' -ForegroundColor Gray
    $razerSvcs | ForEach-Object { Write-Host ('     ' + $_.Name.PadRight(30) + ' ' + $_.Status + ' / ' + $_.StartType) }
}

Write-Section 'DONE'
Write-Host 'Next: Run Phase 2 stress tests to isolate whether warble is triggered by' -ForegroundColor Cyan
Write-Host '      GPU load, network load, or only the combination of both.' -ForegroundColor Cyan
