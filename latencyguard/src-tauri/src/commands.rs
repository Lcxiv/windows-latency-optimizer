use std::process::Command;
use std::path::PathBuf;

/// Find the scripts directory relative to the executable or CWD.
/// Search order: LATENCYGUARD_SCRIPTS env var → exe ancestors → CWD ancestors → fallback.
pub fn scripts_dir() -> PathBuf {
    // 1. Explicit override via environment variable
    if let Ok(env_path) = std::env::var("LATENCYGUARD_SCRIPTS") {
        let p = PathBuf::from(&env_path);
        if p.join("audit.ps1").exists() {
            return p;
        }
        eprintln!("[LatencyGuard] LATENCYGUARD_SCRIPTS={} but audit.ps1 not found there", env_path);
    }

    // 2. Walk ancestors from exe location (up to 10 levels for safety)
    if let Ok(exe) = std::env::current_exe() {
        let parent = exe.parent().unwrap_or(std::path::Path::new("."));
        for ancestor in parent.ancestors().take(10) {
            let candidate = ancestor.join("scripts");
            if candidate.join("audit.ps1").exists() {
                return candidate;
            }
        }
    }

    // 3. Walk ancestors from CWD
    if let Ok(cwd) = std::env::current_dir() {
        for ancestor in cwd.ancestors().take(10) {
            let candidate = ancestor.join("scripts");
            if candidate.join("audit.ps1").exists() {
                return candidate;
            }
        }
    }

    eprintln!("[LatencyGuard] Could not find scripts/audit.ps1 — commands will fail. \
        Set LATENCYGUARD_SCRIPTS to the scripts directory path.");
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

/// Read the latest audit JSON without running a scan (instant load on app launch)
#[tauri::command]
pub async fn get_latest_audit() -> Result<serde_json::Value, String> {
    let scripts = scripts_dir();
    let audits_dir = scripts.parent().unwrap_or(std::path::Path::new(".")).join("captures").join("audits");

    if !audits_dir.exists() {
        return Ok(serde_json::Value::Null);
    }

    let mut json_files: Vec<_> = std::fs::read_dir(&audits_dir)
        .map_err(|e| format!("Cannot read audits dir: {}", e))?
        .filter_map(|e| e.ok())
        .filter(|e| {
            e.path().extension().map_or(false, |ext| ext == "json")
                && e.file_name().to_string_lossy().starts_with("audit_")
        })
        .collect();

    if json_files.is_empty() {
        return Ok(serde_json::Value::Null);
    }

    json_files.sort_by_key(|e| std::cmp::Reverse(e.file_name().to_string_lossy().to_string()));

    read_json_file(&json_files[0].path())
}

#[tauri::command]
pub async fn apply_fix(command: String) -> Result<bool, String> {
    // If the command is a script path, resolve it via scripts_dir() and use -File
    if command.starts_with(".\\scripts\\") || command.starts_with("./scripts/") {
        let script_name = command
            .trim_start_matches(".\\scripts\\")
            .trim_start_matches("./scripts/");
        match run_ps(script_name, &[]) {
            Ok(_) => return Ok(true),
            Err(e) => return Err(e),
        }
    }

    // Otherwise run as inline PowerShell expression
    let output = Command::new("powershell")
        .arg("-ExecutionPolicy").arg("Bypass")
        .arg("-Command").arg(&command)
        .output()
        .map_err(|e| format!("Failed to run fix: {}", e))?;

    Ok(output.status.success())
}

/// Helper to read a JSON file, stripping BOM
fn read_json_file(path: &std::path::Path) -> Result<serde_json::Value, String> {
    let content = std::fs::read_to_string(path)
        .map_err(|e| format!("Cannot read {}: {}", path.display(), e))?;
    let clean = content.strip_prefix('\u{feff}').unwrap_or(&content);
    serde_json::from_str(clean)
        .map_err(|e| format!("Failed to parse {}: {}", path.display(), e))
}

#[tauri::command]
pub async fn get_pipeline_data() -> Result<serde_json::Value, String> {
    let scripts = scripts_dir();
    let project = scripts.parent().unwrap_or(std::path::Path::new("."));
    let exp_dir = project.join("captures").join("experiments");

    if !exp_dir.exists() {
        return Ok(serde_json::Value::Null);
    }

    // Find latest experiment directory
    let mut dirs: Vec<_> = std::fs::read_dir(&exp_dir)
        .map_err(|e| format!("Cannot read experiments: {}", e))?
        .filter_map(|e| e.ok())
        .filter(|e| e.path().is_dir())
        .collect();

    dirs.sort_by_key(|e| std::cmp::Reverse(e.file_name().to_string_lossy().to_string()));

    let latest = match dirs.first() {
        Some(d) => d,
        None => return Ok(serde_json::Value::Null),
    };

    let exp_json = latest.path().join("experiment.json");
    if !exp_json.exists() {
        return Ok(serde_json::Value::Null);
    }

    let mut result = read_json_file(&exp_json)?;

    // Merge input latency analysis if present
    let input_json = latest.path().join("input_latency_analysis.json");
    if input_json.exists() {
        if let Ok(input_data) = read_json_file(&input_json) {
            result["inputLatency"] = input_data;
        }
    }

    Ok(result)
}

#[tauri::command]
pub async fn get_experiments() -> Result<Vec<serde_json::Value>, String> {
    let scripts = scripts_dir();
    let project = scripts.parent().unwrap_or(std::path::Path::new("."));
    let exp_dir = project.join("captures").join("experiments");

    if !exp_dir.exists() {
        return Ok(vec![]);
    }

    let mut experiments = vec![];

    let mut dirs: Vec<_> = std::fs::read_dir(&exp_dir)
        .map_err(|e| format!("Cannot read experiments: {}", e))?
        .filter_map(|e| e.ok())
        .filter(|e| e.path().is_dir())
        .collect();

    dirs.sort_by_key(|e| std::cmp::Reverse(e.file_name().to_string_lossy().to_string()));

    for dir in dirs.iter().take(50) {
        let json_path = dir.path().join("experiment.json");
        if json_path.exists() {
            if let Ok(data) = read_json_file(&json_path) {
                experiments.push(data);
            }
        }
    }

    Ok(experiments)
}

#[tauri::command]
pub async fn get_history() -> Result<Vec<serde_json::Value>, String> {
    let scripts = scripts_dir();
    let project = scripts.parent().unwrap_or(std::path::Path::new("."));
    let history_path = project.join("captures").join("audits").join("history.csv");

    if !history_path.exists() {
        return Ok(vec![]);
    }

    let content = std::fs::read_to_string(&history_path)
        .map_err(|e| format!("Cannot read history.csv: {}", e))?;
    let clean = content.strip_prefix('\u{feff}').unwrap_or(&content);

    let mut entries = vec![];
    let mut lines = clean.lines();
    let _header = lines.next(); // skip header

    for line in lines {
        let parts: Vec<&str> = line.split(',').collect();
        if parts.len() >= 7 {
            entries.push(serde_json::json!({
                "timestamp": parts[0],
                "mode": parts[1],
                "score": parts[2].parse::<i32>().unwrap_or(0),
                "pass": parts[3].parse::<i32>().unwrap_or(0),
                "warn": parts[4].parse::<i32>().unwrap_or(0),
                "fail": parts[5].parse::<i32>().unwrap_or(0),
                "skip": parts[6].parse::<i32>().unwrap_or(0),
            }));
        }
    }

    Ok(entries)
}
