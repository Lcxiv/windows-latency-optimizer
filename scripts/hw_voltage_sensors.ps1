<#
.SYNOPSIS
    Capture voltage / temperature / power sensors from HWiNFO64 CSV log
    (preferred) plus ACPI thermal zones + nvidia-smi rails (always-available
    fallback).
.DESCRIPTION
    HWiNFO64 must be running with CSV logging enabled. Setup once:
        HWiNFO64 -> Sensors -> Logging Start (right-click trash icon) -> CSV.
    OR run HWiNFO64.exe with no_gui sensors-only mode and -log<file>.

    This script:
    1. Detects HWiNFO64 install + locates most-recent CSV log under
       %USERPROFILE%\Documents\HWiNFO64\, the HWiNFO64 install dir, or a
       user-supplied -HwInfoCsv path.
    2. If a CSV is found and is being written to in the past 30s,
       extracts the last DurationSec rows and computes per-rail
       min/avg/p50/max for known column patterns.
    3. Captures ACPI thermal zones via Get-CimInstance MSAcpi_ThermalZoneTemperature.
    4. Captures nvidia-smi power.draw / temperature.gpu / temperature.memory
       (DurationSec-second polling at 1s).
    5. Writes voltages_<phase>.summary.json and voltages_<phase>.csv (HWiNFO
       slice if available; thermalzones+nvidia-smi otherwise).

    If HWiNFO64 logging is NOT active, the script logs a clear instruction and
    falls back to Windows-native + nvidia-smi data only.
.OUTPUTS
    <OutDir>\voltages_<phase>.summary.json
    <OutDir>\voltages_<phase>.csv (data slice or fallback)
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$OutDir,
    [ValidateRange(15, 600)]
    [int]$DurationSec = 60,
    [string]$Phase = 'idle',
    [string]$HwInfoCsv = ''
)

$ErrorActionPreference = 'Continue'
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$summary = [ordered]@{
    schemaVersion = 1
    capturedAt = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    phase = $Phase
    durationSec = $DurationSec
    hwinfo64 = [ordered]@{
        installed = $false
        installPath = $null
        running = $false
        csvLog = $null
        csvLogActive = $false
        sampleCount = 0
        rails = @{}
    }
    acpiThermalZones = @()
    nvidia = $null
    flags = @()
}

# --- 1. Detect HWiNFO64 install ---
$hwInfoExePath = $null
$candidates = @(
    'C:\Program Files\HWiNFO64\HWiNFO64.EXE',
    'C:\Program Files (x86)\HWiNFO64\HWiNFO64.EXE'
)
foreach ($p in $candidates) {
    if (Test-Path $p) { $hwInfoExePath = $p; break }
}
if ($hwInfoExePath) {
    $summary.hwinfo64.installed = $true
    $summary.hwinfo64.installPath = $hwInfoExePath
    if (Get-Process -Name 'HWiNFO64' -ErrorAction SilentlyContinue) {
        $summary.hwinfo64.running = $true
    }
}

# --- 2. Locate HWiNFO64 CSV log ---
function Find-HwInfoCsv {
    param([string]$Override)
    if ($Override -and (Test-Path $Override)) { return $Override }
    $searchDirs = @(
        (Join-Path $env:USERPROFILE 'Documents\HWiNFO64'),
        (Join-Path $env:USERPROFILE 'Documents'),
        'C:\Program Files\HWiNFO64',
        'C:\Program Files (x86)\HWiNFO64'
    )
    foreach ($dir in $searchDirs) {
        if (-not (Test-Path $dir)) { continue }
        $csvs = Get-ChildItem -Path $dir -Filter '*.csv' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
        foreach ($f in $csvs) {
            try {
                $hdr = Get-Content $f.FullName -TotalCount 1 -ErrorAction Stop
                if ($hdr -match 'HWiNFO|CPU \[#0\]|Time|Vcore|Tctl|VDDCR_SOC|Core \(Tctl') {
                    return $f.FullName
                }
            } catch {}
        }
    }
    return $null
}

$csvPath = Find-HwInfoCsv -Override $HwInfoCsv
if ($csvPath) {
    $summary.hwinfo64.csvLog = $csvPath
    $info = Get-Item $csvPath
    $age = (Get-Date) - $info.LastWriteTime
    if ($age.TotalSeconds -lt 30) {
        $summary.hwinfo64.csvLogActive = $true
    }
}

# --- 3. If HWiNFO64 CSV is active, do live capture ---
function Get-HwInfoSlice {
    param([string]$CsvPath, [int]$DurationSec)
    Write-Host ('[hw_voltage_sensors] HWiNFO64 CSV active; sampling for ' + $DurationSec + 's...') -ForegroundColor Cyan
    Start-Sleep -Seconds $DurationSec

    # Read full CSV (HWiNFO logs append-only). Take last N rows where N ~ DurationSec
    # at HWiNFO default poll rate of 2s = N = DurationSec / 2. Be generous and take
    # 4x to handle 500ms poll rates.
    $maxRows = [math]::Max(20, $DurationSec * 4)
    try {
        $allRows = Get-Content -Path $CsvPath -ErrorAction Stop
    } catch {
        return @{ error = $_.Exception.Message }
    }
    if ($allRows.Count -lt 2) { return @{ error = 'CSV has no data rows' } }

    $header = $allRows[0]
    $dataRows = @($allRows | Select-Object -Skip 1)
    if ($dataRows.Count -gt $maxRows) {
        $dataRows = $dataRows | Select-Object -Last $maxRows
    }

    return @{
        header = $header
        rows = $dataRows
    }
}

if ($summary.hwinfo64.csvLogActive) {
    $slice = Get-HwInfoSlice -CsvPath $csvPath -DurationSec $DurationSec
    if ($slice.error) {
        $summary.flags += ('HWiNFO64 CSV slice error: ' + $slice.error)
    } else {
        $summary.hwinfo64.sampleCount = $slice.rows.Count
        # Save the slice to OutDir for future ref
        $sliceCsvPath = Join-Path $OutDir ('voltages_' + $Phase + '.csv')
        $slice.header | Set-Content -Path $sliceCsvPath -Encoding UTF8
        Add-Content -Path $sliceCsvPath -Value $slice.rows -Encoding UTF8

        # Parse CSV into per-column arrays of numerics.
        # Each pattern is { match: <regex on column header>, unit: <required unit suffix marker> }
        # Voltage columns must contain "[V]"; temp columns must contain "C]" (covers
        # both [°C] and [degC] variants). Power "[W]". Fan PWM "[%]".
        $cols = $slice.header -split ','
        $patterns = [ordered]@{
            'cpu_core_vid'    = @{ match = '(CPU Core VID|VDDCR_VDD Voltage|CPU Core Voltage|Vcore)'; unit = 'V]' }
            'cpu_vsoc'        = @{ match = '(VDDCR_SOC Voltage|CPU SoC Voltage|SoC Voltage)';         unit = 'V]' }
            'cpu_vddio_mem'   = @{ match = '(VDDIO\s*/\s*MC|VDDIO_MEM|VDDIO Mem|VDD\s*IO Mem)';        unit = 'V]' }
            'ram_vddq'        = @{ match = '(VDDQ \(SWB\)|VDDQ Voltage|DRAM VDDQ)';                     unit = 'V]' }
            'cpu_vddp'        = @{ match = '(VDDP Voltage|VDD_MISC Voltage|VDDP)';                     unit = 'V]' }
            'cpu_tdie'        = @{ match = '(CPU \(Tctl/Tdie\)|CPU Tdie|CPU \(Tdie\)|CPU Die \(Tdie\))'; unit = 'C]' }
            'cpu_ccd1'        = @{ match = '(CCD1 \(Tdie\)|CPU CCD1|Core Complex Die 1)';              unit = 'C]' }
            'cpu_iod'         = @{ match = '(IOD Hotspot|IOD \(Tdie\)|I/O Die|CPU IOD)';               unit = 'C]' }
            'vrm_temp'        = @{ match = '(VDDCR_VDD VRM|VDDCR_SOC VRM|VRM (?:MOS )?Temperature|VRM Temp|Motherboard VRM)'; unit = 'C]' }
            'chipset_temp'    = @{ match = '(Chipset Temperature|PCH Temp)';                          unit = 'C]' }
            'mb_temp'         = @{ match = '(Motherboard Temperature|Motherboard \(.*?\))';            unit = 'C]' }
            'fan_pwm_cpu'     = @{ match = '(CPU Fan|Fan #1|Fan 1)';                                   unit = '%]' }
        }

        $railResults = @{}
        foreach ($railKey in $patterns.Keys) {
            $spec = $patterns[$railKey]
            $regex = $spec.match
            $unit = $spec.unit
            # Find first matching column index whose header also contains the
            # required unit suffix (e.g. "[V]" for voltage). Prevents temp
            # columns named "VDDCR_SOC VRM (SVI3 TFN) [°C]" from matching the
            # VSOC voltage rail.
            $colIdx = -1
            for ($i = 0; $i -lt $cols.Count; $i++) {
                if (($cols[$i] -match $regex) -and ($cols[$i] -match [regex]::Escape($unit))) {
                    $colIdx = $i; break
                }
            }
            if ($colIdx -lt 0) {
                $railResults[$railKey] = @{ found = $false }
                continue
            }
            $vals = @()
            foreach ($r in $slice.rows) {
                $parts = $r -split ','
                if ($parts.Count -le $colIdx) { continue }
                $raw = $parts[$colIdx].Trim().Replace('"','')
                # Strip units (V, °C, %)
                $raw = $raw -replace '[^\d\.\-]', ''
                if ($raw -eq '') { continue }
                $num = 0.0
                if ([double]::TryParse($raw, [ref]$num)) { $vals += $num }
            }
            if ($vals.Count -eq 0) {
                $railResults[$railKey] = @{ found = $false; columnIdx = $colIdx; columnName = $cols[$colIdx] }
                continue
            }
            $m = $vals | Measure-Object -Average -Minimum -Maximum
            $sorted = $vals | Sort-Object
            $p50 = $sorted[[int]([math]::Floor($sorted.Count / 2))]
            $railResults[$railKey] = [ordered]@{
                found = $true
                columnIdx = $colIdx
                columnName = $cols[$colIdx]
                count = $vals.Count
                min = [math]::Round($m.Minimum, 4)
                avg = [math]::Round($m.Average, 4)
                p50 = [math]::Round($p50, 4)
                max = [math]::Round($m.Maximum, 4)
            }
        }
        $summary.hwinfo64.rails = $railResults
    }
} elseif ($summary.hwinfo64.installed) {
    $summary.flags += 'HWiNFO64 installed but no active CSV log detected. Start HWiNFO64 sensors-only mode and enable Logging (right-click trash icon -> CSV) to capture voltages.'
} else {
    $summary.flags += 'HWiNFO64 not installed. Install from https://www.hwinfo.com/download/ and enable CSV logging.'
}

# --- 4. ACPI thermal zones (always available) ---
try {
    $tzs = Get-CimInstance -Namespace 'root\wmi' -ClassName 'MSAcpi_ThermalZoneTemperature' -ErrorAction Stop
    foreach ($tz in $tzs) {
        $tempC = ($tz.CurrentTemperature / 10.0) - 273.15
        $summary.acpiThermalZones += [ordered]@{
            instanceName = $tz.InstanceName
            currentTempC = [math]::Round($tempC, 1)
            criticalTripC = [math]::Round((($tz.CriticalTripPoint / 10.0) - 273.15), 1)
        }
    }
} catch {
    $summary.acpiThermalZones = @(@{ error = $_.Exception.Message })
}

# --- 5. nvidia-smi sampling ---
$nvSmi = 'C:\Windows\System32\nvidia-smi.exe'
if (Test-Path $nvSmi) {
    Write-Host ('[hw_voltage_sensors] nvidia-smi sampling ' + $DurationSec + 's...') -ForegroundColor Cyan
    $nvSamples = @()
    $endT = (Get-Date).AddSeconds($DurationSec)
    function Convert-NvField {
        param([string]$Raw)
        if (-not $Raw) { return $null }
        $clean = $Raw.Trim()
        if ($clean -eq '[N/A]' -or $clean -eq 'N/A' -or $clean -eq '') { return $null }
        $clean = $clean -replace '[^\d\.\-]', ''
        if ($clean -eq '') { return $null }
        $num = 0.0
        if ([double]::TryParse($clean, [ref]$num)) { return $num }
        return $null
    }
    while ((Get-Date) -lt $endT) {
        try {
            $line = (& $nvSmi --query-gpu=temperature.gpu,temperature.memory,power.draw,clocks.current.graphics,clocks.current.memory --format=csv,noheader,nounits 2>&1 | Select-Object -First 1).ToString().Trim()
            $parts = $line -split ',\s*'
            if ($parts.Count -ge 5) {
                $nvSamples += [ordered]@{
                    tGpu = (Convert-NvField $parts[0])
                    tMem = (Convert-NvField $parts[1])
                    pwrW = (Convert-NvField $parts[2])
                    coreClock = (Convert-NvField $parts[3])
                    memClock = (Convert-NvField $parts[4])
                }
            }
        } catch {}
        Start-Sleep -Seconds 1
    }
    if ($nvSamples.Count -gt 0) {
        $tGpus = @($nvSamples | ForEach-Object { $_.tGpu } | Where-Object { $null -ne $_ })
        $tMems = @($nvSamples | ForEach-Object { $_.tMem } | Where-Object { $null -ne $_ })
        $pwrs  = @($nvSamples | ForEach-Object { $_.pwrW } | Where-Object { $null -ne $_ })
        $cClks = @($nvSamples | ForEach-Object { $_.coreClock } | Where-Object { $null -ne $_ })
        $mClks = @($nvSamples | ForEach-Object { $_.memClock } | Where-Object { $null -ne $_ })
        function Get-Q { param($v) if (-not $v -or $v.Count -eq 0) { return $null }; $m = $v | Measure-Object -Average -Minimum -Maximum; return @{ avg = [math]::Round($m.Average,2); min = $m.Minimum; max = $m.Maximum } }
        $summary.nvidia = [ordered]@{
            samples = $nvSamples.Count
            gpu_temp_c = (Get-Q $tGpus)
            mem_temp_c = (Get-Q $tMems)
            power_w = (Get-Q $pwrs)
            core_clock_mhz = (Get-Q $cClks)
            mem_clock_mhz = (Get-Q $mClks)
        }
    }
} else {
    $summary.nvidia = @{ error = 'nvidia-smi.exe not found' }
}

# --- Flags from HWiNFO64 rails (if any) ---
$rails = $summary.hwinfo64.rails
if ($rails['cpu_vsoc'] -and $rails['cpu_vsoc'].found -and $rails['cpu_vsoc'].max -gt 1.20) {
    $summary.flags += ('VSOC max ' + $rails['cpu_vsoc'].max + ' V > 1.20 V (CRITICAL — AMD safety advisory)')
}
if ($rails['cpu_tdie'] -and $rails['cpu_tdie'].found -and $rails['cpu_tdie'].max -gt 89) {
    $summary.flags += ('CPU Tdie max ' + $rails['cpu_tdie'].max + ' C > 89 C (throttle imminent at 95)')
}
if ($rails['vrm_temp'] -and $rails['vrm_temp'].found -and $rails['vrm_temp'].max -gt 75) {
    $summary.flags += ('VRM temp max ' + $rails['vrm_temp'].max + ' C > 75 C')
}
if ($summary.nvidia -and $summary.nvidia.gpu_temp_c -and $summary.nvidia.gpu_temp_c.max -gt 88) {
    $summary.flags += ('GPU edge max ' + $summary.nvidia.gpu_temp_c.max + ' C > 88 C (throttle threshold)')
}

if ($summary.flags.Count -eq 0) {
    $summary.flags = @('PASS: voltage/thermal sample within reference bands (or HWiNFO64 not active — see installed flag)')
}

$outPath = Join-Path $OutDir ('voltages_' + $Phase + '.summary.json')
$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $outPath -Encoding UTF8
Write-Host ('[hw_voltage_sensors] summary: ' + $outPath) -ForegroundColor Cyan
foreach ($f in $summary.flags) { Write-Host ('  -> ' + $f) }
