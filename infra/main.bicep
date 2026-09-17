metadata name = 'Azure Update Manager Dashboard'
metadata description = 'Deploys a shared Azure Workbook backed by Change Tracking and Inventory data in Log Analytics.'

targetScope = 'resourceGroup'

@description('The resource ID of the Log Analytics workspace that contains ConfigurationData records.')
param logAnalyticsWorkspaceResourceId string

@description('The Azure region in which to store the Workbook resource.')
param location string = resourceGroup().location

@description('The display name shown for the Workbook in the Azure portal.')
param workbookDisplayName string = 'Azure Update Manager - ConfigurationData'

var workbookContent string = replace(
  loadTextContent('../workbook/azure-update-manager.workbook.json'),
  '__WORKSPACE_RESOURCE_ID__',
  logAnalyticsWorkspaceResourceId
)

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, 'Microsoft.Insights/workbooks', workbookDisplayName)
  location: location
  kind: 'shared'
  tags: {
    'data-source': 'ConfigurationData'
    workload: 'azure-update-manager-dashboard'
  }
  properties: {
    category: 'workbook'
    description: 'SCCM-inspired software update and inventory reporting from Log Analytics ConfigurationData.'
    displayName: workbookDisplayName
    serializedData: workbookContent
    sourceId: logAnalyticsWorkspaceResourceId
    version: 'Notebook/1.0'
  }
}

@description('The resource ID of the deployed Workbook.')
output workbookResourceId string = workbook.id
