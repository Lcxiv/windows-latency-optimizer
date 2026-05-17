@{
    # PSScriptAnalyzer rule configuration for Windows Latency Optimizer.
    # Scope: scripts/ only. Tests/, spike/, _deprecated/ excluded by wrapper.

    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # Write-Host is correct for interactive CLI scripts with colored output
        'PSAvoidUsingWriteHost',
        # Project uses domain-specific verbs (Get-Stats, Parse-FrameCSV); intent
        # is descriptive name over Approved Verb compliance
        'PSUseSingularNouns',
        'PSUseApprovedVerbs',
        # Admin scripts intentionally change state without -WhatIf
        'PSUseShouldProcessForStateChangingFunctions',
        # Readability over rigid positional-vs-named flagging
        'PSAvoidUsingPositionalParameters',
        # Style only; project mixes K&R + Allman per file
        'PSPlaceOpenBrace',
        'PSPlaceCloseBrace',
        'PSUseConsistentIndentation',
        # Network diagnostic scripts legitimately ping known IPs (1.1.1.1, 8.8.8.8)
        # for reachability checks — those are not sensitive
        'PSAvoidUsingComputerNameHardcoded'
    )

    Rules = @{
        PSUseConsistentWhitespace = @{ Enable = $false }
    }
}
