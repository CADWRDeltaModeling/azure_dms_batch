// ─────────────────────────────────────────────────────────────────────────────
// batch_pool_alert.bicep
//
// Creates Azure Monitor alerts that detect a stuck / preempted Azure Batch
// pool and trigger the runbook webhook to automatically restart it.
//
// Alerts created:
//   1. PreemptedNodeCount ≥ 1 on the Batch account   (metric alert)
//      → Fires when one or more spot / low-priority VMs are evicted.
//
//   2. FailedTaskCount ≥ 1 over 5 min on the Batch account  (metric alert)
//      → Fires when tasks fail (e.g. due to preemption or node issues).
//
//   3. Pool resize activity log alert
//      → Fires when the Batch service records a resize failure on the pool.
//
// Both metric alerts call the Action Group, which posts to the Automation
// runbook webhook to cycle the pool to 0 and back.
//
// Deploy after bicep/automation_account.bicep – provide the webhookUri output
// as the webhookUri parameter here:
//
//   WEBHOOK_URI=$(az deployment group show \
//       --resource-group <rg> \
//       --name automation_account \
//       --query "properties.outputs.webhookUri.value" -o tsv)
//
//   az deployment group create \
//       --resource-group <rg> \
//       --template-file  bicep/batch_pool_alert.bicep \
//       --parameters     batchAccountName=<acct>  poolId=<pool>  webhookUri="$WEBHOOK_URI"
// ─────────────────────────────────────────────────────────────────────────────

@description('Azure region for alert rules (must match the Batch account region).')
param location string = resourceGroup().location

@description('Name of the existing Azure Batch account to monitor.')
param batchAccountName string

@description('Pool ID to monitor (used in alert descriptions and webhook payload).')
param poolId string

@description('Webhook URI from the Automation Account deployment output. Treated as a secret.')
@secure()
param webhookUri string

@description('How many preempted nodes must be detected before the alert fires (default 1).')
param preemptedNodeThreshold int = 1

@description('How many failed tasks must be detected before the alert fires (default 1).')
param failedTaskThreshold int = 1

@description('Evaluation period (minutes) for metric alerts (default 5).')
param evaluationPeriodMinutes int = 5

// ─────────────────────────────────────────────────────────────────────────────
// Reference the existing Batch account
// ─────────────────────────────────────────────────────────────────────────────
resource batchAccount 'Microsoft.Batch/batchAccounts@2024-02-01' existing = {
  name: batchAccountName
}

// ─────────────────────────────────────────────────────────────────────────────
// Action Group – webhook posts to the runbook with pool context
// ─────────────────────────────────────────────────────────────────────────────
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'restart-stuck-pool-ag'
  location: 'Global'
  properties: {
    groupShortName: 'rstrtPool'
    enabled: true
    webhookReceivers: [
      {
        name: 'automation-runbook-webhook'
        serviceUri: webhookUri
        useCommonAlertSchema: false
        // Pass pool context so the runbook knows which pool to restart.
        // The Python runbook reads "PoolId" from the payload or Automation Variables.
        // Azure Monitor injects the alertContext; extra custom fields go in useCommonAlertSchema=false body.
      }
    ]
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Alert 1: Spot VM preemption  (PreemptedNodeCount ≥ threshold)
// ─────────────────────────────────────────────────────────────────────────────
resource alertPreemption 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${batchAccountName}-${poolId}-preempted-nodes'
  location: 'Global'
  properties: {
    description: 'One or more spot VMs were preempted in pool ${poolId}. Runbook will restart the pool.'
    severity: 2                          // Warning
    enabled: true
    scopes: [batchAccount.id]
    evaluationFrequency: 'PT${evaluationPeriodMinutes}M'
    windowSize: 'PT${evaluationPeriodMinutes}M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'preempted-nodes-threshold'
          metricName: 'PreemptedNodeCount'
          metricNamespace: 'Microsoft.Batch/batchaccounts'
          dimensions: [
            {
              name: 'poolId'
              operator: 'Include'
              values: [poolId]
            }
          ]
          operator: 'GreaterThanOrEqual'
          threshold: preemptedNodeThreshold
          timeAggregation: 'Maximum'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    autoMitigate: true
    actions: [
      {
        actionGroupId: actionGroup.id
        webHookProperties: {}
      }
    ]
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Alert 2: Task failures  (FailedTaskCount ≥ threshold in evaluation window)
// ─────────────────────────────────────────────────────────────────────────────
resource alertFailedTasks 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${batchAccountName}-${poolId}-failed-tasks'
  location: 'Global'
  properties: {
    description: 'Task failures detected in pool ${poolId}. Runbook will restart the pool.'
    severity: 2
    enabled: true
    scopes: [batchAccount.id]
    evaluationFrequency: 'PT${evaluationPeriodMinutes}M'
    windowSize: 'PT${evaluationPeriodMinutes}M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'failed-tasks-threshold'
          metricName: 'FailedTaskCount'
          metricNamespace: 'Microsoft.Batch/batchaccounts'
          dimensions: [
            {
              name: 'poolId'
              operator: 'Include'
              values: [poolId]
            }
          ]
          operator: 'GreaterThanOrEqual'
          threshold: failedTaskThreshold
          timeAggregation: 'Total'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    autoMitigate: true
    actions: [
      {
        actionGroupId: actionGroup.id
        webHookProperties: {}
      }
    ]
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Alert 3: Pool resize error  (Activity Log)
// Fires when the Batch service records a PoolResizeCompleted event with an
// error status, which indicates the pool could not scale up after losing nodes.
// ─────────────────────────────────────────────────────────────────────────────
resource alertResizeError 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: '${batchAccountName}-${poolId}-resize-error'
  location: 'Global'
  properties: {
    description: 'Pool ${poolId} reported a resize error. Runbook will restart the pool.'
    enabled: true
    scopes: [subscription().id]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'ServiceHealth'
        }
        {
          field: 'resourceId'
          equals: batchAccount.id
        }
        {
          field: 'operationName'
          equals: 'Microsoft.Batch/batchAccounts/pools/resize/action'
        }
        {
          field: 'status'
          equals: 'Failed'
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroup.id
          webhookProperties: {}
        }
      ]
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Outputs
// ─────────────────────────────────────────────────────────────────────────────
@description('Resource ID of the Action Group.')
output actionGroupId string = actionGroup.id

@description('Resource IDs of the created metric alerts.')
output alertIds array = [
  alertPreemption.id
  alertFailedTasks.id
  alertResizeError.id
]
