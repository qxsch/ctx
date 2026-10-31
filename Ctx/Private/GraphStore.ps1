# Optional, per-environment storage of the Graph refresh token (ctx set <name> -SaveGraphCredentials On). Off by default.
# The refresh token is encrypted with DPAPI (current user, this device only) in %LOCALAPPDATA%\ctx\graph\<name>.dat and is
# only restored by a Graph connect (ctx <name> -Admin, ctx pim, ctx graph). Access tokens are never stored.

$script:CtxGraphCredentialEntropy = [Text.Encoding]::UTF8.GetBytes('ctx.graph.credentials.v1')

function Get-CtxGraphMaxSessionHours {
    $hours = 0.0
    [void][double]::TryParse([string](Get-CtxConfig).graphMaxSessionHours, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$hours)
    $hours
}

function Get-CtxGraphCredentialPath {
    <# One file per environment. The name is validated again because the state file is not trusted to hold safe file names. #>
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -notmatch '^[a-z0-9][a-z0-9-]{0,31}$') { throw "Invalid environment name '$(ConvertTo-CtxSafeText $Name -MaxLength 40)'." }
    Join-Path (Join-Path (Get-CtxHome) 'graph') "$Name.dat"
}

function Test-CtxGraphCredentialsEnabled {
    param([Parameter(Mandatory)][string]$Name)
    try {
        $e = Find-CtxEnvironment (Get-CtxStateCached) $Name
        [bool]($e -and $e.saveGraphCredentials -eq $true)
    } catch { $false }
}

function Protect-CtxText {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [System.Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($Text), $script:CtxGraphCredentialEntropy,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    [Convert]::ToBase64String($bytes)
}

function Unprotect-CtxText {
    param([Parameter(Mandatory)][string]$Protected)
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Protected), $script:CtxGraphCredentialEntropy,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    [Text.Encoding]::UTF8.GetString($bytes)
}

function Read-CtxGraphCredentialFile {
    <# Decrypts the saved credentials; $null when there are none or they are unreadable (corrupt, other user or other device). #>
    param([Parameter(Mandatory)][string]$Name)
    $path = Get-CtxGraphCredentialPath $Name
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $data = Unprotect-CtxText ([IO.File]::ReadAllText($path).Trim()) | ConvertFrom-Json -AsHashtable
        if ($data -is [System.Collections.IDictionary] -and $data['version'] -eq 1 -and $data['refreshToken']) { $data }
    } catch { Write-Debug "ctx: unreadable saved Graph credentials '$path': $_" }
}

function Save-CtxGraphCredentials {
    <# Encrypts and stores the session's refresh token. Never throws: a failure only means nothing is restored later. #>
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$RefreshToken,
        [Parameter(Mandatory)][datetime]$SessionStartedAt
    )
    try {
        $path = Get-CtxGraphCredentialPath $Entry.name
        $content = Protect-CtxText ([ordered]@{
                version          = 1
                tenantId         = $Entry.tenantId
                userObjectId     = $Entry.userObjectId
                clientId         = $ClientId
                refreshToken     = $RefreshToken
                sessionStartedAt = ConvertTo-CtxIsoDate $SessionStartedAt
                savedAt          = ConvertTo-CtxIsoDate ([datetime]::UtcNow)
            } | ConvertTo-Json -Compress)
        Invoke-CtxLocked {
            $dir = Split-Path -Parent $path
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Write-CtxFileAtomic -Path $path -Content $content
        }
    } catch {
        if (-not $script:GraphSaveWarned) {
            $script:GraphSaveWarned = $true
            Write-CtxMsg warn "Graph credentials of '$($Entry.name)' could not be saved: $($_.Exception.Message)"
        }
    }
}

function Remove-CtxGraphCredentials {
    <# Deletes the saved credentials of an environment. With -RefreshToken only when the file holds exactly that token (another terminal may have saved a newer one). #>
    param([Parameter(Mandatory)][string]$Name, [string]$RefreshToken)
    try {
        $path = Get-CtxGraphCredentialPath $Name
        if (-not (Test-Path -LiteralPath $path)) { return }
        if ($RefreshToken) {
            $saved = Read-CtxGraphCredentialFile $Name
            if ($saved -and $saved['refreshToken'] -cne $RefreshToken) { return }
        }
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
    } catch {
        Write-CtxMsg warn "Saved Graph credentials of '$Name' could not be deleted: $($_.Exception.Message)"
    }
}

function Move-CtxGraphCredentials {
    param([Parameter(Mandatory)][string]$OldName, [Parameter(Mandatory)][string]$NewName)
    try {
        $old = Get-CtxGraphCredentialPath $OldName
        if (-not (Test-Path -LiteralPath $old)) { return }
        Move-Item -LiteralPath $old -Destination (Get-CtxGraphCredentialPath $NewName) -Force -ErrorAction Stop
    } catch {
        Write-CtxMsg warn "Saved Graph credentials could not follow the rename to '$NewName' ($($_.Exception.Message)); the next Graph sign-in saves them again."
    }
}

function Get-CtxGraphCredentialInfo {
    <# Read-only summary of the saved credentials for status and doctor. $null when nothing is saved. #>
    param([Parameter(Mandatory)]$Entry)
    $saved = Read-CtxGraphCredentialFile $Entry.name
    if (-not $saved) { return $null }
    $started = try { ConvertTo-CtxDate $saved['sessionStartedAt'] } catch { $null }
    $savedAt = try { ConvertTo-CtxDate $saved['savedAt'] } catch { $null }
    $maxHours = Get-CtxGraphMaxSessionHours
    $until = if ($started -and $maxHours -gt 0) { $started.AddHours($maxHours) } else { $null }
    [pscustomobject]@{
        SavedAt         = $savedAt
        RestorableUntil = $until
        Expired         = [bool]($until -and $until -le [datetime]::UtcNow)
    }
}

function Get-CtxSavedGraphCredentials {
    <# Saved credentials that may be used for this login and Graph client. Unusable files (other login or client, past graphMaxSessionHours) are deleted. #>
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$ClientId)
    if (-not (Test-Path -LiteralPath (Get-CtxGraphCredentialPath $Entry.name))) { return $null }
    $saved = Read-CtxGraphCredentialFile $Entry.name
    $started = if ($saved) { try { ConvertTo-CtxDate $saved['sessionStartedAt'] } catch { $null } }
    $why = $null
    if (-not $saved -or -not $started) {
        $why = 'unreadable'
    } elseif ([string]$saved['tenantId'] -ine $Entry.tenantId -or [string]$saved['userObjectId'] -ine $Entry.userObjectId -or [string]$saved['clientId'] -ine $ClientId) {
        $why = 'for another login or Graph app'
    } else {
        $maxHours = Get-CtxGraphMaxSessionHours
        if ($maxHours -gt 0 -and [datetime]::UtcNow -ge $started.AddHours($maxHours)) { $why = "older than graphMaxSessionHours ($maxHours h)" }
    }
    if ($why) {
        Write-CtxMsg dim "Saved Graph credentials are $why and were removed."
        Remove-CtxGraphCredentials -Name $Entry.name
        return $null
    }
    [pscustomobject]@{ RefreshToken = [string]$saved['refreshToken']; SessionStartedAt = $started }
}

function Restore-CtxGraphCredentials {
    <# Silent Graph sign-in with the credentials saved for this environment. $true when a Graph session is connected. #>
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$ClientId, [Parameter(Mandatory)][string]$Scope)
    if ($Entry.saveGraphCredentials -ne $true) { return $false }
    $saved = Get-CtxSavedGraphCredentials -Entry $Entry -ClientId $ClientId
    if (-not $saved) { return $false }
    try {
        $r = Invoke-CtxOAuth -TenantId $Entry.tenantId -Endpoint token -TimeoutSec 15 -Body @{
            grant_type    = 'refresh_token'
            client_id     = $ClientId
            refresh_token = $saved.RefreshToken
            scope         = $Scope
        }
    } catch { $r = [pscustomobject]@{ error = 'network'; error_description = $_.Exception.Message } }
    if ($r.access_token) {
        try {
            Set-CtxGraphToken -Response $r -Entry $Entry -ClientId $ClientId -Scope $Scope -PreviousRefreshToken $saved.RefreshToken -SessionStartedAt $saved.SessionStartedAt
            Write-CtxMsg dim 'Microsoft Graph restored from the saved credentials (no device code).'
            return $true
        } catch {
            $code = if ($_.Exception.Data['CtxOAuthError']) { $_.Exception.Data['CtxOAuthError'] } else { 'token_validation' }
            $r = [pscustomobject]@{ error = $code; error_description = $_.Exception.Message }
        }
    }
    # A token for another account means the file does not belong to this environment.
    if ($r.error -eq 'token_validation') { Remove-CtxGraphCredentials -Name $Entry.name -RefreshToken $saved.RefreshToken }
    Write-CtxMsg dim "Saved Graph credentials could not be used ($(Get-CtxOAuthErrorText $r))."
    $false
}
