---
tags: [reference, tauri, rust, ipc, windows]
date: 2026-04-05
status: complete
aliases: [Tauri Patterns]
---

## Prerequisites (confidence 0.95)
- Rust toolchain: `winget install Rustlang.Rustup`
- MSVC Build Tools: `winget install Microsoft.VisualStudio.2022.BuildTools --override "--add Microsoft.VisualStudio.Workload.VCTools"`
- Verify: `cl.exe` available before `cargo tauri build`

**Why:** Tauri compiles Rust on Windows via MSVC. The zerocopy crate specifically needs C++ compiler.

## Global Tauri IPC (confidence 0.95)
Add `"withGlobalTauri": true` to `app` section of `tauri.conf.json`.

**Why:** Tauri v2 doesn't inject `window.__TAURI__` by default. Without it, `invoke()` calls silently fail — buttons appear to do nothing.

## Script Execution from apply_fix (confidence 0.9)
When `apply_fix` receives a script path (like `.\scripts\fix_razer_polling.ps1`), use `-File` with absolute path, not `-Command` with relative path.

**Why:** `-Command` resolves paths relative to CWD (which is the Tauri binary dir, not project root). Use `scripts_dir()` to resolve absolute paths, same as `run_ps()`.

**How to apply:** Check if command starts with `.\scripts\` → strip prefix, pass to `run_ps()` which uses `-File` with `scripts_dir()` resolution.

## Build Lock (confidence 0.9)
Close the running LatencyGuard window before `cargo tauri build`. The .exe is locked while running.

**Why:** Windows locks running executables. `taskkill` from Git Bash fails because `/IM` is interpreted as a file path. Use `cmd.exe /c 'taskkill /IM latencyguard.exe /F'` or ask user to close manually.

## Color Variables for Accessibility (confidence 0.9)
Split `--blue` into `--blue` (#60a5fa for text) and `--blue-bg` (#2563eb for filled buttons).

**Why:** White text on #3b82f6 = 3.7:1 contrast (fails WCAG AA). #2563eb = 4.6:1 (passes). Blue text on dark surfaces needs the lighter #60a5fa variant.
