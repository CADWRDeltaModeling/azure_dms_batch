"""
restart_stuck_pool.py
=====================
Azure Automation Python 3 runbook that restarts a stuck Azure Batch pool by:

  1. Reading the pool's current autoscale formula via the Azure Management API.
  2. Switching the pool to fixed-scale (0 dedicated + 0 low-priority nodes),
     which terminates or requeues stuck tasks and releases all preempted spot VMs.
  3. Waiting for the pool to drain to 0 nodes.
  4. Restoring the original autoscale formula so idle-scale-up kicks in when
     pending tasks appear again.

Execution contexts
------------------
Azure Automation runbook (recommended for alert-triggered restarts)
  - The runbook receives parameters through either:
      a. Automation Account Variables (SubscriptionId, ResourceGroup,
         BatchAccountName, PoolId set in the Automation Account).
      b. A JSON webhook payload  {"PoolId": "<pool-id>"}.  The other parameters
         are then read from Automation Variables as above.
  - Authentication uses the Automation Account's system-assigned Managed Identity
    (DefaultAzureCredential picks this up automatically in the sandbox).

Local / on-demand CLI
  - python restart_stuck_pool.py \\
        --subscription-id <sub>  \\
        --resource-group  <rg>   \\
        --batch-account   <acct> \\
        --pool-id         <pool>

Dependencies:
  azure-identity
  azure-mgmt-batch

Install locally:
  pip install azure-identity azure-mgmt-batch
"""

import argparse
import json
import os
import sys
import time
import logging

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger(__name__)


# ── Azure SDK imports ──────────────────────────────────────────────────────────
try:
    from azure.identity import DefaultAzureCredential
    from azure.mgmt.batch import BatchManagementClient
    from azure.mgmt.batch.models import (
        Pool,
        ScaleSettings,
        FixedScaleSettings,
        AutoScaleSettings,
        ComputeNodeDeallocationOption,
    )
    from azure.core.exceptions import HttpResponseError
except ImportError as exc:
    sys.exit(
        f"Missing dependency: {exc}\n"
        "Run: pip install azure-identity azure-mgmt-batch"
    )


# ── Automation Asset helper (only present inside Azure Automation sandboxes) ───
def _try_get_automation_variable(name: str, fallback: str = "") -> str:
    """Return an Azure Automation Variable if the module is available."""
    try:
        import automationassets  # type: ignore[import]

        return automationassets.get_automation_variable(name) or fallback
    except ImportError:
        return fallback


# ── Core logic ────────────────────────────────────────────────────────────────

def restart_stuck_pool(
    subscription_id: str,
    resource_group: str,
    batch_account: str,
    pool_id: str,
    wait_timeout_minutes: int = 30,
    poll_interval_seconds: int = 30,
    node_dealloc_option: str = "requeue",
) -> None:
    """
    Resize an Azure Batch pool to 0 nodes and restore its autoscale formula.

    Parameters
    ----------
    subscription_id : str
    resource_group : str
    batch_account : str
    pool_id : str
    wait_timeout_minutes : int
        How long to wait for the pool to drain to 0 (default 30).
    poll_interval_seconds : int
        Polling cadence while waiting (default 30).
    node_dealloc_option : str
        One of requeue, terminate, taskcompletion, retaineddata (default requeue).
        'requeue' cancels running tasks so they can restart on the new nodes.
    """
    credential = DefaultAzureCredential()
    client = BatchManagementClient(credential, subscription_id)

    # ── 1. Get current pool state ──────────────────────────────────────────────
    logger.info("[1/5] Reading pool '%s' from account '%s'...", pool_id, batch_account)
    pool: Pool = client.pool.get(resource_group, batch_account, pool_id)

    autoscale_formula: str | None = None
    autoscale_interval: str = "PT5M"
    fixed_dedicated: int = 0

    if pool.scale_settings and pool.scale_settings.auto_scale:
        autoscale_formula = pool.scale_settings.auto_scale.formula
        autoscale_interval = (
            pool.scale_settings.auto_scale.evaluation_interval or "PT5M"
        )
        logger.info(
            "  Scale mode: autoscale  (interval %s, formula length=%d chars)",
            autoscale_interval,
            len(autoscale_formula or ""),
        )
    elif pool.scale_settings and pool.scale_settings.fixed_scale:
        fixed_dedicated = (
            pool.scale_settings.fixed_scale.target_dedicated_nodes or 0
        )
        logger.info(
            "  Scale mode: fixedScale  (targetDedicatedNodes=%d)", fixed_dedicated
        )
    else:
        raise RuntimeError(
            f"Pool '{pool_id}' has no recognised scaleSettings. Cannot proceed safely."
        )

    # ── 2. Switch to fixed-scale at 0 nodes ────────────────────────────────────
    logger.info("[2/5] Switching pool to fixed-scale 0 nodes (dealloc=%s)...", node_dealloc_option)

    dealloc_map = {
        "requeue": ComputeNodeDeallocationOption.REQUEUE,
        "terminate": ComputeNodeDeallocationOption.TERMINATE,
        "taskcompletion": ComputeNodeDeallocationOption.TASK_COMPLETION,
        "retaineddata": ComputeNodeDeallocationOption.RETAINED_DATA,
    }
    dealloc = dealloc_map.get(node_dealloc_option.lower(), ComputeNodeDeallocationOption.REQUEUE)

    client.pool.update(
        resource_group,
        batch_account,
        pool_id,
        Pool(
            scale_settings=ScaleSettings(
                fixed_scale=FixedScaleSettings(
                    target_dedicated_nodes=0,
                    target_low_priority_nodes=0,
                    node_deallocation_option=dealloc,
                )
            )
        ),
    )
    logger.info("  Fixed-scale 0 applied.")

    # ── 3. Wait for pool to drain ──────────────────────────────────────────────
    logger.info("[3/5] Waiting up to %dm for pool to reach 0 nodes...", wait_timeout_minutes)
    deadline = time.time() + wait_timeout_minutes * 60
    while True:
        current: Pool = client.pool.get(resource_group, batch_account, pool_id)
        dedicated = current.current_dedicated_nodes or 0
        low_pri = current.current_low_priority_nodes or 0
        resize_errors = current.resize_operation_status and current.resize_operation_status.errors

        logger.info("  Nodes: dedicated=%d  low-priority=%d", dedicated, low_pri)
        if resize_errors:
            for err in resize_errors:
                logger.warning("  Resize error %s: %s", err.code, err.message)

        if dedicated == 0 and low_pri == 0:
            logger.info("  Pool is at 0 nodes.")
            break

        if time.time() >= deadline:
            logger.warning(
                "Timeout waiting for pool to drain. Proceeding with scale restore anyway."
            )
            break

        time.sleep(poll_interval_seconds)

    # ── 4. Restore original scale settings ────────────────────────────────────
    if autoscale_formula:
        logger.info("[4/5] Re-enabling autoscale formula (interval %s)...", autoscale_interval)
        client.pool.update(
            resource_group,
            batch_account,
            pool_id,
            Pool(
                scale_settings=ScaleSettings(
                    auto_scale=AutoScaleSettings(
                        formula=autoscale_formula,
                        evaluation_interval=autoscale_interval,
                    )
                )
            ),
        )
        logger.info("  Autoscale formula restored. Pool will scale up on pending tasks.")
    else:
        logger.info(
            "[4/5] Restoring fixed-scale to targetDedicatedNodes=%d...", fixed_dedicated
        )
        client.pool.update(
            resource_group,
            batch_account,
            pool_id,
            Pool(
                scale_settings=ScaleSettings(
                    fixed_scale=FixedScaleSettings(
                        target_dedicated_nodes=fixed_dedicated,
                        target_low_priority_nodes=0,
                    )
                )
            ),
        )
        logger.info("  Fixed-scale restored.")

    logger.info("[5/5] Pool '%s' restart complete.", pool_id)


# ── Entry points ──────────────────────────────────────────────────────────────

def _run_as_automation_runbook() -> None:
    """
    Entry point when running inside an Azure Automation sandbox.
    Parameters are read from Automation Variables and/or a webhook JSON payload
    injected as the WEBHOOK_DATA environment variable by the Automation runtime.
    """
    subscription_id = _try_get_automation_variable("SubscriptionId")
    resource_group = _try_get_automation_variable("ResourceGroup")
    batch_account = _try_get_automation_variable("BatchAccountName")
    pool_id = _try_get_automation_variable("PoolId")

    # Webhook payload overrides: the alert sends {"PoolId": "...", ...}
    webhook_data = os.environ.get("WEBHOOK_DATA", "")
    if webhook_data:
        try:
            payload = json.loads(webhook_data)
            pool_id = payload.get("PoolId", pool_id)
            # Allow per-call overrides
            subscription_id = payload.get("SubscriptionId", subscription_id)
            resource_group = payload.get("ResourceGroup", resource_group)
            batch_account = payload.get("BatchAccountName", batch_account)
        except json.JSONDecodeError:
            logger.warning("Could not parse WEBHOOK_DATA as JSON; using Automation Variables.")

    missing = [k for k, v in {
        "SubscriptionId": subscription_id,
        "ResourceGroup": resource_group,
        "BatchAccountName": batch_account,
        "PoolId": pool_id,
    }.items() if not v]
    if missing:
        raise ValueError(
            f"Missing required Automation Variables / webhook fields: {missing}"
        )

    restart_stuck_pool(subscription_id, resource_group, batch_account, pool_id)


def _run_from_cli() -> None:
    """Entry point for local / on-demand CLI usage."""
    parser = argparse.ArgumentParser(
        description="Restart a stuck Azure Batch pool by cycling its scale to 0 and back."
    )
    parser.add_argument("--subscription-id", required=True, help="Azure subscription ID")
    parser.add_argument("--resource-group", required=True, help="Resource group name")
    parser.add_argument("--batch-account", required=True, help="Batch account name")
    parser.add_argument("--pool-id", required=True, help="Pool ID to restart")
    parser.add_argument(
        "--wait-minutes",
        type=int,
        default=30,
        help="Minutes to wait for pool to drain (default: 30)",
    )
    parser.add_argument(
        "--node-dealloc",
        default="requeue",
        choices=["requeue", "terminate", "taskcompletion", "retaineddata"],
        help="Node deallocation option (default: requeue)",
    )
    args = parser.parse_args()

    restart_stuck_pool(
        subscription_id=args.subscription_id,
        resource_group=args.resource_group,
        batch_account=args.batch_account,
        pool_id=args.pool_id,
        wait_timeout_minutes=args.wait_minutes,
        node_dealloc_option=args.node_dealloc,
    )


if __name__ == "__main__":
    # Detect whether we're running inside Azure Automation (no sys.argv beyond script name)
    # or as a local CLI invocation.
    if len(sys.argv) > 1:
        _run_from_cli()
    else:
        _run_as_automation_runbook()
