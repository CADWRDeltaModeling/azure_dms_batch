// ─────────────────────────────────────────────────────────────────────────────
// batch_idle_node_logic_app.bicep
//
// Generic (job-type-agnostic) idle-node notifier. Unlike the SCHISM stuck-job
// pipeline (docs/schism_alerting_setup.md), this does NOT depend on Telegraf or
// Application Insights.
//
// Runs on a 30-minute Recurrence trigger (NOT an Azure Monitor alert) because
// the relevant Batch account metrics (IdleNodeCount, WaitingForStartTaskNodeCount,
// StartTaskFailedNodeCount, UnusableNodeCount) have no dimensions at all
// (confirmed via `az monitor metrics list-definitions` — dims: null) so Azure
// Monitor cannot tell us WHICH pool is idle, only the account-wide total. The
// workflow instead polls the Batch data-plane "list pool node counts" API
// directly per configured account, finds the specific idle/stuck pool(s), and
// reads the submitter's email from that pool's own "created-by" ARM metadata
// (stamped by every dmsbatch pool.bicep template at creation time).
//
// Deploy once; re-run (redeploy) whenever batchAccountResourceIds changes to
// add/remove accounts the workflow polls, and to grant the new account's Batch
// data-plane access to this same Logic App identity.
// ─────────────────────────────────────────────────────────────────────────────

@description('Name for the Logic App')
param logicAppName string = 'batch-idle-node-handler'

@description('Azure region to deploy into')
param location string = resourceGroup().location

@description('Azure Batch account name in THIS resource group — used only for the role assignment below. Accounts in other resource groups get their role assignment via `az role assignment create` in the setup script instead.')
param batchAccountName string

@description('Full ARM resource IDs of every Batch account the workflow should poll every run (can span resource groups/subscriptions).')
param batchAccountResourceIds array = []

@description('Email address of the shared mailbox to send alerts from (e.g. batch-alerts@yourorg.com)')
param senderEmail string

// ── Logic App ────────────────────────────────────────────────────────────────

resource logicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    definition: loadJsonContent('batch_idle_node_workflow.json')
    parameters: {
      senderEmail: { value: senderEmail }
      batchAccounts: { value: batchAccountResourceIds }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Role assignment: Contributor on the Batch account
// The workflow calls the Batch DATA-PLANE "list pool node counts" API
// (https://{account}.{region}.batch.azure.com/nodecounts), which — like the
// SCHISM terminate workflow's data-plane calls — is authorized via a
// Contributor role assignment on the account (Batch does not recognize the
// built-in Reader role for data-plane reads). The pool/account ARM GETs need
// only read access, but Contributor covers both with one role assignment.
// ─────────────────────────────────────────────────────────────────────────────
resource batchAccount 'Microsoft.Batch/batchAccounts@2024-02-01' existing = {
  name: batchAccountName
}

var contributorRoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'

resource batchContributorRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(batchAccount.id, logicAppName, 'Contributor')
  scope: batchAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', contributorRoleId)
    principalId:   logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── Outputs ──────────────────────────────────────────────────────────────────

@description('Managed identity principal ID — grant Microsoft Graph Mail.Send to this ID (see docs/schism_alerting_setup.md Step 4, same process)')
output principalId string = logicApp.identity.principalId
