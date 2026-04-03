use std::process::Command;
use std::path::PathBuf;

/// Find the scripts directory relative to the executable or CWD
fn scripts_dir() -> PathBuf {
    // Try relative to exe: ../scripts/ (when running from latencyguard/)
    if let Ok(exe) = std::env::current_exe() {
        let parent = exe.parent().unwrap_or(std::path::Path::new("."));
        // In dev mode, exe is in target/debug/, scripts are at ../../scripts/
        for ancestor in parent.ancestors().take(5) {
            let candidate = ancestor.join("scripts");
            if candidate.join("audit.ps1").exists() {
                return candidate;
            }
        }
    }
    // Fallback: check CWD parents
    if let Ok(cwd) = std::env::current_dir() {
        for ancestor in cwd.ancestors().take(5) {
            let candidate = ancestor.join("scripts");
            if candidate.join("audit.ps1").exists() {
                return candidate;
            }
        }
    }
    PathBuf::from("scripts")
}

/// Run a PowerShell command and capture stdout
fn run_ps(script: &str, args: &[&str]) -> Result<String, String> {
    let scripts = scripts_dir();
    let script_path = scripts.join(script);
    if !script_path.exists() {
        return Err(format!("Script not found: {}", script_path.display()));
    }

    let mut cmd = Command::new("powershell");
    cmd.arg("-ExecutionPolicy").arg("Bypass")
        .arg("-File").arg(&script_path);
    for arg in args {
        cmd.arg(arg);
    }

    let output = cmd.output().map_err(|e| format!("Failed to spawn PowerShell: {}", e))?;
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    if !output.status.success() {
        return Err(format!("Script failed (exit {}): {}", output.status, stderr));
    }
    Ok(stdout)
}

/// Run an inline PowerShell expression
fn run_ps_expression(expr: &str) -> Result<String, String> {
    let output = Command::new("powershell")
        .arg("-ExecutionPolicy").arg("Bypass")
        .arg("-Command").arg(expr)
        .output()
        .map_err(|e| format!("Failed to spawn PowerShell: {}", e))?;

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

#[tauri::command]
pub async fn get_system_info() -> Result<serde_json::Value, String> {
    let scripts = scripts_dir();
    let checks_path = scripts.join("audit-checks.ps1");

    let expr = format!(
        ". '{}'; Get-SystemInfo | ConvertTo-Json -Depth 4",
        checks_path.display()
    );

    let output = run_ps_expression(&expr)?;
    let json: serde_json::Value = serde_json::from_str(output.trim())
        .map_err(|e| format!("Failed to parse system info JSON: {}", e))?;
    Ok(json)
}

#[tauri::command]
pub async fn run_audit(mode: String) -> Result<serde_json::Value, String> {
    let mode_arg = format!("-Mode");
    let args = vec![mode_arg.as_str(), mode.as_str(), "-Quiet"];
    let _output = run_ps("audit.ps1", &args)?;

    // Find the latest audit JSON
    let scripts = scripts_dir();
    let audits_dir = scripts.parent().unwrap_or(std::path::Path::new(".")).join("captures").join("audits");

    let mut json_files: Vec<_> = std::fs::read_dir(&audits_dir)
        .map_err(|e| format!("Cannot read audits dir: {}", e))?
        .filter_map(|e| e.ok())
        .filter(|e| {
            e.path().extension().map_or(false, |ext| ext == "json")
                && e.file_name().to_string_lossy().starts_with("audit_")
        })
        .collect();

    json_files.sort_by_key(|e| std::cmp::Reverse(e.file_name().to_string_lossy().to_string()));

    let latest = json_files.first()
        .ok_or("No audit JSON files found")?;

    let content = std::fs::read_to_string(latest.path())
        .map_err(|e| format!("Cannot read {}: {}", latest.path().display(), e))?;

    // Strip UTF-8 BOM if present
    let clean = content.strip_prefix('\u{feff}').unwrap_or(&content);

    let json: serde_json::Value = serde_json::from_str(clean)
        .map_err(|e| format!("Failed to parse audit JSON: {}", e))?;

    Ok(json)
}

#[tauri::command]
pub async fn apply_fix(command: String) -> Result<bool, String> {
    let output = Command::new("powershell")
        .arg("-ExecutionPolicy").arg("Bypass")
        .arg("-Command").arg(&command)
        .output()
        .map_err(|e| format!("Failed to run fix: {}", e))?;

    Ok(output.status.success())
}
