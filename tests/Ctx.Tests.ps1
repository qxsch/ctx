#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Runs fully offline: temp CTX_HOME, sandboxed user environment variables, Azure/Graph calls mocked.

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:savedEnv = @{}
    foreach ($n in 'CTX_HOME', 'CTX_SANDBOX_USERENV', 'AZURE_CONFIG_DIR', 'AZURE_EXTENSION_DIR') { $script:savedEnv[$n] = [Environment]::GetEnvironmentVariable($n) }
    $script:testHome = Join-Path ([IO.Path]::GetTempPath()) "ctx-tests-$([guid]::NewGuid().ToString('n'))"
    New-Item -ItemType Directory -Path $script:testHome | Out-Null
    $env:CTX_HOME = $script:testHome
    $env:CTX_SANDBOX_USERENV = Join-Path $script:testHome 'userenv.json'
    # CTX_TEST_MODULE = path to an installed Ctx.psd1 runs the suite against the bundled copy
    Import-Module $(if ($env:CTX_TEST_MODULE) { $env:CTX_TEST_MODULE } else { Join-Path $script:repoRoot 'Ctx\Ctx.psd1' }) -Force
    Mock -ModuleName Ctx Invoke-CtxOAuth { throw 'Offline test attempted an unmocked OAuth request.' }
    Mock -ModuleName Ctx Get-CtxAzGraphToken { }

    $script:T1 = '11111111-1111-1111-1111-111111111111'
    $script:T2 = '22222222-2222-2222-2222-222222222222'
    $script:O1 = 'aaaaaaaa-0000-0000-0000-000000000001'
    $script:O2 = 'aaaaaaaa-0000-0000-0000-000000000002'

    function New-TestEnv {
        param([string]$Name, [string]$TenantId, [string]$ObjectId, [string[]]$Tools = @('cli', 'az'), [string[]]$Tags = @(), [object[]]$Activations = @())
        @{ name = $Name; tenantId = $TenantId; tenantName = "Tenant $Name"; userObjectId = $ObjectId; upn = "$Name@contoso.com"
            tools = $Tools; tags = $Tags; activations = $Activations }
    }

    function Set-TestState {
        param([object[]]$Environments, [string]$Current)
        if (Test-Path -LiteralPath $env:CTX_SANDBOX_USERENV) { Remove-Item -LiteralPath $env:CTX_SANDBOX_USERENV -Force }
        InModuleScope Ctx -Parameters @{ Envs = $Environments; Current = $Current } {
            param($Envs, $Current)
            $s = New-CtxState
            $s.current = $Current
            foreach ($e in $Envs) {
                $h = [ordered]@{}
                foreach ($k in $e.Keys) { $h[$k] = $e[$k] }
                $s.environments.Add((Repair-CtxEnvironmentEntry $h))
            }
            Save-CtxState $s
            $script:ProcessEnvName = $Current
            $script:ProcessPreviousName = $null
            $script:ProcessLocal = $false
            $script:GraphEnvName = $null
            $script:GraphProfileName = $null
            $script:GraphToken = $null
        }
    }

    function Get-TestState { InModuleScope Ctx { Read-CtxState } }
    function Get-TestUserEnv([string]$Name) { InModuleScope Ctx -Parameters @{ N = $Name } { param($N) Get-CtxUserEnv $N } }

    function New-TestJwt([hashtable]$Claims) {
        $enc = { param($o) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($o | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
        "$(& $enc @{ alg = 'none'; typ = 'JWT' }).$(& $enc $Claims).signature"
    }
}

AfterAll {
    Remove-Module Ctx -Force -ErrorAction SilentlyContinue
    foreach ($n in $script:savedEnv.Keys) { [Environment]::SetEnvironmentVariable($n, $script:savedEnv[$n]) }
    Remove-Item -LiteralPath $script:testHome -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Names and resolution' {
    It 'normalizes valid names' {
        InModuleScope Ctx { Assert-CtxName 'EMEA3' } | Should -Be 'emea3'
    }
    It 'rejects invalid names' -TestCases @(
        @{ Name = 'two words' }, @{ Name = '-lead' }, @{ Name = ('x' * 33) }, @{ Name = 'ümlaut' }
    ) {
        param($Name)
        { InModuleScope Ctx -Parameters @{ N = $Name } { param($N) Assert-CtxName $N } } | Should -Throw '*Invalid environment name*'
    }
    It 'rejects reserved names' -TestCases @(@{ Name = 'list' }, @{ Name = 'all' }, @{ Name = 'pim' }, @{ Name = '-' }) {
        param($Name)
        { InModuleScope Ctx -Parameters @{ N = $Name } { param($N) Assert-CtxName $N } } | Should -Throw
    }
    Context 'resolve' {
        BeforeAll {
            Set-TestState -Current 'emea' -Environments @(
                (New-TestEnv 'emea' $T1 $O1), (New-TestEnv 'emea3' $T2 $O2), (New-TestEnv 'germany' $T2 $O1)
            )
        }
        It 'prefers the exact name' { (InModuleScope Ctx { Resolve-CtxEnvironment (Read-CtxState) 'emea' }).name | Should -Be 'emea' }
        It 'accepts a unique prefix' { (InModuleScope Ctx { Resolve-CtxEnvironment (Read-CtxState) 'ger' }).name | Should -Be 'germany' }
        It 'reports ambiguous prefixes' { { InModuleScope Ctx { Resolve-CtxEnvironment (Read-CtxState) 'em' } } | Should -Throw '*ambiguous*' }
        It 'suggests on unknown names' { { InModuleScope Ctx { Resolve-CtxEnvironment (Read-CtxState) 'nowhere' } } | Should -Throw '*Unknown environment*' }
        It 'finds environments by identity (tenant + login)' {
            (InModuleScope Ctx -Parameters @{ T = $T2; O = $O1 } { param($T, $O) Find-CtxEnvironmentByIdentity (Read-CtxState) $T $O.ToUpperInvariant() }).name | Should -Be 'germany'
        }
    }
}

Describe 'State' {
    It 'round-trips and keeps a backup' {
        Set-TestState -Current 'alpha' -Environments @((New-TestEnv 'alpha' $T1 $O1))
        $saved = InModuleScope Ctx { Update-CtxState { param($s) $s.previous = 'x'; (Find-CtxEnvironment $s 'alpha').description = 'hello' } }
        $saved.previous | Should -Be 'x'
        $state = Get-TestState
        (InModuleScope Ctx -Parameters @{ S = $state } { param($S) Find-CtxEnvironment $S 'alpha' }).description | Should -Be 'hello'
        Test-Path (Join-Path $testHome 'environments.json.bak') | Should -BeTrue
    }
    It 'repairs entries with defaults' {
        Set-TestState -Current $null -Environments @(@{ name = 'bare'; tenantId = $T1; userObjectId = $O1 })
        $e = (Get-TestState).environments[0]
        $e.tools | Should -Be @('cli', 'az')
        $e.azContextName | Should -Be 'ctx:bare'
        $e.browserProfile | Should -Be 'ctx-bare'
    }
}

Describe 'Helpers' {
    It 'decodes JWT identities' {
        $exp = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()
        $jwt = New-TestJwt @{ tid = $T1; oid = $O1; upn = 'admin@contoso.com'; exp = $exp }
        $id = InModuleScope Ctx -Parameters @{ J = $jwt } { param($J) Get-CtxIdentityFromClaims (ConvertFrom-CtxJwt $J) }
        $id.TenantId | Should -Be $T1
        $id.ObjectId | Should -Be $O1
        $id.Upn | Should -Be 'admin@contoso.com'
        $id.ExpiresAt | Should -BeGreaterThan ([datetime]::UtcNow)
    }
    It 'uses the home tenant UPN for guest-style unique_name' {
        $jwt = New-TestJwt @{ tid = $T1; oid = $O1; unique_name = 'live.com#me@outlook.com' }
        (InModuleScope Ctx -Parameters @{ J = $jwt } { param($J) Get-CtxIdentityFromClaims (ConvertFrom-CtxJwt $J) }).Upn | Should -Be 'me@outlook.com'
    }
    It 'matches identities on tenant + object id' {
        InModuleScope Ctx -Parameters @{ T = $T1; O = $O1 } {
            param($T, $O)
            Test-CtxIdentityMatch @{ tenantId = $T; userObjectId = $O } ([pscustomobject]@{ TenantId = $T.ToUpperInvariant(); ObjectId = $O }) | Should -BeTrue
            Test-CtxIdentityMatch @{ tenantId = $T; userObjectId = $O } ([pscustomobject]@{ TenantId = $T; ObjectId = 'other' }) | Should -BeFalse
        }
    }
    It 'formats durations' -TestCases @(
        @{ Minutes = 95; Expected = '1h35m' }, @{ Minutes = 30; Expected = '30m' }, @{ Minutes = 0.5; Expected = '1m' }, @{ Minutes = -3; Expected = '0m' }
    ) {
        param($Minutes, $Expected)
        InModuleScope Ctx -Parameters @{ M = $Minutes } { param($M) Format-CtxDuration ([timespan]::FromMinutes($M)) } | Should -Be $Expected
    }
    It 'formats unlimited durations' { InModuleScope Ctx { Format-CtxDuration $null } | Should -Be '∞' }
    It 'writes INI values' {
        $f = Join-Path $testHome 'test.ini'
        Set-Content -LiteralPath $f -Value "[core]`noutput = json`n[cloud]`nname = AzureCloud"
        InModuleScope Ctx -Parameters @{ F = $f } {
            param($F)
            Set-CtxIniValue -Path $F -Section 'core' -Key 'login_experience_v2' -Value 'off'
            Set-CtxIniValue -Path $F -Section 'core' -Key 'output' -Value 'table'
            Set-CtxIniValue -Path $F -Section 'extension' -Key 'use_dynamic_install' -Value 'no'
        }
        $text = Get-Content -LiteralPath $f -Raw
        $text | Should -Match '(?s)\[core\]\s+output = table\s+login_experience_v2 = off\s+\[cloud\]'
        $text | Should -Match '\[extension\]\s+use_dynamic_install = no'
    }
    It 'builds portal URLs' {
        InModuleScope Ctx -Parameters @{ T = $T1 } {
            param($T)
            $e = @{ tenantId = $T; tenantDomain = 'contoso.onmicrosoft.com' }
            Get-CtxPortalUrl -Entry $e -Portal 'azure' | Should -Be 'https://portal.azure.com/#@contoso.onmicrosoft.com'
            Get-CtxPortalUrl -Entry $e -Portal 'security' | Should -Be "https://security.microsoft.com/?tid=$T"
            Get-CtxPortalUrl -Entry $e -Portal 'https://example.org/x' | Should -Be 'https://example.org/x'
            { Get-CtxPortalUrl -Entry $e -Portal 'nope' } | Should -Throw '*Unknown portal*'
        }
    }
    It 'sandboxes user environment variables' {
        InModuleScope Ctx { Set-CtxUserEnv 'CTX_TEST_VAR' 'abc'; Get-CtxUserEnv 'CTX_TEST_VAR' } | Should -Be 'abc'
        [Environment]::GetEnvironmentVariable('CTX_TEST_VAR', 'User') | Should -BeNullOrEmpty
        InModuleScope Ctx { Set-CtxUserEnv 'CTX_TEST_VAR' $null; Get-CtxUserEnv 'CTX_TEST_VAR' } | Should -BeNullOrEmpty
    }
    It 'detects paths synced by OneDrive' {
        $saved = $env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer
        try {
            $env:OneDrive = 'C:\Users\x\OneDrive - Contoso'; $env:OneDriveCommercial = $env:OneDrive; $env:OneDriveConsumer = $null
            InModuleScope Ctx {
                Get-CtxOneDriveRoot 'C:\Users\x\OneDrive - Contoso\Documents\PowerShell\Modules\Ctx' | Should -Be 'C:\Users\x\OneDrive - Contoso'
                Get-CtxOneDriveRoot 'c:\users\x\onedrive - contoso' | Should -Be 'C:\Users\x\OneDrive - Contoso'
                Get-CtxOneDriveRoot 'C:\Users\x\OneDrive - Contoso2\a' | Should -BeNullOrEmpty
                Get-CtxOneDriveRoot 'C:\Users\x\AppData\Local\ctx' | Should -BeNullOrEmpty
            }
        } finally { $env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer = $saved }
    }
}

Describe 'Picker sliding window' {
    It 'fits lists below, at and above the terminal height minus two' -TestCases @(
        @{ Items = 1; Visible = 1 }, @{ Items = 22; Visible = 22 },
        @{ Items = 23; Visible = 23 }, @{ Items = 24; Visible = 23 },
        @{ Items = 500; Visible = 23 }
    ) {
        param($Items, $Visible)
        InModuleScope Ctx -Parameters @{ Items = $Items; Visible = $Visible } {
            param($Items, $Visible)
            $frame = New-CtxMenuFrame -Rows @(1..$Items | ForEach-Object { "subscription-$_" }) -Selected 0 -Width 79 -Height 25 -Footer 'controls'
            $frame.Count | Should -Be $Visible
            $frame.Start | Should -Be 0
            @($frame.Text -split "`n").Count | Should -Be ($Visible + 1)
            $frame.Text | Should -Not -Match "`n$"
        }
    }

    It 'keeps every subscription visible while scrolling down and back up' {
        InModuleScope Ctx {
            $rows = @(0..499 | ForEach-Object { "subscription-{0:000}" -f $_ })
            $start = 0
            foreach ($selected in (@(0..499) + @(499..0))) {
                $frame = New-CtxMenuFrame -Rows $rows -Selected $selected -Start $start -Width 79 -Height 25 -Footer 'controls'
                $frame.Count | Should -Be 23
                $selected | Should -BeGreaterOrEqual $frame.Start
                $selected | Should -BeLessThan ($frame.Start + $frame.Count)
                $frame.Text | Should -Match ("›.*" + $rows[$selected])
                @($frame.Text -split "`n").Count | Should -Be 24
                $start = $frame.Start
            }
            $start | Should -Be 0
        }
    }

    It 'follows a distant default, Home, End and wrapped selections' {
        InModuleScope Ctx {
            $rows = @(0..499 | ForEach-Object { "subscription-$_" })
            $frame = New-CtxMenuFrame -Rows $rows -Selected 450 -Width 79 -Height 25
            $frame.Start | Should -Be 428
            $frame = New-CtxMenuFrame -Rows $rows -Selected 499 -Start $frame.Start -Width 79 -Height 25
            $frame.Start | Should -Be 477
            $frame = New-CtxMenuFrame -Rows $rows -Selected 0 -Start $frame.Start -Width 79 -Height 25
            $frame.Start | Should -Be 0
            $frame = New-CtxMenuFrame -Rows $rows -Selected 499 -Start $frame.Start -Width 79 -Height 25
            $frame.Start | Should -Be 477
        }
    }

    It 'adapts the viewport when the terminal shrinks and grows' {
        InModuleScope Ctx {
            $rows = @(0..499 | ForEach-Object { "subscription-$_" })
            $frame = New-CtxMenuFrame -Rows $rows -Selected 499 -Width 79 -Height 25
            $frame = New-CtxMenuFrame -Rows $rows -Selected 499 -Start $frame.Start -Width 39 -Height 10
            $frame.Start | Should -Be 492
            $frame.Count | Should -Be 8
            $frame = New-CtxMenuFrame -Rows $rows -Selected 499 -Start $frame.Start -Width 119 -Height 40
            $frame.Start | Should -Be 462
            $frame.Count | Should -Be 38
        }
    }

    It 'prevents long rows and controls from wrapping in narrow terminals' -TestCases @(
        @{ Width = 1 }, @{ Width = 2 }, @{ Width = 10 }, @{ Width = 39 }
    ) {
        param($Width)
        InModuleScope Ctx -Parameters @{ Width = $Width } {
            param($Width)
            $frame = New-CtxMenuFrame -Rows @('first subscription', ("a`tvery`nlong`rsubscription" * 10)) -Selected 1 -Width $Width -Height 3 -Footer ('controls ' * 20) -Colors @('Red', 'Green')
            $frame.Start | Should -Be 1
            $frame.Count | Should -Be 1
            $plain = $frame.Text -replace "$([char]27)\[[0-9;]*[mKJ]", '' -replace "`r", ''
            $lines = @($plain -split "`n")
            $lines.Count | Should -Be 2
            foreach ($line in $lines) { $line.Length | Should -BeLessOrEqual $Width }
            if ($Width -gt 1) { $frame.Text | Should -Match ([regex]::Escape((Get-CtxAnsi Green))) }
        }
    }
}

Describe 'PIM and Graph helpers' {
    It 'classifies PIM errors' -TestCases @(
        @{ Message = 'RoleAssignmentRequestPolicyValidationFailed: ExpirationRule'; Kind = 'Expiration' }
        @{ Message = 'The following policy rules failed: ["JustificationRule"]'; Kind = 'Justification' }
        @{ Message = 'TicketingRule'; Kind = 'Ticket' }
        @{ Message = 'RoleAssignmentRequestAcrsValidationFailed'; Kind = 'Mfa' }
        @{ Message = 'The following policy rules failed: ["MfaRule"]'; Kind = 'Mfa' }
        @{ Message = 'RoleAssignmentExists: The Role assignment already exists.'; Kind = 'Exists' }
        @{ Message = 'ActiveDurationTooShort'; Kind = 'TooShort' }
        @{ Message = 'Authorization_RequestDenied'; Kind = 'Forbidden' }
        @{ Message = 'RoleEligibilityScheduleNotFound'; Kind = 'NotEligible' }
        @{ Message = 'boom'; Kind = 'Other' }
    ) {
        param($Message, $Kind)
        InModuleScope Ctx -Parameters @{ M = $Message } { param($M) Get-CtxPimErrorKind $M } | Should -Be $Kind
    }
    It 'resolves roles by alias, name and id' {
        InModuleScope Ctx {
            (Resolve-CtxRole 'ga').Name | Should -Be 'Global Administrator'
            (Resolve-CtxRole 'ga').Id | Should -Be '62e90394-69f5-4237-9190-012177145e10'
            (Resolve-CtxRole 'global reader').Name | Should -Be 'Global Reader'
            (Resolve-CtxRole '62E90394-69F5-4237-9190-012177145E10').Name | Should -Be 'Global Administrator'
            (Resolve-CtxRole 'Some Custom Role').Id | Should -BeNullOrEmpty
            Get-CtxRoleShortName 'Global Administrator' | Should -Be 'GA'
            Get-CtxRoleShortName 'Privileged Role Administrator' | Should -Be 'PRA'
        }
    }
    It 'resolves Graph scope profiles' {
        InModuleScope Ctx {
            Get-CtxGraphScopes 'Pim' | Should -Contain 'RoleAssignmentSchedule.ReadWrite.Directory'
            Get-CtxGraphScopes 'User.Read.All, Group.Read.All' | Should -Be @('User.Read.All', 'Group.Read.All')
            { Get-CtxGraphScopes 'Nope' } | Should -Throw '*Unknown Graph scope profile*'
        }
    }
    It 'defaults to the focused daily profile without filtering scopes through stale SDK metadata' {
        Mock -ModuleName Ctx Get-CtxDelegatedPermissionNames { throw 'SDK discovery is not needed for a fixed profile' }
        InModuleScope Ctx {
            (Get-CtxConfig).defaultGraphProfile | Should -Be 'Admin'
            $scopes = @(Get-CtxGraphScopes 'Admin')
            $scopes.Count | Should -Be 11
            $scopes | Should -Be @(
                'Application.Read.All', 'Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All',
                'User.ReadWrite.All', 'Group.ReadWrite.All', 'UserAuthenticationMethod.ReadWrite.All',
                'Domain.Read.All', 'Policy.Read.AuthenticationMethod',
                'RoleManagement.ReadWrite.Directory', 'RoleEligibilitySchedule.Read.Directory', 'RoleAssignmentSchedule.ReadWrite.Directory'
            )
            $scopes | Should -Not -Contain 'Application.ReadWrite.OwnedBy'
            @(Get-CtxGraphScopes 'ReadOnly' | Where-Object { $_ -match 'ReadWrite' }).Count | Should -Be 0
        }
        Should -Invoke Get-CtxDelegatedPermissionNames -ModuleName Ctx -Times 0 -Exactly
    }
    It 'resolves custom Graph scope profiles from config' {
        Set-CtxConfig 'graphScopeProfiles.Intune' 'DeviceManagementManagedDevices.Read.All,DeviceManagementConfiguration.Read.All' 6>$null
        try {
            InModuleScope Ctx { Get-CtxGraphScopes 'Intune' } | Should -Be @('DeviceManagementManagedDevices.Read.All', 'DeviceManagementConfiguration.Read.All')
        } finally { Set-CtxConfig -Reset 6>$null }
    }
    It 'has no profile that requests every delegated permission' {
        Mock -ModuleName Ctx Get-CtxDelegatedPermissionNames { throw 'must not enumerate all permissions' }
        { InModuleScope Ctx { Get-CtxGraphScopes 'All' } } | Should -Throw "*'All' Graph profile was removed*least privilege*"
        { InModuleScope Ctx { Get-CtxGraphScopes 'all' } } | Should -Throw '*was removed*'
        $offered = @(InModuleScope Ctx { Get-CtxGraphProfileCompletion '' }).CompletionText
        $offered | Should -Be @('Admin', 'ReadOnly', 'Pim')
        Set-TestState -Current 'alpha' -Environments @((New-TestEnv 'alpha' $T1 $O1))
        { ctx set alpha -GraphProfile All } | Should -Throw '*was removed*'
        (Get-Command Connect-CtxGraph).Parameters.ContainsKey('NoFallback') | Should -BeFalse
        InModuleScope Ctx { $script:CtxDefaultConfig.Contains('fallbackGraphProfile') } | Should -BeFalse
    }
    It 'migrates a stored All profile from older versions to the default' {
        $cfgFile = Join-Path $testHome 'config.json'
        Set-Content -LiteralPath $cfgFile -Value '{ "defaultGraphProfile": "All", "fallbackGraphProfile": "Admin", "pimDefaultHours": 2 }'
        try {
            $cfg = Get-CtxConfig
            $cfg.defaultGraphProfile | Should -Be 'Admin'
            $cfg.Contains('fallbackGraphProfile') | Should -BeFalse
            $cfg.pimDefaultHours | Should -Be 2
            Set-TestState -Current 'alpha' -Environments @(@{ name = 'alpha'; tenantId = $T1; userObjectId = $O1; graphProfile = 'All' })
            (Get-TestState).environments[0].graphProfile | Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $cfgFile -Force -ErrorAction SilentlyContinue }
    }
    It 'keeps a custom profile that happens to be named All' {
        Set-CtxConfig 'graphScopeProfiles.All' 'User.Read.All' 6>$null
        try {
            InModuleScope Ctx { Get-CtxGraphScopes 'All' } | Should -Be @('User.Read.All')
            Set-TestState -Current 'alpha' -Environments @(@{ name = 'alpha'; tenantId = $T1; userObjectId = $O1; graphProfile = 'All' })
            (Get-TestState).environments[0].graphProfile | Should -Be 'All'
        } finally { Set-CtxConfig -Reset 6>$null }
    }
}

Describe 'Graph sign-in' {
    BeforeAll {
        $script:gEntry = New-TestEnv 'graphy' $T1 $O1
        $script:gExp = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()
        $script:gDevice = [pscustomobject]@{ device_code = 'dc'; user_code = 'ABC123'; verification_uri = 'https://login.microsoft.com/device'; interval = 5; expires_in = 900 }
        function New-GraphTokenState([double]$Minutes, [string]$RefreshToken = 'rt-1') {
            @{ Entry = $gEntry; TenantId = $T1; ObjectId = $O1; Account = 'graphy@contoso.com'; ClientId = 'cid'; TokenClientId = 'cid'
                Scope = 'User.Read.All offline_access openid profile'; Scopes = @('User.Read.All'); Source = 'DeviceCode'; RefreshToken = $RefreshToken
                ExpiresAt = [datetime]::UtcNow.AddMinutes($Minutes); RetryAfter = $null; LastError = $null; ErrorCode = $null; Warned = $false }
        }
    }
    AfterEach {
        InModuleScope Ctx { $script:GraphToken = $null; $script:GraphEnvName = $null; $script:GraphProfileName = $null }
    }

    Context 'helpers' {
        It 'requests offline_access for silent renewal' {
            InModuleScope Ctx { Get-CtxGraphScopeString @('User.Read.All', 'offline_access', 'Group.Read.All') } |
                Should -Be 'User.Read.All Group.Read.All offline_access openid profile'
        }
        It 'extracts readable OAuth errors' {
            InModuleScope Ctx {
                Get-CtxOAuthErrorText ([pscustomobject]@{ error = 'invalid_grant'; error_description = "AADSTS70043: The refresh token has expired. Trace ID: x`r`nCorrelation ID: y" }) |
                    Should -Be 'AADSTS70043: The refresh token has expired.'
                Get-CtxOAuthErrorText ([pscustomobject]@{ error = 'network'; error_description = "No such host is known.`nmore" }) | Should -Be 'No such host is known.'
                Get-CtxOAuthErrorText ([pscustomobject]@{ error = 'http_500' }) | Should -Be 'http_500'
            }
        }
        It 'starts one renewal timer and removes it on disconnect' {
            InModuleScope Ctx {
                Start-CtxGraphRenewal
                Start-CtxGraphRenewal
                @(Get-EventSubscriber -SourceIdentifier $script:CtxGraphRenewalId).Count | Should -Be 1
                Disconnect-CtxGraphSession
                Get-EventSubscriber -SourceIdentifier $script:CtxGraphRenewalId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
                Get-Job -Name $script:CtxGraphRenewalId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
                $script:GraphRenewalTimer | Should -BeNullOrEmpty
            }
        }
    }

    Context 'device-code flow and renewal' {
        BeforeAll {
            Mock -ModuleName Ctx Write-Host { }
            Mock -ModuleName Ctx Start-Sleep { }
            Mock -ModuleName Ctx Show-CtxDeviceCode { }
            Mock -ModuleName Ctx Import-CtxGraphModule { }
            Mock -ModuleName Ctx Get-CtxAzGraphToken { }
            Mock -ModuleName Ctx Connect-CtxGraphToken { }
            Mock -ModuleName Ctx Start-CtxGraphRenewal { }
            Mock -ModuleName Ctx Stop-CtxGraphRenewal { }
            Mock -ModuleName Ctx Get-CtxMgContext {
                InModuleScope Ctx {
                    if ($script:GraphToken) {
                        [pscustomobject]@{
                            AuthType = 'UserProvidedAccessToken'; TenantId = $script:GraphToken.TenantId
                            Account = $script:GraphToken.Account; ClientId = $script:GraphToken.TokenClientId; Scopes = $script:GraphToken.Scopes
                        }
                    }
                }
            }
            Mock -ModuleName Ctx Invoke-CtxOAuth { $gDevice } -ParameterFilter { $Endpoint -eq 'devicecode' }
        }

        It 'signs in with its own device-code flow and hands the token to the Graph SDK' {
            $at = New-TestJwt @{ aud = 'https://graph.microsoft.com'; tid = $T1; oid = $O1; upn = 'graphy@contoso.com'; scp = 'User.Read.All Group.Read.All'; exp = $gExp }
            $responses = [Collections.Generic.Queue[object]]::new()
            $responses.Enqueue([pscustomobject]@{ error = 'authorization_pending' })
            $responses.Enqueue([pscustomobject]@{ error = 'slow_down' })
            $responses.Enqueue([pscustomobject]@{ access_token = $at; refresh_token = 'rt-1'; expires_in = 3600 })
            Mock -ModuleName Ctx Invoke-CtxOAuth { $responses.Dequeue() } -ParameterFilter { $Endpoint -eq 'token' }

            $r = InModuleScope Ctx -Parameters @{ E = $gEntry } { param($E) Connect-CtxGraphSession -Entry $E -Scopes @('User.Read.All', 'Group.Read.All') -Label 'Admin' }

            $r.Account | Should -Be 'graphy@contoso.com'
            $r.Scopes | Should -Be @('User.Read.All', 'Group.Read.All')
            Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 1 -Exactly -ParameterFilter {
                $Endpoint -eq 'devicecode' -and $TenantId -eq '11111111-1111-1111-1111-111111111111' -and
                $Body.client_id -eq '14d82eec-204b-4c2f-b7e8-296a70dab67e' -and $Body.scope -eq 'User.Read.All Group.Read.All offline_access openid profile'
            }
            Should -Invoke Show-CtxDeviceCode -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Code -eq 'ABC123' -and $Tool -eq 'Microsoft Graph (Admin)' }
            Should -Invoke Start-Sleep -ModuleName Ctx -Times 2 -Exactly -ParameterFilter { $Seconds -eq 5 }
            Should -Invoke Start-Sleep -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Seconds -eq 10 }
            Should -Invoke Connect-CtxGraphToken -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $AccessToken -eq $at }
            Should -Invoke Start-CtxGraphRenewal -ModuleName Ctx -Times 1 -Exactly
            InModuleScope Ctx {
                $script:GraphEnvName | Should -Be 'graphy'
                $script:GraphProfileName | Should -Be 'Admin'
                $script:GraphToken.RefreshToken | Should -Be 'rt-1'
                $script:GraphToken.ExpiresAt | Should -BeGreaterThan ([datetime]::UtcNow.AddMinutes(55))
            }
        }

        It 'refuses a token for another login or tenant before connecting' {
            foreach ($case in @(
                    @{ Claims = @{ tid = $T1; oid = $O2; upn = 'someone@contoso.com'; exp = $gExp }; Expected = "*signed in as 'someone@contoso.com'*environment = tenant + login*" }
                    @{ Claims = @{ tid = $T2; oid = $O1; upn = 'graphy@contoso.com'; exp = $gExp }; Expected = "*signed into tenant '$T2'*" }
                )) {
                $at = New-TestJwt $case.Claims
                Mock -ModuleName Ctx Invoke-CtxOAuth { [pscustomobject]@{ access_token = $at; refresh_token = 'rt' } } -ParameterFilter { $Endpoint -eq 'token' }
                { InModuleScope Ctx -Parameters @{ E = $gEntry } { param($E) Connect-CtxGraphSession -Entry $E -Scopes @('User.Read') -Label 'Admin' } } |
                    Should -Throw $case.Expected
            }
            Should -Invoke Connect-CtxGraphToken -ModuleName Ctx -Times 0 -Exactly
            InModuleScope Ctx {
                $script:GraphToken | Should -BeNullOrEmpty
                $script:GraphEnvName | Should -BeNullOrEmpty
            }
        }

        It 'stops on declined, expired and failed sign-ins' {
            foreach ($case in @(
                    @{ Response = @{ error = 'authorization_declined' }; Expected = '*declined*' }
                    @{ Response = @{ error = 'expired_token' }; Expected = '*code expired*' }
                    @{ Response = @{ error = 'invalid_scope'; error_description = 'AADSTS70011: The provided value for scope is not valid. Trace ID: 1' }
                        Expected = 'Microsoft Graph (Admin) sign-in failed: AADSTS70011: The provided value for scope is not valid.' }
                )) {
                $resp = [pscustomobject]$case.Response
                Mock -ModuleName Ctx Invoke-CtxOAuth { $resp } -ParameterFilter { $Endpoint -eq 'token' }
                { InModuleScope Ctx -Parameters @{ E = $gEntry } { param($E) Connect-CtxGraphSession -Entry $E -Scopes @('User.Read') -Label 'Admin' } } |
                    Should -Throw $case.Expected
            }
            Mock -ModuleName Ctx Invoke-CtxOAuth { [pscustomobject]@{ error = 'invalid_client'; error_description = 'AADSTS7000218: client_assertion missing.' } } -ParameterFilter { $Endpoint -eq 'devicecode' }
            { InModuleScope Ctx -Parameters @{ E = $gEntry } { param($E) Connect-CtxGraphSession -Entry $E -Scopes @('User.Read') -Label 'Admin' } } |
                Should -Throw '*sign-in failed: AADSTS7000218*'
            Should -Invoke Connect-CtxGraphToken -ModuleName Ctx -Times 0 -Exactly
        }

        It 'does not renew while the token is fresh' {
            Mock -ModuleName Ctx Invoke-CtxOAuth { throw 'unexpected' } -ParameterFilter { $Endpoint -eq 'token' }
            InModuleScope Ctx -Parameters @{ S = (New-GraphTokenState 50) } {
                param($S)
                $script:GraphToken = $S
                Update-CtxGraphToken | Should -BeTrue
            }
            Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 0 -Exactly
        }

        It 'renews a token that is about to expire with the refresh token' {
            $at = New-TestJwt @{ aud = 'https://graph.microsoft.com'; tid = $T1; oid = $O1; upn = 'graphy@contoso.com'; appid = 'cid'; scp = 'User.Read.All'; exp = $gExp }
            Mock -ModuleName Ctx Invoke-CtxOAuth { [pscustomobject]@{ access_token = $at; refresh_token = 'rt-2' } } -ParameterFilter { $Endpoint -eq 'token' }
            InModuleScope Ctx -Parameters @{ S = (New-GraphTokenState 5) } {
                param($S)
                $script:GraphToken = $S
                Update-CtxGraphToken -Quiet | Should -BeTrue
                $script:GraphToken.RefreshToken | Should -Be 'rt-2'
                $script:GraphToken.ExpiresAt | Should -BeGreaterThan ([datetime]::UtcNow.AddMinutes(55))
            }
            Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 1 -Exactly -ParameterFilter {
                $Endpoint -eq 'token' -and $Body.grant_type -eq 'refresh_token' -and $Body.refresh_token -eq 'rt-1' -and
                $Body.client_id -eq 'cid' -and $Body.scope -eq 'User.Read.All offline_access openid profile'
            }
            Should -Invoke Connect-CtxGraphToken -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $AccessToken -eq $at }
        }

        It 'warns once at the prompt and backs off when renewal fails' {
            Mock -ModuleName Ctx Invoke-CtxOAuth { [pscustomobject]@{ error = 'invalid_grant'; error_description = 'AADSTS70043: The refresh token has expired. Trace ID: x' } } -ParameterFilter { $Endpoint -eq 'token' }
            InModuleScope Ctx -Parameters @{ S = (New-GraphTokenState 10) } {
                param($S)
                $script:GraphToken = $S
                Update-CtxGraphToken -Quiet | Should -BeTrue
                $script:GraphToken.RefreshToken | Should -BeNullOrEmpty
                $script:GraphToken.Warned | Should -BeFalse
                Update-CtxGraphToken | Should -BeTrue
                Update-CtxGraphToken | Should -BeTrue
            }
            Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Endpoint -eq 'token' }
            Should -Invoke Write-Host -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { "$Object" -like '*could not be renewed (AADSTS70043: The refresh token has expired.)*' }
        }

        It 'reports an expired token as unusable after a failed renewal' {
            Mock -ModuleName Ctx Invoke-CtxOAuth { throw 'No such host is known.' } -ParameterFilter { $Endpoint -eq 'token' }
            InModuleScope Ctx -Parameters @{ S = (New-GraphTokenState -5) } {
                param($S)
                $script:GraphToken = $S
                $script:GraphEnvName = 'graphy'
                Update-CtxGraphToken | Should -BeFalse
                $script:GraphToken.RefreshToken | Should -Be 'rt-1'
                $script:GraphToken.RetryAfter | Should -BeGreaterThan ([datetime]::UtcNow)
                Test-CtxGraphSession -Entry @{ name = 'graphy'; tenantId = '11111111-1111-1111-1111-111111111111' } | Should -BeFalse
            }
            Should -Invoke Write-Host -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { "$Object" -like '*No such host is known.*expired*' }
        }

        It 'forgets its token when the Graph session was replaced outside ctx' {
            Mock -ModuleName Ctx Get-CtxMgContext { [pscustomobject]@{ AuthType = 'Delegated'; TenantId = '11111111-1111-1111-1111-111111111111' } }
            Mock -ModuleName Ctx Invoke-CtxOAuth { throw 'unexpected' } -ParameterFilter { $Endpoint -eq 'token' }
            InModuleScope Ctx -Parameters @{ S = (New-GraphTokenState 50) } {
                param($S)
                $script:GraphToken = $S
                $script:GraphEnvName = 'graphy'
                Update-CtxGraphToken | Should -BeFalse
                $script:GraphToken | Should -BeNullOrEmpty
                $script:GraphEnvName | Should -BeNullOrEmpty
            }
            Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 0 -Exactly
        }

        It 'reuses a matching cached Az token without a device-code request' {
            $at = New-TestJwt @{ aud = 'https://graph.microsoft.com'; tid = $T1; oid = $O1; upn = 'graphy@contoso.com'; appid = 'az-client'; scp = 'User.Read.All'; exp = $gExp }
            Mock -ModuleName Ctx Get-CtxAzGraphToken { [pscustomobject]@{ access_token = $at } }
            $r = InModuleScope Ctx -Parameters @{ E = $gEntry } {
                param($E)
                Connect-CtxGraphSession -Entry $E -Scopes User.Read.All -Label ReadOnly
                $script:GraphToken.Source | Should -Be 'Az'
                $script:GraphToken.TokenClientId | Should -Be 'az-client'
            }
            $r.Account | Should -Be 'graphy@contoso.com'
            Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 0 -Exactly
            Should -Invoke Connect-CtxGraphToken -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $AccessToken -eq $at }
        }

        It 'falls back to one device code when the cached Az token belongs to another account' {
            $wrong = New-TestJwt @{ aud = 'https://graph.microsoft.com'; tid = $T1; oid = $O2; upn = 'other@contoso.com'; scp = 'User.Read.All'; exp = $gExp }
            $right = New-TestJwt @{ aud = 'https://graph.microsoft.com'; tid = $T1; oid = $O1; upn = 'graphy@contoso.com'; scp = 'User.Read.All'; exp = $gExp }
            Mock -ModuleName Ctx Get-CtxAzGraphToken { [pscustomobject]@{ access_token = $wrong } }
            Mock -ModuleName Ctx Invoke-CtxOAuth { [pscustomobject]@{ access_token = $right; refresh_token = 'rt' } } -ParameterFilter { $Endpoint -eq 'token' }
            InModuleScope Ctx -Parameters @{ E = $gEntry } { param($E) Connect-CtxGraphSession -Entry $E -Scopes User.Read.All -Label ReadOnly } | Out-Null
            Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Endpoint -eq 'devicecode' }
            Should -Invoke Connect-CtxGraphToken -ModuleName Ctx -Times 0 -Exactly -ParameterFilter { $AccessToken -eq $wrong }
            Should -Invoke Connect-CtxGraphToken -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $AccessToken -eq $right }
        }

        It 'does not use an Az token that lacks required authentication-method permissions' {
            $azToken = New-TestJwt @{ aud = 'https://graph.microsoft.com'; tid = $T1; oid = $O1; upn = 'graphy@contoso.com'; scp = 'Directory.AccessAsUser.All User.Read.All'; exp = $gExp }
            $graphToken = New-TestJwt @{ aud = 'https://graph.microsoft.com'; tid = $T1; oid = $O1; upn = 'graphy@contoso.com'; scp = 'UserAuthenticationMethod.ReadWrite.All'; exp = $gExp }
            Mock -ModuleName Ctx Get-CtxAzGraphToken { [pscustomobject]@{ access_token = $azToken } }
            Mock -ModuleName Ctx Invoke-CtxOAuth { [pscustomobject]@{ access_token = $graphToken; refresh_token = 'rt' } } -ParameterFilter { $Endpoint -eq 'token' }
            InModuleScope Ctx -Parameters @{ E = $gEntry } { param($E) Connect-CtxGraphSession -Entry $E -Scopes UserAuthenticationMethod.ReadWrite.All -Label Admin } | Out-Null
            Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Endpoint -eq 'devicecode' }
            Should -Invoke Connect-CtxGraphToken -ModuleName Ctx -Times 0 -Exactly -ParameterFilter { $AccessToken -eq $azToken }
        }

        It 'uses the configured Graph client instead of cached Az credentials' {
            $entry = $gEntry.Clone()
            $entry.graphClientId = 'custom-client'
            $at = New-TestJwt @{ aud = 'https://graph.microsoft.com'; tid = $T1; oid = $O1; upn = 'graphy@contoso.com'; appid = 'custom-client'; scp = 'User.Read.All'; exp = $gExp }
            Mock -ModuleName Ctx Invoke-CtxOAuth { [pscustomobject]@{ access_token = $at; refresh_token = 'rt' } } -ParameterFilter { $Endpoint -eq 'token' }
            InModuleScope Ctx -Parameters @{ E = $entry } { param($E) Connect-CtxGraphSession -Entry $E -Scopes User.Read.All -Label ReadOnly } | Out-Null
            Should -Invoke Get-CtxAzGraphToken -ModuleName Ctx -Times 0 -Exactly
            Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Endpoint -eq 'devicecode' -and $Body.client_id -eq 'custom-client' }
        }

        It 'rejects a token for another API before giving it to the Graph SDK' {
            $at = New-TestJwt @{ aud = 'https://management.azure.com/'; tid = $T1; oid = $O1; upn = 'graphy@contoso.com'; scp = 'User.Read.All'; exp = $gExp }
            Mock -ModuleName Ctx Invoke-CtxOAuth { [pscustomobject]@{ access_token = $at } } -ParameterFilter { $Endpoint -eq 'token' }
            { InModuleScope Ctx -Parameters @{ E = $gEntry } { param($E) Connect-CtxGraphSession -Entry $E -Scopes User.Read.All -Label ReadOnly } } |
                Should -Throw '*not intended for Microsoft Graph*'
            Should -Invoke Connect-CtxGraphToken -ModuleName Ctx -Times 0 -Exactly
        }

        It 'forces a silent refresh even when the previous token is still fresh' {
            $at = New-TestJwt @{ aud = 'https://graph.microsoft.com'; tid = $T1; oid = $O1; upn = 'graphy@contoso.com'; appid = 'cid'; scp = 'User.Read.All'; exp = $gExp }
            Mock -ModuleName Ctx Invoke-CtxOAuth { [pscustomobject]@{ access_token = $at } } -ParameterFilter { $Endpoint -eq 'token' }
            InModuleScope Ctx -Parameters @{ S = (New-GraphTokenState 50) } {
                param($S)
                $script:GraphToken = $S
                Update-CtxGraphToken -Force -Quiet | Should -BeTrue
                $script:GraphToken.RefreshToken | Should -Be 'rt-1'
            }
            Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Endpoint -eq 'token' -and $Body.grant_type -eq 'refresh_token' }
            Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 0 -Exactly -ParameterFilter { $Endpoint -eq 'devicecode' }
        }

        It 'does not report a failed forced refresh as success merely because the old token is usable' {
            Mock -ModuleName Ctx Invoke-CtxOAuth { [pscustomobject]@{ error = 'interaction_required'; error_description = 'MFA required' } } -ParameterFilter { $Endpoint -eq 'token' }
            InModuleScope Ctx -Parameters @{ S = (New-GraphTokenState 50) } {
                param($S)
                $script:GraphToken = $S
                Update-CtxGraphToken -Force -Quiet | Should -BeFalse
                $script:GraphToken.ErrorCode | Should -Be 'interaction_required'
            }
            Should -Invoke Connect-CtxGraphToken -ModuleName Ctx -Times 0 -Exactly
        }

        It 'does not accept a wrong-account token during renewal' {
            $at = New-TestJwt @{ aud = 'https://graph.microsoft.com'; tid = $T1; oid = $O2; upn = 'other@contoso.com'; scp = 'User.Read.All'; exp = $gExp }
            Mock -ModuleName Ctx Invoke-CtxOAuth { [pscustomobject]@{ access_token = $at } } -ParameterFilter { $Endpoint -eq 'token' }
            InModuleScope Ctx -Parameters @{ S = (New-GraphTokenState 50) } {
                param($S)
                $script:GraphToken = $S
                Update-CtxGraphToken -Force -Quiet | Should -BeFalse
                $script:GraphToken.ObjectId | Should -Be 'aaaaaaaa-0000-0000-0000-000000000001'
                $script:GraphToken.ErrorCode | Should -Be 'token_validation'
            }
            Should -Invoke Connect-CtxGraphToken -ModuleName Ctx -Times 0 -Exactly
        }

        It 'stops renewing when another client replaces the Graph token in the same tenant' {
            Mock -ModuleName Ctx Get-CtxMgContext {
                [pscustomobject]@{ AuthType = 'UserProvidedAccessToken'; TenantId = '11111111-1111-1111-1111-111111111111'; Account = 'graphy@contoso.com'; ClientId = 'another-client' }
            }
            InModuleScope Ctx -Parameters @{ S = (New-GraphTokenState 50) } {
                param($S)
                $script:GraphToken = $S
                Update-CtxGraphToken | Should -BeFalse
                $script:GraphToken | Should -BeNullOrEmpty
            }
            Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 0 -Exactly
        }

        It 'renews an Az-backed session through its matching Az context' {
            $at = New-TestJwt @{ aud = 'https://graph.microsoft.com'; tid = $T1; oid = $O1; upn = 'graphy@contoso.com'; appid = 'az-client'; scp = 'User.Read.All'; exp = $gExp }
            Mock -ModuleName Ctx Get-CtxAzGraphToken { [pscustomobject]@{ access_token = $at } }
            InModuleScope Ctx -Parameters @{ S = (New-GraphTokenState 5) } {
                param($S)
                $S.Source = 'Az'
                $S.RefreshToken = $null
                $script:GraphToken = $S
                Update-CtxGraphToken -Quiet | Should -BeTrue
                $script:GraphToken.Source | Should -Be 'Az'
                $script:GraphToken.ExpiresAt | Should -BeGreaterThan ([datetime]::UtcNow.AddMinutes(55))
            }
            Should -Invoke Get-CtxAzGraphToken -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Entry.name -eq 'graphy' }
            Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 0 -Exactly
        }

        It 'stops renewing once the session is older than graphMaxSessionHours' {
            Mock -ModuleName Ctx Invoke-CtxOAuth { throw 'must not renew' } -ParameterFilter { $Endpoint -eq 'token' }
            InModuleScope Ctx -Parameters @{ S = (New-GraphTokenState 5) } {
                param($S)
                $S.SessionStartedAt = [datetime]::UtcNow.AddHours(-13)
                $script:GraphToken = $S
                Update-CtxGraphToken -Quiet | Should -BeTrue
                $script:GraphToken.RefreshToken | Should -BeNullOrEmpty
                $script:GraphToken.ErrorCode | Should -Be 'login_required'
                $script:GraphToken.LastError | Should -BeLike '*graphMaxSessionHours*'
            }
            Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 0 -Exactly
        }

        It 'keeps the session start across renewals and allows unlimited sessions with 0' {
            $at = New-TestJwt @{ aud = 'https://graph.microsoft.com'; tid = $T1; oid = $O1; upn = 'graphy@contoso.com'; appid = 'cid'; scp = 'User.Read.All'; exp = $gExp }
            Mock -ModuleName Ctx Invoke-CtxOAuth { [pscustomobject]@{ access_token = $at; refresh_token = 'rt-2' } } -ParameterFilter { $Endpoint -eq 'token' }
            Set-CtxConfig graphMaxSessionHours 0 6>$null
            try {
                InModuleScope Ctx -Parameters @{ S = (New-GraphTokenState 5) } {
                    param($S)
                    $started = [datetime]::UtcNow.AddHours(-100)
                    $S.SessionStartedAt = $started
                    $script:GraphToken = $S
                    Update-CtxGraphToken -Quiet | Should -BeTrue
                    $script:GraphToken.RefreshToken | Should -Be 'rt-2'
                    $script:GraphToken.SessionStartedAt | Should -Be $started
                }
            } finally { Set-CtxConfig graphMaxSessionHours -Reset 6>$null }
            Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Endpoint -eq 'token' }
        }
    }
}

Describe 'PIM activation' {
    BeforeAll {
        Mock -ModuleName Ctx Write-Host { }
        Mock -ModuleName Ctx Use-CtxPimGraph { }
        Mock -ModuleName Ctx Request-CtxPimActivation { }
    }
    BeforeEach {
        Set-TestState -Current 'pimmy' -Environments @((New-TestEnv 'pimmy' $T1 $O1))
        Mock -ModuleName Ctx Get-CtxPimActiveRoles { @() }
    }

    It 'activates the default role (Global Administrator) when no role is given' {
        Invoke-CtxPim -NoGraph
        Should -Invoke Request-CtxPimActivation -ModuleName Ctx -Times 1 -Exactly -ParameterFilter {
            $Role.Name -eq 'Global Administrator' -and $Role.Id -eq '62e90394-69f5-4237-9190-012177145e10' -and -not $RoleExplicit
        }
    }
    It 'resolves an explicit role alias and remembers it as explicit' {
        Invoke-CtxPim pra -NoGraph
        Should -Invoke Request-CtxPimActivation -ModuleName Ctx -Times 1 -Exactly -ParameterFilter {
            $Role.Name -eq 'Privileged Role Administrator' -and $Role.Id -eq 'e8611ab8-c189-46e8-94e1-60213ab1f814' -and $RoleExplicit
        }
    }
    It 'skips activation when the role is already active' {
        Mock -ModuleName Ctx Get-CtxPimActiveRoles {
            [pscustomobject]@{ RoleId = '62e90394-69f5-4237-9190-012177145e10'; RoleName = 'Global Administrator'; Scope = '/'; End = [datetime]::UtcNow.AddHours(2); AssignmentType = 'Activated' }
        }
        Invoke-CtxPim -NoGraph
        Should -Invoke Request-CtxPimActivation -ModuleName Ctx -Times 0 -Exactly
        Should -Invoke Write-Host -ModuleName Ctx -ParameterFilter { "$Object" -like '*Global Administrator already active*' }
    }
}

Describe 'PIM and Graph login reuse' {
    BeforeAll {
        Mock -ModuleName Ctx Write-Host { }
        Mock -ModuleName Ctx Start-Sleep { }
        Mock -ModuleName Ctx Show-CtxDeviceCode { }
        Mock -ModuleName Ctx Import-CtxGraphModule { }
        Mock -ModuleName Ctx Get-CtxAzGraphToken { }
        Mock -ModuleName Ctx Connect-CtxGraphToken { }
        Mock -ModuleName Ctx Start-CtxGraphRenewal { }
        Mock -ModuleName Ctx Stop-CtxGraphRenewal { }
        Mock -ModuleName Ctx Get-CtxMgContext {
            InModuleScope Ctx {
                if ($script:GraphToken) {
                    [pscustomobject]@{
                        AuthType = 'UserProvidedAccessToken'; TenantId = $script:GraphToken.TenantId
                        Account = $script:GraphToken.Account; ClientId = $script:GraphToken.TokenClientId; Scopes = $script:GraphToken.Scopes
                    }
                }
            }
        }
        $script:dailyScopes = @(InModuleScope Ctx { Get-CtxGraphScopes Admin })
        function New-FlowToken([string[]]$Scopes = $dailyScopes, [string]$ClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e') {
            [pscustomobject]@{
                access_token = New-TestJwt @{
                    aud = 'https://graph.microsoft.com'; tid = $T1; oid = $O1; upn = 'flow@contoso.com'
                    appid = $ClientId; scp = $Scopes -join ' '; exp = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()
                }
                refresh_token = 'flow-refresh-token'
            }
        }
        $script:activeRole = [pscustomobject]@{
            RoleId = '62e90394-69f5-4237-9190-012177145e10'; RoleName = 'Global Administrator'
            Scope = '/'; End = [datetime]::UtcNow.AddHours(2); AssignmentType = 'Activated'
        }
    }
    BeforeEach {
        Set-TestState -Current 'flow' -Environments @((New-TestEnv 'flow' $T1 $O1))
        $script:flowResponse = New-FlowToken
        Mock -ModuleName Ctx Get-CtxPimActiveRoles { @() }
        Mock -ModuleName Ctx Request-CtxPimActivation { $activeRole }
        Mock -ModuleName Ctx Invoke-CtxOAuth {
            [pscustomobject]@{ device_code = 'flow-dc'; user_code = 'FLOW123'; verification_uri = 'https://login.microsoft.com/device'; interval = 5; expires_in = 900 }
        } -ParameterFilter { $Endpoint -eq 'devicecode' }
        Mock -ModuleName Ctx Invoke-CtxOAuth { $flowResponse } -ParameterFilter { $Endpoint -eq 'token' }
    }
    AfterEach {
        InModuleScope Ctx { $script:GraphToken = $null; $script:GraphEnvName = $null; $script:GraphProfileName = $null }
    }

    It 'uses one device code for a new PIM activation and silently refreshes afterwards' {
        Invoke-CtxPim
        Should -Invoke Request-CtxPimActivation -ModuleName Ctx -Times 1 -Exactly
        Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 1 -Exactly -ParameterFilter {
            $Endpoint -eq 'devicecode' -and $Body.scope -like '*Application.ReadWrite.All*' -and
            $Body.scope -like '*RoleAssignmentSchedule.ReadWrite.Directory*' -and ($Body.scope -split ' ').Count -eq 14
        }
        Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Endpoint -eq 'token' -and $Body.grant_type -eq 'refresh_token' }
        InModuleScope Ctx { $script:GraphProfileName | Should -Be 'Admin' }
    }

    It 'does not reconnect after discovering that Global Admin is already active' {
        Mock -ModuleName Ctx Get-CtxPimActiveRoles { $activeRole }
        Invoke-CtxPim
        Should -Invoke Request-CtxPimActivation -ModuleName Ctx -Times 0 -Exactly
        Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Endpoint -eq 'devicecode' }
        Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 0 -Exactly -ParameterFilter { $Endpoint -eq 'token' -and $Body.grant_type -eq 'refresh_token' }
    }

    It 'needs no Graph login when a matching Az token covers the profile and PIM is already active' {
        $cached = New-FlowToken -ClientId 'az-client'
        Mock -ModuleName Ctx Get-CtxAzGraphToken { $cached }
        Mock -ModuleName Ctx Get-CtxPimActiveRoles { $activeRole }
        Invoke-CtxPim
        Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 0 -Exactly
        InModuleScope Ctx { $script:GraphToken.Source | Should -Be 'Az' }
    }

    It 'uses at most one device code when Az cannot force a fresh token after a new activation' {
        $cached = New-FlowToken -ClientId 'az-client'
        Mock -ModuleName Ctx Get-CtxAzGraphToken { $cached }
        Invoke-CtxPim
        Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Endpoint -eq 'devicecode' }
        Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 0 -Exactly -ParameterFilter { $Endpoint -eq 'token' -and $Body.grant_type -eq 'refresh_token' }
        InModuleScope Ctx { $script:GraphToken.Source | Should -Be 'DeviceCode' }
    }

    It 'reuses a suitable Graph session across repeated commands without another login' {
        Connect-CtxGraph
        Mock -ModuleName Ctx Get-CtxPimActiveRoles { $activeRole }
        Invoke-CtxPim
        Connect-CtxGraph
        Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Endpoint -eq 'devicecode' }
        Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 0 -Exactly -ParameterFilter { $Endpoint -eq 'token' -and $Body.grant_type -eq 'refresh_token' }
    }

    It 'keeps NoGraph activation limited to the PIM bootstrap scopes' {
        Invoke-CtxPim -NoGraph
        Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 1 -Exactly -ParameterFilter {
            $Endpoint -eq 'devicecode' -and $Body.scope -eq 'RoleEligibilitySchedule.Read.Directory RoleAssignmentSchedule.ReadWrite.Directory offline_access openid profile'
        }
        Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 0 -Exactly -ParameterFilter { $Endpoint -eq 'token' -and $Body.grant_type -eq 'refresh_token' }
    }

    It 'adds scopes silently, deduplicates them and does not persist additions or tokens' {
        Connect-CtxGraph
        $before = Get-Content -LiteralPath (Join-Path $env:CTX_HOME 'environments.json') -Raw
        $expanded = New-FlowToken -Scopes @($dailyScopes + 'AuditLog.Read.All')
        Mock -ModuleName Ctx Invoke-CtxOAuth { $expanded } -ParameterFilter { $Endpoint -eq 'token' -and $Body.grant_type -eq 'refresh_token' }
        ctx graph -AddScopes 'AuditLog.Read.All,AuditLog.Read.All'
        Connect-CtxGraph
        Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Endpoint -eq 'devicecode' }
        Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 1 -Exactly -ParameterFilter {
            $Endpoint -eq 'token' -and $Body.grant_type -eq 'refresh_token' -and
            @($Body.scope -split ' ' | Where-Object { $_ -eq 'AuditLog.Read.All' }).Count -eq 1 -and $Body.scope -like '*Application.ReadWrite.All*'
        }
        InModuleScope Ctx {
            $script:GraphToken.Scopes | Should -Contain 'AuditLog.Read.All'
            $script:GraphProfileName | Should -Be 'Admin'
        }
        Get-Content -LiteralPath (Join-Path $env:CTX_HOME 'environments.json') -Raw | Should -Be $before
    }

    It 'requests one additional device code only when adding scopes requires consent' {
        Connect-CtxGraph
        $expanded = New-FlowToken -Scopes @($dailyScopes + 'AuditLog.Read.All')
        Mock -ModuleName Ctx Invoke-CtxOAuth {
            [pscustomobject]@{ error = 'consent_required'; error_description = 'AADSTS65001: Consent is required.' }
        } -ParameterFilter { $Endpoint -eq 'token' -and $Body.grant_type -eq 'refresh_token' }
        Mock -ModuleName Ctx Invoke-CtxOAuth { $expanded } -ParameterFilter { $Endpoint -eq 'token' -and $Body.grant_type -like '*device_code' }
        ctx graph -AddScopes AuditLog.Read.All
        Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 2 -Exactly -ParameterFilter { $Endpoint -eq 'devicecode' }
        Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Endpoint -eq 'devicecode' -and $Body.scope -like '*AuditLog.Read.All*' }
        InModuleScope Ctx { $script:GraphToken.Scopes | Should -Contain 'AuditLog.Read.All' }
    }

    It 'keeps session additions when PIM requires a fresh token' {
        Connect-CtxGraph
        $expanded = New-FlowToken -Scopes @($dailyScopes + 'AuditLog.Read.All')
        Mock -ModuleName Ctx Invoke-CtxOAuth { $expanded } -ParameterFilter { $Endpoint -eq 'token' -and $Body.grant_type -eq 'refresh_token' }
        Connect-CtxGraph -AddScopes AuditLog.Read.All
        Invoke-CtxPim
        Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Endpoint -eq 'devicecode' }
        Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 2 -Exactly -ParameterFilter {
            $Endpoint -eq 'token' -and $Body.grant_type -eq 'refresh_token' -and $Body.scope -like '*AuditLog.Read.All*'
        }
        InModuleScope Ctx { $script:GraphToken.Scopes | Should -Contain 'AuditLog.Read.All' }
    }

    It 'preserves the original refresh token when consent to added scopes is declined' {
        Connect-CtxGraph
        Mock -ModuleName Ctx Invoke-CtxOAuth {
            [pscustomobject]@{ error = 'invalid_grant'; error_description = 'AADSTS65001: Consent is required.' }
        } -ParameterFilter { $Endpoint -eq 'token' -and $Body.grant_type -eq 'refresh_token' }
        Mock -ModuleName Ctx Invoke-CtxOAuth {
            [pscustomobject]@{ error = 'authorization_declined' }
        } -ParameterFilter { $Endpoint -eq 'token' -and $Body.grant_type -like '*device_code' }
        { Connect-CtxGraph -AddScopes AuditLog.Read.All } | Should -Throw '*declined*'
        InModuleScope Ctx {
            $script:GraphToken.RefreshToken | Should -Be 'flow-refresh-token'
            $script:GraphToken.Scopes | Should -Not -Contain 'AuditLog.Read.All'
            Update-CtxGraphToken | Should -BeTrue
        }
        Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 2 -Exactly -ParameterFilter { $Endpoint -eq 'devicecode' }
    }

    It 'does not open a device login or silently drop scopes when a refresh has a network failure' {
        Connect-CtxGraph
        Mock -ModuleName Ctx Invoke-CtxOAuth { throw 'Network is unavailable.' } -ParameterFilter { $Endpoint -eq 'token' -and $Body.grant_type -eq 'refresh_token' }
        { Connect-CtxGraph -AddScopes AuditLog.Read.All } | Should -Throw '*token renewal failed*Network is unavailable*'
        Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Endpoint -eq 'devicecode' }
        InModuleScope Ctx { $script:GraphToken.Scopes | Should -Not -Contain 'AuditLog.Read.All' }
    }

    It 'reports an expired-session network error without retrying immediately or starting a new login' {
        Connect-CtxGraph
        InModuleScope Ctx { $script:GraphToken.ExpiresAt = [datetime]::UtcNow.AddMinutes(-1) }
        Mock -ModuleName Ctx Invoke-CtxOAuth { throw 'Network is unavailable.' } -ParameterFilter { $Endpoint -eq 'token' -and $Body.grant_type -eq 'refresh_token' }
        { Connect-CtxGraph } | Should -Throw '*token renewal failed*Network is unavailable*'
        Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Endpoint -eq 'devicecode' }
        Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Endpoint -eq 'token' -and $Body.grant_type -eq 'refresh_token' }
    }

    It 'does not retry with another profile when the sign-in fails' {
        Mock -ModuleName Ctx Connect-CtxGraphSession { throw 'AADSTS70011: invalid_scope' }
        { Connect-CtxGraph -AddScopes NotAReal.Scope } | Should -Throw '*invalid_scope*'
        { Connect-CtxGraph } | Should -Throw '*invalid_scope*'
        Should -Invoke Connect-CtxGraphSession -ModuleName Ctx -Times 2 -Exactly
        (Get-TestState).environments[0].graphProfile | Should -BeNullOrEmpty
    }

    It 'replaces additions when an explicit narrower profile is selected' {
        Connect-CtxGraph
        $expanded = New-FlowToken -Scopes @($dailyScopes + 'AuditLog.Read.All')
        Mock -ModuleName Ctx Invoke-CtxOAuth { $expanded } -ParameterFilter { $Endpoint -eq 'token' -and $Body.grant_type -eq 'refresh_token' }
        Connect-CtxGraph -AddScopes AuditLog.Read.All
        $readOnlyScopes = @(InModuleScope Ctx { Get-CtxGraphScopes ReadOnly })
        $readOnly = New-FlowToken -Scopes $readOnlyScopes
        Mock -ModuleName Ctx Invoke-CtxOAuth { $readOnly } -ParameterFilter { $Endpoint -eq 'token' -and $Body.grant_type -eq 'refresh_token' }
        Connect-CtxGraph ReadOnly
        Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Endpoint -eq 'devicecode' }
        Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 2 -Exactly -ParameterFilter { $Endpoint -eq 'token' -and $Body.grant_type -eq 'refresh_token' }
        InModuleScope Ctx {
            $script:GraphProfileName | Should -Be 'ReadOnly'
            $script:GraphToken.Scopes | Should -Not -Contain 'AuditLog.Read.All'
            @($script:GraphToken.Scopes | Where-Object { $_ -match 'ReadWrite' }).Count | Should -Be 0
        }
    }

    It 'supports an explicit fresh device login' {
        Connect-CtxGraph
        ctx graph -Relogin
        Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 2 -Exactly -ParameterFilter { $Endpoint -eq 'devicecode' }
        Should -Invoke Get-CtxAzGraphToken -ModuleName Ctx -Times 1 -Exactly
    }

    It 'rejects empty scope additions before starting authentication' {
        { Connect-CtxGraph -AddScopes ' , ' } | Should -Throw '*at least one Microsoft Graph permission*'
        Should -Invoke Invoke-CtxOAuth -ModuleName Ctx -Times 0 -Exactly
    }
}

Describe 'Configuration' {
    It 'converts values by the type of the default' {
        InModuleScope Ctx {
            ConvertTo-CtxConfigValue -Value 'off' -Default $true -Name 'x' | Should -BeFalse
            ConvertTo-CtxConfigValue -Value 'yes' -Default $false -Name 'x' | Should -BeTrue
            ConvertTo-CtxConfigValue -Value '2' -Default 4 -Name 'x' | Should -Be 2
            ConvertTo-CtxConfigValue -Value '2' -Default 4 -Name 'x' | Should -BeOfType [int]
            ConvertTo-CtxConfigValue -Value 'prod, live' -Default @('prod') -Name 'x' | Should -Be @('prod', 'live')
            { ConvertTo-CtxConfigValue -Value 'maybe' -Default $true -Name 'x' } | Should -Throw
        }
    }
    It 'sets and resets settings' {
        ctx config pimDefaultHours 2 6>$null
        (Get-CtxConfig).pimDefaultHours | Should -Be 2
        ctx config pimDefaultHours -Reset 6>$null
        (Get-CtxConfig).pimDefaultHours | Should -Be 4
    }
    It 'rejects unknown settings' { { ctx config nope 1 } | Should -Throw '*Unknown setting*' }
}

Describe 'Dispatcher' {
    BeforeAll {
        Set-TestState -Current 'emea' -Environments @((New-TestEnv 'emea' $T1 $O1), (New-TestEnv 'germany' $T2 $O2))
        foreach ($fn in 'Invoke-CtxPim', 'Connect-CtxGraph', 'Rename-CtxEnvironment', 'Invoke-CtxCommand', 'Switch-CtxEnvironment', 'Set-CtxConfig', 'Select-CtxSubscription', 'Remove-CtxEnvironment', 'Get-CtxEnvironment') {
            Mock -ModuleName Ctx -CommandName $fn -MockWith { }
        }
    }
    It 'forwards verb parameters (ctx pim -Hours 4)' {
        ctx pim -Hours 4 -Reason 'change 1'
        Should -Invoke Invoke-CtxPim -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Hours -eq 4 -and $Reason -eq 'change 1' }
    }
    It 'forwards additional Graph scopes' {
        ctx graph -AddScopes AuditLog.Read.All,Policy.ReadWrite.AuthenticationMethod
        Should -Invoke Connect-CtxGraph -ModuleName Ctx -Times 1 -Exactly -ParameterFilter {
            $AddScopes.Count -eq 2 -and $AddScopes -contains 'AuditLog.Read.All' -and $AddScopes -contains 'Policy.ReadWrite.AuthenticationMethod'
        }
    }
    It 'shifts positional parameters behind the verb (ctx rename a b)' {
        ctx rename a b
        Should -Invoke Rename-CtxEnvironment -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Name -eq 'a' -and $NewName -eq 'b' }
    }
    It 'passes script blocks (ctx exec x {})' {
        ctx exec emea, germany { 'hi' }
        Should -Invoke Invoke-CtxCommand -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Name.Count -eq 2 -and $ScriptBlock.ToString().Trim() -eq "'hi'" }
    }
    It 'switches for environment names (ctx germany -Admin)' {
        ctx germany -Admin
        Should -Invoke Switch-CtxEnvironment -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Name -eq 'germany' -and $Admin }
    }
    It 'switches back with ctx -' {
        ctx -
        Should -Invoke Switch-CtxEnvironment -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Name -eq '-' }
    }
    It 'opens the picker without arguments' {
        ctx
        Should -Invoke Switch-CtxEnvironment -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { -not $Name }
    }
    It 'passes values (ctx config key value, ctx sub "name with space")' {
        ctx config pimDefaultHours 2
        Should -Invoke Set-CtxConfig -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Name -eq 'pimDefaultHours' -and $Value -eq 2 }
        ctx sub 'Platform Prod'
        Should -Invoke Select-CtxSubscription -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Subscription -eq 'Platform Prod' }
    }
    It 'forwards -WhatIf to remove' {
        ctx rm germany -WhatIf
        Should -Invoke Remove-CtxEnvironment -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Name -eq 'germany' -and $WhatIf }
    }
    It 'exposes the parameters of the target command' {
        (Get-Command Invoke-Ctx -ArgumentList 'pim').Parameters.Keys | Should -Contain 'Hours'
        (Get-Command Invoke-Ctx -ArgumentList 'graph').Parameters.Keys | Should -Contain 'AddScopes'
        (Get-Command Invoke-Ctx -ArgumentList 'emea').Parameters.Keys | Should -Contain 'Local'
        (Get-Command Invoke-Ctx -ArgumentList 'emea').Parameters.Keys | Should -Not -Contain 'Name'
    }
}

Describe 'Completion' {
    BeforeAll {
        Set-TestState -Current 'emea' -Environments @((New-TestEnv 'emea' $T1 $O1), (New-TestEnv 'germany' $T2 $O2))
    }
    It 'completes environments and verbs for the target' {
        $r = InModuleScope Ctx { Invoke-CtxCompletion -Command 'ctx' -Parameter 'Target' -Word 'g' -Fake @{} }
        $r.CompletionText | Should -Contain 'germany'
        $r.CompletionText | Should -Contain 'graph'
    }
    It 'routes dynamic parameters by verb' {
        $r = InModuleScope Ctx { Invoke-CtxCompletion -Command 'ctx' -Parameter 'Role' -Word 'ga' -Fake @{ Target = 'pim' } }
        $r.CompletionText | Should -Contain 'ga'
        $r = InModuleScope Ctx { Invoke-CtxCompletion -Command 'ctx' -Parameter 'Name' -Word 'pim' -Fake @{ Target = 'config' } }
        $r.CompletionText | Should -Contain 'pimDefaultHours'
    }
    It 'works through TabExpansion2' {
        $line = 'ctx pim -Environment ger'
        (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText | Should -Contain 'germany'
    }
    It 'completes scope additions through the graph dispatcher' {
        Mock -ModuleName Ctx Get-CtxDelegatedPermissionNames { @('AuditLog.Read.All', 'Mail.Read') }
        $line = 'ctx graph -AddScopes Aud'
        (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText | Should -Contain 'AuditLog.Read.All'
    }
}

Describe 'Switching' {
    BeforeAll {
        Mock -ModuleName Ctx Write-Host { }
        Mock -ModuleName Ctx Initialize-CtxCliDir { }
        Mock -ModuleName Ctx Start-CtxCliTokenCheck { 'handle' }
        Mock -ModuleName Ctx Complete-CtxCliTokenCheck { [pscustomobject]@{ Ok = $true; Reason = $null; Identity = $null; Missing = $false } }
        Mock -ModuleName Ctx Get-CtxCliDefaultSubscription { [pscustomobject]@{ id = 'sub-1'; name = 'Sub One'; isDefault = $true } }
        Mock -ModuleName Ctx Set-CtxAzEnvironment { [pscustomobject]@{ Ok = $true; SubscriptionId = 'sub-1'; SubscriptionName = 'Sub One'; Account = 'x' } }
        Mock -ModuleName Ctx Save-CtxAzPosition { [pscustomobject]@{ Id = 'sub-9'; Name = 'Nine' } }
        Mock -ModuleName Ctx Invoke-CtxAdminOffer { }
        Mock -ModuleName Ctx Disconnect-CtxGraphSession { }
    }
    BeforeEach {
        Set-TestState -Current 'alpha' -Environments @(
            (New-TestEnv 'alpha' $T1 $O1), (New-TestEnv 'beta' $T2 $O2), (New-TestEnv 'azonly' $T2 $O1 -Tools @('az'))
        )
    }
    It 'switches globally (user env + Az CurrentUser) and remembers the outgoing position' {
        ctx beta
        $s = Get-TestState
        $s.current | Should -Be 'beta'
        $s.previous | Should -Be 'alpha'
        Get-TestUserEnv 'AZURE_CONFIG_DIR' | Should -Be (Join-Path $testHome 'cli\beta')
        $env:AZURE_CONFIG_DIR | Should -Be (Join-Path $testHome 'cli\beta')
        Should -Invoke Set-CtxAzEnvironment -ModuleName Ctx -ParameterFilter { $Scope -eq 'CurrentUser' -and $Entry.name -eq 'beta' }
        ($s.environments | Where-Object name -EQ 'alpha').azSubscriptionId | Should -Be 'sub-9'
        InModuleScope Ctx { $script:ProcessEnvName } | Should -Be 'beta'
        Get-CtxPromptBadge -NoColor | Should -Be '[beta]'
    }
    It 'switches only this terminal with -Local' {
        ctx beta -Local
        (Get-TestState).current | Should -Be 'alpha'
        Get-TestUserEnv 'AZURE_CONFIG_DIR' | Should -BeNullOrEmpty
        $env:AZURE_CONFIG_DIR | Should -Be (Join-Path $testHome 'cli\beta')
        Should -Invoke Set-CtxAzEnvironment -ModuleName Ctx -ParameterFilter { $Scope -eq 'Process' }
        Get-CtxPromptBadge -NoColor | Should -Be '[beta*→alpha]'
    }
    It 'goes back with ctx -' {
        ctx beta -Local
        ctx -
        InModuleScope Ctx { $script:ProcessEnvName } | Should -Be 'alpha'
    }
    It 'syncs a terminal to the global environment' {
        ctx beta -Local
        ctx sync
        InModuleScope Ctx { $script:ProcessEnvName; $script:ProcessLocal } | Should -Be @('alpha', $false)
    }
    It 'resets the CLI variables for Az-only environments' {
        ctx beta
        ctx azonly
        Get-TestUserEnv 'AZURE_CONFIG_DIR' | Should -BeNullOrEmpty
        $env:AZURE_CONFIG_DIR | Should -BeNullOrEmpty
    }
    It 'runs commands across environments and restores the terminal (ctx exec)' {
        $names = ctx exec alpha, beta { $_.Name }
        $names | Should -Be @('alpha', 'beta')
        InModuleScope Ctx { $script:ProcessEnvName } | Should -Be 'alpha'
        (Get-TestState).current | Should -Be 'alpha'
    }
    It 'asks before ctx exec runs in production environments (-Force skips)' {
        Set-TestState -Current 'alpha' -Environments @((New-TestEnv 'alpha' $T1 $O1), (New-TestEnv 'live' $T2 $O2 -Tags @('prod')))
        Mock -ModuleName Ctx Confirm-CtxTyped { $false }
        $names = ctx exec all { $_.Name }
        $names | Should -BeNullOrEmpty
        Should -Invoke Confirm-CtxTyped -ModuleName Ctx -Times 1 -Exactly -ParameterFilter { $Expected -eq 'live' -and $Message -like '*PRODUCTION: live*' }
        $names = ctx exec all { $_.Name } -Force
        $names | Should -Be @('alpha', 'live')
        Should -Invoke Confirm-CtxTyped -ModuleName Ctx -Times 1 -Exactly
        $names = ctx exec alpha { $_.Name }
        $names | Should -Be 'alpha'
        Should -Invoke Confirm-CtxTyped -ModuleName Ctx -Times 1 -Exactly
    }
}

Describe 'Managing environments' {
    BeforeAll { Mock -ModuleName Ctx Write-Host { } }
    BeforeEach {
        Set-TestState -Current 'alpha' -Environments @(
            (New-TestEnv 'alpha' $T1 $O1 -Tools @('cli')), (New-TestEnv 'beta' $T2 $O2 -Tools @('cli'))
        )
    }
    It 'lists environments with markers' {
        $list = ctx list
        $list.Name | Should -Be @('alpha', 'beta')
        ($list | Where-Object Name -EQ 'alpha').Current | Should -Be '*'
    }
    It 'sets tags, color and PIM defaults' {
        $r = ctx set beta -AddTag Prod, LAB -Color Red -PimHours 2 -PimRole pra
        $r.Tags | Should -Be @('prod', 'lab')
        $r.Prod | Should -BeTrue
        $e = (Get-TestState).environments | Where-Object name -EQ 'beta'
        $e.color | Should -Be 'Red'
        $e.pim.hours | Should -Be 2
        $e.pim.role | Should -Be 'Privileged Role Administrator'
    }
    It 'renames the global environment including the CLI folder and user variable' {
        InModuleScope Ctx { Set-CtxUserEnv 'AZURE_CONFIG_DIR' (Get-CtxCliDir 'alpha') }
        New-Item -ItemType Directory -Path (Join-Path $testHome 'cli\alpha') -Force | Out-Null
        ctx rename alpha gamma
        $s = Get-TestState
        $s.current | Should -Be 'gamma'
        Test-Path (Join-Path $testHome 'cli\gamma') | Should -BeTrue
        Get-TestUserEnv 'AZURE_CONFIG_DIR' | Should -Be (Join-Path $testHome 'cli\gamma')
        (InModuleScope Ctx { $script:ProcessEnvName }) | Should -Be 'gamma'
    }
    It 'keeps Graph renewal bound to the renamed Az context' {
        InModuleScope Ctx {
            $script:GraphEnvName = 'alpha'
            $script:GraphToken = @{ Source = 'Az'; Entry = Find-CtxEnvironment (Read-CtxState) 'alpha' }
        }
        Rename-CtxEnvironment alpha gamma
        InModuleScope Ctx {
            $script:GraphEnvName | Should -Be 'gamma'
            $script:GraphToken.Entry.name | Should -Be 'gamma'
            $script:GraphToken.Entry.azContextName | Should -Be 'ctx:gamma'
        }
    }
    It 'removes an environment and its CLI folder' {
        New-Item -ItemType Directory -Path (Join-Path $testHome 'cli\beta') -Force | Out-Null
        ctx rm beta -Force
        (Get-TestState).environments.name | Should -Not -Contain 'beta'
        Test-Path (Join-Path $testHome 'cli\beta') | Should -BeFalse
    }
    It 'does not remove with -WhatIf' {
        ctx rm beta -WhatIf
        (Get-TestState).environments.name | Should -Contain 'beta'
    }
    It 'exports and imports definitions, refusing duplicate identities' {
        $file = Join-Path $testHome 'export.json'
        ctx export $file
        ctx rm beta -Force
        ctx import $file
        (Get-TestState).environments.name | Should -Contain 'beta'

        $doc = Get-Content $file -Raw | ConvertFrom-Json -AsHashtable
        $doc.environments[1].name = 'beta-copy'
        $doc | ConvertTo-Json -Depth 10 | Set-Content $file
        ctx import $file -Name beta-copy
        (Get-TestState).environments.name | Should -Not -Contain 'beta-copy'
    }
}

Describe 'Security hardening' {
    BeforeAll { Mock -ModuleName Ctx Write-Host { } }

    It 'refuses az arguments that cmd.exe would interpret' -TestCases @(
        @{ Arg = 'x"&calc&rem "' }, @{ Arg = '%PATH%' }, @{ Arg = 'a|b' }, @{ Arg = 'a>b' }, @{ Arg = 'a^b' }, @{ Arg = "a`nb" }
    ) {
        param($Arg)
        { InModuleScope Ctx -Parameters @{ A = $Arg } { param($A) Assert-CtxAzCliArgument @('account', '--tenant', $A) } } | Should -Throw '*shell metacharacters*'
    }
    It 'accepts the arguments ctx itself passes to az' {
        InModuleScope Ctx -Parameters @{ T = $T1 } {
            param($T)
            { Assert-CtxAzCliArgument @('account', 'get-access-token', '--tenant', $T, '--query', 'accessToken', '-o', 'tsv') } | Should -Not -Throw
            { Assert-CtxAzCliArgument @('rest', '--url', 'https://graph.microsoft.com/v1.0/organization?$select=displayName,verifiedDomains') } | Should -Not -Throw
        }
    }
    It 'never starts az with an injected tenant id' {
        Mock -ModuleName Ctx Get-CtxAzCliPath { 'C:\nowhere\az.cmd' }
        Mock -ModuleName Ctx Initialize-CtxCliDir { }
        Mock -ModuleName Ctx Invoke-CtxDeviceLogin { }
        $bad = @{ name = 'evil'; tenantId = 'x"&echo pwned>%TEMP%\ctx-pwned.txt&rem "' }
        { InModuleScope Ctx -Parameters @{ E = $bad } { param($E) Start-CtxCliTokenCheck $E } } | Should -Throw '*shell metacharacters*'
        { InModuleScope Ctx -Parameters @{ E = $bad } { param($E) Connect-CtxCli -Entry $E -Dir (Join-Path $env:CTX_HOME 'cli\evil') } } | Should -Throw '*shell metacharacters*'
        Should -Invoke Invoke-CtxDeviceLogin -ModuleName Ctx -Times 0 -Exactly
    }
    It 'validates tenants on add before any sign-in' {
        Set-TestState -Current $null -Environments @()
        Mock -ModuleName Ctx Get-CtxAzCliPath { 'C:\nowhere\az.cmd' }
        Mock -ModuleName Ctx Test-CtxAzAvailable { $true }
        Mock -ModuleName Ctx Connect-CtxCli { throw 'must not sign in' }
        { Add-CtxEnvironment -Name 'evil' -Tenant 'contoso.com" --x' } | Should -Throw '*Invalid tenant*'
        Should -Invoke Connect-CtxCli -ModuleName Ctx -Times 0 -Exactly
        InModuleScope Ctx {
            Test-CtxTenantSpec 'contoso.onmicrosoft.com' | Should -BeTrue
            Test-CtxTenantSpec '11111111-1111-1111-1111-111111111111' | Should -BeTrue
            Test-CtxTenantSpec 'common' | Should -BeFalse
            Test-CtxTenantSpec 'a b.com' | Should -BeFalse
        }
    }
    It 'imports only valid, portable definitions' {
        Set-TestState -Current $null -Environments @()
        $file = Join-Path $testHome 'untrusted.json'
        $esc = [char]27
        @{
            ctxExport    = 1
            environments = @(
                @{ name = 'good'; tenantId = $T1; userObjectId = $O1; upn = "good@contoso.com$esc]0;owned$([char]7)"; tenantDomain = 'contoso.onmicrosoft.com'
                    description = "line1`nline2$esc[2J"; color = 'NotAColor'; tools = @('cli', 'evil'); adminOnSwitch = 'sometimes'
                    pim = @{ hours = 99; reason = 'ok'; extra = 'x' }; browserProfile = '..\..\Windows'; azContextName = 'other'; foo = 'bar'
                    activations = @(@{ roleId = 'r'; expiresAt = '2099-01-01T00:00:00Z' }) }
                @{ name = 'cmdinject'; tenantId = 'x"&calc&rem "'; userObjectId = $O2 }
                @{ name = 'urlinject'; tenantId = $T2; userObjectId = $O2; tenantDomain = 'x.com" --gpu-launcher="calc' }
                @{ name = 'subinject'; tenantId = $T2; userObjectId = $O1; cliSubscriptionId = 'x"&calc' }
                @{ name = 'client'; tenantId = $T2; userObjectId = $O2; graphClientId = '99999999-9999-9999-9999-999999999999' }
                @{ name = '../escape'; tenantId = $T2; userObjectId = $O1 }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $file
        Mock -ModuleName Ctx Test-CtxInteractive { $false }
        ctx import $file
        $s = Get-TestState
        @($s.environments.name) | Should -Be @('good', 'client')
        $good = $s.environments | Where-Object name -EQ 'good'
        $good.upn | Should -Be 'good@contoso.com]0;owned'
        $good.description | Should -Be 'line1line2[2J'
        $good.color | Should -BeNullOrEmpty
        $good.tools | Should -Be @('cli')
        $good.adminOnSwitch | Should -BeNullOrEmpty
        $good.pim.Keys | Should -Be @('reason')
        $good.browserProfile | Should -Be 'ctx-good'
        $good.azContextName | Should -Be 'ctx:good'
        $good.Contains('foo') | Should -BeFalse
        @($good.activations).Count | Should -Be 0
        ($s.environments | Where-Object name -EQ 'client').graphClientId | Should -BeNullOrEmpty
        Should -Invoke Write-Host -ModuleName Ctx -ParameterFilter { "$Object" -like "skip 'cmdinject': tenantId*is not a GUID*" }
        Should -Invoke Write-Host -ModuleName Ctx -ParameterFilter { "$Object" -like "skip 'urlinject': tenantDomain*is not a domain name*" }
        Should -Invoke Write-Host -ModuleName Ctx -ParameterFilter { "$Object" -like "skip 'subinject': cliSubscriptionId*" }
        Should -Invoke Write-Host -ModuleName Ctx -ParameterFilter { "$Object" -like "*dropped graphClientId 99999999-9999-9999-9999-999999999999*" }

        ctx import $file -Name client -Force -AllowGraphClientId
        ((Get-TestState).environments | Where-Object name -EQ 'client').graphClientId | Should -Be '99999999-9999-9999-9999-999999999999'
    }
    It 'requires GUIDs for Graph client ids set by hand' {
        Set-TestState -Current 'alpha' -Environments @((New-TestEnv 'alpha' $T1 $O1))
        { ctx set alpha -GraphClientId 'not-a-guid' } | Should -Throw '*GUID*'
    }
    It 'starts the browser with one argument per value' {
        InModuleScope Ctx {
            $entry = @{ name = 'x'; browserProfile = 'ctx-x' }
            $psi = New-CtxBrowserStartInfo -Browser 'C:\b\msedge.exe' -Url 'https://portal.azure.com/#@x" --gpu-launcher="calc' -Entry $entry
            @($psi.ArgumentList) | Should -Be @('--profile-directory=ctx-x', '--no-first-run', '--no-default-browser-check', 'https://portal.azure.com/#@x%22%20--gpu-launcher=%22calc')
            $psi.UseShellExecute | Should -BeFalse
            @((New-CtxBrowserStartInfo -Browser 'C:\b\chrome.exe' -Url 'https://x.org/' -Entry $entry -InPrivate).ArgumentList) | Should -Be @('--incognito', 'https://x.org/')
            { ConvertTo-CtxBrowserUrl 'file:///C:/Windows/System32/calc.exe' } | Should -Throw '*only http(s)*'
            { ConvertTo-CtxBrowserUrl 'calc.exe' } | Should -Throw '*only http(s)*'
        }
    }
    It 'builds portal URLs only from a valid tenant' {
        InModuleScope Ctx -Parameters @{ T = $T1 } {
            param($T)
            Get-CtxPortalUrl -Entry @{ tenantId = $T; tenantDomain = 'x.com" --flag' } -Portal azure | Should -Be "https://portal.azure.com/#@$T"
            { Get-CtxPortalUrl -Entry @{ name = 'bad'; tenantId = 'x" --flag' } -Portal security } | Should -Throw '*invalid tenant ID*'
        }
    }
    It 'refuses browser profile names that leave the browser user-data folder' -TestCases @(
        @{ ProfileName = '..\..\Windows' }, @{ ProfileName = 'C:\Windows' }, @{ ProfileName = '..' }, @{ ProfileName = '' }
    ) {
        param($ProfileName)
        { InModuleScope Ctx -Parameters @{ P = $ProfileName } { param($P) Get-CtxBrowserProfileDir @{ browserProfile = $P } } } | Should -Throw '*Invalid browser profile*'
    }
    It 'opens and shows only Microsoft device-login pages' {
        InModuleScope Ctx {
            Get-CtxDeviceLoginUrl 'https://microsoft.com/devicelogin' | Should -Be 'https://microsoft.com/devicelogin'
            Get-CtxDeviceLoginUrl 'https://login.microsoft.com/device' | Should -Be 'https://login.microsoft.com/device'
            Get-CtxDeviceLoginUrl 'https://evil.example/devicelogin' | Should -Be 'https://microsoft.com/devicelogin'
            Get-CtxDeviceLoginUrl 'https://microsoft.com.evil.example/x' | Should -Be 'https://microsoft.com/devicelogin'
            Get-CtxDeviceLoginUrl 'http://microsoft.com/devicelogin' | Should -Be 'https://microsoft.com/devicelogin'
            Get-CtxDeviceLoginUrl 'https://login.microsoftonline.com:8443/x' | Should -Be 'https://microsoft.com/devicelogin'
        }
    }
    It 'strips terminal control characters from stored text' {
        $esc = [char]27
        Set-TestState -Current 'alpha' -Environments @(@{ name = 'alpha'; tenantId = $T1; userObjectId = $O1; tenantName = "Evil$esc[31m"; description = "a$([char]0x202E)b" })
        $e = (Get-TestState).environments[0]
        $e.tenantName | Should -Be 'Evil[31m'
        $e.description | Should -Be 'ab'
    }
}

Describe 'Reliability and safety' {
    BeforeAll { Mock -ModuleName Ctx Write-Host { } }

    It 'exports exactly the manifest surface' {
        $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $repoRoot 'Ctx\Ctx.psd1')
        @((Get-Module Ctx).ExportedFunctions.Keys | Sort-Object) | Should -Be @($manifest.FunctionsToExport | Sort-Object)
        @((Get-Module Ctx).ExportedAliases.Keys) | Should -Be @('ctx')
    }
    It 'supports -WhatIf on every exported command that changes state' {
        $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $repoRoot 'Ctx\Ctx.psd1')
        foreach ($fn in @($manifest.FunctionsToExport | Where-Object { $_ -match '^(Set|Remove|Rename|New|Reset|Update)-' })) {
            (Get-Command $fn).Parameters.ContainsKey('WhatIf') | Should -BeTrue -Because "$fn changes state"
        }
    }
    It 'does not change anything with -WhatIf' {
        Set-TestState -Current 'alpha' -Environments @((New-TestEnv 'alpha' $T1 $O1))
        ctx set alpha -Description 'changed' -WhatIf
        (Get-TestState).environments[0].description | Should -BeNullOrEmpty
        ctx config pimDefaultHours 3 -WhatIf
        (Get-CtxConfig).pimDefaultHours | Should -Be 4
    }
    It 'writes config.json atomically under the lock' {
        Mock -ModuleName Ctx Invoke-CtxLocked { & $LockedBody }
        try {
            ctx config pimDefaultHours 3
            Should -Invoke Invoke-CtxLocked -ModuleName Ctx -Times 1 -Exactly
            (Get-CtxConfig).pimDefaultHours | Should -Be 3
            Test-Path (Join-Path $testHome 'config.json.tmp') | Should -BeFalse
        } finally { ctx config -Reset }
    }
    It 'does not write state when the lock cannot be acquired' {
        $lockName = InModuleScope Ctx { Get-CtxLockName }
        $ready = [Threading.ManualResetEventSlim]::new($false)
        $release = [Threading.ManualResetEventSlim]::new($false)
        # The mutex is owned by a thread, so another runspace (its own thread) holds it.
        $holder = [powershell]::Create().AddScript({
                param($Name, $Ready, $Release)
                $m = [Threading.Mutex]::new($false, $Name)
                [void]$m.WaitOne()
                $Ready.Set()
                [void]$Release.Wait(10000)
                $m.ReleaseMutex()
                $m.Dispose()
            }).AddArgument($lockName).AddArgument($ready).AddArgument($release)
        $async = $holder.BeginInvoke()
        try {
            $ready.Wait(5000) | Should -BeTrue
            $ran = InModuleScope Ctx {
                $script:ctxLockBodyRan = $false
                try { Invoke-CtxLocked -Timeout ([timespan]::FromMilliseconds(200)) { $script:ctxLockBodyRan = $true } } catch { $_.Exception.Message }
                $script:ctxLockBodyRan
            }
            $ran[0] | Should -BeLike '*locked by another ctx command*'
            $ran[1] | Should -BeFalse
        } finally {
            $release.Set()
            [void]$holder.EndInvoke($async)
            $holder.Dispose()
        }
    }
    It 'parses editors with arguments' {
        $saved = $env:EDITOR
        try {
            $env:EDITOR = 'ctx-no-such-editor --wait'
            InModuleScope Ctx { Get-CtxEditorCommand } | Should -Be @('ctx-no-such-editor', '--wait')
            $env:EDITOR = '"C:\Program Files\No Such\ed.exe" -n'
            InModuleScope Ctx { Get-CtxEditorCommand } | Should -Be @('C:\Program Files\No Such\ed.exe', '-n')
            $env:EDITOR = 'pwsh'
            InModuleScope Ctx { Get-CtxEditorCommand } | Should -Be 'pwsh'
        } finally { $env:EDITOR = $saved }
    }
    It 'doctor checks Az autosave, orphaned Az contexts and unsafe environments' {
        Set-TestState -Current 'alpha' -Environments @(
            (New-TestEnv 'alpha' $T1 $O1 -Tools @('az')),
            @{ name = 'bad'; tenantId = 'x"&calc'; userObjectId = $O2; tools = @('az') }
        )
        Mock -ModuleName Ctx Get-CtxAzCliPath { $null }
        Mock -ModuleName Ctx Test-CtxAzAvailable { $true }
        Mock -ModuleName Ctx Import-CtxAzModule { }
        Mock -ModuleName Ctx Sync-CtxAzProfileFromDisk { }
        Mock -ModuleName Ctx Get-CtxAzAutosaveMode { 'CurrentUser' }
        Mock -ModuleName Ctx Get-CtxAzContextNames { @('ctx:alpha', 'ctx:ghost', 'other') }
        Mock -ModuleName Ctx Get-CtxAzNamedContext { $null }
        $r = Test-CtxSetup -PassThru
        ($r | Where-Object Area -EQ 'Az autosave').Status | Should -Be 'ok'
        @($r | Where-Object Area -EQ 'Orphan Az context').Detail | Should -Be @("ctx:ghost (Remove-AzContext -Name 'ctx:ghost')")
        ($r | Where-Object Area -EQ 'Environment bad').Status | Should -Be 'fail'
        @($r | Where-Object Area -Like 'bad*').Count | Should -Be 0
    }
    It 'does not report the loaded module as tampered' {
        $base = (Get-Module Ctx).ModuleBase
        $r = InModuleScope Ctx -Parameters @{ B = $base } { param($B) Test-CtxModuleSignature -ModuleBase $B }
        $r.Status | Should -Not -Be 'fail' -Because $r.Detail
    }
    It 'keeps an unset LASTEXITCODE unset in the prompt (strict mode)' {
        Set-TestState -Current 'x' -Environments @((New-TestEnv 'x' $T1 $O1))
        $had = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction Ignore
        $saved = if ($had) { $global:LASTEXITCODE } else { $null }
        try {
            Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction Ignore
            { prompt } | Should -Not -Throw
            Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction Ignore | Should -BeNullOrEmpty
            $global:LASTEXITCODE = 7
            $null = prompt
            $global:LASTEXITCODE | Should -Be 7
        } finally { if ($had) { $global:LASTEXITCODE = $saved } else { Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction Ignore } }
    }
}

Describe 'Module signature check' {
    BeforeAll {
        $script:sigDir = Join-Path $testHome 'sigcheck'
        New-Item -ItemType Directory -Path $sigDir -Force | Out-Null
        function Set-SigFiles([hashtable]$Status, [string[]]$WithBlock = @()) {
            foreach ($n in 'Ctx.psm1', 'Ctx.psd1', 'Ctx.Format.ps1xml') {
                $text = if ($WithBlock -contains $n) { "x`n# SIG # Begin signature block`n# abc`n# SIG # End signature block`n# appended" }
                elseif ($WithBlock -contains "quoted:$n") { "    Block = `$text -match '(?m)^# SIG # Begin signature block\r?$'`n    `$y = '# SIG # Begin signature block'" }
                else { 'x' }
                Set-Content -LiteralPath (Join-Path $sigDir $n) -Value $text
            }
            $script:sigStatus = $Status
        }
        Mock -ModuleName Ctx Get-AuthenticodeSignature {
            $s = $sigStatus[(Split-Path $LiteralPath -Leaf)]
            [pscustomobject]@{ Status = $s; StatusMessage = "msg $s"; SignerCertificate = $(if ($s -ne 'NotSigned') { [pscustomobject]@{ Subject = 'CN=ctx test' } }) }
        }
    }
    It 'reports <Expected> for <Case>' -TestCases @(
        @{ Case = 'unsigned files'; Status = @{ 'Ctx.psm1' = 'NotSigned'; 'Ctx.psd1' = 'NotSigned'; 'Ctx.Format.ps1xml' = 'NotSigned' }; Block = @(); Expected = 'info'; Detail = 'not signed*' }
        @{ Case = 'trusted signatures'; Status = @{ 'Ctx.psm1' = 'Valid'; 'Ctx.psd1' = 'Valid'; 'Ctx.Format.ps1xml' = 'Valid' }; Block = @(); Expected = 'ok'; Detail = 'signed by CN=ctx test' }
        @{ Case = 'untrusted signer'; Status = @{ 'Ctx.psm1' = 'UnknownError'; 'Ctx.psd1' = 'UnknownError'; 'Ctx.Format.ps1xml' = 'UnknownError' }; Block = @(); Expected = 'warn'; Detail = 'UnknownError*' }
        @{ Case = 'edited content'; Status = @{ 'Ctx.psm1' = 'HashMismatch'; 'Ctx.psd1' = 'Valid'; 'Ctx.Format.ps1xml' = 'Valid' }; Block = @(); Expected = 'fail'; Detail = 'Ctx.psm1 changed after*' }
        @{ Case = 'text appended after the signature'; Status = @{ 'Ctx.psm1' = 'NotSigned'; 'Ctx.psd1' = 'NotSigned'; 'Ctx.Format.ps1xml' = 'NotSigned' }; Block = @('Ctx.psm1'); Expected = 'fail'; Detail = 'Ctx.psm1 changed after*' }
        @{ Case = 'a stripped signature'; Status = @{ 'Ctx.psm1' = 'NotSigned'; 'Ctx.psd1' = 'Valid'; 'Ctx.Format.ps1xml' = 'Valid' }; Block = @(); Expected = 'fail'; Detail = 'Ctx.psm1 changed after*' }
        @{ Case = 'the marker quoted in unsigned code'; Status = @{ 'Ctx.psm1' = 'NotSigned'; 'Ctx.psd1' = 'NotSigned'; 'Ctx.Format.ps1xml' = 'NotSigned' }; Block = @('quoted:Ctx.psm1'); Expected = 'info'; Detail = 'not signed*' }
    ) {
        param($Case, $Status, $Block, $Expected, $Detail)
        Set-SigFiles -Status $Status -WithBlock $Block
        $r = InModuleScope Ctx -Parameters @{ D = $sigDir } { param($D) Test-CtxModuleSignature -ModuleBase $D }
        $r.Status | Should -Be $Expected
        $r.Detail | Should -BeLike $Detail
    }
}

Describe 'Uninstall safety' {
    It 'refuses to delete a data folder that is protected or holds foreign files' -TestCases @(
        @{ Case = 'foreign' }, @{ Case = 'home' }
    ) {
        param($Case)
        $dir = if ($Case -eq 'home') { $HOME } else {
            $d = Join-Path $testHome "uninstall-$Case"
            New-Item -ItemType Directory -Path (Join-Path $d 'cli') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $d 'config.json') -Value '{}'
            Set-Content -LiteralPath (Join-Path $d 'important.docx') -Value 'x'
            $d
        }
        $script = Join-Path $repoRoot 'Uninstall.ps1'
        $out = pwsh -NoProfile -NonInteractive -Command "`$env:CTX_HOME = '$($dir.Replace("'", "''"))'; `$env:PSModulePath = `$env:PSModulePath -split ';' | Where-Object { `$_ -notmatch 'OneDrive|Documents' } | Join-String -Separator ';'; & '$($script.Replace("'", "''"))' -RemoveData -KeepModule -WhatIf *>&1" | Out-String
        $out | Should -BeLike '*Data folder not deleted*'
        $out | Should -Not -BeLike '*Delete ctx data folder*'
        if ($Case -ne 'home') { Test-Path -LiteralPath (Join-Path $dir 'important.docx') | Should -BeTrue }
    }
}

Describe 'Prompt badge' {
    It 'shows production, PIM time left and Graph' {
        $exp = [datetime]::UtcNow.AddMinutes(95).ToString('yyyy-MM-ddTHH:mm:ssZ')
        Set-TestState -Current 'prodenv' -Environments @(
            (New-TestEnv 'prodenv' $T1 $O1 -Tags @('prod') -Activations @(@{ roleId = '62e90394-69f5-4237-9190-012177145e10'; roleName = 'Global Administrator'; expiresAt = $exp }))
        )
        InModuleScope Ctx { $script:GraphEnvName = 'prodenv' }
        Get-CtxPromptBadge -NoColor | Should -Match '^\[!prodenv:graph GA 1h3[45]m\]$'
        InModuleScope Ctx { $script:GraphEnvName = $null }
    }
    It 'ignores expired activations' {
        $exp = [datetime]::UtcNow.AddMinutes(-5).ToString('yyyy-MM-ddTHH:mm:ssZ')
        Set-TestState -Current 'x' -Environments @((New-TestEnv 'x' $T1 $O1 -Activations @(@{ roleId = 'r'; roleName = 'Global Administrator'; expiresAt = $exp })))
        Get-CtxPromptBadge -NoColor | Should -Be '[x]'
    }
    It 'prefixes the prompt' {
        Set-TestState -Current 'x' -Environments @((New-TestEnv 'x' $T1 $O1))
        (prompt) | Should -Match '^\S*\[\S*x\S*\]'
    }
}
