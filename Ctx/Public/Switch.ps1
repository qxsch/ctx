function Switch-CtxEnvironment {
    <#
    .SYNOPSIS
    Switches Azure CLI and Az PowerShell to an environment (tenant + login).
    .DESCRIPTION
    Without -Local the switch is user-wide: every new terminal starts in this environment (AZURE_CONFIG_DIR user
    variable + Az PowerShell default context). Each environment keeps its own CLI login and subscription and its own
    named Az context, so you land where you left off. Expired sessions are renewed with a device code.
    Afterwards ctx offers to activate the PIM role (Global Administrator) and to connect Microsoft Graph.
    .PARAMETER Name
    Environment name, a unique prefix of it, or '-' for the previous environment. Omit to get a picker.
    .PARAMETER Admin
    Activate the PIM role and connect Microsoft Graph right away.
    .PARAMETER NoAdmin
    Do not ask about PIM / Graph.
    .PARAMETER Local
    Switch this terminal only; other and new terminals are not affected.
    .PARAMETER NoVerify
    Skip the token checks (fastest; expired logins surface later).
    .PARAMETER Relogin
    Sign in again with device code for Azure CLI and Az PowerShell.
    .EXAMPLE
    ctx emea
    .EXAMPLE
    ctx -            # back to the previous environment
    .EXAMPLE
    ctx germany -Admin
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name,
        [switch]$Admin,
        [switch]$NoAdmin,
        [switch]$Local,
        [switch]$NoVerify,
        [switch]$Relogin,
        [switch]$Quiet
    )
    $savedQuiet = $script:Quiet
    if ($Quiet) { $script:Quiet = $true }
    try {
        $state = Read-CtxState
        if ($state.environments.Count -eq 0) {
            throw "No environments yet. Create one with: ctx add <name>   (example: ctx add switzerland)"
        }
        if (-not $Name) {
            $pick = Select-CtxEnvironmentInteractive $state
            if (-not $pick) { return }
            $Name = $pick.Name
            if ($pick.Admin) { $Admin = [switch]$true }
            if ($pick.Local) { $Local = [switch]$true }
        }
        if ($Name -eq '-') {
            $Name = if ($script:ProcessPreviousName -and (Find-CtxEnvironment $state $script:ProcessPreviousName)) { $script:ProcessPreviousName } else { $state.previous }
            if (-not $Name) { throw 'There is no previous environment yet.' }
        }
        $entry = Resolve-CtxEnvironment $state $Name
        $cfg = Get-CtxConfig
        $verify = -not $NoVerify -and ($cfg.verifyOnSwitch -or $Relogin)

        $outgoingName = if ($script:ProcessEnvName) { $script:ProcessEnvName } else { $state.current }
        $outgoing = Find-CtxEnvironment $state $outgoingName
        if ($outgoing -and $outgoing.name -ne $entry.name) {
            try { Save-CtxPosition $outgoing } catch { Write-Verbose "ctx: could not save position of '$($outgoing.name)': $_" }
        }

        if (Test-CtxProd $entry) { Write-CtxProdBanner $entry }
        $where = if ($Local) { ' (this terminal only)' } else { '' }
        Write-CtxMsg step "Switching to $($entry.name) · $(Get-CtxTenantLabel $entry) · $($entry.upn)$where"

        $useCli = Test-CtxTool $entry 'cli'
        $useAz = Test-CtxTool $entry 'az'
        $cliHandle = $null
        if ($useCli) {
            $dir = Get-CtxCliDir $entry.name
            if (-not (Test-Path -LiteralPath $dir)) { Initialize-CtxCliDir $dir }
            Set-CtxCliEnvironment -Entry $entry -Scope $(if ($Local) { 'Process' } else { 'User' })
            if ($verify -and -not $Relogin) { $cliHandle = Start-CtxCliTokenCheck $entry }
        } elseif ($Local) {
            Reset-CtxCliEnvironment -Process
        } else {
            Reset-CtxCliEnvironment -Process -User
        }

        $problems = [System.Collections.Generic.List[string]]::new()
        $azInfo = $null
        if ($useAz) {
            try {
                $azInfo = Set-CtxAzEnvironment -Entry $entry -Scope $(if ($Local) { 'Process' } else { 'CurrentUser' }) -NoVerify:(-not $verify) -Relogin:$Relogin
            } catch {
                $problems.Add('Az PowerShell')
                Write-CtxMsg error "Az PowerShell: $($_.Exception.Message)"
            }
        }
        $cliSub = $null
        if ($useCli) {
            try {
                $cliSub = Sync-CtxCliLogin -Entry $entry -Handle $cliHandle -Verify $verify -Relogin:$Relogin
            } catch {
                $problems.Add('Azure CLI')
                Write-CtxMsg error "Azure CLI: $($_.Exception.Message)"
            }
        }

        if ($script:GraphEnvName -and $script:GraphEnvName -ne $entry.name) {
            Disconnect-CtxGraphSession
            Write-CtxMsg dim "Microsoft Graph disconnected (it belonged to another environment)."
        }
        if ($outgoingName -and $outgoingName -ne $entry.name) { $script:ProcessPreviousName = $outgoingName }
        $script:ProcessEnvName = $entry.name
        $script:ProcessLocal = [bool]$Local
        $stamp = ConvertTo-CtxIsoDate ([datetime]::UtcNow)
        $targetName = $entry.name
        $isLocal = [bool]$Local
        $null = Update-CtxState {
            param($s)
            $e = Find-CtxEnvironment $s $targetName
            if ($e) { $e.lastUsed = $stamp }
            if (-not $isLocal) {
                if ($s.current -and $s.current -ne $targetName) { $s.previous = $s.current }
                $s.current = $targetName
            }
        }

        $parts = @()
        if ($useCli) {
            $parts += 'cli: ' + $(if ($cliSub -and $cliSub.id -ine $entry.tenantId) { $cliSub.name } elseif ($problems -contains 'Azure CLI') { 'not ready' } else { 'tenant level' })
        }
        if ($useAz) {
            $parts += 'az: ' + $(if ($azInfo -and $azInfo.SubscriptionName) { $azInfo.SubscriptionName } elseif ($azInfo) { 'tenant level' } else { 'not ready' })
        }
        $active = @(Get-CtxActiveActivations $entry)
        foreach ($a in $active) { $parts += "$(Get-CtxRoleShortName $a.RoleName) $(Format-CtxDuration $a.Remaining) left" }
        if ($problems.Count) {
            Write-CtxMsg warn "$($entry.name) switched with problems ($($problems -join ', ')) · $($parts -join ' · ')"
            Write-CtxMsg dim "Retry the sign-in: ctx $($entry.name) -Relogin   ·   details: ctx doctor"
        } else {
            Write-CtxMsg ok "$($entry.name) ready · $($parts -join ' · ')"
        }

        Invoke-CtxAdminOffer -Entry $entry -Admin:$Admin -NoAdmin:$NoAdmin
    } finally {
        $script:Quiet = $savedQuiet
    }
}

function Sync-CtxEnvironment {
    <#
    .SYNOPSIS
    Aligns this terminal with the global environment (for terminals opened before the last switch).
    .EXAMPLE
    ctx sync
    #>
    [CmdletBinding()]
    param([switch]$NoVerify)
    $state = Read-CtxState
    if (-not $state.current) { throw "No global environment yet. Run 'ctx <name>' first." }
    if ($script:ProcessEnvName -eq $state.current -and -not $script:ProcessLocal) {
        Write-CtxMsg ok "This terminal already follows the global environment '$($state.current)'."
        return
    }
    Switch-CtxEnvironment -Name $state.current -Local -NoAdmin -NoVerify:$NoVerify
    $script:ProcessLocal = $false
}

function Get-CtxTenantLabel {
    param($Entry)
    if ($Entry.tenantDomain) { return $Entry.tenantDomain }
    if ($Entry.tenantName) { return $Entry.tenantName }
    [string]$Entry.tenantId
}

function Save-CtxPosition {
    <# Remembers the subscriptions the user was on before leaving an environment. #>
    param([Parameter(Mandatory)]$Entry)
    $az = if (Test-CtxTool $Entry 'az') { Save-CtxAzPosition $Entry } else { $null }
    $cli = if (Test-CtxTool $Entry 'cli') { Get-CtxCliDefaultSubscription $Entry } else { $null }
    if ($cli -and $cli.id -ieq $Entry.tenantId) { $cli = $null }
    $changed = ($az -and $az.Id -ine $Entry.azSubscriptionId) -or ($cli -and $cli.id -ine $Entry.cliSubscriptionId)
    if (-not $changed) { return }
    $entryName = $Entry.name
    $null = Update-CtxState {
        param($s)
        $e = Find-CtxEnvironment $s $entryName
        if (-not $e) { return }
        if ($az) { $e.azSubscriptionId = $az.Id; $e.azSubscriptionName = $az.Name }
        if ($cli) { $e.cliSubscriptionId = $cli.id; $e.cliSubscriptionName = $cli.name }
    }
}

function Sync-CtxCliLogin {
    <# Completes the background token check and signs in with device code when needed. Returns the default subscription. #>
    param([Parameter(Mandatory)]$Entry, $Handle, [bool]$Verify = $true, [switch]$Relogin)
    $reason = $null
    if ($Relogin) {
        $reason = 'sign-in requested'
    } elseif ($Verify) {
        $r = Complete-CtxCliTokenCheck $Handle
        if ($r.Missing) { throw "az was not found on PATH. Install Azure CLI or drop it: ctx set $($Entry.name) -Tools az" }
        if (-not $r.Ok) { $reason = $r.Reason }
    } elseif (-not (Get-CtxCliProfile (Get-CtxCliDir $Entry.name))) {
        $reason = 'not signed in yet'
    }
    if ($reason) {
        if ($reason.Length -gt 110) { $reason = $reason.Substring(0, 107) + '...' }
        Write-CtxMsg warn "Azure CLI: $reason - signing in with device code"
        $id = Connect-CtxCli -Entry $Entry
        if (-not (Test-CtxIdentityMatch $Entry $id)) {
            throw "signed in as '$($id.Upn)', but '$($Entry.name)' is $($Entry.upn) in $($Entry.tenantId). Run 'ctx $($Entry.name) -Relogin' and pick the right account."
        }
        if ($Entry.cliSubscriptionId) {
            try { Set-CtxCliSubscription -Entry $Entry -SubscriptionId $Entry.cliSubscriptionId }
            catch { Write-CtxMsg warn "Azure CLI: last subscription $($Entry.cliSubscriptionName) is not available anymore." }
        }
    }
    Get-CtxCliDefaultSubscription $Entry
}

function Select-CtxEnvironmentInteractive {
    <# Picker. Returns @{ Name; Admin; Local } or $null. #>
    param([Parameter(Mandatory)]$State)
    $envs = @($State.environments | Sort-Object { $_.name })
    $here = if ($script:ProcessEnvName) { $script:ProcessEnvName } else { $State.current }
    $rows = [System.Collections.Generic.List[string]]::new()
    $colors = [System.Collections.Generic.List[string]]::new()
    $default = 0
    $nameWidth = [math]::Max(8, ($envs | ForEach-Object { $_.name.Length } | Measure-Object -Maximum).Maximum)
    for ($i = 0; $i -lt $envs.Count; $i++) {
        $e = $envs[$i]
        if ($e.name -eq $here) { $default = $i }
        $marks = @()
        if ($e.name -eq $here) { $marks += '← here' }
        elseif ($e.name -eq $State.current) { $marks += '← global' }
        foreach ($a in @(Get-CtxActiveActivations $e)) { $marks += "$(Get-CtxRoleShortName $a.RoleName) $(Format-CtxDuration $a.Remaining)" }
        $tags = if (@($e.tags).Count) { '#' + (@($e.tags) -join ' #') } else { '' }
        $rows.Add(('{0}  {1}  {2}  {3}  {4}' -f (Format-CtxCell $e.name $nameWidth), (Format-CtxCell (Get-CtxTenantLabel $e) 30), (Format-CtxCell $e.upn 34), (Format-CtxCell $tags 14), ($marks -join ' ')).TrimEnd())
        $colors.Add((Get-CtxEnvColor $e))
    }
    $choice = Show-CtxMenu -Rows $rows.ToArray() -Colors $colors.ToArray() -Default $default -Title 'Switch environment' `
        -Footer '↑/↓ move · Enter switch · a switch + admin · l this terminal only · 1-9 jump · Esc cancel' -ExtraKeys @('a', 'l')
    if (-not $choice) { return $null }
    @{ Name = $envs[$choice.Index].name; Admin = ($choice.Key -eq 'a'); Local = ($choice.Key -eq 'l') }
}

function Invoke-CtxAdminOffer {
    param([Parameter(Mandatory)]$Entry, [switch]$Admin, [switch]$NoAdmin)
    if ($NoAdmin) { return }
    $cfg = Get-CtxConfig
    $mode = if ($Entry.adminOnSwitch) { ([string]$Entry.adminOnSwitch).ToLowerInvariant() } elseif ($cfg.askAdminOnSwitch) { 'ask' } else { 'never' }
    try {
        if ($Admin -or $mode -eq 'always') {
            Invoke-CtxPim -Environment $Entry.name
            return
        }
        if ($mode -ne 'ask' -or -not (Test-CtxInteractive)) { return }
        $roleSpec = if ($Entry.pim -and $Entry.pim.role) { $Entry.pim.role } else { $cfg.pimDefaultRole }
        $role = Resolve-CtxRole $roleSpec
        $short = Get-CtxRoleShortName $role.Name
        $active = @(Get-CtxActiveActivations $Entry | Where-Object {
                (($role.Id -and $_.RoleId -ieq $role.Id) -or $_.RoleName -ieq $role.Name) -and ($null -eq $_.Remaining -or $_.Remaining.TotalMinutes -gt 5)
            })
        $graphProfile = if ($Entry.graphProfile) { $Entry.graphProfile } else { $cfg.defaultGraphProfile }
        if ($active.Count) {
            if ($script:GraphEnvName -eq $Entry.name) { return }
            if (Read-CtxYesNo "$short is active ($(Format-CtxDuration $active[0].Remaining) left). Connect Microsoft Graph ($graphProfile scopes)?") {
                Connect-CtxGraph -Environment $Entry.name
            }
        } elseif (Read-CtxYesNo "Activate $($role.Name) (PIM) and connect Microsoft Graph?") {
            Invoke-CtxPim -Environment $Entry.name
        }
    } catch {
        Write-CtxMsg error $_.Exception.Message
    }
}
