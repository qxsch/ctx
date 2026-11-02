# Browser: one Edge (or Chrome/Chromium) profile per environment so browser logins never collide.

function Resolve-CtxBrowserExecutable {
    <# A configured browser: an executable, or a macOS .app bundle (resolved to Contents/MacOS/<name>). #>
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    if ($Path -match '\.app[\\/]*$' -and (Test-Path -LiteralPath $Path -PathType Container)) {
        $exe = Join-Path $Path "Contents/MacOS/$([IO.Path]::GetFileNameWithoutExtension($Path.TrimEnd('/', '\')))"
        return $(if (Test-Path -LiteralPath $exe -PathType Leaf) { $exe } else { $null })
    }
    if (Test-Path -LiteralPath $Path -PathType Leaf) { $Path } else { $null }
}

function Get-CtxBrowserPath {
    <# config browserPath, else Microsoft Edge: Windows registry/Program Files, macOS /Applications, Linux PATH, WSL the Windows Edge. #>
    $cfg = Get-CtxConfig
    if ($cfg.browserPath) {
        $configured = Resolve-CtxBrowserExecutable $cfg.browserPath
        if ($configured) { return $configured }
    }
    $candidates = if ($IsWindows) {
        try { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe' -ErrorAction Stop).'(default)' } catch { $null }
        if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe' }
        if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe' }
    } elseif ($IsMacOS) {
        '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge'
        Join-Path $HOME 'Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge'
    } else {
        foreach ($name in 'microsoft-edge-stable', 'microsoft-edge') {
            Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
        }
        # WSL: the Windows Edge (its profiles live on the Windows side).
        if ($env:WSL_DISTRO_NAME) { '/mnt/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe', '/mnt/c/Program Files/Microsoft/Edge/Application/msedge.exe' }
    }
    foreach ($candidate in @($candidates)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    $null
}

function Get-CtxBrowserKind {
    <# edge, chrome or chromium - from the executable name (msedge.exe, Google Chrome, google-chrome-stable, chromium-browser, ...). #>
    param([string]$Path)
    $leaf = [IO.Path]::GetFileNameWithoutExtension([string]$Path).ToLowerInvariant()
    if ($leaf -match 'chromium') { 'chromium' } elseif ($leaf -match 'chrome') { 'chrome' } else { 'edge' }
}

function Get-CtxBrowserUserDataDir {
    <# The browser's User Data folder that holds its profiles. $null for a Windows browser started from WSL. #>
    param([Parameter(Mandatory)][ValidateSet('edge', 'chrome', 'chromium')][string]$Kind, [string]$BrowserPath)
    if (-not $IsWindows -and $BrowserPath -match '^/mnt/[a-z]/') { return $null }
    if ($IsWindows) {
        $rel = switch ($Kind) { 'chrome' { 'Google\Chrome\User Data' } 'chromium' { 'Chromium\User Data' } default { 'Microsoft\Edge\User Data' } }
        return Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) $rel
    }
    if ($IsMacOS) {
        $rel = switch ($Kind) { 'chrome' { 'Google/Chrome' } 'chromium' { 'Chromium' } default { 'Microsoft Edge' } }
        return Join-Path $HOME "Library/Application Support/$rel"
    }
    $config = if ($env:XDG_CONFIG_HOME -and [IO.Path]::IsPathRooted($env:XDG_CONFIG_HOME)) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
    $rel = switch ($Kind) { 'chrome' { 'google-chrome' } 'chromium' { 'chromium' } default { 'microsoft-edge' } }
    Join-Path $config $rel
}

function Get-CtxBrowserProcessNames {
    <# Process names of the configured browser on this OS (to refuse deleting a profile while it runs). #>
    $kind = Get-CtxBrowserKind (Get-CtxBrowserPath)
    if ($IsMacOS) {
        switch ($kind) { 'chrome' { @('Google Chrome') } 'chromium' { @('Chromium') } default { @('Microsoft Edge') } }
    } else {
        switch ($kind) { 'chrome' { @('chrome') } 'chromium' { @('chromium', 'chromium-browse', 'chrome') } default { @('msedge') } }
    }
}

function Get-CtxBrowserProfileDir {
    param($Entry)
    $profileName = [string]$Entry.browserProfile
    if (-not $profileName -or $profileName -match '[\\/:*?"<>|]' -or $profileName.Trim('.') -eq '') {
        throw "Invalid browser profile name '$(ConvertTo-CtxSafeText $profileName -MaxLength 60)'."
    }
    $browser = Get-CtxBrowserPath
    $userData = Get-CtxBrowserUserDataDir -Kind (Get-CtxBrowserKind $browser) -BrowserPath $browser
    if (-not $userData) { throw "The browser profile '$profileName' belongs to the Windows browser - remove it there (browser settings)." }
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
    $isChrome = (Get-CtxBrowserKind $Browser) -ne 'edge'
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

function Test-CtxCanOpenBrowser {
    <# False in sessions without a local desktop (SSH, Linux without a display), where sign-in pages cannot open. #>
    if ($IsLinux) { return [bool]($env:DISPLAY -or $env:WAYLAND_DISPLAY -or $env:WSL_DISTRO_NAME) }
    -not ($env:SSH_CONNECTION -or $env:SSH_TTY)
}

function Get-CtxBrowserCommandLine {
    <#
    Value for the BROWSER variable of Azure CLI's browser sign-in (Python's webbrowser module, shlex-split), so its
    sign-in page opens in the environment's browser profile. $null (= default browser) when no usable browser is found.
    Characters that shlex or the %s substitution would interpret are refused instead of escaped.
    #>
    param([Parameter(Mandatory)]$Entry)
    $browser = Get-CtxBrowserPath
    if (-not $browser) { return $null }
    $path = $browser.Replace('\', '/')
    $profileName = [string]$Entry.browserProfile
    if ($path -match '["%$`\\]' -or $profileName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { return $null }
    # A trailing '&' makes Python start the browser in the background; otherwise az waits until the browser exits.
    "`"$path`" --profile-directory=$profileName --no-first-run --no-default-browser-check %s &"
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
