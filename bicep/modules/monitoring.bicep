// Log Analytics workspace for the AVD diagnostics. Flip 4 reads WVDConnections from
// it, and SigninLogs once Entra ID sign-in logs are connected
// (01-Deploy-Environment.ps1 -ConnectEntraSignInLogs).

@description('Workspace name.')
param name string

@description('Azure region.')
param location string

@description('Days to keep the data.')
@minValue(30)
param retentionInDays int = 30

@description('Tags for every resource.')
param tags object

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
  }
}

@description('Workspace resource ID, used by the diagnostic settings.')
output id string = workspace.id

@description('Workspace (customer) ID, used by the scripts to run KQL.')
output customerId string = workspace.properties.customerId
