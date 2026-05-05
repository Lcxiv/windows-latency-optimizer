#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Audit check modules loader.
.DESCRIPTION
    Dot-sources all category files from scripts/audit-checks/.
    Each module provides one or more check functions used by audit.ps1.
    _helpers.ps1 sorts first (underscore prefix) and provides shared functions.
#>

$checksDir = Join-Path $PSScriptRoot 'audit-checks'
Get-ChildItem -Path $checksDir -Filter '*.ps1' | Sort-Object Name | ForEach-Object {
    . $_.FullName
}
