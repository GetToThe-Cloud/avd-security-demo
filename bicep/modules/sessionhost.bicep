// One sessionhost, built the way the talk says a sessionhost should be built:
//   - Trusted Launch with Secure Boot and vTPM, plus the Guest Attestation extension
//     for boot integrity monitoring (Part II: decide it at creation)
//   - no public IP on the NIC (Part III: reverse connect)
//   - joined to Microsoft Entra ID with the AADLoginForWindows extension
//   - registered to the host pool with the AVD agent, from a signature-checked download

@description('VM resource name.')
param vmName string

@description('Windows computer name, 15 characters at most.')
@maxLength(15)
param computerName string

@description('Azure region.')
param location string

@description('VM size. Needs Gen2 and Trusted Launch support.')
param vmSize string

@description('OS disk type.')
param osDiskType 'Premium_LRS' | 'StandardSSD_LRS' | 'Standard_LRS'

@description('Marketplace image of Windows 11 Enterprise multi-session.')
param image {
  publisher: string
  offer: string
  sku: string
  version: string
}

@description('Sessionhost subnet resource ID.')
param subnetId string

@description('Local admin user name. You sign in with Entra ID; this account is only there because Windows needs one.')
param adminUsername string

@description('Local admin password.')
@secure()
param adminPassword string

@description('Host pool registration token, valid for a few hours.')
@secure()
param registrationToken string

@description('Tags for every resource.')
param tags object

var registrationScript = replace(loadTextContent('Register-AvdAgent.ps1'), '__REGISTRATION_TOKEN__', registrationToken)

resource nic 'Microsoft.Network/networkInterfaces@2024-07-01' = {
  name: 'nic-${vmName}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
          // no publicIPAddress: nothing dials in
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: vmName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned' // needed for the Entra join
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    licenseType: 'Windows_Client' // Windows 11 Enterprise multi-session through AVD
    osProfile: {
      computerName: computerName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
        patchSettings: {
          patchMode: 'AutomaticByOS'
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: image.publisher
        offer: image.offer
        sku: image.sku
        version: image.version
      }
      osDisk: {
        name: 'osdisk-${vmName}'
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: osDiskType
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true // managed storage
      }
    }
  }
}

resource guestAttestation 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: vm
  name: 'GuestAttestation'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.Security.WindowsAttestation'
    type: 'GuestAttestation'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
    settings: {
      AttestationConfig: {
        MaaSettings: {
          maaEndpoint: ''
          maaTenantName: 'GuestAttestation'
        }
        AscSettings: {
          ascReportingEndpoint: ''
          ascReportingFrequency: ''
        }
        useCustomToken: 'false'
        disableAlerts: 'false'
      }
    }
  }
}

resource entraJoin 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: vm
  name: 'AADLoginForWindows'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.0'
    autoUpgradeMinorVersion: true
  }
  dependsOn: [
    guestAttestation
  ]
}

resource avdAgent 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: vm
  name: 'RegisterAvdAgent'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      // The script travels base64-encoded so no quoting can break it; the token stays in protected settings.
      commandToExecute: 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Invoke-Expression ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\'${base64(registrationScript)}\')))"'
    }
  }
  dependsOn: [
    entraJoin // join Entra ID first, then register
  ]
}

@description('VM resource ID.')
output vmId string = vm.id

@description('VM name.')
output vmName string = vm.name
