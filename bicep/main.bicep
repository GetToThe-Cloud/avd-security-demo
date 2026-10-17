// AVD security demo: the lab, from zero
//
// Two resource groups, so the controls land where the talk says they belong:
//   rg-<prefix>-core   network, NAT gateway, Log Analytics, host pool, application group, workspace
//   rg-<prefix>-hosts  the sessionhost, its VM login roles and the deny-public-IP policy
//
// Deploy twice. Phase 'core' builds everything except the sessionhost. The deploy script
// then creates a short-lived registration token and runs phase 'sessionhost', which only
// adds the VM, so the host pool is never touched while its token is in use.
// scripts/01-Deploy-Environment.ps1 does both runs, waits for the host and removes the token.

targetScope = 'subscription'

metadata name = 'AVD security demo lab'
metadata description = 'One secured pooled host pool with one Trusted Launch, Entra-joined sessionhost, for the Azure Virtual Desktop | Securing Your Environment demo.'

// ----- General -------------------------------------------------------------------------

@description('Short name used in every resource name. Lowercase letters and digits.')
@minLength(3)
@maxLength(8)
param prefix string = 'avdsec'

@description('Azure region for the AVD metadata, the network and the sessionhost.')
param region string = 'westeurope'

@description('core: everything except the sessionhost. sessionhost: only the sessionhost VM, which needs a registration token.')
@allowed([
  'core'
  'sessionhost'
])
param phase string = 'core'

@description('Tags for every resource.')
param resourceTags object = {
  workload: 'avd-security-demo'
  'created-by': 'bicep'
}

// ----- Identities ----------------------------------------------------------------------

@description('Object IDs of the demo users (avd.user and avd.poweruser). They get the desktop and Virtual Machine User Login.')
param userObjectIds string[] = []

// ----- Host pool -----------------------------------------------------------------------

@description('Maximum sessions per host.')
@minValue(1)
param maxSessionLimit int = 4

@description('The secured baseline: SSO on, clipboard, drives, printers, USB and COM ports off. The demo opens and closes these live.')
param rdpProperties string = 'enablerdsaadauth:i:1;targetisaadjoined:i:1;redirectclipboard:i:0;drivestoredirect:s:;redirectprinters:i:0;usbdevicestoredirect:s:;redirectcomports:i:0;devicestoredirect:s:;camerastoredirect:s:*;audiocapturemode:i:1;audiomode:i:0'

@description('Assign the built-in Not allowed resource types policy, denying public IPs on the sessionhost resource group.')
param denyPublicIp bool = true

// ----- Sessionhost ---------------------------------------------------------------------

@description('VM size. Needs Gen2 and Trusted Launch support.')
param vmSize string = 'Standard_D4ads_v5'

@description('OS disk type.')
param osDiskType 'Premium_LRS' | 'StandardSSD_LRS' | 'Standard_LRS' = 'Premium_LRS'

@description('Marketplace SKU of Windows 11 Enterprise multi-session.')
param imageSku string = 'win11-25h2-avd'

@description('Local admin user name.')
param vmAdminUsername string = 'avdadmin'

@description('Local admin password. The deploy script generates one; you sign in with Entra ID.')
@secure()
param vmAdminPassword string = ''

@description('Host pool registration token. Only used in phase sessionhost.')
@secure()
param registrationToken string = ''

// ----- Network -------------------------------------------------------------------------

@description('Address space for the demo virtual network.')
param vnetAddressPrefix string = '10.81.0.0/24'

@description('Sessionhost subnet.')
param subnetAddressPrefix string = '10.81.0.0/26'

// ----- Names ---------------------------------------------------------------------------

var names = {
  rgCore: 'rg-${prefix}-core'
  rgHosts: 'rg-${prefix}-hosts'
  logAnalytics: 'log-${prefix}'
  hostPool: 'vdpool-${prefix}'
  appGroup: 'vdag-${prefix}-desktop'
  workspace: 'vdws-${prefix}'
  vnet: 'vnet-${prefix}'
  subnet: 'snet-sessionhosts'
  vm: 'vm-${prefix}-sh0'
  computer: '${prefix}-sh0'
}

var deployCore = phase == 'core'
var deploySessionHost = phase == 'sessionhost'

// ----- Resource groups -----------------------------------------------------------------

resource rgCore 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.rgCore
  location: region
  tags: resourceTags
}

resource rgHosts 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.rgHosts
  location: region
  tags: resourceTags
}

// ----- Core ----------------------------------------------------------------------------

module network 'modules/network.bicep' = if (deployCore) {
  name: 'network'
  scope: rgCore
  params: {
    prefix: prefix
    location: region
    vnetAddressPrefix: vnetAddressPrefix
    subnetAddressPrefix: subnetAddressPrefix
    tags: resourceTags
  }
}

module monitoring 'modules/monitoring.bicep' = if (deployCore) {
  name: 'monitoring'
  scope: rgCore
  params: {
    name: names.logAnalytics
    location: region
    tags: resourceTags
  }
}

module avd 'modules/avd.bicep' = if (deployCore) {
  name: 'avd'
  scope: rgCore
  params: {
    hostPoolName: names.hostPool
    appGroupName: names.appGroup
    workspaceName: names.workspace
    location: region
    maxSessionLimit: maxSessionLimit
    rdpProperties: rdpProperties
    userObjectIds: userObjectIds
    logAnalyticsWorkspaceId: monitoring!.outputs.id
    tags: resourceTags
  }
}

module governance 'modules/hosts-governance.bicep' = if (deployCore) {
  name: 'hosts-governance'
  scope: rgHosts
  params: {
    userObjectIds: userObjectIds
    denyPublicIp: denyPublicIp
  }
}

// ----- Sessionhost ---------------------------------------------------------------------

module sessionHost 'modules/sessionhost.bicep' = if (deploySessionHost) {
  name: 'sessionhost'
  scope: rgHosts
  params: {
    vmName: names.vm
    computerName: names.computer
    location: region
    vmSize: vmSize
    osDiskType: osDiskType
    image: {
      publisher: 'MicrosoftWindowsDesktop'
      offer: 'windows-11'
      sku: imageSku
      version: 'latest'
    }
    subnetId: resourceId(subscription().subscriptionId, names.rgCore, 'Microsoft.Network/virtualNetworks/subnets', names.vnet, names.subnet)
    adminUsername: vmAdminUsername
    adminPassword: vmAdminPassword
    registrationToken: registrationToken
    tags: resourceTags
  }
}

// ----- Outputs, read by the scripts ----------------------------------------------------

output resourceGroups object = {
  core: rgCore.name
  hosts: rgHosts.name
}

output region string = region

output hostPool object = {
  name: names.hostPool
  id: resourceId(subscription().subscriptionId, names.rgCore, 'Microsoft.DesktopVirtualization/hostPools', names.hostPool)
}

output appGroup object = {
  name: names.appGroup
  id: resourceId(subscription().subscriptionId, names.rgCore, 'Microsoft.DesktopVirtualization/applicationGroups', names.appGroup)
}

output workspace object = {
  name: names.workspace
  id: resourceId(subscription().subscriptionId, names.rgCore, 'Microsoft.DesktopVirtualization/workspaces', names.workspace)
}

output logAnalytics object = {
  name: names.logAnalytics
  id: resourceId(subscription().subscriptionId, names.rgCore, 'Microsoft.OperationalInsights/workspaces', names.logAnalytics)
}

output sessionHost object = {
  vmName: names.vm
  computerName: names.computer
}
