@{
    Severity     = @('Error', 'Warning', 'Information')
    ExcludeRules = @(
        # Interactive CLI: colored host output is the user interface.
        'PSAvoidUsingWriteHost'
        # PowerShell 7.2+ only, where UTF-8 without BOM is the default (Install.ps1 adds a BOM before signing).
        'PSUseBOMForUnicodeEncodedFile'
        # Established public command names (Get-CtxActiveActivations, Register-CtxArgumentCompleters, ...).
        'PSUseSingularNouns'
        # Parameters used inside nested script blocks (state mutations, completers) are reported as unused.
        'PSReviewUnusedParameter'
        # Internal helpers only; every exported command that changes state supports -WhatIf (enforced by the tests).
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
