import os
import subprocess
import shutil

import datetime
import tempfile
import pkg_resources
import json
import yaml


import azure.batch.models as batchmodels
from azure.batch.models import BatchErrorException
from dmsbatch.commands import AzureBatch, AzureBlob

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


def create_substitutions_for_keywords(dict, **kwargs):
    dict = dict.copy()
    # string substitution for the config_dict values with kwargs only
    for key in dict:
        value = dict[key]
        if isinstance(value, str):
            dict[key] = value.format(**kwargs)
        else:
            dict[key] = value
    return dict


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
    pool_bicep_resource = config_dict["pool_bicep_resource"]
    pool_parameters_resource = config_dict["pool_parameters_resource"]

    bicep_file = pkg_resources.resource_filename(__name__, pool_bicep_resource)
    parameters_file = pkg_resources.resource_filename(
        __name__, pool_parameters_resource
    )
    dtstr = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    # create a temporary file with the modified parameters in a temporary directory
    modified_parameters_file = tempfile.NamedTemporaryFile(
        prefix=f"schismbatch_{dtstr}", suffix="json"
    ).name
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


def estimate_cores_available(vm_size, num_hosts):
    vm_size = vm_size.lower()
    VM_CORE_MAP = {
        "standard_hc44rs": 44,
        "standard_hb120rs_v2": 120,
        "standard_hb120rs_v3": 120,
        "standard_hb176rs_v4": 176,
    }
    core_count_per_host = VM_CORE_MAP.get(vm_size, 1)
    return num_hosts * core_count_per_host


def convert_command_str_to_list(cmd_str, ostype="linux"):
    # split app_cmd into a list assuming either \n or \r\n
    cmd_str = cmd_str.replace("\r\n", "\n")
    app_cmd_list = cmd_str.split("\n")
    # if linux, optionally replace strings ending with ; and space with empty string
    if ostype == "linux":
        app_cmd_list = [cmd.rstrip("; ") for cmd in app_cmd_list]
    return app_cmd_list


def get_env_var_name_for_app(app_name, ostype="linux"):
    envvar_name = ""
    if ostype == "windows":
        envvar_name = "%AZ_BATCH_APP_PACKAGE_{app_name}#{app_version}%".format(
            app_name, app_version
        )
    elif ostype == "linux":
        envvar_name = "${AZ_BATCH_APP_PACKAGE_{app_name}_{app_version}{brace}".format(
            app_name.replace(".", "_"), app_version.replace(".", "_"), brace="}"
        )
    else:
        raise ValueError("unknown ostype: {}".format(ostype))
    return envvar_name


def submit_schism_task(client, pool_name, config_dict):
    storage_account_name = config_dict["storage_account_name"]
    storage_container_name = config_dict["storage_container_name"]
    storage_account_key = config_dict["storage_account_key"]
    ostype = config_dict.get("ostype", "linux")
    # pool_name has date and time appended after _
    dtstr = pool_name.split("_")[-1]
    # pre_pool_name is everything before the last _
    pre_pool_name = "_".join(pool_name.split("_")[0:-1])
    # name job and task with date and time
    job_name = f"{pre_pool_name}_job_{dtstr}"
    try:
        job_start_command_template = config_dict["job_start_command_template"].format(
            **config_dict
        )
        job_cmd = load_command_from_resourcepath(fname=job_start_command_template)
        job_cmd = job_cmd.format(**config_dict)
        logger.debug("Job Start command: {}".format(job_cmd))
        job_cmd_list = job_cmd.split("\n")
        # prep task takes care of formatting the command for azure
        prep_task = client.create_prep_task(
            f"job_prep_task", job_cmd_list, ostype=ostype
        )
        client.create_job(job_name, pool_name, prep_task)
    except BatchErrorException as e:
        if e.error.code == "JobExists":
            print("Job already exists")
        else:
            raise e
    schism_tasks = []
    # introduce special variable for task_id
    if config_dict.get("task_ids") is not None:
        # evaluate the task_id as a python expression
        task_ids = eval(config_dict["task_ids"].format(**config_dict))
    else:
        task_ids = [""]
    unsubstitued_config_dict = config_dict.copy()
    for task_id in task_ids:
        if task_id == "":
            task_name = f"{pre_pool_name}_task_{dtstr}"
        else:
            task_name = f"{task_id}"
        unsubstitued_config_dict["task_id"] = task_id
        config_dict = create_substituted_dict(
            unsubstitued_config_dict, pool_name=pool_name
        )
        # assign the variables below to the values in the config file
        num_hosts = config_dict["num_hosts"]
        application_command_template = config_dict["application_command_template"]

        app_cmd = load_command_from_resourcepath(fname=application_command_template)
        app_cmd = app_cmd.format(**config_dict)  # do we need an order for substitution?
        app_cmd_list = convert_command_str_to_list(app_cmd, ostype=ostype)
        app_cmd = client.wrap_cmd_with_app_path(app_cmd_list, [], ostype=ostype)
        logger.debug("Application command: {}".format(app_cmd))
        #
        if "mpi_command" in config_dict:
            coordination_command_template = config_dict["coordination_command_template"]
            coordination_cmd = load_command_from_resourcepath(
                fname=coordination_command_template
            )
            coordination_cmd = coordination_cmd.format(**config_dict)
            coordination_cmd_list = convert_command_str_to_list(
                coordination_cmd, ostype
            )
            coordination_cmd = client.wrap_cmd_with_app_path(
                coordination_cmd_list, [], ostype=ostype
            )
            logger.debug("Coordination command: {}".format(coordination_cmd))
        else:
            coordination_cmd = None
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
                f"jobs/{job_name}/{task_name}",
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
        schism_tasks.append(schism_task)
    # adding auto_complete so that job terminates when all these tasks are completed.
    client.submit_tasks(job_name, schism_tasks, auto_complete=True)
    logger.info(f"Submitted task {job_name} to pool {pool_name}.")
    return job_name, task_name


def parse_yaml_file(config_file):
    with open(config_file) as f:
        data = yaml.safe_load(f)
    return data


def create_batch_client(name, key, url):
    return AzureBatch(name, key, url)


def submit_schism_job(config_file, pool_name=None):
    config_dict = parse_yaml_file(config_file)
    config_dict["task_id"] = ""
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
    _, task_name = submit_schism_task(client, pool_name, config_dict)
    try:
        blob_client = AzureBlob(
            config_dict["storage_account_name"], config_dict["storage_account_key"]
        )
        config_filename = os.path.basename(config_file)
        logger.info(
            f"uploading config file {config_file} to storage container under jobs/{task_name}/{config_filename}"
        )
        blob_client.upload_file_to_container(
            config_dict["storage_container_name"],
            f"jobs/{task_name}/{config_filename}",
            config_file,
        )
    except Exception as e:
        logger.error(e)
        logger.error("Error uploading config file to storage account")


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
