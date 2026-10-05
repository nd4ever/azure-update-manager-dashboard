---
title: Azure Update Manager Dashboard
description: SCCM-inspired Azure Workbook and Managed Grafana reports backed by Change Tracking and Inventory data in Log Analytics
ms.date: 2026-09-30
ms.topic: overview
---

## Overview

This project deploys an Azure Workbook for long-term update and software inventory
reporting. It also includes an Azure Managed Grafana dashboard and can optionally
provision a Managed Grafana workspace. The visualizations query the
`ConfigurationData` table populated by Azure Change Tracking and Inventory.

Both experiences target one Log Analytics workspace. Report history follows the
retention configured for that workspace and table.

## Included reports

The Azure Workbook includes:

* Inventory summary and reporting freshness
* SCCM-style scan and inventory state by computer
* Applicability-aware KB baseline compliance
* Installed update summary and per-computer detail
* Historical update adoption by first observation
* Installed software summary and per-computer detail

The Grafana dashboard includes:

* Inventory health statistics and reporting trends
* Inventory state by computer
* Installed update summary and adoption history
* Installed software summary and per-computer detail
* Inventory-based baseline compliance against a user-supplied KB list
* Drill-through links from table cells to Azure Monitor Logs
* Interactive KB baseline, freshness, computer, software, and time-range filters

## Data sources

Both surfaces read Change Tracking and Inventory data from Log Analytics. The
Workbook additionally queries Azure Resource Graph for scoping and update
assessment. The Grafana dashboard does not.

| Data source | Provides | Used by |
|-------------|----------|---------|
| Change Tracking and Inventory in Log Analytics (`ConfigurationData`) | Installed updates, installed software, applications, and packages | Workbook and Grafana |
| Log Analytics `Heartbeat` | Operating system names and versions for inventory tables; operating system filter for baseline compliance | Workbook and Grafana |
| Azure Resource Graph `Resources` | Workspace selection and resource region filtering | Workbook |
| Azure Resource Graph `patchassessmentresources` | Azure Update Manager pending-update assessment for applicability-aware baseline compliance | Workbook |

### Which report reads from which source

Every Workbook report is built on Change Tracking and Inventory
(`ConfigurationData`). Azure Resource Graph is layered on top: the `Resources`
table backs the region filter on every report, and `patchassessmentresources`
backs only the two baseline compliance reports.

| Workbook report | Change Tracking and Inventory | Azure Resource Graph |
|-----------------|-------------------------------|----------------------|
| Inventory summary | Inventory records | `Resources` for the region filter |
| Inventory state by computer | Inventory records | `Resources` for the region filter |
| Overall compliance | Installed updates | `patchassessmentresources` for pending updates, plus `Resources` for the region filter |
| Computer compliance details | Installed updates | `patchassessmentresources` for pending updates, plus `Resources` for the region filter |
| Installed update summary | Installed updates | `Resources` for the region filter |
| Historical update adoption | Installed updates | `Resources` for the region filter |
| Installed updates by computer | Installed updates | `Resources` for the region filter |
| Installed software summary | Installed software | `Resources` for the region filter |
| Software by computer | Installed software | `Resources` for the region filter |

The baseline compliance reports also read Log Analytics `Heartbeat` for the
operating system filter. Among the filters, the workspace picker and region filter
query Azure Resource Graph, the operating system filter queries `Heartbeat`, and the
rest are static choices or free text.

Every Grafana panel queries `ConfigurationData`. The **Inventory state by computer**
table also reads `Heartbeat` to display **OperatingSystem** immediately after
**Computer**, followed by **Server Type**, as does the corresponding Workbook table.
**Server Type** is `Azure` for native Azure VMs (`Microsoft.Compute/virtualMachines`),
`Arc` for connected servers (`Microsoft.HybridCompute/machines`), and `Unknown` for
other or missing resource types. It reuses the resource-ID-derived classification;
the existing **ResourceType** column and filters remain unchanged. Grafana uses no Azure Resource
Graph, because `arg()` cross-service queries are not available through the Log
Analytics query API that the Grafana Azure Monitor data source uses. Its baseline
compliance is therefore inventory-only.

Grafana centers the **Server Type** column with a per-field alignment override;
other columns retain their existing alignment. The Workbook uses its default
text alignment because a supported per-column centering option is not documented.

The inventory tables use the latest populated OS metadata from `Heartbeat` within
the last 30 days (and the selected query history range). They display `OSName`, falling
back to `OSType`, and append the reported major/minor version when it is not already
in the label. This supports Windows and Linux on both Azure VMs and Arc servers.
Matching uses the case-insensitive full resource ID, or the case-insensitive full
computer name only when both records lack a resource ID; short names are not used to
guess identity across resources. Missing or unmatched OS metadata displays `Unknown`
without dropping inventory rows or changing freshness, counts, or scoping. Query
access to `Heartbeat` is required; an unavailable table or denied access remains a
query error. The Workbook's existing **Operating system** dropdown continues to
scope baseline compliance only, not the inventory table.

## Data boundary

`ConfigurationData` contains discovered inventory. The Workbook uses records where
`ConfigDataType` is `Software` and separates applications, packages, and updates by
`SoftwareType`.

> [!IMPORTANT]
> `ConfigurationData` does not contain required or missing update evaluations,
> deployments, enforcement states, scan errors, or installation results. The
> Workbook baseline reports combine installed update inventory with Azure Resource
> Graph `patchassessmentresources` to determine whether a user-supplied KB is
> installed or pending. This is not equivalent to deployment or enforcement state.
> The Grafana baseline compliance section is inventory-based only: it marks a
> computer compliant when every required KB appears in installed inventory and
> noncompliant otherwise. It cannot use `patchassessmentresources`, because Azure
> Resource Graph is not reachable through the Log Analytics query path Grafana uses,
> so it does not evaluate applicability. A required KB that does not apply to a
> machine still counts as missing there; use the KB baseline and computer filters to
> scope results.

The historical chart reports when an update was first observed in inventory. It does
not claim that this timestamp is the installation time. Change events belong in the
`ConfigurationChange` table and are intentionally outside this project's current data
contract.

## Prerequisites

* A Log Analytics workspace receiving Change Tracking and Inventory data
* Workspace or table retention configured for the required history period
* Permission to query workspace logs, such as Log Analytics Reader
* Permission to deploy shared Workbooks, such as Workbook Contributor plus the
  required resource-group deployment permissions
* Azure CLI with Bicep support for local deployment
* PowerShell 7 or newer to run the dashboard import script
* Azure CLI `amg` extension for Grafana dashboard import
* Grafana Admin on the target Managed Grafana workspace
* An Azure Monitor data source in the target Managed Grafana workspace (provided by default in Azure Managed Grafana)

Creating Grafana role assignments also requires
`Microsoft.Authorization/roleAssignments/write`, such as User Access Administrator
or Owner, at the assignment scope.

Install the Managed Grafana CLI extension when needed:

```powershell
az extension add --name amg
```

## Deploy

Create `infra/main.bicepparam` with the target workspace resource ID. The ignored
local parameter file can follow `infra/main.sample.bicepparam`.

The default deployment creates only the Workbook. To also create a Managed Grafana
workspace, add these parameters:

```bicep
param shouldDeployManagedGrafana = true
param managedGrafanaName = 'amg-aum-dashboard'
param managedGrafanaAdminPrincipalId = '<user-group-or-service-principal-object-id>'
```

The new workspace receives a system-assigned managed identity and Monitoring Reader
on the target Log Analytics workspace. The optional admin object ID receives Grafana
Admin so that identity can import and manage dashboards.

To reuse an existing Managed Grafana workspace, leave
`shouldDeployManagedGrafana` set to `false`. You can grant its managed identity
Monitoring Reader during the deployment:

```bicep
param shouldDeployManagedGrafana = false
param existingManagedGrafanaPrincipalId = '<managed-grafana-principal-id>'
```

Preview the deployment first:

```powershell
$resourceGroup = '<resource-group-name>'
az deployment group what-if `
  --resource-group $resourceGroup `
  --template-file infra/main.bicep `
  --parameters infra/main.bicepparam
```

Deploy after reviewing the preview:

```powershell
az deployment group create `
  --resource-group $resourceGroup `
  --template-file infra/main.bicep `
  --parameters infra/main.bicepparam
```

Open the deployed report from **Azure Monitor** > **Workbooks** in the Azure portal.

## Import the Grafana dashboard

Grafana dashboards are data-plane resources, so the Bicep deployment creates the
optional workspace and RBAC while a separate script performs the idempotent dashboard
import. Run it for either a new or existing workspace:

```powershell
./scripts/Import-GrafanaDashboard.ps1 `
  -GrafanaName '<managed-grafana-name>' `
  -GrafanaResourceGroupName '<managed-grafana-resource-group>' `
  -GrafanaSubscriptionId '<managed-grafana-subscription-id>' `
  -LogAnalyticsWorkspaceResourceId '<log-analytics-workspace-resource-id>'
```

The script validates the workspace resource ID you supply, derives its subscription,
and resolves the workspace's Azure Monitor data source. It then substitutes the
dashboard placeholders, imports with overwrite enabled, verifies the stable dashboard
UID, and removes its temporary file. When the workspace has more than one Azure Monitor
data source, the script selects the default one, or the first by name when none is
marked default.

## Project structure

```text
.github/workflows/validate.yml
grafana/azure-update-manager.dashboard.json
infra/main.bicep
infra/main.json
infra/main.sample.bicepparam
infra/modules/log-analytics-monitoring-reader.bicep
scripts/Import-GrafanaDashboard.ps1
scripts/Test-InventoryOperatingSystem.ps1
workbook/azure-update-manager.workbook.json
```

The dashboard JSON files contain the report KQL directly. Bicep loads the Workbook
JSON, while the import script consumes the Grafana JSON. After editing the Workbook,
regenerate the checked-in ARM template and check the inventory OS contract locally:

```powershell
az bicep build --file infra/main.bicep --outfile infra/main.json
./scripts/Test-InventoryOperatingSystem.ps1
```

CI also checks the inventory query's column order, row-preserving OS enrichment,
shared enrichment logic, unchanged filter boundaries, and rebuilt ARM template.

## References

* [ConfigurationData table reference](https://learn.microsoft.com/azure/azure-monitor/reference/tables/configurationdata)
* [Heartbeat table reference](https://learn.microsoft.com/azure/azure-monitor/reference/tables/heartbeat)
* [Change Tracking and Inventory overview](https://learn.microsoft.com/azure/azure-change-tracking-inventory/overview-monitoring-agent)
* [Configuration Manager built-in reports](https://learn.microsoft.com/intune/configmgr/core/servers/manage/list-of-reports)
* [Create or import Azure Managed Grafana dashboards](https://learn.microsoft.com/azure/managed-grafana/how-to-create-dashboard)
* [Configure Managed Grafana access to Azure Monitor](https://learn.microsoft.com/azure/managed-grafana/how-to-permissions)
* [Azure Workbooks data sources](https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-data-sources)

## License

This project is licensed under the MIT License. See [LICENSE](./LICENSE) for details.