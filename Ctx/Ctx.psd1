@{
    RootModule           = 'Ctx.psm1'
    ModuleVersion        = '1.1.0'
    GUID                 = '6f0b8a52-3c1e-4d3b-9a47-2f5c8e1d7b90'
    Author               = 'qxsch'
    Copyright            = '(c) qxsch. MIT License.'
    Description          = 'ctx - switch between environments (tenant + login) for Azure CLI and Az PowerShell, activate PIM roles and connect Microsoft Graph.'
    PowerShellVersion    = '7.2'
    CompatiblePSEditions = @('Core')
    FormatsToProcess     = @('Ctx.Format.ps1xml')
    FunctionsToExport    = @(
        'Invoke-Ctx'
        'Switch-CtxEnvironment', 'Sync-CtxEnvironment'
        'Get-CtxEnvironment', 'Add-CtxEnvironment', 'Remove-CtxEnvironment', 'Rename-CtxEnvironment', 'Set-CtxEnvironment'
        'Export-CtxEnvironment', 'Import-CtxEnvironment'
        'Select-CtxSubscription', 'Invoke-CtxCommand', 'Open-CtxPortal'
        'Invoke-CtxPim', 'Connect-CtxGraph'
        'Get-CtxStatus', 'Test-CtxSetup', 'Set-CtxConfig', 'Get-CtxConfig', 'Get-CtxHelp', 'Get-CtxPromptBadge'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @('ctx')
    PrivateData          = @{
        PSData = @{
            Tags         = @('Azure', 'AzureCLI', 'Tenant', 'PIM', 'MicrosoftGraph', 'Entra', 'Windows')
            ProjectUri   = 'https://github.com/qxsch/ctx'
            LicenseUri   = 'https://github.com/qxsch/ctx/blob/main/LICENSE'
            ReleaseNotes = @'
1.1.0
- Security: 'ctx import' accepts only portable fields, validates IDs (GUID) and tenant domains, asks before keeping a
  custom graphClientId, and strips terminal control characters. az.cmd arguments with shell metacharacters are refused;
  browsers are started with one argument per value; only Microsoft device-login pages are opened.
- Security: Graph sessions stop renewing after graphMaxSessionHours (default 12).
- Safety: 'ctx exec' asks before running in production environments (-Force skips); Set-CtxEnvironment and
  Set-CtxConfig support -WhatIf/-Confirm; Uninstall.ps1 -RemoveData only deletes folders that contain ctx data.
- Fixes: 'ctx doctor' checks Az autosave and orphaned contexts again; a state lock timeout no longer writes unlocked;
  config.json is written atomically under the lock; $env:EDITOR may contain arguments; Install.ps1 escapes quotes;
  the 'ctx rm' confirmation shows the environment again.
- Install.ps1 installs prerequisites with Install-PSResource (minimum versions) and can sign the module; 'ctx doctor'
  reports the module signature and flags files changed after signing.
- Module: Windows-only guard, strict mode, the manifest is the single export list, MIT license, CI (PSScriptAnalyzer + Pester).
'@
        }
    }
}
