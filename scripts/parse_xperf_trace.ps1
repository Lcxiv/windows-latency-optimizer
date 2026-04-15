# Parse xperf DPC/ISR trace for audio diagnostics
$traceFile = "C:\Users\L\AppData\Local\Temp\audio_dpc_trace.etl"
$outFile = "C:\Users\L\Desktop\windows-latency-optimizer\captures\xperf_analysis.txt"

if (-not (Test-Path $traceFile)) {
    Write-Output "Trace file not found: $traceFile"
    exit 1
}

$xperf = $null
$tryPaths = @(
    "${env:ProgramFiles(x86)}\Windows Kits\10\Windows Performance Toolkit\xperf.exe",
    "$env:ProgramFiles\Windows Kits\10\Windows Performance Toolkit\xperf.exe"
)
foreach ($tp in $tryPaths) {
    if (Test-Path $tp) { $xperf = $tp; break }
}
if (-not $xperf) {
    $xperfCmd = Get-Command xperf -ErrorAction SilentlyContinue
    if ($xperfCmd) { $xperf = $xperfCmd.Source }
}

if (-not $xperf) {
    Write-Output "xperf not found!"
    exit 1
}

Write-Output "Using xperf: $xperf"
Write-Output "Trace: $traceFile"
Write-Output "============================================"

# Run DPC summary
Write-Output ""
Write-Output "=== DPC SUMMARY ==="
$dpcOut = & $xperf -i $traceFile -a dpcisr 2>&1
foreach ($line in $dpcOut) {
    Write-Output $line
}
