#Requires -Version 7.2
# ctx - environment (tenant + login) switcher for Azure CLI, Az PowerShell, PIM and Microsoft Graph.
# Persistent data lives in %LOCALAPPDATA%\ctx (override with $env:CTX_HOME); this folder only holds code.

if (-not $IsWindows) {
    throw 'ctx supports Windows only (it uses %LOCALAPPDATA%, user environment variables, az.cmd and Edge/Chrome profiles).'
}
# Version 1.0 rejects uninitialized variables (typos, missing assignments) without changing property access semantics.
Set-StrictMode -Version 1.0

# >>> loader (Install.ps1 inlines all files here for the installed copy: one file loads faster)
foreach ($folder in 'Private', 'Public') {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot $folder) -Filter '*.ps1' | Sort-Object Name) {
        . $file.FullName
    }
}
# <<< loader

Set-Alias -Name ctx -Value Invoke-Ctx

Register-CtxArgumentCompleters
Initialize-CtxSession

$ExecutionContext.SessionState.Module.OnRemove = {
    try { Uninstall-CtxPrompt } catch { Write-Debug "ctx: could not restore the prompt: $_" }
    try { Stop-CtxGraphRenewal } catch { Write-Debug "ctx: could not stop Graph renewal: $_" }
}

# The manifest is the single source of truth for the public surface.
$ctxManifest = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'Ctx.psd1')
Export-ModuleMember -Function $ctxManifest.FunctionsToExport -Alias $ctxManifest.AliasesToExport
Remove-Variable -Name ctxManifest
