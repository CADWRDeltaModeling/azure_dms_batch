@description('Name for the Logic App')
param logicAppName string = 'schism-stuck-handler'

@description('Azure region to deploy into')
param location string = resourceGroup().location

@description('Azure Batch account name — used only for the role assignment. Run this deployment once per Batch account.')
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
    definition: loadJsonContent('schism_alert_workflow.json')
    parameters: {}
  }
}

// ── Role assignment: Contributor on the Batch account ────────────────────────
// Contributor is needed to call Batch data-plane REST API with AAD auth.
// Scope can be tightened to a custom role with only Microsoft.Batch/*/read
// once the workflow is validated.

resource batchAccount 'Microsoft.Batch/batchAccounts@2024-02-01' existing = {
  name: batchAccountName
}

resource batchRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(batchAccount.id, logicAppName, 'Contributor')
  scope: batchAccount
  properties: {
    // Built-in Contributor role
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'b24988ac-6180-42a0-ab88-20f7382dd24c'
    )
    principalId:   logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── Outputs ──────────────────────────────────────────────────────────────────

@description('Managed identity principal ID — use this in Step 3 PowerShell if you add email later')
output principalId string = logicApp.identity.principalId

@description('Webhook URL to paste into the Azure Monitor alert action group')
#disable-next-line outputs-should-not-contain-secrets
output webhookUrl string = listCallbackUrl(
  resourceId('Microsoft.Logic/workflows/triggers', logicAppName, 'When_alert_fires'),
  '2019-05-01'
).value
