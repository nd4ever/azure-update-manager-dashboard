metadata name = 'Log Analytics Monitoring Reader'
metadata description = 'Assigns Monitoring Reader on a Log Analytics workspace to a service principal.'

targetScope = 'resourceGroup'

/* Parameters */

@description('The name of the existing Log Analytics workspace.')
param logAnalyticsWorkspaceName string

@description('The object ID of the service principal that requires monitoring access.')
param principalId string

@description('The built-in Monitoring Reader role definition ID.')
param monitoringReaderRoleDefinitionId string

/* Existing resources */

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
}

/* Resources */

resource monitoringReaderRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(logAnalyticsWorkspace.id, principalId, monitoringReaderRoleDefinitionId)
  scope: logAnalyticsWorkspace
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      monitoringReaderRoleDefinitionId
    )
  }
}
