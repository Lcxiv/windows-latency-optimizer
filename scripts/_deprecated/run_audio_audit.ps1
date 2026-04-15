# Wrapper to run audit and save output
$outFile = "C:\Users\L\Desktop\windows-latency-optimizer\captures\audio_audit_output.txt"
& "C:\Users\L\Desktop\windows-latency-optimizer\scripts\audio_fix_and_audit.ps1" -All -CaptureDurationSec 10 *>&1 | Out-File -FilePath $outFile -Encoding UTF8
Write-Host "Output saved to $outFile"
