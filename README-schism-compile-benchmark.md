# Compiling and Benchmarking SCHISM on Azure Batch

This document describes the end-to-end process for (1) compiling SCHISM from source on Azure Batch and registering it as an application package, and (2) benchmarking MPI tuning options to find the fastest configuration for a given VM SKU. It complements [README-schism-batch.md](README-schism-batch.md), which covers submitting a production SCHISM run once a compiled package and tuned MPI settings already exist.

There is also an agent prompt that automates generation of the artifacts in Part 1: [.github/prompts/schism-compile-package.prompt.md](.github/prompts/schism-compile-package.prompt.md).

## Part 1: Compiling SCHISM

Compilation uses the [`build_schism_alma810`](dmsbatch/templates/build_schism_alma810) template: a single-node, admin, no-NFS/no-MPI-coordination job that builds SCHISM and its dependencies from source, zips the result, uploads it to blob, and registers it as a Batch application package — all in one job.

The build logic itself lives in [schism_scripts/batch/schism_build.sh](schism_scripts/batch/schism_build.sh), which builds HDF5, NetCDF-C, NetCDF-Fortran and GOTM, then compiles `pschism` with `-DBLD_STANDALONE=ON -DTVD_LIM=VL -DPREC_EVAP=ON -DUSE_GOTM=ON`, using the MPI variant given as its argument (`mvapich2`, `mvapich2-ndr-patch`, `openmpi`, `hpcx`, or `intelmpi`).

### 1. One-time setup: build identity

Run [app-packages/setup_build_identity.sh](app-packages/setup_build_identity.sh) once per Batch account. It creates a user-assigned managed identity with rights to register application packages, so the compute node can register the compiled package itself via `az login --identity` during the build — no SAS token or personal credentials needed for that step. Paste the resulting identity resource ID into the build template's `pool.bicep` (`buildIdentityResourceId` parameter) and into your job YAML (`build_identity_resource_id`).

The script's defaults target the original account/resource group/location it was written for; override via environment variables to target any other account/resource group, e.g. a UserSubscription/custom-image account such as `my_batch` (used by the [build_schism_alma810_customimage_usersub](dmsbatch/templates/build_schism_alma810_customimage_usersub) template):

```bash
RESOURCE_GROUP=my_rg BATCH_ACCOUNT_NAME=my_batch \
  LOCATION=my_location IDENTITY_NAME=my-build-identity \
  bash app-packages/setup_build_identity.sh
```

This is a one-time step per Batch account — skip it if the identity already exists (check with `az identity show --name <IDENTITY_NAME> --resource-group <RESOURCE_GROUP>`).

### 2. Write a build job YAML


Base it on [sample_configs/build_schism_alma810_mvapich2.yml](sample_configs/build_schism_alma810_mvapich2.yml). Key fields:

```yaml
template_name: "build_schism_alma810"
vm_size: standard_hb120rs_v2   # or HB120rs_v3 / HB176rs_v4 / HC44rs
num_hosts: 1
run_as_admin: true
delete_after_mins: 480         # build can take a while; adjust as needed

mpi_variant: hpcx              # mvapich2 | mvapich2-ndr-patch | openmpi | hpcx | intelmpi
schism_version: v5.13
os_ver: alma8.10hpc
hdf5_version: "1.14.6"
netcdf_c_version: "4.10.0"
netcdf_fortran_version: "4.6.2"
gotm_version: "v6.0.7"
make_default: "true"           # set this build as the default app package version

full_version: "{schism_version}_{mpi_variant}_{os_ver}_{vm_variant}"
zip_name: "schism_with_deps_{full_version}.zip"
study_dir: "apps/{job_name}"   # blob upload destination

command: |
  sudo env SCHISM_VERSION={schism_version} OSVER={os_ver} \
    HDF5_VERSION={hdf5_version} NETCDF_C_VERSION={netcdf_c_version} \
    NETCDF_FORTRAN_VERSION={netcdf_fortran_version} GOTM_VERSION={gotm_version} \
    bash $AZ_BATCH_APP_PACKAGE_batch_setup/batch/schism_build.sh {mpi_variant};
  azcopy copy /tmp/{zip_name} "https://{storage_account_name}.blob.core.windows.net/{storage_container_name}/{study_dir}/{zip_name}?{sas}";
  az login --identity;
  az batch application package create --application-name schism_with_deps \
    --name "{batch_account_name}" --package-file /tmp/{zip_name} \
    --resource-group "{resource_group}" --version-name "{full_version}";
  az batch application package activate --application-name schism_with_deps \
    --name "{batch_account_name}" --resource-group "{resource_group}" \
    --version-name "{full_version}" --format zip;
  if [ "{make_default}" = "true" ]; then
      az batch application set --application-name schism_with_deps \
        --default-version "{full_version}" --name "{batch_account_name}" \
        --resource-group "{resource_group}";
  fi
```

### 3. Submit the build job

```bash
az login --use-device-code
dmsbatch submit-job --file build_schism_v5.13_hpcx_alma8.10hpc.yml
```

Monitor via Azure Portal / Batch Explorer, or:

```bash
az batch job show --job-id <job_id> --account-name <batch_account>
```

### 4. Verify registration

The job registers and activates the package itself using the managed identity. Confirm with:

```bash
az batch application show --application-name schism_with_deps --name <batch_account> -g <resource_group>
```

If compiling manually/offline instead of via the self-registering job, use [app-packages/register_schism_with_deps_v5.11.1_alma8.10hpc_mvapich2.sh](app-packages/register_schism_with_deps_v5.11.1_alma8.10hpc_mvapich2.sh) as a template: it downloads the zip from blob, then runs `az batch application package create` followed by `az batch application set --default-version`.

### 5. Point production pools at the new package

```bash
grep -r "schism_with_deps" dmsbatch/templates/
```

Update the `version` in each affected template's `default_config.yml` / `pool.bicep` `applicationPackages` entry. If the VM SKU changed, delete `dmsbatch/templates/vm_core_map.yml` to force a refresh of the cached SKU/core-count lookup.

## Part 2: Benchmarking

Benchmarking sweeps MPI tuning environment variables (NUMA binding, SHARP, memory registration cache sizes, etc.) and measures simulated days per minute, so the best settings for a given VM SKU can be baked into production job templates. The shared helper logic is in [schism_scripts/batch/schism_bench_lib.sh](schism_scripts/batch/schism_bench_lib.sh); the two entry-point scripts are:

* [schism_mpi_timing_test_mvapich2.sh](schism_scripts/batch/schism_mpi_timing_test_mvapich2.sh) — MVAPICH2 on HBv2/HBv3
* [schism_mpi_timing_test.sh](schism_scripts/batch/schism_mpi_timing_test.sh) — HPC-X/OpenMPI on HBv4/HBv5

### 1. Prepare a study directory

Use a real (or scaled-down) SCHISM study with `param.nml`, `sflux/`, and optionally a hotstart file. Copy it to blob storage with `azcopy` as usual.

### 2. Submit a benchmark job

Reuse a normal MPI job template, but point `mpi_command` at the timing script instead of `pschism` directly. See the archived example [test_configs/_archive/timing_hbv3.yml](test_configs/_archive/timing_hbv3.yml):

```yaml
template_name: "alma810_mvapich2_202505290_hbv3"
vm_size: Standard_HB120rs_v3
num_hosts: 3
mpi_command: |
  cd sflux; rm -f *.nc; python make_links.py; cd ..
  $SCHISM_SCRIPTS_HOME/batch/schism_mpi_timing_test_mvapich2.sh . 1251 {num_cores} {num_scribes}
```

Script arguments: `study_dir rnday num_cores num_scribes [max_mins]`. `rnday` is the absolute end-day patched into `param.nml`; leave it blank (`""`) for hotstart runs to keep the value already in `param.nml`.

### 3. What the script does

For each variant in its built-in matrix (NUMA `bunch`/`scatter` binding, `MV2_ENABLE_SHARP`, NDREG cache sizes, homogeneous-cluster flag, etc.) it:

1. Restores `param.nml` and `outputs/` from a clean backup (`bench_init_backups` / `restore_outputs`).
2. Launches `mpirun` with that variant's environment variables.
3. Polls `outputs/flux.out` every 30s (`BENCH_POLL_INTERVAL`), starting the clock on the *first detected change* to exclude mesh-load/init time, and computes `sim_days_per_minute`.
4. Detects stuck runs (no progress for `BENCH_STUCK_POLLS` polls) or per-variant timeouts (`BENCH_TIMEOUT_MINS`) and kills them.
5. Appends a row to `mpi_timing_results_mvapich2.txt` (or `mpi_timing_results.txt` for the HPC-X script): `label|sim_days_per_min|wall_secs|mpirun_exit|last_sim_day|first_sim_day|extra_env_vars`.

> [!WARNING]
> The timing scripts clear `outputs/` between each variant run. Do not point them at a study directory whose outputs you need to keep.

### 4. Retrieve and compare results

The results file syncs back to blob under the study directory like any other output file — download it via `azcopy` / Azure Storage Explorer, or SSH to the master node (see [README-schism-batch.md](README-schism-batch.md#ssh-access-to-master-node-for-interactive-debugging)) and:

```bash
cat mpi_timing_results_mvapich2.txt
```

Pick the row with the highest `sim_days_per_min` and `mpirun_exit=0`.

### 5. Bake the winning configuration into production

Hardcode the winning environment variables into the template's `default_config.yml` under `mpi_tuning_opts`, so production jobs pick them up automatically via `mpi_opts: --bind-to core --np {num_cores} -f hostfile {mpi_tuning_opts}`. See [dmsbatch/templates/alma810_mvapich2_202505290_hbv3/default_config.yml](dmsbatch/templates/alma810_mvapich2_202505290_hbv3/default_config.yml), which documents past winners (`numa_bunch_ndreg`, `full_combo`) directly in comments — follow that pattern when recording new results.

## Related Documentation

* [README-schism-batch.md](README-schism-batch.md) — submitting production SCHISM jobs, troubleshooting, SSH debugging
* [README-batch-job-yaml.md](README-batch-job-yaml.md) — job YAML configuration reference
* [README-script-templates.md](README-script-templates.md) — how job/application/coordination command templates work
* [AGENTS.md](AGENTS.md) — quick-reference summary of this repo for coding agents
