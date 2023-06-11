param subscriptionID string = '<subscriptionID>'
param azureImageBuilderName string = '<azureImageBuilderName>'
param stagingResourceGroupName string = '<stagingResourceGroupName>'
param location string = 'eastus'

var userIdentityId = {
    type:'UserAssigned'
    userAssignedIdentities:{
      '<imgBuilderId>': {}
    }
}

resource azureImageBuilder 'Microsoft.VirtualMachineImages/imageTemplates@2022-02-14' = {
  name: azureImageBuilderName
  location: location
  tags:{
    'created-by': 'DWR MSO'
  }
  identity: userIdentityId
  properties:{
    buildTimeoutInMinutes: 30 // default is 240
    customize: []
    distribute: []
    source: {}
    stagingResourceGroup: '/subscriptions/${subscriptionID}/resourceGroups/${stagingResourceGroupName}'
    validate: {}
    vmProfile:{
      vmSize: '<vmSize>'
      proxyVmSize: '<vmSize>'
      osDiskSizeGB: <sizeInGB>
      vnetConfig: {
        subnetId: '/subscriptions/<subscriptionID>/resourceGroups/<vnetRgName>/providers/Microsoft.Network/virtualNetworks/<vnetName>/subnets/<subnetName>'
      }
      userAssignedIdentities: [
        '/subscriptions/<subscriptionID>/resourceGroups/<identityRgName>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<identityName1>'
        '/subscriptions/<subscriptionID>/resourceGroups/<identityRgName>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<identityName2>'
        '/subscriptions/<subscriptionID>/resourceGroups/<identityRgName>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<identityName3>'
        ...
      ]
    }
  }
}
