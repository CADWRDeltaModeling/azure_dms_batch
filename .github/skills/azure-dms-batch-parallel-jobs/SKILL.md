---
name: azure-dms-batch-parallel-jobs
description: 'Use when submitting or designing massively-parallel, embarrassingly-parallel Azure Batch jobs with azure_dms_batch (the `dmsbatch` CLI/package) -- i.e. many independent tasks that do NOT communicate with each other (parameter sweeps, one-run-per-combination studies, e.g. DSM2/GTM Green''s-function node x knot runs, PTM particle-insertion runs). Covers the dmsbatch YAML job-config schema, the task_ids parameter-sweep mechanism, resource_files/output_files/blob_prefix wiring, job-level prep tasks (job_start_command_template) for one-time shared setup, app_pkgs vs container images, the templates/<name>/ directory anatomy, and storage-account bootstrapping with azcopy/AzureBlob. Not for MPI/multi-node coordinated jobs (mpi_command/coordination_command -- see README-schism-batch.md instead).'
---

# azure_dms_batch: massively-parallel, no-inter-task-communication jobs

## When to use

Any time you need to run **many independent DSM2/SCHISM/PTM/etc. simulations that don't
talk to each other** on Azure Batch via this repo's `dmsbatch` package -- e.g. one
DSM2-GTM run per (node, knot) pulse, one PTM run per (insertion node, start date), a
parameter sweep over model variants. If tasks need MPI/inter-node coordination, this is
the wrong pattern -- see `mpi_command`/`coordination_command_template` and
`README-schism-batch.md` instead.

## Mental model: pool -> job -> tasks

```
dmsbatch submit-job --file config.yml
    |
    +--> create_pool()      one Azure Batch POOL (VMs), from templates/<name>/pool.bicep
    |                       interNodeCommunication: Disabled for this use case
    |
    +--> submit_task()      one Azure Batch JOB
            |
            +--> job "prep task" (runs ONCE per job, on every node before any task)
            |       built from job_start_command_template + job_start_command_resource_files
            |       -- the right place for shared, run-once setup (e.g. staging a
            |       pre-computed HYDRO tidefile onto $AZ_BATCH_NODE_SHARED_DIR so every
            |       GTM task on that node can read it without re-downloading/re-running)
            |
            +--> one TASK per entry in task_ids (submitted in batches of 100 via
                    client.submit_tasks) -- this is where the actual embarrassingly-
                    parallel work happens, one task = one independent run
```

## The `task_ids` parameter-sweep mechanism

`task_ids` in the YAML is a **string containing a small Python program**, evaluated with
`exec_then_eval()` (`dmsbatch/batch.py`): the code runs, and its **last line must be an
expression that evaluates to a list** -- typically a list of lists/tuples, one per task.
See `sample_configs/sample_dsm2_ptm.yml` for a full working example (loops over an
insertion-node CSV x year x month grid, appending
`[job_name_prefix, run_no, particle_no, insertion_node, ptm_start_date, ptm_end_date, particle_insertion_row]`
per task).

Each element of that list becomes `config_dict["task_id"]` for one task, and **every
other string field in the YAML can reference `task_id` by index**:
`{task_id[0]}`, `{task_id[1]}`, ... -- typically bound to friendlier names first
(`run_no: '{task_id[1]}'`) which are then used everywhere else (`environment_variables`,
`command`, `resource_files[].blob_prefix`, `output_files[].path`, `task_name`).

Substitution order matters: `create_substituted_dict()` / `substitute_values()` does
several passes of `str.format_map()` over the whole config dict so forward references
resolve, but if you introduce a brand-new derived field, make sure it's derivable from
`task_id[i]` plus already-defined config keys.

## Command wiring: `command:` vs `application_command_template`

You almost never write a full task script yourself. You write a `command:` block (plain
shell/batch lines) in your job YAML; the **template's**
`application_command_template.sh`/`.bat` wraps it (captures stdout/stderr to files that
get uploaded, sets `set -e`/`ERRORLEVEL` handling, runs `{app_pkgs_script}` first). Look
at `dmsbatch/templates/<template_name>/application_command_template.sh` before writing a
new template -- reuse an existing one (e.g. `dvsm_container`) rather than inventing a new
wrapper unless your OS/toolchain genuinely needs a different envelope.

`job_start_command_template` (and, less commonly, `application_command_template`) can
also be overridden **inline, as a literal multi-line command string directly in your job
YAML** instead of a template file path -- `load_command_from_resourcepath()` tries to
read the value as a packaged file first, and silently falls back to treating it as the
literal command text if that fails (see `sample_configs/sample_dsm2_ptm.yml`'s
`job_start_command_template: |` block, which moves a shared tidefile into
`$AZ_BATCH_NODE_SHARED_DIR` -- exactly the pattern to reuse for staging any large,
node-shared, run-once artifact).

## `app_pkgs` (Application Packages) vs container images

Two different, non-interchangeable mechanisms for getting your model binaries onto the
compute node:

- **`app_pkgs`** (used by `win_dsm2` for DSM2 binaries): a list of
  `{name, version?, init_script}`. Each entry corresponds to an **Azure Batch
  Application Package** that must already be uploaded to the Batch account (via
  `az batch application package create` or the portal) -- a separate bootstrapping step
  from uploading study data to blob storage. At pool-creation time,
  `templates/<name>/pool.bicep`'s `applicationPackages` list makes it available on every
  node, mounted at `$AZ_BATCH_APP_PACKAGE_<name>` (or `$AZ_BATCH_APP_PACKAGE_<name>#<version>`
  if versioned). Each entry's `init_script` (string) is concatenated by
  `build_app_pkg_scripts()` into `{app_pkgs_script}`, which the
  `application_command_template` inserts before `{command}` -- use it to extend
  `PATH`/set `DSM2_HOME` etc. This is the mechanism to use for a Linux DSM2/GTM binary
  bundle per the "no container" requirement.
- **`container_image_name` + `container_run_options`** (used by `dvsm_container`): runs
  the whole task inside a pre-built Docker image (`cadwrdms/dsm2:...`) instead. Simpler
  if a suitable image already exists, but requires maintaining/publishing that image.

Do not mix metaphors -- pick one per template. A new Linux, non-container DSM2/GTM
template should follow `win_dsm2`'s `app_pkgs`-based pattern, translated to bash
(`export PATH=$AZ_BATCH_APP_PACKAGE_dsm2/DSM2.../bin:$PATH` instead of `set PATH=...`),
not `dvsm_container`'s container pattern.

## `resource_files` / `output_files` -- blob storage wiring

- `resource_files: [{file_path, blob_prefix}]` -- downloaded from
  `storage_container_name` (via `auto_storage_container_name`, i.e. the pool's
  auto-storage association, not a manually-built SAS URL) into the task's working
  directory before `command` runs. `blob_prefix` can be a single blob or a folder
  prefix (all matching blobs are pulled) and may reference `{task_id[i]}`-derived fields
  for a per-task input file.
- `output_files: [{file_pattern, path, upload_condition}]` -- uploaded from the task's
  working directory to `{storage_container_name}/{path}` (using a SAS URL built with
  `get_sas()`) after the task finishes. `upload_condition` is one of
  `tasksuccess`/`taskfailure`/`taskcompletion`. `path` typically encodes per-task
  identity (`'outputs/{study_name}/{ptm_start_date}/{run_no}'`) so every task's outputs
  land in a distinct, predictable blob path -- this is what a later collation/reduction
  step reads back.
- `job_start_command_resource_files` -- same shape, but downloaded **once**, by the
  job's prep task, onto `$AZ_BATCH_NODE_SHARED_DIR` (shared across every task
  subsequently scheduled on that node). This is the correct place for a large, common,
  run-once artifact (e.g. a precomputed HYDRO tidefile) that every task-level GTM run
  needs to read but none of them should re-fetch or regenerate individually.

## Storage-account bootstrapping (before submitting the job)

Study inputs referenced by `resource_files`/`study_dir` must already exist as blobs in
`storage_container_name` -- `dmsbatch` does not upload your local study tree for you as
part of job submission (it only uploads the job's own YAML config file, for the record,
inside `submit_job()`). Two supported ways to get local files into the container ahead
of time:

1. **azcopy** (what `dmsbatch`'s own `upload_batch_scripts()` helper in
   `dmsbatch/commands.py` uses internally): generate a SAS token with
   `get_sas(storage_account_name, storage_account_key, container_name)` (wraps
   `az storage container generate-sas`), then
   `azcopy cp "<local_dir>/*" "https://<account>.blob.core.windows.net/<container>?<sas>" --recursive=true`.
2. **`AzureBlob` class** (`dmsbatch/commands.py`) -- programmatic upload from Python:
   `AzureBlob(storage_account_name, storage_account_key).upload_file_to_container(container_name, blob_path, local_path)`,
   plus `get_container_sas_token()`/`get_container_sas_url()` helpers if you need a URL
   instead of calling azcopy as a subprocess.

Either way, get the account key first (`get_batch_account_key`/`get_storage_account_key`
in `dmsbatch/commands.py`, both wrap `az cli` and require `az login` to the right
subscription -- or set the `BATCH_ACCOUNT_KEY`/`STORAGE_ACCOUNT_KEY` env vars to skip
the `az cli` round-trip).

## `templates/<template_name>/` anatomy

Every template directory needs:

| File | Purpose |
|---|---|
| `default_config.yml` | Defaults merged into your job YAML via `update_if_not_defined()` -- your YAML only needs to override what's different. |
| `application_command_template.sh`/`.bat` | Wraps your `command:` block (stdout/stderr capture, exit-code handling, `{app_pkgs_script}` prelude). |
| `coordination_command_template.sh`/`.bat` | Only relevant for `mpi_command` jobs -- not used for embarrassingly-parallel jobs. |
| `job_start_command_template.sh`/`.bat` | The job-level prep-task script -- one-time setup shared by every task in the job. |
| `pool.bicep` + `pool.parameters.json` | Defines the VM pool: image, `applicationPackages`, `interNodeCommunication` (`Disabled` for this pattern), autoscale formula, start task. |
| `autoscale_formula.txt` | Pool autoscale formula (`$TargetDedicatedNodes = ...`). |

To add a new massively-parallel job type (e.g. Linux DSM2/GTM via `app_pkgs`): copy the
closest existing template (`win_dsm2` for the `app_pkgs` pattern translated to bash, or
`dvsm_container` for the generic Linux command-wrapper pattern) rather than starting from
scratch, and change only what differs (OS image, `app_pkgs`, `application_command_template`
shell dialect).

## Step-by-step: setting up a new parameter-sweep job

1. Confirm/bootstrap the storage container with the study's common inputs (azcopy or
   `AzureBlob`, see above) -- these are read via `resource_files`/`study_dir`, shared
   read-only across every task.
2. If there's a large shared artifact common to every task (e.g. a tidefile), upload it
   too, and reference it via `job_start_command_resource_files` +
   `job_start_command_template` so it's staged once per node, not once per task.
3. Pick or write a `template_name` (`app_pkgs` if binaries come from an Azure Batch
   Application Package, `container_image_name` if from a Docker image).
4. Write `task_ids` as a small Python snippet whose last line is the list of per-task
   tuples -- one tuple per independent run, containing every value that varies task to
   task (IDs, dates, node numbers, ...).
5. Bind friendly names to `task_id[i]` indices, then use those names in `command`,
   `environment_variables`, `resource_files`, `output_files`, `task_name` -- never
   hardcode a per-task value directly.
6. Make sure every `output_files.path` is unique per task (derived from the bound
   `task_id` names) so a later, separate reduction/collation job can find and combine
   every task's output deterministically.
7. `dmsbatch submit-job --file <config.yml> [--log-level DEBUG]` to submit; tasks are
   batched to Batch in groups of 100 automatically.

## Gotchas

- `task_ids` is `exec`'d Python -- keep it simple/deterministic (no external I/O beyond
  reading a small local CSV) since it runs locally at submission time, not on a compute
  node.
- `resource_files`/`output_files` `blob_prefix`/`path` values go through the same
  `{task_id[i]}`-style substitution as everything else -- a typo there silently produces
  a distinct-but-wrong blob path rather than an error.
- `interNodeCommunication: Disabled` in `pool.bicep` is what makes a pool suitable for
  this pattern (vs. an MPI pool) -- don't copy an MPI template's `pool.bicep` unmodified.
- Application Packages (`app_pkgs`) must be uploaded to the **Batch account** ahead of
  time (a one-time `az batch application package create`, outside `dmsbatch` entirely) --
  this is separate from and easy to confuse with uploading study data to the **storage
  account** container.
- `job_start_command_template`/prep task runs once **per node**, not once per job -- if
  the pool autoscales to N nodes, the shared setup happens N times (once per node), not
  N times per task.
