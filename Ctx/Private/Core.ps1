# Core: paths, persistent state, configuration, locking and name resolution.

$script:CtxVerbs = [ordered]@{
    list    = 'Get-CtxEnvironment'
    ls      = 'Get-CtxEnvironment'
    add     = 'Add-CtxEnvironment'
    new     = 'Add-CtxEnvironment'
    remove  = 'Remove-CtxEnvironment'
    rm      = 'Remove-CtxEnvironment'
    rename  = 'Rename-CtxEnvironment'
    mv      = 'Rename-CtxEnvironment'
    set     = 'Set-CtxEnvironment'
    sub     = 'Select-CtxSubscription'
    pim     = 'Invoke-CtxPim'
    graph   = 'Connect-CtxGraph'
    status  = 'Get-CtxStatus'
    st      = 'Get-CtxStatus'
    sync    = 'Sync-CtxEnvironment'
    exec    = 'Invoke-CtxCommand'
    portal  = 'Open-CtxPortal'
    open    = 'Open-CtxPortal'
    doctor  = 'Test-CtxSetup'
    export  = 'Export-CtxEnvironment'
    import  = 'Import-CtxEnvironment'
    config  = 'Set-CtxConfig'
    help    = 'Get-CtxHelp'
}
$script:CtxReservedNames = @($script:CtxVerbs.Keys) + @('-', 'all', 'none', 'current', 'previous')

$script:CtxDefaultConfig = [ordered]@{
    defaultGraphProfile  = 'Admin'
    askAdminOnSwitch     = $true
    verifyOnSwitch       = $true
    promptBadge          = $true
    pimDefaultRole       = 'Global Administrator'
    pimDefaultHours      = 4
    pimReminderMinutes   = 10
    pimBootstrapScopes   = @('RoleEligibilitySchedule.Read.Directory', 'RoleAssignmentSchedule.ReadWrite.Directory')
    deviceCodeClipboard  = $true
    deviceCodeBrowser    = $true
    browserPath          = ''
    prodTags             = @('prod', 'production')
    shareCliExtensions   = $true
    graphMaxSessionHours = 8
    graphScopeProfiles   = [ordered]@{}
}

# Environment fields that 'ctx export' writes and 'ctx import' accepts (everything else is device-local).
$script:CtxPortableKeys = @(
    'name', 'tenantId', 'tenantName', 'tenantDomain', 'userObjectId', 'upn', 'tools', 'tags', 'color', 'description',
    'graphProfile', 'graphClientId', 'adminOnSwitch', 'pim', 'azSubscriptionId', 'azSubscriptionName', 'cliSubscriptionId', 'cliSubscriptionName'
)
# Free-text fields that are printed to the terminal.
$script:CtxDisplayKeys = @('tenantName', 'tenantDomain', 'upn', 'description', 'azSubscriptionName', 'cliSubscriptionName', 'graphProfile')
$script:CtxGuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$script:CtxDomainPattern = '^(?=.{1,253}$)(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'

# Per-process (per terminal) runtime state.
$script:ProcessEnvName = $null
$script:ProcessPreviousName = $null
$script:ProcessLocal = $false
$script:GraphEnvName = $null
$script:GraphProfileName = $null
$script:GraphToken = $null
$script:GraphRenewalTimer = $null
$script:GraphSaveWarned = $false
$script:StateCacheStamp = $null
$script:ConfigCache = $null
$script:ConfigCacheStamp = $null
$script:Quiet = $false

function Get-CtxHome {
    $dir = if ($env:CTX_HOME) { $env:CTX_HOME } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ctx' }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $dir
}

function Get-CtxOneDriveRoot {
    <# Returns the OneDrive root that contains $Path, or $null when the path is not synced by OneDrive. #>
    param([string]$Path)
    if (-not $Path) { return $null }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
    foreach ($root in @($env:OneDriveCommercial, $env:OneDriveConsumer, $env:OneDrive) | Where-Object { $_ } | Select-Object -Unique) {
        if ($full.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $root }
    }
    $null
}

function Get-CtxStatePath { Join-Path (Get-CtxHome) 'environments.json' }
function Get-CtxConfigPath { Join-Path (Get-CtxHome) 'config.json' }

# User-wide environment variables (HKCU\Environment). $env:CTX_SANDBOX_USERENV redirects them to a JSON file
# so tests and dry runs never touch the real user environment.
function Get-CtxUserEnv {
    param([Parameter(Mandatory)][string]$Name)
    if ($env:CTX_SANDBOX_USERENV) {
        if (-not (Test-Path -LiteralPath $env:CTX_SANDBOX_USERENV)) { return $null }
        $data = [IO.File]::ReadAllText($env:CTX_SANDBOX_USERENV) | ConvertFrom-Json -AsHashtable
        return $(if ($data -and $data.ContainsKey($Name)) { $data[$Name] } else { $null })
    }
    [Environment]::GetEnvironmentVariable($Name, 'User')
}

function Set-CtxUserEnv {
    param([Parameter(Mandatory)][string]$Name, [AllowNull()][AllowEmptyString()][string]$Value)
    if (-not $Value) { $Value = $null }
    if ($env:CTX_SANDBOX_USERENV) {
        $data = if (Test-Path -LiteralPath $env:CTX_SANDBOX_USERENV) { [IO.File]::ReadAllText($env:CTX_SANDBOX_USERENV) | ConvertFrom-Json -AsHashtable } else { $null }
        if (-not $data) { $data = @{} }
        if ($null -eq $Value) { $data.Remove($Name) } else { $data[$Name] = $Value }
        [IO.File]::WriteAllText($env:CTX_SANDBOX_USERENV, ($data | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        return
    }
    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
}

function ConvertTo-CtxDate {
    param($Value)
    if ($null -eq $Value -or '' -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    [datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
}

function ConvertTo-CtxIsoDate {
    param([datetime]$Value)
    $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
}

function Test-CtxGuid {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    [bool]($Value -match $script:CtxGuidPattern)
}

function Test-CtxDomainName {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    [bool]($Value -match $script:CtxDomainPattern)
}

function Test-CtxTenantSpec {
    <# A tenant is a GUID or a DNS domain (contoso.onmicrosoft.com). #>
    param([AllowNull()][AllowEmptyString()][string]$Value)
    (Test-CtxGuid $Value) -or (Test-CtxDomainName $Value)
}

function ConvertTo-CtxSafeText {
    <# Strips control characters (ANSI/OSC escape sequences, newlines) and bidi overrides from text shown in the terminal. #>
    param([AllowNull()]$Value, [int]$MaxLength = 0)
    if ($null -eq $Value) { return $null }
    $text = [regex]::Replace([string]$Value, '[\p{Cc}\u200E\u200F\u202A-\u202E\u2066-\u2069]', '')
    if ($MaxLength -gt 0 -and $text.Length -gt $MaxLength) { $text = $text.Substring(0, $MaxLength - 1) + '…' }
    $text
}

function Get-CtxEntryProblem {
    <# Returns why an environment definition is unsafe to use (IDs reach az.cmd, URLs and the browser command line). #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Entry)
    $show = { param($v) ConvertTo-CtxSafeText $v -MaxLength 60 }
    foreach ($k in 'tenantId', 'userObjectId') {
        if (-not (Test-CtxGuid ([string]$Entry[$k]))) { "$k '$(& $show $Entry[$k])' is not a GUID" }
    }
    foreach ($k in 'graphClientId', 'azSubscriptionId', 'cliSubscriptionId') {
        if ($Entry[$k] -and -not (Test-CtxGuid ([string]$Entry[$k]))) { "$k '$(& $show $Entry[$k])' is not a GUID" }
    }
    if ($Entry['tenantDomain'] -and -not (Test-CtxDomainName ([string]$Entry['tenantDomain']))) {
        "tenantDomain '$(& $show $Entry['tenantDomain'])' is not a domain name"
    }
}

function Write-CtxFileAtomic {
    <# Writes UTF-8 (no BOM) via a temp file and an atomic replace, so readers never see a half-written file. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Content, [switch]$Backup)
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, $Content, [Text.UTF8Encoding]::new($false))
    if ($Backup -and (Test-Path -LiteralPath $Path)) {
        [IO.File]::Replace($tmp, $Path, "$Path.bak")
    } else {
        [IO.File]::Move($tmp, $Path, $true)
    }
}

function New-CtxState {
    [ordered]@{
        version      = 1
        current      = $null
        previous     = $null
        original     = [ordered]@{ saved = $false; azureConfigDir = $null; azureExtensionDir = $null; managedExtensionDir = $false }
        environments = [System.Collections.Generic.List[object]]::new()
    }
}

function ConvertTo-CtxList {
    param($Value)
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($v in @($Value)) { if ($null -ne $v) { $list.Add($v) } }
    , $list
}

function Repair-CtxEnvironmentEntry {
    param([System.Collections.IDictionary]$Entry)
    foreach ($k in 'tags', 'tools') {
        $Entry[$k] = @(@($Entry[$k]) | Where-Object { $_ } | ForEach-Object { ConvertTo-CtxSafeText ([string]$_) } | Where-Object { $_ })
    }
    $Entry['tools'] = @($Entry['tools'] | ForEach-Object { $_.ToLowerInvariant() } | Where-Object { $_ -in 'cli', 'az' } | Select-Object -Unique)
    if (-not $Entry['tools'] -or $Entry['tools'].Count -eq 0) { $Entry['tools'] = @('cli', 'az') }
    foreach ($k in $script:CtxDisplayKeys) {
        if ($null -ne $Entry[$k]) { $Entry[$k] = ConvertTo-CtxSafeText $Entry[$k] }
    }
    $Entry['activations'] = ConvertTo-CtxList $Entry['activations']
    if ([string]$Entry['graphProfile'] -ieq 'All' -and (Test-CtxRemovedGraphProfile 'All' (Get-CtxConfig).graphScopeProfiles)) {
        $Entry['graphProfile'] = $null
    }
    if ($Entry['pim'] -isnot [System.Collections.IDictionary]) { $Entry['pim'] = [ordered]@{} }
    $Entry['saveGraphCredentials'] = ($Entry['saveGraphCredentials'] -eq $true)
    foreach ($k in 'role', 'reason', 'ticketSystem') {
        if ($null -ne $Entry['pim'][$k]) { $Entry['pim'][$k] = ConvertTo-CtxSafeText $Entry['pim'][$k] }
    }
    if (-not $Entry['browserProfile']) { $Entry['browserProfile'] = "ctx-$($Entry['name'])" }
    if (-not $Entry['azContextName']) { $Entry['azContextName'] = "ctx:$($Entry['name'])" }
    $Entry
}

function Read-CtxState {
    $path = Get-CtxStatePath
    if (-not (Test-Path -LiteralPath $path)) { return New-CtxState }
    $raw = [IO.File]::ReadAllText($path)
    if (-not $raw.Trim()) { return New-CtxState }
    try {
        $data = $raw | ConvertFrom-Json -AsHashtable -Depth 32
    } catch {
        throw "ctx state file '$path' is corrupt ($($_.Exception.Message)). A backup may exist at '$path.bak'."
    }
    $state = New-CtxState
    foreach ($k in @($data.Keys)) {
        if ($k -ne 'environments' -and $k -ne 'original') { $state[$k] = $data[$k] }
    }
    if ($data['original']) { foreach ($k in @($data['original'].Keys)) { $state.original[$k] = $data['original'][$k] } }
    foreach ($e in @($data['environments'])) {
        if ($e -and $e['name']) { $state.environments.Add((Repair-CtxEnvironmentEntry $e)) }
    }
    $state
}

function Save-CtxState {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)
    Write-CtxFileAtomic -Path (Get-CtxStatePath) -Content ($State | ConvertTo-Json -Depth 32) -Backup
    $script:StateCache = $null
}

function Get-CtxLockName {
    "Local\ctx-state-$([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)"
}

function Invoke-CtxLocked {
    <# Runs the body under the per-user ctx mutex (state and config writes). Throws when the lock cannot be acquired. #>
    param([Parameter(Mandatory)][scriptblock]$LockedBody, [timespan]$Timeout = [timespan]::FromSeconds(15))
    $mutex = [Threading.Mutex]::new($false, (Get-CtxLockName))
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne($Timeout) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) {
            throw "ctx data is locked by another ctx command (waited $([int]$Timeout.TotalSeconds) s). Try again when it has finished."
        }
        & $LockedBody
    } finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Update-CtxState {
    <# Read-modify-write the state file under a per-user mutex. The mutation receives the state hashtable. #>
    param([Parameter(Mandatory)][scriptblock]$Mutation)
    Invoke-CtxLocked {
        $locked = Read-CtxState
        $null = & $Mutation $locked
        Save-CtxState $locked
        $locked
    }
}

function Get-CtxStateCached {
    <# Cheap state read for the prompt: only re-reads the file when it changed. #>
    $path = Get-CtxStatePath
    $stamp = if (Test-Path -LiteralPath $path) { [IO.File]::GetLastWriteTimeUtc($path) } else { [datetime]::MinValue }
    if ($null -eq $script:StateCache -or $script:StateCacheStamp -ne $stamp) {
        $script:StateCache = Read-CtxState
        $script:StateCacheStamp = $stamp
    }
    $script:StateCache
}

function Get-CtxConfig {
    <#
    .SYNOPSIS
    Returns the effective ctx configuration (defaults merged with config.json).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    $path = Get-CtxConfigPath
    $stamp = if (Test-Path -LiteralPath $path) { [IO.File]::GetLastWriteTimeUtc($path) } else { [datetime]::MinValue }
    if ($null -ne $script:ConfigCache -and $script:ConfigCacheStamp -eq $stamp) { return $script:ConfigCache }
    $cfg = [ordered]@{}
    foreach ($k in $script:CtxDefaultConfig.Keys) { $cfg[$k] = $script:CtxDefaultConfig[$k] }
    if (Test-Path -LiteralPath $path) {
        try {
            $data = [IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable -Depth 16
            # Known settings only: removed settings (e.g. fallbackGraphProfile) in older files are ignored.
            foreach ($k in @($data.Keys)) { if ($script:CtxDefaultConfig.Contains($k)) { $cfg[$k] = $data[$k] } }
        } catch {
            Write-Warning "ctx: ignoring invalid config file '$path': $($_.Exception.Message)"
        }
    }
    if (Test-CtxRemovedGraphProfile ([string]$cfg.defaultGraphProfile) $cfg.graphScopeProfiles) {
        $cfg.defaultGraphProfile = $script:CtxDefaultConfig.defaultGraphProfile
    }
    $script:ConfigCache = $cfg
    $script:ConfigCacheStamp = $stamp
    $cfg
}

function Read-CtxConfigOverrides {
    <# The user's overrides from config.json (not merged with defaults). #>
    $path = Get-CtxConfigPath
    if (-not (Test-Path -LiteralPath $path)) { return [ordered]@{} }
    $raw = [IO.File]::ReadAllText($path)
    if (-not $raw.Trim()) { return [ordered]@{} }
    $data = $raw | ConvertFrom-Json -AsHashtable -Depth 16
    if ($data -isnot [System.Collections.IDictionary]) { throw "Config file '$path' does not contain a JSON object." }
    $data
}

function Save-CtxConfigOverrides {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Overrides)
    Write-CtxFileAtomic -Path (Get-CtxConfigPath) -Content ($Overrides | ConvertTo-Json -Depth 16)
    $script:ConfigCache = $null
}

function Assert-CtxName {
    <# Validates and normalizes an environment name. #>
    param([Parameter(Mandatory)][string]$Name)
    $n = $Name.Trim().ToLowerInvariant()
    if ($n -notmatch '^[a-z0-9][a-z0-9-]{0,31}$') {
        throw "Invalid environment name '$Name'. Use 1-32 chars: a-z, 0-9 and '-' (e.g. switzerland, emea3)."
    }
    if ($script:CtxReservedNames -contains $n) {
        throw "'$n' is reserved (it is a ctx command). Choose another name."
    }
    $n
}

function Find-CtxEnvironment {
    param([Parameter(Mandatory)]$State, [string]$Name)
    if (-not $Name) { return $null }
    foreach ($e in $State.environments) { if ($e.name -ieq $Name) { return $e } }
    $null
}

function Find-CtxEnvironmentByIdentity {
    param([Parameter(Mandatory)]$State, [string]$TenantId, [string]$ObjectId)
    foreach ($e in $State.environments) {
        if ($e.tenantId -ieq $TenantId -and $e.userObjectId -ieq $ObjectId) { return $e }
    }
    $null
}

function Resolve-CtxEnvironment {
    <# Exact name, else unique prefix. Throws with suggestions. #>
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Name)
    $exact = Find-CtxEnvironment $State $Name
    if ($exact) { return $exact }
    $prefix = @($State.environments | Where-Object { $_.name.StartsWith($Name, [StringComparison]::OrdinalIgnoreCase) })
    if ($prefix.Count -eq 1) { return $prefix[0] }
    if ($prefix.Count -gt 1) {
        throw "'$Name' is ambiguous: $(($prefix | ForEach-Object name) -join ', ')."
    }
    $similar = @($State.environments | Where-Object { $_.name -like "*$Name*" -or $Name -like "*$($_.name)*" } | ForEach-Object name)
    $hint = if ($similar) { " Did you mean: $($similar -join ', ')?" } elseif ($State.environments.Count) { " Known: $(($State.environments | ForEach-Object name) -join ', ')." } else { '' }
    throw "Unknown environment '$Name'.$hint Use 'ctx add $Name' to create it."
}

function Get-CtxProcessEnvironment {
    <# The environment this terminal is switched to. #>
    param([switch]$Optional)
    $state = Read-CtxState
    $name = if ($script:ProcessEnvName) { $script:ProcessEnvName } else { $state.current }
    $entry = Find-CtxEnvironment $state $name
    if (-not $entry -and -not $Optional) { throw "No environment selected. Run 'ctx' to pick one or 'ctx add <name>'." }
    $entry
}

function Test-CtxProd {
    param($Entry)
    if (-not $Entry) { return $false }
    $prodTags = @((Get-CtxConfig).prodTags)
    foreach ($t in @($Entry.tags)) { if ($prodTags -contains $t) { return $true } }
    $false
}

function Test-CtxTool {
    param($Entry, [ValidateSet('cli', 'az')][string]$Tool)
    @($Entry.tools) -contains $Tool
}

function Get-CtxActiveActivations {
    <# Cached PIM activations that are still running. #>
    param($Entry)
    $now = [datetime]::UtcNow
    foreach ($a in @($Entry.activations)) {
        if (-not $a) { continue }
        $end = ConvertTo-CtxDate $a.expiresAt
        if ($null -eq $end -or $end -gt $now) {
            [pscustomobject]@{
                RoleId    = $a.roleId
                RoleName  = $a.roleName
                ExpiresAt = $end
                Remaining = if ($end) { $end - $now } else { $null }
            }
        }
    }
}

function Set-CtxActivationCache {
    param([Parameter(Mandatory)][string]$Name, [object[]]$Active)
    $null = Update-CtxState {
        param($s)
        $e = Find-CtxEnvironment $s $Name
        if (-not $e) { return }
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($a in @($Active)) {
            if (-not $a) { continue }
            $list.Add([ordered]@{
                roleId    = $a.RoleId
                roleName  = $a.RoleName
                expiresAt = if ($a.End) { ConvertTo-CtxIsoDate $a.End } else { $null }
                type      = $a.AssignmentType
            })
        }
        $e.activations = $list
        $e.activationsCheckedAt = ConvertTo-CtxIsoDate ([datetime]::UtcNow)
    }
}
