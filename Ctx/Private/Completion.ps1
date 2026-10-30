# Tab completion. Registered centrally with Register-ArgumentCompleter because ArgumentCompleter attribute
# script blocks do not run in module scope (they cannot reach private functions).

$script:CtxCompleterMap = @{
    'Switch-CtxEnvironment'  = @{ Name = 'Name' }
    'Get-CtxEnvironment'     = @{ Name = 'Name' }
    'Add-CtxEnvironment'     = @{ Color = 'Color' }
    'Remove-CtxEnvironment'  = @{ Name = 'Name' }
    'Rename-CtxEnvironment'  = @{ Name = 'Name' }
    'Set-CtxEnvironment'     = @{ Name = 'Name'; Color = 'Color'; GraphProfile = 'GraphProfile'; PimRole = 'Role' }
    'Export-CtxEnvironment'  = @{ Name = 'Name' }
    'Select-CtxSubscription' = @{ Subscription = 'Subscription'; Environment = 'Name' }
    'Invoke-CtxCommand'      = @{ Name = 'NameAll' }
    'Open-CtxPortal'         = @{ Portal = 'Portal'; Environment = 'Name' }
    'Invoke-CtxPim'          = @{ Role = 'Role'; Environment = 'Name'; GraphProfile = 'GraphProfile' }
    'Connect-CtxGraph'       = @{ Scopes = 'GraphProfile'; AddScopes = 'GraphScope'; Environment = 'Name' }
    'Set-CtxConfig'          = @{ Name = 'ConfigKey' }
}

function Invoke-CtxCompletion {
    param([string]$Command, [string]$Parameter, [string]$Word, $Fake)
    try {
        if ($Command -in 'ctx', 'Invoke-Ctx') {
            if ($Parameter -eq 'Target') { return Get-CtxTargetCompletion $Word }
            $Command = (Get-CtxDispatchRoute ([string]$Fake['Target'])).Function
        }
        $map = $script:CtxCompleterMap[$Command]
        if (-not $map) { return }
        switch ($map[$Parameter]) {
            'Name' { Get-CtxNameCompletion $Word }
            'NameAll' { Get-CtxNameCompletion $Word -IncludeAll }
            'Role' { Get-CtxRoleCompletion $Word }
            'GraphProfile' { Get-CtxGraphProfileCompletion $Word }
            'GraphScope' { Get-CtxGraphScopeCompletion $Word }
            'Portal' { Get-CtxPortalCompletion $Word }
            'Subscription' { Get-CtxSubscriptionCompletion $Word ([string]$Fake['Environment']) }
            'ConfigKey' { Get-CtxConfigKeyCompletion $Word }
            'Color' { Get-CtxColorCompletion $Word }
        }
    } catch { Write-Debug "ctx: completion failed: $_" }
}

function Register-CtxArgumentCompleters {
    $completer = { param($c, $p, $w, $ast, $fake) Invoke-CtxCompletion -Command $c -Parameter $p -Word $w -Fake $fake }
    $dispatcherParams = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$dispatcherParams.Add('Target')
    foreach ($fn in $script:CtxCompleterMap.Keys) {
        foreach ($param in $script:CtxCompleterMap[$fn].Keys) {
            Register-ArgumentCompleter -CommandName $fn -ParameterName $param -ScriptBlock $completer
            [void]$dispatcherParams.Add($param)
        }
    }
    foreach ($param in $dispatcherParams) {
        Register-ArgumentCompleter -CommandName 'Invoke-Ctx', 'ctx' -ParameterName $param -ScriptBlock $completer
    }
}

function New-CtxCompletion {
    param([string]$Text, [string]$Tip, [string]$ListText)
    if (-not $ListText) { $ListText = $Text }
    if (-not $Tip) { $Tip = $Text }
    $completion = if ($Text -match '[\s''"$`;,(){}|&<>@#]') { "'" + ($Text -replace "'", "''") + "'" } else { $Text }
    [System.Management.Automation.CompletionResult]::new($completion, $ListText, 'ParameterValue', $Tip)
}

function Get-CtxNameCompletion {
    param([string]$Word, [switch]$IncludeAll)
    $w = ([string]$Word).Trim("'", '"')
    try {
        $state = Get-CtxStateCached
        foreach ($e in @($state.environments | Sort-Object { $_.name })) {
            if ($e.name -like "$w*") {
                $tenant = if ($e.tenantDomain) { $e.tenantDomain } elseif ($e.tenantName) { $e.tenantName } else { $e.tenantId }
                New-CtxCompletion -Text $e.name -Tip "$tenant · $($e.upn)"
            }
        }
        if ($IncludeAll -and 'all' -like "$w*") { New-CtxCompletion -Text 'all' -Tip 'every environment' }
    } catch { Write-Debug "ctx: completion failed: $_" }
}

function Get-CtxTargetCompletion {
    param([string]$Word)
    $w = ([string]$Word).Trim("'", '"')
    Get-CtxNameCompletion $w
    $seen = @{}
    foreach ($verb in $script:CtxVerbs.Keys) {
        $fn = $script:CtxVerbs[$verb]
        if ($verb -like "$w*" -and -not $seen[$verb]) {
            $seen[$verb] = $true
            [System.Management.Automation.CompletionResult]::new($verb, $verb, 'Command', "ctx $verb → $fn")
        }
    }
    if ('-' -like "$w*") { [System.Management.Automation.CompletionResult]::new('-', '-', 'ParameterValue', 'switch back to the previous environment') }
}

function Get-CtxRoleCompletion {
    param([string]$Word)
    $w = ([string]$Word).Trim("'", '"')
    foreach ($alias in ($script:CtxRoleAliases.Keys | Sort-Object)) {
        if ($alias -like "$w*") { New-CtxCompletion -Text $alias -Tip $script:CtxRoleAliases[$alias] }
    }
    foreach ($role in $script:CtxRoles.Keys) {
        if ($role -like "$w*") { New-CtxCompletion -Text $role -Tip $script:CtxRoles[$role] }
    }
}

function Get-CtxGraphProfileCompletion {
    param([string]$Word)
    $w = ([string]$Word).Trim("'", '"')
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($n in $script:CtxBuiltInGraphProfiles) { $names.Add($n) }
    try { foreach ($n in @((Get-CtxConfig).graphScopeProfiles.Keys)) { if ($n) { $names.Add([string]$n) } } } catch { Write-Debug "ctx: completion failed: $_" }
    foreach ($n in $names) { if ($n -like "$w*") { New-CtxCompletion -Text $n -Tip "Graph scope profile '$n'" } }
}

function Get-CtxGraphScopeCompletion {
    param([string]$Word)
    $w = ([string]$Word).Trim("'", '"')
    $names = @($script:CtxAdminScopes) + @(Get-CtxDelegatedPermissionNames)
    foreach ($n in @($names | Sort-Object -Unique)) {
        if ($n -like "$w*") { New-CtxCompletion -Text $n -Tip "Additional delegated Graph permission '$n'" }
    }
}

function Get-CtxPortalCompletion {
    param([string]$Word)
    $w = ([string]$Word).Trim("'", '"')
    foreach ($p in $script:CtxPortals) { if ($p -like "$w*") { New-CtxCompletion -Text $p -Tip "open the $p portal" } }
}

function Get-CtxSubscriptionCompletion {
    param([string]$Word, [string]$EnvironmentName)
    $w = ([string]$Word).Trim("'", '"')
    try {
        $state = Get-CtxStateCached
        $name = if ($EnvironmentName) { $EnvironmentName } elseif ($script:ProcessEnvName) { $script:ProcessEnvName } else { $state.current }
        $entry = Find-CtxEnvironment $state $name
        if (-not $entry) { return }
        foreach ($s in @(Get-CtxCliSubscriptions $entry | Sort-Object name)) {
            if ($s.name -like "$w*" -or $s.id -like "$w*") { New-CtxCompletion -Text $s.name -Tip "$($s.id)" }
        }
        if (-not (Test-CtxTool $entry 'cli') -and $entry.azSubscriptionName -and $entry.azSubscriptionName -like "$w*") {
            New-CtxCompletion -Text $entry.azSubscriptionName -Tip "$($entry.azSubscriptionId)"
        }
    } catch { Write-Debug "ctx: completion failed: $_" }
}

function Get-CtxConfigKeyCompletion {
    param([string]$Word)
    $w = ([string]$Word).Trim("'", '"')
    foreach ($k in $script:CtxDefaultConfig.Keys) {
        if ($k -like "$w*") { New-CtxCompletion -Text $k -Tip "default: $($script:CtxDefaultConfig[$k] | ConvertTo-Json -Compress -Depth 3)" }
    }
}

function Get-CtxColorCompletion {
    param([string]$Word)
    $w = ([string]$Word).Trim("'", '"')
    foreach ($c in (@($script:CtxAnsiCodes.Keys) + 'Auto' | Sort-Object)) { if ($c -like "$w*") { New-CtxCompletion -Text $c -Tip "color $c" } }
}
