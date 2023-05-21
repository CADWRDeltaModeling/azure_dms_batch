import dmsbatch
from dmsbatch import __version__
from dmsbatch import commands
from dmsbatch import schismbatch
from dmsbatch import mount_blob

import click
import os
import sys

CONTEXT_SETTINGS = dict(help_option_names=['-h', '--help'])

@click.group(context_settings=CONTEXT_SETTINGS)
def main():
    pass

@click.command()
@click.option('--file', prompt='generate sample config file', help='config file')
def config_generate_cmd(file):
    commands.generate_blank_config(file)

@click.group()
def schism():
    pass

@click.command(help='submits schism job using the config file specified. You can generate a sample config file using the generate-config command')
@click.option('--file', prompt='config file', help='config file describing the job to be submitted. Use the generate-schism-job-config command to generate a sample config file.')
#optional pool name, no prompt needed
@click.option('--pool-name', help='The pool name if specified means the pool already exists and so would not be created but used', required=False)
def submit_schism_job(file, pool_name=None):
    schismbatch.submit_schism_job(file, pool_name)

@click.command(help='generate schism job yaml file: Use as an example to fill in your own yaml file')
@click.option('--file', prompt='generate sample config file', help='config file')
def generate_schism_job_config(file):
    schismbatch.generate_schism_job_yaml(file)

@click.command(help='set batch and storage account keys')
@click.option('--resource-group-name', prompt='resource group name', help='resource group name')
@click.option('--batch-account-name', prompt='batch account name', help='batch account name')
@click.option('--storage-account-name', prompt='storage account name', help='storage account name')
def set_keys(resource_group_name, batch_account_name, storage_account_name):
    batch_account_key = schismbatch.get_batch_account_key(resource_group_name, batch_account_name)
    storage_account_key = schismbatch.get_storage_account_key(resource_group_name, storage_account_name)
    if sys.platform == "win32":
        with open('schism_keys.bat','w') as f:
            f.write('set BATCH_ACCOUNT_KEY={}\n'.format(batch_account_key))
            f.write('set STORAGE_ACCOUNT_KEY={}\n'.format(storage_account_key))
        print('Batch and storage account keys written to schism_keys.bat')
        print('Run schism_keys.bat to set environment variables before using dmsbatch schism to submit jobs. Delete it when done for security.')
        print('call schism_keys.bat && del schism_keys.bat')
    else:
        with open('schism_keys.sh','w') as f:
            f.write('export BATCH_ACCOUNT_KEY={}\n'.format(batch_account_key))
            f.write('export STORAGE_ACCOUNT_KEY={}\n'.format(storage_account_key))
        print('Batch and storage account keys written to schism_keys.sh')
        print('Run source schism_keys.sh to set environment variables before using dmsbatch schism to submit jobs. Delete it when done for security.')
        print('source schism_keys.sh && rm schism_keys.sh')

@click.command(help='upload batch scripts to storage account')
@click.option('--resource-group-name', prompt='resource group name', help='resource group name')
@click.option('--storage-account-name', prompt='storage account name', help='storage account name')
def upload_batch_scripts(resource_group_name, storage_account_name):
    schismbatch.upload_batch_scripts(resource_group_name, storage_account_name)


schism.add_command(submit_schism_job, name='submit-job')
schism.add_command(generate_schism_job_config, name='generate-config')
schism.add_command(set_keys, name='set-keys')
schism.add_command(upload_batch_scripts, name='upload-batch-scripts')


main.add_command(config_generate_cmd, name='config-generate')
main.add_command(schism, name='schism')
main.add_command(mount_blob.mount_blob, name='mount-blob')
main.add_command(mount_blob.unmount_all_blobs)


if __name__ == '__main__':
    sys.exit(main())
