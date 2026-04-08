# Pre-commit: parse-check all PS scripts + secret scan
$failed = 0

# PS parse check
Get-ChildItem scripts -Filter '*.ps1' -ErrorAction SilentlyContinue | ForEach-Object {
    $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e) | Out-Null
    if ($e.Count -gt 0) { Write-Error ('PARSE FAIL: ' + $_.Name); $failed++ }
}

# Secret scan
Get-ChildItem -Recurse -Include '*.ps1','*.json','*.js','*.rs','*.toml','*.css','*.html' -ErrorAction SilentlyContinue |
    Where-Object { $_.Length -lt 500KB } | ForEach-Object {
    $c = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
    if ($c -match '(?i)(AKIA[0-9A-Z]{16}|ghp_[a-zA-Z0-9]{36}|sk-[a-zA-Z0-9]{48}|-----BEGIN (RSA |EC )?PRIVATE KEY-----)') {
        Write-Error ('SECRET in ' + $_.FullName)
        $failed++
    }
}

if ($failed -gt 0) { exit 1 }
Write-Host 'Pre-commit: all checks passed'
