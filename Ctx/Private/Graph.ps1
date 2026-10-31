# Microsoft Graph: device-code sessions bound to this terminal, scope profiles Admin / ReadOnly / Pim / custom.
# Cached tokens are reused before falling back to ctx's device-code flow (SDK issue #3495).
# Graph refresh tokens stay in this process' memory, unless the environment opts in to saved credentials (GraphStore.ps1).

$script:CtxGraphClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'   # Microsoft Graph Command Line Tools
$script:CtxLoginHost = 'https://login.microsoftonline.com'

$script:CtxAdminScopes = @(
    # Keep Application.Read.All too: the Fabric setup script checks for that exact scope.
    'Application.Read.All', 'Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All',
    'User.ReadWrite.All', 'Group.ReadWrite.All', 'UserAuthenticationMethod.ReadWrite.All',
    'Domain.Read.All', 'Policy.Read.AuthenticationMethod',
    'RoleManagement.ReadWrite.Directory', 'RoleEligibilitySchedule.Read.Directory', 'RoleAssignmentSchedule.ReadWrite.Directory'
)
$script:CtxBuiltInGraphProfiles = @('Admin', 'ReadOnly', 'Pim')

function Import-CtxGraphModule {
    if (-not (Get-Module Microsoft.Graph.Authentication)) {
        try { Import-Module Microsoft.Graph.Authentication -ErrorAction Stop | Out-Null }
        catch { throw "Microsoft.Graph.Authentication could not be loaded: $($_.Exception.Message). Install with (elevated): Install-PSResource Microsoft.Graph.Authentication -Scope AllUsers" }
    }
}

function Get-CtxDelegatedPermissionNames {
    <# Delegated Graph permission names known to the installed SDK (tab completion for -AddScopes), cached per SDK version. #>
    Import-CtxGraphModule
    $ver = (Get-Module Microsoft.Graph.Authentication).Version.ToString()
    $cacheFile = Join-Path (Get-CtxHome) 'graph-permissions.json'
    if (Test-Path -LiteralPath $cacheFile) {
        try {
            $cache = [IO.File]::ReadAllText($cacheFile) | ConvertFrom-Json
            if ($cache.version -eq $ver -and $cache.names) { return [string[]]$cache.names }
        } catch { Write-Debug "ctx: ignoring unreadable permission cache: $_" }
    }
    $names = [string[]](Find-MgGraphPermission -PermissionType Delegated -All -ErrorAction Stop | ForEach-Object Name | Sort-Object -Unique)
    $json = [ordered]@{ version = $ver; names = $names } | ConvertTo-Json -Depth 3
    [IO.File]::WriteAllText($cacheFile, $json, [Text.UTF8Encoding]::new($false))
    $names
}

function Test-CtxRemovedGraphProfile {
    <# True for the removed 'All' profile (every delegated permission), unless a custom profile is named 'All'. #>
    param([AllowNull()][string]$Name, $CustomProfiles)
    $Name -ieq 'All' -and -not ($CustomProfiles -is [System.Collections.IDictionary] -and $CustomProfiles.Contains('All'))
}

function Get-CtxGraphScopes {
    param([Parameter(Mandatory)][string]$GraphProfile)
    $cfg = Get-CtxConfig
    $custom = $cfg.graphScopeProfiles
    if ($custom -and $custom.Contains($GraphProfile)) { return [string[]]@($custom[$GraphProfile]) }
    switch ($GraphProfile) {
        'All' {
            throw "The 'All' Graph profile was removed: requesting every delegated permission violates least privilege and is rejected by Entra. Use Admin, ReadOnly, a custom profile (ctx config graphScopeProfiles.<name> ...) or ctx graph -AddScopes."
        }
        'Admin' { return [string[]]$script:CtxAdminScopes }
        'ReadOnly' {
            return [string[]]@(
                'Application.Read.All', 'User.Read.All', 'Group.Read.All', 'UserAuthenticationMethod.Read.All',
                'Domain.Read.All', 'Policy.Read.AuthenticationMethod', 'RoleManagement.Read.Directory',
                'RoleEligibilitySchedule.Read.Directory', 'RoleAssignmentSchedule.Read.Directory'
            )
        }
        'Pim' { return [string[]]@($cfg.pimBootstrapScopes) }
        default {
            $list = @($GraphProfile -split '[,;\s]+' | Where-Object { $_ })
            if ($list.Count -eq 1 -and $list[0] -notmatch '\.') {
                throw "Unknown Graph scope profile '$GraphProfile'. Use Admin, ReadOnly, Pim, a custom profile from config, or a scope list."
            }
            return [string[]]$list
        }
    }
}

function Get-CtxMgContext {
    <# Get-MgContext without auto-loading the Graph SDK. #>
    if (Get-Module Microsoft.Graph.Authentication) { Get-MgContext -ErrorAction SilentlyContinue }
}

function Disconnect-CtxGraphSession {
    Stop-CtxGraphRenewal
    if (Get-CtxMgContext) { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null }
    $script:GraphEnvName = $null
    $script:GraphProfileName = $null
    $script:GraphToken = $null
}

$script:CtxGraphRenewalId = 'Ctx.GraphTokenRenewal'

function Start-CtxGraphRenewal {
    <#
    Background renewal: a timer event checks the token every 4 minutes. PSReadLine processes events while the terminal
    waits for input, so a token never goes stale while idle. Runs on the pipeline thread (no races with commands).
    #>
    if (Get-EventSubscriber -SourceIdentifier $script:CtxGraphRenewalId -ErrorAction SilentlyContinue) { return }
    $timer = [System.Timers.Timer]::new(240000)
    $timer.AutoReset = $true
    $module = $ExecutionContext.SessionState.Module
    Register-ObjectEvent -InputObject $timer -EventName Elapsed -SourceIdentifier $script:CtxGraphRenewalId -MessageData $module -Action {
        try { & $Event.MessageData { [void](Update-CtxGraphToken -Quiet) } } catch { Write-Debug "ctx: background Graph renewal failed: $_" }
    } | Out-Null
    $timer.Start()
    $script:GraphRenewalTimer = $timer
}

function Stop-CtxGraphRenewal {
    Unregister-Event -SourceIdentifier $script:CtxGraphRenewalId -ErrorAction SilentlyContinue
    Get-Job -Name $script:CtxGraphRenewalId -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
    if ($script:GraphRenewalTimer) {
        $script:GraphRenewalTimer.Stop()
        $script:GraphRenewalTimer.Dispose()
        $script:GraphRenewalTimer = $null
    }
}

function Invoke-CtxOAuth {
    <# POST to the Entra v2 devicecode/token endpoint. OAuth errors come back as the response object (.error), not as exceptions. #>
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][ValidateSet('devicecode', 'token')][string]$Endpoint,
        [Parameter(Mandatory)][hashtable]$Body,
        [int]$TimeoutSec = 30
    )
    $status = 0
    $r = Invoke-RestMethod -Method Post -Uri "$script:CtxLoginHost/$TenantId/oauth2/v2.0/$Endpoint" -Body $Body `
        -ContentType 'application/x-www-form-urlencoded' -SkipHttpErrorCheck -StatusCodeVariable 'status' -TimeoutSec $TimeoutSec -ErrorAction Stop -Verbose:$false
    if ($status -ge 400 -and -not ($r -and $r.PSObject.Properties['error'])) {
        $r = [pscustomobject]@{ error = "http_$status"; error_description = "HTTP $status from the sign-in service" }
    }
    $r
}

function Get-CtxOAuthErrorText {
    param($Response)
    $d = [string]$Response.error_description
    $aad = [regex]::Match($d, 'AADSTS\d+:[^\r\n]*?(?=(\s*Trace ID|\r?\n|$))')
    if ($aad.Success) { return $aad.Value.Trim() }
    if ($d) { return ($d -split '\r?\n')[0].Trim() }
    [string]$Response.error
}

function Get-CtxGraphScopeString {
    <# Bare scope names mean Microsoft Graph; offline_access returns the refresh token used for silent renewal. #>
    param([string[]]$Scopes)
    $extra = @('offline_access', 'openid', 'profile')
    (@($Scopes | ForEach-Object { $_ -split '[,;\s]+' } |
        Where-Object { $_ -and $_ -notin $extra } | Select-Object -Unique) + $extra) -join ' '
}

function Get-CtxMissingGraphScopes {
    param([string[]]$Granted, [string[]]$Required)
    $have = @($Granted | ForEach-Object { $_ -replace '^https://graph\.microsoft\.com/', '' })
    foreach ($s in @($Required | ForEach-Object { $_ -replace '^https://graph\.microsoft\.com/', '' } | Select-Object -Unique)) {
        if (-not $s -or $s -in 'offline_access', 'openid', 'profile' -or $have -contains $s) { continue }
        if ($s -match '\.Read\.' -and $have -contains ($s -replace '\.Read\.', '.ReadWrite.')) { continue }
        if ($s -eq 'Policy.Read.AuthenticationMethod' -and
            ($have -contains 'Policy.Read.All' -or $have -contains 'Policy.ReadWrite.AuthenticationMethod')) { continue }
        if ($s -in 'RoleEligibilitySchedule.Read.Directory', 'RoleAssignmentSchedule.ReadWrite.Directory' -and
            $have -contains 'RoleManagement.ReadWrite.Directory') { continue }
        $s
    }
}

function Get-CtxAzGraphToken {
    param([Parameter(Mandatory)]$Entry)
    if (-not (Test-CtxTool $Entry 'az') -or -not $Entry.azContextName -or -not (Test-CtxAzAvailable)) { return }
    Import-CtxAzModule
    $context = Get-CtxAzNamedContext $Entry.azContextName
    if (-not $context -or $context.Tenant.Id -ine $Entry.tenantId -or
        $context.Account.Type -ne 'User' -or $context.Account.Id -ine $Entry.upn) { return }
    $token = Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com' -TenantId $Entry.tenantId `
        -DefaultProfile $context -ErrorAction Stop -WarningAction SilentlyContinue -Verbose:$false -Debug:$false
    [pscustomobject]@{
        access_token = ConvertFrom-CtxSecureToken $token.Token
        expires_in   = [int]($token.ExpiresOn.UtcDateTime - [datetime]::UtcNow).TotalSeconds
    }
}

function Request-CtxGraphDeviceToken {
    <# Device-code flow: shows the code (clipboard + browser profile), polls until signed in. Returns the token response. #>
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Tool
    )
    $dc = Invoke-CtxOAuth -TenantId $Entry.tenantId -Endpoint devicecode -Body @{ client_id = $ClientId; scope = $Scope }
    if (-not $dc.device_code) { throw "$Tool sign-in failed: $(Get-CtxOAuthErrorText $dc)" }
    $url = if ($dc.verification_uri) { [string]$dc.verification_uri } else { 'https://microsoft.com/devicelogin' }
    Show-CtxDeviceCode -Code $dc.user_code -Url $url -Entry $Entry -Tool $Tool
    $interval = if ([int]$dc.interval -gt 0) { [int]$dc.interval } else { 5 }
    $lifetime = if ([int]$dc.expires_in -gt 0) { [int]$dc.expires_in } else { 900 }
    $deadline = [datetime]::UtcNow.AddSeconds($lifetime)
    $netErrors = 0
    while ([datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            $t = Invoke-CtxOAuth -TenantId $Entry.tenantId -Endpoint token -Body @{
                grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                client_id   = $ClientId
                device_code = $dc.device_code
            }
            $netErrors = 0
        } catch {
            if (++$netErrors -ge 5) { throw "$Tool sign-in failed: $($_.Exception.Message)" }
            continue
        }
        if ($t.access_token) { return $t }
        switch ([string]$t.error) {
            'authorization_pending' { }
            'slow_down' { $interval += 5 }
            'authorization_declined' { throw "$Tool sign-in was declined in the browser." }
            'expired_token' { throw "$Tool sign-in code expired - run the command again." }
            default { throw "$Tool sign-in failed: $(Get-CtxOAuthErrorText $t)" }
        }
    }
    throw "$Tool sign-in code expired - run the command again."
}

function Connect-CtxGraphToken {
    <# Hands an access token to the Graph SDK. Calling it again swaps the token in place (same session, new token). #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'The token arrives as plain text from the token endpoint; Connect-MgGraph requires a SecureString.')]
    param([Parameter(Mandatory)][string]$AccessToken)
    $secure = ConvertTo-SecureString -String $AccessToken -AsPlainText -Force
    Connect-MgGraph -AccessToken $secure -NoWelcome -ErrorAction Stop | Out-Null
}

function Set-CtxGraphToken {
    param(
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$Scope,
        [ValidateSet('DeviceCode', 'Az')][string]$Source = 'DeviceCode',
        [string]$PreviousRefreshToken,
        # Start of the sign-in this token belongs to (kept across renewals; bounded by graphMaxSessionHours).
        [Nullable[datetime]]$SessionStartedAt
    )
    $claims = ConvertFrom-CtxJwt $Response.access_token
    $id = Get-CtxIdentityFromClaims $claims
    if ($id.TenantId -ine $Entry.tenantId) { throw "Graph signed into tenant '$($id.TenantId)', expected $($Entry.tenantId)." }
    if ($id.ObjectId -ine $Entry.userObjectId) {
        throw "Graph signed in as '$($id.Upn)' but environment '$($Entry.name)' is $($Entry.upn) (environment = tenant + login)."
    }
    if ($claims.aud -notin 'https://graph.microsoft.com', 'https://graph.microsoft.com/', '00000003-0000-0000-c000-000000000000') {
        throw 'The access token is not intended for Microsoft Graph.'
    }
    $expires = if ($claims.exp) { [DateTimeOffset]::FromUnixTimeSeconds([long]$claims.exp).UtcDateTime }
    else { [datetime]::UtcNow.AddSeconds([int]$Response.expires_in) }
    if ($expires -le [datetime]::UtcNow.AddMinutes(1)) { throw 'Graph returned an expired or nearly expired access token.' }
    $granted = [string[]]@(([string]$claims.scp) -split ' ' | Where-Object { $_ })
    $missing = @(Get-CtxMissingGraphScopes -Granted $granted -Required ($Scope -split ' '))
    if ($missing.Count) {
        $scopeError = [InvalidOperationException]::new("Microsoft Graph did not grant the required scopes: $($missing -join ', ').")
        $scopeError.Data['CtxOAuthError'] = 'consent_required'
        throw $scopeError
    }
    Connect-CtxGraphToken $Response.access_token
    $script:GraphToken = @{
        Entry         = $Entry
        TenantId      = $id.TenantId
        ObjectId      = $id.ObjectId
        Account       = $id.Upn
        ClientId      = $ClientId
        TokenClientId = if ($claims.appid) { [string]$claims.appid } else { [string]$claims.azp }
        Scope         = $Scope
        Scopes        = $granted
        Source        = $Source
        RefreshToken  = if ($Response.refresh_token) { [string]$Response.refresh_token } else { $PreviousRefreshToken }
        ExpiresAt     = $expires
        SessionStartedAt = if ($SessionStartedAt) { [datetime]$SessionStartedAt } else { [datetime]::UtcNow }
        RetryAfter    = $null
        LastError     = $null
        ErrorCode     = $null
        Warned        = $false
    }
    # The SDK may spell an account differently from the identity helper, especially for guest UPNs.
    $context = Get-CtxMgContext
    if ($context) {
        $script:GraphToken.Account = [string]$context.Account
        $script:GraphToken.TokenClientId = [string]$context.ClientId
    }
    if ($Source -eq 'DeviceCode' -and $Response.refresh_token -and (Test-CtxGraphCredentialsEnabled $Entry.name)) {
        Save-CtxGraphCredentials -Entry $Entry -ClientId $ClientId -RefreshToken ([string]$Response.refresh_token) -SessionStartedAt $script:GraphToken.SessionStartedAt
    }
}

function Update-CtxGraphToken {
    <#
    Keeps this terminal's ctx Graph session alive: renews the access token with the in-memory refresh token when it
    expires within MinMinutes. With -Force, success requires a new token, not just an unexpired old token.
    -Quiet (timer) defers renewal warnings to the next prompt / ctx command.
    #>
    param([double]$MinMinutes = 15, [switch]$Quiet, [switch]$Force, [string[]]$Scopes)
    $t = $script:GraphToken
    if (-not $t) { return $false }
    $now = [datetime]::UtcNow
    $mg = Get-CtxMgContext
    if (-not $mg -or [string]$mg.AuthType -ne 'UserProvidedAccessToken' -or $mg.TenantId -ine $t.TenantId -or
        $mg.Account -ine $t.Account -or $mg.ClientId -ine $t.TokenClientId) {
        # The Graph session was ended or replaced outside ctx - leave it alone.
        Stop-CtxGraphRenewal
        $script:GraphToken = $null
        $script:GraphEnvName = $null
        $script:GraphProfileName = $null
        return $false
    }
    if (-not $Force -and $t.ExpiresAt -gt $now.AddMinutes($MinMinutes)) { return $true }
    $scope = if ($Scopes) { Get-CtxGraphScopeString $Scopes } else { $t.Scope }
    $valid = $t.ExpiresAt -gt $now.AddMinutes(1)
    if ($Force -or -not ($t.RetryAfter -and $now -lt $t.RetryAfter)) {
        $r = $null
        $maxHours = 0.0
        [void][double]::TryParse([string](Get-CtxConfig).graphMaxSessionHours, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$maxHours)
        try {
            if ($maxHours -gt 0 -and $t.SessionStartedAt -and $now -ge ([datetime]$t.SessionStartedAt).AddHours($maxHours)) {
                # Bounded sessions: an idle terminal must not keep privileged Graph access alive indefinitely.
                if ($t.RefreshToken -and $t.Entry) { Remove-CtxGraphCredentials -Name $t.Entry.name -RefreshToken $t.RefreshToken }
                $t.RefreshToken = $null
                $r = [pscustomobject]@{ error = 'login_required'; error_description = "The Graph session reached graphMaxSessionHours ($maxHours h) and is no longer renewed." }
            } elseif ($t.Source -eq 'Az') {
                # Get-AzAccessToken has no force-refresh parameter; do not pretend its cached token is new after PIM.
                if ($Force) {
                    $r = [pscustomobject]@{ error = 'interaction_required'; error_description = 'A fresh Graph token is needed; Az cannot force-refresh its cached token.' }
                } else {
                    $r = Get-CtxAzGraphToken -Entry $t.Entry
                    if (-not $r) { $r = [pscustomobject]@{ error = 'login_required'; error_description = 'The matching Az context is no longer available.' } }
                }
            } elseif ($t.RefreshToken) {
                $r = Invoke-CtxOAuth -TenantId $t.TenantId -Endpoint token -TimeoutSec 10 -Body @{
                    grant_type    = 'refresh_token'
                    client_id     = $t.ClientId
                    refresh_token = $t.RefreshToken
                    scope         = $scope
                }
            } else {
                $r = [pscustomobject]@{ error = 'login_required'; error_description = 'No Graph refresh token is available.' }
            }
        } catch { $r = [pscustomobject]@{ error = 'network'; error_description = $_.Exception.Message } }
        if ($r.access_token) {
            try {
                Set-CtxGraphToken -Response $r -Entry $t.Entry -ClientId $t.ClientId -Scope $scope -Source $t.Source -PreviousRefreshToken $t.RefreshToken -SessionStartedAt $t.SessionStartedAt
                if ($script:GraphToken.ExpiresAt -le $t.ExpiresAt) { $script:GraphToken.RetryAfter = $now.AddMinutes(2) }
                return $true
            } catch {
                $code = if ($_.Exception.Data['CtxOAuthError']) { $_.Exception.Data['CtxOAuthError'] } else { 'token_validation' }
                $r = [pscustomobject]@{ error = $code; error_description = $_.Exception.Message }
            }
        }
        $t.RetryAfter = $now.AddMinutes(2)
        # A consent failure for added scopes does not invalidate the original session's refresh token.
        if ($r.error -eq 'invalid_grant' -and $scope -eq $t.Scope) {
            if ($t.RefreshToken -and $t.Entry) { Remove-CtxGraphCredentials -Name $t.Entry.name -RefreshToken $t.RefreshToken }
            $t.RefreshToken = $null
        }
        $t.LastError = Get-CtxOAuthErrorText $r
        $t.ErrorCode = [string]$r.error
    }
    if ($t.LastError -and -not $t.Warned -and -not $Quiet) {
        $t.Warned = $true
        $when = if ($valid) { "expires $($t.ExpiresAt.ToLocalTime().ToString('HH:mm'))" } else { 'expired' }
        Write-Host "  ctx: Microsoft Graph token could not be renewed ($($t.LastError)); $when - 'ctx graph' retries the connection." -ForegroundColor Yellow
    }
    $valid -and -not $Force
}

function Test-CtxGraphSession {
    <# True when this terminal holds a Graph session for the environment with all required scopes. #>
    param([Parameter(Mandatory)]$Entry, [string[]]$RequiredScopes)
    if ($script:GraphEnvName -ne $Entry.name) { return $false }
    if (-not (Update-CtxGraphToken)) { return $false }
    $ctx = Get-CtxMgContext
    if (-not $ctx -or $ctx.TenantId -ine $Entry.tenantId) { return $false }
    if ($script:GraphToken.ObjectId -ine $Entry.userObjectId) { return $false }
    @(Get-CtxMissingGraphScopes -Granted $ctx.Scopes -Required $RequiredScopes).Count -eq 0
}

function Connect-CtxGraphSession {
    <# Reuses or silently renews matching credentials before asking for a device code. #>
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string[]]$Scopes,
        [Parameter(Mandatory)][string]$Label,
        [switch]$Refresh,
        [switch]$Relogin
    )
    Import-CtxGraphModule
    $clientId = if ($Entry.graphClientId) { [string]$Entry.graphClientId } else { $script:CtxGraphClientId }
    $scope = Get-CtxGraphScopeString $Scopes
    $ready = $false
    if (-not $Relogin -and $script:GraphEnvName -eq $Entry.name -and $script:GraphToken -and
        $script:GraphToken.ObjectId -ieq $Entry.userObjectId -and $script:GraphToken.ClientId -eq $clientId) {
        $usable = Update-CtxGraphToken -Quiet
        $t = $script:GraphToken
        if ($t) {
            if (-not $usable -and $t.LastError -and $t.ErrorCode -notin 'interaction_required', 'consent_required', 'login_required', 'invalid_grant') {
                throw "Microsoft Graph token renewal failed: $($t.LastError)"
            }
            $missing = @(Get-CtxMissingGraphScopes -Granted $t.Scopes -Required $Scopes)
            if (-not $Refresh -and $usable -and -not $missing.Count -and ($t.Scope -eq $scope -or $t.Source -eq 'Az')) {
                $t.Scope = $scope
                $ready = $true
            } else {
                $ready = Update-CtxGraphToken -Force -Scopes $Scopes -Quiet
                if (-not $ready -and $t.ErrorCode -notin 'interaction_required', 'consent_required', 'login_required', 'invalid_grant') {
                    throw "Microsoft Graph token renewal failed: $($t.LastError)"
                }
                if (-not $ready) { Write-CtxMsg dim "Microsoft Graph needs device authentication: $($t.LastError)" }
            }
        }
    }
    if (-not $ready -and -not $Relogin) {
        $ready = Restore-CtxGraphCredentials -Entry $Entry -ClientId $clientId -Scope $scope
    }
    if (-not $ready -and -not $Refresh -and -not $Relogin -and -not $Entry.graphClientId) {
        try {
            $cached = Get-CtxAzGraphToken -Entry $Entry
            if ($cached) {
                Set-CtxGraphToken -Response $cached -Entry $Entry -ClientId $clientId -Scope $scope -Source Az
                Write-CtxMsg dim 'Microsoft Graph is using the matching cached Az login (no device code).'
                $ready = $true
            }
        } catch { Write-CtxMsg dim "Cached Az Graph token cannot be used: $($_.Exception.Message)" }
    }
    if (-not $ready) {
        $tok = Request-CtxGraphDeviceToken -Entry $Entry -ClientId $clientId -Scope $scope -Tool "Microsoft Graph ($Label)"
        Set-CtxGraphToken -Response $tok -Entry $Entry -ClientId $clientId -Scope $scope
    }
    $script:GraphEnvName = $Entry.name
    $script:GraphProfileName = $Label
    if ($script:GraphToken.RefreshToken -or $script:GraphToken.Source -eq 'Az') { Start-CtxGraphRenewal }
    [pscustomobject]@{
        Account   = $script:GraphToken.Account
        TenantId  = $script:GraphToken.TenantId
        Scopes    = $script:GraphToken.Scopes
        ExpiresAt = $script:GraphToken.ExpiresAt
    }
}

function Invoke-CtxGraphList {
    <# GET with paging; returns the items of .value. #>
    param([Parameter(Mandatory)][string]$Uri)
    $next = $Uri
    while ($next) {
        $r = Invoke-MgGraphRequest -Method GET -Uri $next -ErrorAction Stop
        foreach ($v in @($r.value)) { if ($v) { $v } }
        $next = $r.'@odata.nextLink'
    }
}
