param batchAccountName string = 'dwrmodelingbatchaccount'
param batchStorageName string = 'dwrmodelingstore'
@secure()
param accountKey string = ''
param poolName string = 'dsm2linuxpool'
param vmSize string = 'standard_d2d_v4'
param taskSlotsPerNode int = 2 // number of tasks per node to be changed with vmSize (1 task = 1 core) usually unless you want more memory per task
param imageReference object = {
  publisher: 'openlogic'
  offer: 'centos'
  sku: '7_9'
  version: 'latest'
}
param nodeAgentSKUId string = 'batch.node.centos 7'
param targetDedicatedNodes int = 1
param startTaskScript string = 'set -e; set -o pipefail; printenv;yum install -y glibc.i686 libstdc++.i686 glibc.x86_64 libstdc++.x86_64;yum-config-manager --add-repo https://yum.repos.intel.com/2019/setup/intel-psxe-runtime-2019.repo;rpm --import https://yum.repos.intel.com/2019/setup/RPM-GPG-KEY-intel-psxe-runtime-2019;yum install -y intel-icc-runtime-32bit intel-ifort-runtime-32bit; wait'

// use existing batch account

resource batchAccount 'Microsoft.Batch/batchAccounts@2022-10-01' existing = {
  name: batchAccountName
}

resource batchPool 'Microsoft.Batch/batchAccounts/pools@2022-10-01' = {
  name: poolName
  parent: batchAccount
  properties: {
    displayName: poolName
    vmSize: vmSize
    taskSlotsPerNode: taskSlotsPerNode
    deploymentConfiguration: {
      virtualMachineConfiguration: {
        imageReference: imageReference
        nodeAgentSkuId: nodeAgentSKUId
      }
    }

    mountConfiguration: [
      {
        azureBlobFileSystemConfiguration: {
          accountName: batchStorageName
          accountKey: accountKey
          containerName: 'dsm2jobs'
          relativeMountPath: 'data'
        }
      }
    ]

    // add application packages
    applicationPackages: [
      {
        id: '${batchAccount.id}/applications/dsm2linux'
        version: '8.2.8449db2'
      }
    ]

    startTask: {
      commandLine: '/bin/bash -c "${startTaskScript}"'
      waitForSuccess: true
      // define user identity for admin
      userIdentity: {
        autoUser: {
          elevationLevel: 'Admin'
          scope: 'Pool'
        }
      }
    }

    scaleSettings: {
      fixedScale: {
        targetDedicatedNodes: targetDedicatedNodes
      }
    }
  }
}
