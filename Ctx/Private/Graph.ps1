# Microsoft Graph: sessions bound to this terminal, scope profiles Admin / ReadOnly / Pim / custom.
# Before any interactive sign-in, every existing login of the environment is asked for a token (this terminal's
# session, saved credentials, Az PowerShell, Azure CLI). Only then ctx signs in with the environment's method:
# its own device-code flow (SDK issue #3495), its own browser flow (auth code + PKCE), or the Windows broker (WAM).
# Graph refresh tokens stay in this process' memory, unless the environment opts in to saved credentials (GraphStore.ps1).

$script:CtxGraphClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'   # Microsoft Graph Command Line Tools
$script:CtxLoginHost = 'https://login.microsoftonline.com'
# Sessions that ctx renews with its own refresh token, and sessions it renews by asking their provider again.
$script:CtxGraphRefreshSources = @('DeviceCode', 'Browser')
$script:CtxGraphProviderSources = @('Az', 'Cli', 'Broker')

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

function Get-CtxCliGraphToken {
    <# Graph token from the environment's Azure CLI login (az account get-access-token); $null when it has none. #>
    param([Parameter(Mandatory)]$Entry)
    if (-not (Test-CtxTool $Entry 'cli') -or -not (Get-CtxAzCliPath)) { return }
    $dir = Get-CtxCliDir $Entry.name
    if (-not (Get-CtxCliProfile $dir)) { return }
    $r = Invoke-CtxAzCli -ConfigDir $dir -Json -Arguments @(
        'account', 'get-access-token', '--resource-type', 'ms-graph', '--tenant', [string]$Entry.tenantId, '-o', 'json', '--only-show-errors')
    if (-not $r.Success -or -not $r.Value -or -not $r.Value.accessToken) { return }
    $expires = if ($r.Value.expires_on) { [DateTimeOffset]::FromUnixTimeSeconds([long]$r.Value.expires_on).UtcDateTime } else { $null }
    [pscustomobject]@{
        access_token = [string]$r.Value.accessToken
        expires_in   = if ($expires) { [int]($expires - [datetime]::UtcNow).TotalSeconds } else { 3000 }
    }
}

function Get-CtxProviderGraphToken {
    <# Asks a token provider again (renewal or reuse). Az and Azure CLI return what their login allows; Broker may show WAM UI. #>
    param(
        [Parameter(Mandatory)][ValidateSet('Az', 'Cli', 'Broker')][string]$Source,
        [Parameter(Mandatory)]$Entry,
        [string]$ClientId,
        [string]$Scope
    )
    switch ($Source) {
        'Az' { Get-CtxAzGraphToken -Entry $Entry }
        'Cli' { Get-CtxCliGraphToken -Entry $Entry }
        'Broker' { Request-CtxGraphBrokerToken -Entry $Entry -ClientId $ClientId -Scope $Scope -Tool 'Microsoft Graph' -Quiet }
    }
}

function Request-CtxGraphBrowserToken {
    <#
    Authorization code flow with PKCE (RFC 7636) and a loopback redirect (RFC 8252): the sign-in page opens in the
    environment's browser profile with the account as login hint, and the browser returns to http://localhost:<port>.
    Returns the token response (with a refresh token, renewed like a device-code session).
    #>
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Tool,
        [int]$TimeoutSeconds = 300
    )
    $pkce = New-CtxPkce
    $state = New-CtxRandomString 24
    $listener = Start-CtxLoopbackListener
    try {
        $redirect = "http://localhost:$($listener.Port)"
        $query = [ordered]@{
            client_id             = $ClientId
            response_type         = 'code'
            redirect_uri          = $redirect
            response_mode         = 'query'
            scope                 = $Scope
            state                 = $state
            code_challenge        = $pkce.Challenge
            code_challenge_method = 'S256'
        }
        if ($Entry.upn) { $query.login_hint = [string]$Entry.upn }
        $url = "$script:CtxLoginHost/$($Entry.tenantId)/oauth2/v2.0/authorize?" +
            (($query.Keys | ForEach-Object { "$_=$([uri]::EscapeDataString([string]$query[$_]))" }) -join '&')
        Show-CtxSignInStart -Tool $Tool -Entry $Entry -Method 'Browser'
        try { Open-CtxBrowser -Url $url -Entry $Entry }
        catch { Write-Host "     open this address in the browser profile '$($Entry.browserProfile)': $url" -ForegroundColor Cyan }
        $answer = Wait-CtxLoopbackRedirect -Listener $listener -State $state -TimeoutSeconds $TimeoutSeconds
    } finally {
        Stop-CtxLoopbackListener $listener
    }
    if ($answer.Error) {
        $text = if ($answer.Description) { Get-CtxOAuthErrorText ([pscustomobject]@{ error = $answer.Error; error_description = $answer.Description }) } else { $answer.Error }
        if ($answer.Error -eq 'access_denied' -and -not $answer.Description) { throw "$Tool sign-in was declined in the browser." }
        throw "$Tool sign-in failed: $text"
    }
    $t = Invoke-CtxOAuth -TenantId $Entry.tenantId -Endpoint token -Body @{
        grant_type    = 'authorization_code'
        client_id     = $ClientId
        code          = $answer.Code
        redirect_uri  = $redirect
        code_verifier = $pkce.Verifier
        scope         = $Scope
    }
    if (-not $t.access_token) { throw "$Tool sign-in failed: $(Get-CtxOAuthErrorText $t)" }
    $t
}

function Request-CtxGraphBrokerToken {
    <#
    Graph token through the Windows account broker (WAM) of the Graph SDK: Connect-MgGraph with the environment's
    tenant, Graph app, scopes and account as login hint. ctx only takes the access token from that connection and
    disconnects it again; Set-CtxGraphToken then checks tenant, user and scopes before the token is connected.
    #>
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Tool,
        [switch]$Quiet
    )
    if (-not $IsWindows) { throw "$Tool sign-in through the Windows account broker is only available on Windows." }
    Import-CtxGraphModule
    $option = try { Get-MgGraphOption -ErrorAction Stop } catch { $null }
    if ($option -and $option.PSObject.Properties['DisableLoginByWAM'] -and $option.DisableLoginByWAM) {
        throw "$Tool cannot use the Windows account broker: it is disabled for the Graph SDK (Set-MgGraphOption -DisableLoginByWAM `$false enables it)."
    }
    $scopes = @($Scope -split ' ' | Where-Object { $_ -and $_ -notin 'offline_access', 'openid', 'profile' })
    $p = @{ TenantId = $Entry.tenantId; ClientId = $ClientId; Scopes = $scopes; ContextScope = 'Process'; NoWelcome = $true; ErrorAction = 'Stop' }
    if ($Entry.upn -and (Get-Command Connect-MgGraph).Parameters.ContainsKey('LoginHint')) { $p.LoginHint = [string]$Entry.upn }
    if (-not $Quiet) { Show-CtxSignInStart -Tool $Tool -Entry $Entry -Method 'Broker' }
    $token = $null
    try {
        Connect-MgGraph @p | Out-Null
        $response = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/me?$select=id' -OutputType HttpResponseMessage -ErrorAction Stop
        try {
            $auth = $response.RequestMessage.Headers.Authorization
            if ($auth -and $auth.Scheme -ieq 'Bearer') { $token = [string]$auth.Parameter }
        } finally { $response.Dispose() }
    } finally {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }
    if (-not $token) { throw "$Tool sign-in failed: the Windows account broker returned no access token." }
    [pscustomobject]@{ access_token = $token }
}

function Request-CtxGraphInteractiveToken {
    <# One interactive Graph sign-in with the environment's method. Returns @{ Response; Source }. #>
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Tool
    )
    $method = Get-CtxSignInMethod $Entry
    Assert-CtxSignInMethodSupported -Method $method -Entry $Entry
    try {
        $response = switch ($method) {
            'Browser' { Request-CtxGraphBrowserToken -Entry $Entry -ClientId $ClientId -Scope $Scope -Tool $Tool }
            'Broker' { Request-CtxGraphBrokerToken -Entry $Entry -ClientId $ClientId -Scope $Scope -Tool $Tool }
            default { Request-CtxGraphDeviceToken -Entry $Entry -ClientId $ClientId -Scope $Scope -Tool $Tool }
        }
    } catch {
        $hint = Get-CtxSignInFailureHint -Message $_.Exception.Message -Method $method -Entry $Entry
        if ($hint) { throw "$($_.Exception.Message)$hint" }
        throw
    }
    @{ Response = $response; Source = $method }
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
        [ValidateSet('DeviceCode', 'Browser', 'Broker', 'Az', 'Cli')][string]$Source = 'DeviceCode',
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
        # Broker sessions only: lets a failed renewal reconnect the still valid token (memory only, like the SDK's copy).
        AccessToken   = if ($Source -eq 'Broker') { [string]$Response.access_token } else { $null }
    }
    # The SDK may spell an account differently from the identity helper, especially for guest UPNs.
    $context = Get-CtxMgContext
    if ($context) {
        $script:GraphToken.Account = [string]$context.Account
        $script:GraphToken.TokenClientId = [string]$context.ClientId
    }
    if ($Source -in $script:CtxGraphRefreshSources -and $Response.refresh_token -and (Test-CtxGraphCredentialsEnabled $Entry.name)) {
        Save-CtxGraphCredentials -Entry $Entry -ClientId $ClientId -RefreshToken ([string]$Response.refresh_token) -SessionStartedAt $script:GraphToken.SessionStartedAt
    }
}

function Update-CtxGraphToken {
    <#
    Keeps this terminal's ctx Graph session alive when the token expires within MinMinutes: sessions of ctx's own
    sign-ins renew with the in-memory refresh token, sessions from Az, Azure CLI or the broker ask that provider again.
    With -Force, success requires a new token, not just an unexpired old token; after a PIM activation a provider's
    cached token from before the activation does not count. -Quiet defers renewal warnings to the next prompt / ctx
    command. The broker is only asked with -AllowBroker (ctx commands): WAM may show its dialog, which must never pop
    up unannounced from the timer or while the prompt is drawn - those only hint at 'ctx graph' before expiry.
    #>
    param([double]$MinMinutes = 15, [switch]$Quiet, [switch]$Force, [string[]]$Scopes, [switch]$AllowBroker)
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
    $valid = $t.ExpiresAt -gt $now.AddMinutes(1)
    if ($t.Source -eq 'Broker' -and -not $AllowBroker) {
        if (-not $Quiet -and -not $t.Warned) {
            $t.Warned = $true
            $when = if ($valid) { "expires $($t.ExpiresAt.ToLocalTime().ToString('HH:mm'))" } else { 'expired' }
            Write-Host "  ctx: Microsoft Graph token from the Windows account broker $when - 'ctx graph' renews it." -ForegroundColor Yellow
        }
        return $valid
    }
    $scope = if ($Scopes) { Get-CtxGraphScopeString $Scopes } else { $t.Scope }
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
            } elseif ($t.Source -in $script:CtxGraphProviderSources) {
                # Re-read the environment: a PIM activation since the sign-in changes what counts as fresh.
                $current = try { Find-CtxEnvironment (Read-CtxState) $t.Entry.name } catch { $null }
                if (-not $current) { $current = $t.Entry }
                $label = switch ($t.Source) { 'Az' { 'Az PowerShell' } 'Cli' { 'Azure CLI' } default { 'the Windows account broker' } }
                $r = Get-CtxProviderGraphToken -Source $t.Source -Entry $current -ClientId $t.ClientId -Scope $scope
                if (-not $r) {
                    $r = [pscustomobject]@{ error = 'login_required'; error_description = "The matching $label login is no longer available." }
                } elseif ($Force -and $t.Source -ne 'Broker' -and -not (Test-CtxGraphTokenFresh -AccessToken $r.access_token -Entry $current)) {
                    # Az and Azure CLI cannot force-refresh their cached token; do not pretend it is new after PIM.
                    $r = [pscustomobject]@{ error = 'interaction_required'; error_description = "A fresh Graph token is needed; $label returned its cached token from before the PIM activation." }
                } elseif ($Force -and $t.Source -eq 'Broker' -and -not (Test-CtxGraphTokenFresh -AccessToken $r.access_token -Entry $current)) {
                    Write-CtxMsg warn "The Windows account broker returned a Graph token from before the PIM activation; admin calls may need the role until it renews."
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
        if ($t.Source -eq 'Broker' -and $t.AccessToken -and $valid -and -not (Get-CtxMgContext)) {
            # Asking the broker replaced the SDK connection; put the still valid token back.
            try { Connect-CtxGraphToken $t.AccessToken } catch { Write-Debug "ctx: could not reconnect the previous Graph token: $_" }
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
    if (-not (Update-CtxGraphToken -AllowBroker)) { return $false }
    $ctx = Get-CtxMgContext
    if (-not $ctx -or $ctx.TenantId -ine $Entry.tenantId) { return $false }
    if ($script:GraphToken.ObjectId -ine $Entry.userObjectId) { return $false }
    @(Get-CtxMissingGraphScopes -Granted $ctx.Scopes -Required $RequiredScopes).Count -eq 0
}

function Connect-CtxGraphFromLogins {
    <#
    Reuses the environment's Az PowerShell, then Azure CLI login for Graph: official token APIs only, accepted only
    for the same tenant + user with the required scopes and, after a PIM activation (-Refresh), only when the token
    already reflects the activation. $true when a Graph session is connected.
    #>
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$ClientId, [Parameter(Mandatory)][string]$Scope, [switch]$Refresh)
    foreach ($source in 'Az', 'Cli') {
        $label = if ($source -eq 'Az') { 'Az PowerShell' } else { 'Azure CLI' }
        try {
            $cached = Get-CtxProviderGraphToken -Source $source -Entry $Entry
            if (-not $cached) { continue }
            if ($Refresh -and -not (Test-CtxGraphTokenFresh -AccessToken $cached.access_token -Entry $Entry)) {
                Write-CtxMsg dim "The $label Graph token is from before the PIM activation."
                continue
            }
            Set-CtxGraphToken -Response $cached -Entry $Entry -ClientId $ClientId -Scope $Scope -Source $source
            Write-CtxMsg dim "Microsoft Graph is using the matching $label login (no sign-in needed)."
            return $true
        } catch { Write-CtxMsg dim "The $label Graph token cannot be used: $($_.Exception.Message)" }
    }
    $false
}

function Connect-CtxGraphSession {
    <#
    Asks every existing login of the environment for a suitable token (this terminal's session, saved credentials,
    Az PowerShell, Azure CLI) before one interactive sign-in with the environment's method.
    #>
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
        $usable = Update-CtxGraphToken -Quiet -AllowBroker
        $t = $script:GraphToken
        if ($t) {
            if (-not $usable -and $t.LastError -and $t.ErrorCode -notin 'interaction_required', 'consent_required', 'login_required', 'invalid_grant') {
                throw "Microsoft Graph token renewal failed: $($t.LastError)"
            }
            $missing = @(Get-CtxMissingGraphScopes -Granted $t.Scopes -Required $Scopes)
            if (-not $Refresh -and $usable -and -not $missing.Count -and ($t.Scope -eq $scope -or $t.Source -in $script:CtxGraphProviderSources)) {
                $t.Scope = $scope
                $ready = $true
            } else {
                $ready = Update-CtxGraphToken -Force -Scopes $Scopes -Quiet -AllowBroker
                if (-not $ready -and $t.ErrorCode -notin 'interaction_required', 'consent_required', 'login_required', 'invalid_grant') {
                    throw "Microsoft Graph token renewal failed: $($t.LastError)"
                }
                if (-not $ready) { Write-CtxMsg dim "Microsoft Graph needs a new sign-in: $($t.LastError)" }
            }
        }
    }
    if (-not $ready -and -not $Relogin) {
        $ready = Restore-CtxGraphCredentials -Entry $Entry -ClientId $clientId -Scope $scope
    }
    if (-not $ready -and -not $Relogin -and -not $Entry.graphClientId) {
        $ready = Connect-CtxGraphFromLogins -Entry $Entry -ClientId $clientId -Scope $scope -Refresh:$Refresh
    }
    if (-not $ready) {
        $signIn = Request-CtxGraphInteractiveToken -Entry $Entry -ClientId $clientId -Scope $scope -Tool "Microsoft Graph ($Label)"
        Set-CtxGraphToken -Response $signIn.Response -Entry $Entry -ClientId $clientId -Scope $scope -Source $signIn.Source
    }
    $script:GraphEnvName = $Entry.name
    $script:GraphProfileName = $Label
    if ($script:GraphToken.RefreshToken -or $script:GraphToken.Source -in $script:CtxGraphProviderSources) { Start-CtxGraphRenewal }
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
