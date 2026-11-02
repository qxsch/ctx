#Requires -Version 7.2
<#
.SYNOPSIS
Removes ctx: profile blocks and installed module, and restores AZURE_CONFIG_DIR / AZURE_EXTENSION_DIR on this device.
.DESCRIPTION
Windows: the profile block and the module folder sync via OneDrive, so removing them affects all devices. The user
variables and the data folder are per device: other devices keep their AZURE_CONFIG_DIR user variable (az keeps
working with the last environment) until you reset it there.
Linux/macOS: everything is per device. The ctx blocks in ~/.bashrc, ~/.zshenv, ~/.profile and the fish conf.d file
are removed, and global.env (plus the launchctl values on macOS) is put back to what it was before ctx.
.PARAMETER RemoveData
Also delete the ctx data folder of this device (CLI logins of all environments, saved Graph credentials, state, config),
the ctx:* Az PowerShell contexts and, on Linux/macOS, the key of saved Graph credentials in the Keychain / Secret
Service. Browser profiles ('ctx-<name>') are listed but not deleted. The folder is only deleted when it contains nothing
but ctx data and is not a protected folder (drive root, home, Documents, OneDrive, ~/.local/share, ...).
.PARAMETER KeepModule
Keep the installed module and the profile blocks (only clean up this device).
#>
[CmdletBinding(SupportsShouldProcess)]
param([switch]$RemoveData, [switch]$KeepModule)
$ErrorActionPreference = 'Stop'
$sep = [IO.Path]::DirectorySeparatorChar

function Write-Ok([string]$Text) { Write-Host "  ✓ $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "  ! $Text" -ForegroundColor Yellow }
function Get-DataFolderProblem([string]$Path) {
    <# Returns why $Path must not be deleted recursively, or $null when it only holds ctx data. #>
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if (-not $full) { return 'the file system root is protected' }
    $protected = @(
        [IO.Path]::GetPathRoot($full), $HOME, $env:USERPROFILE, $env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer,
        [Environment]::GetFolderPath('LocalApplicationData'), [Environment]::GetFolderPath('ApplicationData'),
        [Environment]::GetFolderPath('MyDocuments'), [Environment]::GetFolderPath('Windows'), $env:ProgramFiles, ${env:ProgramFiles(x86)},
        $env:XDG_DATA_HOME, $env:XDG_CONFIG_HOME, (Join-Path $HOME '.local'), (Join-Path $HOME '.local/share'), (Join-Path $HOME '.config'),
        (Join-Path $HOME 'Library'), (Join-Path $HOME 'Library/Application Support')
    ) | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\', '/') }
    foreach ($p in $protected) {
        if (-not $p) { continue }
        if ($full -ieq $p -or $p.StartsWith("$full$sep", [StringComparison]::OrdinalIgnoreCase)) { return "$full is or contains a protected folder ($p)" }
    }
    $items = @(Get-ChildItem -LiteralPath $full -Force)
    $foreign = @($items | Where-Object { $_.Name -notmatch '^((environments|config|graph-permissions)\.json(\.bak|\.tmp)?|global\.env(\.tmp)?|\.lock|userenv\.json|cli|graph)$' })
    if ($foreign.Count) { return "$full contains files ctx did not create ($(($foreign | Select-Object -First 5 | ForEach-Object Name) -join ', '))" }
    $null
}
function Get-DefaultDataDir {
    if ($IsWindows) { return Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ctx' }
    if ($IsMacOS) { return Join-Path $HOME 'Library/Application Support/ctx' }
    $base = if ($env:XDG_DATA_HOME -and [IO.Path]::IsPathRooted($env:XDG_DATA_HOME)) { $env:XDG_DATA_HOME } else { Join-Path $HOME '.local/share' }
    Join-Path $base 'ctx'
}
function Set-NewProcessVariable([string]$Name, [AllowNull()][string]$Value) {
    <# Windows: user variable. Linux/macOS: global.env in the data folder (read by the shell blocks) and launchctl. #>
    if ($IsWindows) { [Environment]::SetEnvironmentVariable($Name, $(if ($Value) { $Value } else { $null }), 'User'); return }
    $file = Join-Path $dataDir 'global.env'
    if (Test-Path -LiteralPath $file) {
        $lines = @([IO.File]::ReadAllLines($file) | Where-Object { $_ -notmatch "^$([regex]::Escape($Name))=" })
        if ($Value) { $lines += "$Name=$Value" }
        [IO.File]::WriteAllText($file, (($lines -join "`n") + "`n"))
    }
    if ($IsMacOS -and (Get-Command launchctl -CommandType Application -ErrorAction SilentlyContinue)) {
        if ($Value) { & launchctl setenv $Name $Value 2>$null } else { & launchctl unsetenv $Name 2>$null }
    }
}
function Get-NewProcessVariable([string]$Name) {
    if ($IsWindows) { return [Environment]::GetEnvironmentVariable($Name, 'User') }
    $file = Join-Path $dataDir 'global.env'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $line = [IO.File]::ReadAllLines($file) | Where-Object { $_ -match "^$([regex]::Escape($Name))=" } | Select-Object -First 1
    if ($line) { $line.Substring($Name.Length + 1) } else { $null }
}

$dataDir = if ($env:CTX_HOME) { $env:CTX_HOME } else { Get-DefaultDataDir }
$stateFile = Join-Path $dataDir 'environments.json'
$state = if (Test-Path -LiteralPath $stateFile) { [IO.File]::ReadAllText($stateFile) | ConvertFrom-Json -AsHashtable -Depth 32 } else { $null }

if (Get-Module Ctx) { Remove-Module Ctx -Force }

if (-not $KeepModule) {
    # 1) profile blocks (Windows: shared via OneDrive)
    $pattern = '(?s)\r?\n?# >>> ctx >>>.*?# <<< ctx <<<\r?\n?'
    $profiles = @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost)
    if (-not $IsWindows) { $profiles += @('.bashrc', '.zshenv', '.profile' | ForEach-Object { Join-Path $HOME $_ }) }
    foreach ($p in $profiles | Select-Object -Unique) {
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        $content = [IO.File]::ReadAllText($p)
        if ($content -match $pattern -and $PSCmdlet.ShouldProcess($p, 'Remove ctx block')) {
            [IO.File]::WriteAllText($p, [regex]::Replace($content, $pattern, [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            Write-Ok "Removed ctx from $p"
        }
    }
    $fishFile = Join-Path $HOME '.config/fish/conf.d/ctx.fish'
    if (-not $IsWindows -and (Test-Path -LiteralPath $fishFile) -and ([IO.File]::ReadAllText($fishFile) -match '# >>> ctx >>>') -and $PSCmdlet.ShouldProcess($fishFile, 'Delete')) {
        Remove-Item -LiteralPath $fishFile -Force
        Write-Ok "Removed $fishFile"
    }

    # 2) installed module (shared) - only folders that really contain ctx, never the source folder
    $ctxGuid = (Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'Ctx\Ctx.psd1')).GUID
    $sourceDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Ctx'))
    foreach ($root in @($env:PSModulePath -split [IO.Path]::PathSeparator | Where-Object { $_ } | Select-Object -Unique)) {
        $dir = Join-Path $root 'Ctx'
        $manifest = Join-Path $dir 'Ctx.psd1'
        if (-not (Test-Path -LiteralPath $manifest)) { continue }
        if ([IO.Path]::GetFullPath($dir) -ieq $sourceDir) { continue }
        if ((Import-PowerShellDataFile -LiteralPath $manifest).GUID -ne $ctxGuid) { continue }
        $where = if ($IsWindows) { 'Remove installed ctx module (all devices via OneDrive)' } else { 'Remove installed ctx module' }
        if ($PSCmdlet.ShouldProcess($dir, $where)) {
            Remove-Item -LiteralPath $dir -Recurse -Force
            Write-Ok "Removed module $dir"
        }
    }
}

# 3) variables for new processes (this device): Windows user variables, Linux/macOS global.env + launchctl
if ($state -and $state.original -and $state.original.saved) {
    $cfg = $state.original.azureConfigDir
    if ($PSCmdlet.ShouldProcess('AZURE_CONFIG_DIR', "Restore to '$cfg'")) {
        Set-NewProcessVariable 'AZURE_CONFIG_DIR' $cfg
        Write-Ok "AZURE_CONFIG_DIR restored ($(if ($cfg) { $cfg } else { 'unset - az uses ~/.azure again' }))"
    }
    if ($state.original.managedExtensionDir) {
        $ext = $state.original.azureExtensionDir
        if ($PSCmdlet.ShouldProcess('AZURE_EXTENSION_DIR', "Restore to '$ext'")) {
            Set-NewProcessVariable 'AZURE_EXTENSION_DIR' $ext
            Write-Ok "AZURE_EXTENSION_DIR restored ($(if ($ext) { $ext } else { 'unset' }))"
        }
    }
} else {
    $cur = Get-NewProcessVariable 'AZURE_CONFIG_DIR'
    if ($cur -and $cur.StartsWith($dataDir, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Warn "AZURE_CONFIG_DIR still points into the ctx data folder ($cur) and no original value is known."
        if ($PSCmdlet.ShouldProcess('AZURE_CONFIG_DIR', 'Unset')) { Set-NewProcessVariable 'AZURE_CONFIG_DIR' $null; Write-Ok 'AZURE_CONFIG_DIR unset' }
    }
}

# 4) data (this device)
if ($RemoveData) {
    if (Get-Module -ListAvailable -Name Az.Accounts) {
        try {
            Import-Module Az.Accounts -ErrorAction Stop -WarningAction SilentlyContinue
            foreach ($c in @(Get-AzContext -ListAvailable -WarningAction SilentlyContinue | Where-Object { $_.Name -like 'ctx:*' })) {
                if ($PSCmdlet.ShouldProcess($c.Name, 'Remove Az context')) {
                    Remove-AzContext -Name $c.Name -Force -Scope CurrentUser -WarningAction SilentlyContinue | Out-Null
                    Write-Ok "Az context '$($c.Name)' removed"
                }
            }
        } catch { Write-Warn "Az contexts not removed: $($_.Exception.Message)" }
    }
    # Linux/macOS: the key of saved Graph credentials lives in the user's keyring, outside the data folder.
    $PSNativeCommandUseErrorActionPreference = $false
    if ($IsMacOS -and (Get-Command security -CommandType Application -ErrorAction SilentlyContinue) -and $PSCmdlet.ShouldProcess('Keychain item ctx.graph-credentials', 'Delete')) {
        & security delete-generic-password -a ctx -s ctx.graph-credentials 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok 'Keychain item ctx.graph-credentials removed' }
    }
    if ($IsLinux -and (Get-Command secret-tool -CommandType Application -ErrorAction SilentlyContinue) -and $PSCmdlet.ShouldProcess('Secret Service item ctx.graph-credentials', 'Delete')) {
        & secret-tool clear service ctx key ctx.graph-credentials 2>$null | Out-Null
    }
    if (Test-Path -LiteralPath $dataDir) {
        $problem = Get-DataFolderProblem $dataDir
        if ($problem) {
            Write-Warn "Data folder not deleted: $problem. Delete it manually if that is intended."
        } elseif ($PSCmdlet.ShouldProcess($dataDir, 'Delete ctx data folder')) {
            Remove-Item -LiteralPath $dataDir -Recurse -Force
            Write-Ok "Deleted $dataDir"
        }
    }
    if ($state) {
        $profiles = @($state.environments | ForEach-Object { if ($_.browserProfile) { $_.browserProfile } else { "ctx-$($_.name)" } })
        if ($profiles.Count) {
            Write-Warn "Browser profiles are kept (delete them in the browser if you like): $($profiles -join ', ')"
        }
    }
}
Write-Host ''
Write-Host '  ctx uninstalled. Open a new terminal.' -ForegroundColor Cyan
if (-not $KeepModule -and $IsWindows) {
    Write-Host '  Other devices: their AZURE_CONFIG_DIR / AZURE_EXTENSION_DIR user variables still point to their ctx data.' -ForegroundColor DarkGray
    Write-Host "  Reset them there: [Environment]::SetEnvironmentVariable('AZURE_CONFIG_DIR', `$null, 'User') (same for AZURE_EXTENSION_DIR)" -ForegroundColor DarkGray
}
Write-Host ''
