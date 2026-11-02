# Optional, per-environment storage of the Graph refresh token (ctx set <name> -SaveGraphCredentials On). Off by default.
# The refresh token is encrypted in <data folder>/graph/<name>.dat and only restored by a Graph connect (ctx <name>
# -Admin, ctx pim, ctx graph). Access tokens are never stored. Windows: DPAPI (current user, this device). Linux/macOS:
# AES-256-CBC + HMAC-SHA256 (encrypt-then-MAC) with a random per-user key kept in the macOS Keychain or the Secret
# Service (secret-tool), or - only with 'ctx config graphCredentialStore file' - in a file readable only by the user.

$script:CtxGraphCredentialEntropy = [Text.Encoding]::UTF8.GetBytes('ctx.graph.credentials.v1')
$script:CtxSecretKey = $null
$script:CtxSecretKeyService = 'ctx.graph-credentials'
$script:CtxSecretPrefix = 'aes1:'

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

function Get-CtxSecretStoreKind {
    <# Where the Linux/macOS key lives: keychain, secret-service or file; $null when no store is usable. Windows uses DPAPI. #>
    if ($IsWindows) { return 'dpapi' }
    if ([string](Get-CtxConfig).graphCredentialStore -ieq 'file') { return 'file' }
    if ($IsMacOS -and (Get-Command security -CommandType Application -ErrorAction SilentlyContinue)) { return 'keychain' }
    if ($IsLinux -and (Get-Command secret-tool -CommandType Application -ErrorAction SilentlyContinue)) { return 'secret-service' }
    $null
}

function Get-CtxSecretStoreProblem {
    <# Why saved Graph credentials cannot be used on this device; $null when they can. #>
    $kind = Get-CtxSecretStoreKind
    if (-not $kind) {
        return 'no keyring found - install secret-tool (libsecret) with a running Secret Service (GNOME Keyring, KWallet), or opt in to a key file: ctx config graphCredentialStore file'
    }
    if ($kind -in 'dpapi', 'file') { return $null }
    try { $null = Get-CtxSecretKey -Create; $null } catch { "the keyring cannot be used ($($_.Exception.Message)) - or opt in to a key file: ctx config graphCredentialStore file" }
}

function Get-CtxSecretKeyFile { Join-Path (Join-Path (Get-CtxHome) 'graph') '.key' }

function Read-CtxSecretKeyHex {
    param([Parameter(Mandatory)][string]$Kind)
    $PSNativeCommandUseErrorActionPreference = $false
    $out = switch ($Kind) {
        'keychain' { & security find-generic-password -a ctx -s $script:CtxSecretKeyService -w 2>$null }
        'secret-service' { & secret-tool lookup service ctx key $script:CtxSecretKeyService 2>$null }
        'file' { $f = Get-CtxSecretKeyFile; if (Test-Path -LiteralPath $f) { [IO.File]::ReadAllText($f) } }
    }
    if ($Kind -ne 'file' -and $LASTEXITCODE -ne 0) { return $null }
    $hex = ([string]($out -join '')).Trim()
    if ($hex -match '^[0-9A-Fa-f]{64}$') { $hex } else { $null }
}

function Write-CtxSecretKeyHex {
    <# Stores the key; the secret goes through stdin, never on a command line that other processes could list. #>
    param([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Hex)
    $PSNativeCommandUseErrorActionPreference = $false
    switch ($Kind) {
        'keychain' { "add-generic-password -U -a ctx -s $($script:CtxSecretKeyService) -l ctx-graph-credentials-key -w $Hex" | & security -i 2>$null | Out-Null }
        'secret-service' { $Hex | & secret-tool store --label=ctx-graph-credentials-key service ctx key $script:CtxSecretKeyService 2>$null | Out-Null }
        'file' {
            $f = Get-CtxSecretKeyFile
            $dir = Split-Path -Parent $f
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [IO.File]::WriteAllText($f, '')
            Set-CtxPrivateMode -Path $f
            [IO.File]::WriteAllText($f, $Hex)
        }
    }
}

function Get-CtxSecretKey {
    <# The 32-byte key of saved credentials on Linux/macOS (cached per process). -Create makes and stores one when missing. #>
    param([switch]$Create)
    if ($script:CtxSecretKey) { return , $script:CtxSecretKey }
    $kind = Get-CtxSecretStoreKind
    if (-not $kind -or $kind -eq 'dpapi') {
        if ($Create) { throw 'no keyring found (secret-tool / Keychain)' }
        return $null
    }
    $hex = Read-CtxSecretKeyHex $kind
    if (-not $hex -and $Create) {
        $bytes = [byte[]]::new(32)
        [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        Write-CtxSecretKeyHex -Kind $kind -Hex ([Convert]::ToHexString($bytes))
        $hex = Read-CtxSecretKeyHex $kind
        if (-not $hex) { throw "the key could not be stored ($kind)" }
    }
    if (-not $hex) { return $null }
    $script:CtxSecretKey = [Convert]::FromHexString($hex)
    , $script:CtxSecretKey
}

function Get-CtxSecretSubKeys {
    param([Parameter(Mandatory)][byte[]]$Key)
    $h = [Security.Cryptography.HMACSHA256]::new($Key)
    try {
        @{ Enc = $h.ComputeHash([Text.Encoding]::ASCII.GetBytes('ctx graph credentials encryption')); Mac = $h.ComputeHash([Text.Encoding]::ASCII.GetBytes('ctx graph credentials authentication')) }
    } finally { $h.Dispose() }
}

function Protect-CtxBytes {
    <# AES-256-CBC, then HMAC-SHA256 over context + IV + ciphertext (encrypt-then-MAC). #>
    param([Parameter(Mandatory)][byte[]]$Plain, [Parameter(Mandatory)][byte[]]$Key)
    $k = Get-CtxSecretSubKeys $Key
    $aes = [Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = $k.Enc
        $aes.GenerateIV()
        $enc = $aes.CreateEncryptor()
        try { $cipher = $enc.TransformFinalBlock($Plain, 0, $Plain.Length) } finally { $enc.Dispose() }
        $body = [byte[]]($aes.IV + $cipher)
    } finally { $aes.Dispose() }
    $mac = [Security.Cryptography.HMACSHA256]::new($k.Mac)
    try { $tag = $mac.ComputeHash([byte[]]($script:CtxGraphCredentialEntropy + $body)) } finally { $mac.Dispose() }
    [Convert]::ToBase64String([byte[]]($body + $tag))
}

function Unprotect-CtxBytes {
    param([Parameter(Mandatory)][string]$Protected, [Parameter(Mandatory)][byte[]]$Key)
    $all = [Convert]::FromBase64String($Protected)
    if ($all.Length -lt 16 + 16 + 32) { throw 'The protected data is too short.' }
    $body = [byte[]]$all[0..($all.Length - 33)]
    $tag = [byte[]]$all[($all.Length - 32)..($all.Length - 1)]
    $k = Get-CtxSecretSubKeys $Key
    $mac = [Security.Cryptography.HMACSHA256]::new($k.Mac)
    try { $expected = $mac.ComputeHash([byte[]]($script:CtxGraphCredentialEntropy + $body)) } finally { $mac.Dispose() }
    if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($expected, $tag)) { throw 'The protected data was changed or belongs to another key.' }
    $aes = [Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = $k.Enc
        $aes.IV = [byte[]]$body[0..15]
        $dec = $aes.CreateDecryptor()
        try { $plain = $dec.TransformFinalBlock($body, 16, $body.Length - 16) } finally { $dec.Dispose() }
    } finally { $aes.Dispose() }
    , $plain
}

function Protect-CtxText {
    param([Parameter(Mandatory)][string]$Text)
    $plain = [Text.Encoding]::UTF8.GetBytes($Text)
    if ($IsWindows) {
        $bytes = [System.Security.Cryptography.ProtectedData]::Protect($plain, $script:CtxGraphCredentialEntropy,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [Convert]::ToBase64String($bytes)
    }
    $script:CtxSecretPrefix + (Protect-CtxBytes -Plain $plain -Key (Get-CtxSecretKey -Create))
}

function Unprotect-CtxText {
    param([Parameter(Mandatory)][string]$Protected)
    if ($Protected.StartsWith($script:CtxSecretPrefix)) {
        $key = Get-CtxSecretKey
        if (-not $key) { throw 'The key of the saved Graph credentials is not available.' }
        return [Text.Encoding]::UTF8.GetString((Unprotect-CtxBytes -Protected $Protected.Substring($script:CtxSecretPrefix.Length) -Key $key))
    }
    if (-not $IsWindows) { throw 'These credentials were protected with Windows DPAPI.' }
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
            Write-CtxMsg dim 'Microsoft Graph restored from the saved credentials (no sign-in needed).'
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
