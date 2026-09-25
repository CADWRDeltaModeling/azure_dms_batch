#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# restart_stuck_pool.sh
#
# Restart a stuck Azure Batch pool by:
#   1. Capturing the current autoscale formula.
#   2. Disabling autoscale and resizing the pool to 0 nodes (cancels stuck tasks
#      and releases all VMs, including preempted spot VMs).
#   3. Waiting until the pool is empty.
#   4. Re-enabling the original autoscale formula so new nodes spin up when
#      pending tasks are detected.
#
# Trigger options:
#   - On-demand: run this script directly from the CLI.
#   - Alert action: call this script from an Azure Automation runbook webhook
#     configured as an Azure Monitor Action Group webhook action
#     (see monitoring/automation_account.bicep and monitoring/batch_pool_alert.bicep).
#
# Prerequisites:
#   - azure-cli installed and logged in (az login) or running with a managed
#     identity that has the "Azure Batch Contributor" role on the batch account.
#   - The az batch extension must be able to reach the Batch data-plane endpoint.
#     Either pass --account-key / --account-endpoint, or ensure the caller has
#     the "Batch Account Contributor" or "Batch Account Owner" role AND the
#     batch account has "Allow Azure Active Directory authentication" enabled.
#
# Usage:
#   ./restart_stuck_pool.sh \
#       --resource-group <rg-name> \
#       --batch-account  <batch-account-name> \
#       --pool-id        <pool-id> \
#       [--location      <azure-region>] \
#       [--node-dealloc  requeue|terminate|taskcompletion|retaineddata] \
#       [--wait-minutes  <timeout-minutes, default 30>]
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
RESOURCE_GROUP=""
BATCH_ACCOUNT=""
POOL_ID=""
LOCATION=""
NODE_DEALLOC="requeue"          # requeue kills tasks immediately – best for restart
WAIT_MINUTES=30
POLL_INTERVAL=30                # seconds between size-check polls

# ── Helpers ───────────────────────────────────────────────────────────────────
usage() {
    echo ""
    echo "Usage:"
    echo "  $0 --resource-group <rg> --batch-account <account> --pool-id <pool-id>"
    echo "     [--location <region>] [--node-dealloc <option>] [--wait-minutes <n>]"
    echo ""
    echo "  --node-dealloc  requeue (default) | terminate | taskcompletion | retaineddata"
    echo "  --wait-minutes  Timeout waiting for pool to reach 0 nodes (default: 30)"
    echo ""
    exit 1
}

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
err() { echo "[$(date -u +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --resource-group)  RESOURCE_GROUP="$2"; shift 2 ;;
        --batch-account)   BATCH_ACCOUNT="$2";  shift 2 ;;
        --pool-id)         POOL_ID="$2";         shift 2 ;;
        --location)        LOCATION="$2";        shift 2 ;;
        --node-dealloc)    NODE_DEALLOC="$2";    shift 2 ;;
        --wait-minutes)    WAIT_MINUTES="$2";    shift 2 ;;
        -h|--help)         usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

[[ -z "$RESOURCE_GROUP" ]] && err "--resource-group is required"
[[ -z "$BATCH_ACCOUNT"  ]] && err "--batch-account is required"
[[ -z "$POOL_ID"        ]] && err "--pool-id is required"

# ── Derive batch endpoint if not provided via env ─────────────────────────────
# az batch commands need either --account-endpoint or AZURE_BATCH_ENDPOINT set.
# We construct it from the account properties when not already set.
if [[ -z "${AZURE_BATCH_ENDPOINT:-}" ]]; then
    log "Resolving Batch account endpoint..."
    BATCH_ENDPOINT=$(az batch account show \
        --name "$BATCH_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --query "accountEndpoint" \
        --output tsv)
    export AZURE_BATCH_ENDPOINT="https://${BATCH_ENDPOINT}"
    log "  Endpoint: $AZURE_BATCH_ENDPOINT"
fi

# Common az batch flags (uses AAD auth by default; set AZURE_BATCH_ACCESS_TOKEN or
# pass --account-key if the account requires shared-key auth).
BATCH_FLAGS=(--account-name "$BATCH_ACCOUNT" --account-endpoint "$AZURE_BATCH_ENDPOINT")

# ── Step 1: Get the current autoscale formula ─────────────────────────────────
log "[1/5] Reading autoscale formula from pool '$POOL_ID'..."
POOL_JSON=$(az batch pool show --pool-id "$POOL_ID" "${BATCH_FLAGS[@]}" --output json)
AUTOSCALE_FORMULA=$(echo "$POOL_JSON" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('autoScaleFormula',''))")

if [[ -z "$AUTOSCALE_FORMULA" ]]; then
    # Pool may be using fixedScale – try target dedicated node count
    log "  Pool has no autoscale formula; checking fixed-scale settings..."
    FIXED_DEDICATED=$(echo "$POOL_JSON" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); \
         fs=d.get('targetDedicatedNodes', None); print(fs if fs is not None else '')")
    if [[ -z "$FIXED_DEDICATED" ]]; then
        err "Could not determine scale settings for pool '$POOL_ID'. Aborting."
    fi
    log "  Pool uses fixed scale: targetDedicatedNodes=$FIXED_DEDICATED"
    SCALE_TYPE="fixed"
else
    SCALE_TYPE="autoscale"
    log "  Autoscale formula captured (${#AUTOSCALE_FORMULA} chars)."
fi

# ── Step 2: Disable autoscale (required before manual resize) ─────────────────
if [[ "$SCALE_TYPE" == "autoscale" ]]; then
    log "[2/5] Disabling autoscale on pool '$POOL_ID'..."
    az batch pool autoscale disable --pool-id "$POOL_ID" "${BATCH_FLAGS[@]}"
    log "  Autoscale disabled."
else
    log "[2/5] Fixed-scale pool – skipping autoscale disable."
fi

# ── Step 3: Resize pool to 0 nodes ────────────────────────────────────────────
log "[3/5] Resizing pool '$POOL_ID' to 0 nodes (node-dealloc-option: $NODE_DEALLOC)..."
az batch pool resize \
    --pool-id "$POOL_ID" \
    --target-dedicated-node-count 0 \
    --target-low-priority-node-count 0 \
    --node-deallocation-option "$NODE_DEALLOC" \
    "${BATCH_FLAGS[@]}"
log "  Resize to 0 submitted."

# ── Step 4: Wait for pool to reach 0 nodes ────────────────────────────────────
log "[4/5] Waiting up to ${WAIT_MINUTES}m for pool to reach 0 nodes..."
DEADLINE=$(( $(date +%s) + WAIT_MINUTES * 60 ))
while true; do
    POOL_JSON=$(az batch pool show --pool-id "$POOL_ID" "${BATCH_FLAGS[@]}" --output json)
    DEDICATED=$(echo "$POOL_JSON" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('currentDedicatedNodes',0))")
    LOWPRI=$(echo "$POOL_JSON" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('currentLowPriorityNodes',0))")
    RESIZE_ERR=$(echo "$POOL_JSON" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); \
         e=d.get('resizeErrors',[]); print(e[0].get('code','') if e else '')")

    log "  Nodes: dedicated=$DEDICATED low-priority=$LOWPRI"

    if [[ -n "$RESIZE_ERR" ]]; then
        log "  WARNING: resize error reported: $RESIZE_ERR"
    fi

    if [[ "$DEDICATED" == "0" && "$LOWPRI" == "0" ]]; then
        log "  Pool is at 0 nodes."
        break
    fi

    if (( $(date +%s) >= DEADLINE )); then
        log "WARNING: Timeout reached. Pool still has nodes. Proceeding with formula restore anyway."
        break
    fi

    sleep "$POLL_INTERVAL"
done

# ── Step 5: Restore the original scale settings ───────────────────────────────
if [[ "$SCALE_TYPE" == "autoscale" ]]; then
    log "[5/5] Re-enabling autoscale formula on pool '$POOL_ID'..."
    az batch pool autoscale enable \
        --pool-id "$POOL_ID" \
        --auto-scale-formula "$AUTOSCALE_FORMULA" \
        --auto-scale-evaluation-interval "PT5M" \
        "${BATCH_FLAGS[@]}"
    log "  Autoscale re-enabled. The formula will fire within 5 minutes."
else
    log "[5/5] Re-applying fixed scale: targetDedicatedNodes=$FIXED_DEDICATED..."
    az batch pool resize \
        --pool-id "$POOL_ID" \
        --target-dedicated-node-count "$FIXED_DEDICATED" \
        "${BATCH_FLAGS[@]}"
    log "  Fixed-scale resize submitted."
fi

log "=== Pool '$POOL_ID' restart complete ==="
