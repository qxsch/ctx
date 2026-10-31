function Get-CtxEnvironment {
    <#
    .SYNOPSIS
    Lists environments (tenant + login). * = this terminal, + = global environment when it differs.
    .EXAMPLE
    ctx list
    .EXAMPLE
    ctx ls -Tag prod
    #>
    [CmdletBinding()]
    [OutputType('Ctx.Environment')]
    param(
        [Parameter(Position = 0)]
        [SupportsWildcards()]
        [string]$Name = '*',
        [string]$Tag
    )
    $state = Read-CtxState
    $here = if ($script:ProcessEnvName) { $script:ProcessEnvName } else { $state.current }
    foreach ($e in @($state.environments | Sort-Object { $_.name })) {
        if ($e.name -notlike $Name) { continue }
        if ($Tag -and @($e.tags) -notcontains $Tag) { continue }
        $marker = if ($e.name -eq $here) { '*' } elseif ($e.name -eq $state.current) { '+' } else { '' }
        $cliSub = if (Test-CtxTool $e 'cli') { Get-CtxCliDefaultSubscription $e } else { $null }
        $lastUsed = ConvertTo-CtxDate $e.lastUsed
        [pscustomobject]@{
            PSTypeName      = 'Ctx.Environment'
            Current         = $marker
            Name            = $e.name
            Tenant          = Get-CtxTenantLabel $e
            TenantName      = $e.tenantName
            TenantId        = $e.tenantId
            Upn             = $e.upn
            ObjectId        = $e.userObjectId
            Tags            = [string[]]@($e.tags)
            Tools           = [string[]]@($e.tools)
            Admin           = (@(Get-CtxActiveActivations $e) | ForEach-Object { "$(Get-CtxRoleShortName $_.RoleName) $(Format-CtxDuration $_.Remaining)" }) -join ' '
            LastUsed        = if ($lastUsed) { $lastUsed.ToLocalTime() } else { $null }
            LastUsedAgo     = Format-CtxAgo $e.lastUsed
            CliSubscription = if ($cliSub -and $cliSub.id -ine $e.tenantId) { $cliSub.name } else { $null }
            AzSubscription  = $e.azSubscriptionName
            GraphProfile    = $e.graphProfile
            SaveGraphCredentials = [bool]$e.saveGraphCredentials
            Description     = $e.description
            Color           = Get-CtxEnvColor $e
            Prod            = Test-CtxProd $e
        }
    }
}

function Add-CtxEnvironment {
    <#
    .SYNOPSIS
    Creates an environment: a name for one tenant + one login. Signs in with device code.
    .DESCRIPTION
    Signs in to Azure CLI and Az PowerShell (device code, in the environment's own browser profile), reads tenant and
    user from the token and refuses duplicates (same tenant + same login = same environment).
    .PARAMETER Tenant
    Tenant domain or ID. Leave empty to use the home tenant of the account you sign in with.
    .PARAMETER Tools
    Which tools ctx manages for this environment: cli (Azure CLI), az (Az PowerShell). Default: both.
    .PARAMETER Subscription
    Subscription (name or ID) to start in. Default: pick from the list.
    .EXAMPLE
    ctx add switzerland contoso-ch.onmicrosoft.com -Tags prod
    .EXAMPLE
    ctx add emea3
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Position = 1)][string]$Tenant,
        [ValidateSet('cli', 'az')][string[]]$Tools = @('cli', 'az'),
        [string[]]$Tags,
        [string]$Color,
        [string]$Description,
        [string]$Subscription,
        [switch]$NoSwitch
    )
    $n = Assert-CtxName $Name
    $state = Read-CtxState
    if (Find-CtxEnvironment $state $n) { throw "Environment '$n' already exists. Switch with 'ctx $n' or choose another name." }
    $Color = Assert-CtxColor $Color
    $useCli = $Tools -contains 'cli'
    $useAz = $Tools -contains 'az'
    if ($useCli -and -not (Get-CtxAzCliPath)) { throw 'Azure CLI (az) not found. Install it or use -Tools az.' }
    if ($useAz -and -not (Test-CtxAzAvailable)) { throw 'Az.Accounts not found. Install it (elevated: Install-PSResource Az.Accounts -Scope AllUsers) or use -Tools cli.' }
    if (-not $PSBoundParameters.ContainsKey('Tenant') -and (Test-CtxInteractive)) {
        $Tenant = Read-CtxText 'Tenant domain or ID (Enter = home tenant of the account you sign in with)'
    }
    if ($Tenant) {
        $Tenant = $Tenant.Trim()
        if (-not (Test-CtxTenantSpec $Tenant)) {
            throw "Invalid tenant '$(ConvertTo-CtxSafeText $Tenant -MaxLength 60)'. Use a tenant ID (GUID) or a domain such as contoso.onmicrosoft.com."
        }
    }

    $entry = [ordered]@{
        name                 = $n
        tenantId             = $null
        tenantName           = $null
        tenantDomain         = $null
        userObjectId         = $null
        upn                  = $null
        tools                = @($Tools | Select-Object -Unique)
        tags                 = @($Tags | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Select-Object -Unique)
        color                = $Color
        description          = $Description
        browserProfile       = "ctx-$n"
        azContextName        = "ctx:$n"
        azSubscriptionId     = $null
        azSubscriptionName   = $null
        cliSubscriptionId    = $null
        cliSubscriptionName  = $null
        graphProfile         = $null
        graphClientId        = $null
        adminOnSwitch        = $null
        saveGraphCredentials = $false
        pim                  = [ordered]@{}
        activations          = @()
        activationsCheckedAt = $null
        created              = ConvertTo-CtxIsoDate ([datetime]::UtcNow)
        lastUsed             = $null
    }
    Write-CtxMsg step "Adding '$n' - sign in with the account that belongs to this environment"
    Write-CtxMsg dim "Device-code pages open in the browser profile 'ctx-$n', so sign-ins of different environments never mix."

    $pending = Join-Path (Join-Path (Get-CtxHome) 'cli') ".pending-$([guid]::NewGuid().ToString('n').Substring(0, 8))"
    $azTouched = $false
    try {
        $id = if ($useCli) {
            Connect-CtxCli -Entry $entry -Dir $pending -Tenant $Tenant
        } else {
            $azTouched = $true
            Connect-CtxAz -Entry $entry -Scope Process -Tenant $Tenant
        }
        if (-not $id -or -not $id.TenantId -or -not $id.ObjectId) { throw 'Could not read tenant and user from the sign-in token.' }

        $dup = Find-CtxEnvironmentByIdentity (Read-CtxState) $id.TenantId $id.ObjectId
        if ($dup) {
            Remove-CtxPendingLogin -Dir $pending -AzContextName $(if ($azTouched) { $entry.azContextName } else { $null })
            Write-CtxMsg warn "$($id.Upn) in tenant $($id.TenantId) already is environment '$($dup.name)' (same tenant + same login = same environment)."
            if (Test-CtxInteractive) {
                $choice = Show-CtxMenu -Rows @("Switch to '$($dup.name)'", "Rename '$($dup.name)' to '$n' and switch", 'Cancel') -Title 'What now?'
                if ($choice -and $choice.Index -eq 0) { Switch-CtxEnvironment -Name $dup.name }
                elseif ($choice -and $choice.Index -eq 1) { Rename-CtxEnvironment -Name $dup.name -NewName $n; Switch-CtxEnvironment -Name $n }
            }
            return
        }
        $entry.tenantId = $id.TenantId
        $entry.userObjectId = $id.ObjectId
        $entry.upn = $id.Upn
        Write-CtxMsg ok "Signed in as $($id.Upn) · tenant $($id.TenantId)"

        if ($useAz -and -not $azTouched) {
            for ($attempt = 1; ; $attempt++) {
                $azTouched = $true
                $azId = Connect-CtxAz -Entry $entry -Scope Process
                if (Test-CtxIdentityMatch $entry $azId) { break }
                Write-CtxMsg warn "Az PowerShell signed in as '$($azId.Upn)', but this environment is $($entry.upn). Use the same account."
                if ($attempt -ge 3 -or -not (Read-CtxYesNo 'Try again?' $true)) { throw 'Az PowerShell sign-in does not match the environment login.' }
            }
            Write-CtxMsg ok 'Az PowerShell signed in'
        }

        $info = Get-CtxTenantInfo -Entry $entry -CliDir $(if ($useCli) { $pending } else { $null })
        $entry.tenantName = $info.Name
        $entry.tenantDomain = $info.Domain

        $subs = @(Get-CtxEnvironmentSubscriptions -Entry $entry -CliDir $(if ($useCli) { $pending } else { $null }))
        $chosen = Select-CtxSubscriptionChoice -Subscriptions $subs -Wanted $Subscription -AllowNone -Title "Start subscription for '$n'"
        if ($chosen) {
            if ($useCli) { Set-CtxCliSubscription -Entry $entry -SubscriptionId $chosen.id -Dir $pending }
            $entry.cliSubscriptionId = $chosen.id; $entry.cliSubscriptionName = $chosen.name
            $entry.azSubscriptionId = $chosen.id; $entry.azSubscriptionName = $chosen.name
        }

        if ($useCli) {
            $final = Get-CtxCliDir $n
            if (Test-Path -LiteralPath $final) { Remove-Item -LiteralPath $final -Recurse -Force }
            Move-Item -LiteralPath $pending -Destination $final
        }
        $newEntry = $entry
        $null = Update-CtxState {
            param($s)
            if (Find-CtxEnvironment $s $newEntry.name) { throw "Environment '$($newEntry.name)' was created in another terminal meanwhile." }
            $s.environments.Add($newEntry)
        }
    } catch {
        Remove-CtxPendingLogin -Dir $pending -AzContextName $(if ($azTouched) { $entry.azContextName } else { $null })
        throw
    }
    Write-CtxMsg ok "Environment '$n' created · $(Get-CtxTenantLabel $entry) · $($entry.upn)$(if ($entry.cliSubscriptionName) { " · $($entry.cliSubscriptionName)" })"
    if (-not $NoSwitch) {
        Switch-CtxEnvironment -Name $n -NoVerify
    }
}

function Remove-CtxEnvironment {
    <#
    .SYNOPSIS
    Removes an environment: its CLI login folder, its Az context and its entry. Requires the exact name.
    .PARAMETER SignOut
    Also sign the account out of Az PowerShell (only when no other environment uses the same login).
    .PARAMETER RemoveBrowserProfile
    Also delete the environment's browser profile (Edge must be closed).
    .EXAMPLE
    ctx rm emea3
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,
        [switch]$SignOut,
        [switch]$RemoveBrowserProfile,
        [switch]$Force
    )
    $state = Read-CtxState
    $entry = Find-CtxEnvironment $state $Name
    if (-not $entry) { throw "Unknown environment '$Name' (removal needs the exact name)." }
    $label = "$($entry.name) · $(Get-CtxTenantLabel $entry) · $($entry.upn)"
    if (-not $PSCmdlet.ShouldProcess($label, 'Remove ctx environment')) { return }
    if (-not $Force -and -not $WhatIfPreference) {
        if (Test-CtxProd $entry) {
            if (-not (Confirm-CtxTyped -Expected $entry.name -Message "'$($entry.name)' is a PRODUCTION environment.")) { Write-CtxMsg warn 'Cancelled.'; return }
        } elseif (-not (Read-CtxYesNo "Remove environment $($label)?")) {
            Write-CtxMsg warn 'Cancelled.'
            return
        }
    }
    $removedName = $entry.name

    if ($script:GraphEnvName -eq $removedName) { Disconnect-CtxGraphSession }

    if ((Test-CtxTool $entry 'az') -and (Test-CtxAzAvailable)) {
        try {
            Import-CtxAzModule
            Sync-CtxAzProfileFromDisk
            $ctxObj = Get-CtxAzNamedContext $entry.azContextName
            if ($ctxObj) {
                $shared = @($state.environments | Where-Object { $_.name -ne $removedName -and $_.upn -and $_.upn -ieq $entry.upn })
                if ($SignOut -and -not $shared.Count) {
                    Disconnect-AzAccount -ContextName $entry.azContextName -Scope CurrentUser -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
                } else {
                    Remove-AzContext -Name $entry.azContextName -Force -Scope CurrentUser -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
                }
                Update-CtxAzProfileStamp
                Write-CtxMsg ok "Az context '$($entry.azContextName)' removed"
            }
        } catch {
            Write-CtxMsg warn "Az context could not be removed: $($_.Exception.Message)"
        }
    }

    $wasGlobal = $state.current -eq $removedName
    $null = Update-CtxState {
        param($s)
        $e = Find-CtxEnvironment $s $removedName
        if ($e) { [void]$s.environments.Remove($e) }
        if ($s.current -eq $removedName) { $s.current = $null }
        if ($s.previous -eq $removedName) { $s.previous = $null }
    }
    if ($wasGlobal) { Reset-CtxCliEnvironment -User }
    Remove-CtxGraphCredentials -Name $removedName
    if ($script:ProcessEnvName -eq $removedName) {
        Reset-CtxCliEnvironment -Process
        $script:ProcessEnvName = $null
        $script:ProcessLocal = $false
    }
    if ($script:ProcessPreviousName -eq $removedName) { $script:ProcessPreviousName = $null }

    $dir = Get-CtxCliDir $removedName
    if (Test-Path -LiteralPath $dir) {
        try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop; Write-CtxMsg ok 'Azure CLI login removed' }
        catch { Write-CtxMsg warn "Could not delete '$dir' (az running in another terminal?). Delete it later." }
    }

    if ($RemoveBrowserProfile) {
        $profileDir = try { Get-CtxBrowserProfileDir $entry } catch { Write-CtxMsg warn $_.Exception.Message; $null }
        if ($profileDir -and (Get-Process -Name msedge, chrome -ErrorAction SilentlyContinue)) {
            Write-CtxMsg warn "Browser is running - close it and delete '$profileDir' manually."
        } elseif ($profileDir -and (Test-Path -LiteralPath $profileDir)) {
            try { Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction Stop; Write-CtxMsg ok "Browser profile '$($entry.browserProfile)' removed" }
            catch { Write-CtxMsg warn "Could not delete browser profile '$profileDir': $($_.Exception.Message)" }
        }
    }
    Write-CtxMsg ok "Environment '$removedName' removed."
    if ($wasGlobal) { Write-CtxMsg dim "It was the global environment - pick another one with 'ctx'." }
}

function Rename-CtxEnvironment {
    <#
    .SYNOPSIS
    Renames an environment (CLI folder, Az context and state). The browser profile keeps its folder.
    .EXAMPLE
    ctx mv emea3 emea-lab
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,
        [Parameter(Mandatory, Position = 1)][string]$NewName
    )
    $state = Read-CtxState
    $entry = Find-CtxEnvironment $state $Name
    if (-not $entry) { throw "Unknown environment '$Name' (rename needs the exact name)." }
    $new = Assert-CtxName $NewName
    $oldName = $entry.name
    if ($new -eq $oldName) { return }
    if (Find-CtxEnvironment $state $new) { throw "Environment '$new' already exists." }
    if (-not $PSCmdlet.ShouldProcess($oldName, "Rename to '$new'")) { return }

    $oldDir = Get-CtxCliDir $oldName
    $newDir = Get-CtxCliDir $new
    if (Test-Path -LiteralPath $oldDir) {
        try { Move-Item -LiteralPath $oldDir -Destination $newDir -ErrorAction Stop }
        catch { throw "Could not move '$oldDir' (az running in another terminal?): $($_.Exception.Message)" }
    }
    $newContext = "ctx:$new"
    if ((Test-CtxTool $entry 'az') -and (Test-CtxAzAvailable)) {
        try {
            Import-CtxAzModule
            Sync-CtxAzProfileFromDisk
            if (Get-CtxAzNamedContext $entry.azContextName) {
                Rename-AzContext -SourceName $entry.azContextName -TargetName $newContext -Force -Scope CurrentUser -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
                Update-CtxAzProfileStamp
            }
        } catch {
            Write-CtxMsg warn "Az context could not be renamed ($($_.Exception.Message)); it is recreated on the next switch."
        }
    }
    $state = Update-CtxState {
        param($s)
        $e = Find-CtxEnvironment $s $oldName
        $e.name = $new
        $e.azContextName = $newContext
        if ($s.current -eq $oldName) { $s.current = $new }
        if ($s.previous -eq $oldName) { $s.previous = $new }
    }
    if ($state.current -eq $new -and (Test-CtxTool $entry 'cli')) {
        Set-CtxUserEnv 'AZURE_CONFIG_DIR' $newDir
    }
    Move-CtxGraphCredentials -OldName $oldName -NewName $new
    if ($script:ProcessEnvName -eq $oldName) {
        $script:ProcessEnvName = $new
        Set-CtxProcessCliVariables $state (Find-CtxEnvironment $state $new)
    }
    if ($script:ProcessPreviousName -eq $oldName) { $script:ProcessPreviousName = $new }
    if ($script:GraphEnvName -eq $oldName) {
        $script:GraphEnvName = $new
        if ($script:GraphToken) { $script:GraphToken.Entry = Find-CtxEnvironment $state $new }
    }
    Write-CtxMsg ok "Renamed '$oldName' → '$new' (browser profile '$($entry.browserProfile)' is kept)."
}

function Set-CtxEnvironment {
    <#
    .SYNOPSIS
    Changes settings of an environment (default: the one of this terminal).
    .PARAMETER AdminOnSwitch
    Ask = offer PIM + Graph after switching, Always = do it automatically, Never = don't ask, Default = use config.
    .PARAMETER GraphProfile
    Graph scope profile: Admin, ReadOnly, Pim, a custom profile from config, or a scope list. 'Default' clears it.
    .PARAMETER SaveGraphCredentials
    On = keep this environment's Microsoft Graph refresh token (encrypted for your Windows user, on this device) and
    restore it on the next Graph connect (ctx <name> -Admin, ctx pim, ctx graph) instead of asking for a device code.
    Restoring stops graphMaxSessionHours (default 8) after the original sign-in. Off (the default) deletes the saved credentials.
    .EXAMPLE
    ctx set germany -AddTag prod -Color Red
    .EXAMPLE
    ctx set emea -PimHours 2 -AdminOnSwitch Always
    .EXAMPLE
    ctx set emea -SaveGraphCredentials On
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'SaveGraphCredentials',
        Justification = 'An On/Off setting, not a secret.')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)]
        [string]$Name,
        [string[]]$Tags,
        [string[]]$AddTag,
        [string[]]$RemoveTag,
        [string]$Color,
        [string]$Description,
        [ValidateSet('cli', 'az')][string[]]$Tools,
        [string]$GraphProfile,
        [string]$GraphClientId,
        [string]$PimRole,
        [ValidateRange(0.5, 24)][double]$PimHours,
        [string]$PimReason,
        [string]$TicketSystem,
        [ValidateSet('Ask', 'Always', 'Never', 'Default')][string]$AdminOnSwitch,
        [ValidateSet('On', 'Off')][string]$SaveGraphCredentials
    )
    $state = Read-CtxState
    $entry = if ($Name) { Resolve-CtxEnvironment $state $Name } else { Get-CtxProcessEnvironment }
    $targetName = $entry.name
    $bound = $PSBoundParameters
    if ($bound.ContainsKey('Color')) { $Color = if ($Color -ieq 'Auto') { 'Auto' } else { Assert-CtxColor $Color } }
    if ($bound.ContainsKey('GraphProfile') -and $GraphProfile -ine 'Default') { $null = Get-CtxGraphScopes $GraphProfile }
    if ($GraphClientId -and -not (Test-CtxGuid $GraphClientId)) { throw "GraphClientId must be an application (client) ID GUID." }
    if (-not $PSCmdlet.ShouldProcess($targetName, 'Change ctx environment settings')) { return }
    $normTags = { param($list) @($list | Where-Object { $_ } | ForEach-Object { (ConvertTo-CtxSafeText $_).Trim().ToLowerInvariant() } | Where-Object { $_ }) }
    $null = Update-CtxState {
        param($s)
        $e = Find-CtxEnvironment $s $targetName
        if ($bound.ContainsKey('Tags')) { $e.tags = @(& $normTags $Tags | Select-Object -Unique) }
        if ($bound.ContainsKey('AddTag')) { $e.tags = @(@($e.tags) + (& $normTags $AddTag) | Select-Object -Unique) }
        if ($bound.ContainsKey('RemoveTag')) { $rm = & $normTags $RemoveTag; $e.tags = @($e.tags | Where-Object { $rm -notcontains $_ }) }
        if ($bound.ContainsKey('Color')) { $e.color = if ($Color -eq 'Auto') { $null } else { $Color } }
        if ($bound.ContainsKey('Description')) { $e.description = ConvertTo-CtxSafeText $Description }
        if ($bound.ContainsKey('Tools')) { $e.tools = @($Tools | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique) }
        if ($bound.ContainsKey('GraphProfile')) { $e.graphProfile = if ($GraphProfile -ieq 'Default') { $null } else { ConvertTo-CtxSafeText $GraphProfile } }
        if ($bound.ContainsKey('GraphClientId')) { $e.graphClientId = if ($GraphClientId) { $GraphClientId.ToLowerInvariant() } else { $null } }
        if (-not $e.pim) { $e.pim = [ordered]@{} }
        if ($bound.ContainsKey('PimRole')) { $e.pim.role = if ($PimRole) { (Resolve-CtxRole $PimRole).Name } else { $null } }
        if ($bound.ContainsKey('PimHours')) { $e.pim.hours = $PimHours }
        if ($bound.ContainsKey('PimReason')) { $e.pim.reason = ConvertTo-CtxSafeText $PimReason }
        if ($bound.ContainsKey('TicketSystem')) { $e.pim.ticketSystem = ConvertTo-CtxSafeText $TicketSystem }
        if ($bound.ContainsKey('AdminOnSwitch')) { $e.adminOnSwitch = if ($AdminOnSwitch -eq 'Default') { $null } else { $AdminOnSwitch.ToLowerInvariant() } }
        if ($bound.ContainsKey('SaveGraphCredentials')) { $e.saveGraphCredentials = ($SaveGraphCredentials -eq 'On') }
    }
    if ($bound.ContainsKey('SaveGraphCredentials')) {
        if ($SaveGraphCredentials -eq 'Off') {
            Remove-CtxGraphCredentials -Name $targetName
            Write-CtxMsg ok "Graph credentials of '$targetName' are not saved anymore (the saved copy is deleted)."
        } else {
            $t = $script:GraphToken
            if ($t -and $script:GraphEnvName -eq $targetName -and $t.Source -eq 'DeviceCode' -and $t.RefreshToken) {
                Save-CtxGraphCredentials -Entry $t.Entry -ClientId $t.ClientId -RefreshToken $t.RefreshToken -SessionStartedAt $t.SessionStartedAt
                Write-CtxMsg ok "Graph credentials of '$targetName' are saved now."
            } else {
                Write-CtxMsg ok "Graph credentials of '$targetName' are saved at the next Graph sign-in."
            }
            Write-CtxMsg dim "ctx $targetName -Admin (also ctx pim, ctx graph) restores them without a device code, until graphMaxSessionHours after that sign-in."
        }
    }
    if ($bound.ContainsKey('Tools') -and $targetName -eq $script:ProcessEnvName) {
        Write-CtxMsg dim "Tools changed - run 'ctx $targetName' to apply them."
    }
    Get-CtxEnvironment -Name $targetName
}

function Export-CtxEnvironment {
    <#
    .SYNOPSIS
    Exports environment definitions (no tokens) as JSON - to share with a teammate or move to another machine.
    .EXAMPLE
    ctx export ~\ctx-environments.json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Path,
        [SupportsWildcards()]
        [string]$Name = '*'
    )
    $state = Read-CtxState
    $keys = $script:CtxPortableKeys
    $list = foreach ($e in @($state.environments | Where-Object { $_.name -like $Name } | Sort-Object { $_.name })) {
        $o = [ordered]@{}
        foreach ($k in $keys) { $o[$k] = $e[$k] }
        $o
    }
    $doc = [ordered]@{ ctxExport = 1; exportedAt = ConvertTo-CtxIsoDate ([datetime]::UtcNow); environments = @($list) }
    $json = $doc | ConvertTo-Json -Depth 10
    if ($Path) {
        $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        [IO.File]::WriteAllText($full, $json, [Text.UTF8Encoding]::new($false))
        Write-CtxMsg ok "Exported $(@($list).Count) environment(s) to $full (no tokens included)."
    } else {
        $json
    }
}

function Import-CtxEnvironment {
    <#
    .SYNOPSIS
    Imports environment definitions exported with 'ctx export'. Logins happen on the first switch.
    .DESCRIPTION
    Only the portable fields of an export are read. Entries whose IDs are not GUIDs or whose tenant domain is not a
    domain name are skipped. A custom Graph client (graphClientId) is only kept after confirmation or with
    -AllowGraphClientId, because Graph sign-ins for that environment would grant consent to that application.
    .PARAMETER Force
    Overwrite environments with the same name.
    .PARAMETER AllowGraphClientId
    Keep custom Graph client IDs from the file without asking.
    .EXAMPLE
    ctx import ~\ctx-environments.json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [SupportsWildcards()][string]$Name = '*',
        [switch]$Force,
        [switch]$AllowGraphClientId
    )
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path -LiteralPath $full)) { throw "File not found: $full" }
    $doc = [IO.File]::ReadAllText($full) | ConvertFrom-Json -AsHashtable -Depth 16
    if ($doc -isnot [System.Collections.IDictionary] -or -not $doc.ContainsKey('environments')) { throw "'$full' is not a ctx export." }
    $report = [System.Collections.Generic.List[object]]::new()
    $note = { param([string]$Kind, [string]$Text) $report.Add([pscustomobject]@{ Kind = $Kind; Text = $Text }) }

    # Validate outside the lock: confirmations must not hold the state mutex.
    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($doc.environments)) {
        if ($item -isnot [System.Collections.IDictionary]) { & $note warn 'skip: an entry is not a JSON object'; continue }
        $rawName = ConvertTo-CtxSafeText ([string]$item['name']) -MaxLength 40
        if ($rawName -notlike $Name) { continue }
        try { $n = Assert-CtxName $rawName } catch { & $note warn "skip '$rawName': $($_.Exception.Message)"; continue }
        $new = [ordered]@{}
        foreach ($k in $script:CtxPortableKeys) { if ($item.Contains($k)) { $new[$k] = $item[$k] } }
        $new.name = $n
        $problems = @(Get-CtxEntryProblem $new)
        if ($problems.Count) { & $note warn "skip '$n': $($problems -join '; ')"; continue }
        foreach ($k in 'tenantId', 'userObjectId', 'graphClientId', 'azSubscriptionId', 'cliSubscriptionId') {
            if ($new[$k]) { $new[$k] = ([string]$new[$k]).ToLowerInvariant() }
        }
        if ($new.Contains('color')) { $new.color = try { Assert-CtxColor ([string]$new.color) } catch { $null } }
        if ($new.Contains('adminOnSwitch') -and [string]$new.adminOnSwitch -notin 'ask', 'always', 'never') { $new.adminOnSwitch = $null }
        if ($new.Contains('pim')) {
            $pim = [ordered]@{}
            if ($new.pim -is [System.Collections.IDictionary]) {
                foreach ($k in 'role', 'reason', 'ticketSystem') { if ($new.pim[$k] -is [string]) { $pim[$k] = $new.pim[$k] } }
                $h = 0.0
                if ([double]::TryParse([string]$new.pim['hours'], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$h) -and $h -ge 0.5 -and $h -le 24) { $pim.hours = $h }
            }
            $new.pim = $pim
        }
        if ($new.graphClientId -and $new.graphClientId -ne $script:CtxGraphClientId -and -not $AllowGraphClientId) {
            $keep = (Test-CtxInteractive) -and (Read-CtxYesNo "'$n' uses its own Graph application ($($new.graphClientId)); its Graph sign-ins grant consent to that app. Keep it?")
            if (-not $keep) {
                & $note warn "'$n': dropped graphClientId $($new.graphClientId) - keep it with -AllowGraphClientId or 'ctx set $n -GraphClientId <id>'"
                $new.graphClientId = $null
            }
        }
        $candidates.Add($new)
    }

    $null = Update-CtxState {
        param($s)
        foreach ($new in $candidates) {
            $n = $new.name
            $sameId = Find-CtxEnvironmentByIdentity $s $new.tenantId $new.userObjectId
            if ($sameId -and $sameId.name -ne $n) { & $note warn "skip '$n': same tenant + login already is '$($sameId.name)'"; continue }
            $existing = Find-CtxEnvironment $s $n
            if ($existing -and -not $Force) { & $note warn "skip '$n': exists (use -Force to overwrite)"; continue }
            $new.browserProfile = "ctx-$n"
            $new.azContextName = "ctx:$n"
            $new.activations = @()
            $new.created = if ($existing -and $existing.created) { $existing.created } else { ConvertTo-CtxIsoDate ([datetime]::UtcNow) }
            $new.lastUsed = if ($existing) { $existing.lastUsed } else { $null }
            # Device-local opt-in: an export never switches credential saving on, and an overwrite keeps it only for the same login.
            $new.saveGraphCredentials = [bool]($existing -and $existing.saveGraphCredentials -eq $true -and
                $existing.tenantId -ieq $new.tenantId -and $existing.userObjectId -ieq $new.userObjectId)
            $entry = Repair-CtxEnvironmentEntry $new
            if ($existing) { $idx = $s.environments.IndexOf($existing); $s.environments[$idx] = $entry; & $note ok "updated '$n'" }
            else { $s.environments.Add($entry); & $note ok "added '$n'" }
        }
    }
    foreach ($line in $report) { Write-CtxMsg $line.Kind $line.Text }
    Write-CtxMsg dim "Imported environments sign in (device code) on their first switch."
}

function Assert-CtxColor {
    param([string]$Color)
    if (-not $Color) { return $null }
    $match = $script:CtxAnsiCodes.Keys | Where-Object { $_ -ieq $Color } | Select-Object -First 1
    if (-not $match) { throw "Unknown color '$Color'. Use one of: $(($script:CtxAnsiCodes.Keys | Sort-Object) -join ', ')." }
    $match
}

function Remove-CtxPendingLogin {
    param([string]$Dir, [string]$AzContextName)
    if ($Dir -and (Test-Path -LiteralPath $Dir)) { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($AzContextName -and (Get-Module Az.Accounts)) {
        try {
            if (Get-CtxAzNamedContext $AzContextName) {
                Remove-AzContext -Name $AzContextName -Force -Scope CurrentUser -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
                Update-CtxAzProfileStamp
            }
        } catch { Write-Debug "ctx: could not remove pending Az context '$AzContextName': $_" }
    }
}

function Get-CtxTenantInfo {
    <# Tenant display name and default domain from the CLI profile, Az, or Graph via az rest. #>
    param([Parameter(Mandatory)]$Entry, [string]$CliDir)
    $name = $null; $domain = $null
    if ($CliDir) {
        $p = Get-CtxCliProfile $CliDir
        $hit = @($p.subscriptions | Where-Object { $_.tenantId -ieq $Entry.tenantId -and ($_.tenantDisplayName -or $_.tenantDefaultDomain) }) | Select-Object -First 1
        if ($hit) { $name = $hit.tenantDisplayName; $domain = $hit.tenantDefaultDomain }
    }
    if ((-not $name -or -not $domain) -and (Test-CtxTool $Entry 'az') -and (Get-Module Az.Accounts)) {
        try {
            $t = Get-AzTenant -TenantId $Entry.tenantId -ErrorAction Stop -WarningAction SilentlyContinue | Select-Object -First 1
            if (-not $name) { $name = $t.Name }
            if (-not $domain) { $domain = if ($t.DefaultDomain) { $t.DefaultDomain } else { @($t.Domains)[0] } }
        } catch { Write-Debug "ctx: Get-AzTenant failed: $_" }
    }
    if ((-not $name -or -not $domain) -and $CliDir) {
        $r = Invoke-CtxAzCli -ConfigDir $CliDir -Arguments @('rest', '--method', 'GET', '--url', 'https://graph.microsoft.com/v1.0/organization?$select=displayName,verifiedDomains', '-o', 'json', '--only-show-errors') -Json
        if ($r.Success -and $r.Value.value) {
            $org = @($r.Value.value)[0]
            if (-not $name) { $name = $org.displayName }
            if (-not $domain) { $domain = (@($org.verifiedDomains) | Where-Object { $_.isDefault } | Select-Object -First 1).name }
        }
    }
    if ($domain -and -not (Test-CtxDomainName ([string]$domain))) { $domain = $null }
    [pscustomobject]@{ Name = $(if ($name) { ConvertTo-CtxSafeText $name } else { $Entry.tenantId }); Domain = $domain }
}

function Get-CtxEnvironmentSubscriptions {
    <# Subscriptions of the environment: CLI profile (offline) first, Az as fallback. Objects with id/name/isDefault. #>
    param([Parameter(Mandatory)]$Entry, [string]$CliDir)
    if (Test-CtxTool $Entry 'cli') {
        return @(Get-CtxCliSubscriptions -Entry $Entry -Dir $CliDir | ForEach-Object { [pscustomobject]@{ id = $_.id; name = $_.name; isDefault = [bool]$_.isDefault } })
    }
    Import-CtxAzModule
    @(Get-AzSubscription -TenantId $Entry.tenantId -ErrorAction Stop -WarningAction SilentlyContinue |
        Where-Object { $_.Id -ine $Entry.tenantId } |
        ForEach-Object { [pscustomobject]@{ id = $_.Id; name = $_.Name; isDefault = ($_.Id -ieq $Entry.azSubscriptionId) } })
}

function Select-CtxSubscriptionChoice {
    <# Matches -Wanted by id/name/prefix, or shows a picker. Returns the chosen object or $null (tenant level). #>
    param([object[]]$Subscriptions, [string]$Wanted, [switch]$AllowNone, [string]$Title = 'Select subscription')
    $subs = @($Subscriptions | Where-Object { $_ } | Sort-Object name)
    if ($Wanted) {
        $hit = @($subs | Where-Object { $_.id -ieq $Wanted -or $_.name -ieq $Wanted })
        if (-not $hit) { $hit = @($subs | Where-Object { $_.name -like "$Wanted*" }) }
        if (-not $hit) { $hit = @($subs | Where-Object { $_.name -like "*$Wanted*" }) }
        if ($hit.Count -eq 1) { return $hit[0] }
        if ($hit.Count -gt 1) { throw "'$Wanted' matches several subscriptions: $(($hit | ForEach-Object name) -join ', ')" }
        throw "Subscription '$Wanted' not found. Available: $(($subs | ForEach-Object name) -join ', ')"
    }
    if ($subs.Count -eq 0) { return $null }
    if ($subs.Count -eq 1 -and $AllowNone) { return $subs[0] }
    if (-not (Test-CtxInteractive)) { return ($subs | Where-Object isDefault | Select-Object -First 1) ?? $subs[0] }
    $rows = @($subs | ForEach-Object { '{0}  {1}' -f (Format-CtxCell $_.name 44), $_.id })
    if ($AllowNone) { $rows += '(none - tenant level only)' }
    $default = [array]::IndexOf(@($subs | ForEach-Object { [bool]$_.isDefault }), $true)
    $choice = Show-CtxMenu -Rows $rows -Title $Title -Default ([math]::Max(0, $default))
    if (-not $choice -or $choice.Index -ge $subs.Count) { return $null }
    $subs[$choice.Index]
}
