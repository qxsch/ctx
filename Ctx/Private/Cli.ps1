# Azure CLI: one AZURE_CONFIG_DIR per environment (own token cache + own default subscription).

function Get-CtxAzCliPath {
    $cmd = Get-Command az.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { $cmd = Get-Command az -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($cmd) { $cmd.Source } else { $null }
}

function Get-CtxCliDir {
    param([Parameter(Mandatory)][string]$Name)
    Join-Path (Join-Path (Get-CtxHome) 'cli') $Name
}

function Get-CtxOriginalCliDir {
    param($State)
    if (-not $State) { $State = Read-CtxState }
    $orig = if ($State.original.saved) { $State.original.azureConfigDir } else { (Get-CtxUserEnv 'AZURE_CONFIG_DIR') }
    if ($orig) { $orig } else { Join-Path $HOME '.azure' }
}

function Get-CtxSharedExtensionDir {
    param($State)
    if (-not $State) { $State = Read-CtxState }
    $orig = if ($State.original.saved) { $State.original.azureExtensionDir } else { (Get-CtxUserEnv 'AZURE_EXTENSION_DIR') }
    if ($orig) { return $orig }
    Join-Path (Get-CtxOriginalCliDir $State) 'cliextensions'
}

function Assert-CtxAzCliArgument {
    <#
    az is a batch file (az.cmd): cmd.exe re-parses its command line, and quoting cannot reliably neutralize its
    metacharacters, so arguments that contain them are refused instead of being passed on.
    #>
    param([AllowEmptyCollection()][string[]]$Arguments)
    foreach ($a in $Arguments) {
        if ($a -match '["%!^&|<>\r\n]') {
            throw "Refusing to pass an argument with shell metacharacters to az: '$(ConvertTo-CtxSafeText $a -MaxLength 80)'"
        }
    }
}

function Invoke-CtxAzCli {
    <# Runs az against a specific config dir. Returns ExitCode/Output/Error/Value. #>
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$Json
    )
    $az = Get-CtxAzCliPath
    if (-not $az) { throw 'Azure CLI (az) not found. Install it or remove "cli" from the environment tools.' }
    Assert-CtxAzCliArgument $Arguments
    $saved = $env:AZURE_CONFIG_DIR
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $env:AZURE_CONFIG_DIR = $ConfigDir
        $all = & $az @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        $env:AZURE_CONFIG_DIR = $saved
    }
    $out = (@($all) | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }) -join "`n"
    $err = (@($all) | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join "`n"
    $value = $null
    if ($Json -and $code -eq 0 -and $out.Trim()) { $value = $out | ConvertFrom-Json }
    [pscustomobject]@{ ExitCode = $code; Success = ($code -eq 0); Output = $out; Error = $err; Value = $value }
}

function Set-CtxIniValue {
    <# Minimal INI writer for the az CLI config file. #>
    param([string]$Path, [string]$Section, [string]$Key, [string]$Value)
    $lines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $Path) { foreach ($l in [IO.File]::ReadAllLines($Path)) { $lines.Add($l) } }
    $sectionIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -ieq "[$Section]") { $sectionIdx = $i; break } }
    if ($sectionIdx -lt 0) {
        if ($lines.Count -and $lines[$lines.Count - 1].Trim()) { $lines.Add('') }
        $lines.Add("[$Section]"); $lines.Add("$Key = $Value")
    } else {
        $end = $lines.Count
        for ($j = $sectionIdx + 1; $j -lt $lines.Count; $j++) { if ($lines[$j].Trim() -match '^\[.+\]$') { $end = $j; break } }
        $found = $false
        for ($j = $sectionIdx + 1; $j -lt $end; $j++) {
            if ($lines[$j] -match "^\s*$([regex]::Escape($Key))\s*=") { $lines[$j] = "$Key = $Value"; $found = $true; break }
        }
        if (-not $found) { $lines.Insert($end, "$Key = $Value") }
    }
    [IO.File]::WriteAllLines($Path, $lines)
}

function Initialize-CtxCliDir {
    <# Creates a CLI config dir, inheriting the user's az settings, with the interactive subscription picker off. #>
    param([Parameter(Mandatory)][string]$Dir)
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $target = Join-Path $Dir 'config'
    $source = Join-Path (Get-CtxOriginalCliDir) 'config'
    if (-not (Test-Path -LiteralPath $target) -and (Test-Path -LiteralPath $source)) {
        Copy-Item -LiteralPath $source -Destination $target
    }
    Set-CtxIniValue -Path $target -Section 'core' -Key 'login_experience_v2' -Value 'off'
}

function Get-CtxCliProfile {
    <# Reads azureProfile.json of an environment's CLI dir (fast, offline). #>
    param([Parameter(Mandatory)][string]$Dir)
    $file = Join-Path $Dir 'azureProfile.json'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try { (Get-Content -LiteralPath $file -Raw -Encoding utf8) | ConvertFrom-Json } catch { $null }
}

function Get-CtxCliSubscriptions {
    param([Parameter(Mandatory)]$Entry, [string]$Dir)
    if (-not $Dir) { $Dir = Get-CtxCliDir $Entry.name }
    $p = Get-CtxCliProfile $Dir
    if (-not $p) { return @() }
    @($p.subscriptions | Where-Object { $_.tenantId -ieq $Entry.tenantId -and $_.id -ine $Entry.tenantId })
}

function Get-CtxCliDefaultSubscription {
    param([Parameter(Mandatory)]$Entry, [string]$Dir)
    if (-not $Dir) { $Dir = Get-CtxCliDir $Entry.name }
    $p = Get-CtxCliProfile $Dir
    if (-not $p) { return $null }
    $p.subscriptions | Where-Object { $_.isDefault } | Select-Object -First 1
}

function Save-CtxOriginalEnvironment {
    param($State)
    if ($State.original.saved) { return }
    $State.original.azureConfigDir = (Get-CtxUserEnv 'AZURE_CONFIG_DIR')
    $State.original.azureExtensionDir = (Get-CtxUserEnv 'AZURE_EXTENSION_DIR')
    $State.original.managedExtensionDir = $false
    $State.original.saved = $true
}

function Set-CtxCliEnvironment {
    <# Points az to the environment's config dir: this process always, all new terminals with -Scope User. #>
    param([Parameter(Mandatory)]$Entry, [ValidateSet('Process', 'User')][string]$Scope = 'User')
    $dir = Get-CtxCliDir $Entry.name
    $env:AZURE_CONFIG_DIR = $dir
    $cfg = Get-CtxConfig
    $state = Read-CtxState
    if ($Scope -eq 'User') {
        $needsSave = -not $state.original.saved -or
            ($cfg.shareCliExtensions -and -not $state.original.azureExtensionDir -and -not $state.original.managedExtensionDir)
        if ($needsSave) {
            $state = Update-CtxState {
                param($s)
                Save-CtxOriginalEnvironment $s
                if ($cfg.shareCliExtensions -and -not $s.original.azureExtensionDir) { $s.original.managedExtensionDir = $true }
            }
        }
        if ((Get-CtxUserEnv 'AZURE_CONFIG_DIR') -ne $dir) {
            Set-CtxUserEnv 'AZURE_CONFIG_DIR' $dir
        }
    }
    if ($state.original.managedExtensionDir) {
        $ext = Get-CtxSharedExtensionDir $state
        if (-not (Test-Path -LiteralPath $ext)) { New-Item -ItemType Directory -Path $ext -Force | Out-Null }
        $env:AZURE_EXTENSION_DIR = $ext
        if ($Scope -eq 'User' -and (Get-CtxUserEnv 'AZURE_EXTENSION_DIR') -ne $ext) {
            Set-CtxUserEnv 'AZURE_EXTENSION_DIR' $ext
        }
    }
}

function Reset-CtxCliEnvironment {
    <# Restores AZURE_CONFIG_DIR / AZURE_EXTENSION_DIR to what they were before ctx managed them. #>
    param([switch]$Process, [switch]$User)
    $state = Read-CtxState
    if (-not $state.original.saved) { return }
    $origCfg = $state.original.azureConfigDir
    $origExt = $state.original.azureExtensionDir
    if ($User) {
        Set-CtxUserEnv 'AZURE_CONFIG_DIR' $(if ($origCfg) { $origCfg } else { $null })
        if ($state.original.managedExtensionDir) {
            Set-CtxUserEnv 'AZURE_EXTENSION_DIR' $(if ($origExt) { $origExt } else { $null })
        }
    }
    if ($Process) {
        $env:AZURE_CONFIG_DIR = if ($origCfg) { $origCfg } else { $null }
        if ($state.original.managedExtensionDir) { $env:AZURE_EXTENSION_DIR = if ($origExt) { $origExt } else { $null } }
    }
}

function Start-CtxCliTokenCheck {
    <# Starts `az account get-access-token` in the background so the CLI check overlaps with the Az PowerShell work. #>
    param([Parameter(Mandatory)]$Entry)
    $az = Get-CtxAzCliPath
    if (-not $az) { return $null }
    $cliArgs = @('account', 'get-access-token', '--tenant', [string]$Entry.tenantId, '--query', 'accessToken', '-o', 'tsv', '--only-show-errors')
    Assert-CtxAzCliArgument $cliArgs
    $psi = [Diagnostics.ProcessStartInfo]::new($az)
    foreach ($a in $cliArgs) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.Environment['AZURE_CONFIG_DIR'] = Get-CtxCliDir $Entry.name
    $p = [Diagnostics.Process]::Start($psi)
    [pscustomobject]@{ Process = $p; Stdout = $p.StandardOutput.ReadToEndAsync(); Stderr = $p.StandardError.ReadToEndAsync(); Entry = $Entry }
}

function Complete-CtxCliTokenCheck {
    param($Handle, [int]$TimeoutSeconds = 90)
    if (-not $Handle) { return [pscustomobject]@{ Ok = $false; Reason = 'Azure CLI not installed'; Identity = $null; Missing = $true } }
    if (-not $Handle.Process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $Handle.Process.Kill($true) } catch { Write-Debug "ctx: could not stop the timed-out az process: $_" }
        return [pscustomobject]@{ Ok = $false; Reason = 'timed out'; Identity = $null; Missing = $false }
    }
    $Handle.Process.WaitForExit()
    $token = $Handle.Stdout.Result.Trim()
    $errText = ($Handle.Stderr.Result.Trim() -split "`r?`n" | Select-Object -First 1) -replace '^\s*ERROR:\s*', ''
    if ($errText -match "az login|setup account|No subscription found") { $errText = 'not signed in yet' }
    elseif ($errText -match 'AADSTS(700082|70043|50173|50078|50076|50079)') { $errText = "session expired or needs MFA ($($Matches[0]))" }
    if ($Handle.Process.ExitCode -ne 0 -or -not $token) {
        return [pscustomobject]@{ Ok = $false; Reason = $(if ($errText) { $errText } else { 'not signed in' }); Identity = $null; Missing = $false }
    }
    $id = try { Get-CtxIdentityFromClaims (ConvertFrom-CtxJwt $token) } catch { $null }
    if (-not (Test-CtxIdentityMatch $Handle.Entry $id)) {
        return [pscustomobject]@{ Ok = $false; Reason = "signed in as '$($id.Upn)' (expected $($Handle.Entry.upn))"; Identity = $id; Missing = $false }
    }
    [pscustomobject]@{ Ok = $true; Reason = $null; Identity = $id; Missing = $false }
}

function Connect-CtxCli {
    <#
    Interactive Azure CLI login inside the environment's config dir, with the environment's sign-in method:
    DeviceCode (az login --use-device-code), Browser (sign-in page in the environment's browser profile, WAM off)
    or Broker (Windows account manager). Returns the identity from the token.
    #>
    param([Parameter(Mandatory)]$Entry, [string]$Dir, [string]$Tenant)
    if (-not $Dir) { $Dir = Get-CtxCliDir $Entry.name }
    $method = Get-CtxSignInMethod $Entry
    Assert-CtxSignInMethodSupported -Method $method -Entry $Entry
    Initialize-CtxCliDir $Dir
    $az = Get-CtxAzCliPath
    if (-not $az) { throw 'Azure CLI (az) not found.' }
    $loginArgs = @('login')
    if ($method -eq 'DeviceCode') { $loginArgs += '--use-device-code' }
    $loginArgs += @('--allow-no-subscriptions', '-o', 'none')
    $t = if ($Tenant) { $Tenant } else { $Entry.tenantId }
    if ($t) { $loginArgs += @('--tenant', $t) }
    Assert-CtxAzCliArgument $loginArgs
    if ($method -ne 'DeviceCode' -and $IsWindows) {
        # Stored in the environment's own config, so later silent token requests use the same path as the sign-in.
        Set-CtxIniValue -Path (Join-Path $Dir 'config') -Section 'core' -Key 'enable_broker_on_windows' -Value $(if ($method -eq 'Broker') { 'true' } else { 'false' })
    }
    $browserCommand = if ($method -eq 'Browser') { Get-CtxBrowserCommandLine $Entry } else { $null }
    if ($method -ne 'DeviceCode') {
        $detail = if ($method -eq 'Broker') { $null } elseif ($browserCommand) { $null } else { 'default browser - finish the sign-in there' }
        Show-CtxSignInStart -Tool 'Azure CLI' -Entry $Entry -Method $method -Detail $detail
    }
    $saved = $env:AZURE_CONFIG_DIR
    $savedBrowser = $env:BROWSER
    try {
        $env:AZURE_CONFIG_DIR = $Dir
        if ($browserCommand) { $env:BROWSER = $browserCommand }
        $sb = { & $az @loginArgs }.GetNewClosure()
        Invoke-CtxToolLogin -ScriptBlock $sb -Entry $Entry -Tool 'Azure CLI' -Native | Out-Null
    } catch {
        $hint = Get-CtxSignInFailureHint -Message $_.Exception.Message -Method $method -Entry $Entry
        if ($hint) { throw "$($_.Exception.Message)$hint" }
        throw
    } finally {
        $env:AZURE_CONFIG_DIR = $saved
        $env:BROWSER = $savedBrowser
    }
    $tenantArg = if ($t) { @('--tenant', $t) } else { @() }
    $tok = Invoke-CtxAzCli -ConfigDir $Dir -Arguments (@('account', 'get-access-token', '--query', 'accessToken', '-o', 'tsv') + $tenantArg)
    if (-not $tok.Success) { throw "Azure CLI signed in but no token could be acquired: $($tok.Error)" }
    Get-CtxIdentityFromClaims (ConvertFrom-CtxJwt $tok.Output.Trim())
}

function Set-CtxCliSubscription {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$SubscriptionId, [string]$Dir)
    if (-not $Dir) { $Dir = Get-CtxCliDir $Entry.name }
    $r = Invoke-CtxAzCli -ConfigDir $Dir -Arguments @('account', 'set', '--subscription', $SubscriptionId, '--only-show-errors')
    if (-not $r.Success) { throw "az account set failed: $($r.Error)" }
}
