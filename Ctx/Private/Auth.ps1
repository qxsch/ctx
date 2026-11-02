# Token decoding and the sign-in wrapper of Azure CLI / Az PowerShell (device codes: clipboard + browser profile per environment).

function ConvertFrom-CtxJwt {
    param([Parameter(Mandatory)][string]$Token)
    $parts = $Token.Trim().Split('.')
    if ($parts.Count -lt 2) { throw 'Value is not a JWT.' }
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
}

function ConvertFrom-CtxSecureToken {
    param($Token)
    if ($Token -is [securestring]) { return ConvertFrom-SecureString -SecureString $Token -AsPlainText }
    [string]$Token
}

function Get-CtxIdentityFromClaims {
    param([Parameter(Mandatory)]$Claims)
    $upn = foreach ($p in 'upn', 'preferred_username', 'unique_name', 'email') {
        $v = $Claims.$p
        if ($v) { $v; break }
    }
    if ($upn -match '#') { $upn = ($upn -split '#')[-1] }
    [pscustomobject]@{
        TenantId  = [string]$Claims.tid
        ObjectId  = [string]$Claims.oid
        Upn       = [string]$upn
        ExpiresAt = if ($Claims.exp) { [DateTimeOffset]::FromUnixTimeSeconds([long]$Claims.exp).UtcDateTime } else { $null }
    }
}

function Test-CtxIdentityMatch {
    param($Entry, $Identity)
    $Identity -and $Identity.TenantId -ieq $Entry.tenantId -and $Identity.ObjectId -ieq $Entry.userObjectId
}

$script:CtxDeviceLoginHosts = @('microsoft.com', 'www.microsoft.com', 'login.microsoft.com', 'login.microsoftonline.com')
$script:CtxDeviceLoginDefaultUrl = 'https://microsoft.com/devicelogin'

function Get-CtxDeviceLoginUrl {
    <# Only Microsoft device-login pages are opened or shown; anything else falls back to the default page. #>
    param([string]$Url)
    $u = $null
    if ($Url -and [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u) -and $u.Scheme -eq 'https' -and
        $u.IsDefaultPort -and $script:CtxDeviceLoginHosts -contains $u.Host.ToLowerInvariant()) {
        return $u.AbsoluteUri
    }
    $script:CtxDeviceLoginDefaultUrl
}

function Show-CtxDeviceCode {
    param([string]$Code, [string]$Url, $Entry, [string]$Tool)
    $cfg = Get-CtxConfig
    $Url = Get-CtxDeviceLoginUrl $Url
    $Code = ConvertTo-CtxSafeText $Code -MaxLength 40
    $who = if ($Entry.upn) { " as $($Entry.upn)" } else { '' }
    Write-Host ''
    Write-Host "  ┌─ $Tool sign-in for '$($Entry.name)'$who" -ForegroundColor Cyan
    Write-Host '  │  code: ' -NoNewline -ForegroundColor Cyan
    Write-Host $Code -ForegroundColor Yellow -NoNewline
    if ($cfg.deviceCodeClipboard) {
        $paste = if ($IsMacOS) { '⌘V' } else { 'Ctrl+V' }
        try { Set-Clipboard -Value $Code; Write-Host "   (copied to clipboard, paste with $paste)" -ForegroundColor DarkGray }
        catch { Write-Host '' }
    } else { Write-Host '' }
    Write-Host "  │  url:  $Url" -ForegroundColor Cyan
    $opened = $false
    if ($cfg.deviceCodeBrowser) {
        try { Open-CtxBrowser -Url $Url -Entry $Entry; $opened = $true } catch { Write-Debug "ctx: could not open the browser: $_" }
    }
    if ($opened) {
        Write-Host "  └─ opened in browser profile '$($Entry.browserProfile)' - waiting for you to finish…" -ForegroundColor Cyan
    } else {
        Write-Host '  └─ open the url, enter the code - waiting…' -ForegroundColor Cyan
    }
}

function Invoke-CtxToolLogin {
    <#
    Runs a sign-in script block of Azure CLI or Az PowerShell. A device-code message ("enter the code XXXX") from any
    stream (Az: information, az CLI: stderr) is intercepted to copy the code and open the right browser profile;
    browser and broker sign-ins pass their records through. With -Native the native exit code is checked.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$Tool,
        [switch]$Native
    )
    $codeRx = [regex]'enter the code\s+(?<code>[A-Za-z0-9-]{6,})'
    $urlRx = [regex]'(?<url>https://[^\s]+)'
    $stderrLines = [System.Collections.Generic.List[string]]::new()
    $PSNativeCommandUseErrorActionPreference = $false
    & $ScriptBlock *>&1 | ForEach-Object {
        $rec = $_
        $text = $null
        if ($rec -is [System.Management.Automation.ErrorRecord]) { $text = $rec.ToString() }
        elseif ($rec -is [System.Management.Automation.WarningRecord]) { $text = $rec.Message }
        elseif ($rec -is [System.Management.Automation.InformationRecord]) { $text = [string]$rec.MessageData }
        elseif ($rec -is [string]) { $text = $rec }

        if ($text) {
            $m = $codeRx.Match($text)
            if ($m.Success) {
                $u = $urlRx.Match($text)
                $url = if ($u.Success) { $u.Groups['url'].Value.TrimEnd('.', ',') } else { 'https://microsoft.com/devicelogin' }
                Show-CtxDeviceCode -Code $m.Groups['code'].Value -Url $url -Entry $Entry -Tool $Tool
                return
            }
        }

        if ($rec -is [System.Management.Automation.ErrorRecord]) {
            if ($Native) {
                $stderrLines.Add($text)
                # az prints Python tracebacks on unexpected errors; only the readable lines are shown. Its browser
                # sign-in also suggests --use-device-code, which ctx never falls back to by itself.
                if ($text.Trim() -and $text -notmatch '^\s*(ERROR:|Traceback|File "|During handling|To check existing|\w+(Error|Exception):)' -and
                    $text -notmatch 'web browser has been opened|If no web browser is available') {
                    Write-Host "    $text" -ForegroundColor DarkGray
                }
            } else {
                Write-Error -ErrorRecord $rec
            }
        } elseif ($rec -is [System.Management.Automation.WarningRecord]) {
            if ($text -notmatch 'EnableLoginByWam|breaking change|Announcements') { Write-Warning $text }
        } elseif ($rec -is [System.Management.Automation.InformationRecord]) {
            if ($text -notmatch 'select the account you want to log ?in with') { Write-Host "    $text" -ForegroundColor DarkGray }
        } elseif ($rec -is [System.Management.Automation.VerboseRecord] -or $rec -is [System.Management.Automation.DebugRecord] -or $rec -is [System.Management.Automation.ProgressRecord]) {
            # swallow
        } else {
            $rec
        }
    }
    if ($Native -and $LASTEXITCODE -ne 0) {
        $all = $stderrLines -join "`n"
        $aad = [regex]::Match($all, 'AADSTS\d+:[^"\r\n]*?(?=(\s*Trace ID|"|\r?\n|$))')
        $msg = if ($aad.Success) { $aad.Value.Trim() }
        else { ($stderrLines | Where-Object { $_ -match '^\s*ERROR:' } | Select-Object -First 1) -replace '^\s*ERROR:\s*', '' }
        if (-not $msg) { $msg = "exit code $LASTEXITCODE" }
        if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 297) + '...' }
        throw "$Tool sign-in failed: $msg"
    }
}
