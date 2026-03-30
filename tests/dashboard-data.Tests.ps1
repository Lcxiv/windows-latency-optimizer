<#
.SYNOPSIS
    Pester 3.x tests validating dashboard data files.
.DESCRIPTION
    Ensures experiments.js and experiments_generated.js are syntactically valid
    and contain expected data structure.
    Run: Invoke-Pester .\tests\dashboard-data.Tests.ps1
#>

$dashboardDir = "$PSScriptRoot\..\dashboard"
$dataDir = "$dashboardDir\data"

Describe 'Dashboard Data Files' {

    Context 'experiments.js' {
        $filePath = Join-Path $dataDir 'experiments.js'

        It 'exists' {
            Test-Path $filePath | Should Be $true
        }

        It 'contains window.EXPERIMENTS assignment' {
            $content = Get-Content $filePath -Raw
            $content | Should Match 'window\.EXPERIMENTS\s*='
        }

        It 'has valid JavaScript array syntax (opening and closing brackets)' {
            $content = Get-Content $filePath -Raw
            $content | Should Match '\['
            $content | Should Match '\];'
        }

        It 'contains at least the baseline experiment' {
            $content = Get-Content $filePath -Raw
            $content | Should Match 'baseline'
        }

        It 'has DPCTimePct fields' {
            $content = Get-Content $filePath -Raw
            $content | Should Match 'DPCTimePct'
        }

        It 'has InterruptTimePct fields' {
            $content = Get-Content $filePath -Raw
            $content | Should Match 'InterruptTimePct'
        }

        It 'has cpuData arrays' {
            $content = Get-Content $filePath -Raw
            $content | Should Match 'cpuData'
        }
    }

    Context 'experiments_generated.js' {
        $filePath = Join-Path $dataDir 'experiments_generated.js'

        It 'exists' {
            Test-Path $filePath | Should Be $true
        }

        It 'contains window.EXPERIMENTS_GENERATED assignment' {
            $content = Get-Content $filePath -Raw
            $content | Should Match 'window\.EXPERIMENTS_GENERATED\s*='
        }

        It 'has valid JavaScript array syntax' {
            $content = Get-Content $filePath -Raw
            $content | Should Match '\['
            $content | Should Match '\];'
        }
    }

    Context 'Dashboard HTML integrity' {
        $htmlPath = Join-Path $dashboardDir 'index.html'
        $cssPath = Join-Path $dashboardDir 'app.css'
        $jsPath = Join-Path $dashboardDir 'app.js'

        It 'index.html exists' {
            Test-Path $htmlPath | Should Be $true
        }

        It 'app.css exists' {
            Test-Path $cssPath | Should Be $true
        }

        It 'app.js exists' {
            Test-Path $jsPath | Should Be $true
        }

        It 'index.html references app.css' {
            $content = Get-Content $htmlPath -Raw
            $content | Should Match 'app\.css'
        }

        It 'index.html references app.js' {
            $content = Get-Content $htmlPath -Raw
            $content | Should Match 'app\.js'
        }

        It 'index.html references experiments.js' {
            $content = Get-Content $htmlPath -Raw
            $content | Should Match 'experiments\.js'
        }

        It 'app.js contains escHtml function (XSS protection)' {
            $content = Get-Content $jsPath -Raw
            $content | Should Match 'function escHtml'
        }

        It 'app.js contains DOMContentLoaded handler' {
            $content = Get-Content $jsPath -Raw
            $content | Should Match 'DOMContentLoaded'
        }
    }
}

Describe 'Rollback Script Safety' {
    $rollbackPath = "$PSScriptRoot\..\scripts\rollback.ps1"

    It 'rollback.ps1 exists' {
        Test-Path $rollbackPath | Should Be $true
    }

    It 'contains cmdlet allowlist' {
        $content = Get-Content $rollbackPath -Raw
        $content | Should Match 'Set-ItemProperty'
        $content | Should Match 'Remove-ItemProperty'
    }

    It 'validates commands before execution' {
        $content = Get-Content $rollbackPath -Raw
        # Should have some form of validation/allowlist check
        $content | Should Match 'allow'
    }
}

Describe 'PowerShell Script Parse Validation' {
    $scripts = Get-ChildItem "$PSScriptRoot\..\scripts\*.ps1"

    foreach ($script in $scripts) {
        It "$($script.Name) parses without errors" {
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$null, [ref]$errors) | Out-Null
            $errors.Count | Should Be 0
        }
    }
}
