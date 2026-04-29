@echo off
echo === Defender KILL (Safe Mode) === > "C:\Users\L\Desktop\windows-latency-optimizer\captures\defender_safemode\defender_kill_log.txt"
echo Time: %date% %time% >> "C:\Users\L\Desktop\windows-latency-optimizer\captures\defender_safemode\defender_kill_log.txt"
echo. >> "C:\Users\L\Desktop\windows-latency-optimizer\captures\defender_safemode\defender_kill_log.txt"
echo Running: reg add "HKLM\SYSTEM\CurrentControlSet\Services\WinDefend" /v Start /t REG_DWORD /d 4 /f >> "C:\Users\L\Desktop\windows-latency-optimizer\captures\defender_safemode\defender_kill_log.txt"
reg add "HKLM\SYSTEM\CurrentControlSet\Services\WinDefend" /v Start /t REG_DWORD /d 4 /f >> "C:\Users\L\Desktop\windows-latency-optimizer\captures\defender_safemode\defender_kill_log.txt" 2>&1
echo Result: %errorlevel% >> "C:\Users\L\Desktop\windows-latency-optimizer\captures\defender_safemode\defender_kill_log.txt"
echo Running: reg add "HKLM\SYSTEM\CurrentControlSet\Services\WdNisSvc" /v Start /t REG_DWORD /d 4 /f >> "C:\Users\L\Desktop\windows-latency-optimizer\captures\defender_safemode\defender_kill_log.txt"
reg add "HKLM\SYSTEM\CurrentControlSet\Services\WdNisSvc" /v Start /t REG_DWORD /d 4 /f >> "C:\Users\L\Desktop\windows-latency-optimizer\captures\defender_safemode\defender_kill_log.txt" 2>&1
echo Result: %errorlevel% >> "C:\Users\L\Desktop\windows-latency-optimizer\captures\defender_safemode\defender_kill_log.txt"
echo Running: reg add "HKLM\SYSTEM\CurrentControlSet\Services\WdFilter" /v Start /t REG_DWORD /d 4 /f >> "C:\Users\L\Desktop\windows-latency-optimizer\captures\defender_safemode\defender_kill_log.txt"
reg add "HKLM\SYSTEM\CurrentControlSet\Services\WdFilter" /v Start /t REG_DWORD /d 4 /f >> "C:\Users\L\Desktop\windows-latency-optimizer\captures\defender_safemode\defender_kill_log.txt" 2>&1
echo Result: %errorlevel% >> "C:\Users\L\Desktop\windows-latency-optimizer\captures\defender_safemode\defender_kill_log.txt"
echo Running: reg add "HKLM\SYSTEM\CurrentControlSet\Services\WdBoot" /v Start /t REG_DWORD /d 4 /f >> "C:\Users\L\Desktop\windows-latency-optimizer\captures\defender_safemode\defender_kill_log.txt"
reg add "HKLM\SYSTEM\CurrentControlSet\Services\WdBoot" /v Start /t REG_DWORD /d 4 /f >> "C:\Users\L\Desktop\windows-latency-optimizer\captures\defender_safemode\defender_kill_log.txt" 2>&1
echo Result: %errorlevel% >> "C:\Users\L\Desktop\windows-latency-optimizer\captures\defender_safemode\defender_kill_log.txt"
echo. >> "C:\Users\L\Desktop\windows-latency-optimizer\captures\defender_safemode\defender_kill_log.txt"
echo === Verification === >> "C:\Users\L\Desktop\windows-latency-optimizer\captures\defender_safemode\defender_kill_log.txt"
reg query "HKLM\SYSTEM\CurrentControlSet\Services\WinDefend" /v Start >> "C:\Users\L\Desktop\windows-latency-optimizer\captures\defender_safemode\defender_kill_log.txt" 2>&1
reg query "HKLM\SYSTEM\CurrentControlSet\Services\WdNisSvc" /v Start >> "C:\Users\L\Desktop\windows-latency-optimizer\captures\defender_safemode\defender_kill_log.txt" 2>&1
reg query "HKLM\SYSTEM\CurrentControlSet\Services\WdFilter" /v Start >> "C:\Users\L\Desktop\windows-latency-optimizer\captures\defender_safemode\defender_kill_log.txt" 2>&1
reg query "HKLM\SYSTEM\CurrentControlSet\Services\WdBoot" /v Start >> "C:\Users\L\Desktop\windows-latency-optimizer\captures\defender_safemode\defender_kill_log.txt" 2>&1
echo. >> "C:\Users\L\Desktop\windows-latency-optimizer\captures\defender_safemode\defender_kill_log.txt"
echo === Done === >> "C:\Users\L\Desktop\windows-latency-optimizer\captures\defender_safemode\defender_kill_log.txt"
