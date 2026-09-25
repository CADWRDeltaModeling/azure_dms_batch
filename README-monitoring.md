# Azure Batch Job Monitoring & Alerting — Overview

This document explains the monitoring/alerting stack for jobs running on Azure Batch, all
defined in [monitoring/](monitoring/). It ties together three separate but complementary pipelines
that live in that folder:

1. **Pool-health monitoring** — detects infrastructure-level problems (spot preemption,
   task failures, resize errors) and auto-restarts the affected pool. *(generic — any job type)*
2. **Idle-node monitoring** — detects nodes that are allocated but doing no useful work,
   using only native Azure Batch node-state metrics, and emails the pool's submitter.
   *(generic — any job type)*
3. **Simulation-progress monitoring** — detects a job that is *running* but not making
   progress and auto-terminates it if it stays stuck too long. *(SCHISM-specific today —
   see §3)*

All three pipelines are Azure-native (Monitor alerts + Logic Apps / Automation runbooks
with system-assigned managed identities — no stored credentials) and are scoped
per-Batch-account via role assignments, so they can be deployed against any subscription
that runs Batch jobs. §1 and §2 need nothing beyond an Azure Batch account; §3 additionally
needs Telegraf + Application Insights (see [docs/telegraf_appinsights_setup.md](docs/telegraf_appinsights_setup.md))
and is currently written specifically for SCHISM's own progress signal.


## Why three pipelines

A pool can be "healthy" at the infrastructure level (nodes up, tasks `running`) while the
SCHISM process itself is deadlocked, a pool can look fine at the simulation level while a
spot eviction has silently starved it of nodes, and a pool can have neither problem while
simply sitting idle with nothing left to do. None of these symptoms is detectable from
another pipeline's signal, so they are implemented independently and can be deployed
separately:

| | Signal source | Detects | Action |
|---|---|---|---|
| Pool-health (§1) | Batch account metrics + activity log | Preempted nodes, failed tasks, resize errors | Cycle pool to 0 nodes, restore autoscale |
| Idle-node (§2) | Batch data-plane pool node counts, polled every 30 min (native, no Telegraf) | Nodes allocated but idle, stuck pre-task, Start Task failed, or unusable | Email the pool's `created-by` submitter |
| Simulation-progress (§3) | `schism_time` / `cpu_usage_active` custom metrics in App Insights (via Telegraf) | Simulation clock frozen, telemetry gone silent, or never started | Email submitter; auto-terminate job after ~90 min |

---

## 1. Pool-health monitoring — restart-stuck-pool

Full walkthrough: [README-schism-restart-stuck-pool.md](README-schism-restart-stuck-pool.md).

```
Azure Batch pool (spot VMs)
  │  PreemptedNodeCount ≥ 1  OR  FailedTaskCount ≥ 1  OR  pool resize failed
  ▼
Azure Monitor alert (metric alerts + activity log alert)   — monitoring/batch_pool_alert.bicep
  │  action group webhook
  ▼
Azure Automation webhook                                    — monitoring/automation_account.bicep
  │
  ▼
Azure Automation runbook (restart-stuck-pool, Python 3)      — dmsbatch/restart_stuck_pool.py
  │  azure-mgmt-batch via the Automation Account's managed identity
  ▼
Pool resized to 0 nodes → original autoscale formula restored → tasks requeued on fresh nodes
```

- [monitoring/automation_account.bicep](monitoring/automation_account.bicep) — Automation Account
  (system-assigned identity), automation variables (`SubscriptionId`, `ResourceGroup`,
  `BatchAccountName`, `PoolId`), the `restart-stuck-pool` runbook shell, and its webhook.
  Grants the identity **Contributor** on the Batch account.
- [monitoring/batch_pool_alert.bicep](monitoring/batch_pool_alert.bicep) — three alerts, all wired
  to one action group that calls the Automation webhook:
  - `PreemptedNodeCount ≥ 1` (metric alert, 5 min window)
  - `FailedTaskCount ≥ 1` (metric alert, 5 min window)
  - Pool resize activity-log alert (`status == Failed` on
    `Microsoft.Batch/batchAccounts/pools/resize/action`)
- This pipeline can also be triggered on demand without waiting for an alert:
  `runbooks/restart_stuck_pool.sh` or `dmsbatch restart-stuck-pool` (see
  [README-schism-restart-stuck-pool.md](README-schism-restart-stuck-pool.md)).

This pipeline is **SCHISM-agnostic** — it only looks at Batch account/pool metrics
(preemption, task failure, resize activity), not simulation content, so it already
applies as-is to any job type running on a Batch pool.

> **Known limitation (found 2026-09-25, not yet fixed):** `PreemptedNodeCount` and
> `FailedTaskCount` do not actually support a `poolId` dimension (confirmed via
> `az monitor metrics list-definitions` — `dims: null`), the same issue found and fixed
> in §2 below. `batch_pool_alert.bicep` still declares a `poolId` dimension on both
> alerts, so as deployed today these alerts are effectively account-wide despite being
> named/deployed per-pool, and the runbook they trigger always restarts one hardcoded
> pool — a mismatch if the account runs more than one pool. Needs the same recurrence-
> polling redesign as §2 (poll pools directly instead of relying on Azure Monitor
> dimensions) before it's safe to rely on for a multi-pool account. See
> [.github/LESSONS-LEARNED-monitoring.md](.github/LESSONS-LEARNED-monitoring.md).

---

## 2. Idle-node monitoring — generic, no Telegraf/App Insights required

This is a second, fully job-type-agnostic pipeline built entirely on native Azure Batch
data — no Telegraf, no Application Insights, no `schism_time`. It only detects
**idle/wasted node capacity**, not simulation progress; frozen/silent-simulation detection
stays SCHISM-specific (§3).

**This runs on a 30-minute Recurrence trigger, not an Azure Monitor alert.** The relevant
Batch account metrics (`IdleNodeCount`, `WaitingForStartTaskNodeCount`,
`StartTaskFailedNodeCount`, `UnusableNodeCount`) have **no dimensions at all** — confirmed
via `az monitor metrics list-definitions` (`dims: null`) and by a real failed deployment
attempt (`BadRequest: ... specifies a dimension poolId which was not found`) — so Azure
Monitor can only tell you the account-wide total, never which pool is actually idle. The
workflow instead polls the Batch **data-plane** "list pool node counts" API directly:

```
Every 30 minutes (Recurrence trigger, no Azure Monitor alert involved)
  ▼
batch-idle-node-handler (Logic App)  — monitoring/batch_idle_node_logic_app.bicep
  for each configured Batch account:
    - GET account (ARM) → region
    - GET https://{account}.{region}.batch.azure.com/nodecounts (data-plane, per-pool counts)
    - filter pools where idle / waitingForStartTask / startTaskFailed / unusable > 0
    - for each flagged pool: GET pool (ARM) → read "created-by" metadata
    - email the pool creator via Microsoft Graph
```

- [monitoring/batch_idle_node_logic_app.bicep](monitoring/batch_idle_node_logic_app.bicep) +
  [monitoring/batch_idle_node_workflow.json](monitoring/batch_idle_node_workflow.json) — the
  handler Logic App. Deployed **once**, with a `batchAccountResourceIds` array parameter
  listing every account it should poll each run. Its managed identity needs
  **Contributor** on each Batch account — Batch's data-plane API (like the SCHISM
  terminate workflow's job-terminate call) authorizes via ARM RBAC role assignment, not a
  separate Batch-specific role, and the built-in **Reader** role is NOT sufficient for
  data-plane reads (confirmed by testing) — plus Microsoft Graph `Mail.Send` (same
  tenant-admin grant process as the SCHISM Logic Apps, see
  [docs/schism_alerting_setup.md](docs/schism_alerting_setup.md) Step 4).
- The submitter's email comes straight from the pool's own `created-by` ARM metadata —
  every `dmsbatch/templates/*/pool.bicep` already sets
  `metadata: [{ name: 'created-by', value: createdBy }]` at pool-creation time, so no
  extra tagging/telemetry plumbing is needed for this pipeline to work on any job type.
- [monitoring/setup_batch_idle_alert.sh](monitoring/setup_batch_idle_alert.sh) — orchestrates the
  whole pipeline end-to-end (Logic App deploy, Contributor role grants per account, IT
  support file for the Mail.Send grant), mirroring `setup_schism_alert.sh`'s shape:

  ```bash
  bash monitoring/setup_batch_idle_alert.sh skip            # first pass, no email yet
  bash monitoring/setup_batch_idle_alert.sh you@org.com     # after IT grants Mail.Send
  bash monitoring/setup_batch_idle_alert.sh you@org.com -f  # re-run and overwrite the Logic App
  ```

  Without `--overwrite`/`-f`, an existing Logic App is left untouched (role grants are
  always (re)applied regardless) — safe to re-run after adding a new Batch account to
  `BATCH_ACCOUNTS`. `setup_schism_alert.sh` supports the same `--overwrite`/`-f` flag for
  the same reason. Both scripts also support `--config <path>` to source a local,
  gitignored file (`monitoring/local_deploy_configs/*.sh`) with the real resource-group
  and batch-account names for a given deployment, so those specifics never need to be
  committed to this repo.

---

## 3. Simulation-progress monitoring — stuck-job alert & auto-terminate (SCHISM-specific)

This pipeline is the odd one out: unlike §1 and §2, it is written specifically for
SCHISM's own progress signal (`schism_time`) and is not usable as-is for other job types.
See [Generalizing simulation-progress monitoring for other job types](#generalizing-simulation-progress-monitoring-for-other-job-types)
below for what would need to change to support other job types.

Full walkthrough: [docs/schism_alerting_setup.md](docs/schism_alerting_setup.md).
Telemetry prerequisite: [docs/telegraf_appinsights_setup.md](docs/telegraf_appinsights_setup.md).

```
customMetrics (schism_time, cpu_usage_active)
         │  via Telegraf, tagged with host / created_by / batch_account / batch_region
         ▼
  schism-batch-insights (Application Insights)
         │
   ┌─────┴──────────────────────────────┐
   │ stuck ~30 min          stuck ~90 min │
   ▼                                     ▼
SCHISM-stuck-simulation          SCHISM-stuck-terminate      (scheduled query rule alerts)
   │                                     │
   ▼                                     ▼
schism-stuck-handler-ag           schism-terminate-handler-ag (action groups)
   │                                     │
   ▼                                     ▼
schism-stuck-handler (Logic App)  schism-terminate-handler (Logic App)
 - emails the job submitter        - terminates the job via Batch API
                                   - emails the job submitter
```

- [monitoring/schism_alert_logic_app.bicep](monitoring/schism_alert_logic_app.bicep) +
  [monitoring/schism_alert_workflow.json](monitoring/schism_alert_workflow.json) — notification
  Logic App (`schism-stuck-handler`).
- [monitoring/schism_terminate_logic_app.bicep](monitoring/schism_terminate_logic_app.bicep) +
  [monitoring/schism_terminate_workflow.json](monitoring/schism_terminate_workflow.json) —
  termination Logic App (`schism-terminate-handler`).
- [monitoring/setup_schism_alert.sh](monitoring/setup_schism_alert.sh) — orchestrates both
  deployments plus the two `Microsoft.Insights/scheduledQueryRules` alert rules (KQL
  queries embedded in the script, not in Bicep) and the role assignments.
- Both Logic Apps use a system-assigned managed identity granted **Contributor** on each
  Batch account (to query/terminate jobs) and **Monitoring Reader** on Application
  Insights (to read alert query results), plus Microsoft Graph `Mail.Send` (tenant-admin
  granted, restricted to a shared mailbox via an Exchange Application Access Policy) to
  send email.

### How "idling for too long" is decided (SCHISM-specific today)

Both alert rules run the same style of KQL query over `customMetrics`, comparing a recent
window against an earlier baseline, and classify each `host` (pool/node) into one of three
`StuckReason` values:

| Reason | Condition | Meaning |
|---|---|---|
| `frozen` | `schism_time` present in both windows, value unchanged | MPI deadlock / busy-wait — process alive but simulation clock isn't advancing |
| `silent` | `schism_time` present in the baseline window, absent in the current window | Node evicted/crashed, or Telegraf killed — without this branch a dead job's metrics just vanish and never match `frozen` |
| `idle_no_telemetry` | `schism_time` never seen at all, but `cpu_usage_active` is present and averaging < 5% since the host first reported | Bad `$SCHISM_STUDY_DIR`, wrong log format, or a non-SCHISM task — `frozen`/`silent` can never match since both require a prior `schism_time` sample |

Timing (both windows evaluated every 30 min):
- **Notify** (`SCHISM-stuck-simulation`): last 30 min vs. previous 30 min (2h total window) → fires after ~30 min stuck.
- **Terminate** (`SCHISM-stuck-terminate`): last 30 min vs. 90+ min ago (3h total window) → fires after ~90 min stuck, giving the job more runway before destructive action.

Jobs submitted before the routing tags (`created_by`, `batch_account`, `batch_region`)
were added to the Telegraf package are recognized as untagged and the workflow skips
automated action rather than guessing which job/account to act on.

> Note: `setup_schism_alert.sh`'s comments reference a "standalone `cpu idling` rule" that
> uses the same idle-CPU signal — that generic rule (idle CPU with no SCHISM context) is
> not currently checked into this repo; only the SCHISM-scoped `idle_no_telemetry` branch
> above is.

---

## Where the "detect progress" logic is SCHISM-specific

Everything in §1 (pool-health) and §2 (idle-node) is already generic. The part that is
tied to SCHISM is entirely inside §3's KQL queries and metric name:

- The metric name `schism_time` (SCHISM's own simulation-time metric, emitted via
  Telegraf reading SCHISM's stdout/log) is the sole "is this job making progress" signal.
- The `frozen`/`silent`/`idle_no_telemetry` classification and its thresholds (30 min /
  90 min, < 5% CPU) are hardcoded in the KQL in
  [monitoring/setup_schism_alert.sh](monitoring/setup_schism_alert.sh).
- The routing tags (`created_by`, `batch_account`, `batch_region`) come from
  `telegraf.conf` `[global_tags]`, populated per-task from `application_command_template.sh`.
- The termination call target (which Batch job/task to terminate) and the email body
  wording in both workflow JSON files assume a SCHISM run.

Everything else (Logic App plumbing, action groups, managed identities, role
assignments, scheduled-query-rule mechanics) is reusable as-is — and §2 shows that a
fully generic, telemetry-free version of "notify the submitter" is already possible today
for the subset of problems Azure Batch itself can detect (idle nodes).

---

## Generalizing simulation-progress monitoring for other job types

§2 (idle-node) is already generic and covers the "nodes have nothing to do" case for any
job type with no per-job work needed. What remains SCHISM-specific is §3's
progress/frozen/silent detection, which depends on a job emitting its own progress metric
(`schism_time`). Generalizing that further (e.g. other job types with their own progress
metrics wanting frozen/silent detection too) would need its own design pass if/when a
concrete need for it comes up — out of scope for now per current direction (idle-node
notification only for non-SCHISM job types, no frozen/silent).
