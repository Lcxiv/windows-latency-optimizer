#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Latency mitigation audit checks (Deep Tier).
.DESCRIPTION
    NVIDIA power management, autologger disable (LwtNetLog, DiagTrack),
    Defender shader/gaming exclusions, bufferbloat, HPET platform clock, GPU ReBAR.
#>

# ---------------------------------------------------------------------------
# Deep Tier: Latency Mitigation Checks (from EXP15 research)
# ---------------------------------------------------------------------------
function Invoke-LatencyMitigationChecks {
    $results = @()

    # --- Check: NVIDIA Power Management ---
    $nvClasses = @(
        'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0001'
    )
    $nvPerfFound = $false
    foreach ($nvKey in $nvClasses) {
        if (-not (Test-Path $nvKey)) { continue }
        $desc = (Get-ItemProperty $nvKey -ErrorAction SilentlyContinue).DriverDesc
        if ($null -eq $desc -or $desc -notmatch 'NVIDIA') { continue }
        $perfSrc = (Get-ItemProperty $nvKey -ErrorAction SilentlyContinue).PerfLevelSrc
        $nvPerfFound = $true
        if ($perfSrc -eq 0x2222) {
            $results += New-CheckResult -Name 'NVIDIA Power Max Perf' -Category 'GPU' -Tier 'Deep' -Severity 'HIGH' `
                -Status 'PASS' -Current 'PerfLevelSrc = 0x2222' -Expected '0x2222 (Max Performance)'
        } else {
            $currentVal = 'Not set'
            if ($null -ne $perfSrc) { $currentVal = '0x' + $perfSrc.ToString('X') }
            $results += New-CheckResult -Name 'NVIDIA Power Max Perf' -Category 'GPU' -Tier 'Deep' -Severity 'HIGH' `
                -Status 'WARN' -Current $currentVal -Expected '0x2222 (Max Performance)' `
                -Message 'RTX 5070 Ti shows 20% bus interface load at idle without max performance. Causes desktop micro-stutter.' `
                -Fix ('Set-ItemProperty -Path "' + $nvKey + '" -Name PerfLevelSrc -Value 0x2222 -Type DWord') `
                -FixNote 'Or run exp15_latency_mitigations_apply.ps1. Higher idle power (~10-15W).'
        }
        break
    }
    if (-not $nvPerfFound) {
        $results += New-CheckResult -Name 'NVIDIA Power Max Perf' -Category 'GPU' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'SKIP' -Current 'No NVIDIA adapter found' -Expected 'NVIDIA GPU'
    }

    # --- Check: LwtNetLog Autologger ---
    $lwtKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\LwtNetLog'
    $lwtStart = $null
    if (Test-Path $lwtKey) { $lwtStart = (Get-ItemProperty $lwtKey -ErrorAction SilentlyContinue).Start }
    if ($null -eq $lwtStart -or $lwtStart -eq 0) {
        $results += New-CheckResult -Name 'LwtNetLog Disabled' -Category 'OS' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'Disabled (Start=0)' -Expected 'Disabled'
    } else {
        $results += New-CheckResult -Name 'LwtNetLog Disabled' -Category 'OS' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ('Enabled (Start=' + $lwtStart + ')') -Expected 'Disabled (Start=0)' `
            -Message 'LwtNetLog ETW autologger adds DPC latency (5-15% CPU reduction reported when disabled).' `
            -Fix ('Set-ItemProperty -Path "' + $lwtKey + '" -Name Start -Value 0 -Type DWord') `
            -FixNote 'Reboot required. Or run exp15_latency_mitigations_apply.ps1.'
    }

    # --- Check: DiagTrack Autologger ---
    $diagKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\Diagtrack-Listener'
    $diagStart = $null
    if (Test-Path $diagKey) { $diagStart = (Get-ItemProperty $diagKey -ErrorAction SilentlyContinue).Start }
    if ($null -eq $diagStart -or $diagStart -eq 0) {
        $results += New-CheckResult -Name 'DiagTrack Disabled' -Category 'OS' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'Disabled (Start=0)' -Expected 'Disabled'
    } else {
        $results += New-CheckResult -Name 'DiagTrack Disabled' -Category 'OS' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ('Enabled (Start=' + $diagStart + ')') -Expected 'Disabled (Start=0)' `
            -Message 'DiagTrack telemetry autologger consumes background CPU and respawns constantly.' `
            -Fix ('Set-ItemProperty -Path "' + $diagKey + '" -Name Start -Value 0 -Type DWord') `
            -FixNote 'Reboot required. Or run exp15_latency_mitigations_apply.ps1.'
    }

    # --- Check: Defender Shader Cache Exclusion ---
    $dxCache  = $env:LOCALAPPDATA + '\NVIDIA\DXCache'
    $d3dCache = $env:LOCALAPPDATA + '\D3DSCache'
    $existingPaths = @()
    try { $existingPaths = @((Get-MpPreference -ErrorAction Stop).ExclusionPath) } catch {}
    $hasDx  = $existingPaths -contains $dxCache
    $hasD3d = $existingPaths -contains $d3dCache
    if ($hasDx -and $hasD3d) {
        $results += New-CheckResult -Name 'Defender Shader Exclusion' -Category 'OS' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'PASS' -Current 'DXCache + D3DSCache excluded' -Expected 'Both excluded'
    } else {
        $missing = @()
        if (-not $hasDx)  { $missing += 'NVIDIA DXCache' }
        if (-not $hasD3d) { $missing += 'D3DSCache' }
        $missingStr = $missing -join ', '
        $results += New-CheckResult -Name 'Defender Shader Exclusion' -Category 'OS' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'WARN' -Current ('Missing: ' + $missingStr) -Expected 'DXCache + D3DSCache excluded' `
            -Message 'Defender scans shader cache files during gameplay, causing micro-stutter on shader compilation.' `
            -Fix ('Add-MpPreference -ExclusionPath "' + $dxCache + '"; Add-MpPreference -ExclusionPath "' + $d3dCache + '"') `
            -FixNote 'Or run exp15_latency_mitigations_apply.ps1.'
    }

    # --- Check: Defender Gaming Exclusion ---
    # Verify Fortnite / Epic Games paths and processes are excluded from Defender.
    # EXP18 showed 186K Defender I/O ops during 2min Fortnite gameplay.
    $epicPath = 'C:\Program Files\Epic Games'
    $fnProcess = 'FortniteClient-Win64-Shipping.exe'
    $existingProcesses = @()
    try { $existingProcesses = @((Get-MpPreference -ErrorAction Stop).ExclusionProcess) } catch {}
    $hasEpicPath = $existingPaths -contains $epicPath
    $hasFnProc  = $existingProcesses -contains $fnProcess
    if ($hasEpicPath -and $hasFnProc) {
        $results += New-CheckResult -Name 'Defender Gaming Exclusion' -Category 'OS' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'PASS' -Current 'Epic Games path + Fortnite process excluded' -Expected 'Game dirs + processes excluded'
    } else {
        $gameMissing = @()
        if (-not $hasEpicPath) { $gameMissing += 'Epic Games path' }
        if (-not $hasFnProc)   { $gameMissing += 'Fortnite process' }
        $gameMissingStr = $gameMissing -join ', '
        $results += New-CheckResult -Name 'Defender Gaming Exclusion' -Category 'OS' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'WARN' -Current ('Missing: ' + $gameMissingStr) -Expected 'Game dirs + processes excluded' `
            -Message 'Defender scans game files on every asset load, causing input lag during build-switching.' `
            -Fix '' `
            -FixNote 'Run exp19_defender_gaming_exclusions.ps1 to add all gaming exclusions.'
    }

    # --- Check: Bufferbloat (read from pipeline data) ---
    $expRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'captures\experiments'
    $bloatChecked = $false
    if (Test-Path $expRoot) {
        $expDirs = @(Get-ChildItem $expRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
        if ($expDirs.Count -gt 0) {
            $expJson = Join-Path $expDirs[0].FullName 'experiment.json'
            if (Test-Path $expJson) {
                try {
                    $bloatExp = Get-Content $expJson -Raw | ConvertFrom-Json -ErrorAction Stop
                    if ($null -ne $bloatExp.bufferbloat -and $null -ne $bloatExp.bufferbloat.bloatFactor) {
                        $bf = $bloatExp.bufferbloat.bloatFactor
                        $br = $bloatExp.bufferbloat.bloatRating
                        $bloatChecked = $true
                        $bloatDetail = 'Bloat: ' + $bf + 'x (' + $br + ') idle=' + $bloatExp.bufferbloat.idleP50 + 'ms loaded=' + $bloatExp.bufferbloat.loadedP50 + 'ms'
                        if ($bf -lt 2) {
                            $results += New-CheckResult -Name 'Bufferbloat' -Category 'Network' -Tier 'Deep' -Severity 'HIGH' `
                                -Status 'PASS' -Current $bloatDetail -Expected 'Bloat factor < 2x'
                        } elseif ($bf -lt 10) {
                            $results += New-CheckResult -Name 'Bufferbloat' -Category 'Network' -Tier 'Deep' -Severity 'HIGH' `
                                -Status 'WARN' -Current $bloatDetail -Expected 'Bloat factor < 2x' `
                                -Message 'Mild bufferbloat. RTT inflates under load, causing latency spikes during downloads + gaming.' `
                                -Fix '' -FixNote 'Enable SQM/fq_codel on your router. See bufferbloat.net/projects/'
                        } else {
                            $results += New-CheckResult -Name 'Bufferbloat' -Category 'Network' -Tier 'Deep' -Severity 'HIGH' `
                                -Status 'FAIL' -Current $bloatDetail -Expected 'Bloat factor < 2x' `
                                -Message 'Severe bufferbloat detected. Connection adds significant latency under load.' `
                                -Fix '' -FixNote 'Enable SQM/fq_codel on your router or replace router. See bufferbloat.net/projects/'
                        }
                    }
                } catch {}
            }
        }
    }
    if (-not $bloatChecked) {
        $results += New-CheckResult -Name 'Bufferbloat' -Category 'Network' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'SKIP' -Current 'No bufferbloat data' -Expected 'Run pipeline.ps1 first' `
            -Message 'Run pipeline.ps1 to capture bufferbloat data (idle vs loaded RTT test).'
    }

    # --- Check: Platform Clock (HPET) ---
    # If useplatformclock is forced to Yes, Windows uses legacy HPET instead of TSC,
    # adding ~1ms timer resolution overhead.
    $platformClockChecked = $false
    try {
        $bcdOutput = & bcdedit /enum '{current}' 2>&1
        if ($LASTEXITCODE -eq 0) {
            $platformClockChecked = $true
            $upcLine = $bcdOutput | Where-Object { $_ -match 'useplatformclock' }
            if ($null -ne $upcLine) {
                $upcValue = ($upcLine -replace '.*\s+(Yes|No)\s*$', '$1').Trim()
                if ($upcValue -eq 'Yes') {
                    $results += New-CheckResult -Name 'Platform Clock (HPET)' -Category 'OS' -Tier 'Deep' -Severity 'MEDIUM' `
                        -Status 'FAIL' -Current 'useplatformclock = Yes' -Expected 'Not set (TSC default)' `
                        -Message 'Legacy HPET forced on. Adds ~1ms timer latency vs TSC. Games see higher input lag.' `
                        -Fix 'bcdedit /deletevalue useplatformclock' `
                        -FixNote 'Reboot required. Lets Windows use TSC instead of legacy HPET.'
                } else {
                    $results += New-CheckResult -Name 'Platform Clock (HPET)' -Category 'OS' -Tier 'Deep' -Severity 'MEDIUM' `
                        -Status 'PASS' -Current 'useplatformclock = No' -Expected 'Not set (TSC default)' `
                        -Message 'Platform clock explicitly disabled. TSC is active.'
                }
            } else {
                $results += New-CheckResult -Name 'Platform Clock (HPET)' -Category 'OS' -Tier 'Deep' -Severity 'MEDIUM' `
                    -Status 'PASS' -Current 'Not set (TSC default)' -Expected 'Not set (TSC default)' `
                    -Message 'Windows using default TSC timer. Optimal for low latency.'
            }
        }
    } catch {}
    if (-not $platformClockChecked) {
        $results += New-CheckResult -Name 'Platform Clock (HPET)' -Category 'OS' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'ERROR' -Current 'bcdedit failed (run as admin)' -Expected 'Not set (TSC default)' `
            -Message 'Cannot read boot configuration. Run audit as Administrator.'
    }

    # --- Check: GPU ReBAR (Resizable BAR) ---
    # ReBAR lets the CPU access full GPU VRAM directly instead of a 256MB window.
    # ~3-5% FPS uplift in most games when enabled.
    $rebarChecked = $false
    $nvSmiPath = Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe'
    if (-not (Test-Path $nvSmiPath)) {
        # Try PATH fallback
        $nvSmiCmd = Get-Command 'nvidia-smi' -ErrorAction SilentlyContinue
        if ($null -ne $nvSmiCmd) { $nvSmiPath = $nvSmiCmd.Source }
    }
    if (Test-Path $nvSmiPath) {
        try {
            # bar1.total not available via --query-gpu, parse -q output instead
            $smiOutput = & $nvSmiPath -q 2>&1
            $vramRaw = & $nvSmiPath --query-gpu=memory.total --format=csv,noheader,nounits 2>&1
            $bar1Line = $smiOutput | Select-String 'BAR1 Memory Usage' -Context 0,1
            $bar1MB = 0
            if ($null -ne $bar1Line) {
                $totalLine = $bar1Line.Context.PostContext[0]
                if ($totalLine -match '(\d+)\s*MiB') { $bar1MB = [int]$Matches[1] }
            }
            $vramMB = [int]($vramRaw.ToString().Trim())
            if ($bar1MB -gt 0 -and $vramMB -gt 0) {
                $rebarChecked = $true
                if ($bar1MB -ge $vramMB) {
                    $barDetail = 'BAR1 = ' + $bar1MB + ' MB (VRAM = ' + $vramMB + ' MB)'
                    $results += New-CheckResult -Name 'GPU ReBAR (Resizable BAR)' -Category 'GPU' -Tier 'Deep' -Severity 'MEDIUM' `
                        -Status 'PASS' -Current $barDetail -Expected 'BAR1 >= VRAM (full access)' `
                        -Message 'ReBAR enabled. CPU can access full GPU VRAM directly.'
                } else {
                    $barDetail = 'BAR1 = ' + $bar1MB + ' MB (VRAM = ' + $vramMB + ' MB)'
                    $results += New-CheckResult -Name 'GPU ReBAR (Resizable BAR)' -Category 'GPU' -Tier 'Deep' -Severity 'MEDIUM' `
                        -Status 'WARN' -Current $barDetail -Expected 'BAR1 >= VRAM (full access)' `
                        -Message 'ReBAR not enabled. CPU limited to 256MB VRAM window. ~3-5% FPS loss in most games.' `
                        -Fix '' `
                        -FixNote 'Enable in BIOS: AMD CBS > NBIO > BAR Support > Enable. Also requires IOMMU enabled.'
                }
            }
        } catch {}
    }
    if (-not $rebarChecked) {
        $results += New-CheckResult -Name 'GPU ReBAR (Resizable BAR)' -Category 'GPU' -Tier 'Deep' -Severity 'MEDIUM' `
            -Status 'SKIP' -Current 'nvidia-smi not found' -Expected 'BAR1 >= VRAM (full access)' `
            -Message 'Install NVIDIA drivers with nvidia-smi to check ReBAR status.'
    }

    return $results
}
