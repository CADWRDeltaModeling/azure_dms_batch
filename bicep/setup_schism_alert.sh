#!/usr/bin/env bash
# =============================================================================
# setup_schism_alert.sh
#
# Sets up the SCHISM stuck-job alerting pipeline end-to-end:
#   1. Deploy Logic App (schism-stuck-handler) via Bicep
#   2. Grant Logic App managed identity Contributor on each Batch account
#   3. Create/update action group with Logic App webhook
#   4. Create/update scheduled-query alert rule on schism-batch-insights
#   5. Save IT-support variables to it_support_vars.txt
#
# Usage:
#   cd /scratch/psandhu/azure_dms_batch
#   module load azure_cli
#   bash bicep/setup_schism_alert.sh [sender_email]
#
#   sender_email – the shared mailbox to send alerts FROM (e.g. schism-alerts@water.ca.gov)
#                  Required only after IT grants Mail.Send permission.
#                  Pass "skip" to skip email setup for now.
# =============================================================================
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
# Update these values for your deployment before running.
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
RESOURCE_GROUP="dwrbdo_schism_rg"
LOCATION="eastus"

LOGIC_APP_NAME="schism-stuck-handler"
TERMINATE_APP_NAME="schism-terminate-handler"
ACTION_GROUP_NAME="schism-stuck-handler-ag"
TERMINATE_AG_NAME="schism-terminate-handler-ag"
ALERT_RULE_NAME="SCHISM-stuck-simulation"
TERMINATE_ALERT_NAME="SCHISM-stuck-terminate"
APP_INSIGHTS_NAME="schism-batch-insights"

# Batch accounts to grant access to (space-separated: "accountName:resourceGroup")
BATCH_ACCOUNTS=(
  "schismbatch:dwrbdo_schism_rg"
  "schismbatchscus:dwrbdo_schism_scus_rg"
)

SENDER_EMAIL="${1:-skip}"
IT_SUPPORT_FILE="bicep/it_support_vars.txt"
# ──────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
step() { echo; echo "══════════════════════════════════════════════"; echo "  $*"; echo "══════════════════════════════════════════════"; }

# ── Step 1: Deploy Logic App ───────────────────────────────────────────────────
step "1/5  Deploying Logic App via Bicep"

BICEP_PARAMS="batchAccountName=schismbatch"
if [[ "$SENDER_EMAIL" != "skip" ]]; then
  BICEP_PARAMS="$BICEP_PARAMS senderEmail=$SENDER_EMAIL"
else
  # Use a placeholder — can be updated later with another deploy
  BICEP_PARAMS="$BICEP_PARAMS senderEmail=placeholder@placeholder.com"
  log "WARNING: senderEmail set to placeholder. Re-run with real address after IT grants Mail.Send."
fi

az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$SCRIPT_DIR/schism_alert_logic_app.bicep" \
  --parameters $BICEP_PARAMS \
  --query "properties.provisioningState" \
  --output tsv

PRINCIPAL_ID=$(az resource show \
  --resource-group "$RESOURCE_GROUP" \
  --resource-type Microsoft.Logic/workflows \
  --name "$LOGIC_APP_NAME" \
  --query "identity.principalId" -o tsv)

log "Logic App principal ID: $PRINCIPAL_ID"

# ── Step 2: Grant Contributor on each Batch account ───────────────────────────
step "2/5  Granting Logic App access to Batch accounts"

for ENTRY in "${BATCH_ACCOUNTS[@]}"; do
  ACCOUNT="${ENTRY%%:*}"
  RG="${ENTRY##*:}"
  SCOPE="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG/providers/Microsoft.Batch/batchAccounts/$ACCOUNT"
  ROLE_NAME="Contributor"
  ROLE_ID="b24988ac-6180-42a0-ab88-20f7382dd24c"

  # Check if already assigned
  EXISTING=$(az role assignment list \
    --scope "$SCOPE" \
    --assignee "$PRINCIPAL_ID" \
    --query "[?roleDefinitionId contains '$ROLE_ID'].id | [0]" \
    -o tsv 2>/dev/null || true)

  if [[ -n "$EXISTING" ]]; then
    log "  ✓ Already has $ROLE_NAME on $ACCOUNT — skipping"
  else
    az role assignment create \
      --assignee "$PRINCIPAL_ID" \
      --role "$ROLE_NAME" \
      --scope "$SCOPE" \
      --output none
    log "  ✓ Granted $ROLE_NAME on $ACCOUNT"
  fi
done

# ── Step 3: Get fresh webhook URL ─────────────────────────────────────────────
step "3/5  Wiring action group to Logic App webhook"

WEBHOOK_URL=$(az rest \
  --method POST \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Logic/workflows/$LOGIC_APP_NAME/triggers/When_alert_fires/listCallbackUrl?api-version=2016-06-01" \
  --query "value" -o tsv)

log "Webhook URL obtained"

AG_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/microsoft.insights/actionGroups/$ACTION_GROUP_NAME"

az rest --method PUT \
  --url "https://management.azure.com${AG_ID}?api-version=2023-01-01" \
  --body "{
    \"location\": \"global\",
    \"properties\": {
      \"groupShortName\": \"schismag\",
      \"enabled\": true,
      \"webhookReceivers\": [{
        \"name\": \"LogicApp\",
        \"serviceUri\": \"${WEBHOOK_URL}\",
        \"useCommonAlertSchema\": true
      }]
    }
  }" --output none

log "  ✓ Action group $ACTION_GROUP_NAME updated"

# ── Step 4: Create/update scheduled-query alert rule ──────────────────────────
step "4/5  Creating/updating alert rule on $APP_INSIGHTS_NAME"

APP_INSIGHTS_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/microsoft.insights/components/$APP_INSIGHTS_NAME"

KQL_QUERY=$(cat <<'KQLEOF'
customMetrics
| where name == 'schism_time'
| where timestamp >= ago(2h)
| extend host         = tostring(parse_json(customDimensions).host)
| extend created_by   = tostring(parse_json(customDimensions).created_by)
| extend batchAccount = tostring(parse_json(customDimensions).batch_account)
| extend batchRegion  = tostring(parse_json(customDimensions).batch_region)
| summarize
    CurrentSchismTime  = maxif(value, timestamp >= ago(30m)),
    PreviousSchismTime = maxif(value, timestamp < ago(30m)),
    CurrentCount       = countif(timestamp >= ago(30m)),
    PreviousCount      = countif(timestamp < ago(30m)),
    CreatedBy          = any(created_by),
    batchAccount       = any(batchAccount),
    batchRegion        = any(batchRegion)
  by host
| where CurrentCount > 0 and PreviousCount > 0
| where CurrentSchismTime == PreviousSchismTime
| extend StuckAtDays = round(CurrentSchismTime / 86400.0, 1)
| project host, CreatedBy, StuckAtDays, CurrentSchismTime, batchAccount, batchRegion
KQLEOF
)

KQL_JSON=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$KQL_QUERY")

az rest --method PUT \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Insights/scheduledQueryRules/$ALERT_RULE_NAME?api-version=2022-08-01-preview" \
  --body "{
    \"location\": \"$LOCATION\",
    \"properties\": {
      \"description\": \"Fires when a SCHISM job has not advanced simulation time in 30 minutes\",
      \"severity\": 2,
      \"enabled\": true,
      \"scopes\": [\"${APP_INSIGHTS_ID}\"],
      \"evaluationFrequency\": \"PT30M\",
      \"windowSize\": \"PT2H\",
      \"criteria\": {
        \"allOf\": [{
          \"query\": ${KQL_JSON},
          \"timeAggregation\": \"Count\",
          \"operator\": \"GreaterThan\",
          \"threshold\": 0,
          \"failingPeriods\": {
            \"numberOfEvaluationPeriods\": 1,
            \"minFailingPeriodsToAlert\": 1
          }
        }]
      },
      \"actions\": {
        \"actionGroups\": [\"${AG_ID}\"]
      }
    }
  }" --output none

log "  ✓ Alert rule $ALERT_RULE_NAME created/updated"

# ── Step 4b: Deploy termination Logic App ─────────────────────────────────────
step "4b/5  Deploying termination Logic App"

az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$SCRIPT_DIR/schism_terminate_logic_app.bicep" \
  --parameters batchAccountName=schismbatch \
  --query "properties.provisioningState" \
  --output tsv

TERMINATE_PRINCIPAL_ID=$(az resource show \
  --resource-group "$RESOURCE_GROUP" \
  --resource-type Microsoft.Logic/workflows \
  --name "$TERMINATE_APP_NAME" \
  --query "identity.principalId" -o tsv)

log "  Terminate Logic App principal ID: $TERMINATE_PRINCIPAL_ID"

# Grant termination Logic App access to all batch accounts
for ENTRY in "${BATCH_ACCOUNTS[@]}"; do
  ACCOUNT="${ENTRY%%:*}"
  RG="${ENTRY##*:}"
  SCOPE="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG/providers/Microsoft.Batch/batchAccounts/$ACCOUNT"
  EXISTING=$(az role assignment list \
    --scope "$SCOPE" \
    --assignee "$TERMINATE_PRINCIPAL_ID" \
    --query "[?roleDefinitionId contains 'b24988ac'].id | [0]" \
    -o tsv 2>/dev/null || true)
  if [[ -n "$EXISTING" ]]; then
    log "  ✓ Already has Contributor on $ACCOUNT — skipping"
  else
    az role assignment create \
      --assignee "$TERMINATE_PRINCIPAL_ID" \
      --role "Contributor" \
      --scope "$SCOPE" \
      --output none
    log "  ✓ Granted Contributor on $ACCOUNT"
  fi
done

TERMINATE_WEBHOOK=$(az rest \
  --method POST \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Logic/workflows/$TERMINATE_APP_NAME/triggers/When_alert_fires/listCallbackUrl?api-version=2016-06-01" \
  --query "value" -o tsv)

TERMINATE_AG_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/microsoft.insights/actionGroups/$TERMINATE_AG_NAME"

az rest --method PUT \
  --url "https://management.azure.com${TERMINATE_AG_ID}?api-version=2023-01-01" \
  --body "{
    \"location\": \"global\",
    \"properties\": {
      \"groupShortName\": \"schtermag\",
      \"enabled\": true,
      \"webhookReceivers\": [{
        \"name\": \"TerminateLogicApp\",
        \"serviceUri\": \"${TERMINATE_WEBHOOK}\",
        \"useCommonAlertSchema\": true
      }]
    }
  }" --output none

log "  ✓ Termination action group $TERMINATE_AG_NAME created/updated"

# Alert rule: wider KQL window — compares last 30 min against 90+ min ago
# Only fires if schism_time is identical across a 60-min gap => stuck for ≥90 min
KQL_TERMINATE=$(cat <<'KQLEOF'
customMetrics
| where name == 'schism_time'
| where timestamp >= ago(3h)
| extend host         = tostring(parse_json(customDimensions).host)
| extend created_by   = tostring(parse_json(customDimensions).created_by)
| extend batchAccount = tostring(parse_json(customDimensions).batch_account)
| extend batchRegion  = tostring(parse_json(customDimensions).batch_region)
| summarize
    CurrentSchismTime  = maxif(value, timestamp >= ago(30m)),
    BaselineSchismTime = maxif(value, timestamp between (ago(3h) .. ago(90m))),
    CurrentCount       = countif(timestamp >= ago(30m)),
    BaselineCount      = countif(timestamp between (ago(3h) .. ago(90m))),
    CreatedBy          = any(created_by),
    batchAccount       = any(batchAccount),
    batchRegion        = any(batchRegion)
  by host
| where CurrentCount > 0 and BaselineCount > 0
| where CurrentSchismTime == BaselineSchismTime
| extend StuckAtDays = round(CurrentSchismTime / 86400.0, 1)
| project host, CreatedBy, StuckAtDays, CurrentSchismTime, batchAccount, batchRegion
KQLEOF
)
KQL_TERMINATE_JSON=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$KQL_TERMINATE")

az rest --method PUT \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Insights/scheduledQueryRules/$TERMINATE_ALERT_NAME?api-version=2022-08-01-preview" \
  --body "{
    \"location\": \"$LOCATION\",
    \"properties\": {
      \"description\": \"Terminates SCHISM job after schism_time stagnant for 90+ minutes\",
      \"severity\": 1,
      \"enabled\": true,
      \"scopes\": [\"${APP_INSIGHTS_ID}\"],
      \"evaluationFrequency\": \"PT30M\",
      \"windowSize\": \"PT3H\",
      \"criteria\": {
        \"allOf\": [{
          \"query\": ${KQL_TERMINATE_JSON},
          \"timeAggregation\": \"Count\",
          \"operator\": \"GreaterThan\",
          \"threshold\": 0,
          \"failingPeriods\": {
            \"numberOfEvaluationPeriods\": 1,
            \"minFailingPeriodsToAlert\": 1
          }
        }]
      },
      \"actions\": {
        \"actionGroups\": [\"${TERMINATE_AG_ID}\"]
      }
    }
  }" --output none

log "  ✓ Termination alert rule $TERMINATE_ALERT_NAME created/updated"

# ── Step 5: Save IT support variables ─────────────────────────────────────────
step "5/5  Saving IT support variables"

GRAPH_SP_ID=$(az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals?\$filter=appId eq '00000003-0000-0000-c000-000000000000'" \
  --query "value[0].id" -o tsv 2>/dev/null || echo "GRAPH_API_CALL_FAILED")

MAIL_SEND_ROLE_ID=$(az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$GRAPH_SP_ID/appRoles" \
  --query "value[?value=='Mail.Send'].id | [0]" -o tsv 2>/dev/null || echo "GRAPH_API_CALL_FAILED")

cat > "$REPO_ROOT/$IT_SUPPORT_FILE" <<ITEOF
# IT Support variables for granting Mail.Send to the SCHISM Logic App
# Generated: $(date)
#
# Ask your Azure AD admin (Global Admin or Privileged Role Administrator) to run:
#
#   az rest --method POST \\
#     --url "https://graph.microsoft.com/v1.0/servicePrincipals/\$PRINCIPAL_ID/appRoleAssignments" \\
#     --body "{\\"principalId\\":\\"\$PRINCIPAL_ID\\",\\"resourceId\\":\\"\$GRAPH_SP_ID\\",\\"appRoleId\\":\\"\$MAIL_SEND_ROLE_ID\\"}"
#
# Values:
PRINCIPAL_ID=$PRINCIPAL_ID
GRAPH_SP_ID=$GRAPH_SP_ID
MAIL_SEND_ROLE_ID=$MAIL_SEND_ROLE_ID
LOGIC_APP_NAME=$LOGIC_APP_NAME
RESOURCE_GROUP=$RESOURCE_GROUP
SUBSCRIPTION_ID=$SUBSCRIPTION_ID
ITEOF

log "  ✓ IT support variables saved to $IT_SUPPORT_FILE"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Setup complete                                              ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  NOTIFICATION                                                ║"
echo "║    Logic App  : $LOGIC_APP_NAME"
echo "║    Alert rule : $ALERT_RULE_NAME (fires after 1 x 30min stuck)"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  TERMINATION                                                 ║"
echo "║    Logic App  : $TERMINATE_APP_NAME"
echo "║    Alert rule : $TERMINATE_ALERT_NAME (fires after 3 x 30min stuck ~90min)"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  IT support file: $IT_SUPPORT_FILE"
echo "╠══════════════════════════════════════════════════════════════╣"
if [[ "$SENDER_EMAIL" == "skip" ]]; then
echo "║  EMAIL: NOT configured yet.                                  ║"
echo "║  1. Get IT to run the command in $IT_SUPPORT_FILE"
echo "║  2. Re-run:  bash bicep/setup_schism_alert.sh you@org.com   ║"
else
echo "║  Sender email : $SENDER_EMAIL"
fi
echo "╚══════════════════════════════════════════════════════════════╝"
