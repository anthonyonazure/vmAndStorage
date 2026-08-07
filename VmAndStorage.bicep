// example az cli cmd:  az deployment group create --resource-group testRG --template-file ./VMandStorage.bicep --parameters vmName='myVM' storageAccountName='sa2938'
param location string = 'westus' // You can change the location as needed
param vmName string = 'myVM'
param storageAccountName string = 'testRG' // Storage account names must be globally unique and lowercase

param adminUsername string = 'adminuser'

// The admin password is supplied at deployment time and never stored in source.
// @secure() also keeps it out of the deployment history in the Azure portal.
@secure()
param adminPassword string

// Generate a unique storage account name
var uniqueStorageAccountName = toLower('${storageAccountName}${uniqueString(resourceGroup().id)}')

// Network components for the VM
resource vnet 'Microsoft.Network/virtualNetworks@2020-06-01' = {
  name: 'myVNet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'mySubnet'
        properties: {
          addressPrefix: '10.0.0.0/24'
        }
      }
    ]
  }
}

resource publicIP 'Microsoft.Network/publicIPAddresses@2020-06-01' = {
  name: 'myPublicIP'
  location: location
  properties: {
    publicIPAllocationMethod: 'Dynamic'
  }
}

resource networkInterface 'Microsoft.Network/networkInterfaces@2020-06-01' = {
  name: 'myNIC'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: publicIP.id
          }
        }
      }
    ]
  }
}

// Virtual Machine with a System Assigned Managed Identity
resource virtualMachine 'Microsoft.Compute/virtualMachines@2020-06-01' = {
  // CKV_AZURE_178 checks for a Linux SSH public key under osProfile.linuxConfiguration.
  // This VM runs Windows Server (see imageReference below), so there is no Linux
  // configuration block to attach an SSH key to. The check is not applicable here.
  //checkov:skip=CKV_AZURE_178:Windows Server VM — linuxConfiguration/ssh does not apply
  name: vmName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    securityProfile: {
      // Encrypts the OS disk, data disks and temp disk on the host itself,
      // covering CKV_AZURE_151 and CKV_AZURE_97.
      encryptionAtHost: true
    }
    hardwareProfile: {
      vmSize: 'Standard_DS1_v2' // Change as needed
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2019-Datacenter'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      // This template installs no VM extensions. Leaving extension operations
      // enabled would let anyone with VM-contributor rights run arbitrary code
      // on the guest, so the agent is told to refuse them (CKV_AZURE_50).
      allowExtensionOperations: false
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface.id
        }
      ]
    }
  }
}

// Storage Account
resource storageAccount 'Microsoft.Storage/storageAccounts@2021-04-01' = {
  // CKV_AZURE_43 compares the account name against ^[a-z0-9]{3,24}$ as a literal
  // string. This name is built at deploy time from uniqueString(), which is the
  // documented way to get a globally unique account name, so checkov has nothing
  // literal to match. The bicep compiler already enforces the real length rules.
  //checkov:skip=CKV_AZURE_43:name is computed by uniqueString() at deploy time, not a literal
  name: uniqueStorageAccountName
  location: location
  sku: {
    // Geo-redundant rather than locally redundant, so a single-region failure
    // does not lose the data (CKV_AZURE_206).
    name: 'Standard_GRS'
  }
  kind: 'StorageV2'
  properties: {
    // Reject anything below TLS 1.2 (CKV_AZURE_44).
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      // Closed by default: nothing reaches the account unless it is explicitly
      // allowed here or is a trusted Azure service (CKV_AZURE_35).
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = {
  name: guid(resourceGroup().id, storageAccount.name, 'Storage Blob Data Contributor')
  dependsOn: [
    virtualMachine // Ensure this role assignment waits for the VM to be fully provisioned
  ]
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe') // Storage Blob Data Contributor
    principalId: virtualMachine.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
