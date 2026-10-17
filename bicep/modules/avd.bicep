// The AVD control plane objects you own: a pooled host pool with the secured
// baseline RDP properties, a desktop application group, the workspace that
// publishes it, the desktop assignment for the demo users, and diagnostics on
// all three.

@description('Host pool name.')
param hostPoolName string

@description('Desktop application group name.')
param appGroupName string

@description('Workspace name.')
param workspaceName string

@description('Azure region for the AVD metadata.')
param location string

@description('Maximum sessions per host.')
@minValue(1)
param maxSessionLimit int

@description('Custom RDP properties: the secured baseline the demo starts from.')
param rdpProperties string

@description('Object IDs of the demo users who get the desktop.')
param userObjectIds string[]

@description('Log Analytics workspace resource ID for diagnostics.')
param logAnalyticsWorkspaceId string

@description('Tags for every resource.')
param tags object

var desktopVirtualizationUserRoleId = '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63'

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2024-04-03' = {
  name: hostPoolName
  location: location
  tags: tags
  properties: {
    friendlyName: 'AVD security demo'
    description: 'Demo host pool for the gettothe.cloud session Azure Virtual Desktop | Securing Your Environment.'
    hostPoolType: 'Pooled'
    loadBalancerType: 'BreadthFirst'
    maxSessionLimit: maxSessionLimit
    preferredAppGroupType: 'Desktop'
    customRdpProperty: rdpProperties
    validationEnvironment: false
    startVMOnConnect: false
  }
}

resource appGroup 'Microsoft.DesktopVirtualization/applicationGroups@2024-04-03' = {
  name: appGroupName
  location: location
  tags: tags
  properties: {
    applicationGroupType: 'Desktop'
    hostPoolArmPath: hostPool.id
    friendlyName: 'AVD security demo'
  }
}

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2024-04-03' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    friendlyName: 'AVD security demo'
    applicationGroupReferences: [
      appGroup.id
    ]
  }
}

resource desktopUsers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for userId in userObjectIds: {
    name: guid(appGroup.id, userId, desktopVirtualizationUserRoleId)
    scope: appGroup
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', desktopVirtualizationUserRoleId)
      principalId: userId
      principalType: 'User'
      description: 'Demo user gets the AVD security demo desktop.'
    }
  }
]

resource hostPoolDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: hostPool
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      for category in ['Checkpoint', 'Error', 'Management', 'Connection', 'HostRegistration', 'AgentHealthStatus', 'NetworkData']: {
        category: category
        enabled: true
      }
    ]
  }
}

resource appGroupDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: appGroup
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      for category in ['Checkpoint', 'Error', 'Management']: {
        category: category
        enabled: true
      }
    ]
  }
}

resource workspaceDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: workspace
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      for category in ['Checkpoint', 'Error', 'Management', 'Feed']: {
        category: category
        enabled: true
      }
    ]
  }
}

@description('Host pool resource ID.')
output hostPoolId string = hostPool.id

@description('Desktop application group resource ID.')
output appGroupId string = appGroup.id

@description('Workspace resource ID.')
output workspaceId string = workspace.id
