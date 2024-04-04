import dmsbatch
from dmsbatch import create_batch_client, create_blob_client
import datetime


def create_or_resize_pool(batch_client, pool_id, pool_size):
    """Create or if exists then resize pool to desired pool_size

    Args:
        pool_id (str): pool id
        pool_size (int): pool size in number of vms (cores per vm may depend on machine type here)
    """
    vm_size = "standard_f2s_v2"
    tasks_per_vm = 2  # this is tied to the number of cores on the vm_size above. if your task needs 1 cpu per task set this to number of cores
    vm_count = pool_size
    os_image_data = (
        "microsoftwindowsserver",
        "windowsserver",
        "2019-datacenter-core",
    )
    # applications needed here
    app_packages = [("python", "v37")]
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


def create_job(batch_client, job_id, pool_id):
    """
    Creates a job with the specified ID, associated with the specified pool.

    :param batch_client: A Batch service client.
    :type batch_client: `azure.batch.BatchServiceClient`
    :param str job_id: The ID for the job.
    :param str pool_id: The ID for the pool.
    :param JobPreparationTask: preparation task before running tasks in the job
    """
    try:
        batch_client.create_job(job_id, pool_id)
    except Exception as err:
        print(f"Job {job_id} already exists. Delete it and try again.")


def add_tasks_all(batch_client, job_id, sns, output_container_sas_url):
    """
    Adds tasks of hydro scenario
    Set up input, output, command
    """
    command = "cmd /c set & cd pyscripts & rt_postp.bat"

    input_file1 = batch_client.create_input_file_spec("data", blob_prefix="pyscripts")

    tasks = list()
    for sn in sns:
        input_file2 = batch_client.create_input_file_spec(
            "output", blob_prefix="model/" + sn
        )
        inputs = [input_file1, input_file2]

        output_file = batch_client.create_output_file_spec(
            #'**/model/'+sn+'_avgRT.csv',
            "**/model/*RT.csv",
            output_container_sas_url,
        )

        # add_tasks(batch_service_client, job_id, sns, inputs, command, output_file)
        print("Creating postp task [{}]...".format(sn))
        tasks.append(
            batch_client.create_task(
                sn,
                command,
                resource_files=inputs,
                output_files=[output_file],
                env_settings={"SCENARIO": sn},
            )
        )
    batch_client.submit_tasks(job_id, tasks)


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
    parser.add_argument(
        "--job_id", type=str, required=False, default="postp-habs", help="job id"
    )
    parser.add_argument("--sns", nargs="+", help="list of scenarios", required=True)
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
            "postp", timeout=datetime.timedelta(days=3)
        )
        sns = args.sns
        # Add the tasks to the job. Pass the input files and a SAS URL
        # to the storage container for output files.
        add_tasks_all(batch_client, args.job_id, sns, output_container_sas_url)

        # Pause execution until tasks reach Completed state.
        batch_client.wait_for_tasks_to_complete(
            args.job_id, datetime.timedelta(minutes=30)
        )
        print(
            """Success! All tasks reached the 'Completed' state within the specified timeout period."""
        )
        # batch_client.resize_pool(args.pool_id, 0)

        # print(" Resizing pool to 0 ")
    except Exception as err:
        batch_client.print_batch_exception(err)
        raise
