@echo off
bcdedit /deletevalue {current} safeboot
shutdown /r /t 5 /c "LatencyGuard: Defender KILL complete. Rebooting to Normal mode..."
