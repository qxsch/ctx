function Select-CtxSubscription {
    <#
    .SYNOPSIS
    Selects the subscription for Azure CLI and Az PowerShell of this terminal's environment (remembered per environment).
    .PARAMETER Subscription
    Name, ID, or a unique part of the name. Omit for a picker.
    .PARAMETER Refresh
    Reload the subscription list from Azure (new subscriptions).
    .PARAMETER Tool
    Both (default), Cli or Az.
    .EXAMPLE
    ctx sub
    .EXAMPLE
    ctx sub "Platform Prod"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Subscription,
        [string]$Environment,
        [switch]$Refresh,
        [ValidateSet('Both', 'Cli', 'Az')][string]$Tool = 'Both'
    )
    $state = Read-CtxState
    $entry = if ($Environment) { Resolve-CtxEnvironment $state $Environment } else { Get-CtxProcessEnvironment }
    $isHere = $entry.name -eq $script:ProcessEnvName
    $useCli = (Test-CtxTool $entry 'cli') -and $Tool -in 'Both', 'Cli'
    $useAz = (Test-CtxTool $entry 'az') -and $Tool -in 'Both', 'Az'
    if ($Refresh -and (Test-CtxTool $entry 'cli')) {
        Write-CtxMsg step 'Refreshing the subscription list'
        $r = Invoke-CtxAzCli -ConfigDir (Get-CtxCliDir $entry.name) -Arguments @('account', 'list', '--refresh', '-o', 'none', '--only-show-errors')
        if (-not $r.Success) { Write-CtxMsg warn "az account list --refresh failed: $($r.Error)" }
    }
    $subs = @(Get-CtxEnvironmentSubscriptions -Entry $entry)
    if (-not $subs.Count) { throw "No subscriptions visible for $($entry.upn) in '$($entry.name)' (tenant-level access only). New subscription? Use -Refresh." }
    $current = if (Test-CtxTool $entry 'cli') { Get-CtxCliDefaultSubscription $entry } else { $null }
    foreach ($s in $subs) { $s.isDefault = [bool]($current -and $s.id -ieq $current.id) }
    $chosen = Select-CtxSubscriptionChoice -Subscriptions $subs -Wanted $Subscription -Title "Subscription for '$($entry.name)'"
    if (-not $chosen) { return }

    if ($useCli) { Set-CtxCliSubscription -Entry $entry -SubscriptionId $chosen.id }
    if ($useAz -and $isHere) {
        $scope = if ($script:ProcessLocal -or $entry.name -ne $state.current) { 'Process' } else { 'CurrentUser' }
        Set-CtxAzSubscription -Entry $entry -SubscriptionId $chosen.id -Scope $scope
    }
    $targetName = $entry.name
    $null = Update-CtxState {
        param($s)
        $e = Find-CtxEnvironment $s $targetName
        if (-not $e) { return }
        if ($useCli) { $e.cliSubscriptionId = $chosen.id; $e.cliSubscriptionName = $chosen.name }
        if ($useAz) { $e.azSubscriptionId = $chosen.id; $e.azSubscriptionName = $chosen.name }
    }
    $tools = @(); if ($useCli) { $tools += 'cli' }; if ($useAz) { $tools += $(if ($isHere) { 'az' } else { 'az (on next switch)' }) }
    Write-CtxMsg ok "$($entry.name) · $($chosen.name) · $($tools -join ', ')"
}

function Invoke-CtxCommand {
    <#
    .SYNOPSIS
    Runs a script block in one or more environments (this terminal only) and switches back afterwards.
    .DESCRIPTION
    $_ inside the script block is the environment (Name, TenantId, Upn, ...). Wildcards and 'all' select several
    environments. Other terminals and the global environment are not touched.
    .EXAMPLE
    ctx exec all { az group list --query "length(@)" }
    .EXAMPLE
    ctx exec emea*,germany { "$($_.Name): $((Get-AzContext).Subscription.Name)" }
    .PARAMETER Force
    Run in production environments without the typed confirmation (needed in non-interactive sessions).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string[]]$Name,
        [Parameter(Mandatory, Position = 1)][scriptblock]$ScriptBlock,
        [switch]$NoVerify,
        [switch]$Force
    )
    $state = Read-CtxState
    $targets = [System.Collections.Generic.List[object]]::new()
    foreach ($pattern in $Name) {
        $found = if ($pattern -in 'all', '*') { @($state.environments) }
        elseif ([WildcardPattern]::ContainsWildcardCharacters($pattern)) { @($state.environments | Where-Object { $_.name -like $pattern }) }
        else { @(Resolve-CtxEnvironment $state $pattern) }
        if (-not $found.Count) { Write-CtxMsg warn "No environment matches '$pattern'." }
        foreach ($f in $found) { if (-not ($targets | Where-Object { $_.name -eq $f.name })) { $targets.Add($f) } }
    }
    if (-not $targets.Count) { return }
    $prod = @($targets | Where-Object { Test-CtxProd $_ } | ForEach-Object name)
    if ($prod.Count -and -not $Force) {
        $expected = if ($prod.Count -eq 1) { $prod[0] } else { 'prod' }
        if (-not (Confirm-CtxTyped -Expected $expected -Message "ctx exec runs in PRODUCTION: $($prod -join ', ').")) {
            Write-CtxMsg warn 'Cancelled.'
            return
        }
    }

    $saved = @{
        Name     = $script:ProcessEnvName
        Previous = $script:ProcessPreviousName
        Local    = $script:ProcessLocal
        Graph    = $script:GraphEnvName
        Config   = $env:AZURE_CONFIG_DIR
        Ext      = $env:AZURE_EXTENSION_DIR
        AzCtx    = if (Get-Module Az.Accounts) { (Get-AzContext -ErrorAction SilentlyContinue).Name } else { $null }
    }
    $multi = $targets.Count -gt 1
    $failed = 0
    try {
        foreach ($t in $targets) {
            if ($multi) {
                $c = Get-CtxEnvColor $t
                Write-Host ''
                Write-Host "── $($t.name) " -ForegroundColor $c -NoNewline
                Write-Host "· $(Get-CtxTenantLabel $t) · $($t.upn) ──" -ForegroundColor DarkGray
            }
            try {
                Switch-CtxEnvironment -Name $t.name -Local -NoAdmin -Quiet -NoVerify:$NoVerify
                $info = Get-CtxEnvironment -Name $t.name
                ForEach-Object -InputObject $info -Process $ScriptBlock
            } catch {
                $failed++
                Write-CtxMsg error "$($t.name): $($_.Exception.Message)"
            }
        }
    } finally {
        $script:ProcessEnvName = $saved.Name
        $script:ProcessPreviousName = $saved.Previous
        $script:ProcessLocal = $saved.Local
        $env:AZURE_CONFIG_DIR = $saved.Config
        $env:AZURE_EXTENSION_DIR = $saved.Ext
        if (Get-Module Az.Accounts) {
            $back = $saved.AzCtx
            if (-not $back -and $saved.Name) { $back = (Find-CtxEnvironment (Read-CtxState) $saved.Name).azContextName }
            if ($back -and (Get-CtxAzNamedContext $back)) {
                Select-AzContext -Name $back -Scope Process -WarningAction SilentlyContinue | Out-Null
            }
        }
        if ($saved.Graph -and -not $script:GraphEnvName) {
            Write-CtxMsg dim "Microsoft Graph was disconnected by the run - 'ctx graph' reconnects."
        }
    }
    if ($multi -and $failed) { Write-CtxMsg warn "$failed of $($targets.Count) environment(s) failed." }
}

function Open-CtxPortal {
    <#
    .SYNOPSIS
    Opens a portal for the environment in its own browser profile (right tenant, right account).
    .PARAMETER Portal
    azure (default), entra, pim, intune, admin, security, purview, myaccess, devicelogin, or any URL.
    .EXAMPLE
    ctx portal entra
    .EXAMPLE
    ctx open pim -Environment germany
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Portal = 'azure',
        [string]$Environment,
        [switch]$InPrivate
    )
    $entry = if ($Environment) { Resolve-CtxEnvironment (Read-CtxState) $Environment } else { Get-CtxProcessEnvironment }
    $url = Get-CtxPortalUrl -Entry $entry -Portal $Portal
    Open-CtxBrowser -Url $url -Entry $entry -InPrivate:$InPrivate
    $where = if ($InPrivate) { 'an InPrivate window' } else { "browser profile '$($entry.browserProfile)'" }
    Write-CtxMsg ok "Opened $Portal for '$($entry.name)' in $where"
}
