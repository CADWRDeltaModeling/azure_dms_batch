// ─────────────────────────────────────────────────────────────────────────────
// automation_account.bicep
//
// Deploys everything needed to restart a stuck Azure Batch pool on demand or
// in response to an Azure Monitor alert:
//
//   • Azure Automation Account (system-assigned Managed Identity)
//   • Four Automation Variables  (SubscriptionId, ResourceGroup,
//     BatchAccountName, PoolId)
//   • Python 3 runbook  "restart-stuck-pool"
//   • Runbook webhook   (URI emitted as a sensitive output)
//   • Role assignment   (Contributor on the Batch Account) for the MI
//
// After deploying, upload and publish the runbook script:
//
//   az automation runbook replace-content \
//       --resource-group          <rg>               \
//       --automation-account-name <account-name>     \
//       --name                    restart-stuck-pool  \
//       --content                 @<path-to-dmsbatch/restart_stuck_pool.py>
//
//   az automation runbook publish \
//       --resource-group          <rg>               \
//       --automation-account-name <account-name>     \
//       --name                    restart-stuck-pool
//
// ─────────────────────────────────────────────────────────────────────────────

@description('Azure region for the Automation Account.')
param location string = resourceGroup().location

@description('Name for the new Automation Account.')
param automationAccountName string = 'schism-batch-automation'

@description('Subscription ID that holds the Batch account.')
param batchSubscriptionId string = subscription().subscriptionId

@description('Resource group that holds the Batch account.')
param batchResourceGroup string = resourceGroup().name

@description('Name of the Azure Batch account.')
param batchAccountName string

@description('Default pool ID to restart. Can be overridden at webhook call-time via JSON payload.')
param poolId string

@description('How long before the webhook URI expires (ISO 8601 duration, default 5 years).')
param webhookExpiryDuration string = 'P5Y'

@description('Deployment timestamp used to compute the webhook expiry — do not override; utcNow() is only valid as a parameter default.')
param _deploymentTimeUtc string = utcNow()

// ─────────────────────────────────────────────────────────────────────────────
// Automation Account
// ─────────────────────────────────────────────────────────────────────────────
resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
    publicNetworkAccess: true
    disableLocalAuth: false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Automation Variables (shared parameters for the runbook)
// ─────────────────────────────────────────────────────────────────────────────
resource varSubscriptionId 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  name: 'SubscriptionId'
  parent: automationAccount
  properties: {
    value: '"${batchSubscriptionId}"'
    isEncrypted: false
    description: 'Azure subscription that contains the Batch account'
  }
}

resource varResourceGroup 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  name: 'ResourceGroup'
  parent: automationAccount
  properties: {
    value: '"${batchResourceGroup}"'
    isEncrypted: false
    description: 'Resource group that contains the Batch account'
  }
}

resource varBatchAccountName 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  name: 'BatchAccountName'
  parent: automationAccount
  properties: {
    value: '"${batchAccountName}"'
    isEncrypted: false
    description: 'Azure Batch account name'
  }
}

resource varPoolId 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  name: 'PoolId'
  parent: automationAccount
  properties: {
    value: '"${poolId}"'
    isEncrypted: false
    description: 'Default pool ID to restart. Can be overridden in webhook payload.'
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Python 3 runbook (created in Draft state; content uploaded post-deploy)
// ─────────────────────────────────────────────────────────────────────────────
resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  name: 'restart-stuck-pool'
  parent: automationAccount
  location: location
  properties: {
    runbookType: 'Python3'
    logProgress: true
    logVerbose: false
    description: 'Restart a stuck Azure Batch pool by cycling its scale to 0 and back to autoscale.'
    // publishContentLink is set after deploy via `az automation runbook replace-content` + publish
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Webhook  (URI is ONLY readable at creation time – capture the output!)
// ─────────────────────────────────────────────────────────────────────────────
resource webhook 'Microsoft.Automation/automationAccounts/webhooks@2015-10-31' = {
  name: 'restart-stuck-pool-webhook'
  parent: automationAccount
  properties: {
    isEnabled: true
    expiryTime: dateTimeAdd(_deploymentTimeUtc, webhookExpiryDuration)
    runbook: {
      name: runbook.name
    }
    // parameters passed as JSON body from Azure Monitor action group
    parameters: {}
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Role assignment: Contributor on the Batch account for the Automation MI
//
// Contributor (b24988ac-6180-42a0-ab88-20f7382dd24c) lets the runbook call
// the Azure Batch Management API to update pool scale settings.
//
// Assumes the Batch account lives in the SAME resource group as this
// deployment (like every other bicep file in this repo) — batchResourceGroup
// is still recorded as an Automation Variable for the runbook's own use, but
// is not used to cross-scope this resource (Bicep requires a nested module
// for that, which isn't worth the complexity here). Batch accounts in other
// resource groups get their role assignment via `az role assignment create`
// in the setup script instead, same as the other monitoring pipelines.
// ─────────────────────────────────────────────────────────────────────────────
resource batchAccount 'Microsoft.Batch/batchAccounts@2024-02-01' existing = {
  name: batchAccountName
}

var contributorRoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(automationAccount.id, batchAccount.id, contributorRoleId)
  scope: batchAccount
  properties: {
    principalId: automationAccount.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', contributorRoleId)
    principalType: 'ServicePrincipal'
    description: 'Allow Automation Account MI to manage Batch pool scale settings'
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Outputs
// ─────────────────────────────────────────────────────────────────────────────
@description('Principal ID of the Automation Account Managed Identity.')
output automationManagedIdentityPrincipalId string = automationAccount.identity.principalId

@description('Webhook URI – SAVE THIS NOW, it will not be retrievable again.')
@secure()
output webhookUri string = webhook.properties.uri

@description('Automation Account resource ID.')
output automationAccountId string = automationAccount.id
