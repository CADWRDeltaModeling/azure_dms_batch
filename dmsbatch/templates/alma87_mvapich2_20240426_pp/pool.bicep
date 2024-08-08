param batchAccountName string
param storageAccountName string
param storageContainerName string
@secure()
param storageAccountKey string = ''
// pool information
param poolName string
param vmSize string = 'Standard_HB120rs_v2' //'STANDARD_HC44rs' or 
param taskSlotsPerNode int = 1 // number of tasks per node to be changed with vmSize (1 task = 1 core) usually unless you want more memory per task
// param targetDedicatedNodes int = 2 // number of nodes to be changed with vmSize - now in the autoscaling formula
// image pinned to this version. See https://github.com/Azure/azhpc-images/releases
param imageReference object = {
  publisher: 'almalinux'
  offer: 'almalinux-hpc'
  sku: '8-hpc-gen2'
  version: '8.7.2024042601'
}
param nodeAgentSKUId string = 'batch.node.el 8'
param startTaskScript string =  'printenv'
param formula string = '$TargetDedicatedNodes = 0'
// use existing batch account
param createdBy string = ''
param appPkgs array = [ // array of application packages

]
resource batchAccount 'Microsoft.Batch/batchAccounts@2023-11-01' existing = {
  name: batchAccountName
}

resource batchPool 'Microsoft.Batch/batchAccounts/pools@2023-11-01' = {
  name: poolName
  parent: batchAccount
  properties: {
    vmSize: vmSize
    taskSlotsPerNode: taskSlotsPerNode
    taskSchedulingPolicy: {
      nodeFillType: 'Spread'
    }
    
    metadata: [
      { name: 'created-by', value: createdBy }
    ]
    
    mountConfiguration: [
      {
        azureBlobFileSystemConfiguration: {
          accountName: storageAccountName
          accountKey: storageAccountKey
          containerName: storageContainerName
          relativeMountPath: storageContainerName
          blobfuseOptions: '--allow-other'
        }
      }
    ]

    deploymentConfiguration: {
      virtualMachineConfiguration: {
        imageReference: imageReference
        nodeAgentSkuId: nodeAgentSKUId
      }
    }

    scaleSettings: {
      autoScale: {
        formula: formula
        evaluationInterval: 'PT5M'
      }
    }
    startTask: {
      commandLine: '/bin/bash -c "${startTaskScript}"' // this is a bash script
      userIdentity: {
        autoUser: {
          scope: 'Pool'
          elevationLevel: 'Admin' // has to be admin to install software
        }
      }
      maxTaskRetryCount: 0
      waitForSuccess: true
    }
    applicationPackages: [for pkg in appPkgs: {
      id: resourceId('Microsoft.Batch/batchAccounts/applications', batchAccountName, pkg.name)
      version: pkg.?version
    }]
  }
}
