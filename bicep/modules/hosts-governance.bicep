// Governance on the sessionhost resource group, deployed before any host exists:
//   - Virtual Machine User Login for the demo users, scoped to this resource group
//     and not the subscription (Part II: RBAC is the load-bearing wall)
//   - the built-in 'Not allowed resource types' policy, denying public IPs (Part III)
// The poweruser's Virtual Machine Administrator Login is NOT here on purpose: that is
// the demo's misconfiguration, added by 01-Deploy-Environment.ps1 and removed live.

@description('Object IDs of the demo users.')
param userObjectIds string[]

@description('Assign the deny-public-IP policy.')
param denyPublicIp bool

var vmUserLoginRoleId = 'fb879df8-f326-4884-b1cf-06f3ad86be52'
var notAllowedResourceTypesPolicyId = '6c112d4e-5bc7-47ae-a041-ea2d9dccd749'

resource vmUserLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for userId in userObjectIds: {
    name: guid(resourceGroup().id, userId, vmUserLoginRoleId)
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', vmUserLoginRoleId)
      principalId: userId
      principalType: 'User'
      description: 'Standard user sign-in to the demo sessionhost.'
    }
  }
]

resource denyPublicIpAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = if (denyPublicIp) {
  name: 'deny-public-ip-sessionhosts'
  properties: {
    displayName: 'Deny public IPs on AVD sessionhosts'
    description: 'Sessionhosts use reverse connect and never need a public IP. This stops the next troubleshooting session from adding one.'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', notAllowedResourceTypesPolicyId)
    parameters: {
      listOfResourceTypesNotAllowed: {
        value: [
          'Microsoft.Network/publicIPAddresses'
        ]
      }
    }
    nonComplianceMessages: [
      {
        message: 'Sessionhosts never need a public IP: Azure Virtual Desktop uses reverse connect.'
      }
    ]
  }
}
