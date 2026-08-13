param batchAccountName string
// pool information
param poolName string
param dmsbatchVersion string = 'unknown'
param vmSize string = 'Standard_HB120rs_v2'
param taskSlotsPerNode int = 1
// Resource ID of the user-assigned managed identity used for in-node package registration.
// Create it with app-packages/setup_build_identity.sh (pointed at the UserSubscription
// account/resource group), then paste the output here.
param buildIdentityResourceId string
// Azure Compute Gallery custom image (same source as alma810_customimage_usersub) - required
// because Batch's ARM image allow-list rejects this marketplace sku/version directly, and the
// plan-carrying source additionally requires this pool's Batch account to be in
// poolAllocationMode=UserSubscription.
param imageReference object = {
  id: '/subscriptions/c15db114-26b5-454c-b8f4-8a5eb5f16796/resourceGroups/dwrbdo_schism_scus_rg/providers/Microsoft.Compute/galleries/dwrmso_schism_scus_images/images/schism_alma810_hpc_gen2/versions/1.0.0'
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
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${buildIdentityResourceId}': {}
    }
  }
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
