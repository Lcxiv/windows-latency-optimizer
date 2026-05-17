<#
.SYNOPSIS
    Diagnostic script dispatch for diagnose.ps1.
.DESCRIPTION
    Maps domains to specific diagnostic scripts, presents the interactive
    menu, resolves ambiguous classifications, and invokes scripts with
    admin/Quick gating. Dot-sourced by diagnose.ps1.

    Reads from caller scope: $script:IsAdmin, $script:Quick, $script:OutputDir,
    $script:PSScriptRoot, $script:Symptom.
#>

# Idempotency guard
if (Get-Command 'Invoke-DiagnosticScript' -ErrorAction SilentlyContinue) { return }

# ============================================================================
# Domain → Script definitions
# ============================================================================
function Get-DomainScripts {
    param([string]$DomainName)

    $scripts = @()

    switch ($DomainName) {
        'dpc' {
            $scripts += @{
                script       = 'analyze_affinity_overlap.ps1'
                args         = @()
                requireAdmin = $false
                domain       = 'dpc'
            }
            $scripts += @{
                script       = 'audio_diag.ps1'
                args         = @()
                requireAdmin = $false
                domain       = 'dpc'
            }
            $scripts += @{
                script       = 'diagnose-mouse.ps1'
                args         = @('-DurationSec', '10')
                requireAdmin = $true
                domain       = 'dpc'
            }
        }
        'gpu' {
            $scripts += @{
                script       = 'hw_pcie_state.ps1'
                args         = @('-OutDir', $script:OutputDir, '-Phase', 'diag')
                requireAdmin = $false
                domain       = 'gpu'
            }
            $scripts += @{
                script       = 'hw_gpu_ecc.ps1'
                args         = @('-OutDir', $script:OutputDir, '-DurationSec', '10', '-Phase', 'diag')
                requireAdmin = $false
                domain       = 'gpu'
            }
        }
        'net' {
            $scripts += @{
                script       = 'hw_nic_errors.ps1'
                args         = @('-OutDir', $script:OutputDir, '-Mode', 'Snap', '-Phase', 'diag')
                requireAdmin = $false
                domain       = 'net'
            }
        }
        'system' {
            $scripts += @{
                script       = 'audit.ps1'
                args         = @('-Mode', 'Quick', '-Quiet')
                requireAdmin = $true
                domain       = 'system'
            }
            $scripts += @{
                script       = 'health-check.ps1'
                args         = @()
                requireAdmin = $true
                domain       = 'system'
            }
        }
    }

    return $scripts
}

# ============================================================================
# Interactive menu
# ============================================================================
function Show-Menu {
    Write-Host ''
    Write-Host ([char]0x2554 + ([string][char]0x2550 * 54) + [char]0x2557) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '  Windows Latency Optimizer - Diagnostic Dispatcher   ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2560 + ([string][char]0x2550 * 54) + [char]0x2563) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '                                                      ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '  [1] Input / Mouse          Mouse stutter, HID gaps, ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '                             polling, Razer issues     ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '  [2] GPU / Frames           Frame drops, hitches,     ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '                             clocks, G-Sync, tearing   ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '  [3] Network                Ping spikes, packet loss, ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '                             bufferbloat, DNS           ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '  [4] System Health          Full audit, Defender,     ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '                             services, registry         ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '  [5] Audio                  Warble, glitches, HDMI    ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '                             audio pitch shift          ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '  [6] Full Diagnostic        All domains (slowest)     ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '                                                      ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '  [0] Describe symptom       Type what''s wrong         ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '                                                      ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x255A + ([string][char]0x2550 * 54) + [char]0x255D) -ForegroundColor Cyan
    Write-Host ''

    $choice = Read-Host 'Select option'

    switch ($choice) {
        '1' { return 'dpc'    }
        '2' { return 'gpu'    }
        '3' { return 'net'    }
        '4' { return 'system' }
        '5' { return 'dpc'    }  # audio → dpc domain
        '6' { return 'all'    }
        '0' {
            $userSymptom = Read-Host 'Describe your symptom'
            if ($userSymptom -eq '') {
                Write-Host 'No symptom entered, defaulting to system health.' -ForegroundColor Yellow
                return 'system'
            }
            $script:Symptom = $userSymptom
            return '__classify__'
        }
        default {
            Write-Host ('Invalid choice: ' + $choice) -ForegroundColor Red
            return ''
        }
    }
}

# ============================================================================
# Resolve ambiguous classification interactively
# ============================================================================
function Resolve-Ambiguity {
    param([hashtable]$Classification)

    Write-Host ''
    Write-Host 'Multiple domains matched your symptom:' -ForegroundColor Yellow
    $idx = 1
    $domList = @($Classification.allMatches.Keys)
    foreach ($d in $domList) {
        $kws = $Classification.allMatches[$d] -join ', '
        Write-Host ('  [' + $idx + '] ' + $d.ToUpper() + ' (matched: ' + $kws + ')')
        $idx++
    }
    Write-Host ('  [' + $idx + '] Run ALL matched domains')
    Write-Host ''
    $pick = Read-Host 'Pick a domain'

    $pickInt = 0
    if ([int]::TryParse($pick, [ref]$pickInt)) {
        if ($pickInt -ge 1 -and $pickInt -le $domList.Count) {
            return $domList[$pickInt - 1]
        }
        if ($pickInt -eq ($domList.Count + 1)) {
            return 'all'
        }
    }
    # Default to best match
    return $Classification.domain
}

# ============================================================================
# Run a single diagnostic script
# ============================================================================
function Invoke-DiagnosticScript {
    param([hashtable]$ScriptDef)

    $scriptsRoot = Split-Path -Parent $PSScriptRoot   # parent of diagnose/ = scripts/
    $scriptPath = Join-Path $scriptsRoot $ScriptDef.script
    $result = [ordered]@{
        script        = $ScriptDef.script
        domain        = $ScriptDef.domain
        status        = 'pending'
        exitCode      = -1
        durationMs    = 0
        summary       = ''
        requiresAdmin = $ScriptDef.requireAdmin
        output        = ''
    }

    # Check if script exists
    if (-not (Test-Path $scriptPath)) {
        $result.status = 'missing'
        $result.summary = 'Script not found: ' + $ScriptDef.script
        return $result
    }

    # Skip admin-required scripts when not elevated (or -Quick mode)
    if ($ScriptDef.requireAdmin -and (-not $script:IsAdmin -or $script:Quick)) {
        $result.status = 'skipped'
        if ($script:Quick) {
            $result.summary = 'Skipped (-Quick mode, requires admin)'
        } else {
            $result.summary = 'Skipped (requires admin elevation)'
        }
        return $result
    }

    $label = '[' + $ScriptDef.domain + ']'
    Write-Host ('' + $label + ' Running ' + $ScriptDef.script + '...') -ForegroundColor Yellow

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $output = & $scriptPath @($ScriptDef.args) 2>&1 | Out-String
        $result.exitCode = $LASTEXITCODE
        if ($null -eq $result.exitCode) { $result.exitCode = 0 }
        $result.output = $output
        $result.status = 'completed'
        $result.summary = Extract-Summary $output $ScriptDef.script
    }
    catch {
        $result.status = 'error'
        $result.exitCode = 1
        $result.summary = 'Error: ' + $_.Exception.Message
        $result.output = $_.Exception.Message
    }
    $sw.Stop()
    $result.durationMs = [int]$sw.ElapsedMilliseconds

    return $result
}
