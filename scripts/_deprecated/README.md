# Deprecated Scripts

These scripts have been superseded by consolidated replacements:

| Old Script | Replaced By |
|-----------|-------------|
| `before_reboot_capture.ps1` | `reboot_capture.ps1 -Phase Before` |
| `after_reboot_capture.ps1` | `reboot_capture.ps1 -Phase After` |
| `run_audio_audit.ps1` | `invoke-elevated.ps1 -Script audio_fix_and_audit.ps1 -Arguments '-All'` |
| `run_after_reboot.ps1` | `invoke-elevated.ps1 -Script reboot_capture.ps1 -Arguments '-Phase After'` |
| `run_disable_razer.ps1` | `invoke-elevated.ps1 -Script disable_razer_startup.ps1` |

Moved on 2026-04-15 during toolchain consolidation.
