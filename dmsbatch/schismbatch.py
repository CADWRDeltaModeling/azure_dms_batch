import os
import subprocess
import shutil

import datetime
import pkg_resources
import json
import yaml


import azure.batch.models as batchmodels
from azure.batch.models import BatchErrorException
from dmsbatch.commands import AzureBatch

# set up logging
import logging

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)


def load_command_from_resourcepath(fname):
    return pkg_resources.resource_string(__name__, fname).decode("utf-8")


def modify_json_file(json_file, modified_file, **kwargs):
    """the kwargs are the parameters to be modified in the json file."""
    with open(json_file, "r") as f:
        json_dict = json.load(f)
    for key, value in kwargs.items():
        try:
            logger.debug(key, value)
            json_dict["parameters"][key]["value"] = value
        except KeyError:
            logger.debug("key {} not found in json file".format(key))
            pass
    with open(modified_file, "w") as f:
        json.dump(json_dict, f, indent=4)


def build_autoscaling_formula(num_hosts, startTime):
    formula = pkg_resources.resource_string(
        __name__, "schismpool_autoscale_formula.txt"
    )
    formula = formula.decode("utf-8")
    formula = formula.format(num_hosts=num_hosts, startTime=startTime.isoformat())
    return formula


def convert_to_camel_case(variable_name):
    parts = variable_name.split("_")
    camel_case_name = parts[0] + "".join(word.title() for word in parts[1:])
    return camel_case_name


def convert_keys_to_camel_case(config_dict):
    camel_case_dict = {}
    for key, value in config_dict.items():
        camel_case_key = convert_to_camel_case(key)
        camel_case_dict[camel_case_key] = value
    return camel_case_dict


def create_substituted_dict(config_dict, **kwargs):
    config_dict = config_dict.copy()
    config_dict.update(kwargs)
    # string substitution for the config_dict values with itself
    for key in config_dict:
        value = config_dict[key]
        if isinstance(value, str):
            config_dict[key] = value.format(**config_dict)
        elif isinstance(value, list):
            config_dict[key] = " ".join(value)
        else:
            config_dict[key] = value
    return config_dict


def update_if_not_defined(config_dict, **kwargs):
    for key, value in kwargs.items():
        if key not in config_dict:
            logger.info(
                'Will use default config value "{}" for "{}"'.format(value, key)
            )
            config_dict[key] = value
    return config_dict


def create_schism_pool(pool_name, config_dict):
    """create a schism pool with the given number of hosts.  The pool name is
    assumed to include the date and time after the last _ in the name."""
    # assign the variables below to the values in the config file
    config_dict = create_substituted_dict(config_dict, pool_name=pool_name)
    resource_group_name = config_dict["resource_group"]
    pool_name = config_dict["pool_name"]
    num_hosts = config_dict["num_hosts"]
    batch_account_name = config_dict["batch_account_name"]
    storage_account_key = config_dict["storage_account_key"]
    storage_name = config_dict["storage_account_name"]
    container_name = config_dict["storage_container_name"]
    pool_bicep_resource = config_dict["pool_bicep_resource"]
    pool_parameters_resource = config_dict["pool_parameters_resource"]
    start_task_script = config_dict["start_task_script"]

    bicep_file = pkg_resources.resource_filename(__name__, pool_bicep_resource)
    parameters_file = pkg_resources.resource_filename(
        __name__, pool_parameters_resource
    )
    dtstr = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    modified_parameters_file = f"temp_schismpool.parameters_{dtstr}.json"
    json_config_dict = convert_keys_to_camel_case(config_dict)
    try:
        # build json file from template using config_dict values
        modify_json_file(
            parameters_file,
            modified_parameters_file,
            formula=build_autoscaling_formula(
                num_hosts,
                datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0),
            ),
            **json_config_dict,
        )
        # Run the command and capture its output
        cmdstr = f"az deployment group create --name {pool_name} --resource-group {resource_group_name} --template-file {bicep_file} --parameters {modified_parameters_file}"
        logger.debug(cmdstr)
        result = subprocess.check_output(cmdstr, shell=True).decode("utf-8").strip()
        # Print the output -- for debug ---
        logger.debug(result)
        logger.info("created pool {}".format(pool_name))
        return pool_name
    except Exception as e:
        logger.error("Error creating pool {}".format(pool_name))
        logger.error(e)
        raise e
    finally:
        # delete the modified parameters file
        os.remove(modified_parameters_file)
        logger.debug("removed the modified parameters file")  # for debug


def estimate_cores_available(vm_size, num_hosts):
    vm_size = vm_size.lower()
    VM_CORE_MAP = {
        "standard_hc44rs": 44,
        "standard_hb120rs_v2": 120,
        "standard_hb120rs_v3": 120,
        "standard_hb176rs_v4": 176,
    }
    return num_hosts * (VM_CORE_MAP[vm_size])


def submit_schism_task(client, pool_name, config_dict):
    config_dict = create_substituted_dict(config_dict, pool_name=pool_name)
    # assign the variables below to the values in the config file
    num_hosts = config_dict["num_hosts"]
    num_cores = config_dict["num_cores"]
    num_scribes = config_dict["num_scribes"]
    study_dir = config_dict["study_dir"]
    study_copy_flags = config_dict["study_copy_flags"]
    setup_dirs = config_dict["setup_dirs"]
    storage_account_name = config_dict["storage_account_name"]
    storage_container_name = config_dict["storage_container_name"]
    sas = config_dict["sas"]
    storage_account_key = config_dict["storage_account_key"]
    application_command_template = config_dict["application_command_template"]
    mpi_command = config_dict["mpi_command"]
    coordination_command_template = config_dict["coordination_command_template"]
    # pool_name has date and time appended after _
    dtstr = pool_name.split("_")[-1]
    # pre_pool_name is everything before the last _
    pre_pool_name = "_".join(pool_name.split("_")[0:-1])
    # name job and task with date and time
    job_name = f"{pre_pool_name}_job_{dtstr}"
    try:
        client.create_job(job_name, pool_name)
    except BatchErrorException as e:
        if e.error.code == "JobExists":
            print("Job already exists")
        else:
            raise e
    task_name = f"{pre_pool_name}_task_{dtstr}"
    #
    app_cmd = load_command_from_resourcepath(fname=application_command_template)
    app_cmd = app_cmd.format(**config_dict)  # do we need an order for substitution?
    app_cmd = client.wrap_cmd_with_app_path(app_cmd, [], ostype="linux")
    logger.debug("Application command: {}".format(app_cmd))
    #
    coordination_cmd = load_command_from_resourcepath(
        fname=coordination_command_template
    )
    coordination_cmd = coordination_cmd.format(**config_dict)
    coordination_cmd = client.wrap_cmd_with_app_path(
        coordination_cmd, [], ostype="linux"
    )
    logger.debug("Coordination command: {}".format(coordination_cmd))
    # output files should be saved to batch container
    sas_batch = get_sas(
        storage_account_name, storage_account_key, storage_container_name
    )
    output_file_specs = []
    for upload_condition in [
        batchmodels.OutputFileUploadCondition.task_completion,
        batchmodels.OutputFileUploadCondition.task_failure,
    ]:
        spec = client.create_output_file_spec(
            "../std*",
            "https://{}.blob.core.windows.net/{}?{}".format(
                storage_account_name, storage_container_name, sas_batch
            ),
            f"jobs/{task_name}",
            upload_condition=upload_condition,
        )
        output_file_specs.append(spec)
    #
    schism_task = client.create_task(
        task_name,
        app_cmd,
        num_instances=num_hosts,
        coordination_cmdline=coordination_cmd,
        output_files=output_file_specs,
    )
    # adding auto_complete so that job terminates when all these tasks are completed.
    client.submit_tasks(job_name, [schism_task], auto_complete=True)
    logger.info(f"Submitted task {job_name} to pool {pool_name}.")


def parse_yaml_file(config_file):
    with open(config_file) as f:
        data = yaml.safe_load(f)
    return data


def create_batch_client(name, key, url):
    return AzureBatch(name, key, url)


def submit_schism_job(config_file, pool_name=None):
    config_dict = parse_yaml_file(config_file)
    required_keys = [
        "template_name",
        "resource_group",
        "batch_account_name",
        "storage_account_name",
        "storage_container_name",
        "study_dir",
        "job_name",
    ]
    for key in required_keys:
        if key not in config_dict:
            raise Exception(
                "Required key {} not found in config file: {}".format(key, config_file)
            )
    # load defaults from default_config.yml and update undefined ones
    default_config_file = pkg_resources.resource_filename(
        __name__, "templates/default_config.yml"
    )
    default_config_dict = parse_yaml_file(default_config_file)
    update_if_not_defined(config_dict, **default_config_dict)
    # get user info
    user_info = get_user_info()
    if "user" in user_info:
        uinfo = user_info["user"]
        if "type" in uinfo:
            config_dict["created_by"] = uinfo["name"]
    #
    location = config_dict["location"]
    config_dict["batch_account_url"] = (
        f'https://{config_dict["batch_account_name"]}.{location}.batch.azure.com'
    )
    if "BATCH_ACCOUNT_KEY" in os.environ:
        config_dict["batch_account_key"] = os.environ["BATCH_ACCOUNT_KEY"]
        logger.info("using batch account key from environment variable")
    else:
        config_dict["batch_account_key"] = get_batch_account_key(
            config_dict["resource_group"], config_dict["batch_account_name"]
        )
        logger.info("using batch account key from az cli")
    if "STORAGE_ACCOUNT_KEY" in os.environ:
        config_dict["storage_account_key"] = os.environ["STORAGE_ACCOUNT_KEY"]
        logger.info("using storage account key from environment variable")
    else:
        config_dict["storage_account_key"] = get_storage_account_key(
            config_dict["resource_group"], config_dict["storage_account_name"]
        )
        logger.info("using storage account key from az cli")
    logger.info("using vm size", config_dict["vm_size"])
    if "setup_dirs" not in config_dict:
        config_dict["setup_dirs"] = []
        logger.info("using default setup dirs", config_dict["setup_dirs"])
    if "coordination_command_template" not in config_dict:
        config_dict["coordination_command_template"] = (
            f'templates/{config_dict["template_name"]}/coordination_command_template.sh'
        )
        logger.info(
            "using default coordination command template",
            config_dict["coordination_command_template"],
        )
    if "start_task_script" not in config_dict:
        config_dict["start_task_script"] = "printenv"
        logger.info("using default start task script", config_dict["start_task_script"])
    if "num_cores" not in config_dict:
        config_dict["num_cores"] = estimate_cores_available(
            config_dict["vm_size"], config_dict["num_hosts"]
        )
        logger.info(
            f"using calculated number of cores cores using {config_dict['vm_size']}",
            config_dict["num_cores"],
        )
    # log the config dict
    logging.info(config_dict)
    #
    client = create_batch_client(
        config_dict["batch_account_name"],
        config_dict["batch_account_key"],
        config_dict["batch_account_url"],
    )
    # get sas token so that substitution can happen
    sas = get_sas(
        config_dict["storage_account_name"],
        config_dict["storage_account_key"],
        config_dict["storage_container_name"],
    )
    config_dict["sas"] = sas
    # TODO: pool name substitution should be improved
    dtstr = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    if pool_name is None:
        pool_name = config_dict["pool_name"] + f"_{dtstr}"
        # create pool
        pool_name = create_schism_pool(pool_name, config_dict)
    submit_schism_task(client, pool_name, config_dict)


def generate_schism_job_yaml(config_file):
    job_yaml_template = pkg_resources.resource_filename(__name__, "schism.job.yml")
    # copy template to config_file
    shutil.copyfile(job_yaml_template, config_file)


def get_user_info():
    cmd = "az account show"
    try:
        user_info = json.loads(
            subprocess.check_output(cmd, shell=True).decode("utf-8").strip()
        )
    except subprocess.SubprocessError as e:
        logger.error(e)
        raise Exception(
            "Error getting user info. Make sure az cli is logged in to the correct subscription. \n"
            + "Use az login --use-device-code to login to the correct subscription."
        )
    return user_info


def get_batch_account_key(resource_group_name, batch_account_name):
    """make sure az cli is logged in to the correct subscription.
    Use az login --use-device-code to login to the correct subscription."""
    cmd = f"az batch account keys list --name {batch_account_name} --resource-group {resource_group_name}"
    try:
        key_dict = json.loads(
            subprocess.check_output(cmd, shell=True).decode("utf-8").strip()
        )
    except subprocess.SubprocessError as e:
        logger.error(e)
        raise Exception(
            "Error getting batch account key. Make sure az cli is logged in to the correct subscription. \n"
            + "Use az login --use-device-code to login to the correct subscription."
        )
    return key_dict["primary"]


def get_storage_account_key(resource_group_name, storage_account_name):
    """make sure az cli is logged in to the correct subscription.
    Use az login --use-device-code to login to the correct subscription."""
    cmd = f"az storage account keys list --account-name {storage_account_name} --resource-group {resource_group_name}"
    try:
        key_dict = json.loads(
            subprocess.check_output(cmd, shell=True).decode("utf-8").strip()
        )
    except subprocess.SubprocessError as e:
        logger.error(e)
        raise Exception(
            "Error getting storage account key. Make sure az cli is logged in to the correct subscription. \n"
            + "Use az login --use-device-code to login to the correct subscription."
        )

        raise e
    return key_dict[0]["value"]


def get_sas(
    storage_account_name,
    storage_account_key,
    container_name,
    permissions="acdlrw",
    expires_in_days=7,
):
    """make sure az cli is logged in to the correct subscription.
    Use az login --use-device-code to login to the correct subscription."""
    # export SAS=$(az storage container generate-sas --permissions acdlrw --expiry `date +%FT%TZ -u -d "+1 days"` --account-name ${storage_account} --name ${container} --output tsv --auth-mode key --account-key ${ACCOUNT_KEY} --only-show-errors)
    dt = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    # add expires_in_days
    expiry = (dt + datetime.timedelta(days=expires_in_days)).strftime("%Y-%m-%dT%H:%MZ")
    cmd = f"az storage container generate-sas --account-name {storage_account_name} --auth-mode key --account-key {storage_account_key} --name {container_name} --permissions {permissions} --expiry {expiry} --only-show-errors"
    return json.loads(subprocess.check_output(cmd, shell=True).decode("utf-8").strip())


def upload_batch_scripts(
    resource_group_name, storage_account_name, batch_container_name="batch"
):
    if "STORAGE_ACCOUNT_KEY" in os.environ:
        storage_account_key = os.environ["STORAGE_ACCOUNT_KEY"]
    else:
        storage_account_key = get_storage_account_key(
            resource_group_name, storage_account_name
        )
    sas = get_sas(storage_account_name, storage_account_key, batch_container_name)
    batch_dir = pkg_resources.resource_filename("dmsbatch", "../schism_scripts/batch")
    # upload batch scripts
    cmd = f'cd {batch_dir} && azcopy cp "./*"  "https://{storage_account_name}.blob.core.windows.net/{batch_container_name}?{sas}" --recursive=true'
    subprocess.check_output(cmd, shell=True).decode("utf-8").strip()
    return
