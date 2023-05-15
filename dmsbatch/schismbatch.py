import os
import subprocess
import shutil

import datetime
import pkg_resources
import json

from azure.batch.models import BatchErrorException
from dmsbatch.commands import AzureBatch


def load_command_from_resourcepath(fname):
    return pkg_resources.resource_string(__name__, fname).decode('utf-8')


def modify_json_file(json_file, modified_file, **kwargs):
    ''' the kwargs are the parameters to be modified in the json file.'''
    with open(json_file, 'r') as f:
        json_dict = json.load(f)
    for key, value in kwargs.items():
        json_dict['parameters'][key]['value'] = value
    with open(modified_file, 'w') as f:
        json.dump(json_dict, f, indent=4)

def build_autoscaling_formula(num_hosts, startTime):
    formula = pkg_resources.resource_string(__name__, 'schismpool_autoscale_formula.txt')
    formula = formula.decode('utf-8')
    formula = formula.format(num_hosts=num_hosts, startTime=startTime.isoformat())
    return formula

def create_schism_pool(resource_group_name, pool_name, num_hosts,
                       batch_account_name, storage_account_key, storage_name, container_name,
                       pool_bicep_resource='schismpool.bicep', pool_parameters_resource='schismpool.parameters.json'):
    ''' create a schism pool with the given number of hosts.  The pool name is
    assumed to include the date and time after the last _ in the name.'''
    vm_size = 'standard_hb120rs_v2'  # hardwired for now
    batch_scripts_dir = "batch"  # hardwired for now
    # pool_name has date and time appended after _
    dtstr = pool_name.split('_')[-1]
    bicep_file = pkg_resources.resource_filename(__name__, pool_bicep_resource)
    parameters_file = pkg_resources.resource_filename(__name__, pool_parameters_resource)
    modified_parameters_file = f'temp_schismpool.parameters_{dtstr}.json'
    try:
        modify_json_file(parameters_file, modified_parameters_file,
                        poolName=pool_name, 
                        batchAccountName=batch_account_name, storageAccountKey=storage_account_key, 
                        batchStorageName=storage_name, batchContainerName2=container_name,
                        formula = build_autoscaling_formula(num_hosts, datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)))
        # Run the command and capture its output
        cmdstr = f"az deployment group create --name {pool_name} --resource-group {resource_group_name} --template-file {bicep_file} --parameters {modified_parameters_file}"
        result = subprocess.check_output(cmdstr, shell=True).decode('utf-8').strip()
        # Print the output -- for debug ---
        #print(result)
        return pool_name
    finally:
        # delete the modified parameters file
        os.remove(modified_parameters_file)
        #print('removed the modified parameters file') # for debug 


def estimate_cores_available(vm_size, num_hosts):
    VM_CORE_MAP = {'standard_hc44rs': 44, 'standard_hb120rs_v2': 120}
    return num_hosts * (VM_CORE_MAP[vm_size] - 5)


def submit_schism_task(client, pool_name, num_hosts, num_cores, num_scribes, study_dir, setup_dirs,
                       storage_account_name, storage_container_name, sas,
                       application_command_template='application_command_template.sh',
                       mpi_command_template='mpiexec -n {num_cores} -ppn {num_hosts} -hosts $AZ_BATCH_HOST_LIST pschism_PREC_EVAP_GOTM_TVD-VL {num_scribes}',
                       coordination_command_template='coordination_command_template.sh'):
    # pool_name has date and time appended after _
    dtstr = pool_name.split('_')[-1]
    # name job and task with date and time
    job_name = f'schism_job_{dtstr}'
    try:
        client.create_job(job_name, pool_name)
    except BatchErrorException as e:
        if e.error.code == 'JobExists':
            print('Job already exists')
        else:
            raise e
    task_name = f'schism_{dtstr}'
    app_cmd = load_command_from_resourcepath(fname=application_command_template)
    app_cmd = app_cmd.format(num_cores=num_cores, num_scribes=num_scribes,
                                num_hosts=num_hosts, 
                                storage_account_name = storage_account_name,
                                storage_container_name = storage_container_name,
                                sas = sas,
                                study_dir=study_dir, setup_dirs=' '.join(setup_dirs),
                                mpi_command=mpi_command_template.format(num_cores=num_cores, num_hosts=num_hosts, num_scribes=num_scribes))
    app_cmd = client.wrap_cmd_with_app_path(app_cmd, [], ostype='linux')
    coordination_cmd = load_command_from_resourcepath(fname=coordination_command_template)
    coordination_cmd = coordination_cmd.format(num_cores=num_cores, num_scribes=num_scribes,
                                            num_hosts=num_hosts, 
                                            storage_container_name = storage_container_name, 
                                            study_dir=study_dir, setup_dirs=' '.join(setup_dirs))
    coordination_cmd = client.wrap_cmd_with_app_path(coordination_cmd, [], ostype='linux')
    #
    schism_task = client.create_task(task_name, app_cmd,
                                    num_instances=num_hosts,
                                    coordination_cmdline=coordination_cmd)
    client.submit_tasks(job_name, [schism_task])
    print(f'Submitted task {job_name} to pool {pool_name}.')


def parse_yaml_file(config_file):
    import yaml
    with open(config_file) as f:
        data = yaml.safe_load(f)
    return data


def create_batch_client(name, key, url):
    return AzureBatch(name, key, url)


def submit_schism_job(config_file):
    config_dict = parse_yaml_file(config_file)
    config_dict['pool_name'] = config_dict['job_name']  # hardwired for now
    config_dict['vm_size'] = 'standard_hb120rs_v2'  # hardwired for now
    location = 'eastus'  # hardwired for now
    # hardwired for now
    config_dict['batch_account_url'] = f'https://{config_dict["batch_account_name"]}.{location}.batch.azure.com'
    if 'BATCH_ACCOUNT_KEY' in os.environ:
        config_dict['batch_account_key'] = os.environ['BATCH_ACCOUNT_KEY']
    else:
        config_dict['batch_account_key'] = get_batch_account_key(config_dict['resource_group'],config_dict['batch_account_name'])
    if 'STORAGE_ACCOUNT_KEY' in os.environ:
        config_dict['storage_account_key'] = os.environ['STORAGE_ACCOUNT_KEY']
    else:
        config_dict['storage_account_key'] = get_storage_account_key(config_dict['resource_group'],config_dict['storage_account_name'])
    if 'application_command_template' not in config_dict:
        config_dict['application_command_template'] = 'application_command_template.sh'
    if 'mpi_command_template' not in config_dict:
        config_dict['mpi_command_template'] = 'mpiexec -n {num_cores} -ppn {num_hosts} -hosts $AZ_BATCH_HOST_LIST pschism_PREC_EVAP_GOTM_TVD-VL {num_scribes}'
    if 'coordination_command_template' not in config_dict:
        config_dict['coordination_command_template'] = 'coordination_command_template.sh'
    if 'num_cores' not in config_dict:
        config_dict['num_cores'] = estimate_cores_available(
            config_dict['vm_size'], config_dict['num_hosts'])
    if 'pool_bicep_resource_file' not in config_dict:
        config_dict['pool_bicep_resource_file'] = 'schismpool.bicep'
    if 'pool_parameters_file' not in config_dict:
        config_dict['pool_parameters_file'] = 'schismpool.parameters.json'
    #
    client = create_batch_client(
        config_dict['batch_account_name'], config_dict['batch_account_key'], config_dict['batch_account_url'])
    dtstr = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    pool_name = config_dict['pool_name'] + f'_{dtstr}'
    # create pool 
    pool_name = create_schism_pool(config_dict['resource_group'], pool_name, config_dict['num_hosts'],
                                   config_dict['batch_account_name'], config_dict['storage_account_key'], 
                                   config_dict['storage_account_name'], config_dict['storage_container_name'],
                                   pool_bicep_resource=config_dict['pool_bicep_resource_file'],
                                   pool_parameters_resource=config_dict['pool_parameters_file'])
    sas = get_sas(config_dict['storage_account_name'], config_dict['storage_account_key'], config_dict['storage_container_name'])
    submit_schism_task(client, pool_name, config_dict['num_hosts'], config_dict['num_cores'],
                       config_dict['num_scribes'], config_dict['study_dir'], config_dict['setup_dirs'],
                       config_dict['storage_account_name'], config_dict['storage_container_name'], sas,
                       config_dict['application_command_template'], config_dict['mpi_command_template'], config_dict['coordination_command_template'])


def generate_schism_job_yaml(config_file):
    job_yaml_template = pkg_resources.resource_filename(__name__, 'schism.job.yml')
    # copy template to config_file
    shutil.copyfile(job_yaml_template, config_file)


def get_batch_account_key(resource_group_name, batch_account_name):
    '''make sure az cli is logged in to the correct subscription. 
    Use az login --use-device-code to login to the correct subscription.'''
    cmd = f'az batch account keys list --name {batch_account_name} --resource-group {resource_group_name}'
    key_dict = json.loads(subprocess.check_output(cmd, shell=True).decode('utf-8').strip())
    return key_dict['primary']


def get_storage_account_key(resource_group_name, storage_account_name):
    '''make sure az cli is logged in to the correct subscription. 
    Use az login --use-device-code to login to the correct subscription.'''
    cmd = f'az storage account keys list --account-name {storage_account_name} --resource-group {resource_group_name}'
    key_dict = json.loads(subprocess.check_output(cmd, shell=True).decode('utf-8').strip())
    return key_dict[0]['value']

def get_sas(storage_account_name, storage_account_key, container_name, permissions='acdlrw', expires_in_days=7):
    '''make sure az cli is logged in to the correct subscription. 
    Use az login --use-device-code to login to the correct subscription.'''
    # export SAS=$(az storage container generate-sas --permissions acdlrw --expiry `date +%FT%TZ -u -d "+1 days"` --account-name ${storage_account} --name ${container} --output tsv --auth-mode key --account-key ${ACCOUNT_KEY} --only-show-errors)
    dt = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    # add expires_in_days
    expiry = (dt + datetime.timedelta(days=expires_in_days)).strftime('%Y-%m-%dT%H:%MZ')
    cmd = f'az storage container generate-sas --account-name {storage_account_name} --auth-mode key --account-key {storage_account_key} --name {container_name} --permissions {permissions} --expiry {expiry} --only-show-errors'
    return json.loads(subprocess.check_output(cmd, shell=True).decode('utf-8').strip())

def upload_batch_scripts(resource_group_name, storage_account_name, batch_container_name='batch'):
    if 'STORAGE_ACCOUNT_KEY' in os.environ:
        storage_account_key = os.environ['STORAGE_ACCOUNT_KEY']
    else:
        storage_account_key = get_storage_account_key(resource_group_name, storage_account_name)
    sas = get_sas(storage_account_name, storage_account_key, batch_container_name)
    batch_dir = pkg_resources.resource_filename('dmsbatch', '../schism_scripts/batch')
    # upload batch scripts
    cmd = f'cd {batch_dir} && azcopy cp "./*"  "https://{storage_account_name}.blob.core.windows.net/{batch_container_name}?{sas}" --recursive=true'
    subprocess.check_output(cmd, shell=True).decode('utf-8').strip()
    return
