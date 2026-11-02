#Requires -Version 7.2
<#
.SYNOPSIS
Installs ctx for the current user. Windows: module and profile sync via OneDrive. Linux/macOS: installed per device.
.DESCRIPTION
- copies the module (Ctx/) into your user module folder: Documents\PowerShell\Modules\Ctx on Windows (with OneDrive
  known-folder backup this folder syncs, so every device gets the same code), ~/.local/share/powershell/Modules/Ctx on
  Linux and macOS. Only changed files are copied (re-run after edits).
- adds "Import-Module Ctx" (by name, no machine-specific path) to your PowerShell profile (it syncs as well on Windows).
  The block is idempotent and marked with # >>> ctx >>>.
- Linux/macOS: adds a block with the same markers to ~/.bashrc, ~/.zshenv, ~/.profile (when present) and a fish
  conf.d file, so new bash/zsh/fish shells and apps follow the global environment. The block reads the two variables
  AZURE_CONFIG_DIR / AZURE_EXTENSION_DIR from ctx's global.env; it never sources the file.
- checks prerequisites (Azure CLI, Az.Accounts, Microsoft.Graph.Authentication). Windows: when elevated it offers to
  install missing modules for all users (Program Files, not synced); otherwise it prints the elevated install command,
  because CurrentUser installs would land in OneDrive and shadow newer machine-wide versions on every device.
  Linux/macOS: it offers to install them for the current user (nothing syncs there).
- enables Az PowerShell context autosave for the current user (ctx also does this on first use on other devices)
Device-local (never synced): the ctx data folder (%LOCALAPPDATA%\ctx, ~/Library/Application Support/ctx or
~/.local/share/ctx: environments, CLI logins, config), ~/.Azure (Az contexts), browser profiles and the variables for
new processes. Graph tokens live only in each terminal's memory, unless you opt in per environment
(ctx set <name> -SaveGraphCredentials On): then the refresh token is also stored encrypted in the data folder.
.PARAMETER ModulePath
Modules folder to install into. Default: the user module folder (Documents on Windows, ~/.local/share/powershell elsewhere).
.PARAMETER ProfilePath
Profile file to modify. Default: the profile that initializes oh-my-posh/starship (so the ctx badge wraps that
prompt), otherwise $PROFILE.CurrentUserAllHosts (all hosts, including VS Code).
.PARAMETER Repository
PowerShell repository for missing modules. Default: 'azure-powershell' when registered (package proxy), else PSGallery.
.PARAMETER SigningCertificate
Windows only. Thumbprint of a code-signing certificate in Cert:\CurrentUser\My. The installed module is
Authenticode-signed with it, so 'ctx doctor' (and an AllSigned execution policy) detect changes to the synced code.
.PARAMETER TimestampServer
Optional RFC 3161 timestamp server for the signature, e.g. http://timestamp.digicert.com.
.PARAMETER Yes
Do not ask before installing modules.
.PARAMETER NoProfile
Skip all profile changes (PowerShell profile and, on Linux/macOS, the shell profiles).
.PARAMETER NoShellProfile
Linux/macOS: skip the bash/zsh/fish blocks (new non-PowerShell shells then keep az's default ~/.azure).
.PARAMETER Force
Overwrite a module folder named Ctx that does not contain ctx.
#>
[CmdletBinding()]
param(
    [string]$ModulePath,
    [string]$ProfilePath,
    [string]$Repository,
    [string]$SigningCertificate,
    [string]$TimestampServer,
    [switch]$Yes,
    [switch]$NoProfile,
    [switch]$NoShellProfile,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'Ctx'
$sourceManifest = Join-Path $source 'Ctx.psd1'
if (-not (Test-Path -LiteralPath $sourceManifest)) { throw "Ctx/Ctx.psd1 not found next to Install.ps1." }
$ctxGuid = (Import-PowerShellDataFile -LiteralPath $sourceManifest).GUID
# Oldest versions with the features ctx uses (SecureString tokens, -SkipContextPopulation, LoginExperienceV2,
# Connect-MgGraph -AccessToken <SecureString> -NoWelcome).
$minimumVersions = @{ 'Az.Accounts' = '3.0.0'; 'Microsoft.Graph.Authentication' = '2.0.0' }
$signingCert = $null
if ($SigningCertificate) {
    if (-not $IsWindows) { throw 'Authenticode signing (-SigningCertificate) is only available on Windows.' }
    $signingCert = Get-ChildItem -LiteralPath 'Cert:\CurrentUser\My' -CodeSigningCert |
        Where-Object { $_.Thumbprint -ieq ($SigningCertificate -replace '\s', '') -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) } |
        Select-Object -First 1
    if (-not $signingCert) { throw "No valid code-signing certificate with private key and thumbprint '$SigningCertificate' in Cert:\CurrentUser\My." }
}
$sep = [IO.Path]::DirectorySeparatorChar

function Write-Step([string]$Text) { Write-Host "  › $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "  ✓ $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "  ! $Text" -ForegroundColor Yellow }
function Confirm-Step([string]$Question) {
    if ($Yes) { return $true }
    $a = Read-Host "  ? $Question [Y/n]"
    -not $a -or $a -match '^(y|yes|j|ja)$'
}
function Get-OneDriveRoot([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') + $sep
    foreach ($root in @($env:OneDriveCommercial, $env:OneDriveConsumer, $env:OneDrive) | Where-Object { $_ } | Select-Object -Unique) {
        if ($full.StartsWith($root.TrimEnd('\', '/') + $sep, [StringComparison]::OrdinalIgnoreCase)) { return $root }
    }
    $null
}
function Sync-Folder([string]$From, [string]$To) {
    <# Mirrors $From to $To, touching only changed files (keeps OneDrive sync traffic minimal). #>
    New-Item -ItemType Directory -Path $To -Force | Out-Null
    $wanted = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $copied = 0
    foreach ($f in Get-ChildItem -LiteralPath $From -Recurse -File) {
        $rel = [IO.Path]::GetRelativePath($From, $f.FullName)
        [void]$wanted.Add($rel)
        $dest = Join-Path $To $rel
        $same = (Test-Path -LiteralPath $dest) -and (Get-FileHash -LiteralPath $dest).Hash -eq (Get-FileHash -LiteralPath $f.FullName).Hash
        if (-not $same) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
            Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
            $copied++
        }
    }
    $removed = 0
    foreach ($f in Get-ChildItem -LiteralPath $To -Recurse -File) {
        if (-not $wanted.Contains([IO.Path]::GetRelativePath($To, $f.FullName))) { Remove-Item -LiteralPath $f.FullName -Force; $removed++ }
    }
    Get-ChildItem -LiteralPath $To -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending |
        Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force) } | Remove-Item -Force
    [pscustomobject]@{ Copied = $copied; Removed = $removed }
}

function New-BundledModule([string]$From, [string]$To) {
    <# Builds the installed module: Ctx.psm1 with all Private/Public files inlined (one file starts faster). #>
    New-Item -ItemType Directory -Path $To -Force | Out-Null
    foreach ($f in Get-ChildItem -LiteralPath $From -File | Where-Object Name -NE 'Ctx.psm1') { Copy-Item -LiteralPath $f.FullName -Destination $To }
    $parts = foreach ($folder in 'Private', 'Public') {
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $From $folder) -Filter '*.ps1' | Sort-Object Name) {
            "#region $folder\$($f.Name)`n$([IO.File]::ReadAllText($f.FullName).TrimEnd())`n#endregion`n"
        }
    }
    $psm1 = [IO.File]::ReadAllText((Join-Path $From 'Ctx.psm1'))
    $loader = [regex]'(?s)# >>> loader.*?# <<< loader\r?\n'
    if (-not $loader.IsMatch($psm1)) { throw 'Loader markers not found in Ctx\Ctx.psm1.' }
    $bundled = $loader.Replace($psm1, { param($m) ($parts -join "`n") + "`n" }, 1)
    [IO.File]::WriteAllText((Join-Path $To 'Ctx.psm1'), $bundled, [Text.UTF8Encoding]::new($false))
}

Write-Host ''
Write-Host '  ctx installer' -ForegroundColor Cyan
Write-Host ''

# 1) prerequisites
Write-Ok "PowerShell $($PSVersionTable.PSVersion) on $(if ($IsWindows) { 'Windows' } elseif ($IsMacOS) { 'macOS' } else { 'Linux' })"
$az = @(Get-Command az.cmd, az -CommandType Application -ErrorAction SilentlyContinue)[0]
$azHint = if ($IsWindows) { 'winget install Microsoft.AzureCLI' } elseif ($IsMacOS) { 'brew install azure-cli' } else { 'https://learn.microsoft.com/cli/azure/install-azure-cli-linux' }
if ($az) { Write-Ok "Azure CLI $($az.Source)" }
else { Write-Warn "Azure CLI not found - install it ($azHint) or use environments with -Tools az." }

$hasPSResourceGet = [bool](Get-Command Install-PSResource -ErrorAction SilentlyContinue)
if (-not $Repository) {
    $proxy = if ($hasPSResourceGet) { Get-PSResourceRepository -Name 'azure-powershell' -ErrorAction SilentlyContinue }
    else { Get-PSRepository -Name 'azure-powershell' -ErrorAction SilentlyContinue }
    $Repository = if ($proxy) { 'azure-powershell' } else { 'PSGallery' }
}
$isAdmin = if ($IsWindows) {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} else { (& id -u) -eq '0' }
# Windows: CurrentUser scope would land in Documents (OneDrive) and shadow newer machine-wide versions on every device.
# Linux/macOS: nothing syncs, so the user scope is the simple default (all users needs sudo pwsh).
$scope = if ($IsWindows -or $isAdmin) { 'AllUsers' } else { 'CurrentUser' }
foreach ($m in 'Az.Accounts', 'Microsoft.Graph.Authentication') {
    $min = [version]$minimumVersions[$m]
    $found = Get-Module -ListAvailable -Name $m | Sort-Object Version -Descending | Select-Object -First 1
    if ($found -and $found.Version -ge $min) { Write-Ok "$m $($found.Version)"; continue }
    $why = if ($m -eq 'Az.Accounts') { 'Az PowerShell switching' } else { 'PIM activation and Microsoft Graph' }
    $status = if ($found) { "$($found.Version) is older than the required $min" } else { 'missing' }
    $command = if ($hasPSResourceGet) { "Install-PSResource $m -Repository $Repository -Scope $scope -Version '[$min,)'" }
    else { "Install-Module $m -Repository $Repository -Scope $scope -MinimumVersion $min" }
    if ($IsWindows -and -not $isAdmin) {
        Write-Warn "$m is $status (needed for $why). Install it machine-wide from an elevated pwsh: $command"
        continue
    }
    $where = if ($scope -eq 'AllUsers') { 'for all users' } else { 'for the current user' }
    if (Confirm-Step "$m is $status (needed for $why). Install it from '$Repository' $($where)?") {
        Write-Step "Installing $m from $Repository"
        if ($hasPSResourceGet) {
            # The confirmation names the repository, so it is trusted for this installation only. Never overwrite
            # commands of other modules when the module is new on this machine.
            $extra = if ($found) { @{} } else { @{ NoClobber = $true } }
            Install-PSResource -Name $m -Repository $Repository -Scope $scope -Version "[$min,)" -TrustRepository -Quiet @extra
        } else {
            Install-Module -Name $m -Repository $Repository -Scope $scope -MinimumVersion $min
        }
        Write-Ok "$m installed"
    } else {
        Write-Warn "$m skipped - related features stay unavailable."
    }
}

# 2) Az context autosave (named contexts per environment survive new terminals)
if (Get-Module -ListAvailable -Name Az.Accounts) {
    try {
        Import-Module Az.Accounts -ErrorAction Stop -WarningAction SilentlyContinue
        $mode = (Get-AzContextAutosaveSetting -WarningAction SilentlyContinue).Mode
        if ($mode -ne 'CurrentUser') {
            Enable-AzContextAutosave -Scope CurrentUser -WarningAction SilentlyContinue | Out-Null
            Write-Ok 'Az context autosave enabled for the current user'
        } else {
            Write-Ok 'Az context autosave already enabled'
        }
    } catch { Write-Warn "Could not check Az context autosave: $($_.Exception.Message)" }
}

# 3) module (Windows: synced code)
$modulePaths = @($env:PSModulePath -split [IO.Path]::PathSeparator | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\', '/') })
$userModules = if ($IsWindows) {
    [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules'))
} else {
    # pwsh's user module folder on Linux and macOS: the first PSModulePath entry below the home folder.
    $underHome = $modulePaths | Where-Object { $_.StartsWith($HOME.TrimEnd('/') + '/', [StringComparison]::Ordinal) } | Select-Object -First 1
    if ($underHome) { $underHome } else { Join-Path $HOME '.local/share/powershell/Modules' }
}
if (-not $ModulePath) {
    $ModulePath = $modulePaths | Where-Object { $_ -ieq $userModules.TrimEnd('\', '/') } | Select-Object -First 1
    if (-not $ModulePath) { $ModulePath = $userModules }
}
$ModulePath = [IO.Path]::GetFullPath($ModulePath).TrimEnd('\', '/')
$target = Join-Path $ModulePath 'Ctx'
$targetManifest = Join-Path $target 'Ctx.psd1'
if ((Test-Path -LiteralPath $target) -and (Get-ChildItem -LiteralPath $target -Force | Select-Object -First 1) -and -not $Force) {
    $existingGuid = if (Test-Path -LiteralPath $targetManifest) { (Import-PowerShellDataFile -LiteralPath $targetManifest).GUID } else { $null }
    if ($existingGuid -ne $ctxGuid) { throw "$target exists and is not ctx. Remove it or use -Force." }
}
if ($target.StartsWith($PSScriptRoot.TrimEnd('\', '/') + $sep, [StringComparison]::OrdinalIgnoreCase)) { throw "ModulePath must be outside the source folder." }
if (Get-Module Ctx) { Remove-Module Ctx -Force }
$staging = Join-Path ([IO.Path]::GetTempPath()) "ctx-build-$([guid]::NewGuid().ToString('n'))"
try {
    New-BundledModule -From $source -To $staging
    if ($signingCert) {
        foreach ($f in Get-ChildItem -LiteralPath $staging -File | Where-Object Extension -In '.psm1', '.psd1', '.ps1xml') {
            # Signed scripts need a BOM: without it, non-ASCII text can be hashed differently when the signature is checked.
            [IO.File]::WriteAllText($f.FullName, [IO.File]::ReadAllText($f.FullName), [Text.UTF8Encoding]::new($true))
            $sigArgs = @{ LiteralPath = $f.FullName; Certificate = $signingCert; HashAlgorithm = 'SHA256' }
            if ($TimestampServer) { $sigArgs.TimestampServer = $TimestampServer }
            $sig = Set-AuthenticodeSignature @sigArgs
            if (-not $sig.SignerCertificate -or $sig.Status -eq 'HashMismatch') { throw "Signing $($f.Name) failed: $($sig.StatusMessage)" }
            if ($sig.Status -ne 'Valid') { Write-Warn "$($f.Name) is signed, but not trusted on this device: $($sig.StatusMessage)" }
        }
        Write-Ok "Module signed by $($signingCert.Subject)"
    }
    $sync = Sync-Folder -From $staging -To $target
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Ok "Module $(if ($sync.Copied -or $sync.Removed) { "updated ($($sync.Copied) copied, $($sync.Removed) removed)" } else { 'up to date' }): $target"
$byName = $modulePaths -contains $ModulePath
if (-not $byName) { Write-Warn "$ModulePath is not in PSModulePath - the profile imports ctx by full path." }
if (-not $IsWindows) { Write-Ok 'Installed for this device (run Install.ps1 on each Linux/macOS device)' }
elseif (Get-OneDriveRoot $target) { Write-Ok 'Code syncs via OneDrive' }
else { Write-Warn "$target is not inside OneDrive - other devices will not get the code." }

# 4) profile hook (synced, no machine-specific paths when installed into PSModulePath)
if (-not $NoProfile) {
    if (-not $ProfilePath) {
        $promptProfile = @($PROFILE.CurrentUserCurrentHost, $PROFILE.CurrentUserAllHosts) |
            Where-Object { $_ -and (Test-Path -LiteralPath $_) -and ((Get-Content -LiteralPath $_ -Raw) -match 'oh-my-posh|starship|function\s+(global:)?prompt') } |
            Select-Object -First 1
        $ProfilePath = if ($promptProfile) { $promptProfile } else { $PROFILE.CurrentUserAllHosts }
    }
    $begin = '# >>> ctx >>>'
    $end = '# <<< ctx <<<'
    # Single-quoted PowerShell string: embedded quotes (C:\Users\O'Brien\...) are doubled.
    $importTarget = if ($byName) { 'Ctx' } else { "'" + $targetManifest.Replace("'", "''") + "'" }
    $where = if ($IsWindows) { 'Code + profile sync via OneDrive; logins and state stay on this device (%LOCALAPPDATA%\ctx).' } else { 'Logins and state stay on this device (ctx doctor shows the data folder).' }
    $block = @(
        $begin
        "# ctx - environment switcher. $where"
        '# Keep this after your prompt setup (oh-my-posh, starship) so the badge wraps it. Updates: Install.ps1 in the ctx repo.'
        "try { Import-Module $importTarget -ErrorAction Stop } catch { Write-Warning `"ctx not loaded: `$(`$_.Exception.Message)`" }"
        $end
    ) -join [Environment]::NewLine
    $dir = Split-Path -Parent $ProfilePath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $content = if (Test-Path -LiteralPath $ProfilePath) { [IO.File]::ReadAllText($ProfilePath) } else { '' }
    $pattern = "(?s)$([regex]::Escape($begin)).*?$([regex]::Escape($end))"
    if ($content -match $pattern) {
        $updated = [regex]::Replace($content, $pattern, { param($m) $block })
        if ($updated -ne $content) { Write-Ok "Updated the ctx block in $ProfilePath" } else { Write-Ok "Profile already loads ctx: $ProfilePath" }
        $content = $updated
    } else {
        if ($content -and -not $content.EndsWith("`n")) { $content += [Environment]::NewLine }
        $content += $(if ($content) { [Environment]::NewLine } else { '' }) + $block + [Environment]::NewLine
        Write-Ok "Added ctx to $ProfilePath"
    }
    [IO.File]::WriteAllText($ProfilePath, $content, [Text.UTF8Encoding]::new($false))
    if ($IsWindows -and -not (Get-OneDriveRoot $ProfilePath)) { Write-Warn "$ProfilePath is not inside OneDrive - other devices will not load ctx." }
    foreach ($other in @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) | Where-Object { $_ -and $_ -ne $ProfilePath -and (Test-Path -LiteralPath $_) }) {
        if ((Get-Content -LiteralPath $other -Raw) -match [regex]::Escape($begin)) { Write-Warn "$other also contains a ctx block - remove one of them." }
    }
}

# 4b) Linux/macOS: new bash/zsh/fish shells (and apps they start) follow the global environment via global.env
if (-not $IsWindows -and -not $NoProfile -and -not $NoShellProfile) {
    # The data folder as each shell computes it; CTX_HOME (set at install time or in the shell) wins.
    $shHome = if ($env:CTX_HOME) {
        $env:CTX_HOME.Replace('\', '\\').Replace('"', '\"').Replace('$', '\$').Replace('`', '\`')
    } elseif ($IsMacOS) { '$HOME/Library/Application Support/ctx' } else { '${XDG_DATA_HOME:-$HOME/.local/share}/ctx' }
    $posix = @(
        '# >>> ctx >>>'
        '# ctx: Azure CLI environment for new shells. Reads (never sources) two variables from ctx''s global.env.'
        "ctx_env=`"`${CTX_HOME:-$shHome}/global.env`""
        'if [ -r "$ctx_env" ]; then'
        '  while IFS=''='' read -r ctx_k ctx_v; do'
        '    case "$ctx_k" in AZURE_CONFIG_DIR|AZURE_EXTENSION_DIR) export "$ctx_k=$ctx_v" ;; esac'
        '  done < "$ctx_env"'
        'fi'
        'unset ctx_env ctx_k ctx_v'
        '# <<< ctx <<<'
    ) -join "`n"
    $dataDefault = if ($env:CTX_HOME) { $env:CTX_HOME } elseif ($IsMacOS) { Join-Path $HOME 'Library/Application Support/ctx' } else {
        $xdg = if ($env:XDG_DATA_HOME -and [IO.Path]::IsPathRooted($env:XDG_DATA_HOME)) { $env:XDG_DATA_HOME } else { Join-Path $HOME '.local/share' }
        Join-Path $xdg 'ctx'
    }
    $fishHome = "'" + ([string]$dataDefault).Replace('\', '\\').Replace("'", "\'") + "'"
    $fish = @(
        '# >>> ctx >>>'
        '# ctx: Azure CLI environment for new fish shells. Reads (never sources) two variables from ctx''s global.env.'
        "set -l ctx_home $fishHome"
        'set -q CTX_HOME; and set ctx_home $CTX_HOME'
        'if test -r "$ctx_home/global.env"'
        '    for ctx_line in (string match -r ''^(?:AZURE_CONFIG_DIR|AZURE_EXTENSION_DIR)=.*$'' < "$ctx_home/global.env")'
        '        set -l ctx_kv (string split -m 1 ''='' -- $ctx_line)'
        '        set -gx $ctx_kv[1] $ctx_kv[2]'
        '    end'
        'end'
        '# <<< ctx <<<'
    ) -join "`n"
    $targets = @()
    if (Get-Command bash -CommandType Application -ErrorAction SilentlyContinue) { $targets += [pscustomobject]@{ Path = Join-Path $HOME '.bashrc'; Block = $posix } }
    if (Get-Command zsh -CommandType Application -ErrorAction SilentlyContinue) { $targets += [pscustomobject]@{ Path = Join-Path $HOME '.zshenv'; Block = $posix } }
    if (Test-Path -LiteralPath (Join-Path $HOME '.profile')) { $targets += [pscustomobject]@{ Path = Join-Path $HOME '.profile'; Block = $posix } }
    if (Get-Command fish -CommandType Application -ErrorAction SilentlyContinue) { $targets += [pscustomobject]@{ Path = Join-Path $HOME '.config/fish/conf.d/ctx.fish'; Block = $fish } }
    $shellPattern = '(?s)# >>> ctx >>>.*?# <<< ctx <<<'
    foreach ($t in $targets) {
        $dir = Split-Path -Parent $t.Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $content = if (Test-Path -LiteralPath $t.Path) { [IO.File]::ReadAllText($t.Path) } else { '' }
        if ($content -match $shellPattern) {
            $updated = [regex]::Replace($content, $shellPattern, { param($m) $t.Block })
            if ($updated -ne $content) { Write-Ok "Updated the ctx block in $($t.Path)" } else { Write-Ok "$($t.Path) already reads global.env" }
            $content = $updated
        } else {
            if ($content -and -not $content.EndsWith("`n")) { $content += "`n" }
            $content += $(if ($content) { "`n" } else { '' }) + $t.Block + "`n"
            Write-Ok "Added the ctx block to $($t.Path)"
        }
        [IO.File]::WriteAllText($t.Path, $content, [Text.UTF8Encoding]::new($false))
    }
    if (-not $targets.Count) { Write-Warn 'No bash, zsh or fish found - only PowerShell follows the global environment.' }
}

# 5) load it now
Import-Module $targetManifest -Force -Global
$dataDir = & (Get-Module Ctx | Select-Object -First 1) { Get-CtxHome }
if (Get-OneDriveRoot $dataDir) { Write-Warn "Data folder $dataDir is inside OneDrive - logins would sync. Point CTX_HOME to a local folder." }
else { Write-Ok "Data folder (this device only): $dataDir" }
Write-Host ''
Write-Host '  Next steps' -ForegroundColor Cyan
Write-Host '    ctx add switzerland contoso.onmicrosoft.com    create an environment (device code; -SignIn Browser|Broker)'
Write-Host '    ctx switzerland -Admin                          switch + Global Admin (PIM) + Graph'
Write-Host '    ctx help                                        cheat sheet'
Write-Host '    ctx doctor                                      check everything'
Write-Host ''
if ($IsWindows) {
    Write-Host '  Other devices get the code and profile through OneDrive; environments are per device' -ForegroundColor DarkGray
} else {
    Write-Host '  Other devices: clone the repo and run Install.ps1 there; environments are per device' -ForegroundColor DarkGray
}
Write-Host '  (ctx export <file> here, ctx import <file> there, then ctx <name> signs in).' -ForegroundColor DarkGray
Write-Host '  Terminals that are already open: run  ctx sync  (or open a new terminal).' -ForegroundColor DarkGray
Write-Host ''
