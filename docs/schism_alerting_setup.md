# SCHISM Stuck-Job Alerting & Auto-Termination — Setup Guide

This guide explains the monitoring pipeline that detects stalled SCHISM simulations on
Azure Batch, notifies the job submitter by email, and automatically terminates jobs that
remain stuck for too long. It is written so a new subscription/environment can
reproduce the setup from scratch.

> **Prerequisite:** This pipeline assumes `schism_time` and related metrics are already
> flowing into Application Insights. If that telemetry isn't set up yet, start with
> [telegraf_appinsights_setup.md](telegraf_appinsights_setup.md) first, then come back here.

## What this does

Every SCHISM job reports its simulation clock (`schism_time`) to Application Insights via
Telegraf. Two independent alert pipelines watch that metric:

```
                         ┌─────────────────────────┐
customMetrics            │  schism-batch-insights  │
(schism_time)  ───────►  │  (Application Insights) │
                         └───────────┬─────────────┘
                                     │
                 ┌───────────────────┴────────────────────┐
                 │                                         │
     stuck for ~30 min                          stuck for ~90 min
                 │                                         │
                 ▼                                         ▼
   SCHISM-stuck-simulation (alert)          SCHISM-stuck-terminate (alert)
                 │                                         │
                 ▼                                         ▼
     schism-stuck-handler-ag (action group)   schism-terminate-handler-ag (action group)
                 │                                         │
                 ▼                                         ▼
       schism-stuck-handler (Logic App)      schism-terminate-handler (Logic App)
        - looks up the active job              - looks up the active job
        - emails the job submitter             - terminates the job via Batch API
                                                - emails the job submitter
```

Both Logic Apps use a **system-assigned managed identity** — no credentials are stored
anywhere. The identity is granted:
- **Contributor** on each Azure Batch account (to query/terminate jobs)
- **Mail.Send** (Microsoft Graph application permission) on a shared mailbox (to send
  notification emails)

## Files in this repository

| File | Purpose |
|---|---|
| [bicep/schism_alert_logic_app.bicep](../bicep/schism_alert_logic_app.bicep) | Deploys the notification Logic App (`schism-stuck-handler`) + its role assignment |
| [bicep/schism_alert_workflow.json](../bicep/schism_alert_workflow.json) | Workflow definition for the notification Logic App |
| [bicep/schism_terminate_logic_app.bicep](../bicep/schism_terminate_logic_app.bicep) | Deploys the termination Logic App (`schism-terminate-handler`) + its role assignment |
| `bicep/schism_terminate_workflow.json` | Workflow definition for the termination Logic App (generated locally, not committed — see below) |
| [bicep/setup_schism_alert.sh](../bicep/setup_schism_alert.sh) | End-to-end orchestration script — deploys both Logic Apps, wires up action groups and alert rules |
| [app-packages/telegraf/telegraf.conf](../app-packages/telegraf/telegraf.conf) | Telegraf config that tags each metric with `host`, `created_by`, `batch_account`, `batch_region` |
| `dmsbatch/templates/*/application_command_template.sh` | Batch task scripts — set the env vars Telegraf uses for tagging |

> **Note:** `bicep/schism_terminate_workflow.json` and `bicep/schism_alert_logic_app.json`
> (the compiled ARM template) are excluded from git via `.gitignore` because they are
> either generated artifacts or contain deployment-specific values. If you clone this repo
> fresh, `schism_terminate_workflow.json` must exist for the Bicep `loadJsonContent()` call
> to work — check with your team for the current copy, or recreate it following the
> structure of `schism_alert_workflow.json` with a `Terminate_job` HTTP POST action instead
> of the email/notify actions.

## Prerequisites

- Azure CLI (`az`) logged in to the target subscription (`az login`)
- Bicep CLI (bundled with `az`)
- An existing **Application Insights** resource that receives `schism_time` custom
  metrics — see [telegraf_appinsights_setup.md](telegraf_appinsights_setup.md) if this
  isn't set up yet
- One or more **Azure Batch accounts** running SCHISM jobs
- `Contributor` (or `Owner`) on the resource group for yourself
- A tenant admin (Global Administrator or Privileged Role Administrator) available to
  grant Microsoft Graph `Mail.Send` — this cannot be self-granted

## Step 1 — Update Telegraf so metrics carry routing tags

> See [telegraf_appinsights_setup.md](telegraf_appinsights_setup.md) for the full
> Telegraf/Application Insights setup. This step only covers the routing tags this
> alerting pipeline specifically depends on.

The Logic Apps need to know **which Batch account and region** a stuck job belongs to,
and **who submitted it**, purely from the metric data (since alerts fire independently of
any batch job context). This is done via global tags in
[telegraf.conf](../app-packages/telegraf/telegraf.conf):

```toml
[global_tags]
  created_by    = "${CREATED_BY_EMAIL}"
  batch_account = "${BATCH_ACCOUNT_NAME}"
  batch_region  = "${BATCH_REGION}"
```

These env vars are supplied inline when Telegraf is launched from the application
command template (see any `dmsbatch/templates/*/application_command_template.sh`):

```bash
CREATED_BY_EMAIL="{created_by}" \
  BATCH_ACCOUNT_NAME="$(echo $AZ_BATCH_ACCOUNT_URL | sed 's|https://\([^.]*\)\..*|\1|')" \
  BATCH_REGION="$(echo $AZ_BATCH_ACCOUNT_URL | sed 's|https://[^.]*\.\([^.]*\)\..*|\1|')" \
  SCHISM_STUDY_DIR="$AZ_BATCH_TASK_WORKING_DIR/simulations/{study_dir}" \
  telegraf --config $AZ_BATCH_APP_PACKAGE_telegraf/telegraf.conf > /dev/null 2>&1 &
```

`BATCH_ACCOUNT_NAME` / `BATCH_REGION` are parsed automatically from
`AZ_BATCH_ACCOUNT_URL`, which Azure Batch sets on every node — no manual configuration
needed per pool.

After changing `telegraf.conf`, **rebuild and re-upload the telegraf application
package** for each Batch account:

```bash
cd app-packages
source batch_app_package_and_upload.sh
package_and_upload_telegraf "telegraf" <your-batch-account> <your-resource-group>
```

You'll be prompted for your Application Insights resource name (used to look up its
instrumentation key). Repeat once per Batch account.

**Note:** Jobs submitted *before* this package was uploaded won't have these tags. The
Logic Apps detect that case and skip automated action safely (see the
"missing batch tags" branch below) rather than guessing.

## Step 2 — Configure `setup_schism_alert.sh` for your environment

Open [bicep/setup_schism_alert.sh](../bicep/setup_schism_alert.sh) and edit the
configuration block near the top:

```bash
RESOURCE_GROUP="dwrbdo_schism_rg"        # ← resource group to deploy Logic Apps into
LOCATION="eastus"                         # ← region for the alert rules

LOGIC_APP_NAME="schism-stuck-handler"
TERMINATE_APP_NAME="schism-terminate-handler"
ACTION_GROUP_NAME="schism-stuck-handler-ag"
TERMINATE_AG_NAME="schism-terminate-handler-ag"
ALERT_RULE_NAME="SCHISM-stuck-simulation"
TERMINATE_ALERT_NAME="SCHISM-stuck-terminate"
APP_INSIGHTS_NAME="schism-batch-insights"  # ← your App Insights resource name

# List every Batch account that submits SCHISM jobs
BATCH_ACCOUNTS=(
  "your-batch-account:your-resource-group"
  "your-second-batch-account:your-second-resource-group"
)
```

`SUBSCRIPTION_ID` is resolved automatically from your current `az` login context — no
need to hardcode it.

## Step 3 — Run the setup script

```bash
cd /path/to/azure_dms_batch
az login                      # if not already logged in
bash bicep/setup_schism_alert.sh skip
```

Passing `skip` deploys everything **except** working email — a placeholder sender address
is used so the Logic Apps deploy successfully. The script will:

1. Deploy `schism-stuck-handler` (Bicep)
2. Grant its managed identity **Contributor** on every Batch account listed
3. Create/update the `schism-stuck-handler-ag` action group with the Logic App webhook
4. Create/update the `SCHISM-stuck-simulation` alert rule (fires after ~30 min stuck)
5. Deploy `schism-terminate-handler` (Bicep)
6. Grant its managed identity **Contributor** on every Batch account
7. Create/update the `schism-terminate-handler-ag` action group
8. Create/update the `SCHISM-stuck-terminate` alert rule (fires after ~90 min stuck)
9. Write `bicep/it_support_vars.txt` with the values IT needs for the next step

`it_support_vars.txt` is **not committed to git** (see `.gitignore`) since it contains
subscription- and deployment-specific identifiers.

## Step 4 — Request the Mail.Send grant from your tenant admin

Email cannot be sent until a tenant administrator grants the Microsoft Graph application
permission `Mail.Send` to **both** Logic App managed identities, scoped to a specific
shared mailbox via an Exchange **Application Access Policy** (this is a least-privilege
control — without it, the identity could otherwise send mail as any user in the tenant).

Ask your admin to:

1. **Create (or identify) a shared mailbox** to send alerts from, e.g.
   `schism-alerts@yourorg.com`. No license is required for a shared mailbox.

2. **Grant `Mail.Send`** to each Logic App's managed identity. Run in Cloud Shell (or any
   session logged in as Global Admin / Privileged Role Administrator):

   ```bash
   # Look up the Microsoft Graph service principal + Mail.Send role ID (same for every tenant call)
   GRAPH_SP_ID=$(az rest --method GET \
     --url "https://graph.microsoft.com/v1.0/servicePrincipals?\$filter=appId eq '00000003-0000-0000-c000-000000000000'" \
     --query "value[0].id" -o tsv)

   MAIL_SEND_ROLE_ID=$(az rest --method GET \
     --url "https://graph.microsoft.com/v1.0/servicePrincipals/$GRAPH_SP_ID/appRoles" \
     --query "value[?value=='Mail.Send'].id | [0]" -o tsv)

   # Repeat this block once per Logic App, substituting its managed identity's principal ID
   PRINCIPAL_ID="<principalId from it_support_vars.txt or Logic App's Identity blade>"

   az rest --method POST \
     --url "https://graph.microsoft.com/v1.0/servicePrincipals/$PRINCIPAL_ID/appRoleAssignments" \
     --body "{\"principalId\":\"$PRINCIPAL_ID\",\"resourceId\":\"$GRAPH_SP_ID\",\"appRoleId\":\"$MAIL_SEND_ROLE_ID\"}"
   ```

3. **Restrict scope with an Application Access Policy** (Exchange Online PowerShell),
   once per Logic App App ID (not the same as its principal/object ID — see the Logic
   App's *Enterprise application* entry in Entra ID, or `it_support_vars.txt`):

   ```powershell
   New-ApplicationAccessPolicy `
     -AppId "<app-id-of-logic-app-service-principal>" `
     -PolicyScopeGroupId "schism-alerts@yourorg.com" `
     -AccessRight RestrictAccess `
     -Description "Restrict SCHISM Logic App to send only from schism-alerts mailbox"
   ```

Find each Logic App's principal ID and App ID with:

```bash
az resource show \
  --resource-group <your-resource-group> \
  --resource-type Microsoft.Logic/workflows \
  --name schism-stuck-handler \
  --query "identity.principalId" -o tsv

az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/<principalId>" \
  --query "{displayName:displayName, appId:appId}"
```

## Step 5 — Re-run setup with the real sender email

Once the admin confirms both grants and the access policy are in place:

```bash
bash bicep/setup_schism_alert.sh schism-alerts@yourorg.com
```

This redeploys both Logic Apps with the real sender address wired into their workflows.

## Step 6 — Test end-to-end

Send a synthetic alert payload directly to each Logic App's webhook (no need to wait for
a real stuck job):

```bash
WEBHOOK=$(az rest --method POST \
  --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/resourceGroups/<your-resource-group>/providers/Microsoft.Logic/workflows/schism-stuck-handler/triggers/When_alert_fires/listCallbackUrl?api-version=2016-06-01" \
  --query "value" -o tsv)

curl -s -X POST "$WEBHOOK" -H "Content-Type: application/json" -d '{
  "data": { "alertContext": { "condition": { "allOf": [ { "searchResults": { "rows": [ {
    "host": "test_pool_id",
    "StuckAtDays": "1.5",
    "CreatedBy": "you@yourorg.com",
    "batchAccount": "your-batch-account",
    "batchRegion": "your-region"
  } ] } } ] } } } }'
```

Check the run history in the portal: **Logic App → Run history** → open the latest run
and confirm every step succeeded (green checkmarks), including `Send_email_via_graph`.
Since `test_pool_id` doesn't exist, the workflow safely falls into its
"no active job found" branch — nothing gets terminated.

## Verifying in the Azure Portal

| Component | Where to look |
|---|---|
| Logic App + managed identity | Resource group → Logic App → **Identity** tab (Status = On) |
| Logic App run history | Resource group → Logic App → **Run history** |
| Role assignments | Batch account → **Access control (IAM)** → Role assignments (filter Type = "All" — managed identities may show as a raw GUID instead of a name) |
| Action group webhook | Monitor → Alerts → Action groups → select group → webhook receiver |
| Alert rule | Monitor → Alerts → Alert rules → select rule → check scope, KQL condition, and linked action group |
| Mail.Send permission | Entra ID → Enterprise applications → search Logic App name → **Permissions** tab → Application permissions |

## Adjusting thresholds

Both alert rules query `schism_time` from `customMetrics` and compare recent values
against an earlier baseline — if unchanged, the job is "stuck":

- **Notification** (`SCHISM-stuck-simulation`): compares last 30 min vs. previous 30 min
  (2h window) → fires after ~30 min of no progress.
- **Termination** (`SCHISM-stuck-terminate`): compares last 30 min vs. 90+ min ago (3h
  window) → fires after ~90 min of no progress, giving the job more time before
  destructive action is taken.

To change these windows, edit the `KQL_QUERY` / `KQL_TERMINATE` heredocs inside
[setup_schism_alert.sh](../bicep/setup_schism_alert.sh) and re-run the script.

## Adding a new Batch account later

1. Add it to the `BATCH_ACCOUNTS` array in `setup_schism_alert.sh`
2. Re-run `bash bicep/setup_schism_alert.sh <sender-email>` — it grants Contributor on
   any new accounts without duplicating existing role assignments
3. Rebuild/re-upload the telegraf package for the new account (Step 1 above)
