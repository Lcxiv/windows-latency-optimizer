<#
.SYNOPSIS
    Quick 10-second baseline capture (perf counters + registry snapshot).
.DESCRIPTION
    Lightweight snapshot for quick system state checks. Writes to
    captures/os_baseline_{Label}.txt.
.EXAMPLE
    .\baseline_capture.ps1 -Label "PRE_CHANGE"
#>
#Requires -RunAsAdministrator
param([string]$Label = "BASELINE")

$outFile = Join-Path $PSScriptRoot ('..\captures\os_baseline_' + $Label + '.txt')

Write-Host "=== OS Performance Capture: $Label ==="
Write-Host "Sampling for 10 seconds..."

$counters = @(
    '\Processor(_Total)\% Processor Time',
    '\Processor(_Total)\% Interrupt Time',
    '\Processor(_Total)\% DPC Time',
    '\Memory\Available MBytes',
    '\Memory\Pages/sec',
    '\PhysicalDisk(_Total)\Avg. Disk sec/Read',
    '\PhysicalDisk(_Total)\Avg. Disk sec/Write',
    '\PhysicalDisk(_Total)\Current Disk Queue Length',
    '\System\Processor Queue Length',
    '\System\Context Switches/sec'
)

$samples = Get-Counter -Counter $counters -SampleInterval 1 -MaxSamples 10

$results = @{}
foreach ($sample in $samples) {
    foreach ($cs in $sample.CounterSamples) {
        if (-not $results.ContainsKey($cs.Path)) {
            $results[$cs.Path] = @()
        }
        $results[$cs.Path] += $cs.CookedValue
    }
}

$output = @()
$output += "=== OS Performance: $Label ==="
$output += "Captured: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$output += "Samples: 10 (1s interval)"
$output += ""
$output += "{0,-55} {1,12} {2,12} {3,12}" -f "Counter", "Avg", "Min", "Max"
$output += "-" * 95

foreach ($path in ($results.Keys | Sort-Object)) {
    $vals = $results[$path]
    $avg = ($vals | Measure-Object -Average).Average
    $min = ($vals | Measure-Object -Minimum).Minimum
    $max = ($vals | Measure-Object -Maximum).Maximum
    $parts = $path.TrimStart('\').Split('\'); $shortName = ($parts[1..($parts.Length-1)]) -join '\'
    $output += "{0,-55} {1,12:N4} {2,12:N4} {3,12:N4}" -f $shortName, $avg, $min, $max
}

$output += ""
$output += "=== Registry Settings ==="
$mmcss = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -ErrorAction SilentlyContinue
$games = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' -ErrorAction SilentlyContinue
if ($mmcss) {
    $output += "SystemResponsiveness: $($mmcss.SystemResponsiveness)"
    $output += "NetworkThrottlingIndex: $($mmcss.NetworkThrottlingIndex)"
} else {
    $output += "MMCSS SystemProfile: (not found)"
}
if ($games) {
    $output += "Games Scheduling Category: $($games.'Scheduling Category')"
    $output += "Games Priority: $($games.Priority)"
    $output += "Games SFIO Priority: $($games.'SFIO Priority')"
} else {
    $output += "MMCSS Games Task: (not found)"
}

try {
    $exclusions = (Get-MpPreference -ErrorAction Stop).ExclusionPath
    if ($exclusions) {
        $output += "Defender Exclusions: $($exclusions -join ', ')"
    } else {
        $output += "Defender Exclusions: (none)"
    }
} catch {
    $output += "Defender Exclusions: (unable to query)"
}

$output | Out-File $outFile -Encoding UTF8
$output | ForEach-Object { Write-Host $_ }
Write-Host ""
Write-Host "Saved to $outFile"
