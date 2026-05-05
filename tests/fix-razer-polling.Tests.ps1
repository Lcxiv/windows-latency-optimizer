<#
.SYNOPSIS
    Pester tests for fix_razer_polling.ps1 - Razer polling rate fix.
.DESCRIPTION
    Tests that the script detects Razer mice via USB PID, checks for Synapse,
    respects -WhatIf for download actions, and handles missing devices.
    Run: Invoke-Pester .\tests\fix-razer-polling.Tests.ps1
#>

Describe 'fix_razer_polling - device detection' {
    BeforeAll {
        $script:scriptPath = "$PSScriptRoot\..\scripts\fix_razer_polling.ps1"
    }

    It 'detects Razer mouse via VID_1532 in HID devices' {
        Mock Get-WmiObject {
            return @(
                [PSCustomObject]@{
                    DeviceID = 'HID\VID_1532&PID_00C1&MI_00\7&abc&0'
                    Name     = 'HID-compliant mouse'
                    Service  = 'mouhid'
                }
            )
        }

        # Mock Synapse check - already installed
        Mock Get-ItemProperty {
            return @(
                [PSCustomObject]@{ DisplayName = 'Razer Synapse 3' }
            )
        }
        Mock Start-BitsTransfer {}
        Mock Start-Process {}

        # Should complete without error (Synapse already installed)
        { & $script:scriptPath -Confirm:$false 2>$null } | Should Not Throw
    }

    It 'identifies known Razer mouse model from PID table' {
        Mock Get-WmiObject {
            return @(
                [PSCustomObject]@{
                    DeviceID = 'HID\VID_1532&PID_00C1&MI_00\7&abc&0'
                    Name     = 'HID-compliant mouse'
                    Service  = 'mouhid'
                }
            )
        }

        Mock Get-ItemProperty {
            return @(
                [PSCustomObject]@{ DisplayName = 'Razer Synapse 3' }
            )
        }
        Mock Start-BitsTransfer {}
        Mock Start-Process {}

        # PID 00C1 = Viper V3 Pro (Wireless) - script should identify it
        # We just verify it runs without error; the identification is written to host
        { & $script:scriptPath -Confirm:$false 2>$null } | Should Not Throw
    }
}

Describe 'fix_razer_polling - WhatIf' {
    BeforeAll {
        $script:scriptPath = "$PSScriptRoot\..\scripts\fix_razer_polling.ps1"
    }

    It 'does not download installer with -WhatIf' {
        Mock Get-WmiObject {
            return @(
                [PSCustomObject]@{
                    DeviceID = 'HID\VID_1532&PID_00C1&MI_00\7&abc&0'
                    Name     = 'HID-compliant mouse'
                    Service  = 'mouhid'
                }
            )
        }

        # Synapse NOT installed - would normally trigger download
        Mock Get-ItemProperty { return @() }
        Mock Start-BitsTransfer {}
        Mock Start-Process {}

        & $script:scriptPath -WhatIf 2>$null

        Assert-MockCalled Start-BitsTransfer -Times 0 -Scope It
        Assert-MockCalled Start-Process -Times 0 -Scope It
    }

    It 'does not launch installer with -WhatIf' {
        Mock Get-WmiObject {
            return @(
                [PSCustomObject]@{
                    DeviceID = 'HID\VID_1532&PID_007A&MI_00\7&xyz&0'
                    Name     = 'HID-compliant mouse'
                    Service  = 'HidUsb'
                }
            )
        }

        Mock Get-ItemProperty { return @() }
        Mock Start-BitsTransfer {}
        Mock Start-Process {}

        & $script:scriptPath -WhatIf 2>$null

        Assert-MockCalled Start-Process -Times 0 -Scope It
    }
}

Describe 'fix_razer_polling - no Razer mouse' {
    BeforeAll {
        $script:scriptPath = "$PSScriptRoot\..\scripts\fix_razer_polling.ps1"
    }

    It 'exits with error when no Razer mouse is detected' {
        Mock Get-WmiObject {
            # Return non-Razer HID devices only
            return @(
                [PSCustomObject]@{
                    DeviceID = 'HID\VID_046D&PID_C52B&MI_00\7&def&0'
                    Name     = 'HID-compliant mouse'
                    Service  = 'mouhid'
                }
            )
        }
        Mock Get-ItemProperty { return @() }
        Mock Start-BitsTransfer {}
        Mock Start-Process {}

        & $script:scriptPath 2>$null
        $LASTEXITCODE | Should Be 1
    }

    It 'does not attempt download when no Razer mouse found' {
        Mock Get-WmiObject {
            return @(
                [PSCustomObject]@{
                    DeviceID = 'HID\VID_046D&PID_C52B&MI_00\7&def&0'
                    Name     = 'HID-compliant mouse'
                    Service  = 'mouhid'
                }
            )
        }
        Mock Get-ItemProperty { return @() }
        Mock Start-BitsTransfer {}
        Mock Start-Process {}

        & $script:scriptPath 2>$null

        Assert-MockCalled Start-BitsTransfer -Times 0 -Scope It
        Assert-MockCalled Start-Process -Times 0 -Scope It
    }
}

Describe 'fix_razer_polling - Synapse already installed' {
    BeforeAll {
        $script:scriptPath = "$PSScriptRoot\..\scripts\fix_razer_polling.ps1"
    }

    It 'skips download when Synapse is already installed' {
        Mock Get-WmiObject {
            return @(
                [PSCustomObject]@{
                    DeviceID = 'HID\VID_1532&PID_00C1&MI_00\7&abc&0'
                    Name     = 'HID-compliant mouse'
                    Service  = 'mouhid'
                }
            )
        }

        # Synapse found in uninstall registry
        Mock Get-ItemProperty {
            return @(
                [PSCustomObject]@{ DisplayName = 'Razer Synapse 3' }
            )
        }
        Mock Start-BitsTransfer {}
        Mock Start-Process {}

        & $script:scriptPath -Confirm:$false 2>$null

        Assert-MockCalled Start-BitsTransfer -Times 0 -Scope It
        Assert-MockCalled Start-Process -Times 0 -Scope It
    }
}
