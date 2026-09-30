using 'main.bicep'

param logAnalyticsWorkspaceResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-monitoring/providers/Microsoft.OperationalInsights/workspaces/law-management'
param workbookDisplayName = 'Azure Update Manager - ConfigurationData'
param shouldDeployManagedGrafana = false
param managedGrafanaName = 'amg-aum-dashboard'

// For a new workspace, set this to the object ID that should import and manage dashboards.
// param managedGrafanaAdminPrincipalId = '00000000-0000-0000-0000-000000000000'

// For an existing workspace, set this to its system-assigned identity principal ID.
// param existingManagedGrafanaPrincipalId = '00000000-0000-0000-0000-000000000000'
