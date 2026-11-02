function Get-CtxStatus {
    <#
    .SYNOPSIS
    Shows the environment of this terminal: tenant, login, subscriptions, Graph and PIM state.
    .PARAMETER Check
    Also verify the Azure CLI and Az PowerShell tokens (network).
    .PARAMETER PassThru
    Return the status object.
    .EXAMPLE
    ctx st -Check
    #>
    [CmdletBinding()]
    param([switch]$Check, [switch]$PassThru)
    $state = Read-CtxState
    $entry = Get-CtxProcessEnvironment -Optional
    if (-not $entry) {
        Write-CtxMsg warn "No environment selected. 'ctx' opens the picker, 'ctx add <name>' creates one."
        return
    }
    $useCli = Test-CtxTool $entry 'cli'
    $useAz = Test-CtxTool $entry 'az'
    $cliSub = if ($useCli) { Get-CtxCliDefaultSubscription $entry } else { $null }
    $cliText = if (-not $useCli) { 'not managed' } elseif ($cliSub -and $cliSub.id -ine $entry.tenantId) { "$($cliSub.name) ($($cliSub.id))" } elseif ($cliSub) { 'tenant level' } else { 'not signed in' }
    $azText = if (-not $useAz) { 'not managed' } elseif (Get-Module Az.Accounts) {
        $c = Get-AzContext -ErrorAction SilentlyContinue
        if ($c -and $c.Name -eq $entry.azContextName) {
            if ($c.Subscription -and $c.Subscription.Id -and $c.Subscription.Id -ine $entry.tenantId) { "$($c.Subscription.Name) ($($c.Subscription.Id))" } else { 'tenant level' }
        } elseif ($c) { "! active context is '$($c.Name)' - 'ctx $($entry.name)' realigns" } else { 'no context' }
    } else {
        $sub = if ($entry.azSubscriptionName) { $entry.azSubscriptionName } else { 'tenant level' }
        "$sub (module not loaded yet)"
    }
    $graphText = if ($script:GraphEnvName -eq $entry.name) {
        $mg = Get-CtxMgContext
        $tokenText = if ($script:GraphToken) {
            $renew = if ($script:GraphToken.Source -eq 'Broker') { "'ctx graph' renews it (Windows account broker)" }
            elseif ($script:GraphToken.RefreshToken -or $script:GraphToken.Source -in $script:CtxGraphProviderSources) { 'renews automatically' } else { "'ctx graph' to renew" }
            $maxHours = 0.0
            [void][double]::TryParse([string](Get-CtxConfig).graphMaxSessionHours, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$maxHours)
            if ($maxHours -gt 0 -and $script:GraphToken.SessionStartedAt -and $renew -eq 'renews automatically') {
                $renew += " until $(([datetime]$script:GraphToken.SessionStartedAt).AddHours($maxHours).ToLocalTime().ToString('HH:mm'))"
            }
            " · token until $($script:GraphToken.ExpiresAt.ToLocalTime().ToString('HH:mm')), $renew"
        } else { '' }
        "connected · $($script:GraphProfileName) · $(@($mg.Scopes).Count) scopes · $($mg.Account)$tokenText"
    } else { "not connected ('ctx graph' or 'ctx pim')" }
    $savedGraphText = if ($entry.saveGraphCredentials -eq $true) {
        $saved = Get-CtxGraphCredentialInfo $entry
        if (-not $saved) { 'on · nothing saved yet (saved at the next Graph sign-in)' }
        elseif ($saved.Expired) { 'on · expired - the next Graph sign-in saves new credentials' }
        else {
            "on · saved $(Format-CtxAgo $saved.SavedAt)" +
            $(if ($saved.RestorableUntil) { ", restorable until $($saved.RestorableUntil.ToLocalTime().ToString('HH:mm'))" } else { '' })
        }
    }
    $acts = @(Get-CtxActiveActivations $entry)
    $pimText = if ($acts.Count) {
        ($acts | ForEach-Object { "$($_.RoleName) $(Format-CtxDuration $_.Remaining) left" + $(if ($_.ExpiresAt) { " (until $($_.ExpiresAt.ToLocalTime().ToString('HH:mm')))" }) }) -join '; '
    } else { 'no active role' + $(if ($entry.activationsCheckedAt) { " (checked $(Format-CtxAgo $entry.activationsCheckedAt))" } else { '' }) }
    $scopeText = if ($script:ProcessLocal) { 'this terminal only' } else { 'global (new terminals follow)' }
    if ($state.current -and $state.current -ne $entry.name) { $scopeText += " · global is '$($state.current)' ('ctx sync' to follow)" }

    $color = Get-CtxEnvColor $entry
    Write-Host ''
    Write-Host '  ' -NoNewline
    Write-Host $entry.name -ForegroundColor $color -NoNewline
    if (Test-CtxProd $entry) { Write-Host '  PRODUCTION' -ForegroundColor White -BackgroundColor DarkRed -NoNewline }
    if ($entry.description) { Write-Host "  $($entry.description)" -ForegroundColor DarkGray -NoNewline }
    Write-Host ''
    $rows = [ordered]@{
        'Tenant'        = "$($entry.tenantName) · $(Get-CtxTenantLabel $entry) · $($entry.tenantId)"
        'Login'         = "$($entry.upn) · $($entry.userObjectId)"
        'Sign-in'       = (Get-CtxSignInMethod $entry) + $(if (-not $entry.signIn) { ' (default)' } else { '' })
        'Scope'         = $scopeText
        'Azure CLI'     = $cliText
        'Az PowerShell' = $azText
        'Graph'         = $graphText
    }
    if ($savedGraphText) { $rows['Saved Graph'] = $savedGraphText }
    $rows['PIM'] = $pimText
    $rows['Tags'] = if (@($entry.tags).Count) { @($entry.tags) -join ', ' } else { '-' }
    foreach ($k in $rows.Keys) {
        Write-Host ('  {0,-14}' -f $k) -ForegroundColor DarkGray -NoNewline
        Write-Host $rows[$k]
    }

    $checks = [ordered]@{}
    if ($Check) {
        $handle = if ($useCli) { Start-CtxCliTokenCheck $entry } else { $null }
        if ($useAz) {
            try {
                Import-CtxAzModule
                $id = Get-CtxAzIdentity -TenantId $entry.tenantId
                $checks['Az PowerShell'] = if (Test-CtxIdentityMatch $entry $id) { "ok · token valid until $($id.ExpiresAt.ToLocalTime().ToString('HH:mm'))" } else { "! signed in as $($id.Upn)" }
            } catch { $checks['Az PowerShell'] = "! $($_.Exception.Message)" }
        }
        if ($useCli) {
            $r = Complete-CtxCliTokenCheck $handle
            $checks['Azure CLI'] = if ($r.Ok) { "ok · token valid until $($r.Identity.ExpiresAt.ToLocalTime().ToString('HH:mm'))" } else { "! $($r.Reason)" }
        }
        Write-Host ''
        foreach ($k in $checks.Keys) {
            $v = $checks[$k]
            if ($v.StartsWith('ok')) { Write-CtxMsg ok "$k $($v.Substring(2).TrimStart(' ·'))" } else { Write-CtxMsg warn "$k $($v.Substring(2)) - 'ctx $($entry.name)' signs in again" }
        }
    }
    Write-Host ''
    if ($PassThru) {
        [pscustomobject]@{
            PSTypeName = 'Ctx.Status'
            Name = $entry.name; TenantId = $entry.tenantId; Tenant = Get-CtxTenantLabel $entry; Upn = $entry.upn
            Local = $script:ProcessLocal; Global = $state.current
            Cli = $cliText; Az = $azText; Graph = $graphText; Pim = $pimText; Checks = $checks
        }
    }
}

function Test-CtxSetup {
    <#
    .SYNOPSIS
    Checks prerequisites, configuration and the logins of all environments.
    .PARAMETER Deep
    Also check the Az PowerShell token of every environment.
    .EXAMPLE
    ctx doctor
    #>
    [CmdletBinding()]
    param([switch]$Deep, [switch]$PassThru)
    $results = [System.Collections.Generic.List[object]]::new()
    $report = {
        param([string]$Area, [string]$Status, [string]$Detail)
        $results.Add([pscustomobject]@{ PSTypeName = 'Ctx.Check'; Area = $Area; Status = $Status; Detail = $Detail })
        $kind = switch ($Status) { 'ok' { 'ok' } 'warn' { 'warn' } 'fail' { 'error' } default { 'dim' } }
        Write-CtxMsg $kind ("{0,-22} {1}" -f $Area, $Detail)
    }
    Write-Host ''
    Write-Host '  Prerequisites' -ForegroundColor Cyan
    $v = $PSVersionTable.PSVersion
    & $report 'PowerShell' $(if ($v -ge [version]'7.2') { 'ok' } else { 'fail' }) "$v"
    $az = Get-CtxAzCliPath
    & $report 'Azure CLI' $(if ($az) { 'ok' } else { 'warn' }) $(if ($az) { $az } else { 'not found (only needed for environments with tool cli)' })
    $sdkCheck = {
        param([string]$Name, [string]$Label, [string]$Need)
        $all = @(Get-Module -ListAvailable -Name $Name)
        if (-not $all) { & $report $Label 'warn' "not installed - needed for $Need. Elevated: Install-PSResource $Name -Scope AllUsers"; return }
        # Import-Module by name takes the highest version from the first PSModulePath folder that has the module.
        $sep = [IO.Path]::DirectorySeparatorChar
        $paths = @($env:PSModulePath -split [IO.Path]::PathSeparator | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\', '/') })
        $root = { param($m) $paths | Where-Object { $m.ModuleBase.StartsWith("$_$sep", [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1 }
        $firstRoot = $paths | Where-Object { $p = $_; $all | Where-Object { (& $root $_) -eq $p } } | Select-Object -First 1
        if (-not $firstRoot) { $firstRoot = Split-Path (Split-Path $all[0].ModuleBase -Parent) -Parent }
        $used = $all | Where-Object { $_.ModuleBase.StartsWith("$firstRoot$sep", [StringComparison]::OrdinalIgnoreCase) } | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $used) { $used = $all[0] }
        $best = $all | Sort-Object Version -Descending | Select-Object -First 1
        if ($best.Version -gt $used.Version) {
            & $report $Label 'warn' "loads $($used.Version) from $firstRoot - newer $($best.Version) is shadowed. Remove the old copy."
        } elseif (Get-CtxOneDriveRoot $used.ModuleBase) {
            & $report $Label 'warn' "$($used.Version) is in OneDrive ($firstRoot) - it syncs to every device and can shadow newer installs. Prefer -Scope AllUsers."
        } else {
            & $report $Label 'ok' "$($used.Version)"
        }
    }
    & $sdkCheck 'Az.Accounts' 'Az.Accounts' 'Az PowerShell switching'
    & $sdkCheck 'Microsoft.Graph.Authentication' 'Graph.Authentication' 'PIM and Graph'
    $browser = Get-CtxBrowserPath
    & $report 'Browser' $(if ($browser) { 'ok' } else { 'warn' }) $(if ($browser) { $browser } else { 'Edge not found - device-code pages open in the default browser' })

    Write-Host ''
    Write-Host '  ctx' -ForegroundColor Cyan
    $homeDir = Get-CtxHome
    if (Get-CtxOneDriveRoot $homeDir) {
        & $report 'Data folder' 'warn' "$homeDir is inside OneDrive - logins and state would sync to other devices. Point CTX_HOME to a local folder."
    } else {
        & $report 'Data folder' 'ok' "$homeDir (this device only)"
    }
    $mode = Get-CtxUnixMode $homeDir
    if ($mode -and ([Convert]::ToInt32($mode, 8) -band 0x3F)) {
        & $report 'Data permissions' 'warn' "$homeDir is mode $mode - other users may read Azure CLI token caches. Fix: chmod 700 '$homeDir'"
    }
    $moduleBase = $MyInvocation.MyCommand.Module.ModuleBase
    if ($moduleBase) {
        & $report 'Module' $(if (Get-CtxOneDriveRoot $moduleBase) { 'ok' } else { 'info' }) $(if (Get-CtxOneDriveRoot $moduleBase) { "$moduleBase (synced via OneDrive)" } else { "$moduleBase (this device only)" })
        $sigCheck = Test-CtxModuleSignature -ModuleBase $moduleBase
        & $report 'Module signature' $sigCheck.Status $sigCheck.Detail
    }
    $state = $null
    try { $state = Read-CtxState; & $report 'State file' 'ok' "$($state.environments.Count) environment(s)" }
    catch { & $report 'State file' 'fail' $_.Exception.Message }
    try {
        $cfgPath = Get-CtxConfigPath
        if (Test-Path -LiteralPath $cfgPath) { $null = [IO.File]::ReadAllText($cfgPath) | ConvertFrom-Json -AsHashtable; & $report 'Config' 'ok' $cfgPath }
        else { & $report 'Config' 'ok' 'defaults' }
    } catch { & $report 'Config' 'fail' "invalid JSON: $($_.Exception.Message)" }
    $profileFiles = @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    $hooked = @($profileFiles | Where-Object { (Get-Content -LiteralPath $_ -Raw) -match 'Ctx\.psd1|Import-Module\s+Ctx' })
    & $report 'Profile' $(if ($hooked.Count) { 'ok' } else { 'warn' }) $(if ($hooked.Count) { "loaded from $($hooked[0])" } else { 'ctx is not imported by your profile - run Install.ps1' })
    $badge = (Get-CtxConfig).promptBadge
    & $report 'Prompt badge' $(if (-not $badge -or $script:CtxPromptInstalled) { 'ok' } else { 'warn' }) $(if (-not $badge) { 'disabled (config promptBadge)' } elseif ($script:CtxPromptInstalled) { 'installed' } else { 'not installed' })

    if ($state) {
        $cur = Find-CtxEnvironment $state $state.current
        $store = if ($IsWindows) { 'user variable' } else { 'global.env' }
        if ($cur -and (Test-CtxTool $cur 'cli')) {
            $userVar = (Get-CtxUserEnv 'AZURE_CONFIG_DIR')
            $want = Get-CtxCliDir $cur.name
            & $report 'AZURE_CONFIG_DIR' $(if ($userVar -eq $want) { 'ok' } else { 'warn' }) $(if ($userVar -eq $want) { "$store → $($cur.name)" } else { "$store is '$userVar', expected '$want' - 'ctx $($cur.name)' fixes it" })
        }
        if (-not $IsWindows -and -not $env:CTX_SANDBOX_USERENV) {
            $readers = @(Get-CtxShellProfileReaders)
            & $report 'Shell profiles' $(if ($readers.Count) { 'ok' } else { 'warn' }) $(if ($readers.Count) { "new shells read global.env: $($readers -join ', ')" } else { 'no shell profile reads global.env - new bash/zsh/fish shells keep ~/.azure. Run Install.ps1' })
        }
        $here = Get-CtxProcessEnvironment -Optional
        if ($here -and (Test-CtxTool $here 'cli') -and $env:AZURE_CONFIG_DIR -ne (Get-CtxCliDir $here.name)) {
            & $report 'This terminal' 'warn' "AZURE_CONFIG_DIR does not point to '$($here.name)' - 'ctx $($here.name) -Local' fixes it"
        }
        $groups = @($state.environments | Group-Object { "$($_.tenantId)|$($_.userObjectId)".ToLowerInvariant() } | Where-Object Count -GT 1)
        foreach ($g in $groups) { & $report 'Duplicates' 'warn' "same tenant + login: $(($g.Group | ForEach-Object name) -join ', ') - remove one" }
        $invalid = @{}
        foreach ($e in $state.environments) {
            $problems = @(Get-CtxEntryProblem $e)
            if ($problems.Count) {
                $invalid[$e.name] = $true
                & $report "Environment $($e.name)" 'fail' "$($problems -join '; ') - remove it: ctx rm $($e.name)"
            }
        }
        $cliRoot = Join-Path (Get-CtxHome) 'cli'
        if (Test-Path -LiteralPath $cliRoot) {
            $names = @($state.environments | ForEach-Object name)
            foreach ($d in Get-ChildItem -LiteralPath $cliRoot -Directory) {
                if ($names -notcontains $d.Name) { & $report 'Orphan folder' 'warn' "$($d.FullName) (no environment - safe to delete)" }
            }
        }
        $graphRoot = Join-Path (Get-CtxHome) 'graph'
        if (Test-Path -LiteralPath $graphRoot) {
            foreach ($f in Get-ChildItem -LiteralPath $graphRoot -File | Where-Object Name -NE '.key') {
                $owner = Find-CtxEnvironment $state ([IO.Path]::GetFileNameWithoutExtension($f.Name))
                if (-not $owner -or $owner.saveGraphCredentials -ne $true) {
                    & $report 'Saved Graph credentials' 'warn' "$($f.FullName) belongs to no environment that saves credentials - safe to delete"
                }
            }
        }
        if (-not $IsWindows -and @($state.environments | Where-Object { $_.saveGraphCredentials -eq $true }).Count) {
            $why = Get-CtxSecretStoreProblem
            $kindText = switch (Get-CtxSecretStoreKind) { 'keychain' { 'macOS Keychain' } 'secret-service' { 'Secret Service (secret-tool)' } 'file' { "key file $(Get-CtxSecretKeyFile) (graphCredentialStore file)" } default { 'none' } }
            & $report 'Graph credential key' $(if ($why) { 'warn' } else { 'ok' }) $(if ($why) { $why } else { $kindText })
        }

        $azMod = Test-CtxAzAvailable
        if ($azMod) {
            try {
                Import-CtxAzModule
                Sync-CtxAzProfileFromDisk
                $autoMode = Get-CtxAzAutosaveMode
                & $report 'Az autosave' $(if ($autoMode -eq 'CurrentUser') { 'ok' } else { 'warn' }) "$autoMode"
                $ctxNames = @(Get-CtxAzContextNames)
                $known = @($state.environments | ForEach-Object azContextName)
                foreach ($n in @($ctxNames | Where-Object { $_ -like 'ctx:*' -and $known -notcontains $_ })) {
                    & $report 'Orphan Az context' 'warn' "$n (Remove-AzContext -Name '$n')"
                }
            } catch { & $report 'Az PowerShell' 'warn' $_.Exception.Message }
        }

        if ($state.environments.Count) {
            Write-Host ''
            Write-Host '  Environments' -ForegroundColor Cyan
            $handles = @{}
            foreach ($e in $state.environments) {
                if ($invalid[$e.name]) { continue }
                if ((Test-CtxTool $e 'cli') -and $az -and (Test-Path -LiteralPath (Get-CtxCliDir $e.name))) { $handles[$e.name] = Start-CtxCliTokenCheck $e }
            }
            foreach ($e in @($state.environments | Sort-Object { $_.name })) {
                if ($invalid[$e.name]) { continue }
                $label = "$($e.name)"
                $method = Get-CtxSignInMethod $e
                if ($method -ne 'DeviceCode') {
                    try {
                        Assert-CtxSignInMethodSupported -Method $method -Entry $e
                        $note = if ($e.graphClientId -and $method -eq 'Browser') { " (Graph app $($e.graphClientId) needs the redirect URI http://localhost)" } else { '' }
                        & $report "$label · sign-in" 'ok' "$method$note"
                    } catch { & $report "$label · sign-in" 'warn' $_.Exception.Message }
                }
                if ($e.saveGraphCredentials -eq $true) {
                    $gi = Get-CtxGraphCredentialInfo $e
                    if (-not $gi) { & $report "$label · graph" 'info' 'credential saving is on; nothing saved yet (saved at the next Graph sign-in)' }
                    elseif ($gi.Expired) { & $report "$label · graph" 'info' 'saved credentials are past graphMaxSessionHours; the next Graph sign-in replaces them' }
                    else { & $report "$label · graph" 'ok' "saved credentials$(if ($gi.RestorableUntil) { ", restorable until $($gi.RestorableUntil.ToLocalTime().ToString('HH:mm'))" })" }
                }
                if (Test-CtxTool $e 'cli') {
                    if (-not $az) { }
                    elseif (-not $handles[$e.name]) { & $report "$label · cli" 'warn' "not signed in yet - 'ctx $($e.name)' signs in" }
                    else {
                        $r = Complete-CtxCliTokenCheck $handles[$e.name]
                        & $report "$label · cli" $(if ($r.Ok) { 'ok' } else { 'warn' }) $(if ($r.Ok) { $e.upn } else { "$($r.Reason) - 'ctx $($e.name)' signs in again" })
                    }
                }
                if ((Test-CtxTool $e 'az') -and (Get-Module Az.Accounts)) {
                    $ctxObj = Get-CtxAzNamedContext $e.azContextName
                    if (-not $ctxObj) { & $report "$label · az" 'warn' "context '$($e.azContextName)' missing - 'ctx $($e.name)' signs in" }
                    elseif ($Deep) {
                        try {
                            $t = Get-AzAccessToken -TenantId $e.tenantId -DefaultProfile $ctxObj -ErrorAction Stop -WarningAction SilentlyContinue
                            $id = Get-CtxIdentityFromClaims (ConvertFrom-CtxJwt (ConvertFrom-CtxSecureToken $t.Token))
                            & $report "$label · az" $(if (Test-CtxIdentityMatch $e $id) { 'ok' } else { 'warn' }) $(if (Test-CtxIdentityMatch $e $id) { $e.upn } else { "signed in as $($id.Upn)" })
                        } catch { & $report "$label · az" 'warn' "token not available - 'ctx $($e.name)' signs in again" }
                    } else { & $report "$label · az" 'ok' "context $($e.azContextName) (token check: -Deep)" }
                }
            }
        }
    }
    $fail = @($results | Where-Object Status -EQ 'fail').Count
    $warn = @($results | Where-Object Status -EQ 'warn').Count
    Write-Host ''
    if ($fail) { Write-CtxMsg error "$fail problem(s), $warn warning(s)" } elseif ($warn) { Write-CtxMsg warn "$warn warning(s)" } else { Write-CtxMsg ok 'All good' }
    Write-Host ''
    if ($PassThru) { $results }
}

function Set-CtxConfig {
    <#
    .SYNOPSIS
    Shows or changes ctx settings (stored in config.json in the ctx data folder).
    .EXAMPLE
    ctx config
    .EXAMPLE
    ctx config pimDefaultHours 2
    .EXAMPLE
    ctx config graphScopeProfiles.Intune "DeviceManagementManagedDevices.ReadWrite.All,DeviceManagementConfiguration.ReadWrite.All"
    .EXAMPLE
    ctx config askAdminOnSwitch -Reset
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)]
        [string]$Name,
        [Parameter(Position = 1)]$Value,
        [switch]$Reset,
        [switch]$Edit
    )
    $path = Get-CtxConfigPath
    if ($Edit) {
        if (-not (Test-Path -LiteralPath $path)) { Write-CtxFileAtomic -Path $path -Content "{`n}`n" }
        $editor = @(Get-CtxEditorCommand)
        $editorArgs = @($editor | Select-Object -Skip 1)
        & $editor[0] @editorArgs $path
        return
    }
    if (-not $Name) {
        if ($Reset) {
            if (-not $PSCmdlet.ShouldProcess($path, 'Reset all ctx settings to defaults')) { return }
            Invoke-CtxLocked { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
            $script:ConfigCache = $null
            Write-CtxMsg ok 'All settings reset to defaults.'
            return
        }
        $overrides = Read-CtxConfigOverrides
        $cfg = Get-CtxConfig
        foreach ($k in $cfg.Keys) {
            $val = $cfg[$k]
            $text = if ($val -is [System.Collections.IDictionary]) { if ($val.Count) { $val | ConvertTo-Json -Compress -Depth 5 } else { '{}' } }
            elseif ($val -is [array] -or $val -is [System.Collections.IList]) { @($val) -join ', ' } else { "$val" }
            [pscustomobject]@{ PSTypeName = 'Ctx.Setting'; Name = $k; Value = $text; Changed = $overrides.Contains($k) }
        }
        return
    }
    $key, $subKey = $Name -split '\.', 2
    $realKey = $script:CtxDefaultConfig.Keys | Where-Object { $_ -ieq $key } | Select-Object -First 1
    if (-not $realKey) { throw "Unknown setting '$key'. Settings: $($script:CtxDefaultConfig.Keys -join ', ')" }
    $default = $script:CtxDefaultConfig[$realKey]
    if ($subKey -and $default -isnot [System.Collections.IDictionary]) { throw "'$realKey' has no sub keys." }
    $clear = $Reset -or ($subKey -and ($null -eq $Value -or "$Value" -eq ''))
    $newValue = $null
    if (-not $subKey -and -not $clear) {
        if ($null -eq $Value) { throw "Value missing. Example: ctx config $realKey <value>   (or -Reset)" }
        $newValue = ConvertTo-CtxConfigValue -Value $Value -Default $default -Name $realKey
    }
    if (-not $PSCmdlet.ShouldProcess("ctx setting '$Name'", $(if ($clear) { 'Reset to default' } else { "Set to '$Value'" }))) { return }
    Invoke-CtxLocked {
        $overrides = Read-CtxConfigOverrides
        if ($subKey) {
            $dict = if ($overrides[$realKey] -is [System.Collections.IDictionary]) { $overrides[$realKey] } else { [ordered]@{} }
            if ($clear) { $dict.Remove($subKey) }
            else { $dict[$subKey] = @(@($Value) | ForEach-Object { "$_" -split '[,;\s]+' } | Where-Object { $_ }) }
            $overrides[$realKey] = $dict
        } elseif ($clear) {
            $overrides.Remove($realKey)
        } else {
            $overrides[$realKey] = $newValue
        }
        Save-CtxConfigOverrides $overrides
    }
    if ($realKey -eq 'promptBadge') {
        if ((Get-CtxConfig).promptBadge) { Install-CtxPrompt } else { Uninstall-CtxPrompt }
    }
    $now = (Get-CtxConfig)[$realKey]
    if ($subKey -and $now -is [System.Collections.IDictionary]) { $now = if ($now.Contains($subKey)) { $now[$subKey] } else { '(removed)' } }
    Write-CtxMsg ok "$Name = $(if ($now -is [System.Collections.IDictionary]) { $now | ConvertTo-Json -Compress -Depth 5 } elseif ($now -is [array]) { @($now) -join ', ' } else { "$now" })"
}

function ConvertTo-CtxConfigValue {
    param($Value, $Default, [string]$Name)
    if ($Name -eq 'graphCredentialStore') {
        $v = "$Value".Trim().ToLowerInvariant()
        if ($v -notin 'keyring', 'file') { throw "'$Name' expects keyring (macOS Keychain / Secret Service) or file (a key file only you can read; Linux/macOS only)." }
        return $v
    }
    if ($Default -is [bool]) {
        if ($Value -is [bool]) { return $Value }
        $t = "$Value".Trim().ToLowerInvariant()
        if ($t -in 'true', '1', 'yes', 'on', 'y', '$true') { return $true }
        if ($t -in 'false', '0', 'no', 'off', 'n', '$false') { return $false }
        throw "'$Name' expects true or false."
    }
    if ($Default -is [int] -or $Default -is [double]) {
        $d = 0.0
        if (-not [double]::TryParse("$Value", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { throw "'$Name' expects a number." }
        if ($Default -is [int] -and $d -eq [math]::Floor($d)) { return [int]$d }
        return $d
    }
    if ($Default -is [array]) {
        return @(@($Value) | ForEach-Object { "$_" -split '\s*,\s*' } | Where-Object { $_ })
    }
    if ($Default -is [System.Collections.IDictionary]) {
        if ($Value -is [System.Collections.IDictionary]) { return $Value }
        return ("$Value" | ConvertFrom-Json -AsHashtable)
    }
    "$Value"
}

function Get-CtxHelp {
    <#
    .SYNOPSIS
    Shows the ctx cheat sheet.
    #>
    [CmdletBinding()]
    param()
    $d = 'DarkGray'
    # '# text' = section header, 'command :: description' = entry
    $lines = @(
        '# ctx - one command for your tenants (environment = tenant + login)'
        'ctx :: picker (↑/↓, Enter; a = +admin, l = this terminal only)'
        'ctx <name> :: switch everywhere: Azure CLI + Az PowerShell, where you left off'
        'ctx <name> -Admin :: switch, activate Global Admin (PIM), connect Graph (focused Admin scopes)'
        'ctx <name> -Local :: switch this terminal only'
        'ctx - :: back to the previous environment'
        'ctx sync :: make an older terminal follow the global environment'
        '# environments'
        'ctx add <name> [tenant] :: create (device code; -SignIn Browser|Broker); same tenant + login is refused as duplicate'
        'ctx list | ls :: list (* = this terminal, + = global)'
        'ctx rename <old> <new> :: rename'
        'ctx rm <name> :: remove (-SignOut, -RemoveBrowserProfile)'
        'ctx set [name] -Tags prod :: tags, -Color, -Description, -PimHours, -GraphProfile, -AdminOnSwitch'
        'ctx set [name] -SaveGraphCredentials On :: keep the Graph sign-in (encrypted, this device); -Admin restores it for graphMaxSessionHours (default 8)'
        'ctx set [name] -SignIn Browser :: sign in in the browser profile (or Broker = Windows account manager) instead of device code'
        'ctx export | import <file> :: share definitions (no tokens)'
        '# admin'
        'ctx pim [role] :: activate (default Global Admin) + Graph; -Hours -Reason -Ticket -NoGraph'
        'ctx pim -List | -Deactivate | -Renew :: eligible/active roles, end early, start a fresh activation'
        'ctx graph [profile] :: reuse Graph (session, saved, Az, CLI login) or sign in once: Admin, ReadOnly, Pim, custom or "Scope1,Scope2"'
        'ctx graph -AddScopes "Scope1,Scope2" :: extend this session; consent only if needed'
        'ctx graph -Relogin :: explicitly sign in again with the environment''s method (ignores saved credentials)'
        '# everyday'
        'ctx st [-Check] :: status of this terminal'
        'ctx sub [name] :: pick subscription (CLI + Az), remembered per environment'
        'ctx portal [entra|pim|...] :: open a portal in the environment''s browser profile'
        'ctx exec all { ... } :: run a script block in several environments ($_ = environment); prod asks first'
        'ctx doctor [-Deep] :: check prerequisites and every login'
        'ctx config [key value] :: settings (-Reset, -Edit)'
    )
    $width = 2 + (($lines | Where-Object { -not $_.StartsWith('# ') } | ForEach-Object { ($_ -split ' :: ', 2)[0].Length }) | Measure-Object -Maximum).Maximum
    Write-Host ''
    foreach ($l in $lines) {
        if ($l.StartsWith('# ')) { Write-Host "  $($l.Substring(2))" -ForegroundColor Cyan; continue }
        $cmd, $text = $l -split ' :: ', 2
        Write-Host ('    ' + $cmd.PadRight($width)) -NoNewline -ForegroundColor White
        Write-Host $text -ForegroundColor $d
    }
    Write-Host ''
    Write-Host "  Prompt badge: [!name:graph GA 1h20m→other]  ! prod · :graph connected · GA time left · * local · →x global differs" -ForegroundColor $d
    Write-Host "  Details: Get-Help Switch-CtxEnvironment -Full, Get-Help Invoke-CtxPim -Examples, ..." -ForegroundColor $d
    Write-Host ''
}
