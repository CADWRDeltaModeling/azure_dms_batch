---
description: "Generate a SCHISM build job YAML and registration script for the compile → zip → register-as-app-package workflow on Azure Batch. Use when compiling a new SCHISM version or changing the MPI/OS variant."
argument-hint: "SCHISM version (e.g. 5.11.1), OS image (e.g. alma8.10), MPI variant (e.g. mvapich2 | hpcx), batch account, resource group"
agent: agent
---

Generate all artifacts needed to compile SCHISM on Azure Batch and register the result as an application package.

## Inputs (extract from user message or ask if missing)

| Parameter | Example |
|-----------|---------|
| `schism_version` | `5.11.1` |
| `os_label` | `alma8.10hpc` |
| `mpi_variant` | `mvapich2` or `hpcx` |
| `num_cores` | `120` (default for HB120rs_v3) |
| `batch_account_name` | `schismbatchscus` |
| `resource_group` | `dwrbdo_schism_scus_rg` |
| `storage_account_name` | `schismsascus` |
| `storage_container` | `batch` |
| `blob_output_path` | `apps/build_schism_alma810` |

Derived names (compute from the inputs above):
- `package_version` = `v{schism_version}_{os_label}_{mpi_variant}` (e.g. `v5.11.1_alma8.10hpc_mvapich2`)
- `zip_name` = `schism_with_deps_{package_version}.zip`

---

## Step 1 – Build job YAML

Create `build_schism_{schism_version}_{os_label}_{mpi_variant}.yml` using the
[`build_schism_alma810` template](../../dmsbatch/templates/build_schism_alma810/default_config.yml).

Key settings to include:
- `template_name: build_schism_alma810`
- `vm_size: Standard_HB120rs_v3` (or HB176rs_v4 / HC44rs for other H-series)
- `num_hosts: 1` — single-node build, no MPI coordination needed
- `run_as_admin: true` — required by the template
- `delete_after_mins: 480` — pool lives 8 h; adjust if build takes longer
- `command:` — cmake configure + make invocation; `make -j {num_cores}`
  - Load MPI with `module load mpi/mvapich2` (or `mpi/hpcx` for hpcx variant); template already does this via `application_command_template.sh`
  - After `make`, zip the install tree and upload to blob via `azcopy`:
    ```bash
    zip -r /tmp/{zip_name} /path/to/install/
    azcopy copy /tmp/{zip_name} "https://{storage_account_name}.blob.core.windows.net/{storage_container}/{blob_output_path}/{zip_name}?<SAS>"
    ```
  - Generate the azcopy SAS token with:
    ```bash
    az storage blob generate-sas --account-name {storage_account_name} \
      --container-name {storage_container} --name {blob_output_path}/{zip_name} \
      --permissions w --expiry $(date -u -d '+4 hours' +'%Y-%m-%dT%H:%MZ') --output tsv
    ```

Reference: [README-schism-batch.md](../../README-schism-batch.md), [application_command_template.sh](../../dmsbatch/templates/build_schism_alma810/application_command_template.sh)

---

## Step 2 – Submit the build job

```bash
dmsbatch submit-job --file build_schism_{schism_version}_{os_label}_{mpi_variant}.yml
```

Monitor in Azure Portal → Batch Explorer, or via:
```bash
az batch job show --job-id <job_id> --account-name {batch_account_name}
```

---

## Step 3 – Register the compiled package

Create `app-packages/register_schism_with_deps_{package_version}.sh` modelled on
[register_schism_with_deps_v5.11.1_alma8.10hpc_mvapich2.sh](../../app-packages/register_schism_with_deps_v5.11.1_alma8.10hpc_mvapich2.sh)
with the new version strings substituted.

The script must:
1. Download `{zip_name}` from blob using `az storage blob download`
2. Register the package: `az batch application package create --application-name schism_with_deps --version-name {package_version} ...`
3. Set it as the default: `az batch application set --application-name schism_with_deps --default-version {package_version} ...`

---

## Step 4 – Update pool templates

If new MPI or OS variant, check whether existing `pool.bicep` files reference the old package version and update `applicationPackages` entries accordingly.  Search with:
```
grep -r "schism_with_deps" dmsbatch/templates/
```

---

## Output

Produce the following files (show full content):
1. **`build_schism_{schism_version}_{os_label}_{mpi_variant}.yml`** — build job config
2. **`app-packages/register_schism_with_deps_{package_version}.sh`** — registration script

After generating, remind the user:
- Run `az login --use-device-code` before executing any `az` or `dmsbatch` commands.
- The `azcopy` SAS token expires — regenerate if re-running the upload step.
- After registration, delete `dmsbatch/templates/vm_core_map.yml` if VM type changed (forces SKU cache refresh).
