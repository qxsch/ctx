function Invoke-CtxPim {
    <#
    .SYNOPSIS
    Activates a PIM role (default: Global Administrator) and prepares Microsoft Graph with the selected scope profile.
    .DESCRIPTION
    1. Reuse a matching Graph/Az login, otherwise request PIM + the selected Graph scopes in one device-code sign-in.
    2. Self-activation via Graph (justification / ticket / duration asked only when the policy needs it).
    3. Silently refresh after activation. Default Graph profile: Admin (focused Entra administration).
    Defaults (hours, reason, ticket system) are remembered per environment.
    .EXAMPLE
    ctx pim
    .EXAMPLE
    ctx pim -Hours 2 -Reason "CHG0042 conditional access change"
    .EXAMPLE
    ctx pim exchange -NoGraph
    .EXAMPLE
    ctx pim -List
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Role,
        [string]$Environment,
        [ValidateRange(0.5, 24)][double]$Hours,
        [string]$Reason,
        [string]$Ticket,
        [string]$TicketSystem,
        [switch]$List,
        [switch]$Deactivate,
        [switch]$Renew,
        [switch]$NoGraph,
        [string]$GraphProfile,
        [switch]$Wait,
        [switch]$Force
    )
    $entry = Get-CtxCommandEnvironment $Environment
    $cfg = Get-CtxConfig
    $cfgProfile = if ($GraphProfile) { $GraphProfile } elseif ($entry.graphProfile) { $entry.graphProfile } else { $cfg.defaultGraphProfile }
    $pimCfg = if ($entry.pim) { $entry.pim } else { @{} }
    $roleSpec = if ($Role) { $Role } elseif ($pimCfg.role) { $pimCfg.role } else { $cfg.pimDefaultRole }
    # Not $role: PowerShell variables are case-insensitive, so that would overwrite the [string]$Role parameter.
    $roleInfo = Resolve-CtxRole $roleSpec
    $matchRole = { param($r) ($roleInfo.Id -and $r.RoleId -ieq $roleInfo.Id) -or ($r.RoleName -ieq $roleInfo.Name) }

    if ($List) {
        Use-CtxPimGraph $entry
        $eligible = @(Get-CtxPimEligibleRoles $entry)
        $active = @(Get-CtxPimActiveRoles $entry)
        Set-CtxActivationCache -Name $entry.name -Active $active
        $ids = @($eligible.RoleId) + @($active.RoleId) | Where-Object { $_ } | Select-Object -Unique
        foreach ($id in $ids) {
            $a = $active | Where-Object RoleId -EQ $id | Select-Object -First 1
            $e = $eligible | Where-Object RoleId -EQ $id | Select-Object -First 1
            $nameOf = if ($a) { $a.RoleName } else { $e.RoleName }
            [pscustomobject]@{
                PSTypeName = 'Ctx.PimRole'
                Role       = $nameOf
                Status     = if ($a -and $a.AssignmentType -eq 'Assigned') { 'Permanent' } elseif ($a) { 'Active' } else { 'Eligible' }
                Remaining  = if ($a -and $a.End) { Format-CtxDuration ($a.End - [datetime]::UtcNow) } elseif ($a) { '∞' } else { '' }
                Until      = if ($a -and $a.End) { $a.End.ToLocalTime() } else { $null }
                Eligible   = [bool]$e
                RoleId     = $id
            }
        }
        return
    }

    if ($Deactivate) {
        Use-CtxPimGraph $entry
        $active = @(Get-CtxPimActiveRoles $entry)
        $hit = @($active | Where-Object { & $matchRole $_ })
        if (-not $hit.Count) {
            Write-CtxMsg warn "$($roleInfo.Name) is not active in '$($entry.name)'."
            Set-CtxActivationCache -Name $entry.name -Active $active
            return
        }
        try {
            $null = New-CtxPimRequest -Entry $entry -RoleId $hit[0].RoleId -Action selfDeactivate
        } catch {
            $msg = Get-CtxGraphErrorText $_
            if ((Get-CtxPimErrorKind $msg) -eq 'TooShort') { throw 'PIM does not allow deactivation within the first 5 minutes of an activation.' }
            throw "Deactivation failed: $msg"
        }
        Start-Sleep -Seconds 3
        Set-CtxActivationCache -Name $entry.name -Active @(Get-CtxPimActiveRoles $entry)
        Write-CtxMsg ok "$($hit[0].RoleName) deactivated in '$($entry.name)'."
        return
    }

    $activatedNow = $false
    $active = $null
    if (-not $Renew -and -not $Force) {
        $active = @(Get-CtxActiveActivations $entry | Where-Object { (& $matchRole $_) -and ($null -eq $_.Remaining -or $_.Remaining.TotalMinutes -gt 5) }) | Select-Object -First 1
        if ($active) { Write-CtxMsg ok "$($roleInfo.Name) already active in '$($entry.name)' ($(Format-CtxDuration $active.Remaining) left)." }
    }
    if (-not $active) {
        Use-CtxPimGraph -Entry $entry -GraphProfile $(if (-not $NoGraph) { $cfgProfile })
        $live = @(Get-CtxPimActiveRoles $entry)
        $hit = @($live | Where-Object { & $matchRole $_ })
        if ($hit.Count -and $Renew) {
            Write-CtxMsg step "Renewing: deactivating the current $($hit[0].RoleName) activation"
            try { $null = New-CtxPimRequest -Entry $entry -RoleId $hit[0].RoleId -Action selfDeactivate; Start-Sleep -Seconds 5 }
            catch {
                $msg = Get-CtxGraphErrorText $_
                if ((Get-CtxPimErrorKind $msg) -eq 'TooShort') { throw 'The activation is younger than 5 minutes - PIM cannot renew it yet.' }
                throw "Deactivation failed: $msg"
            }
            $hit = @()
        }
        if ($hit.Count) {
            $active = $hit[0]
            Set-CtxActivationCache -Name $entry.name -Active $live
            Write-CtxMsg ok "$($active.RoleName) already active ($(Format-CtxDuration $(if ($active.End) { $active.End - [datetime]::UtcNow } else { $null })) left)."
        } else {
            $active = Request-CtxPimActivation -Entry $entry -Role $roleInfo -Hours $Hours -Reason $Reason -Ticket $Ticket -TicketSystem $TicketSystem -Wait:$Wait -RoleExplicit:([bool]$Role)
            if (-not $active) { return }
            $activatedNow = $true
        }
    }

    if ($NoGraph) { return }
    if ($activatedNow) { Write-CtxMsg step 'Refreshing Microsoft Graph after PIM activation' }
    if ($GraphProfile) { Connect-CtxGraph -Scopes $GraphProfile -Environment $entry.name -Refresh:$activatedNow }
    else { Connect-CtxGraph -Environment $entry.name -Refresh:$activatedNow }
}

function Request-CtxPimActivation {
    <# Eligibility check + activation request with policy-driven retries. Returns the active instance or $null (pending). #>
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)]$Role,
        [double]$Hours,
        [string]$Reason,
        [string]$Ticket,
        [string]$TicketSystem,
        [switch]$Wait,
        [switch]$RoleExplicit
    )
    $cfg = Get-CtxConfig
    $pimCfg = if ($Entry.pim) { $Entry.pim } else { @{} }
    $eligible = @(Get-CtxPimEligibleRoles $Entry)
    $match = @($eligible | Where-Object { ($Role.Id -and $_.RoleId -ieq $Role.Id) -or $_.RoleName -ieq $Role.Name })
    if (-not $match.Count) {
        $names = @($eligible | ForEach-Object RoleName | Sort-Object -Unique)
        throw "$($Entry.upn) is not eligible for '$($Role.Name)' in '$($Entry.name)'. Eligible: $(if ($names) { $names -join ', ' } else { 'none' })."
    }
    $roleId = $match[0].RoleId
    $roleName = $match[0].RoleName
    $h = if ($Hours) { $Hours } elseif ($pimCfg.hours) { [double]$pimCfg.hours } else { [double]$cfg.pimDefaultHours }
    $why = if ($Reason) { $Reason } else {
        $default = if ($pimCfg.reason) { $pimCfg.reason } else { 'Administrative work' }
        Read-CtxText 'Justification' -Default $default
    }
    $ticketNo = $Ticket
    $ticketSys = if ($TicketSystem) { $TicketSystem } else { $pimCfg.ticketSystem }

    $req = $null
    $viaPortal = $false
    for ($attempt = 1; $attempt -le 5 -and -not $req; $attempt++) {
        try {
            Write-CtxMsg step "Requesting $roleName for $(Format-CtxDuration ([timespan]::FromHours($h)))"
            $req = New-CtxPimRequest -Entry $Entry -RoleId $roleId -Action selfActivate -Duration ([timespan]::FromHours($h)) -Reason $why -Ticket $ticketNo -TicketSystem $ticketSys
        } catch {
            $msg = Get-CtxGraphErrorText $_
            $kind = Get-CtxPimErrorKind $msg
            if ($kind -eq 'Exists') {
                $req = @{ status = 'Provisioned' }
            } elseif ($kind -eq 'Expiration') {
                $suggest = [math]::Max(0.5, [math]::Floor($h / 2))
                Write-CtxMsg warn "The policy does not allow $h h."
                $h = [double](Read-CtxText 'Hours' -Default "$suggest")
            } elseif ($kind -eq 'Justification') {
                Write-CtxMsg warn 'The policy requires a (longer) justification.'
                $why = Read-CtxText 'Justification' -Required
            } elseif ($kind -eq 'Ticket') {
                Write-CtxMsg warn 'The policy requires ticket information.'
                $ticketNo = Read-CtxText 'Ticket number' -Required
                $ticketSys = Read-CtxText 'Ticket system' -Default $(if ($ticketSys) { $ticketSys } else { 'ServiceNow' }) -Required
            } elseif ($kind -eq 'Mfa') {
                Write-CtxMsg warn 'The policy requires MFA / an authentication context - finish the activation in the PIM portal.'
                Open-CtxBrowser -Url (Get-CtxPortalUrl -Entry $Entry -Portal 'pim') -Entry $Entry
                if (Test-CtxInteractive) { $null = Read-Host '  ? Press Enter once the role is activated in the portal' }
                $req = @{ status = 'Portal' }
                $viaPortal = $true
            } else {
                throw "PIM activation failed: $msg"
            }
        }
    }
    if (-not $req) { throw 'PIM activation failed after several attempts.' }

    $active = $null
    if ([string]$req.status -match 'PendingApproval') {
        Write-CtxMsg warn "$roleName needs approval."
        if ($Wait -or (Read-CtxYesNo 'Wait for the approval (up to 30 minutes)?' $true)) {
            $active = Wait-CtxPimActive -Entry $Entry -RoleId $roleId -TimeoutSeconds 1800
        }
        if (-not $active) {
            Write-CtxMsg dim "Run 'ctx pim' again once it is approved."
            Save-CtxPimDefaults -Entry $Entry -Hours $h -Reason $why -TicketSystem $ticketSys -Role $(if ($RoleExplicit) { $roleName } else { $null })
            return $null
        }
    } else {
        $active = Wait-CtxPimActive -Entry $Entry -RoleId $roleId -TimeoutSeconds $(if ($viaPortal) { 300 } else { 180 })
        if (-not $active) { throw "Activation requested (status $($req.status)) but the role is not active yet. Check with: ctx pim -List" }
    }
    Set-CtxActivationCache -Name $Entry.name -Active @(Get-CtxPimActiveRoles $Entry)
    Save-CtxPimDefaults -Entry $Entry -Hours $h -Reason $why -TicketSystem $ticketSys -Role $(if ($RoleExplicit) { $roleName } else { $null })
    $until = if ($active.End) { $active.End.ToLocalTime().ToString('HH:mm') } else { 'permanent' }
    Write-CtxMsg ok "$roleName active until $until"
    $active
}

function Save-CtxPimDefaults {
    param($Entry, [double]$Hours, [string]$Reason, [string]$TicketSystem, [string]$Role)
    $targetName = $Entry.name
    $null = Update-CtxState {
        param($s)
        $e = Find-CtxEnvironment $s $targetName
        if (-not $e) { return }
        if (-not $e.pim) { $e.pim = [ordered]@{} }
        if ($Hours) { $e.pim.hours = $Hours }
        if ($Reason) { $e.pim.reason = $Reason }
        if ($TicketSystem) { $e.pim.ticketSystem = $TicketSystem }
        if ($Role) { $e.pim.role = $Role }
    }
}

function Connect-CtxGraph {
    <#
    .SYNOPSIS
    Connects Microsoft Graph using cached credentials, silent refresh, or device code when necessary.
    .PARAMETER Scopes
    Scope profile (Admin, ReadOnly, Pim, custom from config) or a comma separated scope list. Default: the
    environment's profile, else config defaultGraphProfile (Admin). An explicit profile replaces session additions.
    .PARAMETER AddScopes
    Add permissions to the current session, or to the selected/default profile if no session exists.
    Accepts an array or comma-separated names. Additions are not saved to the environment.
    .PARAMETER Refresh
    Obtain a fresh token, silently when possible. Used after PIM activation.
    .PARAMETER Relogin
    Skip cached credentials and explicitly sign in with device code.
    .EXAMPLE
    ctx graph
    .EXAMPLE
    ctx graph ReadOnly
    .EXAMPLE
    ctx graph "User.Read.All,Group.Read.All"
    .EXAMPLE
    ctx graph -AddScopes "AuditLog.Read.All,Policy.ReadWrite.AuthenticationMethod"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Scopes,
        [string[]]$AddScopes,
        [string]$Environment,
        [switch]$Refresh,
        [switch]$Relogin
    )
    $entry = Get-CtxCommandEnvironment $Environment
    $cfg = Get-CtxConfig
    $current = $script:GraphToken -and $script:GraphEnvName -eq $entry.name -and $script:GraphToken.ObjectId -ieq $entry.userObjectId
    $profileName = if ($Scopes) { $Scopes } elseif ($AddScopes -and $current) { $script:GraphProfileName }
    elseif ($entry.graphProfile) { $entry.graphProfile } else { $cfg.defaultGraphProfile }
    $list = if (-not $Scopes -and $current -and $script:GraphProfileName -eq $profileName) {
        @($script:GraphToken.Scope -split ' ' | Where-Object { $_ -notin 'offline_access', 'openid', 'profile' })
    } else { @(Get-CtxGraphScopes $profileName) }
    if ($PSBoundParameters.ContainsKey('AddScopes')) {
        $extra = @($AddScopes | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ })
        if (-not $extra.Count) { throw 'AddScopes requires at least one Microsoft Graph permission name.' }
        $list = @($list + $extra | Select-Object -Unique)
    }
    Write-CtxMsg step "Preparing Microsoft Graph · profile $profileName ($($list.Count) scopes)"
    $mg = Connect-CtxGraphSession -Entry $entry -Scopes $list -Label $profileName -Refresh:$Refresh -Relogin:$Relogin
    Write-CtxMsg ok "Microsoft Graph connected · $($mg.Account) · $profileName · $(@($mg.Scopes).Count) scopes granted"
}

function Get-CtxCommandEnvironment {
    <# Environment for admin commands: must be this terminal's environment (Graph sessions are per terminal). #>
    param([string]$Environment)
    $here = Get-CtxProcessEnvironment
    if (-not $Environment) { return $here }
    $entry = Resolve-CtxEnvironment (Read-CtxState) $Environment
    if ($entry.name -ne $here.name) {
        throw "This terminal is in '$($here.name)'. Switch first: ctx $($entry.name)   (or ctx $($entry.name) -Local for this terminal only)"
    }
    $entry
}
