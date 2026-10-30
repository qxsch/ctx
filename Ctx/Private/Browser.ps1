# Browser: one Edge (or Chromium) profile per environment so browser logins never collide.

function Get-CtxBrowserPath {
    $cfg = Get-CtxConfig
    if ($cfg.browserPath -and (Test-Path -LiteralPath $cfg.browserPath)) { return $cfg.browserPath }
    $appPath = try { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe' -ErrorAction Stop).'(default)' } catch { $null }
    foreach ($candidate in @(
            $appPath
            (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe')
            (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
        )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    $null
}

function Get-CtxBrowserProfileDir {
    param($Entry)
    $profileName = [string]$Entry.browserProfile
    if (-not $profileName -or $profileName -match '[\\/:*?"<>|]' -or $profileName.Trim('.') -eq '') {
        throw "Invalid browser profile name '$(ConvertTo-CtxSafeText $profileName -MaxLength 60)'."
    }
    $browser = Get-CtxBrowserPath
    $userData = if ($browser -and (Split-Path $browser -Leaf) -ieq 'chrome.exe') {
        Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'
    } else {
        Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'
    }
    Join-Path $userData $profileName
}

function ConvertTo-CtxBrowserUrl {
    <# Only absolute http(s) URLs; AbsoluteUri percent-encodes quotes and spaces, so the URL stays one argument. #>
    param([Parameter(Mandatory)][string]$Url)
    $u = $null
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u) -or $u.Scheme -notin 'https', 'http') {
        throw "Refusing to open '$(ConvertTo-CtxSafeText $Url -MaxLength 80)': only http(s) URLs are supported."
    }
    $u.AbsoluteUri
}

function New-CtxBrowserStartInfo {
    <# ProcessStartInfo for the browser; ArgumentList quotes every value on its own, so no field can add browser switches. #>
    param([Parameter(Mandatory)][string]$Browser, [Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)]$Entry, [switch]$InPrivate)
    $isChrome = (Split-Path $Browser -Leaf) -ieq 'chrome.exe'
    $psi = [Diagnostics.ProcessStartInfo]::new($Browser)
    $psi.UseShellExecute = $false
    if ($InPrivate) {
        $psi.ArgumentList.Add($(if ($isChrome) { '--incognito' } else { '--inprivate' }))
    } else {
        $psi.ArgumentList.Add("--profile-directory=$($Entry.browserProfile)")
        $psi.ArgumentList.Add('--no-first-run')
        $psi.ArgumentList.Add('--no-default-browser-check')
    }
    $psi.ArgumentList.Add((ConvertTo-CtxBrowserUrl $Url))
    $psi
}

function Open-CtxBrowser {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)]$Entry, [switch]$InPrivate)
    $target = ConvertTo-CtxBrowserUrl $Url
    $browser = Get-CtxBrowserPath
    if (-not $browser) {
        Start-Process $target
        return
    }
    $process = [Diagnostics.Process]::Start((New-CtxBrowserStartInfo -Browser $browser -Url $target -Entry $Entry -InPrivate:$InPrivate))
    if ($process) { $process.Dispose() }
}

function Get-CtxPortalUrl {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$Portal)
    $tid = [string]$Entry.tenantId
    if (-not (Test-CtxGuid $tid)) { throw "Environment '$($Entry.name)' has an invalid tenant ID." }
    $tenant = if (Test-CtxDomainName ([string]$Entry.tenantDomain)) { $Entry.tenantDomain } else { $tid }
    switch ($Portal.ToLowerInvariant()) {
        'azure' { "https://portal.azure.com/#@$tenant" }
        'entra' { "https://entra.microsoft.com/auth/login/@$tenant" }
        'pim' { "https://portal.azure.com/#@$tenant/view/Microsoft_Azure_PIMCommon/ActivationMenuBlade/~/aadmigratedroles" }
        'intune' { "https://intune.microsoft.com/#@$tenant" }
        'admin' { 'https://admin.microsoft.com/' }
        'security' { "https://security.microsoft.com/?tid=$tid" }
        'purview' { "https://purview.microsoft.com/?tid=$tid" }
        'myaccess' { "https://myaccess.microsoft.com/@$tenant" }
        'devicelogin' { 'https://microsoft.com/devicelogin' }
        default {
            if ($Portal -match '^https?://') { $Portal }
            else { throw "Unknown portal '$Portal'. Use: $($script:CtxPortals -join ', ') or a URL." }
        }
    }
}

$script:CtxPortals = @('azure', 'entra', 'pim', 'intune', 'admin', 'security', 'purview', 'myaccess', 'devicelogin')
