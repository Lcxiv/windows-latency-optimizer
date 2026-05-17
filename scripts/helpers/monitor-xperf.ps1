# helpers/monitor-xperf.ps1
# xperf DPC/ISR trace helper for real-time latency monitoring.
# Runs a short xperf DPC/ISR trace and parses the dpcisr -summary output into
# structured per-CPU-per-driver data.
# Dot-sourced by monitor_collector.ps1 after config.ps1.
# PowerShell 5.1 compatible — no ternary, no null-coalescing, no Join-String,
# no -StandardDeviation on Measure-Object. $error and $pid are reserved.

function Get-MonitorXperfSnapshot {
    <#
    .SYNOPSIS
        Run a short xperf DPC/ISR trace and parse per-driver attribution data.
    .DESCRIPTION
        Starts an xperf kernel trace for DPC and INTERRUPT events, waits for
        DurationSec seconds, stops the trace, and parses -a dpcisr -summary
        output into a structured hashtable.

        Each driver entry includes:
            module    [string]  — driver filename (e.g., nvlddmkm.sys)
            cpuUsec   [long[]]  — per-CPU DPC time in microseconds (16 elements)
            totalUsec [long]    — sum of cpuUsec across all CPUs
            dpcCount  [long]    — total DPC execution count for this module

        Requires elevation (admin) for xperf kernel tracing.
        Only one xperf trace can run at a time; returns an error if another
        trace is already in progress.
    .PARAMETER DurationSec
        Number of seconds to collect the trace. Default: 5.
    .OUTPUTS
        Hashtable with keys:
            timestamp       [string] — ISO-8601 timestamp at function call
            traceDurationUs [long]   — trace window in microseconds
            drivers         [array]  — per-driver DPC entries (sorted by totalUsec desc)
            error           [string] — error message if failed, else $null
    #>
    param(
        [int]$DurationSec = 5
    )

    $timestamp = Get-Date -Format 'o'
    $emptyResult = @{
        timestamp       = $timestamp
        traceDurationUs = 0L
        drivers         = @()
        error           = $null
    }

    # -------------------------------------------------------------------------
    # 1. Elevation check — xperf kernel tracing requires admin
    # -------------------------------------------------------------------------
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    if (-not $isAdmin) {
        $emptyResult.error = 'Requires elevation — run PowerShell as Administrator'
        Write-Warning $emptyResult.error
        return $emptyResult
    }

    # -------------------------------------------------------------------------
    # 2. Locate xperf
    # -------------------------------------------------------------------------
    $xperf = $null
    if ($script:ToolPaths -and $script:ToolPaths.ContainsKey('Xperf')) {
        $xperf = $script:ToolPaths.Xperf
    }

    if (-not $xperf -or -not (Test-Path $xperf)) {
        $emptyResult.error = 'xperf not found — install Windows Performance Toolkit (ADK)'
        Write-Warning $emptyResult.error
        return $emptyResult
    }

    # -------------------------------------------------------------------------
    # 3. Verify no active NT Kernel Logger trace is blocking us
    # -------------------------------------------------------------------------
    $sessionCheck = & $xperf -loggers 2>&1
    $sessionLines = @($sessionCheck | ForEach-Object { $_.ToString() })
    $ntKernelRunning = $false
    foreach ($sl in $sessionLines) {
        if ($sl -match 'NT Kernel Logger') {
            $ntKernelRunning = $true
            break
        }
    }

    if ($ntKernelRunning) {
        $emptyResult.error = 'NT Kernel Logger is already running — cannot start a new xperf trace'
        Write-Warning $emptyResult.error
        return $emptyResult
    }

    # -------------------------------------------------------------------------
    # 4. Run trace
    # -------------------------------------------------------------------------
    $etlPath = Join-Path $env:TEMP ('monitor_dpc_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.etl')
    $traceStarted = $false

    try {
        # Start kernel trace (DPC + INTERRUPT providers)
        $startOut = & $xperf -on PROC_THREAD+LOADER+DPC+INTERRUPT -buffersize 1024 -minbuffers 256 -maxbuffers 512 2>&1
        $startLines = @($startOut | ForEach-Object { $_.ToString() })

        # Detect start failure (xperf prints errors to stdout mixed with normal output)
        foreach ($sl in $startLines) {
            if ($sl -match 'Error|error|failed|Failed|cannot|Cannot') {
                # Ignore benign messages referencing the always-running circular kernel logger
                if ($sl -match 'Circular Kernel') { continue }
                $emptyResult.error = ('xperf trace start failed: ' + $sl.Trim())
                Write-Warning $emptyResult.error
                return $emptyResult
            }
        }

        $traceStarted = $true
        Start-Sleep -Seconds $DurationSec

        # Stop trace and flush to ETL
        & $xperf -d $etlPath 2>&1 | Out-Null

        if (-not (Test-Path $etlPath)) {
            $emptyResult.error = 'xperf trace file was not created after stop'
            return $emptyResult
        }

        # -------------------------------------------------------------------------
        # 5. Parse dpcisr -summary output
        #
        # Output structure (both DPC and ISR share the same layout):
        #
        #   "DPC Info"                    <- section header
        #   "CPU Usage from 0 us to N us:" <- trace duration
        #   "     CPU 0 Usage, ..."       <- column header (CPU names)
        #   "     usec      %, ..."       <- column label row (marks table start)
        #   "  1624   0.05, ..., mod.sys" <- per-driver data row (starts with digit)
        #   ...more data rows...
        #   "Total = N"                   <- overall totals (histogram header)
        #   "Elapsed Time, ..."           <- histogram buckets (skip)
        #   "Total = N for module X"      <- per-module DPC count  <-- STILL IN TABLE
        #   ...more histogram buckets...
        #   "All Module = N, ..."         <- end of section table
        #   "Interrupt Info"              <- ISR section starts
        #
        # CRITICAL: "Total = N for module X" count lines appear BEFORE "All Module ="
        # (i.e., while $inDataTable is still true). We must not `continue` blindly
        # for non-digit lines inside the data table — fall through to dpcCountMap.
        # -------------------------------------------------------------------------
        $rawOutput = & $xperf -i $etlPath -a dpcisr -summary 2>&1
        $lines = @($rawOutput | ForEach-Object { $_.ToString() })

        # State: track DPC section vs ISR section and table open/closed
        $inDpcSection    = $false
        $inDataTable     = $false
        $traceDurationUs = 0L
        $cpuCount        = 0   # derived from column header, not hardcoded

        # dpcCountMap: module name -> DPC execution count
        $dpcCountMap = @{}

        # Collect per-driver data rows during table parse
        $driverList = New-Object System.Collections.ArrayList

        foreach ($line in $lines) {

            # --- Section headers ---
            if ($line -match 'DPC Info') {
                $inDpcSection = $true
                $inDataTable  = $false
                continue
            }
            if ($line -match 'Interrupt Info') {
                # ISR section begins — stop collecting DPC data entirely
                $inDpcSection = $false
                $inDataTable  = $false
                continue
            }

            # Skip lines outside the DPC section
            if (-not $inDpcSection) { continue }

            # --- Trace duration ---
            if ($traceDurationUs -eq 0L -and $line -match 'CPU Usage from \d+ us to (\d+) us') {
                $parsedUs = 0L
                if ([long]::TryParse($Matches[1], [ref]$parsedUs)) {
                    $traceDurationUs = $parsedUs
                }
                continue
            }

            # --- CPU column header — derive CPU count dynamically ---
            # "     CPU 0 Usage,     CPU 1 Usage, ..., Module"
            if ($line -match '^\s+CPU \d+ Usage') {
                # Count how many "CPU N" tokens appear to get the CPU count
                $cpuMatches = [regex]::Matches($line, 'CPU \d+')
                $cpuCount = $cpuMatches.Count
            }

            # --- Column label line — opens the data table ---
            # "     usec      %,      usec      %, ..., Module"
            if ($line -match '^\s+usec\s+%') {
                $inDataTable = $true
                if ($cpuCount -eq 0) { $cpuCount = 16 }  # fallback if header not found
                continue
            }

            # --- End of DPC data table ---
            if ($inDataTable -and $line -match '^\s*All Module\s*=') {
                $inDataTable = $false
                continue
            }

            # --- Per-driver count lines: "Total = N for module X" ---
            # These appear while $inDataTable is STILL TRUE (before "All Module").
            # Capture them here and let the loop continue (do NOT skip with `continue`).
            if ($line -match 'Total = (\d+) for module (.+)') {
                $countVal = 0L
                if ([long]::TryParse($Matches[1], [ref]$countVal)) {
                    $modName = $Matches[2].Trim()
                    $dpcCountMap[$modName] = $countVal
                }
                # No `continue` — fall through (there is nothing below that would
                # also match, so the foreach will naturally advance to the next line)
            }

            # --- Per-driver data row (digit-leading, inside data table) ---
            # Format: "   1624   0.05,   27   0.00, ...,  module.sys"
            # 17 comma-separated fields: [0..15] are "usec %" pairs, [16] is module name.
            if ($inDataTable) {
                $trimmed = $line.Trim()
                # Blank lines and non-digit lines (histograms, count lines) are not rows
                if ($trimmed.Length -eq 0) { continue }
                if (-not ($trimmed -match '^\d')) { continue }

                $parts = $trimmed -split ',\s*'
                $expectedFields = $cpuCount + 1  # N CPU columns + module name
                if ($parts.Count -lt $expectedFields) { continue }

                $moduleName = $parts[$cpuCount].Trim()
                if ($moduleName.Length -eq 0) { continue }

                # Extract per-CPU usec values; each part is "usec %" — take first token
                $cpuUsec   = New-Object System.Collections.ArrayList
                $totalUsec = 0L

                for ($cpuIdx = 0; $cpuIdx -lt $cpuCount; $cpuIdx++) {
                    $tokens  = $parts[$cpuIdx].Trim() -split '\s+'
                    $usecVal = 0L
                    if ($tokens.Count -ge 1 -and [long]::TryParse($tokens[0], [ref]$usecVal)) {
                        [void]$cpuUsec.Add($usecVal)
                        $totalUsec += $usecVal
                    } else {
                        [void]$cpuUsec.Add(0L)
                    }
                }

                [void]$driverList.Add(@{
                    module    = $moduleName
                    cpuUsec   = $cpuUsec.ToArray()
                    totalUsec = $totalUsec
                })
            }

        } # end foreach line

        # -------------------------------------------------------------------------
        # 6. Merge dpcCount into driver entries and sort
        # -------------------------------------------------------------------------
        $finalDrivers = New-Object System.Collections.ArrayList
        foreach ($entry in $driverList) {
            $cnt = 0L
            if ($dpcCountMap.ContainsKey($entry.module)) {
                $cnt = $dpcCountMap[$entry.module]
            }
            [void]$finalDrivers.Add(@{
                module    = $entry.module
                cpuUsec   = $entry.cpuUsec
                totalUsec = $entry.totalUsec
                dpcCount  = $cnt
            })
        }

        # Sort descending by totalUsec (highest DPC time first)
        $sortedDrivers = @($finalDrivers | Sort-Object { $_.totalUsec } -Descending)

        return @{
            timestamp       = $timestamp
            traceDurationUs = $traceDurationUs
            drivers         = $sortedDrivers
            error           = $null
        }

    } catch {
        $emptyResult.error = $_.Exception.Message
        return $emptyResult
    } finally {
        # If trace was started but ETL was never written (stop failed), cancel the session
        if ($traceStarted -and -not (Test-Path $etlPath)) {
            try { & $xperf -stop 2>&1 | Out-Null } catch {}
        }
        # Always clean up temp ETL regardless of success or failure
        if (Test-Path $etlPath) {
            Remove-Item $etlPath -Force -ErrorAction SilentlyContinue
        }
    }
}
