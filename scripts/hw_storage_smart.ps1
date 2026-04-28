<#
.SYNOPSIS
    SMART snapshot for all physical disks.
.DESCRIPTION
    Get-PhysicalDisk + Get-StorageReliabilityCounter per drive.
    Captures: Wear, Temperature, Read/WriteErrorsTotal, Read/WriteLatencyMax,
    PowerOnHours.
    Flags: temperature > 70 C, wear > 70%, any read/write errors,
    ReadLatencyMax > 100 ms.
.OUTPUTS
    JSON to <OutDir>\smart.json
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$OutDir,
    [string]$Phase = 'preflight'
)

$ErrorActionPreference = 'Continue'
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$result = [ordered]@{
    schemaVersion = 1
    capturedAt = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    phase = $Phase
    drives = @()
    flags = @()
}

try {
    $disks = Get-PhysicalDisk | Sort-Object DeviceId
    foreach ($d in $disks) {
        $entry = [ordered]@{
            deviceId = $d.DeviceId
            friendlyName = $d.FriendlyName
            busType = ($d.BusType).ToString()
            mediaType = ($d.MediaType).ToString()
            sizeGB = [math]::Round($d.Size / 1GB, 1)
            healthStatus = ($d.HealthStatus).ToString()
            operationalStatus = ($d.OperationalStatus).ToString()
            firmwareVersion = $d.FirmwareVersion
            reliability = $null
        }
        try {
            $rel = $d | Get-StorageReliabilityCounter -ErrorAction Stop
            if ($rel) {
                $entry.reliability = [ordered]@{
                    temperature_c = $rel.Temperature
                    temperatureMax_c = $rel.TemperatureMax
                    wear_pct = $rel.Wear
                    powerOnHours = $rel.PowerOnHours
                    startStopCycles = $rel.StartStopCycleCount
                    readErrorsTotal = $rel.ReadErrorsTotal
                    writeErrorsTotal = $rel.WriteErrorsTotal
                    readErrorsCorrected = $rel.ReadErrorsCorrected
                    writeErrorsCorrected = $rel.WriteErrorsCorrected
                    readErrorsUncorrected = $rel.ReadErrorsUncorrected
                    writeErrorsUncorrected = $rel.WriteErrorsUncorrected
                    readLatencyMax_ms = $rel.ReadLatencyMax
                    writeLatencyMax_ms = $rel.WriteLatencyMax
                }
                $tag = $d.FriendlyName
                if ($null -ne $rel.Temperature -and $rel.Temperature -gt 70) {
                    $result.flags += ('SMART ' + $tag + ': temp ' + $rel.Temperature + ' C > 70 C')
                }
                if ($null -ne $rel.Wear -and $rel.Wear -gt 70) {
                    $result.flags += ('SMART ' + $tag + ': wear ' + $rel.Wear + '% > 70%')
                }
                if ($null -ne $rel.ReadErrorsUncorrected -and $rel.ReadErrorsUncorrected -gt 0) {
                    $result.flags += ('SMART ' + $tag + ': uncorrected read errors = ' + $rel.ReadErrorsUncorrected)
                }
                if ($null -ne $rel.WriteErrorsUncorrected -and $rel.WriteErrorsUncorrected -gt 0) {
                    $result.flags += ('SMART ' + $tag + ': uncorrected write errors = ' + $rel.WriteErrorsUncorrected)
                }
                if ($null -ne $rel.ReadLatencyMax -and $rel.ReadLatencyMax -gt 100) {
                    $result.flags += ('SMART ' + $tag + ': max read latency ' + $rel.ReadLatencyMax + ' ms > 100 ms')
                }
                if ($null -ne $rel.WriteLatencyMax -and $rel.WriteLatencyMax -gt 100) {
                    $result.flags += ('SMART ' + $tag + ': max write latency ' + $rel.WriteLatencyMax + ' ms > 100 ms')
                }
                if ($d.HealthStatus -ne 'Healthy') {
                    $result.flags += ('SMART ' + $tag + ': health = ' + $d.HealthStatus)
                }
            }
        } catch {
            $entry.reliability = @{ error = $_.Exception.Message }
        }
        $result.drives += $entry
    }
} catch {
    $result.error = $_.Exception.Message
}

if ($result.flags.Count -eq 0) {
    $result.flags = @('PASS: All drives healthy, no SMART thresholds breached')
}

$outPath = Join-Path $OutDir 'smart.json'
$result | ConvertTo-Json -Depth 6 | Set-Content -Path $outPath -Encoding UTF8
Write-Host ('[hw_storage_smart] wrote: ' + $outPath) -ForegroundColor Cyan
foreach ($f in $result.flags) { Write-Host ('  -> ' + $f) }
