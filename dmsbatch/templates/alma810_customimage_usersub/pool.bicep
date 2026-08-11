param batchAccountName string
param storageAccountName string
param storageContainerName string
@secure()
param storageAccountKey string = ''
// pool information
param poolName string
param dmsbatchVersion string = 'unknown'
param vmSize string = 'Standard_HB120rs_v2' //'STANDARD_HC44rs' or 
param taskSlotsPerNode int = 1 // number of tasks per node to be changed with vmSize (1 task = 1 core) usually unless you want more memory per task
// Azure Compute Gallery custom image captured from almalinux-hpc:8_10-hpc-gen2:8.10.2024101801
// (that marketplace sku/version combo is rejected outright by Batch's ARM image allow-list, so it
// must be consumed as a gallery "custom image" instead - which in turn requires this pool's Batch
// account to be in poolAllocationMode=UserSubscription, since the source carries a Marketplace plan).
// NOTE: fill in the exact version once the AIB build (imageForAlma810HBv2Scus) finishes - placeholder below.
param imageReference object = {
  id: '/subscriptions/c15db114-26b5-454c-b8f4-8a5eb5f16796/resourceGroups/dwrbdo_schism_scus_rg/providers/Microsoft.Compute/galleries/dwrmso_schism_scus_images/images/schism_alma810_hpc_gen2/versions/1.0.0'
}
param nodeAgentSKUId string = 'batch.node.el 8'
param startTaskScript string =  'printenv'
param formula string = '$TargetDedicatedNodes = 0'
// use existing batch account
param createdBy string = ''
param appPkgs array
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
    
    metadata: [
      { name: 'created-by', value: createdBy }
      { name: 'dmsbatch-version', value: dmsbatchVersion }
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
    applicationPackages: [
      for pkg in appPkgs:{
        id: '${batchAccount.id}/applications/${pkg.name}'
        version: pkg.?version
      }
    ]
  }
}
