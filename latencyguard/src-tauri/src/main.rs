// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod commands;

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![
            commands::get_system_info,
            commands::run_audit,
            commands::apply_fix,
            commands::get_pipeline_data,
            commands::get_experiments,
            commands::get_history,
        ])
        .run(tauri::generate_context!())
        .expect("error while running LatencyGuard");
}
