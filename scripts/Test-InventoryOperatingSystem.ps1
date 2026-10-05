[CmdletBinding()]
param(
    [string]$TemplatePath = (Join-Path $PSScriptRoot '..\infra\main.json')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$workbookSource = Get-Content -Raw (Join-Path $root 'workbook\azure-update-manager.workbook.json')
$workbook = $workbookSource | ConvertFrom-Json
$grafana = Get-Content -Raw (Join-Path $root 'grafana\azure-update-manager.dashboard.json') | ConvertFrom-Json
$workbookTables = @($workbook.items | Where-Object { $_.name -eq 'inventory-health' })
$grafanaTables = @($grafana.panels | Where-Object { $_.title -eq 'Inventory state by computer' })
if ($workbookTables.Count -ne 1 -or $grafanaTables.Count -ne 1) {
    throw 'Both dashboards must contain exactly one inventory-state table.'
}

$queries = @(
    $workbookTables[0].content.query
    $grafanaTables[0].targets[0].azureLogAnalytics.query
)
$serverTypeOverrides = @($grafanaTables[0].fieldConfig.overrides | Where-Object {
    $_.matcher.id -eq 'byName' -and $_.matcher.options -eq 'Server Type'
})
if ($serverTypeOverrides.Count -ne 1 -or
    @($serverTypeOverrides[0].properties | Where-Object {
        $_.id -eq 'custom.align' -and $_.value -eq 'center'
    }).Count -ne 1) {
    throw 'Grafana must center the Server Type column with a scoped field override.'
}
$expectedProjection = "| project Computer, OperatingSystem, ['Server Type'] = VMType, InventoryState, LastInventory, InventoryAgeDays, SubscriptionId, ResourceGroup, ResourceType, ResourceId"
$heartbeatKey = '| extend OSJoinKey = iff(isnotempty(_ResourceId), strcat("resource:", tolower(_ResourceId)), strcat("computer:", tolower(Computer)))'
$inventoryKey = '| extend OSJoinKey = iff(isnotempty(ResourceId), strcat("resource:", tolower(ResourceId)), strcat("computer:", tolower(Computer)))'
$expectedTail = @(
    $inventoryKey
    '| join kind=leftouter MachineOperatingSystems on OSJoinKey'
    '| extend OperatingSystem = coalesce(OperatingSystem, "Unknown")'
    '| extend VMType = case(ResourceType =~ "Azure VM", "Azure", ResourceType =~ "Arc server", "Arc", "Unknown")'
    $expectedProjection
    '| sort by InventoryState asc, LastInventory desc'
) -join "`n"

foreach ($query in $queries) {
    if (-not $query.StartsWith("let MachineOperatingSystems = Heartbeat`n") -or
        -not $query.Contains('| where TimeGenerated > ago(30d)') -or
        -not $query.Contains('| where isnotempty(OSName) or isnotempty(OSType)') -or
        -not $query.Contains('| where isnotempty(_ResourceId) or isnotempty(Computer)') -or
        -not $query.Contains($heartbeatKey) -or
        -not $query.Contains('| summarize arg_max(TimeGenerated, OSName, OSType, OSMajorVersion, OSMinorVersion) by OSJoinKey')) {
        throw 'OS enrichment must use the latest populated Heartbeat metadata, deduplicated by safe machine identity.'
    }
    if (-not $query.Contains('| extend OSLabel = coalesce(OSName, OSType)') -or
        -not $query.Contains('OperatingSystem = iff(isnotempty(OSVersion) and not(OSLabel contains OSVersion), strcat(OSLabel, " (", OSVersion, ")"), OSLabel)')) {
        throw 'OS labels must preserve reported names/types and include available versions without duplication.'
    }
    if (-not $query.EndsWith($expectedTail)) {
        throw 'Inventory enrichment must preserve rows and project Computer, OperatingSystem, Server Type, then InventoryState.'
    }
    if ($query -notmatch 'summarize LastInventory = max\(TimeGenerated\).+ by Computer' -or
        $query -notmatch 'InventoryState = iff\(LastInventory >= ago\(') {
        throw 'Inventory grouping and freshness must remain based on ConfigurationData, not Heartbeat.'
    }
}

$enrichment = @($queries | ForEach-Object { ($_ -split ";`nConfigurationData`n", 2)[0] })
if ($enrichment[0] -cne $enrichment[1]) {
    throw 'Workbook and Grafana OS enrichment must stay identical.'
}

$parameters = $workbook.items | Where-Object { $_.type -eq 9 } | ForEach-Object { $_.content.parameters }
$osParameter = $parameters | Where-Object { $_.name -eq 'OperatingSystem' }
if ($osParameter.query -notmatch 'OSType =~ "Windows"' -or
    $queries[0].Contains('{OperatingSystem}') -or
    $queries[1].Contains('arg(')) {
    throw 'The baseline-only OS filter and Grafana no-Resource-Graph contract must remain unchanged.'
}

$template = Get-Content -Raw $TemplatePath | ConvertFrom-Json
$embeddedSources = @($template.variables.PSObject.Properties | Where-Object {
    $_.Value -is [string] -and $_.Value -match '^\s*\{\s*"version"\s*:\s*"Notebook/1\.0"'
})
if ($embeddedSources.Count -ne 1) {
    throw 'The compiled Bicep template must contain exactly one embedded Workbook.'
}
$embeddedWorkbook = $embeddedSources[0].Value | ConvertFrom-Json
$embeddedTable = $embeddedWorkbook.items | Where-Object { $_.name -eq 'inventory-health' }
if ($embeddedTable.content.query -cne $queries[0]) {
    throw 'The compiled Bicep template must embed the updated Workbook inventory query.'
}

Write-Output 'Inventory OS contracts passed for Workbook, Grafana, and compiled Bicep.'
