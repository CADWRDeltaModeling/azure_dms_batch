param batchAccountName string
// pool information
param poolName string
param dmsbatchVersion string = 'unknown'
param vmSize string = 'Standard_HB120rs_v3'
param taskSlotsPerNode int = 1
// AlmaLinux 8.10 HPC — same image as alma810_mvapich2_latest_hbv3
param imageReference object = {
  publisher: 'almalinux'
  offer: 'almalinux-hpc'
  sku: '8-hpc-gen2'
  version: '8.10.202505290'
}
param nodeAgentSKUId string = 'batch.node.el 8'
param startTaskScript string = 'printenv && $AZ_BATCH_APP_PACKAGE_batch_setup/batch/pool_setup_alma8_hpcx.sh'
param formula string = '$TargetDedicatedNodes = 0'
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
    interNodeCommunication: 'Disabled'
    taskSlotsPerNode: taskSlotsPerNode
    taskSchedulingPolicy: {
      nodeFillType: 'Pack'
    }

    metadata: [
      { name: 'created-by', value: createdBy }
      { name: 'dmsbatch-version', value: dmsbatchVersion }
    ]

    // No blob fuse mount needed — build job uploads via azcopy
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
      commandLine: '/bin/bash -c "${startTaskScript}"'
      userIdentity: {
        autoUser: {
          scope: 'Pool'
          elevationLevel: 'Admin'
        }
      }
      maxTaskRetryCount: 0
      waitForSuccess: true
    }
    applicationPackages: [
      for pkg in appPkgs: {
        id: '${batchAccount.id}/applications/${pkg.name}'
        version: pkg.?version
      }
    ]
  }
}
