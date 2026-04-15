$script = "C:\Users\L\Desktop\windows-latency-optimizer\scripts\disable_razer_startup.ps1"
$outFile = "C:\Users\L\Desktop\windows-latency-optimizer\captures\razer_disable_results.txt"
Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -Command `"& '$script' *>&1 | Out-File '$outFile' -Encoding UTF8`"" -Wait
Write-Output "Done. Results in: $outFile"
