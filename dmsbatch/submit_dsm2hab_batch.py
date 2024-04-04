import dmsbatch
from dmsbatch import create_batch_client, create_blob_client
import datetime


def create_or_resize_pool(batch_client, pool_id, pool_size):
    """Create or if exists then resize pool to desired pool_size

    Args:
        pool_id (str): pool id
        pool_size (int): pool size in number of vms (cores per vm may depend on machine type here)
    """
    vm_size = "standard_f4s_v2"
    tasks_per_vm = 4  # this is tied to the number of cores on the vm_size above. if your task needs 1 cpu per task set this to number of cores
    vm_count = pool_size
    os_image_data = (
        "microsoftwindowsserver",
        "windowsserver",
        "2019-datacenter-core",
    )
    app_packages = [("dsm2", "8.2.1")]
    batch_client.create_or_resize_pool(
        pool_id,
        pool_size,
        app_packages=app_packages,
        vm_size=vm_size,
        tasks_per_vm=tasks_per_vm,
        os_image_data=os_image_data,
        start_task_cmd="cmd /c set",
        elevation_level="admin",
    )


def copy_tidefile_task_to_shared_dir(batch_client, job_id):
    """copies tidefile from container blob to shared directory for tasks

    Args:
        job_id (str): The job id to which this preparation task will be attached to.

    Returns:
        batchmodels.JobPreparationTask: The preparation task
    """
    input_tidefile = batch_client.create_input_file_spec(
        "data", blob_prefix=f"tidefiles/{job_id}.h5", file_path="tidefile"
    )
    prep_commands = [
        f"move tidefile\\tidefiles\\{job_id}.h5 %AZ_BATCH_NODE_SHARED_DIR%"
    ]

    prep_task = batch_client.create_prep_task(
        "copy_tidefile_task",
        prep_commands,
        resource_files=[input_tidefile],
        ostype="windows",
    )

    return prep_task


def create_job(batch_client, job_id, pool_id):
    """
    Creates a job with the specified ID, associated with the specified pool.

    :param batch_client: A Batch service client.
    :type batch_client: `azure.batch.BatchServiceClient`
    :param str job_id: The ID for the job.
    :param str pool_id: The ID for the pool.
    :param JobPreparationTask: preparation task before running tasks in the job
    """
    prep_task = copy_tidefile_task_to_shared_dir(batch_client, job_id)
    try:
        batch_client.create_job(job_id, pool_id, prep_task=prep_task)
    except Exception as err:
        print(f"Job {job_id} already exists. Delete it and try again.")


def add_tasks(batch_client, job_id, times, input_file, commands, output_file):
    """
    Adds tasks of diff time periods
    Set up envvar
    """
    tasks = list()
    for time in times:
        START = time[0]
        END = time[1]
        envvars = {"START": START, "END": END}
        task = batch_client.create_task(
            f"dsm2_hab_{START}",
            batch_client.wrap_commands_in_shell(commands, ostype="windows"),
            resource_files=[input_file],
            output_files=[output_file],
            env_settings=envvars,
        )
        tasks.append(task)
    batch_client.submit_tasks(job_id, tasks)


def add_tasks_all(batch_client, job_id, times, output_container_sas_url):
    """
    Adds tasks of hydro scenario
    Set up input, output, command
    """
    print("Creating dsm2 run tasks for job [{}]...".format(job_id))
    print(len(times))
    commands = [
        f"cd model\\{job_id}",
        "set AZ_BATCH_NODE_SHARED_DIR=%AZ_BATCH_NODE_SHARED_DIR:\=/%",
        "qual_HAB.bat",
    ]
    input_file = batch_client.create_input_file_spec(
        "data", blob_prefix=job_id, file_path="model"
    )
    output_file = batch_client.create_output_file_spec(
        "**/output/*.dss",
        output_container_sas_url,
    )

    add_tasks(batch_client, job_id, times, input_file, commands, output_file)


def build_times():
    """build up time pairs (start, end) 93*6=558
    with year/month
    4-months simulation is choosed since some output of some hydro scenario need
    this long time to drop 10% HAB concentration (most only need 1-month)
    """
    years = range(1922, 2015)
    months = range(6, 12)
    # years = range(2014,2015) #test
    # months = range(6,8)      #test
    day = "03"

    times = list()
    for year in years:
        for mon in months:
            dt_obj0 = datetime.datetime.strptime(
                str("03") + str(mon) + str(year), "%d%m%Y"
            )
            dt_obj1 = dt_obj0 + datetime.timedelta(days=+4 * 30)
            time0 = dt_obj0.strftime("%d%b%Y").upper()
            time1 = dt_obj1.strftime("%d%b%Y").upper()

            times.append([time0, time1])

    return times


def read_times():
    """read time pairs (start, end)
    from text file
    """


import argparse

if __name__ == "__main__":
    # use argparse to get config file
    parser = argparse.ArgumentParser(description="Submit DSM2 HAB Batch Job")
    parser.add_argument(
        "--config_file", type=str, required=True, help="path to config file"
    )
    parser.add_argument("--pool_id", type=str, required=True, help="pool id")
    parser.add_argument("--pool_size", type=int, required=True, help="pool size")
    parser.add_argument("--job_id", type=str, required=True, help="job id")

    args = parser.parse_args()
    config_file = args.config_file
    batch_client = create_batch_client(config_file)
    blob_client = create_blob_client(config_file)
    # Create Pool, Job, Tasks
    try:
        create_or_resize_pool(batch_client, args.pool_id, args.pool_size)
        # Create the job that will run the tasks.
        create_job(batch_client, args.job_id, args.pool_id)  # turn off once established
        output_container_sas_url = blob_client.get_container_sas_url(
            "output", timeout=datetime.timedelta(days=3)
        )
        # Add the tasks to the job. Pass the input files and a SAS URL
        # to the storage container for output files.
        times = build_times()
        # times = [["03JUN1930", "03OCT1930"]]  # test
        add_tasks_all(batch_client, args.job_id, times, output_container_sas_url)
        # Pause execution until tasks reach Completed state.
        batch_client.wait_for_tasks_to_complete(
            args.job_id, datetime.timedelta(minutes=30)
        )
        print(
            """Success! All tasks reached the 'Completed' state within the specified timeout period."""
        )
        batch_client.resize_pool(args.pool_id, 0)

        print(" Resizing pool to 0 ")
    except Exception as err:
        batch_client.print_batch_exception(err)
        raise
