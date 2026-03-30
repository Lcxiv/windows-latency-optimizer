@{
    # Rules to exclude — intentional design choices for CLI scripts
    ExcludeRules = @(
        # Write-Host is correct for interactive CLI scripts with colored output
        'PSAvoidUsingWriteHost',
        # BOM encoding is not required for our scripts
        'PSUseBOMForUnicodeEncodedFile',
        # Get-Stats is a well-known name; Parse-FrameCSV is descriptive
        'PSUseSingularNouns',
        'PSUseApprovedVerbs',
        # Pipeline functions are called programmatically, not interactively
        'PSUseShouldProcessForStateChangingFunctions'
    )

    Severity = @('Error', 'Warning')
}
