@echo off
echo Starting Fortnite with V-Cache affinity (cores 8-15)...
echo Waiting for FortniteClient-Win64-Shipping.exe to start...

:wait
timeout /t 5 /nobreak >nul
tasklist /fi "IMAGENAME eq FortniteClient-Win64-Shipping.exe" 2>nul | find "FortniteClient" >nul
if errorlevel 1 goto wait

echo Found Fortnite! Setting CPU affinity to cores 8-15...
powershell -Command "Get-Process 'FortniteClient-Win64-Shipping' | ForEach-Object { $_.ProcessorAffinity = [IntPtr]0xFF00 }"
echo Affinity set! You can close this window.
pause
