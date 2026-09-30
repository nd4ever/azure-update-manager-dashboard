metadata name = 'Azure Update Manager Dashboard'
metadata description = 'Deploys a shared Azure Workbook and optionally an Azure Managed Grafana workspace backed by Change Tracking and Inventory data in Log Analytics.'

targetScope = 'resourceGroup'

/* Common parameters */

@description('The resource ID of the Log Analytics workspace that contains ConfigurationData records.')
param logAnalyticsWorkspaceResourceId string

@description('The Azure region in which to store the Workbook resource.')
param location string = resourceGroup().location

/* Workbook parameters */

@description('The display name shown for the Workbook in the Azure portal.')
param workbookDisplayName string = 'Azure Update Manager - ConfigurationData'

/* Azure Managed Grafana parameters */

@description('Whether to deploy a new Azure Managed Grafana workspace in this resource group.')
param shouldDeployManagedGrafana bool = false

@description('The name of the Azure Managed Grafana workspace to deploy when shouldDeployManagedGrafana is true.')
@minLength(2)
@maxLength(30)
param managedGrafanaName string = 'amg-${uniqueString(resourceGroup().id)}'

@description('The SKU of the Azure Managed Grafana workspace.')
param managedGrafanaSkuName string = 'Standard'

@description('Whether to allow public network access to a newly deployed Azure Managed Grafana workspace.')
param shouldEnableGrafanaPublicNetworkAccess bool = true

@description('Whether to enable zone redundancy for a newly deployed Azure Managed Grafana workspace.')
param shouldEnableGrafanaZoneRedundancy bool = false

@description('The object ID to receive Grafana Admin on a newly deployed workspace. No Grafana data-plane role is assigned when omitted.')
param managedGrafanaAdminPrincipalId string?

@description('The system-assigned managed identity principal ID of an existing Azure Managed Grafana workspace. When supplied without deploying a workspace, Monitoring Reader is assigned on the Log Analytics workspace.')
param existingManagedGrafanaPrincipalId string?

/* Variables */

var logAnalyticsWorkspaceResourceIdSegments array = split(logAnalyticsWorkspaceResourceId, '/')
var logAnalyticsWorkspaceSubscriptionId string = logAnalyticsWorkspaceResourceIdSegments[2]
var logAnalyticsWorkspaceResourceGroupName string = logAnalyticsWorkspaceResourceIdSegments[4]
var logAnalyticsWorkspaceName string = logAnalyticsWorkspaceResourceIdSegments[8]
var monitoringReaderRoleDefinitionId string = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
var grafanaAdminRoleDefinitionId string = '22926164-76b3-42b3-bc55-97df8dab3e41'
var workloadTags = {
  'data-source': 'ConfigurationData'
  workload: 'azure-update-manager-dashboard'
}
var workbookContent string = replace(
  loadTextContent('../workbook/azure-update-manager.workbook.json'),
  '__WORKSPACE_RESOURCE_ID__',
  logAnalyticsWorkspaceResourceId
)

/* Existing resources */

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
  scope: resourceGroup(logAnalyticsWorkspaceSubscriptionId, logAnalyticsWorkspaceResourceGroupName)
}

/* Resources */

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, 'Microsoft.Insights/workbooks', workbookDisplayName)
  location: location
  kind: 'shared'
  tags: workloadTags
  properties: {
    category: 'workbook'
    description: 'SCCM-inspired software update and inventory reporting from Log Analytics ConfigurationData.'
    displayName: workbookDisplayName
    serializedData: workbookContent
    sourceId: logAnalyticsWorkspaceResourceId
    version: 'Notebook/1.0'
  }
}

resource managedGrafana 'Microsoft.Dashboard/grafana@2024-10-01' = if (shouldDeployManagedGrafana) {
  name: managedGrafanaName
  location: location
  tags: workloadTags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    apiKey: 'Disabled'
    deterministicOutboundIP: 'Disabled'
    publicNetworkAccess: shouldEnableGrafanaPublicNetworkAccess ? 'Enabled' : 'Disabled'
    zoneRedundancy: shouldEnableGrafanaZoneRedundancy ? 'Enabled' : 'Disabled'
  }
  sku: {
    name: managedGrafanaSkuName
  }
}

/* Modules */

module deployedGrafanaMonitoringReaderRoleAssignment './modules/log-analytics-monitoring-reader.bicep' = if (shouldDeployManagedGrafana) {
  scope: resourceGroup(logAnalyticsWorkspaceSubscriptionId, logAnalyticsWorkspaceResourceGroupName)
  params: {
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    monitoringReaderRoleDefinitionId: monitoringReaderRoleDefinitionId
    principalId: managedGrafana!.identity.principalId
  }
}

module existingGrafanaMonitoringReaderRoleAssignment './modules/log-analytics-monitoring-reader.bicep' = if (!shouldDeployManagedGrafana && existingManagedGrafanaPrincipalId != null) {
  scope: resourceGroup(logAnalyticsWorkspaceSubscriptionId, logAnalyticsWorkspaceResourceGroupName)
  params: {
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    monitoringReaderRoleDefinitionId: monitoringReaderRoleDefinitionId
    principalId: existingManagedGrafanaPrincipalId!
  }
}

resource managedGrafanaAdminRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (shouldDeployManagedGrafana && managedGrafanaAdminPrincipalId != null) {
  name: guid(managedGrafana!.id, managedGrafanaAdminPrincipalId!, grafanaAdminRoleDefinitionId)
  scope: managedGrafana!
  properties: {
    principalId: managedGrafanaAdminPrincipalId!
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', grafanaAdminRoleDefinitionId)
  }
}

/* Outputs */

@description('The resource ID of the deployed Workbook.')
output workbookResourceId string = workbook.id

@description('The immutable workspace ID used by Azure Monitor Logs and Grafana queries.')
output logAnalyticsWorkspaceCustomerId string = logAnalyticsWorkspace.properties.customerId

@description('The resource ID of the deployed Azure Managed Grafana workspace, or null when deployment is disabled.')
output managedGrafanaResourceId string? = managedGrafana.?id

@description('The endpoint of the deployed Azure Managed Grafana workspace, or null when deployment is disabled.')
output managedGrafanaEndpoint string? = managedGrafana.?properties.endpoint

@description('The system-assigned managed identity principal ID of the deployed Azure Managed Grafana workspace, or null when deployment is disabled.')
output managedGrafanaPrincipalId string? = managedGrafana.?identity.principalId
