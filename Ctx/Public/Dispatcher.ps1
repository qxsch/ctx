function Invoke-Ctx {
    <#
    .SYNOPSIS
    ctx - switch between environments (tenant + login) and run the admin routine.
    .DESCRIPTION
    ctx <name>                switch Azure CLI + Az PowerShell (globally) to the environment, where you left off
    ctx <name> -Admin         ... and activate Global Administrator (PIM) + connect Graph with focused Admin scopes
    ctx <name> -Local         switch this terminal only
    ctx                       picker
    ctx -                     previous environment
    ctx <verb> [arguments]    list, add, rm, rename, set, sub, pim, graph, st, sync, exec, portal, doctor,
                              export, import, config, help

    Every verb forwards its parameters to the underlying command (ctx pim -Hours 2 = Invoke-CtxPim -Hours 2), so
    tab completion and Get-Help of the commands apply (Get-Help Invoke-CtxPim -Full).
    .PARAMETER Target
    Environment name (or unique prefix), '-' for the previous environment, or a verb.
    .EXAMPLE
    ctx add switzerland contoso.onmicrosoft.com
    .EXAMPLE
    ctx emea -Admin
    .EXAMPLE
    ctx pim -Hours 2 -Reason "Change 4711"
    .EXAMPLE
    ctx exec all { az account show --query name -o tsv }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Target
    )
    dynamicparam {
        try {
            $route = Get-CtxDispatchRoute $PSBoundParameters['Target']
            New-CtxDynamicParameters -FunctionName $route.Function -Shift $route.Shift -Skip $route.Skip
        } catch {
            Write-Debug "ctx: dynamic parameters failed: $_"
        }
    }
    end {
        $route = Get-CtxDispatchRoute $Target
        $forward = @{}
        foreach ($k in $PSBoundParameters.Keys) {
            if ($k -ne 'Target') { $forward[$k] = $PSBoundParameters[$k] }
        }
        if ($route.IsSwitch -and $Target) { $forward['Name'] = $Target }
        & $route.Function @forward
    }
}

function Get-CtxDispatchRoute {
    param([string]$Target)
    $key = if ($Target) { $Target.ToLowerInvariant() } else { '' }
    if ($key -and $script:CtxVerbs.Contains($key)) {
        return @{ Function = $script:CtxVerbs[$key]; Shift = 1; Skip = @(); IsSwitch = $false }
    }
    @{ Function = 'Switch-CtxEnvironment'; Shift = 0; Skip = @('Name'); IsSwitch = $true }
}

function New-CtxDynamicParameters {
    <# Mirrors the parameters of a ctx command (positions shifted behind the verb). #>
    param([Parameter(Mandatory)][string]$FunctionName, [int]$Shift, [string[]]$Skip)
    $dict = [System.Management.Automation.RuntimeDefinedParameterDictionary]::new()
    $cmd = Get-Command -Name $FunctionName -CommandType Function -ErrorAction Stop
    $common = @([System.Management.Automation.PSCmdlet]::CommonParameters) + @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
    foreach ($p in $cmd.Parameters.Values) {
        if ($p.Name -eq 'Target' -or $Skip -contains $p.Name) { continue }
        if ($common -contains $p.Name -and $p.Name -notin 'WhatIf', 'Confirm') { continue }
        $attrs = [System.Collections.ObjectModel.Collection[Attribute]]::new()
        $hasParameterAttribute = $false
        foreach ($a in $p.Attributes) {
            if ($a -is [System.Management.Automation.ParameterAttribute]) {
                $copy = [System.Management.Automation.ParameterAttribute]::new()
                if ($a.Position -ge 0) { $copy.Position = $a.Position + $Shift }
                if ($a.HelpMessage) { $copy.HelpMessage = $a.HelpMessage }
                $attrs.Add($copy)
                $hasParameterAttribute = $true
            } elseif ($a.GetType().Name -ne 'ArgumentTypeConverterAttribute') {
                $attrs.Add($a)
            }
        }
        if (-not $hasParameterAttribute) { $attrs.Insert(0, [System.Management.Automation.ParameterAttribute]::new()) }
        $dict.Add($p.Name, [System.Management.Automation.RuntimeDefinedParameter]::new($p.Name, $p.ParameterType, $attrs))
    }
    $dict
}
