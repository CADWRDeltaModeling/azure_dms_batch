# Lessons Learned — Azure Batch Monitoring Pipelines (2026-09-25)

Working notes from building/deploying the generic idle-node monitoring pipeline
(`monitoring/batch_idle_node_*`) and discovering a related bug in the older
restart-stuck-pool pipeline (`monitoring/batch_pool_alert.bicep`). See
[README-monitoring.md](../README-monitoring.md) for the current architecture.

## 1. Several `Microsoft.Batch/batchAccounts` metrics have NO dimensions at all

`IdleNodeCount`, `PreemptedNodeCount`, `WaitingForStartTaskNodeCount`,
`StartTaskFailedNodeCount`, `UnusableNodeCount` (Resource Allocation category) do not
support a `poolId` dimension, despite it being easy to *write* a Bicep metric alert that
declares one — the deployment only fails at apply time:

```
BadRequest: The metric IdleNodeCount specifies a dimension poolId which was not found.
```

Confirm before relying on any dimension for a Batch account metric:

```bash
az monitor metrics list-definitions --resource <batchAccountResourceId> \
  --query "[?name.value=='IdleNodeCount'].dimensions"
# → null
```

This silently invalidates any design that assumes "one metric alert per pool" for these
metrics — they are account-wide totals only. `batch_pool_alert.bicep` has the same latent
bug (`PreemptedNodeCount`/`FailedTaskCount` with a `poolId` dimension) and was never
actually deployed/tested before this was discovered; it needs the same fix described
below before it can be trusted on a multi-pool account.

**Fix:** don't use Azure Monitor metric alerts for per-pool detection on these metrics.
Instead, poll the Batch **data-plane** "list pool node counts" API directly
(`GET https://{account}.{region}.batch.azure.com/nodecounts`, api-version
`2024-02-01.19.0`), which returns per-pool `dedicated`/`lowPriority` counts by node state
in one call per account. See `monitoring/batch_idle_node_workflow.json` for a working
implementation (Recurrence-triggered Logic App, no Azure Monitor alert involved).

## 2. Batch data-plane calls need ARM `Contributor`, not `Reader`

Azure Batch's data-plane REST API (`https://{account}.{region}.batch.azure.com/...`) does
not have its own separate RBAC role model when the account uses AAD authentication —
authorization is checked against the caller's **ARM role assignment** on the Batch
account resource. The built-in **Reader** role does not include the necessary
`dataActions` for Batch data-plane calls (pool/job reads, terminates, etc.) — only
**Contributor** (or a custom role with the matching `Microsoft.Batch/*/read` /
`.../action` dataActions) works. Confirmed by testing: a Logic App identity granted only
Reader could do ARM `GET` calls fine but would need Contributor for the `/nodecounts`
data-plane call.

## 3. Logic App `InitializeVariable` must be a top-level action

`InitializeVariable` actions cannot be nested inside `If`/`Foreach`/`Scope` actions —
deployment fails with:

```
InvalidVariableInitialization: The variable action 'X' of type 'InitializeVariable'
cannot be nested in an action of type 'Only_act_on_fired_alerts'.
```

Declare all variables in one top-level `InitializeVariable` action that runs early
(e.g. right after parsing the trigger payload), then reference/`SetVariable` them from
anywhere else in the workflow, including inside conditional branches.

## 4. `*_workflow.json` vs `*_logic_app.json` — only one of these is generated

In `monitoring/`, only `*_logic_app.json` files are compiled ARM templates
(`az bicep build` output — safe to `.gitignore`, regenerate anytime). `*_workflow.json`
files (e.g. `schism_alert_workflow.json`, `batch_idle_node_workflow.json`) are
hand-authored **source**, loaded by the corresponding `.bicep` file via
`loadJsonContent(...)` — `az bicep build` reads them as input, it does not create them.
A prior commit deleted one of these under the mistaken "it's generated" assumption and
silently broke a deployment. `.gitignore` now scopes its ignore rule to
`monitoring/*_logic_app.json` specifically (not a blanket `*.json`) to prevent recurrence.

## 5. Keep deployment-specific names out of committed setup scripts

`monitoring/setup_schism_alert.sh` and `monitoring/setup_batch_idle_alert.sh` both accept
a `--config <path>` flag that sources a plain bash file to override the script's generic
placeholder defaults (`RESOURCE_GROUP`, `LOCATION`, `BATCH_ACCOUNTS`, etc.) at run time.
Real per-deployment values live only in `monitoring/local_deploy_configs/*.sh`, which is
entirely gitignored — never committed. When onboarding a new resource group/batch
account, add a new file there rather than editing the committed script.

## 6. Verify the outer Logic App run status AND per-action status

A Logic App run can show `status: Succeeded` overall even when a nested/conditional
action inside it failed or was silently skipped in a way that hides a real problem — an
independent `Respond`/`Compose` action elsewhere in the same run can mask it. Always also
check action-level status:

```bash
az rest --method GET --url ".../runs/<runId>/actions?api-version=2016-06-01" \
  --query "value[].{name:name, status:properties.status, code:properties.code}"
```

And where possible, pull the actual action output body (not just its status) to confirm
the call returned genuine data, not just a 200 with an empty/unexpected payload.
