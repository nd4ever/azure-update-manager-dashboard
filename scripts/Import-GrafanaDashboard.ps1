#!/usr/bin/env pwsh
# Copyright (c) 2026 nd4ever
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

<#
.SYNOPSIS
    Imports the Azure Update Manager dashboard into Azure Managed Grafana.
.DESCRIPTION
    Resolves the Log Analytics workspace customer ID, substitutes deployment
    placeholders in the checked-in dashboard, imports it idempotently, and
    verifies the dashboard by its stable UID.
.PARAMETER GrafanaName
    Name of the target Azure Managed Grafana workspace.
.PARAMETER GrafanaResourceGroupName
    Resource group containing the target Azure Managed Grafana workspace.
.PARAMETER LogAnalyticsWorkspaceResourceId
    Full Azure resource ID of the Log Analytics workspace queried by the dashboard.
.PARAMETER GrafanaSubscriptionId
    Subscription containing the target Azure Managed Grafana workspace. Defaults
    to the active Azure CLI subscription.
.PARAMETER DashboardPath
    Path to the source dashboard JSON file.
.EXAMPLE
    ./scripts/Import-GrafanaDashboard.ps1 `
      -GrafanaName amg-aum-dashboard `
      -GrafanaResourceGroupName rg-monitoring `
      -LogAnalyticsWorkspaceResourceId /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-monitoring/providers/Microsoft.OperationalInsights/workspaces/law-management
.NOTES
    Requires Azure CLI, the amg extension, Grafana Admin, and access to read the
    Log Analytics workspace.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GrafanaName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GrafanaResourceGroupName,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$')]
    [string]$LogAnalyticsWorkspaceResourceId,

    [Parameter(Mandatory = $false)]
    [string]$GrafanaSubscriptionId,

    [Parameter(Mandatory = $false)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$DashboardPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'grafana/azure-update-manager.dashboard.json')
)

$ErrorActionPreference = 'Stop'

#region Functions

function Invoke-AzureCliTsv {
    <#
    .SYNOPSIS
        Invokes Azure CLI and returns one trimmed text value.
    .PARAMETER Arguments
        Arguments passed to the Azure CLI executable.
    .OUTPUTS
        [string] The trimmed command output.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Arguments
    )

    $Output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: $($Output -join [Environment]::NewLine)"
    }

    return ($Output | Select-Object -Last 1).Trim()
}

function Resolve-GrafanaDashboard {
    <#
    .SYNOPSIS
        Resolves deployment placeholders into a temporary dashboard file.
    .PARAMETER SourcePath
        Path to the checked-in dashboard JSON.
    .PARAMETER SubscriptionId
        Subscription containing the Log Analytics workspace.
    .PARAMETER WorkspaceResourceId
        Full Azure resource ID of the Log Analytics workspace.
    .PARAMETER AzureMonitorDatasourceUid
        UID of the Azure Monitor data source in the target Grafana workspace.
    .OUTPUTS
        [hashtable] The temporary path and dashboard UID.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$WorkspaceResourceId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$AzureMonitorDatasourceUid
    )

    $SourceContent = Get-Content -Raw -LiteralPath $SourcePath
    foreach ($placeholder in @('__AZURE_SUBSCRIPTION_ID__', '__LOG_ANALYTICS_WORKSPACE_RESOURCE_ID__', '__AZURE_MONITOR_DATASOURCE_UID__')) {
        if ($SourceContent -notmatch $placeholder) {
            throw "The dashboard source is missing required placeholder $placeholder."
        }
    }

    $ResolvedContent = $SourceContent.
        Replace('__AZURE_SUBSCRIPTION_ID__', $SubscriptionId).
        Replace('__LOG_ANALYTICS_WORKSPACE_RESOURCE_ID__', $WorkspaceResourceId).
        Replace('__AZURE_MONITOR_DATASOURCE_UID__', $AzureMonitorDatasourceUid)
    $Dashboard = $ResolvedContent | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($Dashboard.uid)) {
        throw 'The dashboard must define a stable uid for idempotent imports.'
    }

    $TemporaryPath = Join-Path ([System.IO.Path]::GetTempPath()) "aum-grafana-$([guid]::NewGuid().ToString('N')).json"
    Set-Content -LiteralPath $TemporaryPath -Value $ResolvedContent -Encoding utf8NoBOM

    return @{
        Path = $TemporaryPath
        Uid  = $Dashboard.uid
    }
}

#endregion Functions

#region Main Execution

if ($MyInvocation.InvocationName -ne '.') {
    $ResolvedDashboard = $null

    try {
        if ($null -eq (Get-Command az -ErrorAction SilentlyContinue)) {
            throw 'Azure CLI is required but was not found on PATH.'
        }

        $null = & az extension show --name amg --only-show-errors 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw 'The Azure CLI amg extension is required. Install it with: az extension add --name amg'
        }

        if ([string]::IsNullOrWhiteSpace($GrafanaSubscriptionId)) {
            $GrafanaSubscriptionId = Invoke-AzureCliTsv -Arguments @(
                'account', 'show',
                '--query', 'id',
                '--output', 'tsv',
                '--only-show-errors'
            )
        }

        $WorkspaceSubscriptionId = ($LogAnalyticsWorkspaceResourceId -split '/')[2]

        $AzureMonitorDatasourceUid = Invoke-AzureCliTsv -Arguments @(
            'grafana', 'data-source', 'list',
            '--name', $GrafanaName,
            '--resource-group', $GrafanaResourceGroupName,
            '--subscription', $GrafanaSubscriptionId,
            '--query', "sort_by([?type=='grafana-azure-monitor-datasource'], &name)[?isDefault]|[0].uid",
            '--output', 'tsv',
            '--only-show-errors'
        )
        if ([string]::IsNullOrWhiteSpace($AzureMonitorDatasourceUid)) {
            $AzureMonitorDatasourceUid = Invoke-AzureCliTsv -Arguments @(
                'grafana', 'data-source', 'list',
                '--name', $GrafanaName,
                '--resource-group', $GrafanaResourceGroupName,
                '--subscription', $GrafanaSubscriptionId,
                '--query', "sort_by([?type=='grafana-azure-monitor-datasource'], &name)[0].uid",
                '--output', 'tsv',
                '--only-show-errors'
            )
        }
        if ([string]::IsNullOrWhiteSpace($AzureMonitorDatasourceUid)) {
            throw "No Azure Monitor data source was found in Grafana workspace '$GrafanaName'."
        }

        $ResolvedDashboard = Resolve-GrafanaDashboard `
            -SourcePath $DashboardPath `
            -SubscriptionId $WorkspaceSubscriptionId `
            -WorkspaceResourceId $LogAnalyticsWorkspaceResourceId `
            -AzureMonitorDatasourceUid $AzureMonitorDatasourceUid

        & az grafana dashboard import `
            --name $GrafanaName `
            --resource-group $GrafanaResourceGroupName `
            --subscription $GrafanaSubscriptionId `
            --definition $ResolvedDashboard.Path `
            --overwrite true `
            --only-show-errors `
            --output none
        if ($LASTEXITCODE -ne 0) {
            throw "Dashboard import failed for Azure Managed Grafana workspace '$GrafanaName'."
        }

        & az grafana dashboard show `
            --name $GrafanaName `
            --resource-group $GrafanaResourceGroupName `
            --subscription $GrafanaSubscriptionId `
            --dashboard $ResolvedDashboard.Uid `
            --only-show-errors `
            --output none
        if ($LASTEXITCODE -ne 0) {
            throw "Dashboard verification failed for UID '$($ResolvedDashboard.Uid)'."
        }

        $GrafanaEndpoint = Invoke-AzureCliTsv -Arguments @(
            'grafana', 'show',
            '--name', $GrafanaName,
            '--resource-group', $GrafanaResourceGroupName,
            '--subscription', $GrafanaSubscriptionId,
            '--query', 'properties.endpoint',
            '--output', 'tsv',
            '--only-show-errors'
        )

        Write-Output "Imported dashboard '$($ResolvedDashboard.Uid)' into $GrafanaEndpoint."
        exit 0
    }
    catch {
        Write-Error -ErrorAction Continue "Grafana dashboard import failed: $($_.Exception.Message)"
        exit 1
    }
    finally {
        if ($null -ne $ResolvedDashboard -and (Test-Path -LiteralPath $ResolvedDashboard.Path)) {
            Remove-Item -LiteralPath $ResolvedDashboard.Path -Force
        }
    }
}

#endregion Main Execution
