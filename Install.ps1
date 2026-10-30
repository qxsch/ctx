#Requires -Version 7.2
<#
.SYNOPSIS
Installs ctx for the current user: module and profile sync via OneDrive, logins and state stay on each device.
.DESCRIPTION
- copies the module (Ctx\) into your user module folder, Documents\PowerShell\Modules\Ctx. With OneDrive known-folder
  backup this folder syncs, so every device gets the same code. Only changed files are copied (re-run after edits).
- adds "Import-Module Ctx" (by name, no machine-specific path) to your PowerShell profile, which syncs as well.
  The block is idempotent and marked with # >>> ctx >>>.
- checks prerequisites (Azure CLI, Az.Accounts, Microsoft.Graph.Authentication). When elevated it offers to install
  missing modules for all users (Program Files, not synced); otherwise it prints the elevated install command.
  CurrentUser installs would land in OneDrive and shadow newer machine-wide versions on every device.
- enables Az PowerShell context autosave for the current user (ctx also does this on first use on other devices)
Device-local (never synced): %LOCALAPPDATA%\ctx (environments, CLI logins, config), ~\.Azure (Az contexts),
browser profiles and the AZURE_CONFIG_DIR user variable. Graph tokens live only in each terminal's memory.
.PARAMETER ModulePath
Modules folder to install into. Default: the user module folder in Documents (first PSModulePath entry there).
.PARAMETER ProfilePath
Profile file to modify. Default: the profile that initializes oh-my-posh/starship (so the ctx badge wraps that
prompt), otherwise $PROFILE.CurrentUserAllHosts (all hosts, including VS Code).
.PARAMETER Repository
PowerShell repository for missing modules. Default: 'azure-powershell' when registered (package proxy), else PSGallery.
.PARAMETER SigningCertificate
Thumbprint of a code-signing certificate in Cert:\CurrentUser\My. The installed module is Authenticode-signed with it,
so 'ctx doctor' (and an AllSigned execution policy) detect changes to the synced code.
.PARAMETER TimestampServer
Optional RFC 3161 timestamp server for the signature, e.g. http://timestamp.digicert.com.
.PARAMETER Yes
Do not ask before installing modules.
.PARAMETER NoProfile
Skip the profile change.
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
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'Ctx'
$sourceManifest = Join-Path $source 'Ctx.psd1'
if (-not (Test-Path -LiteralPath $sourceManifest)) { throw "Ctx\Ctx.psd1 not found next to Install.ps1." }
$ctxGuid = (Import-PowerShellDataFile -LiteralPath $sourceManifest).GUID
# Oldest versions with the features ctx uses (SecureString tokens, -SkipContextPopulation, LoginExperienceV2,
# Connect-MgGraph -AccessToken <SecureString> -NoWelcome).
$minimumVersions = @{ 'Az.Accounts' = '3.0.0'; 'Microsoft.Graph.Authentication' = '2.0.0' }
$signingCert = $null
if ($SigningCertificate) {
    $signingCert = Get-ChildItem -LiteralPath 'Cert:\CurrentUser\My' -CodeSigningCert |
        Where-Object { $_.Thumbprint -ieq ($SigningCertificate -replace '\s', '') -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) } |
        Select-Object -First 1
    if (-not $signingCert) { throw "No valid code-signing certificate with private key and thumbprint '$SigningCertificate' in Cert:\CurrentUser\My." }
}

function Write-Step([string]$Text) { Write-Host "  › $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "  ✓ $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "  ! $Text" -ForegroundColor Yellow }
function Confirm-Step([string]$Question) {
    if ($Yes) { return $true }
    $a = Read-Host "  ? $Question [Y/n]"
    -not $a -or $a -match '^(y|yes|j|ja)$'
}
function Get-OneDriveRoot([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
    foreach ($root in @($env:OneDriveCommercial, $env:OneDriveConsumer, $env:OneDrive) | Where-Object { $_ } | Select-Object -Unique) {
        if ($full.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $root }
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
Write-Ok "PowerShell $($PSVersionTable.PSVersion)"
$az = Get-Command az.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($az) { Write-Ok "Azure CLI $($az.Source)" }
else { Write-Warn 'Azure CLI not found - install it (winget install Microsoft.AzureCLI) or use environments with -Tools az.' }

$hasPSResourceGet = [bool](Get-Command Install-PSResource -ErrorAction SilentlyContinue)
if (-not $Repository) {
    $proxy = if ($hasPSResourceGet) { Get-PSResourceRepository -Name 'azure-powershell' -ErrorAction SilentlyContinue }
    else { Get-PSRepository -Name 'azure-powershell' -ErrorAction SilentlyContinue }
    $Repository = if ($proxy) { 'azure-powershell' } else { 'PSGallery' }
}
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
foreach ($m in 'Az.Accounts', 'Microsoft.Graph.Authentication') {
    $min = [version]$minimumVersions[$m]
    $found = Get-Module -ListAvailable -Name $m | Sort-Object Version -Descending | Select-Object -First 1
    if ($found -and $found.Version -ge $min) { Write-Ok "$m $($found.Version)"; continue }
    $why = if ($m -eq 'Az.Accounts') { 'Az PowerShell switching' } else { 'PIM activation and Microsoft Graph' }
    $status = if ($found) { "$($found.Version) is older than the required $min" } else { 'missing' }
    $command = if ($hasPSResourceGet) { "Install-PSResource $m -Repository $Repository -Scope AllUsers -Version '[$min,)'" }
    else { "Install-Module $m -Repository $Repository -Scope AllUsers -MinimumVersion $min" }
    # CurrentUser scope would land in Documents (OneDrive) and shadow newer machine-wide versions on every device.
    if (-not $isAdmin) {
        Write-Warn "$m is $status (needed for $why). Install it machine-wide from an elevated pwsh: $command"
        continue
    }
    if (Confirm-Step "$m is $status (needed for $why). Install it from '$Repository' for all users (Program Files, not synced)?") {
        Write-Step "Installing $m from $Repository"
        if ($hasPSResourceGet) {
            # The confirmation names the repository, so it is trusted for this installation only. Never overwrite
            # commands of other modules when the module is new on this machine.
            $extra = if ($found) { @{} } else { @{ NoClobber = $true } }
            Install-PSResource -Name $m -Repository $Repository -Scope AllUsers -Version "[$min,)" -TrustRepository -Quiet @extra
        } else {
            Install-Module -Name $m -Repository $Repository -Scope AllUsers -MinimumVersion $min
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

# 3) module (synced code)
$userModules = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules'))
$modulePaths = @($env:PSModulePath -split [IO.Path]::PathSeparator | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') })
if (-not $ModulePath) {
    $ModulePath = $modulePaths | Where-Object { $_ -ieq $userModules.TrimEnd('\') } | Select-Object -First 1
    if (-not $ModulePath) { $ModulePath = $userModules }
}
$ModulePath = [IO.Path]::GetFullPath($ModulePath).TrimEnd('\')
$target = Join-Path $ModulePath 'Ctx'
$targetManifest = Join-Path $target 'Ctx.psd1'
if ((Test-Path -LiteralPath $target) -and (Get-ChildItem -LiteralPath $target -Force | Select-Object -First 1) -and -not $Force) {
    $existingGuid = if (Test-Path -LiteralPath $targetManifest) { (Import-PowerShellDataFile -LiteralPath $targetManifest).GUID } else { $null }
    if ($existingGuid -ne $ctxGuid) { throw "$target exists and is not ctx. Remove it or use -Force." }
}
if ($target.StartsWith($PSScriptRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "ModulePath must be outside the source folder." }
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
if (Get-OneDriveRoot $target) { Write-Ok 'Code syncs via OneDrive' }
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
    $block = @(
        $begin
        '# ctx - environment switcher. Code + profile sync via OneDrive; logins and state stay on this device (%LOCALAPPDATA%\ctx).'
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
    if (-not (Get-OneDriveRoot $ProfilePath)) { Write-Warn "$ProfilePath is not inside OneDrive - other devices will not load ctx." }
    foreach ($other in @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) | Where-Object { $_ -and $_ -ne $ProfilePath -and (Test-Path -LiteralPath $_) }) {
        if ((Get-Content -LiteralPath $other -Raw) -match [regex]::Escape($begin)) { Write-Warn "$other also contains a ctx block - remove one of them." }
    }
}

# 5) load it now
Import-Module $targetManifest -Force -Global
$dataDir = if ($env:CTX_HOME) { $env:CTX_HOME } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ctx' }
if (Get-OneDriveRoot $dataDir) { Write-Warn "Data folder $dataDir is inside OneDrive - logins would sync. Point CTX_HOME to a local folder." }
else { Write-Ok "Data folder (this device only): $dataDir" }
Write-Host ''
Write-Host '  Next steps' -ForegroundColor Cyan
Write-Host '    ctx add switzerland contoso.onmicrosoft.com    create an environment (device code sign-in)'
Write-Host '    ctx switzerland -Admin                          switch + Global Admin (PIM) + Graph'
Write-Host '    ctx help                                        cheat sheet'
Write-Host '    ctx doctor                                      check everything'
Write-Host ''
Write-Host '  Other devices get the code and profile through OneDrive; environments are per device' -ForegroundColor DarkGray
Write-Host '  (ctx export <file> here, ctx import <file> there, then ctx <name> signs in).' -ForegroundColor DarkGray
Write-Host '  Terminals that are already open: run  ctx sync  (or open a new terminal).' -ForegroundColor DarkGray
Write-Host ''
