# Prompt badge, PIM expiry reminders and per-terminal session initialization.

$script:CtxOriginalPrompt = $null
$script:CtxPromptInstalled = $false
$script:CtxReminded = @{}
$script:CtxPromptMarker = 'ctx-prompt-wrapper'

function Get-CtxPromptBadge {
    <#
    .SYNOPSIS
    Returns the ctx prompt badge, e.g. [!emea:graph GA 2h13m→germany].
    .DESCRIPTION
    ! = production, :graph = Microsoft Graph connected in this terminal, GA 2h13m = active PIM role and time left
    (yellow below the reminder threshold), *  = switched for this terminal only, →x = the global environment differs.
    Use it in custom prompts (oh-my-posh, starship) when the built-in prompt hook is disabled.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([switch]$NoColor)
    try {
        $state = Get-CtxStateCached
        $name = if ($script:ProcessEnvName) { $script:ProcessEnvName } else { $state.current }
        if (-not $name) { return '' }
        $entry = Find-CtxEnvironment $state $name
        if (-not $entry) { return '' }
        $cfg = Get-CtxConfig
        $r = Get-CtxAnsiReset
        $dim = Get-CtxAnsi 'DarkGray'
        $sb = [Text.StringBuilder]::new()
        [void]$sb.Append($dim + '[' + $r)
        if (Test-CtxProd $entry) { [void]$sb.Append((Get-CtxAnsi 'Red') + '!' + $r) }
        [void]$sb.Append((Get-CtxAnsi (Get-CtxEnvColor $entry)) + $entry.name + $r)
        if ($script:ProcessLocal) { [void]$sb.Append($dim + '*' + $r) }
        if ($script:GraphEnvName -eq $entry.name) { [void]$sb.Append($dim + ':graph' + $r) }
        foreach ($a in @(Get-CtxActiveActivations $entry)) {
            $warn = $a.Remaining -and $a.Remaining.TotalMinutes -le [double]$cfg.pimReminderMinutes
            $color = if ($warn) { 'Yellow' } else { 'Red' }
            [void]$sb.Append(' ' + (Get-CtxAnsi $color) + (Get-CtxRoleShortName $a.RoleName) + ' ' + (Format-CtxDuration $a.Remaining) + $r)
        }
        if ($state.current -and $state.current -ne $entry.name) { [void]$sb.Append($dim + '→' + $state.current + $r) }
        [void]$sb.Append($dim + ']' + $r)
        $text = $sb.ToString()
        if ($NoColor -or $env:NO_COLOR) { $text = Remove-CtxAnsi $text }
        $text
    } catch {
        ''
    }
}

function Invoke-CtxPromptReminder {
    <# Prints a one-time reminder shortly before and right after a cached PIM activation ends. #>
    $state = Get-CtxStateCached
    $name = if ($script:ProcessEnvName) { $script:ProcessEnvName } else { $state.current }
    $entry = Find-CtxEnvironment $state $name
    if (-not $entry) { return }
    $threshold = [double](Get-CtxConfig).pimReminderMinutes
    $now = [datetime]::UtcNow
    foreach ($a in @($entry.activations)) {
        if (-not $a) { continue }
        $end = ConvertTo-CtxDate $a.expiresAt
        if (-not $end) { continue }
        $key = "$($entry.name)|$($a.roleId)|$(ConvertTo-CtxIsoDate $end)"
        $left = $end - $now
        if ($left.TotalSeconds -le 0) {
            if ($left.TotalMinutes -gt -60 -and -not $script:CtxReminded["$key|x"]) {
                $script:CtxReminded["$key|x"] = $true
                Write-Host "  ⏰ ctx: $($a.roleName) in '$($entry.name)' has expired - 'ctx pim' activates it again." -ForegroundColor Yellow
            }
        } elseif ($left.TotalMinutes -le $threshold -and -not $script:CtxReminded["$key|w"]) {
            $script:CtxReminded["$key|w"] = $true
            Write-Host "  ⏰ ctx: $($a.roleName) in '$($entry.name)' expires in $(Format-CtxDuration $left) - 'ctx pim -Renew' to start a new activation." -ForegroundColor Yellow
        }
    }
}

function Install-CtxPrompt {
    if ($script:CtxPromptInstalled) { return }
    if (-not (Get-CtxConfig).promptBadge) { return }
    $cur = Get-Command prompt -CommandType Function -ErrorAction SilentlyContinue
    if ($cur -and $cur.ScriptBlock.ToString().Contains($script:CtxPromptMarker)) { return }
    $script:CtxOriginalPrompt = if ($cur) { $cur.ScriptBlock } else {
        { "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) " }
    }
    $wrapper = {
        # ctx-prompt-wrapper
        $ctxOk = $?
        $ctxCode = Get-Variable -Name LASTEXITCODE -Scope Global -ValueOnly -ErrorAction Ignore
        $ctxBadge = ''
        try {
            Invoke-CtxPromptReminder
            if ($script:GraphToken) { [void](Update-CtxGraphToken) }
            $ctxBadge = Get-CtxPromptBadge
        } catch { Write-Debug "ctx: prompt badge failed: $_" }
        if ($null -ne $ctxCode) { $global:LASTEXITCODE = $ctxCode }
        # Hand the original prompt the real success state of the last command ($? / exit code).
        if (-not $ctxOk) { Write-Error -Message 'ctx' -ErrorAction Ignore }
        $ctxText = (& $script:CtxOriginalPrompt) -join ''
        if ($ctxBadge) { "$ctxBadge $ctxText" } else { $ctxText }
    }
    Set-Item -Path function:global:prompt -Value $wrapper
    $script:CtxPromptInstalled = $true
}

function Uninstall-CtxPrompt {
    if (-not $script:CtxPromptInstalled) { return }
    $cur = Get-Command prompt -CommandType Function -ErrorAction SilentlyContinue
    if ($cur -and $cur.ScriptBlock.ToString().Contains($script:CtxPromptMarker) -and $script:CtxOriginalPrompt) {
        Set-Item -Path function:global:prompt -Value $script:CtxOriginalPrompt
    }
    $script:CtxPromptInstalled = $false
}

function Set-CtxProcessCliVariables {
    <# Points this process' az CLI to the environment's config dir (or back to the user's original when az is not managed). #>
    param($State, $Entry)
    if ($Entry -and (Test-CtxTool $Entry 'cli')) {
        $env:AZURE_CONFIG_DIR = Get-CtxCliDir $Entry.name
        if ($State.original.managedExtensionDir) { $env:AZURE_EXTENSION_DIR = Get-CtxSharedExtensionDir $State }
    } elseif ($State.original.saved) {
        $env:AZURE_CONFIG_DIR = if ($State.original.azureConfigDir) { $State.original.azureConfigDir } else { $null }
        if ($State.original.managedExtensionDir) {
            $env:AZURE_EXTENSION_DIR = if ($State.original.azureExtensionDir) { $State.original.azureExtensionDir } else { $null }
        }
    }
}

function Initialize-CtxSession {
    <# Runs on module import: adopt the global environment for this terminal. No network calls, no prompts. #>
    try {
        $state = Read-CtxState
        $entry = Find-CtxEnvironment $state $state.current
        $script:ProcessEnvName = if ($entry) { $entry.name } else { $null }
        $script:ProcessLocal = $false
        if ($entry) { Set-CtxProcessCliVariables $state $entry }
    } catch {
        Write-Warning "ctx: $($_.Exception.Message)"
    }
    try { Install-CtxPrompt } catch { Write-Warning "ctx: prompt badge disabled ($($_.Exception.Message))" }
}
