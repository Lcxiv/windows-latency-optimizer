@echo off
REM Lock VRAM minimum clock to 810 MHz to prevent P8 wake-up stutter
REM RTX 5070 Ti GDDR7: 405(P8), 810(P5), 7001, 13801, 14001(P0)
REM This prevents the 405->14001 MHz transition lag on desktop/game launch
C:\Windows\System32\nvidia-smi.exe -lmc 810,14001
