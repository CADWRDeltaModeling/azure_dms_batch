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
param imageReference object = {
  publisher: 'almalinux'
  offer: 'almalinux-hpc'
  sku: '8-hpc-gen2'
  version: 'latest'
}
param nodeAgentSKUId string = 'batch.node.el 8'
param startTaskScript string =  'printenv'
param formula string = '$TargetDedicatedNodes = 0'
// app insights info
param appInsightsInstrumentationKey string = ''
param appInsightsAppId string = ''

// use existing batch account

resource batchAccount 'Microsoft.Batch/batchAccounts@2023-11-01' existing = {
  name: batchAccountName
}

resource batchPool 'Microsoft.Batch/batchAccounts/pools@2023-11-01' = {
  name: poolName
  parent: batchAccount
  properties: {
    vmSize: vmSize
    interNodeCommunication: 'Enabled'
    taskSlotsPerNode: taskSlotsPerNode
    taskSchedulingPolicy: {
      nodeFillType: 'Pack'
    }

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
      environmentSettings: [
         { name: 'APP_INSIGHTS_INSTRUMENTATION_KEY',  value: appInsightsInstrumentationKey }
         { name: 'APP_INSIGHTS_APP_ID', value: appInsightsAppId  }
      ]
      maxTaskRetryCount: 0
      waitForSuccess: true
    }
    applicationPackages: [
      {
        id: '${batchAccount.id}/applications/schism'
        version: '5.11.alma8.7'
      }
      {
        id: '${batchAccount.id}/applications/batch_setup'
        version: 'alma8.7'
      }
    ]
  }
}
