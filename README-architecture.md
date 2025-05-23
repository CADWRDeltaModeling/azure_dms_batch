# Azure DMS Batch Architecture

This document explains the architectural components and implementation details of the Azure DMS Batch framework.

## Applications

Applications are binary executable packages. These are uploaded as application packages with a version number. A pool can be specified
so that these application packages are pre-downloaded to the nodes of the pool before a job/tasks are run on it.
See details here:
* [Application packages in Azure Batch](https://docs.microsoft.com/en-us/azure/batch/nodes-and-pools#application-packages)
* [Deploy applications to compute nodes](https://docs.microsoft.com/en-us/azure/batch/batch-application-packages)

## Class Architecture

The Azure DMS Batch framework consists of two primary classes in batch.commands:

* [**AzureBlob**](dmsbatch/commands.py#L898) - Handles uploading/downloading to Azure Blob Storage
* [**AzureBatch**](dmsbatch/commands.py#L120) - Manages pools, jobs, and tasks (depends on AzureBlob)

Management of batch resources such as creation of batch account, storage account, etc. is a low-frequency activity and can be managed via the Azure CLI or web console.

## Model Representation

A model in Azure DMS Batch is considered to be something that:
 - Needs application packages, versions, and the location of the binary directory (i.e., ApplicationPackage[])
 - Can have one or more input file(s), common ones or unique ones
   * These need to be uploaded to storage as blobs and then referenced
 - Needs environment variables
   * These are specified as name-value pairs (i.e., Python dictionaries)
 - Can have output file(s), which are uploaded to the associated storage via directives to the batch service

If the input and output files are specified by the [create...spec](dmsbatch/commands.py#L265) methods on [AzureBatch](dmsbatch/commands.py#L120),
then those are directives to the batch service to download the inputs and upload the outputs without writing specific code.

## Model Run

A model run is a particular execution that is submitted to the batch service as a *task*.
Each run:
 - Needs a unique task name
 - Will have output unique to it
 - Could have a set of unique input files
 - Could have environment settings unique to each run

## MPI Implementation Details

SCHISM is a multi-dimensional model that uses multiple cores and multiple hosts for computation. These are networked
computers that form "clusters" using MPI for communication.

Key implementation details include:
 * Use of multi-instance tasks with `AZ_BATCH_HOST_LIST` to get a list of networked hosts available
 * Use of H-series VMs capable of leveraging Infiniband (though other VM/OS combinations may work)
 * Use of Linux OS with HPC images that include appropriate device drivers

## Parameterized Runs

Many model runs are closely related, with only a few parameters varying between them. These are
submitted as tasks to the batch service and can reuse the same pool.

The batch submission script samples the parameter space and submits the tasks.

The most efficient approach is to vary the environment variables and have the model use those 
environment variables to change parameter values. A less efficient but equally effective approach
is to express parameter changes as modified input files that overlay the base inputs.

## BEOPEST Implementation

PEST (Parameterized ESTimation) is a software package for non-linear optimization. BeoPEST is a master/slave model 
that implements a parallel version of estimation runs.

Implementation details:
1. A BeoPEST master is submitted to the batch service
2. The task's stdout.txt is polled, and the first line is assumed to have the hostname which is captured
3. This hostname is passed as an environment variable to start multiple slaves as batch runs
4. BeoPEST master registers these slave tasks as they come in and submits runs to them through MPI

## Template System Implementation

The template system is implemented through several components:

1. **Template Directory Structure:** Templates are stored in `dmsbatch/templates/<template_name>/` with standardized files.

2. **Configuration Merging:** Values from command-line, user YAML, default_config.yaml, and pool.parameters.json are merged with a defined priority.

3. **Variable Substitution:** Uses Python's string formatting to substitute values in templates using `{{VARIABLE_NAME}}` syntax.

4. **Script Generation:** Templates are processed to generate the final scripts executed on Batch nodes.

For implementation details, see the [substitute_values](dmsbatch/batch.py) function which handles recursive formatting of strings within the configuration.
