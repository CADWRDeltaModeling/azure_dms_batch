

# AZURE DMS BATCH
## YAML Configuration System - The Power of Templates

**The YAML configuration and template system is what makes Azure DMS Batch uniquely powerful and flexible.**

With just a simple YAML file, you can define and submit complex Azure Batch jobs without writing any code:

```yaml
# Basic job configuration
resource_group: my_resource_group
job_name: test_job
batch_account_name: my_batch_account
storage_account_name: my_storage_account
template_name: win_dsm2

# VM configuration
vm_size: standard_ds2_v2
num_hosts: 1

# Command to execute
command: 'echo "This is a test job"'
```

Submit your job with a single command:

```bash
dmsbatch submit-job --file my_config.yml
```

### Key Benefits:

1. **Simple Job Definition** - Define all aspects of your job in a clean, readable YAML format
2. **Pre-built Templates** - Use specialized templates for different workloads (DSM2, SCHISM, MPI, etc.)
3. **Minimal Configuration** - Override only the parameters you need; inherit sensible defaults from templates
4. **Dynamic Substitution** - Use variable references and custom tags for flexible configurations
5. **Template-Based Architecture** - Standardized approach for different model types

### Documentation:

* [**Job YAML Configuration Guide**](README-batch-job-yaml.md) - How to write job configuration YAML files
* [**Template System Documentation**](README-batch-yaml-template.md) - Deep dive into how the template system works

# Azure Batch runs for Models 

Models are processes that take input and process via files and environment variables and run an executable producing output

(input(s) --> EXE --> output(s))

![Azure Batch Job Architecture](docs/tech_overview_03.png)

Azure Batch runs for a model, i.e., a executable that runs independently based on a set of input files and environment
variables and produces a set of output files.


# Setup package
Use the environment.yml with conda to create an environment called azure
```
conda env create -f environment.yml
```
or
```
pip install -r requirements.txt
```
Git clone this project
```
git clone https://github.com/CADWRDeltaModeling/azure_dms_batch.git
```
Change directory to the location of this project and then install using
```
pip install --no-deps -e .
```

# Setup Azure

Setup can be done via az commands. Here we setup a batch account with associated storage

## Login with your Azure credentials

```az login ```

## Create a resource group in the desired location

See the [Azure docs](https://docs.microsoft.com/en-us/azure/azure-resource-manager/management/manage-resource-groups-portal) for details. To use the commands below, enter your values (replacing the angle brackets and values)

```az group create --name <resource_group_name> --location <location_name>```

```az storage account create --resource-group <resource_group_name> --name <storage_account_name> --location <location_name> --sku Standard_LRS```

```az batch account create --name <batch_account_name> --storage-account <storage_account_name> --resource-group <resource_group_name> --location <location_name>```

You can also create the batch account and associated account as explained here https://docs.microsoft.com/en-us/azure/batch/batch-account-create-portal

## VM sizes available

This is needed later when deciding what machine sizes to use

```az batch location list-skus --location <location_name> --output table```

You can also browse [the availability by region](https://azure.microsoft.com/en-us/global-infrastructure/services/?regions=us-west-2&products=virtual-machines) as not all VMs are available in every region

This [page is to guide selection of VMs](https://azure.microsoft.com/en-us/pricing/vm-selector/) by different attributes

This is needed later when deciding what machine sizes to use

```az batch location list-skus --location <location_name> --output table```

You can also browse [the availability by region](https://azure.microsoft.com/en-us/global-infrastructure/services/?regions=us-west-2&products=virtual-machines) as not all VMs are available in every region

This [page is to guide selection of VMs](https://azure.microsoft.com/en-us/pricing/vm-selector/) by different attributes

## OS Images available

```
set AZ_BATCH_ACCOUNT=<batch_account_name>
set AZ_BATCH_ACCESS_KEY=<batch_account_key>
set AZ_BATCH_ENDPOINT=<batch_account_url>
az batch pool supported-images list --output table
```
A [sample output](notebooks/osimage.list.txt) is included for quick reference 

# Tools
Azure allows you to do most things via the command line interface (cli) or the web console. However I have found the following
desktop apps useful for working with these services.

[Batch Explorer](https://azure.github.io/BatchExplorer/) is a desktop tool for managing batch jobs, pools and application packages

[Storage Explorer](https://azure.microsoft.com/en-us/features/storage-explorer/) is a desktop tool for working with storage containers

## Sample Configuration Files

For all new projects, we recommend using the YAML configuration system instead of writing Python code directly:

```bash
# Submit a job using a YAML configuration file
dmsbatch submit-job --file my_config.yml
```

This approach is much simpler than the notebook examples and provides all the same capabilities. We have several example configuration files in the [sample_configs](./sample_configs/) directory, such as:

- [sample_dsm2_ptm.yml](./sample_configs/sample_dsm2_ptm.yml) - DSM2 Particle Tracking Model
- [sample_container_echo.yml](./sample_configs/sample_container_echo.yml) - Container-based job
- [sample_schism_pp.yml](./sample_configs/sample_schism_pp.yml) - SCHISM post-processing

## SCHISM specific runs
 See the detailed documentation for SCHISM specific run setup in [README-schism-batch.md](README-schism-batch.md)

## MPI runs

> **Note:** For MPI workloads, YAML configuration is now the recommended approach. See the [SCHISM-specific configuration guide](README-schism-batch.md) and the [template system documentation](README-batch-yaml-template.md#coordination_command_templateshbat-for-mpi-jobs) for details.


## Parameterized runs

> **Note:** For information on how to submit parameterized runs, see the [architecture documentation](README-architecture.md#parameterized-runs).

An [example notebook for PTM batch runs that vary based on environment variables](./notebooks/sample_submit_ptm_batch.ipynb) demonstrates this capability. It also shows an example where a large file needs to be uploaded and shared with all the running tasks.

## Beopest runs

> **Note:** For information on how BeoPEST is implemented, see the [architecture documentation](README-architecture.md#beopest-implementation).
 
This [notebook showing an implementation of the beopest run scheme](./notebooks/sample_submit_beopest.ipynb) demonstrates how this works.
 
# Sample Notebooks

See the [sample notebooks](./notebooks/) for examples
The samples explain step by step and can be used as a template for writing your own batch run

See the [simplest example notebook for running dsm2 hydro and outputting its version](./notebooks/sample_submit_dsm2_hydro_version.ipynb)

See the [slightly more involved example notebook for running dsm2 hydro with input and output file handling](./notebooks/sample_submit_dsm2_historical.ipynb) which uploads the input files as a zip and then uploads the output directory next to the uploaded input files at the end of the run

> **Note:** While these notebooks demonstrate how to use the Azure DMS Batch API directly, we recommend using the YAML configuration system for new projects.

# References

## Documentation

- [**Job YAML Configuration Guide**](README-batch-job-yaml.md) - How to write job configuration YAML files
- [**Template System Documentation**](README-batch-yaml-template.md) - Details on how the template system works
- [**Script Templates Documentation**](README-script-templates.md) - In-depth information on script templates
- [**SCHISM-specific Configuration**](README-schism-batch.md) - For SCHISM model workloads
- [**Architecture Documentation**](README-architecture.md) - Implementation details for developers

## Azure Documentation

- [Python SDK Setup](https://docs.microsoft.com/en-us/azure/developer/python/azure-sdk-overview)
- [BlobStorage Python Example](https://github.com/Azure/azure-sdk-for-python/tree/main/sdk/storage/azure-storage-blob)
- [Azure Batch Python API](https://docs.microsoft.com/en-us/python/api/overview/azure/batch?view=azure-python)
- [Azure Batch Python Samples](https://github.com/Azure-Samples/azure-batch-samples/tree/master/Python)
- [Azure Batch Shipyard](https://github.com/Azure/batch-shipyard)

## MPI specific

[Azure Batch MPI](https://docs.microsoft.com/en-us/azure/batch/batch-mpi)

[Cluster configuration options](https://docs.microsoft.com/en-us/azure/virtual-machines/sizes-hpc#cluster-configuration-options)

### Intel MPI
[Azure settings for Intel MPI](https://docs.microsoft.com/en-us/azure/virtual-machines/workloads/hpc/setup-mpi#intel-mpi)

[Intel MPI Pre-requisites](https://www.intel.com/content/www/us/en/develop/documentation/mpi-developer-guide-linux/top/installation-and-prerequisites/prerequisite-steps.html)
