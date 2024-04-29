# Azure Batch Runs for SCHISM

For general Azure Batch see this [README](README.md)

SCHISM is an MPI program so requires some special settings unlike the non-communicating parallel batch jobs.
For this purpose the schismbatch.py program expose a command line tool that takes a yaml file as an input

## Submitting a SCHISM job

The oneliner for this is 
```
dmsbatch schism submit-job --file schism_job_config.yml
```

If all the pre-requisites are met, this will spin up a cluster of the desired size, set it up, download the referenced
files (on a Blob container) onto it and run the specified commands on its head node. Once the job is running it can be monitored using the 
Azure portal or associated tools (Batch Explorer and Storage Explorer). New and changed files from the run directory are copied over with a 
slight delay to the same location as reference files (on the Blob container).

## Deeper dive

### Setup and installs

#### Tools
* Azure Account with permissions to create required resources (VMs, storage containers, etc..)
* Azure CLI (Command Line Interface) and azcopy.
* Python with this repo and its [requirements.txt](requirements.txt) installed.


#### Create a batch account with an associated storage account

 Azure requires a [batch account to be created](https://learn.microsoft.com/en-us/azure/batch/batch-account-create-portal). There is no cost of doing so till it gets used. 

 Also [create](https://learn.microsoft.com/en-us/azure/storage/common/storage-account-create?tabs=azure-portal) and [associate](https://learn.microsoft.com/en-us/azure/batch/accounts#azure-storage-accounts) it (or an existing storage account) with the batch account. Associating is required for now, but might be changed to be optional later

#### Install the batch application packages

 Azure batch requires the setup and installation to happen via zip files that are called application packages. The user should specify these packages with the version names as specified in the template. Here we will refer to the [alma8 template](dmsbatch/templates/alma8/pool.bicep). 

 Look for the applicationPackages section shown below
```
    applicationPackages: [
      {
        id: '${batchAccount.id}/applications/batch_setup'
        version: 'alma8.7'
      }
      {
        id: '${batchAccount.id}/applications/nfs'
        version: 'alma8.7'
      }
      {
        id: '${batchAccount.id}/applications/schism_with_deps'
        version: '5.11_alma8.7hpc_ucx'
      }
    ]
```

Using the Azure portal upload the zip files with names (after /applications in the id) and the version (value in the version tag). E.g. upload batch_setup.zip as name batch_setup and version alma8.7
These zip files are available for the alma8 template in [this release page.](https://github.com/CADWRDeltaModeling/azure_dms_batch/releases/tag/schism_5.11)


#### Install azure_dms_batch from repo

Assuming git and python is installed on the client (windows or linux) machine
1. git clone the [azure_dms_batch repo](https://github.com/CADWRDeltaModeling/azure_dms_batch/tree/main) `git clone https://github.com/CADWRDeltaModeling/azure_dms_batch.git`
2. pip install using the requirements.txt file `pip install -r requirements.txt`
3. pip install the repo `pip install -e .`


### Per job setup

Ensure you have a running schism setup on a linux VM. It is much quicker to troubleshoot the run especially if it happens at startup time on a running machine. 

Once the setup passes validation checks, the next step is to copy over the required files to an Azure Blob storage container. If the run relies on common files those can be referred to as well but each run must have its own folder under which outputs will be written to the outputs/ directory.

#### Copy the required files to a Azure Blob storage container

 Use [**azcopy**](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-v10) or [Azure Storage Explorer](https://azure.microsoft.com/en-us/products/storage/storage-explorer) for this. If you are using linux symbolic links be sure to use azcopy with the following options to preserve those links

 ```
 azcopy cp <<source>> <<destination>> --recursive --preserve-symlinks
 ```

The command above if run from a terminal that has azure cli and the user is logged in using az login and has the correct permissions.

#### Create a job submission configuration file in yaml syntax.

Here is a template for the job submission configuration

```yaml
# the resource group containing the batch account
resource_group: my_resource_group 
# job name, will be used to name the pool and the job
job_name: my_job 
# batch account name, should match the name from the azure portal
batch_account_name: my_batch_account 
# this is referring to the application name and version and setup script
start_task_script: "printenv && $AZ_BATCH_APP_PACKAGE_batch_setup_alma8_7/batch/pool_setup.sh"
# this is the storage account containing batch and storage_container defined below
storage_account_name: my_storage_account 
# this is mounted to $AZ_BATCH_MOUNTS_DIR/<<storage_container_name>> in addition to batch container which is mounted to $AZ_BATCH_MOUNTS_DIR/batch
storage_container_name: my_continer_in_storage_account 
# study flags, these two are highly recommended and more flags can be added to include/exclude. Refer to azcopy docs
study_copy_flags: --recursive --preserve-symlinks
# e.g. this folder is copied from the storage account/container to cluster with azcopy using the study_copy_flags and the command is run in this directory
study_dir: folder_at_top_level/study_folder
# these are directories that are also copied in addition to the study_dir
setup_dirs:
 - hrrr # e.g. for weather related data
 - other_data
# number of nodes in the pool
num_hosts: 2
# Some variables like num_cores are defined by calculation but can be overridden here
# num_cores: <<number of cores total>> # is optional as default is number of cores per host * number of hosts
# One can define other key value pairs that will be substitued once after all values are read. 
# This is used in the mpi_cmd template if referred to there. 
num_scribes: 10 
# command to run , assume the study_dir is current directory
mpi_command: "mpirun --oversubscribe -n {num_cores} --hostfile hostfile -x PATH -x LD_LIBRARY_PATH --bind-to core pschism_PREC_EVAP_GOTM_TVD-VL {num_scribes}"
# template for the pool name, which is used to create the pool with appropriate settings
template_name: "alma8"
# a template defines the cluster environment and the pool coordination and application commands. 
# a user can write their own clusters for different tasks than schism runs e.g. post processing.
# the standard place for enabling templates is a subdirectory of dmsbatch/templates in the azure_dms_batch repo (which is a pre-requisite)
# It looks for the standard names under templates/<template_name> resources for the following
# application_command_template: 'application_command_template.sh' 
# translates to pkg_resources.resource_filename('dmsbatch', 'templates/<template_name>/application_command_template.sh')
# coordination_command_template: 'coordination_command_template.sh'
# pool_bicep_resource: 'pool.bicep' # pkg_resources.resource_filename('dmsbatch', 'templates/<template_name>/pool.bicep')
# pool_parameters_resource: 'pool.parameters.json' # pkg_resources.resource_filename('dmsbatch', 'templates/<template_name>/pool.parameters.json')
```

#### Submit the job

Use the command line to submit the job as shown below

```dmsbatch schism submit-job --file job_config.yml```

If the user is logged in with `az login --use-device-code` then the above command should after some time return the job id and pool id on which the job will run

The running job can be monitored via the Azure portal or [Azure Batch Explorer](https://azure.github.io/BatchExplorer/). 

The resulting new and changed files will show up in the "study_dir" as configured in the yaml file after a small delay (10-15 minutes). Once the job is finished the pool will
shutdown the VMs. The job standard out and error will also be available in the storage accounts "job" folder under the name of the job id after the run is complete.

### Troubleshooting

If the job fails, one can resize the pool manually to the size requested and then use the Azure portal (or Batch Explorer) to resubmit the task (in the job) associated with that pool.
One can then login using SSH to the cluster master node and issue commands manually. This can help with troubleshooting and testing new commands.
