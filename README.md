---
title: Azure Update Manager Dashboard
description: SCCM-inspired Azure Workbook reports backed by Change Tracking and Inventory data in Log Analytics
ms.date: 2026-09-16
ms.topic: overview
---

## Overview

This project deploys an Azure Workbook for long-term update and software inventory
reporting. Every report queries the `ConfigurationData` table populated by Azure
Change Tracking and Inventory. Azure Resource Graph Update Manager tables are not
used.

The Workbook is associated with one Log Analytics workspace at deployment time.
Report history follows the retention configured for that workspace and table.

## Included reports

* Inventory summary and reporting freshness
* SCCM-style scan and inventory state by computer
* Inventory-derived KB baseline compliance
* Installed update summary and per-computer detail
* Historical update adoption by first observation
* Installed software summary and per-computer detail

## Data boundary

`ConfigurationData` contains discovered inventory. The Workbook uses records where
`ConfigDataType` is `Software` and separates applications, packages, and updates by
`SoftwareType`.

> [!IMPORTANT]
> `ConfigurationData` does not contain required or missing update evaluations,
> deployments, enforcement states, scan errors, or installation results. The
> baseline reports infer compliance by checking whether user-supplied KB identifiers
> appear in each computer's current installed-update inventory. This is not equivalent
> to SCCM or Azure Update Manager compliance state.

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

## Deploy

Create `infra/main.bicepparam` with the target workspace resource ID. The ignored
local parameter file can follow `infra/main.sample.bicepparam`.

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

## Project structure

```text
.github/workflows/validate.yml
infra/main.bicep
infra/main.sample.bicepparam
workbook/azure-update-manager.workbook.json
```

## References

* [ConfigurationData table reference](https://learn.microsoft.com/azure/azure-monitor/reference/tables/configurationdata)
* [Change Tracking and Inventory overview](https://learn.microsoft.com/azure/azure-change-tracking-inventory/overview-monitoring-agent)
* [Configuration Manager built-in reports](https://learn.microsoft.com/intune/configmgr/core/servers/manage/list-of-reports)
* [Azure Workbooks data sources](https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-data-sources)