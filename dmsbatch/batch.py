import os
import subprocess
import shutil
import re

import datetime
import tempfile
import pkg_resources
import json
import yaml
import base64

import azure.batch.models as batchmodels
from azure.batch.models import BatchErrorException
import dmsbatch.commands
from dmsbatch.commands import AzureBatch, AzureBlob

#
import tqdm
import sys

# set up logging
import logging
import logging.config

logger = logging.getLogger(__name__)


def setup_logging(log_level=logging.INFO):
    logger.setLevel(log_level)
    handler = logging.StreamHandler(sys.stdout)
    formatter = logging.Formatter("%(levelname)s:%(name)s %(message)s")
    handler.setFormatter(formatter)
    logger.addHandler(handler)
    dmsbatch.commands.logger.setLevel(log_level)
    dmsbatch.commands.logger.addHandler(handler)


def load_command_from_resourcepath(fname):
    try:
        return pkg_resources.resource_string(__name__, fname).decode("utf-8")
    except FileNotFoundError as e:
        return fname  # assume the fname is the command itself


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


def build_autoscaling_formula(config_dict):
    formula = pkg_resources.resource_string(__name__, config_dict["autoscale_formula"])
    formula = formula.decode("utf-8")
    config_dict = config_dict.copy()
    config_dict["startTime"] = (
        datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()
    )
    formula = formula.format(**config_dict)
    return formula


def build_app_pkg_scripts(config_dict):
    if "app_pkgs" in config_dict:
        app_pkgs = config_dict["app_pkgs"]
        app_pkg_scripts = [
            app_pkg["init_script"] for app_pkg in app_pkgs if "init_script" in app_pkg
        ]
        return "\n".join(app_pkg_scripts)
    else:
        return ""


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


def recursive_format(value, current_data):
    """
    Recursively formats strings within nested structures using values from the dictionary.

    Parameters:
    value: The value to format, can be a string, list, or dictionary.
    current_data (dict): Current state of the dictionary with values for formatting.

    Returns:
    The formatted value.
    """
    if isinstance(value, str):
        try:
            return value.format(**current_data)
        except KeyError as e:
            logger.debug(
                f"Failed to format ... KeyError: Missing key {e} for value '{value}'"
            )
            return value
    elif isinstance(value, dict):
        return {k: recursive_format(v, current_data) for k, v in value.items()}
    elif isinstance(value, list):
        return [recursive_format(item, current_data) for item in value]
    else:
        return value


def substitute_values(data):
    """
    Substitutes values in the dictionary with formatted values from other values in the dictionary,
    using the current updated state of the dictionary for each substitution.

    Parameters:
    data (dict): Dictionary with values that should be formatted with other values in the dictionary.

    Returns:
    dict: Dictionary with substituted values.
    """

    # Create a copy of the original dictionary to store updated values
    updated_data = {}

    # Process each item in the original dictionary
    for key, value in data.items():
        # Format the value using the current state of updated_data
        formatted_value = recursive_format(value, updated_data)
        # Add the formatted value to the updated dictionary
        updated_data[key] = formatted_value

    return updated_data


def create_substituted_dict(config_dict, **kwargs):
    config_dict = config_dict.copy()
    config_dict.update(kwargs)
    return substitute_values(config_dict)


def update_if_not_defined(config_dict, **kwargs):
    for key, value in kwargs.items():
        if key not in config_dict:
            logger.debug(
                'Will use default config value "{}" for "{}"'.format(value, key)
            )
            config_dict[key] = value
    return config_dict


def create_pool(config_dict):
    """create a pool with the given number of hosts.  The pool name is
    assumed to include the date and time after the last _ in the name."""
    # assign the variables below to the values in the config file
    config_dict = create_substituted_dict(config_dict)
    resource_group_name = config_dict["resource_group"]
    pool_name = config_dict["pool_name"]
    pool_bicep_resource = config_dict["pool_bicep_resource"]
    pool_parameters_resource = config_dict["pool_parameters_resource"]

    bicep_file = pkg_resources.resource_filename(__name__, pool_bicep_resource)
    parameters_file = pkg_resources.resource_filename(
        __name__, pool_parameters_resource
    )
    # create a temporary file with the modified parameters in a temporary directory
    modified_parameters_file = tempfile.NamedTemporaryFile(
        prefix=f"batch_{pool_name}", suffix=".json"
    ).name
    json_config_dict = convert_keys_to_camel_case(config_dict)
    try:
        # build json file from template using config_dict values
        modify_json_file(
            parameters_file,
            modified_parameters_file,
            formula=build_autoscaling_formula(config_dict),
            **json_config_dict,
        )
        # Run the command and capture its output
        azdebug = "--debug" if logger.level == logging.DEBUG else ""
        cmdstr = f"az deployment group create {azdebug} --name {pool_name} --resource-group {resource_group_name} --template-file {bicep_file} --parameters {modified_parameters_file}"
        logger.debug(cmdstr)
        result = subprocess.check_output(cmdstr, shell=True).decode("utf-8").strip()
        # Print the output -- for debug ---
        logger.debug(result)
        logger.info("created pool {}".format(pool_name))
        return pool_name
    except Exception as e:
        logger.error("Error creating pool {}".format(pool_name))
        logger.error(e)
        if logger.level != logging.DEBUG:
            try:
                os.remove(modified_parameters_file)
            except Exception as e:
                logger.error(
                    "Error removing temporary file {}".format(modified_parameters_file)
                )
        raise e


def get_core_count(vm_size, location):
    try:
        with open(
            pkg_resources.resource_filename(__name__, "templates/vm_core_map.yml")
        ) as f:
            VM_CORE_MAP = yaml.safe_load(f)
    except FileNotFoundError as e:
        logger.error(e)
        VM_CORE_MAP = {
            "standard_hc44rs": 44,
            "standard_hb120rs_v2": 120,
            "standard_hb120rs_v3": 120,
            "standard_hb176rs_v4": 176,
        }
        with open(
            pkg_resources.resource_filename(__name__, "templates/vm_core_map.yml"), "w"
        ) as f:
            yaml.dump(VM_CORE_MAP, f)

    vm_size = vm_size.lower()
    if not vm_size in VM_CORE_MAP:
        # use az cli to get the number of cores available for the vm_size
        json_query = "[0].capabilities[?name=='vCPUs'].value | [0]"
        cmd = f'az vm list-skus --location {location} --size {vm_size} --output json --query "{json_query}"'
        try:
            cpu_count = json.loads(
                subprocess.check_output(cmd, shell=True).decode("utf-8").strip()
            )
            core_count_per_host = int(cpu_count)
        except subprocess.SubprocessError as e:
            logger.error(e)
            core_count_per_host = 1
        VM_CORE_MAP[vm_size] = core_count_per_host
        with open(
            pkg_resources.resource_filename(__name__, "templates/vm_core_map.yml"), "w"
        ) as f:
            yaml.dump(VM_CORE_MAP, f)
    core_count_per_host = VM_CORE_MAP.get(vm_size, 1)
    return core_count_per_host


def estimate_cores_available(vm_size, num_hosts, location):
    core_count_per_host = get_core_count(vm_size, location)
    return num_hosts * core_count_per_host


def get_semicolon_pattern():
    return re.compile(r";\s*$")


def convert_command_str_to_list(cmd_str, ostype="linux"):
    cmd_str = cmd_str.replace("\r\n", "\n")
    cmds = cmd_str.split("\n")
    cmds = [cmd.rstrip() for cmd in cmds]
    if ostype == "linux":
        cmds = [cmd.rstrip(";") for cmd in cmds]
    if ostype == "windows":
        cmds = [cmd.replace('"', '\\\\"') for cmd in cmds]
    # remove empty strings
    cmds = [cmd for cmd in cmds if cmd]
    return cmds


def envvar_name(app_name, app_version=None, ostype="linux"):
    envvar_name = ""
    if ostype == "windows":
        envvar_name = f"AZ_BATCH_APP_PACKAGE_{app_name}"
        if app_version:
            envvar_name = f"{envvar_name}#{app_version}"
        envvar_name = f"%{envvar_name}%"
    elif ostype == "linux":
        envvar_name = f"AZ_BATCH_APP_PACKAGE_{app_name}"
        if app_version:
            app_version = app_version.replace(".", "_").replace("-", "_")
            app_name = app_name.replace(".", "_").replace("-", "_")
            envvar_name = f"{envvar_name}_{app_version}"
        envvar_name = "${" + envvar_name + "}"
    else:
        raise ValueError("unknown ostype: {}".format(ostype))
    return envvar_name


def commands_to_string(commands, ostype="linux"):
    # Strip whitespace and filter out empty lines
    commands = [cmd.strip() for cmd in commands if cmd.strip()]

    if ostype.lower() == "linux":
        # Join commands with semicolons for bash
        joined_commands = "; ".join(commands)
        # Remove any trailing semicolon
        joined_commands = joined_commands.rstrip(";")
        # Escape single quotes and wrap the entire command in single quotes
        escaped_commands = joined_commands.replace("'", "'\"'\"'")
        return escaped_commands

    elif ostype.lower() == "windows":
        # Join commands with '&' for CMD
        joined_commands = " & ".join(commands)
        # Remove any trailing '&'
        joined_commands = joined_commands.rstrip("&").strip()
        # Escape special characters and wrap in double quotes
        escaped_commands = (
            joined_commands.replace("^", "^^")
            # .replace("&", "^&")
            .replace("<", "^<")
            .replace(">", "^>")
            .replace("|", "^|")
        )
        return escaped_commands
    else:
        raise ValueError("Invalid ostype. Use 'linux' or 'windows'.")


def move_key_to_first(d, key):
    if key not in d:
        raise KeyError(f"Key '{key}' not found in the dictionary.")

    # Create a new dictionary with the specified key first
    new_dict = {key: d[key]}

    # Add the rest of the items
    for k, v in d.items():
        if k != key:
            new_dict[k] = v

    return new_dict


def submit_task(client: AzureBatch, pool_name, config_dict, pool_exists=False):
    storage_account_name = config_dict["storage_account_name"]
    storage_container_name = config_dict["storage_container_name"]
    storage_account_key = config_dict["storage_account_key"]
    ostype = config_dict.get("ostype", "linux")
    # pool_name has date and time appended after _
    if pool_exists:  # create job with new timestamp
        dtstr = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    else:  # if new pool is created, use the timestamp from the pool name
        dtstr = pool_name.split("_")[-1]
    # pre_pool_name is everything before the last _
    pre_pool_name = "_".join(pool_name.split("_")[0:-1])
    # name job and task with date and time
    job_name = f"{pre_pool_name}_job_{dtstr}"
    try:
        local_config_dict = create_substituted_dict(config_dict, pool_name=pool_name)
        job_start_command_template = local_config_dict["job_start_command_template"]
        job_cmd = load_command_from_resourcepath(fname=job_start_command_template)
        job_cmd = job_cmd.format(**local_config_dict)
        logger.debug("Job Start command: {}".format(job_cmd))
        if "job_start_command_resource_files" in local_config_dict:
            job_resource_files = [
                batchmodels.ResourceFile(
                    file_path=resource_file["file_path"],
                    auto_storage_container_name=storage_container_name,
                    blob_prefix=resource_file["blob_prefix"],
                )
                for resource_file in local_config_dict[
                    "job_start_command_resource_files"
                ]
            ]
        else:
            job_resource_files = None
        if ostype == "linux":
            job_cmd = commands_to_string(job_cmd.split("\n")).split(";")
        else:
            job_cmd = commands_to_string(job_cmd.split("\n"), ostype="windows").split(
                " & "
            )
        # prep task takes care of formatting the command for azure
        prep_task = client.create_prep_task(
            f"job_prep_task",
            job_cmd,
            ostype=ostype,
            resource_files=job_resource_files,
        )
        client.create_job(job_name, pool_name, prep_task)
    except BatchErrorException as e:
        if e.error.code == "JobExists":
            print("Job already exists")
        else:
            raise e
    tasks = []
    task_ids = config_dict.pop("task_ids")
    unsubstitued_config_dict = move_key_to_first(config_dict, "task_id")
    for task_id in tqdm.tqdm(task_ids):
        unsubstitued_config_dict["task_id"] = task_id
        config_dict = create_substituted_dict(
            unsubstitued_config_dict, pool_name=pool_name
        )
        if task_id == "":
            task_name = f"{pre_pool_name}_task_{dtstr}"
        else:
            if "task_name" in config_dict:
                task_name = config_dict["task_name"]
            else:
                task_name = f"{task_id}"
        # assign the variables below to the values in the config file
        num_hosts = config_dict["num_hosts"]
        application_command_template = config_dict["application_command_template"]
        app_cmd = load_command_from_resourcepath(fname=application_command_template)
        app_cmd = app_cmd.format(**config_dict)  # do we need an order for substitution?
        if ostype == "windows":
            # Encode the commands as base64
            encoded_commands = base64.b64encode(app_cmd.encode("utf-8")).decode("utf-8")
            app_cmd = (
                'powershell -Command "'
                f"$encoded = '{encoded_commands}'; "
                "$decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded)); "
                "$decoded | Out-File -Encoding ASCII $env:AZ_BATCH_TASK_WORKING_DIR\\temp_commands.bat; "
                'cmd /c $env:AZ_BATCH_TASK_WORKING_DIR\\temp_commands.bat"'
            )
        else:
            cmds = [app_cmd]
            app_cmd = client.wrap_commands_in_shell(cmds, ostype=ostype)
        logger.debug("Application command: {}".format(app_cmd))
        #
        if "mpi_command" in config_dict:
            coordination_command_template = config_dict["coordination_command_template"]
            coordination_cmd = load_command_from_resourcepath(
                fname=coordination_command_template
            )
            coordination_cmd = coordination_cmd.format(**config_dict)
            coordination_cmd = client.wrap_commands_in_shell(
                [coordination_cmd], ostype=ostype
            )
            logger.debug("Coordination command: {}".format(coordination_cmd))
        else:
            coordination_cmd = None
        output_file_specs = []
        spec = client.create_output_file_spec(
            "../std*",
            "https://{}.blob.core.windows.net/{}?{}".format(
                storage_account_name, storage_container_name, config_dict["sas"]
            ),
            f"jobs/{job_name}/{task_name}",
            upload_condition=batchmodels.OutputFileUploadCondition.task_completion,
        )
        output_file_specs.append(spec)
        #
        if "container_run_options" in config_dict:
            task_container_settings = batchmodels.TaskContainerSettings(
                image_name=config_dict["container_image_name"],
                container_run_options=config_dict["container_run_options"],
            )
        else:
            task_container_settings = None
        #
        if "resource_files" in config_dict:
            resource_files = config_dict["resource_files"]
            resource_files = [  # convert to list of ResourceFile objects
                batchmodels.ResourceFile(
                    file_path=resource_file["file_path"],
                    auto_storage_container_name=storage_container_name,
                    blob_prefix=resource_file["blob_prefix"],
                )
                for resource_file in resource_files
            ]
        else:
            resource_files = None
        if "output_files" in config_dict:
            output_files = config_dict["output_files"]
            output_files = [  # convert to list of OutputFile objects
                batchmodels.OutputFile(
                    file_pattern=output_file["file_pattern"],
                    destination=batchmodels.OutputFileDestination(
                        container=batchmodels.OutputFileBlobContainerDestination(
                            container_url=f"https://{storage_account_name}.blob.core.windows.net/{storage_container_name}?{config_dict['sas']}",
                            path=output_file["path"],
                        )
                    ),
                    upload_options=batchmodels.OutputFileUploadOptions(
                        upload_condition=output_file["upload_condition"]
                    ),
                )
                for output_file in output_files
            ]
            output_file_specs.extend(output_files)

        if coordination_cmd is not None:
            task = client.create_task(
                task_name,
                app_cmd,
                num_instances=num_hosts,
                coordination_cmdline=coordination_cmd,
                resource_files=resource_files,
                env_settings=config_dict.get("environment_variables", None),
                output_files=output_file_specs,
                container_settings=task_container_settings,
            )
        else:
            task = client.create_task(
                task_name,
                app_cmd,
                resource_files=resource_files,
                env_settings=config_dict.get("environment_variables", None),
                output_files=output_file_specs,
                container_settings=task_container_settings,
            )
        tasks.append(task)
        if len(tasks) == 100:
            try:
                client.submit_tasks(job_name, tasks, auto_complete=False)
                tasks = []
            except BatchErrorException as e:
                print(e)
                raise e
    # adding auto_complete so that job terminates when all these tasks are completed.
    try:
        client.submit_tasks(job_name, tasks, auto_complete=True)
    except BatchErrorException as e:
        print(e)
        raise e
    logger.info(f"Submitted task {job_name} to pool {pool_name}.")
    return job_name, task_name


def parse_yaml_file(config_file):
    with open(config_file) as f:
        data = yaml.safe_load(f)
    return data


def create_batch_client(name, key, url) -> AzureBatch:
    return AzureBatch(name, key, url)


# https://stackoverflow.com/questions/39379331/python-exec-a-code-block-and-eval-the-last-line
import ast


def exec_then_eval(code):
    block = ast.parse(code, mode="exec")

    # assumes last node is an expression
    last = ast.Expression(block.body.pop().value)

    _globals, _locals = {}, {}
    exec(compile(block, "<string>", mode="exec"), _globals, _locals)
    return eval(compile(last, "<string>", mode="eval"), _globals, _locals)


def insert_after_key(dictionary, key, new_key, new_value):
    items = list(dictionary.items())
    index = next((i for i, (k, v) in enumerate(items) if k == key), -1)
    if index != -1:
        items.insert(index + 1, (new_key, new_value))
    return dict(items)


def initialize_config(config_file, pool_name=None):
    config_dict = parse_yaml_file(config_file)
    # get the output of git describe
    try:
        config_dict["dmsbatch_version"] = (
            subprocess.check_output("git describe", shell=True).decode("utf-8").strip()
        )
    except subprocess.SubprocessError as e:
        config_dict["dmsbatch_version"] = "unknown"
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
        __name__, f'templates/{config_dict["template_name"]}/default_config.yml'
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
        logger.debug("using batch account key from environment variable")
    else:
        config_dict["batch_account_key"] = get_batch_account_key(
            config_dict["resource_group"], config_dict["batch_account_name"]
        )
        logger.debug("using batch account key from az cli")
    if "STORAGE_ACCOUNT_KEY" in os.environ:
        config_dict["storage_account_key"] = os.environ["STORAGE_ACCOUNT_KEY"]
        logger.debug("using storage account key from environment variable")
    else:
        config_dict["storage_account_key"] = get_storage_account_key(
            config_dict["resource_group"], config_dict["storage_account_name"]
        )
        logger.debug("using storage account key from az cli")
    logger.debug("using vm size", config_dict["vm_size"])
    if "setup_dirs" not in config_dict:
        config_dict["setup_dirs"] = []
        logger.debug("using default setup dirs", config_dict["setup_dirs"])
    if "coordination_command_template" not in config_dict:
        config_dict["coordination_command_template"] = (
            f'templates/{config_dict["template_name"]}/coordination_command_template.sh'
        )
        logger.debug(
            "using default coordination command template",
            config_dict["coordination_command_template"],
        )
    if "task_slots_per_node" not in config_dict:
        config_dict["task_slots_per_node"] = get_core_count(
            config_dict["vm_size"], config_dict["location"]
        )
        logger.debug(
            "using default task slots per node", config_dict["task_slots_per_node"]
        )
    if "num_cores" not in config_dict:
        # insert the number of cores available right after the num_hosts key
        ncores = estimate_cores_available(
            config_dict["vm_size"], config_dict["num_hosts"], config_dict["location"]
        )
        config_dict = insert_after_key(config_dict, "num_hosts", "num_cores", ncores)
        logger.debug(
            f"using calculated number of cores cores using {config_dict['vm_size']}",
            config_dict["num_cores"],
        )
    # log the config dict
    logger.debug(config_dict)
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
    config_dict = move_key_to_first(config_dict, "sas")
    if "ostype" in config_dict and config_dict["ostype"] == "windows":
        sas_win = sas.replace("%", "%%")
        config_dict["sas_win"] = sas_win
        config_dict = move_key_to_first(config_dict, "sas_win")
    dtstr = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    if pool_name is None:
        pool_name = config_dict["pool_name"] + f"_{dtstr}"
    else:
        pool_name = pool_name
    config_dict["pool_name"] = pool_name
    # introduce special variable for task_id
    if config_dict.get("task_ids") is not None:
        # evaluate the task_id as a python expression
        config_dict["task_ids"] = exec_then_eval(
            config_dict["task_ids"].format(**config_dict)
        )
    else:
        config_dict["task_ids"] = [""]
    config_dict["task_id"] = config_dict["task_ids"][0]  # for now
    # add in app_pkgs_script
    config_dict["app_pkgs_script"] = build_app_pkg_scripts(config_dict)
    logger.info("config initialized...")
    return config_dict, client


def create_pool_from_config(config_file, pool_name=None):
    config_dict, client = initialize_config(config_file, pool_name)
    pool_name = create_pool(config_dict)
    return pool_name


def submit_job(config_file, pool_name=None):
    config_dict, client = initialize_config(config_file, pool_name)
    if pool_name is None:
        # create pool
        pool_name = create_pool(config_dict)
        pool_exists = False
    else:
        pool_exists = True

    job_name, task_name = submit_task(
        client, pool_name, config_dict, pool_exists=pool_exists
    )
    try:
        blob_client = AzureBlob(
            config_dict["storage_account_name"], config_dict["storage_account_key"]
        )
        config_filename = os.path.basename(config_file)
        logger.debug(
            f"uploading config file {config_file} to storage container under jobs/{job_name}/{config_filename}"
        )
        blob_client.upload_file_to_container(
            config_dict["storage_container_name"],
            f"jobs/{job_name}/{config_filename}",
            config_file,
        )
    except Exception as e:
        logger.error(e)
        logger.error("Error uploading config file to storage account")


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
