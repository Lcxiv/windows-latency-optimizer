// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod commands;

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .setup(|_app| {
            let scripts = commands::scripts_dir();
            if scripts.join("audit.ps1").exists() {
                eprintln!("[LatencyGuard] Scripts found at: {}", scripts.display());
            } else {
                eprintln!(
                    "[LatencyGuard] WARNING: scripts directory not found. \
                    Launch from the project root or set LATENCYGUARD_SCRIPTS env var."
                );
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_system_info,
            commands::run_audit,
            commands::get_latest_audit,
            commands::apply_fix,
            commands::get_pipeline_data,
            commands::get_experiments,
            commands::compare_experiments,
            commands::diagnose_mouse,
            commands::export_report,
            commands::get_history,
            commands::run_diagnostic_chain,
            commands::run_single_check,
        ])
        .run(tauri::generate_context!())
        .expect("error while running LatencyGuard");
}
