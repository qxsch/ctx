# Az PowerShell: one named context ("ctx:<name>") per environment, persisted with context autosave (CurrentUser).

$script:AzAutosaveChecked = $false
$script:AzProfileStamp = $null

function Test-CtxAzAvailable {
    [bool](Get-Module Az.Accounts) -or [bool](Get-Module -ListAvailable Az.Accounts)
}

function Import-CtxAzModule {
    if (-not (Get-Module Az.Accounts)) {
        try {
            Import-Module Az.Accounts -ErrorAction Stop -WarningAction SilentlyContinue -Verbose:$false | Out-Null
        } catch {
            throw "Az.Accounts module could not be loaded: $($_.Exception.Message). Install with (elevated): Install-PSResource Az.Accounts -Scope AllUsers"
        }
    }
    if (-not $script:AzAutosaveChecked) {
        $setting = Get-AzContextAutosaveSetting -WarningAction SilentlyContinue
        if ($setting.Mode -ne 'CurrentUser') {
            Enable-AzContextAutosave -Scope CurrentUser -WarningAction SilentlyContinue | Out-Null
        }
        # No interactive subscription picker during device-code logins (this process only).
        try { Update-AzConfig -LoginExperienceV2 Off -Scope Process -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null }
        catch { Write-Debug "ctx: Update-AzConfig -LoginExperienceV2 is not supported by this Az.Accounts: $_" }
        $script:AzAutosaveChecked = $true
    }
}

function Get-CtxAzAutosaveMode {
    (Get-AzContextAutosaveSetting -WarningAction SilentlyContinue).Mode
}

function Get-CtxAzContextNames {
    @(Get-AzContext -ListAvailable -WarningAction SilentlyContinue | ForEach-Object Name)
}

function Get-CtxAzContextFile {
    $s = Get-AzContextAutosaveSetting -WarningAction SilentlyContinue
    if ($s.Mode -ne 'CurrentUser') { return $null }
    Join-Path $s.ContextDirectory $s.ContextFile
}

function Sync-CtxAzProfileFromDisk {
    <#
    Az keeps contexts in memory per session. Reload the autosave file when another terminal changed it,
    so CurrentUser writes from this session never drop contexts created elsewhere.
    #>
    param([switch]$Force)
    $file = Get-CtxAzContextFile
    if (-not $file -or -not (Test-Path -LiteralPath $file)) { return }
    $stamp = [IO.File]::GetLastWriteTimeUtc($file)
    if ($Force -or $script:AzProfileStamp -ne $stamp) {
        $current = Get-AzContext -ErrorAction SilentlyContinue
        Import-AzContext -Path $file -Scope Process -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        # Import resets the process default to the file's default; keep this session's selection.
        if ($current -and $current.Name) {
            $match = Get-AzContext -ListAvailable -WarningAction SilentlyContinue | Where-Object Name -EQ $current.Name | Select-Object -First 1
            if ($match) { Select-AzContext -Name $current.Name -Scope Process -WarningAction SilentlyContinue | Out-Null }
        }
        $script:AzProfileStamp = [IO.File]::GetLastWriteTimeUtc($file)
    }
}

function Update-CtxAzProfileStamp {
    $file = Get-CtxAzContextFile
    if ($file -and (Test-Path -LiteralPath $file)) { $script:AzProfileStamp = [IO.File]::GetLastWriteTimeUtc($file) }
}

function Get-CtxAzNamedContext {
    param([Parameter(Mandatory)][string]$ContextName)
    Get-AzContext -ListAvailable -WarningAction SilentlyContinue | Where-Object { $_.Name -eq $ContextName } | Select-Object -First 1
}

function Get-CtxAzIdentity {
    param([Parameter(Mandatory)][string]$TenantId)
    $t = Get-AzAccessToken -TenantId $TenantId -ErrorAction Stop -WarningAction SilentlyContinue
    Get-CtxIdentityFromClaims (ConvertFrom-CtxJwt (ConvertFrom-CtxSecureToken $t.Token))
}

function Connect-CtxAz {
    <#
    Device-code login into a named context. The context is always persisted (CurrentUser) so the login survives;
    with -Scope Process the user-wide default context is put back to the global ctx environment afterwards.
    Returns the identity from the token.
    #>
    param(
        [Parameter(Mandatory)]$Entry,
        [ValidateSet('Process', 'CurrentUser')][string]$Scope = 'CurrentUser',
        [string]$Tenant
    )
    Import-CtxAzModule
    Sync-CtxAzProfileFromDisk
    $t = if ($Tenant) { $Tenant } elseif ($Entry.tenantId) { $Entry.tenantId } else { $null }
    $p = @{
        UseDeviceAuthentication = $true
        ContextName             = $Entry.azContextName
        Force                   = $true
        SkipContextPopulation   = $true
        Scope                   = 'CurrentUser'
        ErrorAction             = 'Stop'
        WarningAction           = 'SilentlyContinue'
    }
    if ($t) { $p.Tenant = $t }
    $sb = { Connect-AzAccount @p }.GetNewClosure()
    Invoke-CtxDeviceLogin -ScriptBlock $sb -Entry $Entry -Tool 'Az PowerShell' | Out-Null
    if ($Scope -eq 'Process') {
        $state = Read-CtxState
        $global = Find-CtxEnvironment $state $state.current
        if ($global -and $global.name -ne $Entry.name -and (Get-CtxAzNamedContext $global.azContextName)) {
            Select-AzContext -Name $global.azContextName -Scope CurrentUser -WarningAction SilentlyContinue | Out-Null
        }
        Select-AzContext -Name $Entry.azContextName -Scope Process -WarningAction SilentlyContinue | Out-Null
    }
    Update-CtxAzProfileStamp
    $tenantId = if ($Entry.tenantId) { $Entry.tenantId } else { (Get-AzContext).Tenant.Id }
    Get-CtxAzIdentity -TenantId $tenantId
}

function Save-CtxAzPosition {
    <# Returns the subscription the user is currently on for this environment (only if Az is already loaded). #>
    param([Parameter(Mandatory)]$Entry)
    if (-not (Get-Module Az.Accounts)) { return $null }
    $c = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $c -or -not $c.Tenant -or $c.Tenant.Id -ine $Entry.tenantId) { return $null }
    if ($Entry.upn -and $c.Account -and $c.Account.Id -ine $Entry.upn) { return $null }
    if (-not $c.Subscription -or -not $c.Subscription.Id -or $c.Subscription.Id -ieq $Entry.tenantId) { return $null }
    [pscustomobject]@{ Id = $c.Subscription.Id; Name = $c.Subscription.Name }
}

function Set-CtxAzSubscription {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$SubscriptionId, [ValidateSet('Process', 'CurrentUser')][string]$Scope = 'CurrentUser')
    Import-CtxAzModule
    Sync-CtxAzProfileFromDisk
    Set-AzContext -Subscription $SubscriptionId -Tenant $Entry.tenantId -Name $Entry.azContextName -Force -Scope $Scope -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
    Update-CtxAzProfileStamp
}

function Set-CtxAzEnvironment {
    <# Selects (or restores via device code) the environment's Az context and aligns the subscription. #>
    param(
        [Parameter(Mandatory)]$Entry,
        [ValidateSet('Process', 'CurrentUser')][string]$Scope = 'CurrentUser',
        [switch]$NoVerify,
        [switch]$Relogin
    )
    Import-CtxAzModule
    Sync-CtxAzProfileFromDisk
    $name = $Entry.azContextName
    $reason = $null
    $ctx = Get-CtxAzNamedContext $name
    if ($Relogin) {
        $reason = 'sign-in requested'
    } elseif (-not $ctx) {
        $reason = 'no saved context'
    } else {
        Select-AzContext -Name $name -Scope $Scope -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        Update-CtxAzProfileStamp
        if (-not $NoVerify) {
            try {
                $id = Get-CtxAzIdentity -TenantId $Entry.tenantId
                if (-not (Test-CtxIdentityMatch $Entry $id)) { $reason = "context is signed in as '$($id.Upn)'" }
            } catch {
                $reason = 'session expired'
            }
        }
    }
    if ($reason) {
        Write-CtxMsg warn "Az PowerShell: $reason - signing in with device code"
        $id = Connect-CtxAz -Entry $Entry -Scope $Scope
        if (-not (Test-CtxIdentityMatch $Entry $id)) {
            throw "Az PowerShell signed in as '$($id.Upn)' but environment '$($Entry.name)' is $($Entry.upn). Sign in with the right account."
        }
    }
    if ($Entry.azSubscriptionId) {
        $cur = Get-AzContext
        if (-not $cur.Subscription -or $cur.Subscription.Id -ine $Entry.azSubscriptionId) {
            try { Set-CtxAzSubscription -Entry $Entry -SubscriptionId $Entry.azSubscriptionId -Scope $Scope }
            catch { Write-CtxMsg warn "Az PowerShell: subscription $($Entry.azSubscriptionId) not available ($($_.Exception.Message))" }
        }
    }
    $cur = Get-AzContext
    [pscustomobject]@{
        Ok               = $true
        SubscriptionId   = if ($cur.Subscription) { $cur.Subscription.Id } else { $null }
        SubscriptionName = if ($cur.Subscription) { $cur.Subscription.Name } else { $null }
        Account          = if ($cur.Account) { $cur.Account.Id } else { $null }
    }
}
