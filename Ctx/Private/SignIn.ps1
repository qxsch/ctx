# Sign-in methods per environment (DeviceCode by default, Browser or Broker when set) and the helpers of the
# browser flow: PKCE, loopback redirect listener and the freshness check for tokens reused after a PIM activation.

function ConvertTo-CtxSignInMethod {
    <# Canonical method name for a case-insensitive value; $null for empty or unknown values. #>
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if (-not $Value) { return $null }
    $script:CtxSignInMethods | Where-Object { $_ -ieq $Value.Trim() } | Select-Object -First 1
}

function Get-CtxSignInMethod {
    <# The method the environment signs in with: its own setting, otherwise device code. Never chosen automatically. #>
    param($Entry)
    $m = if ($Entry) { ConvertTo-CtxSignInMethod ([string]$Entry.signIn) } else { $null }
    if ($m) { $m } else { 'DeviceCode' }
}

function Get-CtxSignInLabel {
    param([Parameter(Mandatory)][string]$Method)
    switch ($Method) {
        'Browser' { 'in the browser' }
        'Broker' { 'through the Windows account broker' }
        default { 'with device code' }
    }
}

function Get-CtxSignInFixCommand {
    <# 'ctx set <name>' for existing environments, 'ctx add <name>' while an environment is being created. #>
    param([Parameter(Mandatory)]$Entry)
    $exists = try { [bool](Find-CtxEnvironment (Read-CtxState) $Entry.name) } catch { $false }
    if ($exists) { "ctx set $($Entry.name)" } else { "ctx add $($Entry.name)" }
}

function Assert-CtxSignInMethodSupported {
    <# Throws when the method cannot work on this device or in this session. ctx never switches to another method by itself. #>
    param([Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)]$Entry)
    if ($Method -eq 'Broker' -and -not $IsWindows) {
        throw "'$($Entry.name)' signs in through the Windows account broker, which is only available on Windows. Choose another method: $(Get-CtxSignInFixCommand $Entry) -SignIn Browser (or DeviceCode)"
    }
    if ($Method -eq 'Browser' -and -not (Test-CtxCanOpenBrowser)) {
        throw "'$($Entry.name)' signs in in the browser, but this session cannot open one (SSH or no display). Sign in from a desktop session, or choose: $(Get-CtxSignInFixCommand $Entry) -SignIn DeviceCode"
    }
}

function Get-CtxSignInFailureHint {
    <# Explains failures that a different sign-in method or app registration fixes. Empty when there is nothing to add. #>
    param([AllowNull()][string]$Message, [Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)]$Entry)
    if (-not $Message) { return '' }
    $fix = Get-CtxSignInFixCommand $Entry
    if ($Method -eq 'DeviceCode' -and $Message -match 'AADSTS53003|AADSTS50097|device code flow is blocked|DeviceCodeFlow') {
        $alternatives = if ($IsWindows) { 'Browser or Broker' } else { 'Browser' }
        return " - Conditional Access may block device code sign-in for this tenant. Use $($alternatives): $fix -SignIn Browser"
    }
    if ($Message -match 'AADSTS50011' -and $Entry.graphClientId) {
        $uri = if ($Method -eq 'Broker') { "ms-appx-web://microsoft.aad.brokerplugin/$($Entry.graphClientId)" } else { 'http://localhost' }
        return " - add the redirect URI '$uri' (Mobile and desktop applications) to the Graph app $($Entry.graphClientId), or use: $fix -SignIn DeviceCode"
    }
    ''
}

function Show-CtxSignInStart {
    <# Header for browser and broker sign-ins (device codes have their own box in Show-CtxDeviceCode). #>
    param([Parameter(Mandatory)][string]$Tool, [Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$Method, [string]$Detail)
    $who = if ($Entry.upn) { " as $($Entry.upn)" } else { '' }
    Write-Host ''
    Write-Host "  ┌─ $Tool sign-in for '$($Entry.name)'$who" -ForegroundColor Cyan
    $text = if ($Detail) { $Detail } elseif ($Method -eq 'Broker') { 'Windows account broker - pick the account in its dialog' } else { "browser profile '$($Entry.browserProfile)' - finish the sign-in there" }
    Write-Host "  └─ $text - waiting…" -ForegroundColor Cyan
}

function Test-CtxGraphTokenFresh {
    <#
    After a PIM activation a reused token only counts when it already carries the active roles: its wids claim lists
    them or, without wids, it was issued after each activation started (both times come from Microsoft's servers).
    #>
    param([Parameter(Mandatory)][string]$AccessToken, [Parameter(Mandatory)]$Entry)
    $claims = try { ConvertFrom-CtxJwt $AccessToken } catch { return $false }
    $active = @(Get-CtxActiveActivations $Entry | Where-Object { $_.RoleId })
    if (-not $active.Count) { return $false }
    $hasWids = [bool]$claims.PSObject.Properties['wids']
    $wids = @($claims.wids | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $issued = if ($claims.iat) { [DateTimeOffset]::FromUnixTimeSeconds([long]$claims.iat).UtcDateTime } else { $null }
    foreach ($a in $active) {
        if ($hasWids) {
            if ($wids -notcontains ([string]$a.RoleId).ToLowerInvariant()) { return $false }
        } elseif (-not $issued -or -not $a.StartedAt -or $issued -lt $a.StartedAt) {
            return $false
        }
    }
    $true
}

function ConvertTo-CtxBase64Url {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-CtxRandomString {
    param([int]$Bytes = 32)
    $buffer = [byte[]]::new($Bytes)
    [Security.Cryptography.RandomNumberGenerator]::Fill($buffer)
    ConvertTo-CtxBase64Url $buffer
}

function New-CtxPkce {
    <# RFC 7636 S256: the verifier never leaves this process; the browser only sees its hash. #>
    $verifier = New-CtxRandomString 32
    $challenge = ConvertTo-CtxBase64Url ([Security.Cryptography.SHA256]::HashData([Text.Encoding]::ASCII.GetBytes($verifier)))
    [pscustomobject]@{ Verifier = $verifier; Challenge = $challenge }
}

function ConvertFrom-CtxQueryString {
    param([AllowEmptyString()][string]$Query)
    $result = @{}
    foreach ($pair in ($Query.TrimStart('?') -split '&')) {
        if (-not $pair) { continue }
        $k, $v = $pair -split '=', 2
        $key = [uri]::UnescapeDataString($k.Replace('+', ' '))
        if ($result.ContainsKey($key)) { continue }
        $result[$key] = if ($null -ne $v) { [uri]::UnescapeDataString($v.Replace('+', ' ')) } else { '' }
    }
    $result
}

function ConvertFrom-CtxLoopbackRequest {
    <# Parses 'GET /path?query HTTP/1.1'. Anything else (other methods, absolute targets, huge lines) is $null. #>
    param([AllowNull()][string]$RequestLine)
    if (-not $RequestLine -or $RequestLine.Length -gt 16384) { return $null }
    $m = [regex]::Match($RequestLine, '^GET (?<target>/\S*) HTTP/1\.[01]$')
    if (-not $m.Success) { return $null }
    $target = $m.Groups['target'].Value
    $path, $query = $target -split '\?', 2
    [pscustomobject]@{ Path = $path; Query = ConvertFrom-CtxQueryString ([string]$query) }
}

function Start-CtxLoopbackListener {
    <# Listens on 127.0.0.1 and, when possible, ::1 on the same free port (browsers may resolve localhost to either). #>
    $v4 = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $v4.Start()
    $port = ([Net.IPEndPoint]$v4.LocalEndpoint).Port
    $listeners = [System.Collections.Generic.List[Net.Sockets.TcpListener]]::new()
    $listeners.Add($v4)
    if ([Net.Sockets.Socket]::OSSupportsIPv6) {
        try {
            $v6 = [Net.Sockets.TcpListener]::new([Net.IPAddress]::IPv6Loopback, $port)
            $v6.Start()
            $listeners.Add($v6)
        } catch { Write-Debug "ctx: no IPv6 loopback listener: $_" }
    }
    [pscustomobject]@{ Port = $port; Listeners = $listeners }
}

function Stop-CtxLoopbackListener {
    param($Listener)
    foreach ($l in @($Listener.Listeners)) { try { $l.Stop() } catch { Write-Debug "ctx: could not stop the loopback listener: $_" } }
}

function Send-CtxLoopbackResponse {
    param([Parameter(Mandatory)]$Stream, [int]$Status = 200, [Parameter(Mandatory)][string]$Message)
    $reason = switch ($Status) { 200 { 'OK' } 400 { 'Bad Request' } default { 'Not Found' } }
    # Static text only: nothing from the request is reflected into the page.
    $body = "<!DOCTYPE html><html><head><meta charset=`"utf-8`"><title>ctx</title></head><body style=`"font-family:sans-serif;margin:3em`"><h2>ctx</h2><p>$Message</p></body></html>"
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $head = "HTTP/1.1 $Status $reason`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
    $headBytes = [Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($headBytes, 0, $headBytes.Length)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Wait-CtxLoopbackRedirect {
    <#
    Waits for the browser to return to http://localhost:<port>/ with the authorization response. Requests for other
    paths or with a wrong state are answered and ignored, so a stray local request cannot end or hijack the sign-in.
    Polls (instead of blocking) so Ctrl+C still works. Returns @{ Code } or @{ Error; Description }.
    #>
    param([Parameter(Mandatory)]$Listener, [Parameter(Mandatory)][string]$State, [int]$TimeoutSeconds = 300)
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        $ready = @($Listener.Listeners | Where-Object { $_.Pending() }) | Select-Object -First 1
        if (-not $ready) { Start-Sleep -Milliseconds 200; continue }
        $client = $ready.AcceptTcpClient()
        try {
            $client.ReceiveTimeout = 5000
            $client.SendTimeout = 5000
            $stream = $client.GetStream()
            $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 8192, $true)
            $request = $null
            try {
                $request = ConvertFrom-CtxLoopbackRequest $reader.ReadLine()
                for ($i = 0; $i -lt 100; $i++) { if (-not $reader.ReadLine()) { break } }
            } catch { Write-Debug "ctx: unreadable loopback request: $_" }
            if (-not $request -or $request.Path -ne '/') {
                Send-CtxLoopbackResponse -Stream $stream -Status 404 -Message 'Not found.'
                continue
            }
            $q = $request.Query
            if (-not $q.ContainsKey('state') -or $q['state'] -cne $State) {
                Send-CtxLoopbackResponse -Stream $stream -Status 400 -Message 'This sign-in response does not belong to the running ctx sign-in.'
                continue
            }
            if ($q['error']) {
                Send-CtxLoopbackResponse -Stream $stream -Status 400 -Message 'The sign-in did not complete. Return to the terminal for details.'
                return @{ Error = [string]$q['error']; Description = [string]$q['error_description'] }
            }
            if ($q['code']) {
                Send-CtxLoopbackResponse -Stream $stream -Message 'Signed in. You can close this tab and return to the terminal.'
                return @{ Code = [string]$q['code'] }
            }
            Send-CtxLoopbackResponse -Stream $stream -Status 400 -Message 'The sign-in response has no authorization code.'
        } catch {
            Write-Debug "ctx: loopback request failed: $_"
        } finally {
            $client.Dispose()
        }
    }
    throw 'Sign-in timed out - run the command again.'
}
