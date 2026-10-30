#Requires -Version 7.2
<#
.SYNOPSIS
Removes ctx: profile block and installed module (shared via OneDrive), and restores AZURE_CONFIG_DIR /
AZURE_EXTENSION_DIR on this device.
.DESCRIPTION
The profile block and the module folder sync via OneDrive, so removing them affects all devices. The user variables
and the data folder are per device: other devices keep their AZURE_CONFIG_DIR user variable (az keeps working with
the last environment) until you reset it there.
.PARAMETER RemoveData
Also delete the ctx data folder of this device (CLI logins of all environments, state, config) and the ctx:* Az
PowerShell contexts. Browser profiles (Edge 'ctx-<name>') are listed but not deleted. The folder is only deleted when
it contains nothing but ctx data and is not a protected folder (drive root, profile, Documents, OneDrive, ...).
.PARAMETER KeepModule
Keep the installed module and the profile block (only clean up this device).
#>
[CmdletBinding(SupportsShouldProcess)]
param([switch]$RemoveData, [switch]$KeepModule)
$ErrorActionPreference = 'Stop'

function Write-Ok([string]$Text) { Write-Host "  ✓ $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "  ! $Text" -ForegroundColor Yellow }
function Get-DataFolderProblem([string]$Path) {
    <# Returns why $Path must not be deleted recursively, or $null when it only holds ctx data. #>
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $protected = @(
        [IO.Path]::GetPathRoot($full), $HOME, $env:USERPROFILE, $env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer,
        [Environment]::GetFolderPath('LocalApplicationData'), [Environment]::GetFolderPath('ApplicationData'),
        [Environment]::GetFolderPath('MyDocuments'), [Environment]::GetFolderPath('Windows'), $env:ProgramFiles, ${env:ProgramFiles(x86)}
    ) | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') }
    foreach ($p in $protected) {
        if ($full -ieq $p -or $p.StartsWith("$full\", [StringComparison]::OrdinalIgnoreCase)) { return "$full is or contains a protected folder ($p)" }
    }
    $items = @(Get-ChildItem -LiteralPath $full -Force)
    $foreign = @($items | Where-Object { $_.Name -notmatch '^((environments|config|graph-permissions)\.json(\.bak|\.tmp)?|userenv\.json|cli)$' })
    if ($foreign.Count) { return "$full contains files ctx did not create ($(($foreign | Select-Object -First 5 | ForEach-Object Name) -join ', '))" }
    $null
}

$dataDir = if ($env:CTX_HOME) { $env:CTX_HOME } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ctx' }
$stateFile = Join-Path $dataDir 'environments.json'
$state = if (Test-Path -LiteralPath $stateFile) { [IO.File]::ReadAllText($stateFile) | ConvertFrom-Json -AsHashtable -Depth 32 } else { $null }

if (Get-Module Ctx) { Remove-Module Ctx -Force }

if (-not $KeepModule) {
    # 1) profile block (shared)
    $pattern = '(?s)\r?\n?# >>> ctx >>>.*?# <<< ctx <<<\r?\n?'
    foreach ($p in @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) | Select-Object -Unique) {
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        $content = [IO.File]::ReadAllText($p)
        if ($content -match $pattern -and $PSCmdlet.ShouldProcess($p, 'Remove ctx block')) {
            [IO.File]::WriteAllText($p, [regex]::Replace($content, $pattern, [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            Write-Ok "Removed ctx from $p"
        }
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
        if ($PSCmdlet.ShouldProcess($dir, 'Remove installed ctx module (all devices via OneDrive)')) {
            Remove-Item -LiteralPath $dir -Recurse -Force
            Write-Ok "Removed module $dir"
        }
    }
}

# 3) user environment variables (this device)
if ($state -and $state.original -and $state.original.saved) {
    $cfg = $state.original.azureConfigDir
    if ($PSCmdlet.ShouldProcess('AZURE_CONFIG_DIR', "Restore to '$cfg'")) {
        [Environment]::SetEnvironmentVariable('AZURE_CONFIG_DIR', $(if ($cfg) { $cfg } else { $null }), 'User')
        Write-Ok "AZURE_CONFIG_DIR restored ($(if ($cfg) { $cfg } else { 'unset - az uses ~\.azure again' }))"
    }
    if ($state.original.managedExtensionDir) {
        $ext = $state.original.azureExtensionDir
        if ($PSCmdlet.ShouldProcess('AZURE_EXTENSION_DIR', "Restore to '$ext'")) {
            [Environment]::SetEnvironmentVariable('AZURE_EXTENSION_DIR', $(if ($ext) { $ext } else { $null }), 'User')
            Write-Ok "AZURE_EXTENSION_DIR restored ($(if ($ext) { $ext } else { 'unset' }))"
        }
    }
} else {
    $cur = [Environment]::GetEnvironmentVariable('AZURE_CONFIG_DIR', 'User')
    if ($cur -and $cur.StartsWith($dataDir, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Warn "AZURE_CONFIG_DIR still points into the ctx data folder ($cur) and no original value is known."
        if ($PSCmdlet.ShouldProcess('AZURE_CONFIG_DIR', 'Unset')) { [Environment]::SetEnvironmentVariable('AZURE_CONFIG_DIR', $null, 'User'); Write-Ok 'AZURE_CONFIG_DIR unset' }
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
            Write-Warn "Browser profiles are kept (delete them in Edge if you like): $($profiles -join ', ')"
        }
    }
}
Write-Host ''
Write-Host '  ctx uninstalled. Open a new terminal.' -ForegroundColor Cyan
if (-not $KeepModule) {
    Write-Host '  Other devices: their AZURE_CONFIG_DIR / AZURE_EXTENSION_DIR user variables still point to their ctx data.' -ForegroundColor DarkGray
    Write-Host "  Reset them there: [Environment]::SetEnvironmentVariable('AZURE_CONFIG_DIR', `$null, 'User') (same for AZURE_EXTENSION_DIR)" -ForegroundColor DarkGray
}
Write-Host ''
