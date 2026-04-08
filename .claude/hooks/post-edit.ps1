param([string]$FilePath)
if ($FilePath -match '\.ps1$') {
    $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$null, [ref]$e) | Out-Null
    if ($e.Count -gt 0) {
        Write-Error ('PS parse errors in ' + $FilePath + ': ' + ($e | ForEach-Object { $_.Message }) -join ', ')
        exit 1
    }
    Write-Host ('PS parse OK: ' + $FilePath)
} elseif ($FilePath -match '\.wprp$') {
    try { [xml](Get-Content $FilePath); Write-Host ('XML valid: ' + $FilePath) }
    catch { Write-Error ('XML invalid: ' + $FilePath); exit 1 }
}
# Secret scan
if ($FilePath -match '\.(ps1|json|js|rs|toml|css|html|wprp)$') {
    $c = Get-Content $FilePath -Raw -ErrorAction SilentlyContinue
    if ($c -match '(?i)(AKIA[0-9A-Z]{16}|ghp_[a-zA-Z0-9]{36}|sk-[a-zA-Z0-9]{48}|-----BEGIN (RSA |EC )?PRIVATE KEY-----)') {
        Write-Error ('SECRET DETECTED in ' + $FilePath + ' -- do not commit')
        exit 1
    }
}
