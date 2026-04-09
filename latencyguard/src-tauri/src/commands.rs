use std::process::Command;
use std::path::PathBuf;
use tauri::Emitter;

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
pub async fn compare_experiments(label1: String, label2: String) -> Result<serde_json::Value, String> {
    let scripts = scripts_dir();
    let project = scripts.parent().unwrap_or(std::path::Path::new("."));
    let exp_dir = project.join("captures").join("experiments");

    if !exp_dir.exists() {
        return Err("No experiments directory found".to_string());
    }

    let mut exp1: Option<serde_json::Value> = None;
    let mut exp2: Option<serde_json::Value> = None;

    let dirs: Vec<_> = std::fs::read_dir(&exp_dir)
        .map_err(|e| format!("Cannot read experiments: {}", e))?
        .filter_map(|e| e.ok())
        .filter(|e| e.path().is_dir())
        .collect();

    for dir in &dirs {
        let json_path = dir.path().join("experiment.json");
        if !json_path.exists() { continue; }
        if let Ok(data) = read_json_file(&json_path) {
            let label = data["label"].as_str().unwrap_or("");
            if label == label1 && exp1.is_none() {
                exp1 = Some(data);
            } else if label == label2 && exp2.is_none() {
                exp2 = Some(data);
            }
            if exp1.is_some() && exp2.is_some() { break; }
        }
    }

    let e1 = exp1.ok_or_else(|| format!("Experiment '{}' not found", label1))?;
    let e2 = exp2.ok_or_else(|| format!("Experiment '{}' not found", label2))?;

    // Compute deltas for key metrics
    let dpc1 = e1["cpuTotal"]["dpcPct"].as_f64().unwrap_or(0.0);
    let dpc2 = e2["cpuTotal"]["dpcPct"].as_f64().unwrap_or(0.0);
    let intr1 = e1["cpuTotal"]["interruptPct"].as_f64().unwrap_or(0.0);
    let intr2 = e2["cpuTotal"]["interruptPct"].as_f64().unwrap_or(0.0);
    let cpu0_1 = e1["interruptTopology"]["cpu0Share"].as_f64().unwrap_or(0.0);
    let cpu0_2 = e2["interruptTopology"]["cpu0Share"].as_f64().unwrap_or(0.0);

    Ok(serde_json::json!({
        "exp1": e1,
        "exp2": e2,
        "deltas": {
            "dpcPct": {
                "before": dpc1, "after": dpc2,
                "delta": dpc2 - dpc1,
                "improved": dpc2 < dpc1
            },
            "interruptPct": {
                "before": intr1, "after": intr2,
                "delta": intr2 - intr1,
                "improved": intr2 < intr1
            },
            "cpu0Share": {
                "before": cpu0_1, "after": cpu0_2,
                "delta": cpu0_2 - cpu0_1,
                "improved": cpu0_2 < cpu0_1
            }
        }
    }))
}

#[tauri::command]
pub async fn diagnose_mouse(duration_sec: Option<u32>) -> Result<serde_json::Value, String> {
    let scripts = scripts_dir();
    let script_path = scripts.join("diagnose-mouse.ps1");
    if !script_path.exists() {
        return Err("diagnose-mouse.ps1 not found".to_string());
    }

    let dur = duration_sec.unwrap_or(10).to_string();
    let args = vec!["-DurationSec", dur.as_str()];
    let _output = run_ps("diagnose-mouse.ps1", &args)?;

    // Find the latest mouse_diagnostic.json
    let project = scripts.parent().unwrap_or(std::path::Path::new("."));
    let exp_dir = project.join("captures").join("experiments");
    if !exp_dir.exists() {
        return Err("No experiments directory".to_string());
    }

    let mut dirs: Vec<_> = std::fs::read_dir(&exp_dir)
        .map_err(|e| format!("Cannot read experiments: {}", e))?
        .filter_map(|e| e.ok())
        .filter(|e| e.path().is_dir() && e.file_name().to_string_lossy().contains("MOUSE_DIAG"))
        .collect();
    dirs.sort_by_key(|e| std::cmp::Reverse(e.file_name().to_string_lossy().to_string()));

    match dirs.first() {
        Some(d) => {
            let json_path = d.path().join("mouse_diagnostic.json");
            if json_path.exists() {
                read_json_file(&json_path)
            } else {
                Err("Mouse diagnostic completed but no JSON output found".to_string())
            }
        }
        None => Err("No mouse diagnostic results found".to_string()),
    }
}

#[tauri::command]
pub async fn export_report() -> Result<String, String> {
    let scripts = scripts_dir();
    let project = scripts.parent().unwrap_or(std::path::Path::new("."));
    let audits_dir = project.join("captures").join("audits");
    let audit_path = scripts.join("audit.ps1");

    if !audit_path.exists() {
        return Err("audit.ps1 not found".to_string());
    }

    // Build a PS expression that runs audit.ps1 in quiet export mode
    // audit.ps1 already handles reading data, calling New-AuditHtmlReport, and writing HTML
    let expr = format!(
        ". '{}' -Mode Deep -Quiet",
        audit_path.display()
    );

    // Run the audit which generates HTML automatically
    let _output = run_ps_expression(&expr)?;

    // Find the latest HTML file generated
    if !audits_dir.exists() {
        return Err("Audits directory not found after export".to_string());
    }

    let mut html_files: Vec<_> = std::fs::read_dir(&audits_dir)
        .map_err(|e| format!("Cannot read audits dir: {}", e))?
        .filter_map(|e| e.ok())
        .filter(|e| {
            e.path().extension().map_or(false, |ext| ext == "html")
                && e.file_name().to_string_lossy().starts_with("audit_")
        })
        .collect();

    html_files.sort_by_key(|e| std::cmp::Reverse(e.file_name().to_string_lossy().to_string()));

    match html_files.first() {
        Some(f) => Ok(f.path().display().to_string()),
        None => Err("No HTML report was generated".to_string()),
    }
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

/// Emit a diagnostic progress event to the frontend
fn emit_progress(app: &tauri::AppHandle, step: u32, total: u32, status: &str) {
    let _ = app.emit("diagnostic-progress", serde_json::json!({
        "step": step,
        "total": total,
        "status": status
    }));
}

#[tauri::command]
pub async fn run_diagnostic_chain(
    symptom: String,
    app_handle: tauri::AppHandle,
) -> Result<serde_json::Value, String> {
    let is_mouse = symptom == "MouseFreezing";
    let total_steps: u32 = if is_mouse { 5 } else { 4 };

    // Step 1: Run targeted audit
    emit_progress(&app_handle, 0, total_steps, "Running targeted system audit...");

    let scripts = scripts_dir();
    let audit_path = scripts.join("audit.ps1");
    if !audit_path.exists() {
        return Err("audit.ps1 not found".to_string());
    }

    let output = Command::new("powershell")
        .arg("-ExecutionPolicy").arg("Bypass")
        .arg("-File").arg(&audit_path)
        .arg("-Mode").arg("Deep")
        .arg("-Symptom").arg(&symptom)
        .arg("-Quiet")
        .output()
        .map_err(|e| format!("Failed to run audit: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("Audit failed: {}", stderr));
    }

    // Step 2: Read audit results
    emit_progress(&app_handle, 1, total_steps, "Reading audit results...");

    let audits_dir = scripts.parent()
        .unwrap_or(std::path::Path::new("."))
        .join("captures").join("audits");

    let audit_data = if audits_dir.exists() {
        let mut json_files: Vec<_> = std::fs::read_dir(&audits_dir)
            .map_err(|e| format!("Cannot read audits dir: {}", e))?
            .filter_map(|e| e.ok())
            .filter(|e| {
                e.path().extension().map_or(false, |ext| ext == "json")
                    && e.file_name().to_string_lossy().starts_with("audit_")
            })
            .collect();
        json_files.sort_by_key(|e| std::cmp::Reverse(e.file_name().to_string_lossy().to_string()));
        match json_files.first() {
            Some(f) => read_json_file(&f.path()).ok(),
            None => None,
        }
    } else {
        None
    };

    // Step 3: Mouse diagnostic (if MouseFreezing)
    let mouse_diag = if is_mouse {
        emit_progress(&app_handle, 2, total_steps, "Running mouse input capture (10s)...");

        let mouse_script = scripts.join("diagnose-mouse.ps1");
        if mouse_script.exists() {
            let mouse_out = Command::new("powershell")
                .arg("-ExecutionPolicy").arg("Bypass")
                .arg("-File").arg(&mouse_script)
                .arg("-DurationSec").arg("10")
                .output()
                .map_err(|e| format!("Mouse diagnostic failed: {}", e))?;

            if mouse_out.status.success() {
                // Read latest mouse diagnostic
                let project = scripts.parent().unwrap_or(std::path::Path::new("."));
                let exp_dir = project.join("captures").join("experiments");
                if exp_dir.exists() {
                    let mut dirs: Vec<_> = std::fs::read_dir(&exp_dir)
                        .ok()
                        .map(|rd| rd.filter_map(|e| e.ok())
                            .filter(|e| e.path().is_dir() && e.file_name().to_string_lossy().contains("MOUSE_DIAG"))
                            .collect())
                        .unwrap_or_default();
                    dirs.sort_by_key(|e| std::cmp::Reverse(e.file_name().to_string_lossy().to_string()));
                    dirs.first().and_then(|d| {
                        let json_path = d.path().join("mouse_diagnostic.json");
                        if json_path.exists() { read_json_file(&json_path).ok() } else { None }
                    })
                } else { None }
            } else { None }
        } else { None }
    } else { None };

    // Step 4: Build findings
    let step_before_final = if is_mouse { 3 } else { 2 };
    emit_progress(&app_handle, step_before_final, total_steps, "Analyzing results and building findings...");

    let checks = audit_data.as_ref()
        .and_then(|d| d["checks"].as_array())
        .cloned()
        .unwrap_or_default();

    let mut findings = Vec::new();
    let mut pass_count: u32 = 0;
    let mut high_count: u32 = 0;
    let mut medium_count: u32 = 0;
    let mut low_count: u32 = 0;

    for check in &checks {
        let status = check["status"].as_str().unwrap_or("SKIP");
        let name = check["name"].as_str().unwrap_or("");
        let current = check["current"].as_str().unwrap_or("");
        let expected = check["expected"].as_str().unwrap_or("");
        let message = check["message"].as_str().unwrap_or("");
        let fix = check["fix"].as_str().unwrap_or("");
        let fix_note = check["fixNote"].as_str().unwrap_or("");
        let severity_raw = check["severity"].as_str().unwrap_or("LOW");
        let category = check["category"].as_str().unwrap_or("");

        if status == "PASS" {
            pass_count += 1;
            continue;
        }
        if status == "SKIP" {
            continue;
        }

        let severity = match severity_raw {
            "CRITICAL" | "HIGH" => { high_count += 1; "high" },
            "MEDIUM" => { medium_count += 1; "medium" },
            _ => { low_count += 1; "low" },
        };

        let fix_type = if !fix.is_empty() { "auto" } else if !fix_note.is_empty() { "manual" } else { "info" };

        findings.push(serde_json::json!({
            "severity": severity,
            "title": name,
            "what": format!("Current: {}", current),
            "why": message,
            "expected": expected,
            "fix": fix,
            "fixNote": fix_note,
            "fixType": fix_type,
            "category": category,
            "current": current,
        }));
    }

    // Sort findings: high first, then medium, then low
    findings.sort_by(|a, b| {
        let order = |s: &str| match s { "high" => 0, "medium" => 1, _ => 2 };
        let sa = a["severity"].as_str().unwrap_or("low");
        let sb = b["severity"].as_str().unwrap_or("low");
        order(sa).cmp(&order(sb))
    });

    // Final step
    emit_progress(&app_handle, total_steps, total_steps, "Complete!");

    Ok(serde_json::json!({
        "symptom": symptom,
        "findings": findings,
        "mouseDiag": mouse_diag,
        "auditData": audit_data,
        "summary": {
            "high": high_count,
            "medium": medium_count,
            "low": low_count,
            "pass": pass_count,
            "total": checks.len()
        }
    }))
}

#[tauri::command]
pub async fn run_single_check(check_name: String) -> Result<serde_json::Value, String> {
    let scripts = scripts_dir();
    let checks_path = scripts.join("audit-checks.ps1");

    let expr = format!(
        ". '{}'; $allChecks = @(); \
         $allChecks += Invoke-OsChecks; $allChecks += Invoke-NicChecks; \
         $allChecks += Invoke-GpuChecks; $allChecks += Invoke-MemoryChecks; \
         $allChecks += Invoke-PeripheralChecks; $allChecks += Invoke-NetworkChecks; \
         $match = $allChecks | Where-Object {{ $_.name -eq '{}' }} | Select-Object -First 1; \
         if ($match) {{ $match | ConvertTo-Json -Depth 4 }} else {{ '{{}}' }}",
        checks_path.display(),
        check_name.replace('\'', "''")
    );

    let output = run_ps_expression(&expr)?;
    let clean = output.trim();
    if clean.is_empty() || clean == "{}" {
        return Err(format!("Check '{}' not found", check_name));
    }
    serde_json::from_str(clean)
        .map_err(|e| format!("Failed to parse check result: {}", e))
}
