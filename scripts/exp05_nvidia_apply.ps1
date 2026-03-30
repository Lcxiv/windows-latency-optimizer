#Requires -RunAsAdministrator
<#
.SYNOPSIS
    EXP05: NVIDIA Reflex 2 + NVCP Low Latency Settings
.DESCRIPTION
    Apply NVIDIA Control Panel 3D settings for minimum latency.
    ProfileInspector cannot run headless; this script documents manual steps
    and applies what's possible via registry/nvidia-smi.
.NOTES
    Requires: NVIDIA Control Panel open, or NVIDIAProfileInspector GUI
    Reboot: No
    Rollback: Run the rollback section at bottom, or restore .nip backup
#>

$ErrorActionPreference = 'Stop'

Write-Host '=== EXP05: NVIDIA Reflex + NVCP Low Latency ===' -ForegroundColor Cyan

# --- Step 1: Manual NVCP Settings ---
Write-Host ''
Write-Host 'MANUAL STEPS REQUIRED in NVIDIA Control Panel:' -ForegroundColor Yellow
Write-Host '  1. Open NVIDIA Control Panel > Manage 3D Settings > Global Settings'
Write-Host '  2. Set "Low Latency Mode" = Ultra'
Write-Host '  3. Set "Power Management Mode" = Prefer Maximum Performance'
Write-Host '  4. Set "Shader Cache Size" = Unlimited'
Write-Host '  5. Click Apply'
Write-Host ''
Write-Host 'OR use NVIDIAProfileInspector GUI:' -ForegroundColor Yellow
Write-Host '  1. Open nvidiaProfileInspector.exe'
Write-Host '  2. In Base Profile, find and set:'
Write-Host '     - Frame Rate Limiter Mode = 0x00000000'
Write-Host '     - Maximum pre-rendered frames = 1 (Low Latency Ultra = 0x00000003)'
Write-Host '     - Power management mode = Prefer maximum performance (0x00000001)'
Write-Host '     - Shader Cache = Unlimited'
Write-Host '  3. Click Apply Changes'
Write-Host ''

# --- Step 2: In-Game Reflex ---
Write-Host 'IN-GAME STEPS (Fortnite):' -ForegroundColor Yellow
Write-Host '  1. Settings > Display > NVIDIA Reflex Low Latency = On + Boost'
Write-Host '  2. This cannot be automated externally'
Write-Host ''

# --- Step 3: Capture Commands ---
Write-Host 'CAPTURE COMMANDS (run after applying settings):' -ForegroundColor Cyan
Write-Host ''
Write-Host '  # Idle capture (NVCP overhead only):'
Write-Host '  .\scripts\pipeline.ps1 -Label "EXP05_NVIDIA_NVCP" -Description "NVCP: Low Latency Ultra, Max Perf, Unlimited shader cache" -DurationSec 120 -SkipPresentMon -SkipWPR'
Write-Host ''
Write-Host '  # Gaming capture (with Fortnite + Reflex):'
Write-Host '  .\scripts\pipeline.ps1 -Label "EXP05_REFLEX_GAMING" -Description "Reflex On+Boost in Fortnite" -DurationSec 300 -GameProcess "FortniteClient-Win64-Shipping"'
Write-Host ''

# --- Rollback ---
Write-Host 'ROLLBACK:' -ForegroundColor Red
Write-Host '  NVCP: Set Low Latency Mode = Off, Power = Optimal Power, Shader Cache = default'
Write-Host '  Fortnite: Set NVIDIA Reflex = Off'
Write-Host '  Or import .nip backup: nvidiaProfileInspector.exe (GUI > Import)'
