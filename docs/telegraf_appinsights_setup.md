# SCHISM Telemetry Setup — Application Insights + Telegraf

This document explains how SCHISM Azure Batch jobs report telemetry (including the
`schism_time` simulation clock) into Application Insights. It is the foundation the
stuck-job alerting pipeline is built on — see
[schism_alerting_setup.md](schism_alerting_setup.md) for what happens *after* the metrics
land in Application Insights.

## Why this exists

Each SCHISM run writes its progress (current simulation time step) to a log file
(`mirror.out`) on the compute node. That's only visible if you SSH into the node. To make
progress observable centrally — for dashboards, health checks, and automated stuck-job
detection — every compute node runs [Telegraf](https://www.influxdata.com/time-series-platform/telegraf/),
which tails the log, extracts the simulation clock, and pushes it (plus basic host
metrics) to Application Insights as custom metrics.

## Architecture

```
 SCHISM process                 Telegraf agent                Application Insights
┌────────────────┐   tail    ┌───────────────────┐   HTTPS   ┌─────────────────────┐
│ outputs/       │ ───────►  │ inputs.exec (grok)│ ────────► │ customMetrics table │
│  mirror.out    │           │  + inputs.cpu/    │           │  - schism_time      │
│  "TIME STEP=...│           │    disk/diskio/mem│           │  - cpu_usage_active │
│   TIME=1234.5" │           │  + global_tags:   │           │  - disk_used_percent│
└────────────────┘           │    created_by,    │           │  - diskio_reads/... │
                             │    batch_account, │           │  - mem_used_percent │
                             │    batch_region   │           │  (tagged by host,   │
                             └───────────────────┘           │   created_by, etc.) │
                                                             └─────────────────────┘
```

Telegraf runs as a background process for the lifetime of the SCHISM task, polling every
60 seconds (configurable).

## Files involved

| File | Purpose |
|---|---|
| [app-packages/telegraf/telegraf.conf](../app-packages/telegraf/telegraf.conf) | Telegraf agent config: inputs, tags, and the Application Insights output |
| [app-packages/telegraf/install_telegraf.sh](../app-packages/telegraf/install_telegraf.sh) | Installs Telegraf from cached RPMs on the compute node (offline install, no internet egress needed) |
| [app-packages/batch_app_package_and_upload.sh](../app-packages/batch_app_package_and_upload.sh) | Contains `package_and_upload_telegraf()` — bakes your Application Insights instrumentation key into `telegraf.conf`, zips it, and registers it as a Batch application package |
| `dmsbatch/templates/*/coordination_command_template.sh` | Runs once per node at task startup; installs Telegraf from the app package (`install_telegraf.sh`) |
| `dmsbatch/templates/*/application_command_template.sh` | Launches the `telegraf` binary in the background before the SCHISM run starts, passing routing tags as env vars |
| `dmsbatch/templates/*/pool.bicep` | Declares `telegraf` in the pool's `applicationPackages` list so it gets mounted on every node |

## Step 1 — Create an Application Insights resource

If you don't already have one for your SCHISM environment:

```bash
az login
az group create --name <your-resource-group> --location <your-region>

az monitor app-insights component create \
  --app schism-batch-insights \
  --location <your-region> \
  --resource-group <your-resource-group> \
  --kind other \
  --application-type other
```

Note the resource name (`schism-batch-insights` here) — you'll need it in Step 3, and
again when setting up alerting.

## Step 2 — Understand the Telegraf config

[telegraf.conf](../app-packages/telegraf/telegraf.conf) has three relevant sections:

**1. Global tags** — attached to every metric, used later by the alerting Logic Apps to
route/notify:

```toml
[global_tags]
  created_by    = "${CREATED_BY_EMAIL}"    # who submitted the job
  batch_account = "${BATCH_ACCOUNT_NAME}"  # which Batch account
  batch_region  = "${BATCH_REGION}"        # which Azure region
```

**2. The `schism_time` metric** — extracted from the model's own log file via a grok
pattern:

```toml
[[inputs.exec]]
  commands = [
    "sh -c 'tail -50 ${SCHISM_STUDY_DIR}/outputs/mirror.out | grep TIME | tail -1'"
  ]
  ignore_error = true
  timeout = "10s"
  data_format = "grok"
  grok_patterns = [
    "TIME STEP=%{SPACE}%{NUMBER:step:int};%{SPACE}TIME=%{SPACE}%{NUMBER:time:float}"
  ]
  name_override = "schism"
```

This produces a custom metric named **`schism_time`** (measurement `schism` + field
`time`) whose value is the simulation clock, sampled once per interval. It depends on
`$SCHISM_STUDY_DIR` being set and pointing at the run's working directory — Telegraf must
be launched with that variable already populated (see Step 4 — this bit it fragile, see
Troubleshooting).

**3. Host metrics** — `inputs.cpu`, `inputs.disk`, `inputs.diskio`, `inputs.mem`, trimmed
down via `processors.override` to just `usage_active`, `used_percent`, `reads`/`writes`.
These are useful for spotting resource exhaustion independent of `schism_time`.

**4. The output plugin**:

```toml
[[outputs.application_insights]]
instrumentation_key = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"   # placeholder — filled in at packaging time
[outputs.application_insights.context_tag_sources]
  "ai.cloud.roleInstance" = "${AZ_BATCH_POOL_ID}"
  "ai.cloud.role" = "azure-dms-batch"
```

The instrumentation key placeholder is **never edited by hand** — the packaging script in
Step 3 substitutes it automatically into a temporary copy, so the checked-in
`telegraf.conf` stays generic and safe to commit.

## Step 3 — Package and upload the Telegraf application

```bash
export MY_BATCH_ACCOUNT="<your-batch-account>"
export MY_RG="<your-resource-group>"
cd app-packages
source batch_app_package_and_upload.sh
package_and_upload_telegraf "telegraf" "$MY_BATCH_ACCOUNT" "$MY_RG"
```

You'll be prompted:

```
Enter Application Insights resource name (searched across the current subscription):
```

Enter the name from Step 1 (e.g. `schism-batch-insights`). The function then:

1. Looks up the resource by name across the current subscription (`az resource list`)
2. Retrieves its instrumentation key (`az monitor app-insights component show`)
3. Copies `telegraf.conf` to a temp directory and substitutes the real key in
4. Zips it as `telegraf_<YYYY.MM.DD>.zip`
5. Registers it as a Batch application package (`az batch application package create`)
   and sets it as the default version (`az batch application set`)

Repeat once per Batch account that will run SCHISM jobs — each account needs its own
copy of the application package (they can all point at the same Application Insights
resource, or different ones per environment).

> If you need to point an *existing* deployment at a different Application Insights
> resource (e.g. moving environments), just re-run `package_and_upload_telegraf` — the
> new version becomes the default and future jobs pick it up automatically.

## Step 4 — Reference the package in your pool definition

Every `pool.bicep` under `dmsbatch/templates/` must list `telegraf` in
`applicationPackages` (no version pinned — it always uses the account's default
version):

```json
"appPkgs": {
  "value": [
    { "name": "batch_setup" },
    { "name": "nfs" },
    { "name": "schism_with_deps" },
    { "name": "schimpy_with_deps" },
    { "name": "baydeltaschism" },
    { "name": "telegraf" }
  ]
}
```

At node startup, `coordination_command_template.sh` installs it once per node:

```bash
if [ -n "$AZ_BATCH_APP_PACKAGE_telegraf" ]; then
  pushd $AZ_BATCH_APP_PACKAGE_telegraf;
  sudo bash ./install_telegraf.sh;
  popd;
fi;
```

`install_telegraf.sh` installs from RPMs cached inside the application package itself —
no internet access is required on the compute node.

Then `application_command_template.sh` launches it in the background right before the
SCHISM run, passing the routing tags and `SCHISM_STUDY_DIR` **inline on the command
line** (not via a separate `export`, see Troubleshooting):

```bash
CREATED_BY_EMAIL="{created_by}" \
  BATCH_ACCOUNT_NAME="$(echo $AZ_BATCH_ACCOUNT_URL | sed 's|https://\([^.]*\)\..*|\1|')" \
  BATCH_REGION="$(echo $AZ_BATCH_ACCOUNT_URL | sed 's|https://[^.]*\.\([^.]*\)\..*|\1|')" \
  SCHISM_STUDY_DIR="$AZ_BATCH_TASK_WORKING_DIR/simulations/{study_dir}" \
  telegraf --config $AZ_BATCH_APP_PACKAGE_telegraf/telegraf.conf > /dev/null 2>&1 &
telegraf_pid=$!;
```

`BATCH_ACCOUNT_NAME` and `BATCH_REGION` are parsed automatically from
`AZ_BATCH_ACCOUNT_URL` (set by Azure Batch on every node) — no per-pool configuration
needed. `{created_by}` and `{study_dir}` are template placeholders substituted by
`dmsbatch/batch.py` at job-submission time from your job YAML.

## Step 5 — Verify metrics are flowing

Submit a test SCHISM job, then in the Azure Portal open your Application Insights
resource → **Logs**, and run:

```kql
// See every distinct metric name reported in the last hour
customMetrics
| where timestamp > ago(1h)
| distinct name

// Confirm schism_time is updating for a specific host
customMetrics
| where name == "schism_time"
| where timestamp > ago(1h)
| project timestamp, value, host = tostring(customDimensions["host"]), created_by = tostring(customDimensions["created_by"])
| order by timestamp desc

// Confirm routing tags are present (required for the alerting pipeline)
customMetrics
| where name == "schism_time"
| where timestamp > ago(1h)
| project timestamp, batch_account = tostring(customDimensions["batch_account"]), batch_region = tostring(customDimensions["batch_region"])
| take 20
```

You should see `schism_time` increasing roughly every minute (or your configured
`interval`) while the job runs, alongside `cpu_usage_active`, `disk_used_percent`,
`diskio_reads`, `diskio_writes`, and `mem_used_percent`.

## Troubleshooting

- **`schism_time` never appears, but other metrics do** — almost always means
  `$SCHISM_STUDY_DIR` was unset or wrong when Telegraf started, so the `inputs.exec` tail
  command pointed at a nonexistent path (`ignore_error = true` hides the failure
  silently). Fix: pass `SCHISM_STUDY_DIR` **inline** on the `telegraf` command itself
  (as shown in Step 4), don't rely on an `export` earlier/later in the script — ordering
  matters and env vars exported *after* a backgrounded process starts do not propagate to
  it.
- **No metrics at all** — check `AZ_BATCH_APP_PACKAGE_telegraf` is set (i.e. the pool's
  `applicationPackages` includes `telegraf`) and that `install_telegraf.sh` ran without
  error in the coordination task log.
- **Metrics appear but tags (`created_by`, `batch_account`, `batch_region`) are empty** —
  the job was submitted with an older application package. Re-upload the package
  (Step 3) and resubmit; there's no way to backfill tags on already-running jobs.
- **Wrong Application Insights resource / stale instrumentation key** — re-run
  `package_and_upload_telegraf` with the correct resource name; it always re-embeds a
  fresh key and sets a new default version, so existing pools pick it up on their next
  job (they always reference the "default" version, not a pinned one).
- **Multiple Application Insights resources share the same name in your subscription** —
  the packaging script warns and uses the first match; rename resources to be unique or
  pass a more specific resource group scope if this happens.

## What consumes this data

The [stuck-job alerting pipeline](schism_alerting_setup.md) queries `customMetrics` for
`schism_time` on a schedule, compares recent vs. earlier values per host, and fires an
alert (email notification, then automatic job termination) when the value stops
advancing. See that document for the full alerting/termination setup.
