---
tags: [research, dwm, mpo, unreal-engine, crash]
date: 2026-04-22
status: complete
aliases: [DWM MPO Crash, OverlayTestMode]
---

**Crash signature:**
```
Assertion failed: SUCCEEDED(DwmExtendFrameIntoClientArea(HWnd, &Margins))
File: ...ApplicationCore\Private\Windows\WindowsWindow.cpp  Line: 363
Stack: EpicGamesLauncher -> user32 (WndProc) -> UE WindowsWindow -> DwmExtendFrameIntoClientArea
GetLastError: 0  (HRESULT from DWM itself, not Win32)
```

**Confirmed trigger on user's machine (2026-04-22, log `UECC-Windows-7B9FBC72424B712A41420D959379C8DF_0000`):**
Launcher ran 35 s fine → user launched Ghost Recon Breakpoint via `uplay://launch/11903?source=epic` → GRB went foreground fullscreen at `14:46:23` → 9 s later at `14:46:32` Launcher asserted on GameThread.

**Why:** GRB fullscreen-exclusive mode-switch + MPO disabled (`HKLM\SOFTWARE\Microsoft\Windows\Dwm\OverlayTestMode=5` from EXP11/EXP13) means DWM tears down composition surface during the flip transition. Launcher's WndProc receives `WM_DWMCOMPOSITIONCHANGED` / `WM_DISPLAYCHANGE`, calls `DwmExtendFrameIntoClientArea`, gets `DWM_E_COMPOSITIONDISABLED` (or transient `E_FAIL`), UE's `verify()` macro hard-asserts.

**Why:** EXP11 `exp11_stutter_fixes_apply.ps1` and EXP13 `exp13_fso_mitigation_apply.ps1` set `OverlayTestMode=5` to mitigate FSO stutter. Unintended side effect: any UE-based launcher or windowed app on the primary monitor crashes when a different app takes fullscreen exclusive.

**How to apply:**
- When user reports Epic Launcher / UE app crash after launching a game → check `Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' OverlayTestMode` first, NOT Themes service.
- Fix priority: (1) Epic Settings "Exit after launch", (2) Set game to Borderless Windowed, (3) `Remove-ItemProperty ...\Dwm OverlayTestMode` + reboot.
- Before recommending EXP11/EXP13 in future plans, add a warning: "This breaks UE-based launchers when launching fullscreen-exclusive games."
- Consider adding `Test-DWMHealth` audit check that flags `OverlayTestMode=5` as "warning: causes UE launcher crashes on fullscreen game launch."
- Games most affected (use fullscreen-exclusive): GRB, older AnvilNext titles, UE4 games pre-UE5. Borderless-by-default games (Fortnite, most UE5) are unaffected.
