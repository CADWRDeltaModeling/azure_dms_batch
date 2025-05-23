# Azure DMS Batch Job Submission Guide

This document provides guidance on how to use the `dmsbatch submit-job` command and explains the structure of the YAML configuration files used to submit batch jobs.

## Overview

The `dmsbatch` tool allows you to submit jobs to Azure Batch using a YAML configuration file that defines all aspects of the job, including:

- Resource specifications (pool size, VM type)
- Job parameters
- Input/output file handling
- Application packages
- Commands to execute

## Using the `dmsbatch submit-job` Command

### Basic Usage

```bash
dmsbatch submit-job --file <config_file.yml> [--pool-name <existing_pool_name>] [--log-level <LOG_LEVEL>]
```

### Parameters

- `--file`: Path to the YAML configuration file (required)
- `--pool-name`: Name of an existing pool to use (optional). If not specified, a new pool will be created.
- `--log-level`: Set logging level to DEBUG, INFO, WARNING, ERROR, or CRITICAL (default: INFO)

### Example

```bash
dmsbatch submit-job --file my_job_config.yml --log-level DEBUG
```

## YAML Configuration File Structure

The YAML configuration file defines how your job will be set up and executed on Azure Batch. Below is an explanation of the main sections and parameters:

### Required Parameters

```yaml
# Basic identification and resource information
resource_group: my_resource_group          # Azure resource group name
job_name: my_job                           # Name for this job (will be used for pool/job naming)
batch_account_name: my_batch_account       # Azure Batch account name
storage_account_name: my_storage_account   # Azure Storage account name
storage_container_name: my_container       # Storage container for input/output files
template_name: win_dsm2                    # Template to use (folder name in dmsbatch/templates/)

# Job specifications
vm_size: standard_ds2_v2                   # Azure VM size to use
num_hosts: 1                               # Number of VMs to create in the pool
```

### Common Optional Parameters

```yaml
location: eastus                           # Azure region (defaults to eastus)
ostype: windows                            # OS type: 'windows' or 'linux'
study_dir: mystudy                         # Directory in storage container with job files
delete_after_mins: 240                     # Auto-delete job after specified minutes
command: echo "Hello World"                # Command to execute (can be overridden by template)
```

### Template-specific Parameters

Each template may have its own specific parameters defined in its `default_config.yml` file. For example, the `win_dsm2` template defines:

```yaml
# Environment variables for the job
environment_variables:
  DSM2_HOME: "%AZ_BATCH_APP_PACKAGE_dsm2%\\DSM2-8.2.c5aacef7-win32"
  PATH: "%PATH%;%DSM2_HOME%\\bin"

# Application packages to be installed
app_pkgs:
  - name: azcopy
    init_script: set PATH=%PATH%;%AZ_BATCH_APP_PACKAGE_azcopy%\azcopy_windows_amd64_10.25.1
  - name: dsm2
    init_script: set DSM2_HOME=%AZ_BATCH_APP_PACKAGE_dsm2%\DSM2-8.2.c5aacef7-win32 & set PATH=%PATH%;%DSM2_HOME%\bin
  - name: unzip
    init_script: set PATH=%PATH%;%AZ_BATCH_APP_PACKAGE_unzip%\bin
```

### Input/Output File Specifications

```yaml
# Input files to be downloaded to the VM
resource_files:
  - blob_prefix: "input/model.zip"
    file_path: "model.zip"

# Output files to be uploaded from the VM
output_files:
  - file_pattern: "output/**/*.dss"
    path: "results"
    upload_condition: "taskCompletion"
```

### Container Settings (for containerized jobs)

```yaml
container_image_name: 'cadwrdms/dsm2:8.2.2-intel_2022.2-almalinux_9.3-54a9cc3'
container_run_options: '--rm'
```

## Template System

The framework uses a template system where common configurations are stored in the `dmsbatch/templates/<template_name>/` directory. Each template includes:

- `default_config.yml`: Default values for the template
- `application_command_template.sh` or `.bat`: Command template for running the application
- `pool.bicep`: Azure Bicep template for pool creation
- Other supporting files

Your job config can override any values from the template's default config.

## Sample Configuration

Here's a sample configuration file that submits a simple echo command:

```yaml
# Basic configuration
resource_group: my_resource_group
job_name: echo_test_job
batch_account_name: my_batch_account
storage_account_name: my_storage_account
storage_container_name: batch
template_name: win_dsm2
study_dir: test_echo

# VM configuration
vm_size: standard_ds2_v2
num_hosts: 1

# Job configuration
command: 'echo "This is a test job"'
delete_after_mins: 60

# Environment variables
environment_variables:
  TEST_VAR: "Hello World"
```

## Common Templates

The framework provides several templates for different use cases:

- `win_dsm2`: Windows-based DSM2 model runs
- `alma87_mvapich2_20241018`: Linux-based MPI jobs with MVAPICH2
- `alma87_mvapich2_20241018_pp`: Post-processing template for Linux
- `dvsm_container`: Linux container-based job template

## Advanced Features

### MPI Jobs

For MPI jobs, use additional parameters:

```yaml
num_hosts: 4                 # Number of nodes in the MPI cluster
task_slots_per_node: 120     # Number of CPU cores per node to use
mpi_command: 'mpiexec -n 480 ./my_app'  # MPI execution command
```

mpi_command indicates that the pool should be setup with inter-node communication enabled. This triggers the creation of a pool with nodes, where one node is the head node and the rest are compute nodes. The coordinatation command will be executed on all nodes in the pool and the mpi_command will be executed on the head node. The MPI command should be a valid command that can be run on the head node.


## Troubleshooting

If your job fails:
- Check the Azure portal or Batch Explorer for task error messages
- Examine task stdout and stderr files in the storage account
- For running pools, you can SSH or RDP into the nodes for direct debugging
- Check the log level to DEBUG for more detailed logs: `--log-level DEBUG`

## References

For more detailed information, refer to:
- [Azure DMS Batch README](README.md)
- [SCHISM-specific configuration](README-schism-batch.md)