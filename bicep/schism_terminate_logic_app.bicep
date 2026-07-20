@description('Name for the termination Logic App')
param logicAppName string = 'schism-terminate-handler'

@description('Azure region to deploy into')
param location string = resourceGroup().location

@description('Azure Batch account name — used for the role assignment. Run once per Batch account.')
param batchAccountName string

// ── Logic App ────────────────────────────────────────────────────────────────

resource logicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    definition: loadJsonContent('schism_terminate_workflow.json')
    parameters: {}
  }
}

// ── Role assignment: Contributor on the Batch account ────────────────────────
// Contributor is required to call the Batch data-plane terminate endpoint.

resource batchAccount 'Microsoft.Batch/batchAccounts@2024-02-01' existing = {
  name: batchAccountName
}

resource batchRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(batchAccount.id, logicAppName, 'Contributor')
  scope: batchAccount
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'b24988ac-6180-42a0-ab88-20f7382dd24c'
    )
    principalId:   logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── Outputs ──────────────────────────────────────────────────────────────────

output principalId string = logicApp.identity.principalId

#disable-next-line outputs-should-not-contain-secrets
output webhookUrl string = listCallbackUrl(
  resourceId('Microsoft.Logic/workflows/triggers', logicAppName, 'When_alert_fires'),
  '2019-05-01'
).value
