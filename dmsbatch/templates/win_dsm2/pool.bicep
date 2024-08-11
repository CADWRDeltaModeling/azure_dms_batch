param batchAccountName string
// pool information
param poolName string
param dmsbatchVersion string
param vmSize string
param taskSlotsPerNode int // number of tasks per node to be changed with vmSize (1 task = 1 core) usually unless you want more memory per task
param imageReference object
param nodeAgentSkuId string
param startTaskScript string
param formula string
// use existing batch account
param createdBy string
resource batchAccount 'Microsoft.Batch/batchAccounts@2023-11-01' existing = {
  name: batchAccountName
}
param appPkgs array
resource batchPool 'Microsoft.Batch/batchAccounts/pools@2023-11-01' = {
  name: poolName
  parent: batchAccount
  properties: {
    vmSize: vmSize
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
        nodeAgentSkuId: nodeAgentSkuId
      }
    }

    scaleSettings: {
      autoScale: {
        formula: formula
        evaluationInterval: 'PT5M'
      }
    }
    startTask: {
      commandLine: 'cmd /c "${startTaskScript}"' // this is windows specific
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
