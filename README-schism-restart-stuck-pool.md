# Restarting a Stuck Azure Batch Pool (SCH-759)

## Problem

SCHISM jobs running on spot / low-priority Azure Batch pools can get stuck when:

1. One or more spot VMs are **preempted** (evicted) by Azure.
2. The remaining nodes continue to run but no longer make progress.
3. No new nodes are provisioned because the autoscale formula still sees "running"
   tasks.
4. The job appears active and **continues to accrue charges** even though nothing
   is computing.

The only reliable fix is to:
- Resize the pool to **0 nodes** (kills all VMs, cancels/requeues stuck tasks).
- Restore the **original autoscale formula** so the pool scales back up and tasks
  restart on fresh nodes.

This solution provides three ways to do that:

| Method | When to use |
|--------|-------------|
| **`restart_stuck_pool.sh`** | Quick on-demand bash fix from your laptop |
| **`dmsbatch restart-stuck-pool`** / `python -m dmsbatch.restart_stuck_pool` | Python / CLI, integrates with existing tooling |
| **Azure Automation + Alert** | Fully automated, runs when Azure Monitor fires an alert |

---

## Quick start – on-demand bash script

```bash
# From the repo root
chmod +x runbooks/restart_stuck_pool.sh

bash runbooks/restart_stuck_pool.sh \
    --resource-group  <my-rg>            \
    --batch-account   <my-batch-account> \
    --pool-id         <my-pool-id>
```

The script will:
1. Read the current autoscale formula from the pool.
2. Disable autoscale and resize the pool to 0 (`--node-dealloc requeue` by default,
   so stuck tasks are requeued and will restart on fresh nodes).
3. Wait up to 30 minutes for the pool to drain (configurable via `--wait-minutes`).
4. Re-enable the original autoscale formula.

### Prerequisites

- `az` CLI installed and authenticated (`az login` or managed identity).
- The caller needs **Contributor** (or at minimum **Azure Batch Data Contributor**)
  on the Batch account.

---

## On-demand Python / CLI

```bash
# Install dependencies (once)
pip install azure-identity azure-mgmt-batch

# Run via dmsbatch CLI
dmsbatch restart-stuck-pool \
    --subscription-id <sub-id>          \
    --resource-group  <my-rg>           \
    --batch-account   <my-batch-account>\
    --pool-id         <my-pool-id>

# Or via schism sub-command
dmsbatch schism restart-stuck-pool \
    --subscription-id <sub-id>          \
    --resource-group  <my-rg>           \
    --batch-account   <my-batch-account>\
    --pool-id         <my-pool-id>

# Or directly
python -m dmsbatch.restart_stuck_pool \
    --subscription-id <sub-id>          \
    --resource-group  <my-rg>           \
    --batch-account   <my-batch-account>\
    --pool-id         <my-pool-id>      \
    --wait-minutes 20                   \
    --node-dealloc requeue
```

Authentication uses `DefaultAzureCredential` — works with `az login`,
environment-variable service principals, and Managed Identity.

---

## Automated restart via Azure Alert + Runbook

### Architecture

```
Azure Batch pool (spot VMs)
  │  PreemptedNodeCount ≥ 1  OR  FailedTaskCount ≥ 1
  ▼
Azure Monitor metric alert
  │  action group
  ▼
Azure Automation webhook  (restart-stuck-pool-webhook)
  │
  ▼
Azure Automation runbook  (restart-stuck-pool / Python 3)
  │  azure-mgmt-batch via Managed Identity
  ▼
Pool cycled to 0 → autoscale restored → tasks restart
```

### Step 1 – Deploy the Automation Account

```bash
az deployment group create \
    --resource-group  <my-rg>           \
    --name            automation-account \
    --template-file   bicep/automation_account.bicep \
    --parameters \
        batchAccountName=<my-batch-account> \
        poolId=<my-pool-id>

# Save the webhook URI – it is only readable at creation time!
WEBHOOK_URI=$(az deployment group show \
    --resource-group  <my-rg> \
    --name            automation-account \
    --query "properties.outputs.webhookUri.value" \
    --output tsv)

echo "Webhook URI: $WEBHOOK_URI"
```

### Step 2 – Upload and publish the Python runbook

```bash
az automation runbook replace-content \
    --resource-group          <my-rg>                 \
    --automation-account-name schism-batch-automation \
    --name                    restart-stuck-pool       \
    --content                 @$(python -c "import dmsbatch.restart_stuck_pool as m; import inspect, pathlib; print(pathlib.Path(inspect.getfile(m)))")

az automation runbook publish \
    --resource-group          <my-rg>                 \
    --automation-account-name schism-batch-automation \
    --name                    restart-stuck-pool
```

Or supply the path to `dmsbatch/restart_stuck_pool.py` directly via `--content @<path>`.

### Step 3 – Deploy the alerts and action group

```bash
az deployment group create \
    --resource-group  <my-rg>       \
    --name            batch-alerts  \
    --template-file   bicep/batch_pool_alert.bicep \
    --parameters \
        batchAccountName=<my-batch-account> \
        poolId=<my-pool-id>                 \
        webhookUri="$WEBHOOK_URI"
```

This creates three alerts:

| Alert | Trigger | Severity |
|-------|---------|----------|
| Preempted nodes | `PreemptedNodeCount ≥ 1` | Warning |
| Failed tasks    | `FailedTaskCount ≥ 1` in 5 min window | Warning |
| Resize error    | Activity log: pool resize failed | Warning |

All three route to the same Action Group → Automation webhook.

### Overriding the pool ID per webhook call

The runbook reads `PoolId` from the webhook JSON body or from the Automation
Variable. To restart a *different* pool, post the webhook with a custom body:

```bash
curl -s -X POST "$WEBHOOK_URI" \
    -H "Content-Type: application/json" \
    -d '{"PoolId": "other-pool-id"}'
```

### Testing the runbook manually

```bash
az automation runbook start \
    --resource-group          <my-rg>                \
    --automation-account-name schism-batch-automation \
    --name                    restart-stuck-pool
```

---

## Node deallocation options

| Option | Behaviour | When to use |
|--------|-----------|-------------|
| `requeue` (default) | Cancels running tasks; they rejoin the queue | Pool restart / stuck tasks |
| `terminate` | Cancels tasks without requeue | One-off cleanup |
| `taskcompletion` | Waits for tasks to finish naturally | Graceful drain |
| `retaineddata` | Keeps task output until node is removed | Debug purposes |

---

## Files added

| File | Purpose |
|------|---------|
| `runbooks/restart_stuck_pool.sh` | On-demand bash script (uses `az` CLI) |
| `dmsbatch/restart_stuck_pool.py` | Python runbook (local CLI + Azure Automation) |
| `bicep/automation_account.bicep` | Automation Account, runbook, webhook, role assignment |
| `bicep/batch_pool_alert.bicep` | Azure Monitor alerts + Action Group |

