# PIM for Entra roles via Microsoft Graph (roleManagement/directory).

$script:CtxRoles = [ordered]@{
    'Global Administrator'                    = '62e90394-69f5-4237-9190-012177145e10'
    'Privileged Role Administrator'           = 'e8611ab8-c189-46e8-94e1-60213ab1f814'
    'Privileged Authentication Administrator' = '7be44c8a-adaf-4e2a-84d6-ab2649e08a13'
    'Global Reader'                           = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'
    'Security Administrator'                  = '194ae4cb-b126-40b2-bd5b-6091b380977d'
    'Security Reader'                         = '5d6b6bb7-de71-4623-b4af-96380a352509'
    'Conditional Access Administrator'        = 'b1be1c3e-b65d-4f19-8427-f6fa0d97feb9'
    'Authentication Administrator'            = 'c4e39bd9-1100-46d3-8c65-fb160da0071f'
    'User Administrator'                      = 'fe930be7-5e62-47db-91af-98c3a49a38b1'
    'Groups Administrator'                    = 'fdd7a751-b60b-444a-984c-02652fe8fa1c'
    'Helpdesk Administrator'                  = '729827e3-9c14-49f7-bb1b-9608f156bbb8'
    'Application Administrator'               = '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3'
    'Cloud Application Administrator'         = '158c047a-c907-4556-b7ef-446551a6b5f7'
    'Exchange Administrator'                  = '29232cdf-9323-42fd-ade2-1d097af3e4de'
    'SharePoint Administrator'                = 'f28a1f50-f6e7-4571-818b-6a12f2af6b6c'
    'Teams Administrator'                     = '69091246-20e8-4a56-aa4d-066075b2a7a8'
    'Intune Administrator'                    = '3a2c62db-5318-420d-8d74-23affee5d9d5'
    'Billing Administrator'                   = 'b0f54661-2d74-4c50-afa3-1ec803f12efe'
    'Compliance Administrator'                = '17315797-102d-40b4-93e0-432062caca18'
}
$script:CtxRoleAliases = @{
    ga = 'Global Administrator'; globaladmin = 'Global Administrator'; admin = 'Global Administrator'
    pra = 'Privileged Role Administrator'; paa = 'Privileged Authentication Administrator'
    reader = 'Global Reader'; gr = 'Global Reader'
    security = 'Security Administrator'; secreader = 'Security Reader'
    ca = 'Conditional Access Administrator'; auth = 'Authentication Administrator'
    user = 'User Administrator'; groups = 'Groups Administrator'; helpdesk = 'Helpdesk Administrator'
    app = 'Application Administrator'; cloudapp = 'Cloud Application Administrator'
    exchange = 'Exchange Administrator'; sharepoint = 'SharePoint Administrator'; teams = 'Teams Administrator'
    intune = 'Intune Administrator'; billing = 'Billing Administrator'; compliance = 'Compliance Administrator'
}

function Get-CtxRoleShortName {
    param([string]$RoleName)
    if ($RoleName -eq 'Global Administrator') { return 'GA' }
    if (-not $RoleName) { return 'role' }
    if ($RoleName -match '^[0-9a-f-]{36}$') { return 'role' }
    (($RoleName -split '\s+' | Where-Object { $_ } | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() }) -join '')
}

function Resolve-CtxRole {
    <# Returns @{ Id; Name } for a role name, alias or GUID. Id is $null when it must be resolved online. #>
    param([Parameter(Mandatory)][string]$Role)
    $r = $Role.Trim()
    if ($r -match '^[0-9a-fA-F-]{36}$') {
        $name = $script:CtxRoles.Keys | Where-Object { $script:CtxRoles[$_] -ieq $r } | Select-Object -First 1
        return [pscustomobject]@{ Id = $r.ToLowerInvariant(); Name = $(if ($name) { $name } else { $r }) }
    }
    $alias = $script:CtxRoleAliases[$r.ToLowerInvariant()]
    if ($alias) { $r = $alias }
    foreach ($k in $script:CtxRoles.Keys) {
        if ($k -ieq $r) { return [pscustomobject]@{ Id = $script:CtxRoles[$k]; Name = $k } }
    }
    [pscustomobject]@{ Id = $null; Name = $r }
}

function ConvertTo-CtxRoleInstance {
    param($Item)
    $roleId = [string]$Item.roleDefinitionId
    $name = if ($Item.roleDefinition -and $Item.roleDefinition.displayName) { $Item.roleDefinition.displayName }
    else { (Resolve-CtxRole $roleId).Name }
    [pscustomobject]@{
        RoleId         = $roleId
        RoleName       = $name
        Scope          = $Item.directoryScopeId
        Start          = ConvertTo-CtxDate $Item.startDateTime
        End            = ConvertTo-CtxDate $Item.endDateTime
        AssignmentType = $Item.assignmentType
        MemberType     = $Item.memberType
    }
}

function Invoke-CtxGraphListFallback {
    param([Parameter(Mandatory)][string[]]$Uris)
    $lastError = $null
    foreach ($u in $Uris) {
        try { return , @(Invoke-CtxGraphList $u) } catch { $lastError = $_ }
    }
    throw $lastError
}

function Get-CtxPimEligibleRoles {
    param([Parameter(Mandatory)]$Entry)
    $base = 'v1.0/roleManagement/directory/roleEligibilityScheduleInstances'
    $items = Invoke-CtxGraphListFallback @(
        "$base/filterByCurrentUser(on='principal')?`$expand=roleDefinition"
        "$base/filterByCurrentUser(on='principal')"
        "$base`?`$filter=principalId eq '$($Entry.userObjectId)'"
    )
    @($items | ForEach-Object { ConvertTo-CtxRoleInstance $_ } | Where-Object { $_.Scope -eq '/' -or -not $_.Scope })
}

function Get-CtxPimActiveRoles {
    param([Parameter(Mandatory)]$Entry)
    $base = 'v1.0/roleManagement/directory/roleAssignmentScheduleInstances'
    $items = Invoke-CtxGraphListFallback @(
        "$base/filterByCurrentUser(on='principal')?`$expand=roleDefinition"
        "$base/filterByCurrentUser(on='principal')"
        "$base`?`$filter=principalId eq '$($Entry.userObjectId)'"
    )
    $now = [datetime]::UtcNow
    @($items | ForEach-Object { ConvertTo-CtxRoleInstance $_ } |
        Where-Object { ($_.Scope -eq '/' -or -not $_.Scope) -and ($null -eq $_.End -or $_.End -gt $now) })
}

function New-CtxPimRequest {
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$RoleId,
        [Parameter(Mandatory)][ValidateSet('selfActivate', 'selfDeactivate')][string]$Action,
        [timespan]$Duration = [timespan]::FromHours(1),
        [string]$Reason,
        [string]$Ticket,
        [string]$TicketSystem
    )
    $body = [ordered]@{
        action           = $Action
        principalId      = $Entry.userObjectId
        roleDefinitionId = $RoleId
        directoryScopeId = '/'
    }
    if ($Reason) { $body.justification = $Reason }
    if ($Action -eq 'selfActivate') {
        $body.scheduleInfo = [ordered]@{
            startDateTime = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
            expiration    = [ordered]@{ type = 'afterDuration'; duration = [Xml.XmlConvert]::ToString($Duration) }
        }
        if ($Ticket) { $body.ticketInfo = [ordered]@{ ticketNumber = $Ticket; ticketSystem = $TicketSystem } }
    }
    Invoke-MgGraphRequest -Method POST -Uri 'v1.0/roleManagement/directory/roleAssignmentScheduleRequests' `
        -Body ($body | ConvertTo-Json -Depth 6) -ContentType 'application/json' -ErrorAction Stop
}

function Get-CtxPimErrorKind {
    <# Classifies PIM request failures so the caller can ask for exactly what the policy needs. #>
    param([string]$Message)
    switch -Regex ($Message) {
        'ActiveDurationTooShort' { return 'TooShort' }
        'RoleAssignmentExists|already exists' { return 'Exists' }
        'ExpirationRule|Expiration' { return 'Expiration' }
        'JustificationRule' { return 'Justification' }
        'TicketingRule' { return 'Ticket' }
        'MfaRule|MultiFactorAuthentication|AcrsValidation|AuthenticationContext|claims|InteractionRequired' { return 'Mfa' }
        'RoleAssignmentDoesNotExist|RoleAssignmentRequestDoesNotExist|not active' { return 'NotActive' }
        'RoleEligibilityScheduleNotFound|not eligible|NoEligib' { return 'NotEligible' }
        'Authorization_RequestDenied|Forbidden|403' { return 'Forbidden' }
    }
    'Other'
}

function Get-CtxGraphErrorText {
    param($ErrorRecord)
    $parts = @()
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { $parts += $ErrorRecord.ErrorDetails.Message }
    if ($ErrorRecord.Exception) { $parts += $ErrorRecord.Exception.Message }
    ($parts -join ' ') -replace '\s+', ' '
}

function Wait-CtxPimActive {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$RoleId, [int]$TimeoutSeconds = 180)
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    Write-Host '    waiting for activation ' -NoNewline -ForegroundColor DarkGray
    try {
        while ([datetime]::UtcNow -lt $deadline) {
            $hit = @(Get-CtxPimActiveRoles $Entry | Where-Object { $_.RoleId -ieq $RoleId })
            if ($hit.Count) { return $hit[0] }
            Write-Host '.' -NoNewline -ForegroundColor DarkGray
            Start-Sleep -Seconds 5
        }
        $null
    } finally {
        Write-Host ''
    }
}

function Use-CtxPimGraph {
    <# Include the final profile in the first sign-in so PIM does not require a second device code. #>
    param([Parameter(Mandatory)]$Entry, [string]$GraphProfile)
    $scopes = Get-CtxGraphScopes 'Pim'
    if (Test-CtxGraphSession -Entry $Entry -RequiredScopes $scopes) { return }
    $label = 'Pim'
    if ($GraphProfile) {
        $profileScopes = @(Get-CtxGraphScopes $GraphProfile)
        $label = if (@(Get-CtxMissingGraphScopes -Granted $profileScopes -Required $scopes).Count) { "$GraphProfile + Pim" } else { $GraphProfile }
        $scopes = @($profileScopes + $scopes | Select-Object -Unique)
    }
    Write-CtxMsg step "Preparing Microsoft Graph for PIM · $label ($($scopes.Count) scopes)"
    Connect-CtxGraphSession -Entry $Entry -Scopes $scopes -Label $label | Out-Null
}
