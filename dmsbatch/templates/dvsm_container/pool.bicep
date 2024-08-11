param batchAccountName string
// pool information
param poolName string
param dmsbatchVersion string
param vmSize string = 'Standard_DS5_v2'
param taskSlotsPerNode int = 1 // number of tasks per node to be changed with vmSize (1 task = 1 core) usually unless you want more memory per task
// param targetDedicatedNodes int = 2 // number of nodes to be changed with vmSize - now in the autoscaling formula
// image pinned to this version. See https://github.com/Azure/azhpc-images/releases
param imageReference object = {
  publisher: 'microsoft-dsvm'
  offer: 'ubuntu-hpc'
  sku: '2204'
  version: 'latest'
}
param nodeAgentSKUId string = 'batch.node.ubuntu 22.04'
param startTaskScript string =  'printenv'
param formula string = '$TargetDedicatedNodes = 0'
// use existing batch account
param createdBy string = ''
param containerImageName string
resource batchAccount 'Microsoft.Batch/batchAccounts@2023-11-01' existing = {
  name: batchAccountName
}
param appPkgs array

resource batchPool 'Microsoft.Batch/batchAccounts/pools@2023-11-01' = {
  name: poolName
  parent: batchAccount
  properties: {
    vmSize: vmSize
    interNodeCommunication: 'Disabled'
    taskSlotsPerNode: taskSlotsPerNode
    taskSchedulingPolicy: {
      nodeFillType: 'Pack'
    }
    
    metadata: [
      { name: 'created-by', value: createdBy }
      { name: 'dmsbatch-version', value: dmsbatchVersion }
    ]
    
    deploymentConfiguration: {
      virtualMachineConfiguration: {
        imageReference: imageReference
        nodeAgentSkuId: nodeAgentSKUId
        containerConfiguration:{ 
          type: 'DockerCompatible'
          containerImageNames: [
            containerImageName
          ]
        }
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
    applicationPackages: [
      for pkg in appPkgs:{
        id: '${batchAccount.id}/applications/${pkg.name}'
        version: pkg.?version 
      }
    ]
  }
}
