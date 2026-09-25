#!/usr/bin/env bash
# =============================================================================
# setup_batch_idle_alert.sh
#
# Sets up the generic (job-type-agnostic) idle-node alerting pipeline described
# in README-monitoring.md §2 end-to-end:
#   1. Deploy the Logic App (batch-idle-node-handler) via Bicep — it polls the
#      Batch data-plane "list pool node counts" API on a 30-min Recurrence
#      trigger for every account in BATCH_ACCOUNTS (Azure Monitor can't be used
#      here: the relevant Batch metrics have no per-pool dimension at all)
#   2. Grant its managed identity Contributor on each Batch account (needed for
#      the Batch data-plane calls, same pattern as the SCHISM terminate workflow)
#   3. Save IT-support variables to it_support_vars_idle_node.txt (Mail.Send grant)
#
# Unlike setup_schism_alert.sh, this pipeline has no Telegraf/Application
# Insights dependency and no KQL — it only reacts to native Azure Batch
# node-state data, so it applies to any job type on any pool.
#
# Usage:
#   cd /scratch/psandhu/azure_dms_batch
#   module load azure_cli
#   bash monitoring/setup_batch_idle_alert.sh [sender_email] [--overwrite|-f] [--config <path>]
#
#   sender_email     – the shared mailbox to send alerts FROM (e.g. batch-alerts@water.ca.gov)
#                      Required only after IT grants Mail.Send permission.
#                      Pass "skip" to skip email setup for now. Defaults to
#                      schism-batch-alerts@water.ca.gov (already granted Mail.Send).
#   --overwrite / -f – update/replace the Logic App if it already exists.
#                      Without this flag, an existing Logic App is left
#                      untouched — safe to re-run to pick up newly added Batch
#                      accounts (role grants are always applied regardless).
#   --config <path>  – source a local, gitignored shell file that overrides
#                      RESOURCE_GROUP / BATCH_ACCOUNTS / SENDER_EMAIL_ARG below
#                      for a specific deployment target, so real resource-group
#                      and batch-account names never need to be committed here.
#                      See monitoring/local_deploy_configs/ (gitignored).
# =============================================================================
set -euo pipefail

OVERWRITE=false
SENDER_EMAIL_ARG=""
CONFIG_FILE=""
ARGS=("$@")
i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
  ARG="${ARGS[$i]}"
  case "$ARG" in
    --overwrite|-f) OVERWRITE=true ;;
    --config) i=$((i + 1)); CONFIG_FILE="${ARGS[$i]:-}" ;;
    *) SENDER_EMAIL_ARG="$ARG" ;;
  esac
  i=$((i + 1))
done

# ── Configuration ─────────────────────────────────────────────────────────────
# Defaults below are just a fallback example — override via --config <path>
# (see monitoring/local_deploy_configs/, gitignored) rather than editing here.
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
RESOURCE_GROUP="dwrbdo_schism_rg"

LOGIC_APP_NAME="batch-idle-node-handler"

# Batch accounts to protect (space-separated: "accountName:resourceGroup").
# The FIRST entry's account/resource-group is used for the Logic App's own
# Bicep deployment; every entry (including the first) gets its own alert
# deployment and Reader role assignment.
BATCH_ACCOUNTS=(
  "schismbatch:dwrbdo_schism_rg"
  "schismbatchscus:dwrbdo_schism_scus_rg"
  "schismbatchscus2:dwrbdo_schism_scus_rg"
)

if [[ -n "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

SENDER_EMAIL="${SENDER_EMAIL_ARG:-schism-batch-alerts@water.ca.gov}"
IT_SUPPORT_FILE="monitoring/it_support_vars_idle_node.txt"
# ──────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
step() { echo; echo "══════════════════════════════════════════════"; echo "  $*"; echo "══════════════════════════════════════════════"; }

if [[ -n "$CONFIG_FILE" ]]; then
  log "Loaded config overrides from $CONFIG_FILE"
fi

# Returns 0 (true) if resource exists in the given resource group.
resource_exists() {
  az resource show --resource-group "$1" --resource-type "$2" --name "$3" &>/dev/null
}

# Skips a create/update step unless it doesn't exist yet or --overwrite was passed.
should_deploy() {
  local rg="$1" resource_type="$2" name="$3"
  if resource_exists "$rg" "$resource_type" "$name"; then
    if [[ "$OVERWRITE" == "true" ]]; then
      return 0
    fi
    log "  ↷ $name already exists — skipping (pass --overwrite to update)"
    return 1
  fi
  return 0
}

# ── Step 1: Deploy the Logic App ──────────────────────────────────────────────
step "1/3  Deploying batch-idle-node-handler Logic App via Bicep"

PRIMARY_ACCOUNT="${BATCH_ACCOUNTS[0]%%:*}"

# Build the full ARM resource ID list the workflow polls every run.
RESOURCE_IDS_JSON="["
for ENTRY in "${BATCH_ACCOUNTS[@]}"; do
  ACCOUNT="${ENTRY%%:*}"
  RG="${ENTRY##*:}"
  RESOURCE_IDS_JSON="${RESOURCE_IDS_JSON}\"/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG/providers/Microsoft.Batch/batchAccounts/$ACCOUNT\","
done
RESOURCE_IDS_JSON="${RESOURCE_IDS_JSON%,}]"

BICEP_PARAMS="batchAccountName=$PRIMARY_ACCOUNT batchAccountResourceIds=$RESOURCE_IDS_JSON"
if [[ "$SENDER_EMAIL" != "skip" ]]; then
  BICEP_PARAMS="$BICEP_PARAMS senderEmail=$SENDER_EMAIL"
else
  BICEP_PARAMS="$BICEP_PARAMS senderEmail=placeholder@placeholder.com"
  log "WARNING: senderEmail set to placeholder. Re-run with real address after IT grants Mail.Send."
fi

if should_deploy "$RESOURCE_GROUP" Microsoft.Logic/workflows "$LOGIC_APP_NAME"; then
  az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$SCRIPT_DIR/batch_idle_node_logic_app.bicep" \
    --parameters $BICEP_PARAMS \
    --query "properties.provisioningState" \
    --output tsv
fi

PRINCIPAL_ID=$(az resource show \
  --resource-group "$RESOURCE_GROUP" \
  --resource-type Microsoft.Logic/workflows \
  --name "$LOGIC_APP_NAME" \
  --query "identity.principalId" -o tsv)

log "Logic App principal ID: $PRINCIPAL_ID"

# ── Step 2: Grant Contributor on each Batch account (Batch data-plane access) ─
step "2/3  Granting Contributor on each Batch account"

CONTRIBUTOR_ROLE_ID="b24988ac-6180-42a0-ab88-20f7382dd24c"

for ENTRY in "${BATCH_ACCOUNTS[@]}"; do
  ACCOUNT="${ENTRY%%:*}"
  RG="${ENTRY##*:}"
  SCOPE="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG/providers/Microsoft.Batch/batchAccounts/$ACCOUNT"

  EXISTING=$(az role assignment list \
    --scope "$SCOPE" \
    --assignee "$PRINCIPAL_ID" \
    --query "[?roleDefinitionId contains '$CONTRIBUTOR_ROLE_ID'].id | [0]" \
    -o tsv 2>/dev/null || true)

  if [[ -n "$EXISTING" ]]; then
    log "  ✓ Already has Contributor on $ACCOUNT — skipping"
  else
    az role assignment create \
      --assignee "$PRINCIPAL_ID" \
      --role "Contributor" \
      --scope "$SCOPE" \
      --output none
    log "  ✓ Granted Contributor on $ACCOUNT"
  fi
done

# ── Step 3: Save IT support variables ─────────────────────────────────────────
step "3/3  Saving IT support variables"

GRAPH_SP_ID=$(az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals?\$filter=appId eq '00000003-0000-0000-c000-000000000000'" \
  --query "value[0].id" -o tsv 2>/dev/null || echo "GRAPH_API_CALL_FAILED")

MAIL_SEND_ROLE_ID=$(az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$GRAPH_SP_ID/appRoles" \
  --query "value[?value=='Mail.Send'].id | [0]" -o tsv 2>/dev/null || echo "GRAPH_API_CALL_FAILED")

cat > "$REPO_ROOT/$IT_SUPPORT_FILE" <<ITEOF
# IT Support variables for granting Mail.Send to the batch-idle-node-handler Logic App
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
echo "║  Logic App    : $LOGIC_APP_NAME (30-min Recurrence trigger, polls Batch data-plane)"
echo "║  Accounts     : ${BATCH_ACCOUNTS[*]}"
echo "║  Conditions   : idle, waitingForStartTask, startTaskFailed, unusable node counts"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  IT support file: $IT_SUPPORT_FILE"
echo "╠══════════════════════════════════════════════════════════════╣"
if [[ "$SENDER_EMAIL" == "skip" ]]; then
echo "║  EMAIL: NOT configured yet.                                  ║"
echo "║  1. Get IT to run the command in $IT_SUPPORT_FILE"
echo "║  2. Re-run:  bash monitoring/setup_batch_idle_alert.sh you@org.com --overwrite"
else
echo "║  Sender email : $SENDER_EMAIL"
fi
echo "╚══════════════════════════════════════════════════════════════╝"
