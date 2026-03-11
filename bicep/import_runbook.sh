#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# import_runbook.sh
#
# Post-deployment helper: uploads and publishes the Python restart runbook to
# an Azure Automation Account created by bicep/automation_account.bicep.
#
# Run this once after `az deployment group create ... --template-file
#   bicep/automation_account.bicep`.
#
# Usage:
#   bash bicep/import_runbook.sh \
#       --resource-group       <rg-name>               \
#       --automation-account   <automation-account>    \
#       [--runbook-script      <path/to/restart_stuck_pool.py>]
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SCRIPT="${SCRIPT_DIR}/../dmsbatch/restart_stuck_pool.py"

RESOURCE_GROUP=""
AUTOMATION_ACCOUNT=""
RUNBOOK_NAME="restart-stuck-pool"
RUNBOOK_SCRIPT="$DEFAULT_SCRIPT"

usage() {
    echo "Usage: $0 --resource-group <rg> --automation-account <account> [--runbook-script <path>]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --resource-group)      RESOURCE_GROUP="$2";      shift 2 ;;
        --automation-account)  AUTOMATION_ACCOUNT="$2";  shift 2 ;;
        --runbook-script)      RUNBOOK_SCRIPT="$2";      shift 2 ;;
        -h|--help)             usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

[[ -z "$RESOURCE_GROUP"     ]] && { echo "ERROR: --resource-group is required"; usage; }
[[ -z "$AUTOMATION_ACCOUNT" ]] && { echo "ERROR: --automation-account is required"; usage; }
[[ ! -f "$RUNBOOK_SCRIPT"   ]] && { echo "ERROR: Runbook script not found: $RUNBOOK_SCRIPT"; exit 1; }

echo "Uploading runbook content from: $RUNBOOK_SCRIPT"

az automation runbook replace-content \
    --resource-group      "$RESOURCE_GROUP" \
    --automation-account-name "$AUTOMATION_ACCOUNT" \
    --name                "$RUNBOOK_NAME" \
    --content             @"$RUNBOOK_SCRIPT"

echo "Publishing runbook..."

az automation runbook publish \
    --resource-group      "$RESOURCE_GROUP" \
    --automation-account-name "$AUTOMATION_ACCOUNT" \
    --name                "$RUNBOOK_NAME"

echo "Runbook '$RUNBOOK_NAME' published successfully."
echo ""
echo "To test it manually (replace <pool-id> with your pool):"
echo ""
echo "  az automation runbook start \\"
echo "      --resource-group      $RESOURCE_GROUP \\"
echo "      --automation-account-name $AUTOMATION_ACCOUNT \\"
echo "      --name                $RUNBOOK_NAME"
