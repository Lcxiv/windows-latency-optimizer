#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Memory audit checks (Deep Tier).
.DESCRIPTION
    RAM speed vs rated (XMP/EXPO detection).
#>

# ---------------------------------------------------------------------------
# Deep Tier: Memory Checks (20)
# ---------------------------------------------------------------------------
function Invoke-MemoryChecks {
    $results = @()

    # --- Check 20: RAM Speed vs Rated ---
    $dimms = @()
    try { $dimms = @(Get-WmiObject Win32_PhysicalMemory -ErrorAction Stop) } catch {}
    if ($dimms.Count -eq 0) {
        $results += New-CheckResult -Name 'RAM Speed vs Rated' -Category 'Memory' -Tier 'Deep' -Severity 'HIGH' `
            -Status 'ERROR' -Current 'WMI query failed' -Expected 'Configured >= JEDEC Speed'
    } else {
        $configured = $dimms[0].ConfiguredClockSpeed
        $jedec      = $dimms[0].Speed
        $totalGB    = [math]::Round(($dimms | Measure-Object -Property Capacity -Sum).Sum / 1GB)
        if ($configured -ge $jedec -and $configured -gt 4800) {
            $results += New-CheckResult -Name 'RAM Speed vs Rated' -Category 'Memory' -Tier 'Deep' -Severity 'HIGH' `
                -Status 'PASS' -Current ($configured.ToString() + ' MT/s') -Expected 'XMP/EXPO profile active'
        } elseif ($configured -eq $jedec -or $configured -le 4800) {
            $results += New-CheckResult -Name 'RAM Speed vs Rated' -Category 'Memory' -Tier 'Deep' -Severity 'HIGH' `
                -Status 'WARN' -Current ($configured.ToString() + ' MT/s (JEDEC default)') -Expected 'XMP/EXPO rated speed' `
                -Message 'RAM running at JEDEC default. Enable XMP/EXPO in BIOS to reach rated speed.' `
                -Fix '' -FixNote 'BIOS setting: EXPO/XMP Profile 1. No OS change needed.'
        } else {
            $results += New-CheckResult -Name 'RAM Speed vs Rated' -Category 'Memory' -Tier 'Deep' -Severity 'HIGH' `
                -Status 'PASS' -Current ($configured.ToString() + ' MT/s') -Expected 'XMP/EXPO active'
        }
    }

    return $results
}
